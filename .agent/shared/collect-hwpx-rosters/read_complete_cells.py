"""Read-only content audit: retain inline control tails omitted by map APIs.

Never writes or repacks a document. Public HWPX APIs still own all edits and
open-safety. XML text/controls are read only to check source-content coverage.
"""
from pathlib import Path
import re
import zipfile
import xml.etree.ElementTree as ET

HP = '{http://www.hancom.co.kr/hwpml/2011/paragraph}'


def text_node(node):
    text = node.text or ''
    for child in node:
        if child.tag == HP + 'lineBreak':
            text += '\n'
        elif child.tag == HP + 'tab':
            text += '\t'
        else:
            text += text_node(child)
        text += child.tail or ''
    return text


def cell_text(cell):
    paragraphs = []
    for para in cell.findall('./' + HP + 'subList/' + HP + 'p'):
        parts = [text_node(t) for run in para.findall(HP + 'run') for t in run.findall(HP + 't')]
        paragraphs.append(''.join(parts))
    return '\n'.join(paragraphs).strip()


def complete_map(path, document_map):
    tables = []
    with zipfile.ZipFile(Path(path)) as package:
        sections = sorted((n for n in package.namelist() if re.fullmatch(r'Contents/section\d+\.xml', n)),
                          key=lambda n: int(re.search(r'\d+', n).group()))
        for section in sections:
            root = ET.fromstring(package.read(section))
            for table in root.iter(HP + 'tbl'):
                values = {}
                for row in table.findall(HP + 'tr'):
                    for cell in row.findall(HP + 'tc'):
                        address = cell.find(HP + 'cellAddr')
                        if address is None:
                            raise ValueError('Cell address missing from source audit')
                        key = int(address.attrib['rowAddr']), int(address.attrib['colAddr'])
                        values[key] = cell_text(cell)
                tables.append(values)
    mapped = document_map['tables']['tables']
    if len(mapped) != len(tables):
        raise ValueError('Public map table coverage differs from source audit')
    differences = []
    for table, full in zip(mapped, tables):
        if set(full) != {(c['row'], c['col']) for c in table['cells']}:
            raise ValueError('Public map cell coverage differs from source audit')
        for cell in table['cells']:
            value = full[cell['row'], cell['col']]
            if cell['text'].strip() != value:
                differences.append(dict(table=table['table_index'], row=cell['row'], col=cell['col'],
                                        apiText=cell['text'], completeText=value))
                cell['text'] = value
    return document_map, differences
