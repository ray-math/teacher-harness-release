"""Convert an ordered list of selected document paths into a verified merge manifest."""
import argparse,json,hashlib,shutil,sys
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from work_storage import resolve_job

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser();p.add_argument('--job',required=True);p.add_argument('--inputs',required=True);p.add_argument('--name',default='merged.hwpx');a=p.parse_args()
    workspace=Path(__file__).resolve().parents[3];job=resolve_job(workspace,a.job)
    if Path(a.name).name!=a.name or not a.name.lower().endswith('.hwpx'):raise ValueError('Output name must be a HWPX filename')
    values=json.loads(Path(a.inputs).read_text(encoding='utf-8-sig'))
    if not isinstance(values,list) or len(values)<2:raise ValueError('Input list must contain base first, then append files')
    paths=[Path(x).resolve(strict=True) for x in values]
    if len({str(x).casefold() for x in paths})!=len(paths):raise ValueError('Duplicate input path')
    if any(x.suffix.lower() not in ('.hwp','.hwpx') for x in paths):raise ValueError('Only selected HWP/HWPX files are supported')
    manifest=job/'native-plan.json'
    if manifest.exists():raise ValueError('Manifest exists; reuse it or create a new job revision')
    records=[]
    for i,path in enumerate(paths):
        digest=sha(path);copy=job/'sources'/('native-'+digest[:16])/(str(i).zfill(3)+path.suffix.lower())
        copy.parent.mkdir(parents=True,exist_ok=True)
        if not copy.exists():shutil.copy2(path,copy)
        if sha(copy)!=digest or sha(path)!=digest:raise ValueError('Input changed while preserving copy')
        records.append(dict(path=str(copy),sha256=digest,sourcePath=str(path)))
    data=dict(inputs=records,output=str(job/'wip'/a.name),renderPdf=False)
    manifest.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(dict(ok=True,manifest=str(manifest),inputs=len(records)),ensure_ascii=False))
if __name__=='__main__':main()
