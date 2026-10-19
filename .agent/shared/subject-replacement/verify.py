"""Fail-closed publication lineage for native subject replacement.

Reads HWPX XML only. It never mutates packages, invokes job code or relaxes the
existing content-only/whole-document merge gates.
"""
import json,re,hashlib,sys,copy
from pathlib import Path
from zipfile import ZipFile
from lxml import etree as E
# Existing verified 6.3.0 inline-control counting compatibility; it changes no file
# bytes, retains the unmodified upstream report and runs every other check as-is.
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'hancom-native'))
from verify_package import verify as verify_package

def read(p):return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def check_hash(p,h):assert sha(p)==h.lower(),f'Revision changed: {p}'
def norm(t):return re.sub(r'\s+','',t or '')
def ln(e):return E.QName(e).localname
def table(t):
 rows=[]
 for tr in t:
  if ln(tr)!='tr':continue
  cells=[]
  for tc in tr:
   if ln(tc)!='tc':continue
   props={ln(c):dict(c.attrib) for c in tc if ln(c) in ['cellAddr','cellSpan','cellSz','cellMargin']}
   cells.append({'properties':props,'text':norm(''.join(x.text or '' for x in tc.iter() if ln(x)=='t'))})
  rows.append(cells)
 return {'rowCnt':t.get('rowCnt'),'colCnt':t.get('colCnt'),'rows':rows}
def blocks(path):
 out=[];cur=None
 with ZipFile(path) as z:
  for sec in sorted((n for n in z.namelist() if re.fullmatch(r'Contents/section\d+\.xml',n)),key=lambda s:int(re.search(r'(\d+)\.xml',s).group(1))):
   for p in E.fromstring(z.read(sec)):
    title=norm(''.join(x.text or '' for run in p if ln(run)=='run' for t in run if ln(t)=='t' for x in t.iter()))
    if re.search(r'(?<!\d)\d{4}학년도.*학년.*계획서',title):cur={'title':title,'tables':[]};out.append(cur)
    if cur is not None:cur['tables'].extend(table(t) for t in p.iter() if ln(t)=='tbl')
 return out
def within(p,root):
 p=Path(p).resolve();assert p.is_relative_to(root.resolve()),f'Path outside work: {p}';return p
def validate_table_lineage(expected,actual,edits):
 expected=copy.deepcopy(expected)
 for edit in edits:
  assert set(edit)=={'table','row','cell','before','after','authorization'},'Unsupported edit shape'
  assert edit['authorization'].strip(),'Missing explicit user decision'
  cell=expected[edit['table']]['rows'][edit['row']][edit['cell']]
  assert cell['text']==norm(edit['before']),'Unexpected pre-edit cell'
  cell['text']=norm(edit['after'])
 assert expected==actual,'Table text, geometry, cell topology or order changed outside the replacement contract'

