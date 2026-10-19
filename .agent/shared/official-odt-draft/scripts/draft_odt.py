"""Fill an explicitly selected existing placeholder ODT; never invent a layout."""
import argparse
import calendar
from datetime import date
import hashlib
import json
from pathlib import Path
import re
import sys
from copy import deepcopy
from io import BytesIO
from zipfile import ZipFile, ZIP_STORED, BadZipFile
from xml.etree import ElementTree as ET

from odf.opendocument import load
from odf.text import P, Span, Bookmark, BookmarkStart, BookmarkEnd
from odf import teletype

SKILL = Path(__file__).resolve().parents[1]
MIME = b'application/vnd.oasis.opendocument.text'


def clear(node):
    for child in list(node.childNodes):
        if child.nodeType == child.TEXT_NODE:
            # odfpy 1.4.1 removeChild wrongly sends Text nodes to its element cache.
            child.data = ''
        else:
            node.removeChild(child)


def set_text(p, value):
    # Emptying an official value must not remove the cell/approval field itself.
    saved_controls = [deepcopy(n) for factory in (Bookmark, BookmarkStart, BookmarkEnd)
                      for n in p.getElementsByType(factory)]
    spans = p.getElementsByType(Span)
    style = spans[0].getAttribute('stylename') if spans else None
    clear(p)
    span = Span(stylename=style) if style else Span()
    teletype.addTextToElement(span, value)
    p.addElement(span)
    for n in saved_controls:
        if n.qname == BookmarkStart(name='').qname and span.childNodes:
            span.insertBefore(n, span.childNodes[0])
        else:
            span.addElement(n)


def leaf_paragraphs(doc):
    return [p for p in doc.text.getElementsByType(P) if len(p.getElementsByType(P)) == 1]


def format_date(value=None):
    """None/0 denotes unknown. Calendar-check supplied components."""
    if value is None:
        parts = [0, 0, 0]
    elif isinstance(value, (list, tuple)) and len(value) == 3:
        if any(x is not None and (isinstance(x, bool) or not isinstance(x, int)) for x in value):
            raise ValueError('Date components must be integers or null')
        parts = [x or 0 for x in value]
    elif isinstance(value, str):
        match = re.fullmatch(r'\s*(\d{4})[.\-/]\s*(\d{1,2})[.\-/]\s*(\d{1,2})\.?\s*', value)
        if not match:
            raise ValueError('Use YYYY-MM-DD, YYYY. M. D., or [year,month,day]')
        parts = list(map(int, match.groups()))
    else:
        raise ValueError('Invalid date input')
    y, m, d = parts
    if not 0 <= y <= 9999 or not 0 <= m <= 12 or not 0 <= d <= 31:
        raise ValueError('Date component outside valid range')
    if m and d and d > calendar.monthrange(y or 2000, m)[1]:
        raise ValueError('Invalid day for month')
    if y and m and d:
        date(y, m, d)
    return f'{y:04d}. {m}. {d}.'


def related_line(ref):
    allowed = {'agency', 'number', 'date', 'basis'}
    if set(ref) - allowed:
        raise ValueError('Unknown related-document field')
    if ref.get('basis'):
        if any(ref.get(k) is not None for k in ('agency','number','date')):
            raise ValueError('Use either basis text or a document reference')
        return str(ref['basis'])
    agency = ref.get('agency') or '00고'
    number = str(ref.get('number') or '0000')
    if not re.fullmatch(r'\d+', number):
        raise ValueError('Document number must contain digits only')
    return f'{agency}-{number}({format_date(ref.get("date"))})'


