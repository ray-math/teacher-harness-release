"""Narrow compatibility correction for python-hwpx 6.3.0 inline text controls.

No document bytes are changed. Keep the upstream report for audit.
"""
from importlib.metadata import version
from hwpx.tools import package_validator as validator
from hwpx_automation.storage import build_hwpx_open_safety_report

def paragraph_text(paragraph):
    pieces=[]
    def content(node):
        if node.text: pieces.append(node.text)
        for child in node:
            if child.tag.rsplit('}',1)[-1].lower() not in {'linebreak','tab','hyphen','nbspace'} or len(child):
                return False
            pieces.append(' ')
            if child.tail:pieces.append(child.tail)
        return True
    for child in paragraph:
        name=child.tag.rsplit('}',1)[-1].lower()
        if name=='linesegarray':continue
        if name!='run':return None
        for run_child in child:
            name=run_child.tag.rsplit('}',1)[-1].lower()
            if name=='t':
                if not content(run_child):return None
            elif name in {'linebreak','tab','hyphen','nbspace'}:pieces.append(' ')
            else:return None
    return ''.join(pieces)

def verify(path):
    upstream=build_hwpx_open_safety_report(path)
    if upstream['ok']:return dict(ok=True,upstream=upstream,correctionApplied=False)
    if version('python-hwpx')!='6.3.0':return dict(ok=False,upstream=upstream,correctionApplied=False)
    original=validator._simple_paragraph_text
    try:
        validator._simple_paragraph_text=paragraph_text
        corrected=build_hwpx_open_safety_report(path)
    finally:validator._simple_paragraph_text=original
    return dict(ok=corrected['ok'],upstream=upstream,corrected=corrected,correctionApplied=True,
                correction='Count inline single-position controls inside hp:t as well as directly inside hp:run; all other validators unchanged')
