"""Actual stdio launch, configuration changes and path denial in TEMP fixtures."""
import argparse
import asyncio
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import tomllib

from hwpx import HwpxDocument
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.shared.exceptions import McpError

ROOT = Path(__file__).resolve().parents[2]


async def check(parameters, source=None, denied=None):
    async with stdio_client(parameters) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            health = await session.call_tool('mcp_server_health', {})
            assert not health.isError, health.model_dump_json()
            if source:
                result = await session.call_tool('get_document_text', {'filename': str(source)})
                assert not result.isError and 'DYNAMIC_ROOT_CHECK' in result.model_dump_json()
            if denied:
                try:
                    result = await session.call_tool('get_document_text', {'filename': str(denied)})
                except McpError as error:
                    assert 'WORKSPACE_OUTSIDE_ROOT' in str(error), str(error)
                else:
                    assert result.isError and 'WORKSPACE_OUTSIDE_ROOT' in result.model_dump_json()


async def synthetic():
    with tempfile.TemporaryDirectory(prefix='hwpx-dynamic-launch-') as directory:
        fixture = Path(directory)
        root = fixture / 'tools'
        shared = root / '.agent/shared'
        shared.mkdir(parents=True)
        for name in ('hwpx_mcp_launch.py', 'hwpx_read_client.py', 'work_storage.py'):
            shutil.copy2(ROOT / '.agent/shared' / name, shared / name)
        index = root / '.agent/index'
        index.mkdir()
        runtime = root / '.agent/cache/runtime'
        for name in ('Scripts/python.exe', 'Lib/site-packages/hwpx_automation/mcp_cli.py'):
            path = runtime / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture', encoding='utf-8')
        (index / 'hwpx-runtime.json').write_text(json.dumps({
            'runtimeDirectory': '.agent/cache/runtime', 'skillVersion': '2.1.0'}), encoding='utf-8')
        cabinet = fixture / 'cabinet'
        cabinet.mkdir()
        outside = fixture / 'outside.hwpx'
        document = HwpxDocument.new()
        document.add_paragraph('DYNAMIC_ROOT_CHECK')
        document.save_to_path(str(outside))
        source = cabinet / 'source.hwpx'
        shutil.copy2(outside, source)
        config = index / 'delivery-system.json'
        def configure(selected):
            config.write_text(json.dumps({'humanCabinet': str(selected),
                'incomingRoot': str(fixture / 'missing-input')}), encoding='utf-8')
        configure(cabinet)
        parameters = StdioServerParameters(command=sys.executable,
            args=['-B', str(shared / 'hwpx_mcp_launch.py')],
            env={**os.environ, 'PYTHONUTF8': '1', 'PYTHONDONTWRITEBYTECODE': '1'})
        await check(parameters, source, outside)
        moved = fixture / 'moved-cabinet'
        cabinet.rename(moved)
        configure(moved)
        # Same command and args pick up the new selected root without reinstalling.
        await check(parameters, moved / source.name, outside)
        print(json.dumps({'ok': True, 'checks': [
            'stdio initialize and health', 'missing optional input ignored',
            'configured document readable', 'outside existing document denied',
            'same launcher follows configured cabinet move']}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--installed-config', type=Path)
    args = parser.parse_args()
    if args.installed_config:
        config = tomllib.loads(args.installed_config.read_text(encoding='utf-8-sig'))['mcp_servers']['hwpx']
        assert config['args'] == ['-B', str(ROOT / '.agent/shared/hwpx_mcp_launch.py')]
        parameters = StdioServerParameters(command=config['command'], args=config['args'],
            env={**os.environ, **config.get('env', {})})
        asyncio.run(asyncio.wait_for(check(parameters), 60))
        print(json.dumps({'ok': True, 'installedConfigStdioHealth': True}))
    else:
        asyncio.run(asyncio.wait_for(synthetic(), 90))


if __name__ == '__main__':
    main()