def body_lines(data):
    refs = data.get('related', [{}])
    if not isinstance(refs, list):
        raise ValueError('related must be a list; [] explicitly means no related document')
    lines = []
    if len(refs) == 1:
        lines.append('1. 관련: ' + related_line(refs[0]))
    elif refs:
        if len(refs) > 14:
            raise ValueError('More than 14 references need manual enumeration')
        lines.append('1. 관련')
        for marker, ref in zip('가나다라마바사아자차카타파하', refs):
            lines.append(f'  {marker}. ' + related_line(ref))
    body = data.get('body')
    if not isinstance(body, list) or not body or any(not isinstance(x, str) for x in body) or not any(x.strip() for x in body):
        raise ValueError('body must contain nonempty paragraph strings with intended numbering')
    if any('\n' in x or '\r' in x for x in body):
        raise ValueError('Use a separate body array element for each paragraph')
    if any(re.search(r'(?:끝\.|이하 빈칸)\s*$', x) for x in body):
        raise ValueError('Do not include end markers; this helper adds the final marker')
    lines.extend(body)
    while lines and not lines[-1].strip():
        lines.pop()
    attachments = data.get('attachments', [])
    if not isinstance(attachments, list):
        raise ValueError('attachments must be a list')
    if attachments:
        lines.append('')
        for i, item in enumerate(attachments, 1):
            if not isinstance(item, dict) or set(item) != {'name','quantity'} or not item['name'] or not item['quantity']:
                raise ValueError('Every attachment needs an explicit name and quantity')
            prefix = '붙임  ' if i == 1 else '      '
            number = f'{i}. ' if len(attachments) > 1 else ''
            lines.append(f'{prefix}{number}{item["name"]} {item["quantity"]}'.rstrip('. ') + '.')
    lines[-1] = lines[-1].rstrip() + '  끝.'
    return lines


def check_package(path):
    path = Path(path)
    if path.suffix.lower() != '.odt':
        raise ValueError('Output must have .odt extension')
    with ZipFile(path) as z:
        infos = z.infolist()
        if not infos or infos[0].filename != 'mimetype' or infos[0].compress_type != ZIP_STORED or infos[0].extra:
            raise ValueError('Invalid ODT mimetype placement/compression')
        if z.read('mimetype') != MIME or z.testzip() is not None:
            raise ValueError('ODT MIME or ZIP integrity failure')
        names = z.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate package member')
        for name in ('content.xml','styles.xml','META-INF/manifest.xml'):
            ET.fromstring(z.read(name))
        manifest = ET.fromstring(z.read('META-INF/manifest.xml'))
        ns = '{urn:oasis:names:tc:opendocument:xmlns:manifest:1.0}'
        entries = {e.get(ns+'full-path'):e.get(ns+'media-type') for e in manifest}
        if entries.get('/') != MIME.decode():
            raise ValueError('Manifest root MIME mismatch')
        for member in ('content.xml','styles.xml'):
            if member not in entries:
                raise ValueError('Manifest entry missing')
        for member in entries:
            if not member.endswith('/') and member not in names:
                raise ValueError('Manifest points to absent member')
    doc = load(str(path))
    texts = [teletype.extractText(p) for p in leaf_paragraphs(doc)]
    return doc, texts


class NeedsInput(ValueError):
    """A user-selected baseline or a supported editing route is required."""


