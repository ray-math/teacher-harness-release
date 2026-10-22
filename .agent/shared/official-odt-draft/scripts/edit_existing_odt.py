"""Exact, byte-preserving edits of leaf ODT paragraphs; Python standard library only."""
import argparse
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import re
import tempfile
import xml.parsers.expat as expat
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape
import zipfile

TEXT = 'urn:oasis:names:tc:opendocument:xmlns:text:1.0'
MIME = b'application/vnd.oasis.opendocument.text'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def paragraphs(xml, node_mode=False):
    # Byte offsets are valid only for UTF-8. Never reserialize the surrounding XML.
    xml.decode('utf-8-sig')
    declaration = re.match(br'(?:\xef\xbb\xbf)?<\?xml[^?]*\?>', xml)
    if declaration and re.search(br'encoding\s*=\s*[\"\'](?!utf-8[\"\'])', declaration[0], re.I):
        raise ValueError('Only UTF-8 content.xml is supported')
    parser = expat.ParserCreate(namespace_separator='|')
    stack, result = [], []

    def reject(*args):
        raise ValueError('DTD and entities are not supported')

    def start(name, attrs):
        if stack:
            stack[-1]['child'] = True
        offset = parser.CurrentByteIndex
        tag = re.match(br'<(?:[^>\"\']|\"[^\"]*\"|\'[^\']*\')*>', xml[offset:])
        if not tag:
            raise ValueError('Cannot locate XML start tag')
        item = {'start': offset + len(tag[0]), 'child': False, 'text': '',
                'self_closing': tag[0].rstrip().endswith(b'/>')}
        if name in ((TEXT + '|p', TEXT + '|h', TEXT + '|span') if node_mode else (TEXT + '|p', TEXT + '|h')):
            item['paragraph'] = len(result)
            result.append(item)
        stack.append(item)

    def chars(value):
        if stack:
            stack[-1]['text'] += value

    def end(name):
        item = stack.pop()
        item['end'] = parser.CurrentByteIndex
        item['editable'] = (not item['child'] and not item['self_closing']
                            and b'<' not in xml[item['start']:item['end']])

    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.CharacterDataHandler = chars
    parser.StartDoctypeDeclHandler = reject
    parser.EntityDeclHandler = reject
    parser.ExternalEntityRefHandler = reject
    parser.Parse(xml, True)
    return result


def package(data):
    z = zipfile.ZipFile(io.BytesIO(data))
    names = z.namelist()
    if len(names) != len(set(names)):
        raise ValueError('Duplicate ZIP members')
    if 'mimetype' not in names or z.read('mimetype') != MIME:
        raise ValueError('Not an ODT package')
    if any('signatures' in n.lower() for n in names) or any(i.flag_bits & 1 for i in z.infolist()):
        raise ValueError('Signed or encrypted packages are not supported')
    if z.testzip() is not None:
        raise ValueError('ZIP CRC failure')
    roots = {}
    for name in ('content.xml', 'styles.xml', 'META-INF/manifest.xml'):
        raw = z.read(name)
        paragraphs(raw)  # Expat rejects DTD/entities before ElementTree reads it.
        roots[name] = ET.fromstring(raw)
    office = '{urn:oasis:names:tc:opendocument:xmlns:office:1.0}'
    ns = '{urn:oasis:names:tc:opendocument:xmlns:manifest:1.0}'
    if roots['content.xml'].tag != office + 'document-content' or roots['content.xml'].find(office + 'body/' + office + 'text') is None:
        raise ValueError('Missing ODF text body')
    if roots['styles.xml'].tag != office + 'document-styles':
        raise ValueError('Invalid ODF styles root')
    manifest = roots['META-INF/manifest.xml']
    if manifest.tag != ns + 'manifest' or manifest.find('.//' + ns + 'encryption-data') is not None:
        raise ValueError('Invalid or encrypted manifest')
    entries = {}
    for entry in manifest.findall(ns + 'file-entry'):
        path = entry.get(ns + 'full-path')
        if not path or path in entries:
            raise ValueError('Missing or duplicate manifest address')
        entries[path] = entry.get(ns + 'media-type')
    if entries.get('/') != MIME.decode() or not all(n in entries for n in ('content.xml', 'styles.xml')):
        raise ValueError('Missing manifest root/content/styles entry')
    if any(not n.endswith('/') and n not in names for n in entries):
        raise ValueError('Manifest references an absent member')
    return z


