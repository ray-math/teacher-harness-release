import copy,unittest,tempfile
from pathlib import Path
from zipfile import ZipFile
from verify import validate_table_lineage,check_hash,within,blocks

class GuardTests(unittest.TestCase):
 def setUp(self):
  self.base=[{'rows':[[{'properties':{'cellSpan':{'rowSpan':'1','colSpan':'1'}},'text':'9월'}]]}]
  self.edit={'table':0,'row':0,'cell':0,'before':'9월','after':'9~10월','authorization':'user exact period decision'}
 def test_identical(self):validate_table_lineage(self.base,self.base,[])
 def test_authorized_cell(self):
  new=copy.deepcopy(self.base);new[0]['rows'][0][0]['text']='9~10월';validate_table_lineage(self.base,new,[self.edit])
 def test_unauthorized_text_rejected(self):
  new=copy.deepcopy(self.base);new[0]['rows'][0][0]['text']='12월'
  with self.assertRaises(AssertionError):validate_table_lineage(self.base,new,[])
 def test_geometry_change_rejected(self):
  new=copy.deepcopy(self.base);new[0]['rows'][0][0]['properties']['cellSpan']['colSpan']='2'
  with self.assertRaises(AssertionError):validate_table_lineage(self.base,new,[])
 def test_missing_row_rejected(self):
  with self.assertRaises(AssertionError):validate_table_lineage(self.base,[],[])
 def test_incorrect_before_rejected(self):
  edit={**self.edit,'before':'10월'}
  with self.assertRaises(AssertionError):validate_table_lineage(self.base,self.base,[edit])
 def test_missing_authorization_rejected(self):
  with self.assertRaises(AssertionError):validate_table_lineage(self.base,self.base,[{**self.edit,'authorization':''}])
 def test_hash_and_outside_path_rejected(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'x';p.write_text('changed')
   with self.assertRaises(AssertionError):check_hash(p,'0'*64)
   with self.assertRaises(AssertionError):within(p,Path(d)/'other')
 def test_next_year_subjects_keep_titles_order_and_tables(self):
  with tempfile.TemporaryDirectory() as d:
   p=Path(d)/'next-year.hwpx'
   body=''.join(f'<p><run><t>{title}</t><tbl rowCnt="1" colCnt="1"><tr><tc><cellAddr rowAddr="0" colAddr="0"/><cellSpan rowSpan="1" colSpan="1"/><cellSz width="100" height="50"/><cellMargin left="1"/><subList><p><run><t>{value}</t></run></p></subList></tc></tr></tbl></run></p>' for title,value in [('2027학년도 1학년 국어 계획서','국어 기준'),('2027학년도 1학년 수학 계획서','수학 기준')])
   with ZipFile(p,'w') as package:package.writestr('Contents/section0.xml','<section>'+body+'</section>')
   result=blocks(p)
   self.assertEqual([x['title'] for x in result],['2027학년도1학년국어계획서','2027학년도1학년수학계획서'])
   self.assertEqual([x['tables'][0]['rows'][0][0]['text'] for x in result],['국어기준','수학기준'])
   self.assertEqual(result[0]['tables'][0]['rows'][0][0]['properties']['cellSz'],{'width':'100','height':'50'})
if __name__=='__main__':unittest.main()