def create(data, output, form=None, *, template=None):
    if template is None:
        raise NeedsInput('기존 초안/양식을 지정해 주세요: --template <기존 .odt 경로>. '
                         '양식이 없으면 작성을 멈추고 사용자에게 요청해야 합니다.')
    if form == 'paste':
        raise NeedsInput('새 빈 ODT/붙여넣기 양식 생성은 지원하지 않습니다. 기존 초안/양식을 지정해 주세요.')
    template = Path(template).resolve()
    if template.suffix.lower() != '.odt' or not template.is_file():
        raise NeedsInput('실제 기존 .odt 초안/양식 경로가 필요합니다. 다른 원본 형식은 해당 형식의 편집 경로를 사용하고 자동 변환하지 마세요.')
    allowed = {'title','agency','recipient','via','sender','related','body','attachments','typography'}
    if set(data) - allowed:
        raise ValueError('Unknown input field(s): ' + ', '.join(sorted(set(data)-allowed)))
    if not isinstance(data.get('title'), str) or not data['title'].strip():
        raise ValueError('A title is required')
    output = Path(output).resolve()
    if output.suffix.lower() != '.odt' or output.exists():
        raise ValueError('Choose a new .odt output path; overwrite is not supported')
    baseline_hash = hashlib.sha256(template.read_bytes()).hexdigest()
    try:
        doc, _ = check_package(template)
    except (BadZipFile, ET.ParseError, OSError, ValueError) as exc:
        raise NeedsInput('지정한 기존 ODT를 정상적으로 읽을 수 없습니다. 유효한 기존 초안/양식과 보존 편집 경로를 확인하세요.') from exc
    from approval_fields import controls
    original_controls = controls(doc)
    fields = {'{{TITLE}}':data['title'], '{{AGENCY}}':data.get('agency') or '00고등학교',
              '{{RECIPIENT}}':data.get('recipient') or '00', '{{VIA}}':data.get('via') or '',
              '{{SENDER}}':data.get('sender') or ''}
    paragraphs = leaf_paragraphs(doc)
    anchors = [p for p in paragraphs if teletype.extractText(p) == '{{BODY}}']
    if len(anchors) != 1:
        raise NeedsInput('지정한 기존 문서에 {{BODY}} 본문 자리표시자가 하나 있어야 합니다. '
                         '일반 현재본은 재생성하지 않고 해당 문서를 편집할 도구/수정 범위를 사용자에게 확인하세요.')
    known = set(fields) | {'{{BODY}}'}
    for p in paragraphs:
        value = teletype.extractText(p)
        if ('{{' in value or '}}' in value) and value not in known:
            raise NeedsInput('지원하지 않는 자리표시자 또는 혼합 문단입니다. 기존 구조를 보존할 편집 경로를 확인하세요.')
    if not any(teletype.extractText(p) == '{{TITLE}}' for p in paragraphs):
        raise NeedsInput('지정 양식에 {{TITLE}} 제목 자리표시자가 없습니다. 기존 문서의 수정 위치를 확인하세요.')
    changed_fields = []
    for p in paragraphs:
        value = teletype.extractText(p)
        for key,replacement in fields.items():
            value = value.replace(key,replacement)
        if value != teletype.extractText(p):
            set_text(p,value)
            changed_fields.append(p)
    anchor = anchors[0]
    anchor_controls = [deepcopy(n) for factory in (BookmarkStart, BookmarkEnd)
                       for n in anchor.getElementsByType(factory)]
    lines = body_lines(data)
    generated = []
    for value in lines:
        p = deepcopy(anchor)
        p.parentNode = None
        for factory in (Bookmark, BookmarkStart, BookmarkEnd):
            for n in list(p.getElementsByType(factory)):
                n.parentNode.removeChild(n)
        set_text(p,value)
        anchor.parentNode.insertBefore(p,anchor)
        generated.append(p)
    anchor.parentNode.removeChild(anchor)
    from basic_format import normalize_line_height
    from odf.style import TextProperties,ParagraphProperties,FontFace
    typography = dict(data.get('typography', {}))
    if set(typography) - {'font_name','font_file','size','line_height'}:
        raise ValueError('Unknown typography field')
    if 'line_height' in typography:
        typography['line_height'] = normalize_line_height(typography['line_height'])
    if 'font_file' in typography and 'font_name' not in typography:
        raise ValueError('font_file requires an explicitly requested font_name')
    if 'size' in typography and not 6 <= float(typography['size']) <= 72:
        raise ValueError('Invalid requested font size')
    if 'font_name' in typography and (not isinstance(typography['font_name'], str) or not typography['font_name'].strip()):
        raise ValueError('font_name must be nonempty')
    if 'font_name' in typography and not any(f.getAttribute('name') == typography['font_name'] for f in doc.fontfacedecls.getElementsByType(FontFace)):
        doc.fontfacedecls.addElement(FontFace(name=typography['font_name'], fontfamily=typography['font_name']))
    # Clone only replacement-field/body styles. Never normalize the baseline.
    from odf.style import Style
    style_map={s.getAttribute('name'):s for rt in (doc.styles,doc.automaticstyles) for s in rt.getElementsByType(Style)}
    def scoped_style(node, family, serial):
        old = style_map.get(node.getAttribute('stylename'))
        st = deepcopy(old) if old is not None else Style(name=serial, family=family)
        st.parentNode = None
        while serial in style_map:
            serial += 'X'
        st.setAttribute('name', serial)
        if family == 'paragraph' and 'line_height' in typography:
            props = st.getElementsByType(ParagraphProperties)
            pp = props[0] if props else ParagraphProperties()
            if not props: st.addElement(pp)
            pp.setAttribute('lineheight', typography['line_height'])
        if 'font_name' in typography or 'size' in typography:
            props = st.getElementsByType(TextProperties)
            tp = props[0] if props else TextProperties()
            if not props: st.addElement(tp)
            if 'font_name' in typography:
                for key in ('fontname','fontnameasian','fontnamecomplex','fontfamily','fontfamilyasian','fontfamilycomplex'):
                    tp.setAttribute(key, typography['font_name'])
            if 'size' in typography:
                for key in ('fontsize','fontsizeasian','fontsizecomplex'):
                    tp.setAttribute(key, f"{float(typography['size']):g}pt")
        doc.automaticstyles.addElement(st)
        style_map[serial] = st
        node.setAttribute('stylename', st)
    if typography:
        for i, p in enumerate(changed_fields + generated):
            scoped_style(p, 'paragraph', f'OfficialReplacement{i}')
            if 'font_name' in typography or 'size' in typography:
                for j, span in enumerate(p.getElementsByType(Span)):
                    scoped_style(span, 'text', f'OfficialReplacement{i}Span{j}')
    for n in anchor_controls:
        paragraph = generated[0] if n.qname == BookmarkStart(name='').qname else generated[-1]
        span = paragraph.getElementsByType(Span)[0]
        if n.qname == BookmarkStart(name='').qname and span.childNodes:
            span.insertBefore(n, span.childNodes[0])
        else:
            span.addElement(n)
    if controls(doc) != original_controls:
        raise ValueError('Template field inventory changed during generation')
    # Preserve every other package member byte-for-byte, including styles,
    # metadata, settings, images, approval layout, and manifest.
    memory = BytesIO()
    doc.save(memory)
    with ZipFile(memory) as rewritten:
        content = rewritten.read('content.xml')
    if hashlib.sha256(template.read_bytes()).hexdigest() != baseline_hash:
        raise ValueError('Baseline changed while it was being read; reselect the current baseline')
    output.parent.mkdir(parents=True,exist_ok=True)
    # Exclusive creation prevents accidental replacement, including concurrent runs.
    with output.open('xb') as stream:
        with ZipFile(template) as source, ZipFile(stream, 'w') as target:
            for info in source.infolist():
                target.writestr(info, content if info.filename == 'content.xml' else source.read(info.filename))
    reopened, texts = check_package(output)
    if controls(reopened) != original_controls:
        raise ValueError('Template field inventory changed during save')
    if any('{{' in t or '}}' in t for t in texts):
        raise ValueError('Unreplaced template field remains')
    if not any(texts[i:i+len(lines)] == lines for i in range(len(texts))):
        raise ValueError('Generated paragraphs did not survive ODT round-trip')
    if data['title'] not in texts:
        raise ValueError('Generated title did not survive ODT round-trip')
    return {'path':str(output),'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),
            'checks':['ODT MIME/ZIP/XML/manifest','odfpy reopen','exact title and body paragraphs'],
            'template':str(template), 'template_sha256':baseline_hash,
            'preserved_package_members':'all except content.xml',
            'format_scope':'replacement fields/body only' if typography else 'existing styles preserved',
            'portal_import_verified':False,
            'rendering_checked':False}


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--form', choices=['general','internal'], help='Legacy label only; never selects a template')
    parser.add_argument('--template', type=Path, help='User-selected existing .odt baseline (required)')
    parser.add_argument('--check', type=Path)
    args=parser.parse_args()
    if args.check:
        _, texts = check_package(args.check)
        print(json.dumps({'path':str(args.check),'paragraphs':len(texts),'package_check':'passed','rendering_checked':False},ensure_ascii=False))
    else:
        if not args.template:
            print(json.dumps({'status':'needs_input', 'message':'기존 초안/양식을 지정해 주세요: --template <기존 .odt 경로>. 양식이 없으면 작성을 멈추고 사용자에게 요청하세요.'}, ensure_ascii=False))
            return 2
        if not args.data or not args.output:
            parser.error('--data and --output are required for creation')
        data=json.loads(args.data.read_text(encoding='utf-8-sig'))
        try:
            receipt = create(data,args.output,args.form,template=args.template)
        except NeedsInput as exc:
            print(json.dumps({'status':'needs_input', 'message':str(exc)}, ensure_ascii=False))
            return 2
        print(json.dumps(receipt,ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
