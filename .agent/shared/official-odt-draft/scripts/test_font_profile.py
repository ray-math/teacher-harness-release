"""Offline regression checks; creates synthetic ODTs only in a temporary directory."""
import tempfile
import unittest
from pathlib import Path
from odf.opendocument import load
from odf.style import FontFace, DefaultStyle, TextProperties, ParagraphProperties, Style
from odf.text import P, Span
from odf import teletype
from draft_odt import create, SKILL, check_package
from font_profile import verify_fonts
from paste_odt import verify_paste, create_paste


class FontProfileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='odt-font-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def paste(self):
        spec = {'title':'검사', 'blocks':[
            '1. 관련: 00고-0000(0000. 0. 0.)',
            {'text':'2. 내용 ABC 123', 'bold':True},
            {'table':{'headers':['구분','내용'], 'rows':[['검사','ABC 123']],
                      'column_widths_mm':[30,130], 'column_roles':['short','text'],
                      'anchor_item':{'marker':'1)', 'item_start_mm':4}}},
            '', '붙임  1. 검사 자료 1부.', '      2. 참고 자료 1부.  끝.']}
        path=self.root/'paste.odt'
        create_paste(spec,path)
        return load(str(path))

    def test_paste_mixed_scripts_table_emphasis_attachments(self):
        doc=self.paste()
        verify_paste(doc)
        paragraphs=doc.text.getElementsByType(P)
        texts=[teletype.extractText(p) for p in paragraphs]
        self.assertIn('ABC 123',texts)
        bold=next(p for p in paragraphs if teletype.extractText(p)=='2. 내용 ABC 123')
        self.assertEqual(bold.getElementsByType(Span)[0].getAttribute('stylename'),'CleanBold')
        index=next(i for i,t in enumerate(texts) if t.startswith('붙임'))
        self.assertEqual(texts[index-1],'')
        self.assertIn('1. 검사 자료',texts[index])
        self.assertIn('2. 참고 자료',texts[index+1])
        self.assertNotIn('1.\t',texts[index])

    def test_reject_hidden_font_declaration(self):
        doc=self.paste()
        doc.fontfacedecls.addElement(FontFace(name='Legacy',fontfamily='HY신명조'))
        with self.assertRaises(ValueError):verify_paste(doc)

    def test_reject_misleading_font_mapping(self):
        doc=self.paste()
        doc.fontfacedecls.getElementsByType(FontFace)[0].setAttribute('fontfamily','HY신명조')
        with self.assertRaises(ValueError):verify_paste(doc)

    def test_reject_default_western_size(self):
        doc=self.paste()
        default=doc.styles.getElementsByType(DefaultStyle)[0]
        default.getElementsByType(TextProperties)[0].setAttribute('fontsize','10pt')
        with self.assertRaises(ValueError):verify_paste(doc)

    def test_assets_and_full_draft_routes(self):
        spec={'title':'검사', 'body':['2. 확인합니다.'],
              'attachments':[{'name':'검사 자료','quantity':'1부'}, {'name':'참고 자료','quantity':'1부'}]}
        for form in ('general','internal'):
            with self.subTest(form=form):
                verify_fonts(load(str(SKILL/'assets'/(form+'.odt'))))
                path=self.root/(form+'.odt')
                receipt=create(spec,path,template=SKILL/'assets'/(form+'.odt'))
                verify_fonts(check_package(path)[0])
                self.assertFalse(receipt['portal_import_verified'])

    def test_requested_line_height_survives_all_new_draft_routes(self):
        spec={'title':'간격검사', 'recipient':'내부결재', 'related':[],
              'body':['2. 본문 간격 확인.'], 'typography':{'line_height':'160%'},
              'attachments':[{'name':'간격 자료','quantity':'1부'}]}
        for form in ('general','internal'):
            with self.subTest(form=form):
                path=self.root/(form+'-spacing.odt')
                create(spec,path,template=SKILL/'assets'/(form+'.odt'))
                doc=check_package(path)[0]
                styles={s.getAttribute('name'):s for r in (doc.styles,doc.automaticstyles)
                        for s in r.getElementsByType(Style)}
                checked=[]
                for paragraph in doc.text.getElementsByType(P):
                    text=teletype.extractText(paragraph)
                    if text in {'간격검사','내부결재','2. 본문 간격 확인.'} or text.startswith('붙임'):
                        props=styles[paragraph.getAttribute('stylename')].getElementsByType(ParagraphProperties)
                        self.assertEqual(props[0].getAttribute('lineheight'),'160%')
                        checked.append(text)
                self.assertIn('간격검사',checked)
                self.assertIn('2. 본문 간격 확인.',checked)
                if form=='general':self.assertIn('내부결재',checked)
        paste={'title':'간격검사','typography':{'line_height':'160%'},'blocks':[
            '1. 본문 간격 확인.',
            {'table':{'headers':['항목'],'rows':[['표 간격 확인']],
                      'column_widths_mm':[160],'column_roles':['text']}},
            '2. 확인 종료.']}
        path=self.root/'paste-spacing.odt'
        create_paste(paste,path)
        doc=check_package(path)[0]
        verify_paste(doc,line_height='160%')
        # This validator includes defaults, the leading guard, body and table styles.
        with self.assertRaises((ValueError,AssertionError)):verify_paste(doc)

    def test_invalid_line_height_is_rejected_before_output(self):
        for form in ('general','internal','paste'):
            for index,value in enumerate(('0%','-10%','nan%','160pt',160,None)):
                with self.subTest(form=form,value=value):
                    path=self.root/f'{form}-invalid-{index}.odt'
                    with self.assertRaises(ValueError):
                        spec = {'title':'검사','body':['2. 검사합니다.'], 'typography':{'line_height':value}}
                        if form == 'paste':
                            create_paste(spec,path)
                        else:
                            create(spec,path,template=SKILL/'assets'/(form+'.odt'))
                    self.assertFalse(path.exists())


if __name__=='__main__':unittest.main()
