import unittest
from xml.etree import ElementTree as ET
from hwpx.tools import package_validator as v
from verify_package import paragraph_text

class InlineControlTests(unittest.TestCase):
    def test_mixed_text(self):
        p=ET.fromstring('<p><run><t>abc<lineBreak/>def<nbSpace/>g</t></run></p>')
        self.assertEqual(paragraph_text(p),'abc def g')
    def test_unknown_control_not_guessed(self):
        self.assertIsNone(paragraph_text(ET.fromstring('<p><run><t>a<unknown/>b</t></run></p>')))
    def test_real_overrun_still_fails(self):
        old=v._simple_paragraph_text
        try:
            v._simple_paragraph_text=paragraph_text
            for position,expected in [(4,False),(5,True)]:
                root=ET.fromstring(f'<sec><p><run><t>abc<lineBreak/></t></run><linesegarray><lineseg textpos="{position}"/></linesegarray></p></sec>')
                issues=[];v._check_line_seg_text_positions(issues,'Contents/section0.xml',root)
                self.assertEqual(any('stale lineseg' in str(x) for x in issues),expected)
        finally:v._simple_paragraph_text=old

if __name__=='__main__':unittest.main()
