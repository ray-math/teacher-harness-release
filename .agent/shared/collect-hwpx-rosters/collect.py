"""Collect populated subject rows into an existing HWPX form, with roster checks.

All Hanword access uses public automation operations. No ZIP/XML authoring.
The JSON request is job-specific; this module contains no school/student facts.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from read_complete_cells import complete_map


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(temp, path)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def norm(value):
    return re.sub(r'\s+', '', value)


def table_data(document_map, headers):
    found = []
    for table in document_map['tables']['tables']:
        cells = {(c['row'], c['col']): c['text'].strip() for c in table['cells']}
        header_cells = {norm(text): col for (row, col), text in cells.items() if row == 0}
        if all(norm(text) in header_cells for text in headers.values()):
            found.append((table, cells, {key: header_cells[norm(text)] for key, text in headers.items()}))
    if len(found) != 1:
        raise ValueError('Expected exactly one matching roster table; inspect the selected document')
    return found[0]


def match_records(raw, roster):
    by_id = {r['id']: r for r in roster}
    if len(by_id) != len(roster):
        raise ValueError('Duplicate authority roster IDs')
    by_name = defaultdict(list)
    for entry in roster:
        by_name[entry['name']].append(entry)
    pattern = r'(?:(\d{4,6})\s*)?([가-힣]{2,5})'
    if re.sub(pattern, '', raw).strip(' ,\r\n\t;、'):
        raise ValueError('Unparsed roster text; preserve input and inspect')
    records = []
    for supplied, name in re.findall(pattern, raw):
        if supplied and supplied in by_id and by_id[supplied]['name'] == name:
            student_id, status = supplied, '일치'
        elif not supplied and len(by_name[name]) == 1:
            student_id, status = by_name[name][0]['id'], '학번 보완'
        else:
            # Never silently replace a submitted conflicting ID.
            raise ValueError('ID/name conflict or ambiguous authority match; see local source')
        records.append(dict(id=student_id, name=name, sourceId=supplied, status=status))
    if not records:
        raise ValueError('No parseable students in a nonempty submission')
    if len({r['id'] for r in records}) != len(records):
        raise ValueError('Duplicate student within one subject')
    return sorted(records, key=lambda r: int(r['id']))


def source_diff(maps, config):
    """Align one common form, keep common cells once, and group differing cells.

    A frequent value is not an authority. A nonempty student cell identifies the
    submitting subject row; differing defaults in other rows are not its edits.
    """
    aliases = config.get('subjectAliases', {})
    expected = config['subjects']
    documents = []
    for source, document_map in maps:
        table, cells, cols = table_data(document_map, config['headers'])
        subjects = [aliases.get(cells.get((r, cols['subject']), ''), cells.get((r, cols['subject']), ''))
                    for r in range(1, table['rows'])]
        if subjects != expected:
            raise ValueError('Source rows differ from the common form; map structure before merging')
        documents.append(dict(source=str(source), table=table, cells=cells, cols=cols))
    if not documents:
        raise ValueError('No submitted documents')
    first = documents[0]
    shape = (first['table']['rows'], first['table']['cols'], set(first['cells']), first['cols'])
    for doc in documents[1:]:
        if (doc['table']['rows'], doc['table']['cols'], set(doc['cells']), doc['cols']) != shape:
            raise ValueError('Source table structure differs; coordinate diff is unsafe')
    common, differences = [], []
    fields = {col: field for field, col in first['cols'].items()}
    for row, col in sorted(first['cells']):
        variants = {}
        for doc in documents:
            value = doc['cells'][row, col]
            key = aliases.get(value, value) if row and col == first['cols']['subject'] else value
            key = norm(key)
            variant = variants.setdefault(key, dict(value=value, sources=[]))
            variant['sources'].append(doc['source'])
        cell = dict(row=row, col=col, field=fields.get(col, 'unmapped'))
        if len(variants) == 1:
            common.append(dict(**cell, value=next(iter(variants.values()))['value']))
        else:
            differences.append(dict(**cell, variants=list(variants.values())))
    submissions = []
    unowned_differences = []
    for doc in documents:
        active_rows = set()
        for row, subject in enumerate(expected, 1):
            raw = doc['cells'][row, doc['cols']['students']]
            if not raw.strip():
                continue
            active_rows.add(row)
            submissions.append(dict(subject=subject, source=doc['source'], sourceRow=row,
                                    sourceLabel=doc['cells'][row, doc['cols']['subject']],
                                    teacher=doc['cells'][row, doc['cols']['teacher']],
                                    criteria=doc['cells'][row, doc['cols']['criteria']], students=raw))
        for cell in differences:
            if cell['row'] and cell['row'] not in active_rows and cell['field'] not in ('subject', 'students'):
                value = doc['cells'][cell['row'], cell['col']]
                if value:
                    unowned_differences.append(dict(source=doc['source'], row=cell['row'],
                                                   field=cell['field'], value=value,
                                                   decision='not adopted: this source did not submit this subject row'))
    return dict(schemaVersion='hwpx-roster-source-diff/v1', sourceCount=len(documents),
                rowCount=shape[0], columnCount=shape[1], commonCells=common,
                differingCells=differences, submissions=submissions,
                unownedDifferences=unowned_differences)


def collect_diff(diff, roster, config):
    expected = config['subjects']
    selected = {}
    for submission in diff['submissions']:
        raw, subject = submission['students'], submission['subject']
        is_none = norm(raw) in {norm(x) for x in config.get('noneMarkers', ['없음'])}
        records = [] if is_none else match_records(raw, roster)
        value = {k: v for k, v in submission.items() if k != 'students'}
        value.update(records=records, status='명시적 없음' if is_none else '명단 있음')
        if subject in selected:
            raise ValueError('Multiple populated submissions for one subject; choose authority explicitly')
        selected[subject] = value
    missing = [s for s in expected if s not in selected]
    if missing:
        raise ValueError('Missing subject submissions: ' + ', '.join(missing))
    return [selected[s] for s in expected]


def collect(maps, roster, config):
    return collect_diff(source_diff(maps, config), roster, config)


def merge_diff(base_map, subjects, config):
    table, base_cells, cols = table_data(base_map, config['headers'])
    aliases = config.get('subjectAliases', {})
    targets = {}
    for row in range(1, table['rows']):
        label = base_cells.get((row, cols['subject']), '')
        subject = aliases.get(label, label)
        if subject in targets:
            raise ValueError('Ambiguous duplicate subject in base form')
        targets[subject] = row
    changes = []
    for subject in subjects:
        if subject['subject'] not in targets:
            raise ValueError('Subject row absent from selected base')
        row = targets[subject['subject']]
        values = dict(subject=subject['subject'], teacher=subject['teacher'], criteria=subject['criteria'],
                      students=', '.join(r['id']+' '+r['name'] for r in subject['records']) or '없음')
        for field, text in values.items():
            col = cols[field]
            old = base_cells.get((row, col), '')
            if field == 'students' and subject['records']:
                # Preserve user's separators/line breaks if the ordered IDs and
                # names already match. Typography is not a roster change.
                pattern = r'(\d{4,6})\s*([가-힣]{2,5})'
                remaining = re.sub(pattern, '', old).strip(' ,\r\n\t;、')
                if not remaining and re.findall(pattern, old) == [(r['id'], r['name']) for r in subject['records']]:
                    continue
            if norm(old) == norm(text):
                continue
            # Existing-para engine requires one logical string to avoid truncation.
            text = re.sub(r'\s*\n\s*', ' ', text)
            changes.append(dict(table_index=table['table_index'], row=row, col=col,
                                text=text, before=old, field=field, subject=subject['subject'],
                                source=subject['source'], sourceRow=subject['sourceRow']))
    return changes


def run(config_path):
    started = time.perf_counter()
    config_path = Path(config_path).resolve()
    config = read(config_path)
    job = config_path.parent
    output = (job / config['output']).resolve()
    if output.suffix.lower() != '.hwpx' or not output.is_relative_to(job / 'wip'):
        raise ValueError('Output must be a job-owned HWPX; spreadsheet is reference only')
    inputs = [Path(config['base']), Path(config['roster']['path'])] + [Path(p) for p in config['sources']]
    hashes = {str(p): digest(p) for p in inputs}
    implementation = {p.name: digest(p) for p in [Path(__file__), Path(__file__).with_name('read_roster.py'), Path(__file__).with_name('read_complete_cells.py')]}
    key = hashlib.sha256(json.dumps([config, hashes, implementation], sort_keys=True).encode()).hexdigest()
    receipt_path = job / 'wip/receipts/collection.json'
    if receipt_path.exists():
        old = read(receipt_path)
        if old.get('ok') and old.get('requestHash') == key and output.exists() and digest(output) == old['outputSha256']:
            return dict(ok=True, reused=True, seconds=round(time.perf_counter()-started, 3), output=str(output), total=old['total'])
    if output.exists():
        raise ValueError('Output exists with changed/unknown request; preserve it and use a new job/draft')
    # Match every live input to intake evidence before using it.
    intake = read(job / 'inputs.json')
    for path, sha in hashes.items():
        if not any(os.path.normcase(s['path']) == os.path.normcase(path) and s['sha256'].lower() == sha for s in intake['sources']):
            raise ValueError('Input missing from matching intake: ' + path)
    from hwpx_automation.handlers.read_export import get_document_map
    from hwpx_automation.quality import capability_state
    from hwpx_automation.hwpx_ops import HwpxOps
    health = capability_state()
    save(job / 'wip/receipts/hwpx-health.json', health)
    if not health.get('ok'):
        raise RuntimeError('HWPX capability check failed')
    snapshot_dir = job / 'sources'
    snapshot_dir.mkdir(exist_ok=True)
    copies = {}
    for i, p in enumerate(dict.fromkeys(inputs)):
        target = snapshot_dir / (str(i) + '-' + p.name)
        if target.exists() and digest(target) != hashes[str(p)]:
            raise ValueError('Source snapshot conflict')
        if not target.exists():
            shutil.copy2(p, target)
        copies[str(p)] = target
    extraction_differences = []
    def mapped(path):
        # Each selected file is read once per request; cache is tied to its hash.
        cached = job / 'wip/analysis' / (hashes[str(path)] + '.json')
        if cached.exists():
            value = read(cached)
        else:
            value = get_document_map(str(copies[str(path)]), detail='full', max_preview_chars=100000)
            save(cached, value)
        value, differences = complete_map(copies[str(path)], value)
        extraction_differences.extend(dict(source=str(path), **d) for d in differences)
        return value
    maps = [(p, mapped(Path(p))) for p in config['sources']]
    diff = source_diff(maps, config)
    save(job / 'wip/analysis/source-diff.json', diff)
    proc = subprocess.run([config['rosterPython'], str(Path(__file__).with_name('read_roster.py')), str(config_path)],
                          capture_output=True, encoding='utf-8', timeout=30)
    if proc.returncode:
        raise RuntimeError('Roster reader failed: ' + proc.stderr)
    roster = json.loads(proc.stdout)
    subjects = collect_diff(diff, roster, config)
    for subject, count in config.get('expectedCounts', {}).items():
        actual_count = next((len(s['records']) for s in subjects if s['subject'] == subject), None)
        if actual_count != count:
            raise ValueError('Known subject count differs: ' + subject)
    save(job / 'wip/receipts/source-coverage.json', dict(differences=extraction_differences, completeCellsRead=True))
    save(job / 'wip/analysis/collected.json', subjects)
    base_map = mapped(Path(config['base']))
    table, base_cells, cols = table_data(base_map, config['headers'])
    changes = merge_diff(base_map, subjects, config)
    save(job / 'wip/analysis/merge-diff.json', changes)
    patches = [{k: change[k] for k in ('table_index', 'row', 'col', 'text')} for change in changes]
    base = job / 'wip/docs/base.hwpx'
    base.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(copies[config['base']], base)
    plan = dict(schemaVersion='hwpx.edit-plan/v1', source=str(base), output=str(output),
                steps=[dict(id='collect_subject_rows', op='fill_cells', args=dict(cells=patches))])
    save(job / 'edit-plan.json', plan)
    if not patches:
        # A verified identical current document needs no rewrite or app launch.
        shutil.copy2(base, output)
    engine = HwpxOps(base_directory=job, auto_backup=True)
    for dry in ([True, False] if patches else []):
        report = engine.run_edit_plan(plan, dry_run=dry)
        save(job / ('wip/receipts/edit-dry.json' if dry else 'wip/receipts/edit-commit.json'), report)
        if not report.get('ok'):
            raise RuntimeError('Edit plan blocked; see saved engine report')
    actual_map = get_document_map(str(output), detail='full', max_preview_chars=100000)
    actual_map, output_differences = complete_map(output, actual_map)
    save(job / 'wip/analysis/result-map.json', actual_map)
    actual_table, actual, _ = table_data(actual_map, config['headers'])
    if (actual_table['rows'], actual_table['cols']) != (table['rows'], table['cols']):
        raise RuntimeError('Table structure changed')
    desired = dict(base_cells)
    for patch in patches:
        desired[patch['row'], patch['col']] = patch['text']
    if any(norm(actual.get(k, '')) != norm(v) for k, v in desired.items()):
        raise RuntimeError('Cell readback differs; no delivery')
    # Check all other tables as well, including the title, without printing names.
    for before, after in zip(base_map['tables']['tables'], actual_map['tables']['tables']):
        if before['table_index'] != table['table_index'] and [(c['row'],c['col'],c['text']) for c in before['cells']] != [(c['row'],c['col'],c['text']) for c in after['cells']]:
            raise RuntimeError('Unrelated table changed')
    if any(digest(p) != sha for p, sha in hashes.items()):
        raise RuntimeError('Input changed during collection')
    all_records = [r for s in subjects for r in s['records']]
    receipt = dict(ok=True, requestHash=key, output=str(output), outputSha256=digest(output),
                   total=len(all_records), unique=len({r['id'] for r in all_records}),
                   comparison=dict(Counter(r['status'] for r in all_records)),
                   subjects=[dict(subject=s['subject'], count=len(s['records']), status=s['status']) for s in subjects],
                   inputHashes=hashes, untouchedCellsVerified=True, sourceHashesUnchanged=True,
                   sourceCoverageChecked=True, apiExtractionDifferences=len(extraction_differences),
                   diffSummary=dict(commonCells=len(diff['commonCells']), differingCells=len(diff['differingCells']),
                                    submittedRows=len(diff['submissions']), changedCells=len(changes)),
                   verification='public edit-plan dry-run/commit, open-safety, exact cell readback',
                   seconds=round(time.perf_counter()-started, 3))
    save(receipt_path, receipt)
    return {k: receipt[k] for k in ('ok', 'output', 'total', 'unique', 'comparison', 'subjects', 'diffSummary', 'seconds')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding='utf-8')
    try:
        print(json.dumps(run(args.config), ensure_ascii=False))
    except Exception as exc:
        print(json.dumps(dict(ok=False, error=str(exc)), ensure_ascii=False))
        sys.exit(1)
