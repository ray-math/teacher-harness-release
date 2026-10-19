"""Preserve HanODT approval controls; structural checks are not portal acceptance.

Repair is deliberately limited to matched header/footer trees and an explicit
body paragraph range. It copies control names only, never old official values.
"""
from collections import Counter
from pathlib import Path
import re
from odf.opendocument import load
from odf.text import Bookmark, BookmarkStart, BookmarkEnd, P, Span
from odf import teletype


def elements(node):
    return [x for x in node.childNodes if x.nodeType == x.ELEMENT_NODE]


def controls(doc):
    return Counter((n.qname[1], n.getAttribute('name').split('¡',1)[-1])
                   for factory in (Bookmark, BookmarkStart, BookmarkEnd)
                   for n in doc.text.getElementsByType(factory))


def validate_approval(doc, reference=None):
    actual = controls(doc)
    starts = doc.text.getElementsByType(BookmarkStart)
    ends = doc.text.getElementsByType(BookmarkEnd)
    body = [x for x in starts if '¡본문¡' in x.getAttribute('name')]
    if len(body) != 1:
        raise ValueError('Exactly one approval body start is required')
    name = body[0].getAttribute('name')
    if sum(x.getAttribute('name') == name for x in ends) != 1:
        raise ValueError('Approval body end is missing or duplicated')
    def walk(node):
        yield node
        for child in elements(node):
            yield from walk(child)
    ordered = list(walk(doc.text))
    end = next(x for x in ends if x.getAttribute('name') == name)
    if ordered.index(body[0]) >= ordered.index(end):
        raise ValueError('Body field ends before it starts')
    full_names = [x.getAttribute('name') for x in doc.text.getElementsByType(Bookmark)]
    if len(full_names) != len(set(full_names)) or any(n != 1 for n in actual.values()):
        raise ValueError('Duplicate approval field')
    if reference is not None and actual != controls(reference):
        raise ValueError('Approval control inventory differs from reference')
    return {'control_count': sum(actual.values()), 'body_field_paired': True,
            'portal_import_verified': False}


def _descendant_path(root, descendant):
    path = []
    node = descendant
    while node is not root:
        parent = node.parentNode
        if parent is None:
            raise ValueError('Control is outside matched template region')
        path.append((elements(parent).index(node), node.qname))
        node = parent
    return list(reversed(path))


def _resolve(root, path):
    for index, qname in path:
        children = elements(root)
        if index >= len(children) or children[index].qname != qname:
            raise ValueError('Template structure differs; automatic repair refused')
        root = children[index]
    return root


def restore_missing(current_path, reference_path, output, first_body_index, last_body_index):
    output = Path(output)
    if output.exists() or output.suffix.lower() != '.odt':
        raise ValueError('Use a new .odt output path')
    doc, reference = load(str(current_path)), load(str(reference_path))
    before = teletype.extractText(doc.text)
    roots, old_roots = elements(doc.text), elements(reference.text)
    if not (0 < first_body_index <= last_body_index < len(roots)-1):
        raise ValueError('Body must be between matched header and footer')
    first, last = roots[first_body_index], roots[last_body_index]
    if first.qname != P().qname or last.qname != P().qname:
        raise ValueError('Explicit body boundaries must be paragraphs')
    existing = controls(doc)
    original = controls(reference)
    if existing - original:
        raise ValueError('Unexpected existing controls; review instead of replacing')
    added = []
    max_cell_id = max([int(re.match(r'CellField(\d+)', n.getAttribute('name')).group(1))
                       for n in doc.text.getElementsByType(Bookmark)
                       if re.match(r'CellField(\d+)', n.getAttribute('name'))] or [0])
    # Cells cleared for privacy must retain their field, without restoring values.
    for old_root, root in ((old_roots[0], roots[0]), (old_roots[-1], roots[-1])):
        for field in old_root.getElementsByType(Bookmark):
            key = ('bookmark', field.getAttribute('name').split('¡',1)[-1])
            if existing[key]:
                continue
            if field.parentNode.qname != P().qname:
                raise ValueError('Unsupported cell field placement')
            target = _resolve(root, _descendant_path(old_root, field.parentNode))
            max_cell_id += 1
            restored = Bookmark(name='CellField'+str(max_cell_id)+'¡'+key[1])
            target.addElement(restored)
            added.append(key)
    ref_starts = [n for n in reference.text.getElementsByType(BookmarkStart)
                  if '¡본문¡' in n.getAttribute('name')]
    if len(ref_starts) != 1:
        raise ValueError('Reference body field is ambiguous')
    name = ref_starts[0].getAttribute('name')
    # Use the current first/last text span so the field itself carries current font.
    for kind, factory, paragraph, at_start in (
        ('bookmark-start', BookmarkStart, first, True),
        ('bookmark-end', BookmarkEnd, last, False)):
        if existing[(kind, name.split('¡',1)[-1])]:
            continue
        spans = [n for n in elements(paragraph) if n.qname == Span().qname]
        if not spans:
            raise ValueError('Body boundary needs an explicitly formatted text span')
        span = spans[0] if at_start else spans[-1]
        field = factory(name=name)
        if at_start and span.childNodes:
            span.insertBefore(field, span.childNodes[0])
        else:
            span.addElement(field)
        added.append((kind, name))
    if teletype.extractText(doc.text) != before:
        raise AssertionError('Text changed during control restoration')
    validate_approval(doc, reference)
    output.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(output))
    reopened = load(str(output))
    if teletype.extractText(reopened.text) != before:
        raise AssertionError('Text changed during save')
    result = validate_approval(reopened, reference)
    result['restored_control_count'] = len(added)
    return result
