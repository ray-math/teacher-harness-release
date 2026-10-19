"""Synthetic author/edit/export/native-preview regression; all exits must be zero."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
BUILDER = r'''
import {FileBlob, SpreadsheetFile, Workbook} from '@oai/artifact-tool';
const [mode, source, output] = process.argv.slice(2);
const w = mode === 'create' ? Workbook.create() : await SpreadsheetFile.importXlsx(await FileBlob.load(source));
if (mode === 'create') {
 const s = w.worksheets.add('Roster');
 s.getRange('A1:C5').values = [['ID','Name','Count'],['S01','Synthetic A',3],['S02','Synthetic B',4],['S03','Synthetic C',5],['Total','',null]];
 s.getRange('C5').formulas = [['=SUM(C2:C4)']];
 s.getRange('A1:C5').format.font = {name:'Arial',size:11};
 s.getRange('A1:C5').format.columnWidth = 20;
 w.worksheets.add('Other').getRange('A1:B2').values = [['Preserved',42],['Period','2026 S2']];
} else w.worksheets.getItem('Roster').getRange('C3').values = [[7]];
w.recalculate();
await (await SpreadsheetFile.exportXlsx(w)).save(output);
console.log(JSON.stringify({values:w.worksheets.getItem('Roster').getRange('C3:C5').values}));
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        return {name: archive.read(name) for name in archive.namelist()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--node', type=Path, required=True)
    parser.add_argument('--node-modules', type=Path, required=True)
    args = parser.parse_args()
    fixture = Path(tempfile.mkdtemp(prefix='xlsx-preview-runtime-'))
    # A junction in TEMP uses the bundled dependencies without changing them.
    link = fixture / 'node_modules'
    quote = lambda value: "'" + str(value).replace("'", "''") + "'"
    subprocess.run(['powershell','-NoProfile','-Command',
        'New-Item -ItemType Junction -Path ' + quote(link) + ' -Target ' + quote(args.node_modules) + ' | Out-Null'],
        check=True, capture_output=True)
    builder = fixture / 'workbook.mjs'
    builder.write_text(BUILDER, encoding='utf-8')
    metrics = []
    def run(label, command, success=True):
        result = subprocess.run(list(map(str, command)), capture_output=True, timeout=90,
            env={**os.environ, 'PSModulePath': str(Path(os.environ['SystemRoot'])/'System32/WindowsPowerShell/v1.0/Modules')})
        metrics.append({'step':label, 'exitCode':result.returncode})
        assert (result.returncode == 0) == success, (label, result.stdout, result.stderr)
        # Artifact export emits an inspection-path notice before the final receipt.
        return json.loads(result.stdout.decode('utf-8-sig').strip().splitlines()[-1])
    source = fixture / 'source.xlsx'
    output = fixture / 'edited.xlsx'
    created = run('create', [args.node,builder,'create','unused',source])
    before = digest(source)
    edited = run('edit', [args.node,builder,'edit',source,output])
    assert created['values'] == [[4],[5],[12]] and edited['values'] == [[7],[5],[15]]
    assert digest(source) == before
    old, new = package(source), package(output)
    assert old['xl/styles.xml'] == new['xl/styles.xml']
    assert old['xl/worksheets/sheet2.xml'] == new['xl/worksheets/sheet2.xml']
    namespace = {'s':'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
    def cells(data):
        return {c.attrib['r']: ET.tostring(c) for c in ET.fromstring(data).findall('.//s:c',namespace)}
    a,b = cells(old['xl/worksheets/sheet1.xml']),cells(new['xl/worksheets/sheet1.xml'])
    assert {key for key in a.keys() | b.keys() if a.get(key) != b.get(key)} == {'C3','C5'}
    pdf = fixture / 'preview.pdf'
    command = ['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',
        ROOT/'.agent/shared/Export-XlsxPreview.ps1','-SourceFile',output,
        '-OutputPdf',pdf,'-SheetName','Roster','-RangeAddress','A1:C5']
    preview = run('native-preview', command)
    assert preview['status'] == 'passed' and preview['sourceUnchanged'] and preview['excelExited']
    from pypdf import PdfReader
    document = PdfReader(pdf)
    assert len(document.pages) > 0 and 'Synthetic B' in ''.join(page.extract_text() for page in document.pages)
    rendered = subprocess.run(['pdftoppm','-singlefile','-png','-f','1','-l','1',str(pdf),str(fixture/'preview')],
        capture_output=True, timeout=60)
    assert rendered.returncode == 0, rendered.stderr
    metrics.append({'step':'pdf-to-png','exitCode':rendered.returncode})
    from PIL import Image
    with Image.open(fixture/'preview.png') as image:
        image.verify()
    pdf_hash = digest(pdf)
    rejected = run('existing-preview-rejected', command, success=False)
    assert 'already exists' in rejected['error'] and digest(pdf) == pdf_hash
    result = {'ok':True,'fixture':str(fixture),'measurements':metrics,
        'checks':['create/edit exit zero','input preserved','C3 4 to 7 and total 12 to 15',
        'formulas, styles, other sheet preserved','read-only native PDF and text verified',
        'owned Excel exited','existing preview preserved'],'nativePreview':preview}
    (fixture/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False))


if __name__ == '__main__':
    main()
