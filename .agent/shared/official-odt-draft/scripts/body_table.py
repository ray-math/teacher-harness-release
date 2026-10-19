"""Build an explicitly scoped new ODF body table with example defaults and overrides."""
import math
import re
from odf import teletype
from odf.style import (Style, TableProperties, TableColumnProperties,
                       TableCellProperties, ParagraphProperties, TextProperties, FontFace)
from odf.table import Table, TableColumn, TableHeaderRows, TableRow, TableCell
from odf.text import P


def item_table_left_mm(marker, item_start_mm, *, font_name='굴림체',
                       size_pt=12, font_file=None):
    """Return the owning item's final punctuation position, relative to body.

    Caller supplies the actual marker start, including paragraph/list indents.
    A circled one-character marker uses its own start. Positions refer to the
    character advance box, not the optical centre of the punctuation ink.
    """
    from basic_format import resolve_font_file, load_measurement_font, DEFAULT_FONT
    pattern=r'(?:\d+\.|[가-힣]\.|\d+\)|[가-힣]\)|\(\d+\)|\([가-힣]\)|[①-⑳㉮-㉻])'
    if not isinstance(marker,str) or not re.fullmatch(pattern,marker):
        raise ValueError('Pass an official item marker such as 가., 1), (가), or ①')
    if isinstance(item_start_mm,bool) or not isinstance(item_start_mm,(int,float)) or not math.isfinite(item_start_mm) or item_start_mm<0:
        raise ValueError('Pass the actual nonnegative item marker start in mm')
    if isinstance(size_pt,bool) or not isinstance(size_pt,(int,float)) or not math.isfinite(size_pt) or not 6<=size_pt<=72:
        raise ValueError('Invalid anchor font size')
    if font_name!=DEFAULT_FONT and not font_file:
        raise ValueError('Alternate item font requires its matching font file')
    font=load_measurement_font(resolve_font_file(font_file),size_pt,font_name)
    prefix=marker[:-1] if marker.endswith(('.',')')) else ''
    return item_start_mm+(font.getlength(prefix)/100)*25.4/72


def build_body_table(doc, name, headers, rows, *, column_widths_mm,
                     column_roles, body_width_mm, left_mm=None, anchor_item=None, gap_pt=6,
                     padding_mm=1.5, font_name='굴림체', size_pt=12, line_height='123%',
                     border='0.5pt solid #000000'):
    """Return a new table; caller selects location and checks adjacent spacing.

    Content stays verbatim. Explicit roles prevent dates/identifiers from being
    guessed as numeric quantities. No existing document nodes are reformatted.
    """
    from basic_format import normalize_line_height
    line_height = normalize_line_height(line_height)
    headers, rows = list(headers), [list(row) for row in rows]
    widths, roles = list(column_widths_mm), list(column_roles)
    count = len(headers)
    if not count or len(widths) != count or len(roles) != count:
        raise ValueError('Headers, widths and roles must have the same nonzero length')
    if any(len(row) != count for row in rows):
        raise ValueError('Every row must match the header column count')
    if any(not isinstance(value, str) for row in [headers]+rows for value in row):
        raise ValueError('Pass explicit display strings; no automatic value conversion')
    alignments = {'short':'center', 'text':'left', 'number':'right'}
    if any(role not in alignments for role in roles):
        raise ValueError('Column role must be short, text or number')
    if anchor_item is not None:
        if left_mm is not None:
            raise ValueError('Choose an item anchor or explicit left_mm, not both')
        if not isinstance(anchor_item,dict) or set(anchor_item)-{'marker','item_start_mm','font_name','size_pt','font_file'} or not {'marker','item_start_mm'}<=set(anchor_item):
            raise ValueError('anchor_item requires marker and item_start_mm')
        left_mm=item_table_left_mm(**anchor_item)
    elif left_mm is None:
        left_mm=0
    numbers = widths + [body_width_mm, left_mm, gap_pt, padding_mm, size_pt]
    if any(isinstance(x, bool) or not isinstance(x, (int,float)) or not math.isfinite(x) for x in numbers):
        raise ValueError('Dimensions must be finite numbers')
    if body_width_mm <= 0 or min(left_mm,gap_pt,padding_mm) < 0 or size_pt <= 0:
        raise ValueError('Invalid width, spacing or font size')
    if any(width <= 2*padding_mm for width in widths):
        raise ValueError('Column must have positive content width after cell padding')
    if sum(widths)+left_mm > body_width_mm+1e-6:
        raise ValueError('Table and left offset exceed the body width')
    if not name or any(t.getAttribute('name') == name for t in doc.getElementsByType(Table)):
        raise ValueError('Use a nonempty unique table name')

    used = {s.getAttribute('name') for root in (doc.styles,doc.automaticstyles)
            for s in root.getElementsByType(Style)}
    prefix = 'BodyTable'
    while any(s.startswith(prefix) for s in used): prefix += 'X'
    def style(suffix, family, *properties):
        item = Style(name=prefix+suffix, family=family)
        for prop in properties: item.addElement(prop)
        doc.automaticstyles.addElement(item)
        return item
    if not any(f.getAttribute('name') == font_name for f in doc.fontfacedecls.getElementsByType(FontFace)):
        doc.fontfacedecls.addElement(FontFace(name=font_name,fontfamily=font_name))
    table_style = style('Table','table',TableProperties(
        width=f'{sum(widths):.6f}mm',align='margins',marginleft=f'{left_mm:.6f}mm',
        marginright=f'{body_width_mm-left_mm-sum(widths):.6f}mm',
        margintop=f'{gap_pt:g}pt',marginbottom=f'{gap_pt:g}pt'))
    cell_style = style('Cell','table-cell',TableCellProperties(
        padding=f'{padding_mm:g}mm',border=border))
    paragraph_styles = {}
    for alignment in set(alignments.values()):
        paragraph_styles[alignment] = style(alignment,'paragraph',
            ParagraphProperties(textalign=alignment,marginleft='0pt',marginright='0pt',
                                textindent='0pt',margintop='0pt',marginbottom='0pt',autotextindent='false',lineheight=line_height),
            TextProperties(fontname=font_name,fontnameasian=font_name,fontnamecomplex=font_name,
                           fontfamily=font_name,fontfamilyasian=font_name,fontfamilycomplex=font_name,
                           fontsize=f'{size_pt:g}pt',fontsizeasian=f'{size_pt:g}pt',fontsizecomplex=f'{size_pt:g}pt',
                           textscale='100%',letterspacing='0pt'))
    table = Table(name=name,stylename=table_style)
    for i,width in enumerate(widths):
        col_style = style(f'Column{i}','table-column',TableColumnProperties(columnwidth=f'{width:g}mm'))
        table.addElement(TableColumn(stylename=col_style))
    def add_row(parent, values, header=False):
        row = TableRow(); parent.addElement(row)
        for value,role in zip(values,roles):
            cell = TableCell(stylename=cell_style); row.addElement(cell)
            p = P(stylename=paragraph_styles['center' if header else alignments[role]])
            teletype.addTextToElement(p,value); cell.addElement(p)
    header_rows = TableHeaderRows(); table.addElement(header_rows)
    add_row(header_rows, headers, header=True)
    for values in rows: add_row(table,values)
    return table
