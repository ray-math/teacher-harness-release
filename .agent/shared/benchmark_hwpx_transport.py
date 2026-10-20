"""Compare HWPX MCP connection reuse with equal synthetic read workloads.

This measures Python MCP transport and server startup, not engine improvements,
model reasoning/tokens, Windows integration, or Hancom rendering.
"""
import argparse
import asyncio
from contextlib import asynccontextmanager
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import platform
import statistics
import sys
import tempfile
import time


MODES = ('fresh_per_call', 'fresh_per_batch', 'persistent_session')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def percentile95(values):
    return sorted(values)[max(0, math.ceil(len(values) * .95) - 1)]


def summarize(values):
    return {'medianSeconds': round(statistics.median(values), 6),
            'p95Seconds': round(percentile95(values), 6), 'samples': len(values)}


def startup_inclusive_estimates(samples, startup):
    persistent_total = sum(sample['totalSeconds'] for sample in samples['persistent_session'])
    batch_total = sum(sample['totalSeconds'] for sample in samples['fresh_per_batch'])
    count = len(samples['persistent_session'])
    inclusive = startup + persistent_total
    return {'kind': 'derived estimate from measured startup and measured workload samples',
            'includesWarmup': False,
            'persistentStartupPlusRepeatedWorkloadsSeconds': round(inclusive, 6),
            'persistentAmortizedSecondsPerWorkload': round(inclusive / count, 6),
            'freshPerBatchMeasuredRepeatedWorkloadsSeconds': round(batch_total, 6),
            'estimatedTimeReductionPercent': round((batch_total - inclusive) / batch_total * 100, 2),
            'singleWorkloadStartupInclusiveEstimateSeconds': round(startup + statistics.median(
                sample['totalSeconds'] for sample in samples['persistent_session']), 6),
            'limitation': 'Not an independently measured cold end-to-end run; fresh modes include shutdown, persistent shutdown excluded; persistent calls were already warm.'}


def create_fixtures(directory):
    from hwpx import HwpxDocument
    specifications = [('small', 8, 3, 3), ('medium', 100, 20, 5)]
    fixtures = []
    for name, paragraphs, rows, cols in specifications:
        document = HwpxDocument.new()
        for index in range(paragraphs):
            document.add_paragraph(f'{name} 본문 {index:03d}: 합성 문서 읽기 비교용 문장입니다.')
        table = document.add_table(rows, cols)
        for row in range(rows):
            for col in range(cols):
                table.set_cell_text(row, col, f'{name} 표 {row:02d}/{col:02d}')
        path = directory / f'{name} 한글 경로.hwpx'
        document.save_to_path(str(path))
        fixtures.append({'name': name, 'path': path, 'bodyParagraphs': paragraphs,
                         'rows': rows, 'columns': cols, 'sha256': digest(path),
                         'bytes': path.stat().st_size})
    return fixtures


@asynccontextmanager
async def connection(directory):
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
    parameters = StdioServerParameters(command=sys.executable,
        args=['-B', '-m', 'hwpx_automation.mcp_cli', '--workspace-root', str(directory)],
        env={**os.environ, 'PYTHONUTF8': '1', 'PYTHONDONTWRITEBYTECODE': '1',
             'HWPX_STACK_AUTO_UPDATE': '0'})
    start = time.perf_counter()
    async with stdio_client(parameters) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            yield session, time.perf_counter() - start


async def call(session, tool, arguments, timeout):
    start = time.perf_counter()
    result = await asyncio.wait_for(session.call_tool(tool, arguments), timeout)
    elapsed = time.perf_counter() - start
    if result.isError:
        raise RuntimeError(result.model_dump_json())
    value = result.model_dump(mode='json', exclude_none=True)
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True,
                         separators=(',', ':')).encode('utf-8')
    name = Path(arguments['filename']).name.split()[0]
    marker = f'{name} ' + ('본문' if tool == 'get_document_text' else '표')
    if marker.encode('utf-8') not in encoded:
        raise AssertionError(f'Expected synthetic content absent: {tool}, {name}')
    return hashlib.sha256(encoded).hexdigest(), elapsed


async def workload(mode, directory, requests, timeout, persistent):
    start = time.perf_counter()
    hashes, operation_seconds, startup_seconds = [], [], []
    if mode == 'fresh_per_call':
        for tool, arguments in requests:
            async with connection(directory) as (session, startup):
                startup_seconds.append(startup)
                result_hash, duration = await call(session, tool, arguments, timeout)
                hashes.append(result_hash)
                operation_seconds.append(duration)
    elif mode == 'fresh_per_batch':
        async with connection(directory) as (session, startup):
            startup_seconds.append(startup)
            for tool, arguments in requests:
                result_hash, duration = await call(session, tool, arguments, timeout)
                hashes.append(result_hash)
                operation_seconds.append(duration)
    else:
        for tool, arguments in requests:
            result_hash, duration = await call(persistent, tool, arguments, timeout)
            hashes.append(result_hash)
            operation_seconds.append(duration)
    return {'totalSeconds': time.perf_counter() - start,
            'startupSeconds': sum(startup_seconds), 'startupEvents': startup_seconds,
            'toolCallSeconds': sum(operation_seconds), 'resultHashes': hashes}


