"""Bounded launcher with per-job lock and hash-bound receipt reuse."""
import argparse,hashlib,json,os,subprocess,sys,time,winreg
from pathlib import Path
from importlib.metadata import version

def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser();parser.add_argument('manifest');parser.add_argument('--timeout',type=int,default=120)
    a=parser.parse_args();m=Path(a.manifest).resolve();j=m.parent;p=read(m)
    if p.get('renderPdf',False):
        sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
        from document_scope import assert_scope
        assert_scope(j,'visual_review')
    if not 10<=a.timeout<=600:raise ValueError('Timeout must be 10..600 seconds')
    tools=Path(__file__).parent
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,r'Software\HNC\HwpAutomation\Modules') as registry:
            module_path=winreg.QueryValueEx(registry,'HwpxWorkspaceOfficial')[0]
        module_state=module_path+':'+sha(Path(module_path))
    except OSError:
        module_state='unavailable-in-current-execution-context'
    key=hashlib.sha256((sha(m)+''.join(sha(tools/n) for n in ['merge_worker.py','verify_package.py'])+version('python-hwpx')+version('python-hwpx-automation')+module_state).encode()).hexdigest()
    for x in p['inputs']:
        path=Path(x['path']).resolve()
        if not path.is_relative_to(j) or sha(path)!=x['sha256'].lower():raise ValueError('Input outside job or changed')
    records=j/'wip'/'receipts';records.mkdir(parents=True,exist_ok=True)
    cache=records/('run-'+key+'.json');lock=j/'wip'/'native-merge.lock'
    if cache.exists():
        prior=read(cache)
        if prior['ok']:
            r=read(Path(prior['receipt']))
            if sha(Path(r['output']))!=r['outputSha256']:raise ValueError('Prior output changed; use a new output manifest')
        prior['reused']=True;print(json.dumps(prior,ensure_ascii=False));return 0 if prior['ok'] else 2
    fd=os.open(lock,os.O_CREAT|os.O_EXCL|os.O_WRONLY)
    os.write(fd,json.dumps({'startedAt':time.time(),'launcherPid':os.getpid(),'manifest':str(m)}).encode());os.close(fd)
    keep_lock=False;started=time.perf_counter()
    try:
        proc=subprocess.Popen([sys.executable,str(tools/'merge_worker.py'),str(m)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8',env={**os.environ,'PYTHONIOENCODING':'utf-8'})
        try:out,err=proc.communicate(timeout=a.timeout)
        except subprocess.TimeoutExpired:
            proc.terminate();out,err=proc.communicate(timeout=10);keep_lock=True
            result=dict(ok=False,stage='timeout',seconds=round(time.perf_counter()-started,3),lock=str(lock),action='Inspect the last native receipt and worker-owned Hancom state before clearing the lock; do not repeat')
        else:
            try: result=json.loads(out.strip().splitlines()[-1])
            except (ValueError,IndexError):result=dict(ok=False,stage='worker-failed',error=err[-2000:])
        result['runKey']=key;cache.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps(result,ensure_ascii=False));return 0 if result['ok'] else 2
    finally:
        if not keep_lock:lock.unlink(missing_ok=True)
if __name__=='__main__':sys.exit(main())