def text_segments(xml):
    """Direct character-data segments of p/h/span, including tails after controls."""
    paragraphs(xml)  # Validate encoding and reject DTD/entity declarations first.
    parser = expat.ParserCreate(namespace_separator='|')
    stack, result = [], []
    state = {'node': 0, 'cdata': False}
    allowed = {TEXT + '|p', TEXT + '|h', TEXT + '|span'}

    def start(name, attrs):
        node = state['node'] if name in allowed else None
        if node is not None:
            state['node'] += 1
        stack.append((name, node))

    def chars(value):
        if not stack or stack[-1][0] not in allowed or state['cdata']:
            return
        start = parser.CurrentByteIndex
        end = xml.find(b'<', start)
        if end < 0:
            raise ValueError('Unterminated character segment')
        node = stack[-1][1]
        if result and result[-1]['end'] == end and result[-1]['node'] == node:
            result[-1]['text'] += value
        else:
            result.append({'segment': len(result), 'node': node, 'start': start,
                           'end': end, 'text': value, 'editable': True})

    parser.StartElementHandler = start
    parser.EndElementHandler = lambda name: stack.pop()
    parser.CharacterDataHandler = chars
    parser.StartCdataSectionHandler = lambda: state.update(cdata=True)
    parser.EndCdataSectionHandler = lambda: state.update(cdata=False)
    parser.Parse(xml, True)
    return result


def inspection(xml):
    """Add read-only validator locators without changing byte-edit addresses."""
    ps = paragraphs(xml)
    nodes = paragraphs(xml, node_mode=True)
    segments = text_segments(xml)
    root = ET.fromstring(xml)
    local = lambda tag: tag.rsplit('}', 1)[-1]
    tn = '{urn:oasis:names:tc:opendocument:xmlns:table:1.0}'
    parents = {child: parent for parent in root.iter() for child in parent}
    paragraph_indexes = {n: i for i, n in enumerate(
        n for n in root.iter() if local(n.tag) in ('p', 'h'))}
    cell_locations, cell_errors = {}, {}

    def rows(element):
        # Same row wrappers and covered-cell counting as content validation.
        for child in element:
            if local(child.tag) == 'table-row':
                yield child
            elif local(child.tag) in ('table-header-rows', 'table-rows', 'table-row-group'):
                yield from rows(child)

    def repeat(element, attribute):
        value = int(element.get(tn + attribute, '1'))
        if not 1 <= value <= 10000:
            raise ValueError('Invalid or unbounded table repetition')
        return value

    for ti, table in enumerate(n for n in root.iter() if local(n.tag) == 'table'):
        table_cells, locations = [], {}
        table_rows = list(rows(table))
        for row in table_rows:
            table_cells.extend(c for c in row if local(c.tag) in ('table-cell', 'covered-table-cell'))
        try:
            ri, count = 0, 0
            for row in table_rows:
                rr = repeat(row, 'number-rows-repeated')
                ci = 0
                for cell in row:
                    if local(cell.tag) not in ('table-cell', 'covered-table-cell'):
                        continue
                    rc = repeat(cell, 'number-columns-repeated')
                    count += rr * rc
                    if count > 10000:
                        raise ValueError('Table context exceeds 10000 logical cells')
                    locations[cell] = [
                        {'kind': 'cell', 'table': ti, 'row': r, 'col': c}
                        for r in range(ri, ri + rr) for c in range(ci, ci + rc)]
                    ci += rc
                ri += rr
            cell_locations.update(locations)
        except ValueError as exc:
            # Inspection must not invent a single address for repeated content,
            # or change which documents the byte-preserving editor accepts.
            cell_errors.update({cell: str(exc) for cell in table_cells})

    def context(element):
        paragraph, cells, errors = None, [], []
        current = element
        while current is not None:
            if paragraph is None and current in paragraph_indexes:
                paragraph = {'kind': 'paragraph', 'index': paragraph_indexes[current]}
            if local(current.tag) in ('table-cell', 'covered-table-cell'):
                if current in cell_locations:
                    cells[0:0] = cell_locations[current]
                else:
                    errors.append(cell_errors.get(current, 'Cell is outside supported table rows'))
            current = parents.get(current)
        result = {'paragraph': paragraph, 'cells': cells}
        if errors:
            result.update(cells=[], cell_context_status='unsupported',
                          cell_context_reason='; '.join(dict.fromkeys(errors)))
        return result

    elements = [n for n in root.iter() if n.tag in
                ('{' + TEXT + '}p', '{' + TEXT + '}h', '{' + TEXT + '}span')]
    contexts = [context(n) for n in elements]
    paragraph_contexts = [ctx for n, ctx in zip(elements, contexts)
                          if n.tag != '{' + TEXT + '}span']
    return {
        'paragraphs': [{**{k: item[k] for k in ('paragraph', 'text', 'editable')},
                        'context': ctx} for item, ctx in zip(ps, paragraph_contexts)],
        'nodes': [{'node': item['paragraph'], 'text': item['text'], 'editable': item['editable'],
                   'context': ctx} for item, ctx in zip(nodes, contexts)],
        'segments': [{**{k: item[k] for k in ('segment', 'node', 'text', 'editable')},
                      'context': contexts[item['node']]} for item in segments]}