async def benchmark(args):
    with tempfile.TemporaryDirectory(prefix='hwpx-transport-benchmark-') as temporary:
        directory = Path(temporary)
        fixtures = create_fixtures(directory)
        requests = [(tool, {'filename': str(fixture['path'])}) for fixture in fixtures
                    for tool in ('get_document_text', 'get_table_text')]
        samples = {mode: [] for mode in MODES}
        baseline = None
        async with connection(directory) as (persistent, persistent_startup):
            # Every mode sees one unrecorded full-workload warmup.
            for mode in MODES:
                result = await workload(mode, directory, requests, args.call_timeout, persistent)
                if baseline is None:
                    baseline = result['resultHashes']
                if result['resultHashes'] != baseline:
                    raise AssertionError(f'Warmup result content differs: {mode}')
            for repetition in range(args.repetitions):
                order = MODES[repetition % 3:] + MODES[:repetition % 3]
                # Alternate direction so six repetitions balance all mode positions.
                if (repetition // 3) % 2:
                    order = tuple(reversed(order))
                for mode in order:
                    result = await workload(mode, directory, requests, args.call_timeout, persistent)
                    if result.pop('resultHashes') != baseline:
                        raise AssertionError(f'Result content differs: {mode}, trial {repetition}')
                    result['trial'] = repetition + 1
                    samples[mode].append(result)
        for fixture in fixtures:
            if digest(fixture['path']) != fixture['sha256']:
                raise AssertionError(f'Synthetic source changed: {fixture["name"]}')
        summary = {}
        for mode, mode_samples in samples.items():
            summary[mode] = {
                'workloadTotal': summarize([sample['totalSeconds'] for sample in mode_samples]),
                'startupWithinWorkload': summarize([sample['startupSeconds'] for sample in mode_samples]),
                'toolCallsWithinWorkload': summarize([sample['toolCallSeconds'] for sample in mode_samples]),
            }
        persistent_median = summary['persistent_session']['workloadTotal']['medianSeconds']
        improvements = {}
        for mode in ('fresh_per_call', 'fresh_per_batch'):
            reference = summary[mode]['workloadTotal']['medianSeconds']
            improvements[mode] = {'persistentSpeedupRatio': round(reference / persistent_median, 3),
                'persistentTimeReductionPercent': round((reference - persistent_median) / reference * 100, 2)}
        return {'ok': True, 'benchmark': 'equal synthetic HWPX MCP read workloads',
            'scope': 'MCP transport/session reuse; same Python HWPX server and engine in all modes',
            'excludes': ['model latency', 'token usage', 'Windows installation', 'Hancom rendering',
                         'direct library versus MCP comparison', 'real school document performance'],
            'versions': {name: importlib.metadata.version(name) for name in
                         ('python-hwpx', 'python-hwpx-automation', 'mcp')},
            'environment': {'python': sys.version.split()[0], 'platform': platform.platform()},
            'fixtureStorage': 'TemporaryDirectory; removed after measurement',
            'fixtures': [{key: value for key, value in fixture.items() if key != 'path'} for fixture in fixtures],
            'workloadCalls': len(requests), 'repetitions': args.repetitions,
            'warmupsPerMode': 1, 'order': 'rotating positions, alternating direction every three trials',
            'p95Method': 'nearest-rank; descriptive only with this small sample count',
            'persistentSessionStartupSeconds': round(persistent_startup, 6),
            'persistentStartupPolicy': 'one startup before warmup; excluded from persistent workload totals',
            'totalTimingIncludes': 'context shutdown for fresh modes; persistent connection remains open',
            'checks': {'expectedBodyAndTableMarkersPresent': True,
                       'equalFullResultContentHashes': True, 'sourceSha256Unchanged': True},
            'resultContentHashes': baseline, 'summary': summary,
            'persistentComparison': improvements,
            'startupInclusiveEstimates': startup_inclusive_estimates(samples, persistent_startup),
            'samples': samples}


async def sequence_workload(mode, directory, requests, timeout, batches):
    """Time full sequence, including initialize and connection shutdown."""
    start = time.perf_counter()
    hashes = []
    if mode == 'persistent_session':
        async with connection(directory) as (session, _):
            for _ in range(batches):
                result = await workload(mode, directory, requests, timeout, session)
                hashes.extend(result['resultHashes'])
    else:
        for _ in range(batches):
            result = await workload(mode, directory, requests, timeout, None)
            hashes.extend(result['resultHashes'])
    return {'totalSeconds': time.perf_counter() - start, 'resultHashes': hashes}


async def benchmark_sequence(args):
    with tempfile.TemporaryDirectory(prefix='hwpx-sequence-benchmark-') as temporary:
        directory = Path(temporary)
        fixtures = create_fixtures(directory)
        requests = [(tool, {'filename': str(fixture['path'])}) for fixture in fixtures
                    for tool in ('get_document_text', 'get_table_text')]
        modes = ('fresh_per_batch', 'persistent_session')
        samples = {mode: [] for mode in modes}
        baseline = None
        for repetition in range(args.sequence_repetitions):
            order = modes if repetition % 2 == 0 else tuple(reversed(modes))
            for mode in order:
                result = await sequence_workload(mode, directory, requests,
                    args.call_timeout, args.sequence_batches)
                hashes = result.pop('resultHashes')
                if baseline is None:
                    baseline = hashes
                if hashes != baseline or len(hashes) != len(requests) * args.sequence_batches:
                    raise AssertionError(f'Sequence result content differs: {mode}, trial {repetition}')
                for fixture in fixtures:
                    if digest(fixture['path']) != fixture['sha256']:
                        raise AssertionError(f'Sequence source changed: {fixture["name"]}')
                result['trial'] = repetition + 1
                result['position'] = order.index(mode) + 1
                samples[mode].append(result)
        summary = {mode: summarize([sample['totalSeconds'] for sample in mode_samples])
                   for mode, mode_samples in samples.items()}
        batch_median = summary['fresh_per_batch']['medianSeconds']
        persistent_median = summary['persistent_session']['medianSeconds']
        return {'ok': True, 'benchmark': 'end-to-end repeated MCP read batches',
            'scope': 'Same Python MCP server and HWPX engine; actual measured startup, initialize, tool calls, and shutdown included',
            'excludes': ['model latency', 'token usage', 'Windows installation', 'Hancom rendering',
                         'direct library versus MCP comparison', 'real school document performance'],
            'versions': {name: importlib.metadata.version(name) for name in
                        ('python-hwpx', 'python-hwpx-automation', 'mcp')},
            'environment': {'python': sys.version.split()[0], 'platform': platform.platform()},
            'sequenceBatches': args.sequence_batches, 'callsPerBatch': len(requests),
            'callsPerSequence': len(requests) * args.sequence_batches,
            'repetitions': args.sequence_repetitions, 'warmups': 0,
            'order': 'alternate mode order each trial',
            'p95Method': 'nearest-rank; descriptive only with this small sample count',
            'fixtureStorage': 'TemporaryDirectory; removed after measurement',
            'fixtures': [{key: value for key, value in fixture.items() if key != 'path'} for fixture in fixtures],
            'checks': {'expectedBodyAndTableMarkersPresent': True,
                       'equalFullResultContentHashes': True, 'sourceSha256Unchanged': True},
            'resultContentHashes': baseline,
            'summary': summary,
            'persistentComparison': {'speedupRatio': round(batch_median / persistent_median, 3),
                'timeReductionPercent': round((batch_median-persistent_median) / batch_median * 100, 2)},
            'samples': samples}


async def run_benchmarks(args):
    if args.sequence_only:
        return await benchmark_sequence(args)
    result = await benchmark(args)
    result['startupInclusiveSequenceMeasurement'] = await benchmark_sequence(args)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New JSON output path; never overwritten')
    parser.add_argument('--repetitions', type=int, default=6)
    parser.add_argument('--timeout', type=float, default=300, help='Whole benchmark timeout in seconds')
    parser.add_argument('--call-timeout', type=float, default=30, help='Individual tool call timeout')
    parser.add_argument('--sequence-only', action='store_true', help='Run only the startup-inclusive sequence comparison')
    parser.add_argument('--sequence-batches', type=int, default=6, help='Number of four-call batches per sequence')
    parser.add_argument('--sequence-repetitions', type=int, default=3, help='Alternating-order trials per sequence mode')
    args = parser.parse_args()
    if not 3 <= args.repetitions <= 50 or args.timeout <= 0 or args.call_timeout <= 0:
        parser.error('Use 3..50 repetitions and positive timeouts')
    if not 1 <= args.sequence_batches <= 100 or not 2 <= args.sequence_repetitions <= 50:
        parser.error('Use 1..100 sequence batches and 2..50 sequence repetitions')
    if args.output.exists():
        parser.error('Output already exists; choose a new path')
    result = asyncio.run(asyncio.wait_for(run_benchmarks(args), timeout=args.timeout))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(json.dumps({'ok': True, 'output': str(args.output.resolve()),
                      'summary': result['summary'],
                      'persistentComparison': result['persistentComparison']}, ensure_ascii=False))


if __name__ == '__main__':
    main()
