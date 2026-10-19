"""Small behavioral checks for consequential matching/coverage errors."""
import unittest
from collect import collect, match_records, source_diff, merge_diff
from read_complete_cells import text_node, HP
import xml.etree.ElementTree as ET

class MatchingTests(unittest.TestCase):
    def test_inline_linebreak_tails_are_not_lost(self):
        node=ET.Element(HP+'t')
        node.text='1101 가나다'
        ET.SubElement(node,HP+'lineBreak').tail='1102 라마바'
        ET.SubElement(node,HP+'lineBreak').tail='1103 사아자'
        self.assertEqual(text_node(node),'1101 가나다\n1102 라마바\n1103 사아자')

    def setUp(self):
        self.roster = [{'id':'1102','name':'가나다'}, {'id':'1101','name':'라마바'}]

    def test_sort_and_supplement(self):
        result = match_records('1102 가나다, 라마바', self.roster)
        self.assertEqual([r['id'] for r in result], ['1101','1102'])
        self.assertEqual(result[0]['status'], '학번 보완')

    def test_conflicting_submitted_id_is_never_corrected(self):
        for raw in ['9999 가나다', '1101 가나다', '1102 가나다, 1102 가나다']:
            with self.assertRaises(ValueError):
                match_records(raw, self.roster)

    def test_ambiguous_missing_id(self):
        with self.assertRaises(ValueError):
            match_records('가나다', self.roster+[{'id':'1201','name':'가나다'}])

    def test_combined_file_none_and_missing(self):
        headers={'subject':'과목','teacher':'교사','criteria':'기준','students':'명단'}
        rows=[list(headers.values()), ['과목A','','','1102 가나다'], ['과목B','','','없음']]
        table={'table_index':0,'rows':3,'cols':4,'cells':[dict(row=r,col=c,text=v) for r,row in enumerate(rows) for c,v in enumerate(row)]}
        maps=[('combined.hwpx', {'tables':{'tables':[table]}})]
        config={'headers':headers,'subjects':['과목A','과목B']}
        result=collect(maps,self.roster,config)
        self.assertEqual([len(s['records']) for s in result],[1,0])
        self.assertEqual(result[1]['status'],'명시적 없음')
        table['cells'][-1]['text']=''
        with self.assertRaises(ValueError):
            collect(maps,self.roster,config)

    def test_diff_selects_submitted_row_not_other_template_defaults(self):
        headers={'subject':'과목','teacher':'교사','criteria':'기준','students':'명단'}
        def mapped(rows):
            return {'tables':{'tables':[{'table_index':0,'rows':len(rows),'cols':4,
                    'cells':[dict(row=r,col=c,text=v) for r,row in enumerate(rows) for c,v in enumerate(row)]}]}}
        a=mapped([list(headers.values()),['과목A','담당A','기준A','1102 가나다'],['과목B','옛담당','','']])
        b=mapped([list(headers.values()),['과목A','기본담당','',''],['과목B','담당B','기준B','없음']])
        config={'headers':headers,'subjects':['과목A','과목B']}
        diff=source_diff([('a',a),('b',b)],config)
        subjects=collect([('a',a),('b',b)],self.roster,config)
        self.assertEqual([s['teacher'] for s in subjects],['담당A','담당B'])
        self.assertEqual([s['source'] for s in subjects],['a','b'])
        self.assertEqual(len(diff['submissions']),2)
        current=mapped([list(headers.values()),['과목A','담당A','기준A','1102 가나다,'],['과목B','담당B','기준B','없음']])
        self.assertEqual(merge_diff(current,subjects,config),[])
        # Different records on the same subject must not become a silent union.
        b['tables']['tables'][0]['cells'][7]['text']='1101 라마바'
        with self.assertRaises(ValueError):
            collect([('a',a),('b',b)],self.roster,config)

    def test_diff_rejects_misaligned_rows(self):
        headers={'subject':'과목','teacher':'교사','criteria':'기준','students':'명단'}
        rows=[list(headers.values()),['과목B','','','없음'],['과목A','','','1102 가나다']]
        table={'table_index':0,'rows':3,'cols':4,'cells':[dict(row=r,col=c,text=v) for r,row in enumerate(rows) for c,v in enumerate(row)]}
        with self.assertRaises(ValueError):
            source_diff([('reordered',{'tables':{'tables':[table]}})],{'headers':headers,'subjects':['과목A','과목B']})

if __name__=='__main__':
    unittest.main()