def prepare(source, output, plan):
    source, output = Path(source).resolve(), Path(output).resolve()
    if source.suffix.lower() != '.odt' or output.suffix.lower() != '.odt':
        raise ValueError('Only explicit .odt paths are supported')
    if source == output or output.exists():
        raise ValueError('Source or existing output cannot be overwritten')
    data = source.read_bytes()
    if set(plan) != {'source_sha256', 'edits'} or plan['source_sha256'] != sha(data):
        raise ValueError('Source SHA256 mismatch or invalid plan keys')
    if not isinstance(plan['edits'], list) or not plan['edits']:
        raise ValueError('An explicit nonempty edits list is required')
    z = package(data)
    xml = z.read('content.xml')
    items = paragraphs(xml)
    nodes = paragraphs(xml, node_mode=True)
    segments = text_segments(xml)
    used, replacements = set(), []
    for edit in plan['edits']:
        mode = 'segment' if 'segment' in edit else ('node' if 'node' in edit else 'paragraph')
        if set(edit) != {mode, 'before', 'after'}:
            raise ValueError('Each edit requires exactly one segment/node/paragraph address, before, after')
        index = edit[mode]
        targets = segments if mode == 'segment' else (nodes if mode == 'node' else items)
        if type(index) is not int or index < 0 or index >= len(targets):
            raise ValueError('Invalid address')
        item = targets[index]
        if item['start'] in used:
            raise ValueError('Duplicate or overlapping address')
        used.add(item['start'])
        if any(item['start'] < end and start < item['end'] for start, end, _ in replacements):
            raise ValueError('Overlapping address')
        if not item['editable']:
            raise ValueError('Mixed runs, fields, comments, CDATA or empty self-closing paragraphs require another preserving editor')
        if not isinstance(edit['before'], str) or item['text'] != edit['before']:
            raise ValueError('Exact before text mismatch')
        after = edit['after']
        if not isinstance(after, str) or after == edit['before']:
            raise ValueError('after must be a changed string')
        # ODF represents repeated/boundary spaces and newlines with elements.
        boundary = lambda s: (len(s) - len(s.lstrip(' ')), len(s) - len(s.rstrip(' ')))
        spaces_ok = (mode == 'segment' and bool(after.strip(' ')) and
                     boundary(after) == boundary(edit['before']))
        if (after != after.strip(' ') and not spaces_ok) or '  ' in after.strip(' ') or any(ord(c) < 32 for c in after):
            raise ValueError('Whitespace requiring ODF elements is unsupported')
        replacements.append((item['start'], item['end'], escape(after).encode('utf-8')))
    edited = xml
    for start, end, replacement in sorted(replacements, reverse=True):
        edited = edited[:start] + replacement + edited[end:]
    reread = paragraphs(edited)
    if len(reread) != len(items):
        raise ValueError('Paragraph structure changed')
    renodes = paragraphs(edited, node_mode=True)
    resegments = text_segments(edited)
    # Clearing old official values removes character data, never its enclosing
    # element or controls. Segment indexes after a deletion are not stable; check
    # all character data against the original ranges instead of reusing indexes.
    replacement_text = {(start, end): ET.fromstring(b'<v>' + value + b'</v>').text or ''
                        for start, end, value in replacements}
    expected_segments = [(s['start'], s['node'], replacement_text.get((s['start'], s['end']), s['text']))
                         for s in segments]
    # An explicit empty leaf has no character-data segment before insertion.
    # Bind the new segment to its original byte address and owning node.
    for (start, end), value in replacement_text.items():
        if start == end:
            owners = [n['paragraph'] for n in nodes
                      if n['start'] == start and n['end'] == end and n['editable']]
            if len(owners) != 1:
                raise ValueError('Empty leaf insertion has no unique owning node')
            expected_segments.append((start, owners[0], value))
    expected_segments = [(node, value) for _, node, value in sorted(expected_segments) if value]
    if [(s['node'], s['text']) for s in resegments] != expected_segments:
        raise ValueError('Saved or unselected text segment changed')
    for edit in plan['edits']:
        if 'segment' in edit:
            continue
        actual = renodes[edit['node']] if 'node' in edit else reread[edit['paragraph']]
        if actual['text'] != edit['after']:
            raise ValueError('Saved text mismatch')
    receipt = {'schema': 'odt-leaf-edit/v1', 'source': str(source), 'output': str(output),
               'source_sha256': sha(data), 'plan_sha256': sha(json.dumps(plan, sort_keys=True, ensure_ascii=False).encode()),
               'content_sha256': sha(edited),
               'source_mimetype_conventional': (z.namelist()[0] == 'mimetype' and
                                                z.getinfo('mimetype').compress_type == zipfile.ZIP_STORED),
               'changed_addresses': [
                   {k: v for k, v in e.items() if k in ('segment', 'node', 'paragraph')} for e in plan['edits']]}
    return z, edited, receipt


