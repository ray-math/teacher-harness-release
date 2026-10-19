"""Maintenance-only synthetic paste experiment; never a workflow template fallback."""
import hashlib
from pathlib import Path
from odf.opendocument import OpenDocumentText
from odf.style import Style, DefaultStyle, FontFace, TextProperties, ParagraphProperties, PageLayout, PageLayoutProperties, MasterPage
from odf.text import P, Span
from odf import teletype
from basic_format import apply_basic_format, normalize_line_height
from body_table import build_body_table


def create_paste(data, output):
    from draft_odt import body_lines, check_package, leaf_paragraphs, clear
    allowed={'title','agency','recipient','via','sender','related','body','attachments','typography','blocks'}
    if set(data)-allowed:raise ValueError('Unknown paste input field')
    output=Path(output).resolve()
    if output.suffix.lower()!='.odt' or output.exists():raise ValueError('Choose a new .odt path; never overwrite')
    typo=data.get('typography',{})
    if set(typo)-{'font_name','size','line_height'} or typo.get('font_name','굴림체')!='굴림체' or typo.get('size',12)!=12:
        raise ValueError('Portal profile uses GulimChe 12pt; select a separate workflow for other typography')
    line_height=normalize_line_height(typo.get('line_height','123%'))
    if 'blocks' in data:
        if any(k in data for k in ('body','related','attachments')):raise ValueError('Use blocks OR body/related/attachments')
        blocks=data['blocks']
    else:blocks=body_lines(data)
    if not isinstance(blocks,list) or not blocks:raise ValueError('Nonempty blocks required')
    d=OpenDocumentText()
    props=dict(fontname='GulimChe',fontnameasian='GulimChe',fontnamecomplex='GulimChe',
               fontfamily='굴림체',fontfamilyasian='굴림체',fontfamilycomplex='굴림체',
               fontsize='12pt',fontsizeasian='12pt',fontsizecomplex='12pt',
               fontweight='normal',fontweightasian='normal',fontweightcomplex='normal',
               fontstyle='normal',fontstyleasian='normal',fontstylecomplex='normal',textscale='100%',letterspacing='0pt')
    pp=dict(lineheight=line_height,textalign='left',marginleft='0pt',marginright='0pt',textindent='0pt',margintop='0pt',marginbottom='0pt')
    for family in ('paragraph','text'):
        default=DefaultStyle(family=family);default.addElement(TextProperties(**props))
        if family=='paragraph':default.addElement(ParagraphProperties(**pp))
        d.styles.addElement(default)
    base=Style(name='Standard',displayname='바탕글',family='paragraph')
    base.addElement(TextProperties(**props));base.addElement(ParagraphProperties(**pp));d.styles.addElement(base)
    for name,bold in [('CleanText',False),('CleanBold',True)]:
        s=Style(name=name,family='text');pr=dict(props)
        if bold:pr.update(fontweight='bold',fontweightasian='bold',fontweightcomplex='bold')
        s.addElement(TextProperties(**pr));d.styles.addElement(s)
    layout=PageLayout(name='Page');layout.addElement(PageLayoutProperties(pagewidth='210mm',pageheight='297mm',margintop='20mm',marginbottom='20mm',marginleft='20mm',marginright='15mm',printorientation='portrait'))
    d.automaticstyles.addElement(layout);d.masterstyles.addElement(MasterPage(name='Default',pagelayoutname=layout))
    guard=P(stylename=base);d.text.addElement(guard)
    paragraphs=[];bold_ids=set();neighbors=[];last=None
    for i,block in enumerate(blocks):
        if isinstance(block,str) or (isinstance(block,dict) and 'text' in block):
            if isinstance(block,dict) and (set(block)-{'text','bold'} or not isinstance(block.get('bold',False),bool)):raise ValueError('Text block supports text and boolean bold')
            value=block if isinstance(block,str) else block['text']
            if not isinstance(value,str) or '\n' in value or '\r' in value:raise ValueError('Use one text block per paragraph')
            p=P(stylename=base);sp=Span(stylename='CleanText');teletype.addTextToElement(sp,value);p.addElement(sp)
            d.text.addElement(p);paragraphs.append(p)
            if isinstance(block,dict) and block.get('bold'):bold_ids.add(id(p))
            if last is not None and last.qname!=P().qname:neighbors.append((p,'margintop'))
            last=p
        elif isinstance(block,dict) and set(block)=={'table'}:
            spec=block['table'];required={'headers','rows','column_widths_mm','column_roles'}
            if not isinstance(spec,dict) or not required<=set(spec) or set(spec)-required-{'anchor_item','left_mm'}:raise ValueError('Table requires explicit contents, widths, roles and optional owner anchor')
            t=build_body_table(d,f'Table{i}',body_width_mm=175,gap_pt=0,line_height=line_height,**spec)
            if last is not None and last.qname==P().qname:neighbors.append((last,'marginbottom'))
            d.text.addElement(t);last=t
        else:raise ValueError('Unsupported block; do not silently flatten images or merged tables')
    if not paragraphs or not teletype.extractText(paragraphs[0]).strip():raise ValueError('First supplied paragraph must have text; one guard is added automatically')
    apply_basic_format(d,paragraphs,line_height=line_height)
    styles={s.getAttribute('name'):s for r in (d.styles,d.automaticstyles) for s in r.getElementsByType(Style)}
    for p,key in neighbors:styles[p.getAttribute('stylename')].getElementsByType(ParagraphProperties)[0].setAttribute(key,'6pt')
    for s in styles.values():
        if s.getAttribute('family') not in ('paragraph','text'):continue
        pr=s.getElementsByType(TextProperties)
        if not pr:s.addElement(TextProperties(**props))
        else:
            for key,value in props.items():
                if key.startswith('fontweight') and s.getAttribute('name')=='CleanBold':value='bold'
                pr[0].setAttribute(key,value)
        if s.getAttribute('family')=='paragraph' and s.getAttribute('name')!='Standard':s.setAttribute('parentstylename','Standard')
    for p in leaf_paragraphs(d):
        if p is guard:continue
        spans=p.getElementsByType(Span);style='CleanBold' if id(p) in bold_ids else 'CleanText'
        if spans:
            for sp in spans:sp.setAttribute('stylename',style)
        else:
            value=teletype.extractText(p);clear(p);sp=Span(stylename=style);teletype.addTextToElement(sp,value);p.addElement(sp)
    for face in list(d.fontfacedecls.childNodes):d.fontfacedecls.removeChild(face)
    d.fontfacedecls.addElement(FontFace(name='GulimChe',fontfamily='굴림체',fontfamilygeneric='modern',fontpitch='fixed'))
    expected=[teletype.extractText(p) for p in leaf_paragraphs(d)]
    output.parent.mkdir(parents=True,exist_ok=True)
    with output.open('xb') as stream:d.save(stream)
    reopened,texts=check_package(output);assert texts==expected
    return {'path':str(output),'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'mode':'paste',
            'checks':verify_paste(reopened,line_height=line_height),'textRoundTrip':True,'rendering_checked':False,
            'portalPaste':'not executed; first paragraph needs the leading boundary retained',
            'copyInstruction':'Ctrl+A/Ctrl+C including the first empty paragraph. Paste and retain that blank: removing it can restore the first-paragraph font problem.'}


