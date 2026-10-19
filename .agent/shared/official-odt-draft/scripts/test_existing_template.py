"""Baseline selection and preservation regressions; synthetic temporary files only."""
import hashlib
import tempfile
import unittest
from pathlib import Path
from zipfile import ZipFile
from odf.opendocument import OpenDocumentText, load
from odf.style import Style, TextProperties, ParagraphProperties
from odf.text import P, Bookmark, BookmarkStart, BookmarkEnd
from odf import teletype
from draft_odt import create, NeedsInput, SKILL, check_package


class ExistingTemplateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='odt-existing-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.spec = {'title':'새 제목', 'related':[], 'body':['1. 새 본문.']}

    def baseline(self, placeholders=True):
        doc = OpenDocumentText()
        style = Style(name='Original', family='paragraph')
        style.addElement(TextProperties(fontfamily='바탕', fontsize='11pt'))
        style.addElement(ParagraphProperties(lineheight='145%', marginleft='8mm'))
        doc.styles.addElement(style)
        for value in (['원래 고정 문구','{{TITLE}}','{{BODY}}'] if placeholders else ['일반 현재본 내용']):
            doc.text.addElement(P(stylename=style, text=value))
        path = self.root/'baseline.odt'
        doc.save(str(path))
        return path

    def test_missing_template_never_creates_output_even_with_legacy_form(self):
        for form in (None, 'general', 'internal', 'paste'):
            output = self.root/f'{form}.odt'
            with self.assertRaises(NeedsInput):
                create(self.spec, output, form)
            self.assertFalse(output.exists())

    def test_ordinary_current_document_stops_without_rebuilding(self):
        template = self.baseline(False)
        before = template.read_bytes()
        output = self.root/'result.odt'
        with self.assertRaises(NeedsInput):
            create(self.spec, output, template=template)
        self.assertEqual(template.read_bytes(), before)
        self.assertFalse(output.exists())

    def test_source_format_is_not_implicitly_converted(self):
        output = self.root/'result.odt'
        source = self.root/'baseline.hwpx'
        source.write_bytes(b'synthetic source')
        with self.assertRaises(NeedsInput):
            create(self.spec, output, template=source)
        self.assertFalse(output.exists())

    def test_unreadable_odt_requests_valid_baseline_before_output(self):
        source = self.root/'invalid.odt'
        source.write_bytes(b'not an ODT package')
        output = self.root/'result.odt'
        with self.assertRaises(NeedsInput):
            create(self.spec, output, template=source)
        self.assertFalse(output.exists())

    def test_unknown_or_mixed_placeholder_stops_without_output(self):
        for value in ('{{UNSUPPORTED}}', '고정 문구 {{AGENCY}}'):
            template = self.baseline()
            doc = load(str(template))
            doc.text.addElement(P(text=value))
            doc.save(str(template))
            output = self.root/'unsupported.odt'
            with self.assertRaises(NeedsInput):
                create(self.spec, output, template=template)
            self.assertFalse(output.exists())

    def test_approval_fields_are_preserved_and_body_boundaries_remain_paired(self):
        from approval_fields import controls, validate_approval
        template = self.baseline()
        doc = load(str(template))
        paragraphs = doc.text.getElementsByType(P)
        paragraphs[1].addElement(Bookmark(name='CellField1¡제목¡'))
        paragraphs[2].addElement(BookmarkStart(name='NormalField1¡본문¡'))
        paragraphs[2].addElement(BookmarkEnd(name='NormalField1¡본문¡'))
        doc.save(str(template))
        output = self.root/'approval.odt'
        create({**self.spec, 'body':['1. 첫 본문.', '2. 마지막 본문.']}, output, template=template)
        filled = load(str(output))
        self.assertEqual(controls(filled), controls(doc))
        self.assertTrue(validate_approval(filled, doc)['body_field_paired'])

    def test_selected_baseline_preserves_unedited_content_and_package(self):
        template = self.baseline()
        before = template.read_bytes()
        output = self.root/'result.odt'
        receipt = create(self.spec, output, template=template)
        self.assertEqual(template.read_bytes(), before)
        self.assertEqual(receipt['template_sha256'], hashlib.sha256(before).hexdigest())
        with ZipFile(template) as original, ZipFile(output) as filled:
            self.assertEqual(original.namelist(), filled.namelist())
            for name in original.namelist():
                if name != 'content.xml':
                    self.assertEqual(original.read(name), filled.read(name), name)
        doc, texts = check_package(output)
        self.assertEqual(texts, ['원래 고정 문구', '새 제목', '1. 새 본문.  끝.'])
        for p in doc.text.getElementsByType(P):
            self.assertEqual(p.getAttribute('stylename'), 'Original')

    def test_explicit_typography_only_changes_named_replacements(self):
        template = self.baseline()
        output = self.root/'result.odt'
        create({**self.spec, 'typography':{'line_height':'160%'}}, output, template=template)
        doc = load(str(output))
        paragraphs = doc.text.getElementsByType(P)
        fixed = next(p for p in paragraphs if teletype.extractText(p) == '원래 고정 문구')
        self.assertEqual(fixed.getAttribute('stylename'), 'Original')
        styles = {s.getAttribute('name'):s for root in (doc.styles,doc.automaticstyles) for s in root.getElementsByType(Style)}
        for p in paragraphs[1:]:
            st = styles[p.getAttribute('stylename')]
            self.assertEqual(st.getElementsByType(ParagraphProperties)[0].getAttribute('lineheight'), '160%')
            self.assertEqual(st.getElementsByType(TextProperties)[0].getAttribute('fontfamily'), '바탕')
        self.assertEqual(styles['Original'].getElementsByType(ParagraphProperties)[0].getAttribute('lineheight'), '145%')


if __name__ == '__main__':
    unittest.main()
