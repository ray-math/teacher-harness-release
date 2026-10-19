"""Native concatenation worker. Invoked by Invoke-HancomMerge.ps1, not by the model directly."""
import hashlib,json,re,sys,time,uuid
from pathlib import Path
import win32com.client

def sha(p): return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p): return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def save(p,data):
    tmp=p.with_suffix('.tmp');tmp.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8');tmp.replace(p)
def compact(s): return re.sub(r'\s+','',s)

manifest=Path(sys.argv[1]).resolve(); plan=read(manifest)
job=manifest.parent; inputs=plan['inputs']; output=Path(plan['output']).resolve()
if plan.get('renderPdf',False):
    sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
    from document_scope import assert_scope
    assert_scope(job,'visual_review')
assert len(inputs)>=2,'Need a base and append inputs'
assert output.is_relative_to(job) and output.suffix.lower()=='.hwpx','Output must be a job-owned HWPX'
assert not output.exists(),'Output exists: use verified receipt or select a new destination'
assert len({str(Path(x['path']).resolve()).casefold() for x in inputs})==len(inputs),'Duplicate input'
for x in inputs:
    p=Path(x['path']).resolve()
    assert p.is_relative_to(job) and p.suffix.lower() in ('.hwp','.hwpx'),'Use selected job-owned document copies'
    assert sha(p)==x['sha256'].lower(),'Input hash mismatch'
receipt=job/'wip'/'receipts'/('native-'+time.strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:8]+'.json')
receipt.parent.mkdir(parents=True,exist_ok=True);output.parent.mkdir(parents=True,exist_ok=True)
t=time.perf_counter();h=None
state=dict(ok=False,stage='activation',manifestSha256=sha(manifest),output=str(output),inputs=inputs,insertions=[],receipt=str(receipt),verification={},error=None)
def checkpoint(stage):
    state['stage']=stage;state['seconds']=round(time.perf_counter()-t,3);save(receipt,state)
checkpoint('activation')
try:
    # This workspace uses the registered 32-bit Hancom local server from 64-bit Python.
    h=win32com.client.DispatchEx('HWPFrame.HwpObject', clsctx=4 | 0x40000)
    state['hancomVersion']=h.Version
    if not h.RegisterModule('FilePathCheckDLL','HwpxWorkspaceOfficial'):raise RuntimeError('security_module_unavailable: run installation health check; do not repeat document attempts')
    state['securityModuleRegistered']=True
    h.XHwpWindows.Item(0).Visible=False
    texts=[]
    for i,x in enumerate(inputs):
        checkpoint('reading-input-'+str(i))
        if not h.Open(x['path'],'',''): raise RuntimeError('Input open failed: '+str(i))
        text=compact(h.GetTextFile('TEXT',''))
        if not text:raise RuntimeError('Empty extracted input: '+str(i))
        texts.append(text);h.Clear(1)
    checkpoint('opening-base')
    if not h.Open(inputs[0]['path'],'',''):raise RuntimeError('Base open failed')
    for i,x in enumerate(inputs[1:],1):
        checkpoint('inserting-'+str(i))
        if not h.HAction.Run('MoveDocEnd'):raise RuntimeError('MoveDocEnd failed')
        opt=h.HParameterSet.HInsertFile
        h.HAction.GetDefault('InsertFile',opt.HSet)
        opt.FileName=x['path'];opt.KeepSection=1;opt.KeepCharshape=1;opt.KeepParashape=1;opt.KeepStyle=1
        if not h.HAction.Execute('InsertFile',opt.HSet):raise RuntimeError('InsertFile failed: '+str(i))
        state['insertions'].append(i)
    # Native PDF export also exercises Hancom pagination, without altering formatting preferences.
    if plan.get('renderPdf',False):
        assert_scope(job,'visual_review')
        checkpoint('native-pdf')
        pdf=output.with_suffix('.pdf')
        if pdf.exists():raise RuntimeError('PDF destination already exists')
        if not h.SaveAs(str(pdf),'PDF',''):raise RuntimeError('Native PDF export failed')
        state['pdf']=str(pdf)
    checkpoint('saving')
    if not h.SaveAs(str(output),'HWPX',''):raise RuntimeError('Save failed')
    h.Clear(1)
    checkpoint('reopening')
    if not h.Open(str(output),'HWPX',''):raise RuntimeError('Saved output reopen failed')
    merged=compact(h.GetTextFile('TEXT',''));h.Clear(1)
    cursor=0;checks=[]
    for i,source in enumerate(texts):
        pos=merged.find(source,cursor);checks.append(dict(index=i,foundInOrder=pos>=0,characters=len(source)))
        if pos<0:raise RuntimeError('Full input text missing or out of order: '+str(i))
        cursor=pos+len(source)
    state['verification']=dict(nativeReopen=True,fullTextInOrder=checks,inputHashesUnchanged=all(sha(x['path'])==x['sha256'].lower() for x in inputs),visualReview=False)
    if not state['verification']['inputHashesUnchanged']:raise RuntimeError('Source modified')
    state['outputSha256']=sha(output)
    from verify_package import verify
    safety=verify(output);state['verification']['openSafety']=safety
    state['ok']=bool(safety['ok'])
    checkpoint('verified' if state['ok'] else 'blocked-open-safety')
except Exception as exc:
    state['error']=str(exc);state['failedAt']=state['stage'];checkpoint('failed')
finally:
    if h is not None:
        try:h.Clear(1);h.Quit()
        except Exception as exc:state['cleanupError']=str(exc)
    state['seconds']=round(time.perf_counter()-t,3);save(receipt,state)
print(json.dumps({k:state.get(k) for k in ('ok','stage','seconds','receipt','output','error')},ensure_ascii=False))
sys.exit(0 if state['ok'] else 2)
