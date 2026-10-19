"""Isolated request-level relocation and optional-root regression; no school data."""
import asyncio
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from hwpx import HwpxDocument
import hwpx_read_client as client
from mcp import ClientSession
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parents[2]

def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8-sig')

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(shared, name, *args, ok=True):
    started = time.perf_counter()
    p = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                        '-File', str(shared/name), *map(str, args)],
                       capture_output=True, encoding='utf-8', errors='replace', timeout=90,
                       env={**os.environ, 'PSModulePath':str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/Modules')})
    metrics.append({'script':name, 'seconds':round(time.perf_counter()-started, 4),
                    'responseBytes':len(p.stdout.encode('utf-8')), 'exitCode':p.returncode})
    if (p.returncode == 0) != ok:
        raise AssertionError(p.stdout + p.stderr)
    if ok:
        try:
            return json.loads(p.stdout.lstrip('\ufeff'))
        except ValueError as error:
            raise AssertionError(repr(p.stdout) + repr(p.stderr)) from error
    return p.stderr

async def read_source(params, source):
    # Use the verified interpreter with launcher-generated arguments in the isolated cabinet.
    params.command = sys.executable
    async with stdio_client(params) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            result = await session.call_tool('get_document_text', {'filename':str(source)})
            if result.isError:
                raise RuntimeError(result.model_dump_json())
            assert 'PATH_RESUME_CONTENT' in result.model_dump_json()

def error_text(error):
    return str(error) + ' '.join(error_text(item) for item in getattr(error, 'exceptions', ()))

metrics = []
def main():
    fixture = Path(tempfile.mkdtemp(prefix='workflow-path-resume-'))
    tool = fixture/'tools'; shared = tool/'.agent/shared'; cabinet = fixture/'cabinet'
    shared.mkdir(parents=True); cabinet.mkdir()
    for name in ('Start-HwpxWork.ps1', 'New-HwpxJob.ps1', 'WorkStorage.ps1',
                 'WorkRegistry.ps1', 'DocumentScope.ps1', 'Sync-HumanSourcePreservation.ps1',
                 'HumanRevisionStorage.ps1', 'HumanDeliveryContract.ps1',
                 'Complete-HumanDraft.ps1', 'Publish-HumanResult.ps1', 'Get-HwpxRuntime.ps1',
                 'Set-HumanCabinetRoot.ps1'):
        shutil.copy2(ROOT/'.agent/shared'/name, shared/name)
    config = json.loads((ROOT/'.agent/index/delivery-system.json').read_text(encoding='utf-8-sig'))
    config.update(humanCabinet=str(cabinet), incomingRoot=str(fixture/'missing-incoming'))
    cfg = tool/'.agent/index/delivery-system.json'; save(cfg, config)
    save(tool/'.agent/index/hwpx-runtime.json', {'runtimeDirectory':'.agent/cache/runtime', 'skillVersion':'2.1.0'})
    for stub in ('Scripts/python.exe','Lib/site-packages/hwpx_automation/mcp_cli.py'):
        p = tool/'.agent/cache/runtime'/stub; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('fixture')
    client.ROOT = tool
    source = cabinet/'source.hwpx'
    doc = HwpxDocument.new(); doc.add_paragraph('PATH_RESUME_CONTENT'); doc.save_to_path(str(source))
    before = sha(source)
    optional_read = {'ok':False}
    try:
        asyncio.run(asyncio.wait_for(read_source(client.server_parameters(), source), 30))
        optional_read = {'ok':True}
    except Exception as error:
        optional_read['error'] = str(error)
    assert optional_read['ok'], optional_read
    launcher = shared/'RuntimeArgs.ps1'
    launcher.write_text("& (Join-Path $PSScriptRoot 'Get-HwpxRuntime.ps1') | ConvertTo-Json -Depth 8", encoding='utf-8-sig')
    ps_runtime = run(shared,'RuntimeArgs.ps1')
    assert ps_runtime['Arguments'] == client.server_parameters().args
    assert str(fixture/'missing-incoming') not in ps_runtime['Arguments']
    missing_denied = False
    try:
        asyncio.run(asyncio.wait_for(read_source(client.server_parameters(), fixture/'missing-incoming/needed.hwpx'), 30))
    except Exception as error:
        missing_denied = 'WORKSPACE_OUTSIDE_ROOT' in error_text(error)
    assert missing_denied
    # A natural request uses intake, a completed draft, and one publication.
    intake = run(shared,'Start-HwpxWork.ps1','-Mode','New','-TaskTitle','Path resume',
                 '-WorkFolderName','23_Path resume','-JobSlug','path-resume',
                 '-RequestText','Create one attendance CSV','-RequestId','path-one',
                 '-IntakeSummary','Create one attendance CSV','-DecisionReason','Synthetic request','-Summary')
    job = Path(intake['jobPath']); work = Path(intake['workRoot']); draft = job/'wip/docs/result.csv'
    draft.write_text('item,hours\nsynthetic,15\n', encoding='utf-8')
    # Array arguments are passed through a tiny PS wrapper to preserve PS 5.1 binding.
    wrapper = shared/'Ready.ps1'
    wrapper.write_text("param($Job,$Draft)\n& (Join-Path $PSScriptRoot 'Complete-HumanDraft.ps1') -JobPath $Job -SourceFile $Draft -TargetRelativePath result.csv -Stage Final -ChecksCompleted @('content','integrity')", encoding='utf-8-sig')
    run(shared,'Ready.ps1','-Job',job,'-Draft',draft)
    pub_args = ('-Stage','Final','-TaskTitle','Path resume','-WorkFolderName','23_Path resume',
                '-SourceFile',draft,'-TargetRelativePath','result.csv','-Summary')
    first = run(shared,'Publish-HumanResult.ps1',*pub_args)
    current = work/'result.csv'; current_hash = sha(current)
    # Move the selected cabinet, explicitly bind config to that requested destination.
    moved = fixture/'moved-cabinet'; cabinet.rename(moved)
    run(shared,'Set-HumanCabinetRoot.ps1','-CabinetRoot',moved,'-ExpectedPreviousRoot',cabinet,'-Apply')
    new_job = moved/job.relative_to(cabinet); new_draft = new_job/'wip/docs/result.csv'
    resumed = run(shared,'Start-HwpxWork.ps1','-Mode','FollowUp','-TaskTitle','Path resume',
                 '-WorkFolderName','23_Path resume','-JobPath',new_job,
                 '-RequestText','Create one attendance CSV','-RequestId','path-one',
                 '-IntakeSummary','Create one attendance CSV','-DecisionReason','Resume selected cabinet','-Summary')
    assert resumed['deliveryCycleId'] == intake['deliveryCycleId']
    # Ready receipts intentionally bind absolute source/check paths. Revalidate the
    # same successful bytes at the new path rather than rewriting historical evidence.
    run(shared,'Ready.ps1','-Job',new_job,'-Draft',new_draft)
    retry_args = list(pub_args); retry_args[retry_args.index(draft)] = new_draft
    retry = run(shared,'Publish-HumanResult.ps1',*retry_args)
    metadata = json.loads((moved/'23_Path resume/.ai/work.json').read_text(encoding='utf-8-sig'))
    assert retry['idempotentRetry'] and len(metadata['publishedDeliveries']) == 1
    assert sha(moved/'23_Path resume/result.csv') == current_hash
    assert before == sha(moved/'source.hwpx')
    # Outside storage and an unavailable selected cabinet still fail closed.
    outside_job = fixture/'outside/.ai/jobs/20261002-outside'; outside_job.mkdir(parents=True)
    outside = run(shared,'Ready.ps1','-Job',outside_job,'-Draft',new_draft,ok=False)
    assert 'outside the selected work storage' in outside
    unavailable = fixture/'unavailable-cabinet'; moved.rename(unavailable)
    absent = run(shared,'Start-HwpxWork.ps1','-Mode','FollowUp','-TaskTitle','Path resume',
                 '-WorkFolderName','23_Path resume','-JobPath',new_job,
                 '-IntakeSummary','Resume current file','-DecisionReason','Synthetic request',ok=False)
    assert 'No registered work matches' in absent and not moved.exists()
    assert sha(unavailable/'23_Path resume/result.csv') == current_hash
    result = {'scenario':10, 'request':'Move the work folder and resume; incoming path is unavailable',
              'optionalCurrentRead':optional_read, 'relocationRetryReused':True,
              'publishedCount':1, 'sourcePreserved':True, 'outsideStorageRejected':True,
              'completionRevalidatedAfterMove':True,
              'missingRequiredInputRejected':True, 'launcherRootParity':True,
              'missingSelectedCabinetRejected':True,
              'fixture':str(fixture), 'metrics':metrics, 'retryCount':0}
    save(fixture/'result.json',result)
    print(json.dumps({'resultPath':str(fixture/'result.json'), **result}, ensure_ascii=False))

if __name__ == '__main__':
    main()
