"""Synthetic integration checks; no school documents or Hancom UI."""
import asyncio
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

from hwpx import HwpxDocument
from hwpx_read_client import ROOT, read_batch

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(script, *args, ok=True):
    result = subprocess.run(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT / '.agent/shared' / script),*map(str,args)], capture_output=True, encoding='utf-8', errors='replace', timeout=90)
    if (result.returncode == 0) != ok:
        raise AssertionError(result.stdout + result.stderr)
    return result

async def reads(source):
    results = await read_batch([
        {'tool':'mcp_server_health'},
        {'tool':'get_document_text','arguments':{'filename':str(source)}},
        {'tool':'get_table_text','arguments':{'filename':str(source)}}])
    encoded = json.dumps(results, ensure_ascii=False)
    assert 'ORIGINAL_BODY' in encoded and 'UNCHANGED_CELL' in encoded, encoded
    try:
        await read_batch([{'tool':'search_and_replace','arguments':{}}])
    except ValueError:
        pass
    else:
        raise AssertionError('Write request was accepted')

def main():
    job = ROOT / '.agent/jobs' / ('20260908-runtime-test-' + uuid.uuid4().hex[:8])
    job.mkdir(parents=True)
    (job/'inputs.json').write_text('{}', encoding='utf-8')
    source = job / "한글 경로 O'Brien 입력.hwpx"
    doc = HwpxDocument.new()
    doc.add_paragraph('ORIGINAL_BODY')
    table = doc.add_table(1,1)
    table.set_cell_text(0,0,'UNCHANGED_CELL')
    doc.save_to_path(str(source))
    before = digest(source)
    started=time.perf_counter()
    asyncio.run(asyncio.wait_for(reads(source),60))
    read_seconds=time.perf_counter()-started
    request=job/'reads.json'
    request.write_text(json.dumps([{'tool':'get_document_text','arguments':{'filename':str(source)}}]),encoding='utf-8')
    result_path=job/'read-result.json'
    run('Invoke-HwpxRead.ps1','-RequestPath',request,'-OutputPath',result_path)
    run('Invoke-HwpxRead.ps1','-RequestPath',request,'-OutputPath',result_path,ok=False)
    output=job/'wip/result.hwpx'
    plan=job/'plan.json'
    plan.write_text(json.dumps({'schemaVersion':'hwpx.edit-plan/v1','source':str(source),'output':str(output),'steps':[{'id':'body','op':'apply_body_ops','args':{'ops':[{'op':'replace_text','find':'ORIGINAL_BODY','replace':'UPDATED_BODY','count':1}]}}]}),encoding='utf-8')
    args=['-JobPath',job,'-PlanPath',plan,'-SourceSha256',before]
    run('Invoke-HwpxEditPlan.ps1',*args,'-DryRun')
    assert not output.exists()
    run('Invoke-HwpxEditPlan.ps1',*args)
    result_hash=digest(output)
    run('Invoke-HwpxEditPlan.ps1',*args)
    assert digest(output)==result_hash and digest(source)==before
    edited=asyncio.run(asyncio.wait_for(read_batch([{'tool':'get_document_text','arguments':{'filename':str(output)}},{'tool':'get_table_text','arguments':{'filename':str(output)}}]),60))
    text=json.dumps(edited,ensure_ascii=False)
    assert 'UPDATED_BODY' in text and 'UNCHANGED_CELL' in text and 'ORIGINAL_BODY' not in text
    run('Invoke-HwpxEditPlan.ps1','-JobPath',job,'-PlanPath',plan,'-SourceSha256','0'*64,'-DryRun',ok=False)
    receipt={'ok':True,'checks':['MCP initialize and health','Unicode, space and apostrophe path read','body and table batch','read-only write rejection','read output preservation','edit dry-run','edit commit and reopen','unchanged source and table','identical commit reuse','wrong source hash rejected'],'readBatchSeconds':round(read_seconds,3),'syntheticJob':str(job),'sourceSha256':before,'outputSha256':result_hash}
    archive=ROOT/'.agent/archive/2026/20260908-hwpx-native-runtime'
    archived_job=(archive/job.name).resolve()
    assert job.resolve().parent==ROOT/'.agent/jobs' and archived_job.parent==archive
    assert not archived_job.exists()
    job.rename(archived_job)
    receipt['syntheticJobOriginalPath']=receipt.pop('syntheticJob')
    receipt['syntheticArtifacts']=str(archived_job)
    target=archive/('verification-'+job.name+'.json')
    target.write_text(json.dumps(receipt,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(receipt,ensure_ascii=False))

if __name__=='__main__':
    main()
