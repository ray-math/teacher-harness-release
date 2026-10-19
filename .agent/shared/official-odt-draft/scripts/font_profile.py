"""Explicit font declarations for NEW generated ODTs, not human-file cleanup."""
from odf.style import DefaultStyle, FontFace, TextProperties

FONT_KEYS = ('fontname', 'fontnameasian', 'fontnamecomplex',
             'fontfamily', 'fontfamilyasian', 'fontfamilycomplex')


def normalize_fonts(doc, font_name='굴림체'):
    # Keep sizes, emphasis, paragraph geometry, field controls and text intact.
    defaults = {s.getAttribute('family') for s in doc.styles.getElementsByType(DefaultStyle)}
    for family in ('paragraph', 'text'):
        if family not in defaults:
            style = DefaultStyle(family=family)
            style.addElement(TextProperties())
            doc.styles.addElement(style)
    for root in (doc.styles, doc.automaticstyles):
        for prop in root.getElementsByType(TextProperties):
            for key in FONT_KEYS:
                prop.setAttribute(key, font_name)
    for child in list(doc.fontfacedecls.childNodes):
        doc.fontfacedecls.removeChild(child)
    doc.fontfacedecls.addElement(FontFace(name=font_name, fontfamily=font_name))


def verify_fonts(doc, font_name='굴림체', font_ref=None):
    ref = font_ref or font_name
    faces = doc.fontfacedecls.getElementsByType(FontFace)
    if len(faces) != 1 or faces[0].getAttribute('name') != ref or faces[0].getAttribute('fontfamily') != font_name:
        raise ValueError('Unexpected font declaration; source fonts remain or font mapping is wrong')
    checked = 0
    for root in (doc.styles, doc.automaticstyles):
        for prop in root.getElementsByType(TextProperties):
            for key in FONT_KEYS:
                expected = ref if key.startswith('fontname') else font_name
                if prop.getAttribute(key) != expected:
                    raise ValueError('Font profile mismatch: ' + key)
            checked += 1
    if not checked:
        raise ValueError('No explicit font properties found')
    return {'font': font_name, 'font_declarations': 1, 'text_property_sets': checked}
