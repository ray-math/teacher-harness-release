"""Verify a registered HWPX stdio server without reading school documents."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import sys
import tomllib

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

REQUIRED_TOOLS = frozenset({"mcp_server_health", "get_document_text",
                            "get_table_text", "run_edit_plan"})


def parameters_from_config(path):
    server = tomllib.loads(path.read_text(encoding="utf-8-sig"))["mcp_servers"]["hwpx"]
    if server.get("enabled", True) is not True:
        raise ValueError("HWPX MCP registration is disabled")
    if server.get("transport", "stdio") != "stdio" or not server.get("command"):
        raise ValueError("Expected a local HWPX stdio command")
    if REQUIRED_TOOLS.intersection(server.get("disabled_tools", [])):
        raise ValueError("Required HWPX tools are disabled")
    if "enabled_tools" in server and not REQUIRED_TOOLS.issubset(server["enabled_tools"]):
        raise ValueError("Required HWPX tools are not enabled")
    return StdioServerParameters(command=server["command"], args=server.get("args", []),
        env={**os.environ, **server.get("env", {}), "PYTHONDONTWRITEBYTECODE": "1"})


async def verify(parameters):
    async with stdio_client(parameters) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            names = set()
            cursor = None
            seen = set()
            while True:
                page = await session.list_tools(cursor=cursor)
                names.update(tool.name for tool in page.tools)
                cursor = page.nextCursor
                if not cursor:
                    break
                if cursor in seen:
                    raise RuntimeError("Repeated MCP tool-list cursor")
                seen.add(cursor)
            missing = REQUIRED_TOOLS - names
            if missing:
                raise RuntimeError("HWPX MCP is missing required tools: " + ", ".join(sorted(missing)))
            health = await session.call_tool("mcp_server_health", {})
            if health.isError:
                raise RuntimeError("HWPX MCP health tool reported an error")
            payload = health.structuredContent
            if payload is None:
                for block in health.content:
                    if block.type == "text":
                        try:
                            payload = json.loads(block.text)
                            break
                        except (ValueError, TypeError):
                            continue
            if not isinstance(payload, dict):
                raise RuntimeError("HWPX MCP health payload is missing")
            if (payload.get("toolSurface", {}).get("status") != "ok"
                    or payload.get("capability", {}).get("ok") is not True
                    or payload.get("workspace", {}).get("rootCount", 0) < 1
                    or payload.get("workspace", {}).get("configurationError")):
                raise RuntimeError("HWPX MCP health reported tool, capability or workspace failure")
    return {"ok": True, "stdioInitializeVerified": True, "requiredToolsVerified": True,
            "healthVerified": True, "schoolDocumentsRead": False,
            "currentChatToolExposureVerified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("Timeout must be positive")
    try:
        result = asyncio.run(asyncio.wait_for(verify(parameters_from_config(args.config)), args.timeout))
    except Exception:
        # A server may embed settings or document paths in its exceptions.
        print("HWPX MCP startup, required-tools or health verification failed.", file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