def apply(source, output, plan, receipt):
    z, edited, expected = prepare(source, output, plan)
    if receipt != expected:
        raise ValueError('Run dry-run with this exact source, plan and output first')
    output = Path(output).resolve()
    fd, temp = tempfile.mkstemp(prefix='.odt-candidate-', suffix='.odt', dir=output.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(temp, 'w') as candidate:
            candidate.comment = z.comment
            for info in z.infolist():
                candidate.writestr(copy.copy(info), edited if info.filename == 'content.xml' else z.read(info.filename))
        with package(Path(temp).read_bytes()) as candidate:
            if candidate.namelist() != z.namelist() or candidate.comment != z.comment:
                raise ValueError('Package membership changed')
            for info in z.infolist():
                saved = candidate.getinfo(info.filename)
                for key in ('date_time', 'compress_type', 'comment', 'extra', 'internal_attr', 'external_attr', 'create_system'):
                    if getattr(info, key) != getattr(saved, key):
                        raise ValueError('Package metadata changed: ' + key)
                wanted = edited if info.filename == 'content.xml' else z.read(info.filename)
                if candidate.read(info.filename) != wanted:
                    raise ValueError('Package member changed unexpectedly')
            paragraphs(candidate.read('content.xml'))
        if sha(Path(source).read_bytes()) != expected['source_sha256']:
            raise ValueError('Source changed during edit')
        # Atomic publication with exclusive destination creation, including races.
        os.link(temp, output)
    finally:
        Path(temp).unlink(missing_ok=True)
    return {**expected, 'status': 'written', 'output_sha256': sha(output.read_bytes())}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--inspect', action='store_true')
    modes.add_argument('--dry-run', action='store_true')
    modes.add_argument('--apply', action='store_true')
    parser.add_argument('--plan', type=Path)
    parser.add_argument('--receipt', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(argv)
    try:
        if args.inspect:
            if args.source.suffix.lower() != '.odt':
                raise ValueError('Only ODT sources are supported')
            data = args.source.read_bytes()
            with package(data) as z:
                result = {'source_sha256': sha(data), **inspection(z.read('content.xml'))}
        else:
            if not all((args.plan, args.receipt, args.output)):
                raise ValueError('plan, receipt and output are required')
            plan = json.loads(args.plan.read_text(encoding='utf-8-sig'))
            if args.dry_run:
                _, _, result = prepare(args.source, args.output, plan)
                # A prior receipt is never silently replaced.
                with args.receipt.open('x', encoding='utf-8') as f:
                    json.dump(result, f, ensure_ascii=False, indent=2)
                result = {**result, 'status': 'dry_run'}
            else:
                receipt = json.loads(args.receipt.read_text(encoding='utf-8-sig'))
                result = apply(args.source, args.output, plan, receipt)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, expat.ExpatError) as exc:
        print(json.dumps({'status': 'needs_input', 'reason': str(exc)}, ensure_ascii=False))
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
