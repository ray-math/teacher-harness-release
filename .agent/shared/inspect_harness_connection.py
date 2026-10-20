"""Read the selected Codex TOML without exposing unrelated settings or secrets."""
import json
import sys
import tomllib
from pathlib import Path

config, executable, launcher, version = sys.argv[1:]
path = Path(config)
data = tomllib.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else {}
server = data.get("mcp_servers", {}).get("hwpx")
if server is None:
    result = {"exists": False, "matchesProject": False}
else:
    required = {"HWPX_STACK_AUTO_UPDATE": "0", "PYTHONUTF8": "1", "HWPX_SKILL_VERSION": version}
    env = server.get("env", {})
    required_tools = {"mcp_server_health", "get_document_text", "get_table_text", "run_edit_plan"}
    enabled_tools = server.get("enabled_tools")
    tools_available = (not required_tools.intersection(server.get("disabled_tools", []))
                       and (enabled_tools is None or required_tools.issubset(enabled_tools)))
    matches = (
        server.get("command") == executable
        and server.get("args") == ["-B", launcher]
        and server.get("enabled", True)
        and tools_available
        and all(env.get(key) == value for key, value in required.items())
    )
    result = {"exists": True, "matchesProject": bool(matches)}
print(json.dumps(result))