def verify_paste(doc, *, line_height='123%'):
    line_height=normalize_line_height(line_height)
    from draft_odt import leaf_paragraphs
    from font_profile import verify_fonts
    verify_fonts(doc, '굴림체', 'GulimChe')
    defaults={s.getAttribute('family'):s for s in doc.styles.getElementsByType(DefaultStyle)}
    for family in ('paragraph','text'):
        if family not in defaults:raise ValueError('Missing default style: ' + family)
        pr=defaults[family].getElementsByType(TextProperties)
        if len(pr)!=1:raise ValueError('Missing/ambiguous default text properties')
        for key in ('fontsize','fontsizeasian','fontsizecomplex'):
            if pr[0].getAttribute(key)!='12pt':raise ValueError('Default font size mismatch')
        if family=='paragraph' and defaults[family].getElementsByType(ParagraphProperties)[0].getAttribute('lineheight')!=line_height:
            raise ValueError('Default line spacing mismatch')
    for root in (doc.styles,doc.automaticstyles):
        for pr in root.getElementsByType(TextProperties):
            if pr.getAttribute('textscale')!='100%' or pr.getAttribute('letterspacing')!='0pt':
                raise ValueError('Character scale or spacing mismatch')
    faces=doc.fontfacedecls.getElementsByType(FontFace)
    assert len(faces)==1 and faces[0].getAttribute('name')=='GulimChe'
    elements=[n for n in doc.text.childNodes if hasattr(n,'qname')]
    assert elements[0].qname==P().qname and teletype.extractText(elements[0])==''
    assert elements[1].qname==P().qname and teletype.extractText(elements[1]).strip()
    styles={s.getAttribute('name'):s for r in (doc.styles,doc.automaticstyles) for s in r.getElementsByType(Style)}
    for s in styles.values():
        seen=set();n=s
        while n.getAttribute('parentstylename'):
            key=n.getAttribute('parentstylename');assert key in styles and key not in seen
            seen.add(key);n=styles[key]
        if s.getAttribute('family') in ('paragraph','text'):
            props=s.getElementsByType(TextProperties)[0]
            for key in ('fontname','fontnameasian','fontnamecomplex'):assert props.getAttribute(key)=='GulimChe'
            for key in ('fontsize','fontsizeasian','fontsizecomplex'):assert props.getAttribute(key)=='12pt'
        if s.getAttribute('family')=='paragraph':assert s.getElementsByType(ParagraphProperties)[0].getAttribute('lineheight')==line_height
    for p in leaf_paragraphs(doc):
        assert p.getAttribute('stylename') in styles
        for sp in p.getElementsByType(Span):assert sp.getAttribute('stylename') in styles
    return ['ODT package/reopen','exactly one leading empty paragraph','one font face',
            'explicit font/size/'+line_height,'resolved acyclic parent styles','paragraph/span references']
