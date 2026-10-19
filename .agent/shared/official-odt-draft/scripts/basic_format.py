"""ODF paragraph formatting for official drafts; semantic numbering is reviewed separately."""
import copy
import os
import re
from pathlib import Path

from PIL import ImageFont
from odf import teletype
from odf.style import Style, TextProperties, ParagraphProperties, FontFace, TabStops, TabStop
from odf.text import Span

DEFAULT_FONT = '굴림체'
DEFAULT_LINE_HEIGHT = '123%'


def normalize_line_height(value=DEFAULT_LINE_HEIGHT):
    """Accept an explicit positive percentage for new-draft paragraph spacing."""
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+)?%', value):
        raise ValueError('line_height must be a positive percentage such as 160%')
    percent = float(value[:-1])
    if not 0 < percent < float('inf'):
        raise ValueError('line_height must be a positive finite percentage')
    return f'{percent:g}%'


def resolve_font_file(value=None):
    if value:
        path = Path(value)
        if not path.is_file():
            raise ValueError('Font file is missing')
        return path
    windows = Path(os.environ.get('WINDIR', 'C:/Windows'))
    candidates = [windows / 'Fonts' / 'gulim.ttc']
    for path in candidates:
        if path.is_file():
            return path
    raise ValueError('굴림체 font file not found; supply typography.font_file. Do not silently substitute a font.')


def load_measurement_font(font_path, size, font_name):
    # gulim.ttc contains Gulim, GulimChe, Dotum and DotumChe. Selecting its
    # first face would measure a different family despite a correct filename.
    aliases = {'굴림체': {'gulimche', '굴림체'}, '굴림': {'gulim', '굴림'}}
    expected = aliases.get(font_name, {font_name.casefold()})
    index = 0
    while True:
        try:
            font = ImageFont.truetype(str(font_path), size=round(size * 100), index=index)
        except OSError:
            break
        if font.getname()[0].casefold() in expected:
            return font
        if font_path.suffix.lower() not in ('.ttc', '.otc'):
            if font_name not in aliases:
                return font
            break
        index += 1
    raise ValueError('Requested font family is absent from the font file: ' + font_name)


def formatting_plan(text, measure, size, attachment=False):
    """Return logical text and first-line/continuation positions in points."""
    if text.startswith('붙임  '):
        match = re.match(r'붙임  (?:\d+\. )?', text)
        return text, 0.0, measure(match[0]), True
    if attachment and re.match(r'^\s*\d+\. ', text):
        value = text.lstrip()
        marker = re.match(r'\d+\. ', value)[0]
        first = measure('붙임  ')
        return value, first, first + measure(marker), True
    markers = [r'\d+\.', r'[가-힣]\.', r'\d+\)', r'[가-힣]\)',
               r'\(\d+\)', r'\([가-힣]\)', r'[①-⑳]', r'[㉮-㉻]']
    value = text.lstrip(' ')
    for level, pattern in enumerate(markers):
        match = re.match('(' + pattern + r') (\S.*)$', value)
        if match:
            expected = 2 * level
            if len(text) - len(value) != expected:
                raise ValueError('Item hierarchy indentation must be two spaces per level: ' + text[:20])
            first = level * size
            return value, first, first + measure(match[1] + ' '), False
    return text, 0.0, 0.0, False


