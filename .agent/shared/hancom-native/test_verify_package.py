"""Legacy helper checks and real upstream inline-control validation in TEMP."""
import hashlib
from pathlib import Path
import tempfile
import unittest
from xml.etree import ElementTree as ET
from zipfile import ZipFile

from hwpx import HwpxDocument
from hwpx.tools import package_validator as validator
from lxml import etree as XML

from verify_package import paragraph_text, verify


class InlineControlTests(unittest.TestCase):
    def test_mixed_text(self):
        paragraph = ET.fromstring('<p><run><t>abc<lineBreak/>def<nbSpace/>g</t></run></p>')
        self.assertEqual(paragraph_text(paragraph), 'abc def g')

    def test_unknown_control_not_guessed(self):
        paragraph = ET.fromstring('<p><run><t>a<unknown/>b</t></run></p>')
        self.assertIsNone(paragraph_text(paragraph))


class PackageInlineControlTests(unittest.TestCase):
    # These are Hancom text positions, independently stated fixture expectations.
    # In particular, an inline tab occupies eight positions, not one character.
    controls = (('lineBreak', 1), ('tab', 8), ('hyphen', 1),
                ('nbSpace', 1), ('fwSpace', 1))
    paragraph_namespace = '{http://www.hancom.co.kr/hwpml/2011/paragraph}'

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='hwpx-inline-validation-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        seed = self.root / 'seed.hwpx'
        document = HwpxDocument.new()
        document.add_paragraph('INLINE_FIXTURE')
        document.save_to_path(str(seed))
        with ZipFile(seed) as archive:
            self.members = [(info, archive.read(info.filename))
                            for info in archive.infolist()]

    def fixture(self, control_name, width, *, overrun=False):
        """Change only a newly generated fixture's text and cached line positions."""
        output = self.root / f'{control_name}-{overrun}.hwpx'
        hp = self.paragraph_namespace
        with ZipFile(output, 'w') as archive:
            for info, payload in self.members:
                if info.filename == 'Contents/section0.xml':
                    section = XML.fromstring(payload)
                    text = next(node for node in section.iter(hp + 't')
                                if node.text == 'INLINE_FIXTURE')
                    text.text = 'abc'
                    control = XML.SubElement(text, hp + control_name)
                    control.tail = 'def'
                    paragraph = text.getparent().getparent()
                    for cache in list(paragraph.findall(hp + 'linesegarray')):
                        paragraph.remove(cache)
                    cache = XML.SubElement(paragraph, hp + 'linesegarray')
                    XML.SubElement(cache, hp + 'lineseg', textpos='0', flags='0')
                    XML.SubElement(cache, hp + 'lineseg',
                                   textpos=str(6 + width + int(overrun)), flags='0')
                    payload = XML.tostring(section, encoding='UTF-8', xml_declaration=True,
                                           standalone=True)
                archive.writestr(info, payload)
        return output

    def verify_unchanged(self, path):
        before = hashlib.sha256(path.read_bytes()).hexdigest()
        original = validator._simple_paragraph_text
        report = verify(path)
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), before)
        self.assertIs(validator._simple_paragraph_text, original)
        self.assertFalse(report['correctionApplied'])
        self.assertNotIn('corrected', report)
        return report

    def test_valid_inline_controls_pass_upstream_without_correction(self):
        for control, width in self.controls:
            with self.subTest(control=control):
                report = self.verify_unchanged(self.fixture(control, width))
                self.assertTrue(report['ok'], report)
                self.assertTrue(report['upstream']['ok'], report)
                self.assertTrue(report['upstream']['validatePackage']['validatorOk'], report)

    def test_real_overruns_fail_upstream_without_correction(self):
        for control, width in self.controls:
            with self.subTest(control=control):
                report = self.verify_unchanged(self.fixture(control, width, overrun=True))
                self.assertFalse(report['ok'], report)
                upstream = report['upstream']
                self.assertFalse(upstream['ok'], report)
                self.assertFalse(upstream['validatePackage']['ok'], report)
                self.assertTrue(upstream['validateDocument']['ok'], report)
                self.assertTrue(upstream['reopen']['ok'], report)
                errors = '\n'.join(upstream['validatePackage']['errors'])
                self.assertIn('stale lineseg', errors)
                self.assertIn(f'beyond text length {6 + width}', errors)


if __name__ == '__main__':
    unittest.main()
