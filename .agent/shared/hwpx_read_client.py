"""Bounded read-only fallback using the exact same MCP server, without Bash."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from work_storage import resolve_job

ROOT = Path(__file__).resolve().parents[2]
READ_TOOLS = frozenset({"get_document_text", "get_document_outline", "get_table_text", "get_document_map", "get_document_node", "query_document_nodes", "find_text", "mcp_server_health", "describe_capabilities"})

def server_parameters():
    spec = json.loads((ROOT / '.agent/index/hwpx-runtime.json').read_text(encoding='utf-8-sig'))
    delivery = json.loads((ROOT / '.agent/index/delivery-system.json').read_text(encoding='utf-8-sig'))
    for key in ('humanCabinet', 'incomingRoot'):
        directory = Path(delivery[key])
        delivery[key] = str((ROOT / directory).resolve() if not directory.is_absolute() else directory)
    runtime = (ROOT / spec['runtimeDirectory']).resolve()
    if not runtime.is_relative_to(ROOT):
        raise ValueError('Runtime escaped workspace')
    server = runtime / 'Scripts/python.exe'
    entry_point = runtime / 'Lib/site-packages/hwpx_automation/mcp_cli.py'
    if not server.is_file() or not entry_point.is_file():
        raise FileNotFoundError('Verified HWPX runtime missing; maintenance required')
    args = ['-B', '-m', 'hwpx_automation.mcp_cli']
    for directory in [str(ROOT), delivery['humanCabinet'], delivery['incomingRoot']]:
        # Missing optional roots must not invalidate reads in another selected root.
        # Never substitute a parent or create/authorize a new directory.
        if not Path(directory).exists():
            continue
        args.extend(['--workspace-root', directory])
    return StdioServerParameters(command=str(server), args=args, env={**os.environ, 'PYTHONUTF8':'1', 'PYTHONDONTWRITEBYTECODE':'1', 'HWPX_SKILL_VERSION':spec['skillVersion'], 'HWPX_STACK_AUTO_UPDATE':'0'})

def output_path(value):
    """Keep extracted school content in a validated work job's writable area."""
    output = Path(value).absolute()
    if any(':' in part for part in output.parts[1:]):
        raise ValueError('Alternate data streams are not allowed in result paths')
    for part in (output, *output.parents):
        try:
            attributes = part.lstat()
        except FileNotFoundError:
            continue
        if part.is_symlink() or getattr(attributes, 'st_file_attributes', 0) & 0x400:
            raise ValueError('Result paths must not use reparse points')
    candidate = next((parent for parent in output.parents if parent.parent.name.lower() == 'jobs'), None)
    if candidate is None:
        raise ValueError('Read results must be within a work job wip directory')
    job = resolve_job(ROOT, candidate)
    output = output.resolve()
    if not output.is_relative_to(job / 'wip') or output == job / 'wip':
        raise ValueError('Read results must be within the selected job wip directory')
    if output.exists():
        raise FileExistsError('Use a new output path; existing results are preserved')
    return output

async def read_batch(requests):
    if not isinstance(requests, list) or not 1 <= len(requests) <= 100:
        raise ValueError('Expected 1..100 read requests')
    for request in requests:
        if request.get('tool') not in READ_TOOLS or not isinstance(request.get('arguments', {}), dict):
            raise ValueError('Only declared read-only tools are allowed')
    async with stdio_client(server_parameters()) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            results = []
            for request in requests:
                result = await session.call_tool(request['tool'], request.get('arguments', {}))
                if result.isError:
                    raise RuntimeError(result.model_dump_json())
                results.append({'tool':request['tool'], 'result':result.model_dump(mode='json')})
            return results

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--request', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--timeout', type=int, default=60)
    args = parser.parse_args()
    output = output_path(args.output)
    requests = json.loads(Path(args.request).read_text(encoding='utf-8-sig'))
    results = asyncio.run(asyncio.wait_for(read_batch(requests), timeout=args.timeout))
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x', encoding='utf-8') as stream:
        json.dump({'ok':True, 'results':results}, stream, ensure_ascii=False, indent=2)
    print(json.dumps({'ok':True, 'count':len(results), 'output':str(output)}, ensure_ascii=False))

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