def apply_basic_format(doc, paragraphs, *, font_name=DEFAULT_FONT, font_file=None, size=12,
                       line_height=DEFAULT_LINE_HEIGHT):
    """Only mutate supplied paragraphs, preserving their text except leading alignment spaces."""
    line_height = normalize_line_height(line_height)
    if not 6 <= float(size) <= 72:
        raise ValueError('Invalid body font size')
    if font_name != DEFAULT_FONT and not font_file:
        raise ValueError('An alternate font requires its matching font_file')
    font_path = resolve_font_file(font_file)
    font = load_measurement_font(font_path, size, font_name)
    measure = lambda text: font.getlength(text) / 100
    props = dict(fontname=font_name, fontnameasian=font_name, fontnamecomplex=font_name,
                 fontfamily=font_name, fontfamilyasian=font_name, fontfamilycomplex=font_name,
                 fontsize=f'{size:g}pt', fontsizeasian=f'{size:g}pt', fontsizecomplex=f'{size:g}pt',
                 textscale='100%', letterspacing='0pt', letterkerning='false', textposition='0% 100%')
    if not any(f.getAttribute('name') == font_name for f in doc.fontfacedecls.getElementsByType(FontFace)):
        doc.fontfacedecls.addElement(FontFace(name=font_name, fontfamily=font_name))
    styles = {s.getAttribute('name'): s for r in (doc.styles, doc.automaticstyles) for s in r.getElementsByType(Style)}
    prefix = 'OfficialBasic'
    while any(name.startswith(prefix) for name in styles):
        prefix += 'X'
    ts = Style(name=prefix+'Text', family='text')
    ts.addElement(TextProperties(**props)); doc.automaticstyles.addElement(ts)
    # Both attachment rows start at the same paragraph origin and use the SAME
    # explicit tab before the number, followed by one literal space. Mixing
    # literal-prefix widths with a numeric indent
    # drifted in the user's ODT editor even when the saved values matched.
    attachment_rows = {}
    inside = False
    for i, p in enumerate(paragraphs):
        value = teletype.extractText(p)
        m = re.match(r'^붙임[ \t]+(\d+\.)[ \t]+(.*)$', value)
        if m:
            inside = True; attachment_rows[i] = ('붙임',m[1],m[2])
        elif inside:
            m = re.match(r'^[ \t]*(\d+\.)[ \t]+(.*)$', value)
            if m: attachment_rows[i] = ('',m[1],m[2])
            else: inside = False
    number_stop = measure('붙임  ')
    result = []; attachment = False
    for i, p in enumerate(paragraphs):
        oldtext = teletype.extractText(p)
        if i in attachment_rows:
            label, number, description = attachment_rows[i]
            value = label+'\t'+number+' '+description
            first, continuation, attachment = 0.0, number_stop+measure(number+' '), True
        else:
            value, first, continuation, attachment = formatting_plan(oldtext, measure, size, attachment)
        original = styles.get(p.getAttribute('stylename'))
        s = copy.deepcopy(original) if original is not None else Style(name=prefix+str(i), family='paragraph')
        s.parentNode = None; s.setAttribute('name', prefix+str(i))
        for n in list(s.getElementsByType(TextProperties)):
            n.parentNode.removeChild(n)
        s.addElement(TextProperties(**props))
        existing = s.getElementsByType(ParagraphProperties)
        pp = existing[0] if existing else ParagraphProperties()
        if not existing: s.addElement(pp)
        pp.setAttribute('marginleft', f'{continuation:.4f}pt')
        pp.setAttribute('textindent', f'{first-continuation:.4f}pt')
        pp.setAttribute('autotextindent', 'false')
        pp.setAttribute('textalign', 'left')
        pp.setAttribute('lineheight', line_height)
        if i in attachment_rows:
            for n in list(pp.getElementsByType(TabStops)): pp.removeChild(n)
            stops = TabStops()
            # Tab positions are relative to paragraph left indent in the tested
            # ODT import. Only the number uses a tab; its following space has
            # normal font width. Wrapped text starts at the paragraph indent.
            for pos in (number_stop-continuation,):
                stops.addElement(TabStop(position=f'{pos:.4f}pt',type='left'))
            pp.addElement(stops)
        doc.automaticstyles.addElement(s); p.setAttribute('stylename', s)
        if value != oldtext:
            from draft_odt import set_text
            set_text(p, value)
        for span in p.getElementsByType(Span): span.setAttribute('stylename', ts)
        result.append({'style':s.getAttribute('name'), 'text':value,
                       'first_pt':round(first,4), 'continuation_pt':round(continuation,4),
                       'tabStops':[round(number_stop-continuation,4)] if i in attachment_rows else []})
    return {'font':font_name, 'fontFile':str(font_path), 'size':size, 'lineHeight':line_height, 'paragraphs':result,
            'textProperties':props}


def verify_basic_format(doc, receipt):
    """Recompute effective saved properties, including span overrides, after reopening."""
    from draft_odt import leaf_paragraphs
    styles = {s.getAttribute('name'):s for r in (doc.styles,doc.automaticstyles) for s in r.getElementsByType(Style)}
    def effective(name):
        if name not in styles: return {}
        s=styles[name]; values=effective(s.getAttribute('parentstylename'))
        for c in s.childNodes:
            if hasattr(c, 'attributes'): values.update(c.attributes)
        return values
    def get(values, key):
        return next((v for (ns,k),v in values.items() if k==key), None)
    ps={p.getAttribute('stylename'):p for p in leaf_paragraphs(doc)}
    count=0
    for row in receipt['paragraphs']:
        p=ps[row['style']]; assert teletype.extractText(p)==row['text']
        base=effective(row['style'])
        assert get(base,'margin-left')==f"{row['continuation_pt']:.4f}pt"
        assert abs(float(get(base,'text-indent')[:-2])-(row['first_pt']-row['continuation_pt'])) < .0002
        assert get(base,'text-align')=='left'
        assert get(base,'line-height')==receipt.get('lineHeight', DEFAULT_LINE_HEIGHT)
        if row.get('tabStops'):
            stops=styles[row['style']].getElementsByType(TabStop)
            assert [s.getAttribute('position') for s in stops]==[f'{v:.4f}pt' for v in row['tabStops']]
            assert row['text'].count('\t')==1
            assert re.match(r'^(?:붙임)?\t\d+\. [^ \t]',row['text'])
        for values in [base]+[{**base,**effective(s.getAttribute('stylename'))} for s in p.getElementsByType(Span)]:
            for key in ('font-name','font-name-asian','font-name-complex','font-family','font-family-asian','font-family-complex'):
                assert get(values,key)==receipt['font'], key
            for key in ('font-size','font-size-asian','font-size-complex'):
                assert get(values,key)==f"{receipt['size']:g}pt", key
            assert get(values,'text-scale')=='100%'
            assert get(values,'letter-spacing')=='0pt'
            count+=1
    return {'paragraphs':len(receipt['paragraphs']), 'textSegments':count,
            'savedBasicFormat':'passed', 'renderingChecked':False}
