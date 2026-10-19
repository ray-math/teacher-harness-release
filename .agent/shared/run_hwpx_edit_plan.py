"""Durable local adapter for the same public run_edit_plan engine used by HWPX MCP.

No package/ZIP/XML editing here. The supported engine retains step checks, final
open-safety and atomic candidate writing. Only a verified candidate is published.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from contextlib import contextmanager
from datetime import datetime, timezone

sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"

from work_storage import resolve_job
from document_scope import assert_scope


def now():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest() if Path(path).is_file() else None


def write_json(path, data):
    path = Path(path)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(tmp, path)


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


@contextmanager
def file_lock(path, *, source=False):
    """Deny writes/deletes to a source; deny simultaneous adapters to an operation."""
    if os.name != 'nt':
        raise RuntimeError('This workspace adapter requires Windows.')
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                  ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.CreateFileW(str(path), 0x80000000 if source else 0xC0000000,
                                1 if source else 0, None, 3 if source else 4, 0x80, None)
    if handle == wintypes.HANDLE(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        yield
    finally:
        kernel.CloseHandle(handle)


def inside(path, root):
    resolved = Path(path).resolve()
    if not resolved.is_relative_to(root.resolve()):
        raise ValueError(f'Path escaped permitted job: {path}')
    return resolved


def setup(args):
    workspace = Path(__file__).resolve().parents[2]
    job = resolve_job(workspace, args.job)
    if not (job / 'inputs.json').is_file():
        raise ValueError('An existing active job is required.')
    plan = read_json(inside(args.plan, job))
    if not args.status:
        assert_scope(job, 'edit_plan', args.plan)
    source = Path(plan['source']).resolve(strict=True)
    output = inside(plan['output'], job / 'wip')
    if source == output:
        raise ValueError('Source and destination must differ.')
    if output.suffix.lower() != '.hwpx':
        raise ValueError('Output must be HWPX.')
    plan['source'], plan['output'] = str(source), str(output)
    plan.pop('journalPath', None)
    key = hashlib.sha256(json.dumps([plan, args.source_sha256.lower(), args.dry_run], sort_keys=True,
                                    ensure_ascii=False).encode()).hexdigest()[:20]
    run = job / 'wip' / 'receipts' / ('edit-' + key)
    run.mkdir(parents=True, exist_ok=True)
    return plan, run


def reconcile(run, output):
    state_path = run / 'state.json'
    state = read_json(state_path) if state_path.exists() else {'status': 'not_started', 'saved': False}
    if state.get('status') == 'running':
        try:
            with file_lock(run / 'worker.lock'):
                state.update(status='interrupted_before_publish', saved=False)
        except OSError:
            state['workerActive'] = True
    if state.get('dryRun'):
        return state
    actual = digest(output)
    expected = state.get('candidateSha256')
    if actual and expected and actual == expected:
        state.update(status='saved', saved=True, outputSha256=actual)
    elif actual:
        state.update(status='output_conflict_or_unknown', saved=None)
    elif state.get('saved'):
        state.update(status='output_missing', saved=None)
    return state


def worker(args, plan, run):
    # Pin the small observation adapter to the installed API version. Wrappers
    # measure calls and persist progress; all validation/operation code is upstream.
    from importlib.metadata import version
    if version('python-hwpx') != '6.3.0' or version('python-hwpx-automation') != '7.0.4':
        raise RuntimeError('Runtime version differs from the tested adapter.')
    from hwpx.plan import _execute as engine
    from hwpx_automation.hwpx_ops import HwpxOps

    source, output = Path(plan['source']), Path(plan['output'])
    candidate = run / 'candidate.hwpx'
    execution = dict(plan, output=str(candidate), journalPath=str(run / 'journal.jsonl'))
    state = {'status': 'running', 'saved': False, 'dryRun': args.dry_run, 'pid': os.getpid(), 'startedAt': now(),
             'output': str(output), 'sourceSha256': args.source_sha256.lower(),
             'stageSeconds': {}, 'phase': 'analysis'}
    timings = state['stageSeconds']
    originals = []

    def observe(owner, name, phase):
        old = owner[name] if isinstance(owner, dict) else getattr(owner, name)
        def measured(*a, **kw):
            state.update(phase=phase, phaseStartedAt=now(), updatedAt=now())
            write_json(run / 'state.json', state)
            start = time.perf_counter()
            try:
                return old(*a, **kw)
            finally:
                timings[phase] = timings.get(phase, 0) + time.perf_counter() - start
                state['updatedAt'] = now()
                write_json(run / 'state.json', state)
        if isinstance(owner, dict): owner[name] = measured
        else: setattr(owner, name, measured)
        originals.append((owner, name, old))

    observe(engine, 'validate_edit_plan', 'analysis')
    for op in engine._DISPATCH: observe(engine._DISPATCH, op, 'edit_including_step_checks')
    observe(engine, 'validate_editor_open_safety', 'final_validation')
    observe(engine, 'write_bytes_atomically', 'candidate_save')
    started = time.perf_counter()
    try:
        with file_lock(source, source=True):
            if digest(source) != args.source_sha256.lower():
                raise ValueError('Source revision differs from the expected intake SHA256.')
            write_json(run / 'state.json', state)
            report = HwpxOps(base_directory=Path(args.job), auto_backup=True).run_edit_plan(execution, dry_run=args.dry_run)
            write_json(run / 'engine-report.json', report)
            if not report.get('ok'):
                state.update(status='failed_before_publish', failedStepId=report.get('failedStepId'))
            elif args.dry_run:
                state.update(status='dry_run_passed')
            else:
                if not report.get('executed') or not candidate.is_file():
                    raise RuntimeError('Engine did not return a saved candidate.')
                state.update(status='candidate_ready', candidateSha256=digest(candidate), phase='publish')
                write_json(run / 'state.json', state)
                if digest(source) != args.source_sha256.lower():
                    raise ValueError('Source changed during execution.')
                assert_scope(args.job, 'edit_plan', run / 'plan.json')
                output.parent.mkdir(parents=True, exist_ok=True)
                start = time.perf_counter()
                # Windows rename fails if the destination appeared concurrently.
                # It never replaces a human/current draft or an unrelated output.
                os.rename(candidate, output)
                timings['publish'] = time.perf_counter() - start
                state.update(status='saved', saved=True, outputSha256=digest(output))
    except BaseException as exc:
        state.update(status='failed_before_publish', error=f'{type(exc).__name__}: {exc}')
    finally:
        for owner, name, old in reversed(originals):
            if isinstance(owner, dict): owner[name] = old
            else: setattr(owner, name, old)
        state.update(finishedAt=now(), elapsedSeconds=time.perf_counter() - started)
        timings.update({k: round(v, 6) for k, v in timings.items()})
        write_json(run / 'state.json', state)
    return 0 if state['status'] in ('saved', 'dry_run_passed') else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--job', required=True)
    parser.add_argument('--plan', required=True)
    parser.add_argument('--source-sha256', required=True)
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--status', action='store_true')
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    plan, run = setup(args)
    if args.worker:
        with file_lock(run / 'worker.lock'):
            return worker(args, plan, run)
    if args.status:
        state = reconcile(run, plan['output'])
        print(json.dumps({'receiptDirectory': str(run), **state}, ensure_ascii=False))
        return 0
    with file_lock(run / 'operation.lock'):
        # A supervisor may have been interrupted while its worker is still alive.
        with file_lock(run / 'worker.lock'):
            pass
        state = reconcile(run, plan['output'])
        if state['status'] in ('saved', 'dry_run_passed'):
            if digest(plan['source']) != args.source_sha256.lower():
                raise ValueError('Source revision changed; completed receipt cannot be reused.')
            print(json.dumps({'receiptDirectory': str(run), 'reused': True, **state}, ensure_ascii=False))
            return 0
        if state.get('saved') is None or Path(plan['output']).exists():
            raise RuntimeError('Output state is ambiguous or conflicts. Inspect state and hashes before creating a new plan.')
        if digest(plan['source']) != args.source_sha256.lower():
            raise ValueError('Source revision differs from expected intake SHA256.')
        write_json(run / 'plan.json', plan)
        write_json(run / 'request.json', {'sourceSha256': args.source_sha256.lower(), 'dryRun': args.dry_run,
                                         'job': args.job, 'timeoutSeconds': args.timeout})
        command = [sys.executable, __file__, '--worker', '--job', args.job, '--plan', str(run / 'plan.json'),
                   '--source-sha256', args.source_sha256, '--timeout', str(args.timeout)]
        if args.dry_run: command.append('--dry-run')
        with (run / 'worker.log').open('a', encoding='utf-8') as log:
            process = subprocess.Popen(command, stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)
            timed_out = False
            try: code = process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                process.kill()
                process.wait()
                code = 2
        state = reconcile(run, plan['output'])
        if timed_out:
            state.update(timedOut=True)
            if state['status'] not in ('saved', 'output_conflict_or_unknown'):
                state.update(status='interrupted_before_publish', saved=False)
            write_json(run / 'state.json', state)
        print(json.dumps({'receiptDirectory': str(run), **state}, ensure_ascii=False))
        return 0 if state['status'] == 'saved' else code


if __name__ == '__main__':
    try: sys.exit(main())
    except Exception as error:
        print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False))
        sys.exit(1)