def verify(job,manifest_path,sources):
 job=Path(job).resolve();manifest_path=within(manifest_path,job/'wip/receipts');m=read(manifest_path)
 assert m['schemaVersion']=='hwpx.subject-replacement-publication/v1'
 assert m['authorization'].strip(),'Missing user replacement instruction'
 rp=within(m['nativeReceipt']['path'],job/'wip/receipts');check_hash(rp,m['nativeReceipt']['sha256']);r=read(rp)
 assert r['schemaVersion']=='hwpx.subject-replacement/v1' and r['ok'] and r['inputsUnchanged'] and r['securityModuleRegistered']
 worker=within(m['worker'],job);check_hash(worker,r['workerSha256'])
 intake=read(job/'inputs.json')['sources'];input_by_copy={}
 for x in r['inputs']:
  cp=within(x['copy'],job);check_hash(cp,x['sha256']);check_hash(x['source'],x['sha256'])
  matches=[a for a in intake if Path(a['path']).resolve()==Path(x['source']).resolve() and a['sha256'].lower()==x['sha256'].lower() and a.get('userProvided') is True]
  assert matches,'Source not preserved through intake'
  input_by_copy[str(cp)]=(x,matches)
 assert len(m['files'])==len(r['grades'])==len(sources)>0,'Incomplete grade set'
 assert len(set(x['grade'] for x in m['files']))==len(m['files']),'Duplicate grade'
 assert {Path(x).resolve() for x in sources}=={Path(x['output']).resolve() for x in m['files']},'Requested output set differs'
 checks=[];safety_checks=[]
 for f in m['files']:
  g=next(x for x in r['grades'] if x['grade']==f['grade'])
  assert g['nativeReopen'] and g['fullTextExact'] and g['expectedCharacters']==g['actualCharacters']>0
  base=within(g['base'],job);assert str(base) in input_by_copy
  assert any(a['role']=='human_revision' for a in input_by_copy[str(base)][1]),'Base is not current human revision'
  native=within(g['output'],job/'wip/docs');check_hash(native,g['outputSha256'])
  output=within(f['output'],job/'wip/docs');check_hash(output,f['outputSha256'])
  evidence=f['nativeTextEvidence'];ep=within(evidence['path'],job/'wip/receipts');check_hash(ep,evidence['sha256']);ev=read(ep)
  assert ev['expected']==ev['actual'] and len(ev['actual'])==g['actualCharacters'],'Native full-text evidence mismatch'
  if f.get('patchReceipt'):
   pr=f['patchReceipt'];pp=within(pr['path'],job/'wip/receipts');check_hash(pp,pr['sha256']);patch=read(pp)
   assert patch['ok'] and patch['nativeReopen'] and patch['authorization'].strip()
   assert patch['inputSha256']==g['outputSha256'] and patch['outputSha256']==f['outputSha256']
   assert Path(patch['input']).resolve()==native and Path(patch['output']).resolve()==output
  else:assert f['outputSha256']==g['outputSha256'] and not f.get('cellEdits'),'Unverified output or edits'
  old=blocks(base);new=blocks(output);assert old and [a['title'] for a in old]==[a['title'] for a in new],'Subject title/order changed'
  replacement_terms={x['subject'] for x in g['replacements']}
  assert replacement_terms=={x['subject'] for x in f['sourceForms']},'Replacement source set differs'
  used=set()
  for a,b in zip(old,new):
   hits=[s for s in replacement_terms if s in a['title']];assert len(hits)<=1,'Ambiguous subject'
   term=hits[0] if hits else None;edits=[]
   if term:
    assert term not in used;used.add(term)
    form=next(x for x in f['sourceForms'] if x['subject']==term);cp=within(form['normalized'],job/'wip/docs');check_hash(cp,form['normalizedSha256'])
    orig=next(x for x in g['replacements'] if x['subject']==term);check_hash(orig['source'],orig['sourceSha256'])
    assert str(Path(orig['source']).resolve()) in input_by_copy
    nr=read(form['normalizationReceipt']);matches=[x for x in nr['items'] if Path(x['sourcePath']).resolve()==Path(input_by_copy[str(Path(orig['source']).resolve())][0]['source']).resolve() and x['sourceSha256'].lower()==orig['sourceSha256'].lower() and x['outputSha256'].lower()==form['normalizedSha256'].lower() and x['status']=='ready']
    assert matches,'Normalized form is not anchored to received source'
    expected=blocks(cp);assert len(expected)==1 and expected[0]['title']==a['title'],'Wrong subject source form'
    expected=expected[0]
    edits=[x['edit'] for x in f.get('cellEdits',[]) if x['subject']==term]
   else:expected=a
   validate_table_lineage(expected['tables'],b['tables'],edits)
   checks.append({'grade':g['grade'],'title':a['title'],'tableCount':len(b['tables']),'receivedReplacement':bool(term),'tablesExactExceptAuthorizedCells':True})
  assert used==replacement_terms and all(x['subject'] in used for x in f.get('cellEdits',[]))
  safety=verify_package(str(output));assert safety['ok'],f'Open-safety failed: {safety}'
  safety_checks.append({'grade':g['grade'],'report':safety})
 return {'schemaVersion':'hwpx-publish-form-gate/v1','ok':True,'route':'native_subject_replacement','receipt':str(manifest_path),'verificationLevel':'native_reopen_exact_full_text_subject_order_table_cells_geometry_and_package_safety','realHancomVerified':False,'nativeReopen':True,'visualReview':False,'checks':checks,'openSafety':safety_checks}

if __name__=='__main__':
 q=read(sys.argv[1]);print(json.dumps(verify(q['job'],q['receipt'],q['sources']),ensure_ascii=False))
