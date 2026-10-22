"""Synthetic-only preservation and refusal tests (standard library)."""
import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

import edit_existing_odt as editor

validator_spec = importlib.util.spec_from_file_location(
    'content_validator', Path(__file__).resolve().parents[2] / 'validate_content_contract.py')
validator = importlib.util.module_from_spec(validator_spec)
validator_spec.loader.exec_module(validator)


class ExistingEditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='odt-preserving-edit-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.odt'
        self.output = self.root / 'candidate.odt'
        self.xml = (b'<?xml version="1.0" encoding="UTF-8"?>'
                    b'<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
                    b'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">'
                    b'<office:body><office:text><text:p text:style-name="original">Old &amp; title</text:p>'
                    b'<text:p><text:span text:style-name="bold">mixed</text:span>'
                    b'<text:bookmark text:name="field"/>tail</text:p>'
                    b'<text:p>Old &amp; title</text:p></office:text></office:body></office:document-content>')
        with zipfile.ZipFile(self.source, 'w') as z:
            z.writestr('mimetype', editor.MIME)
            z.writestr('content.xml', self.xml, compress_type=zipfile.ZIP_DEFLATED)
            z.writestr('styles.xml', b'<office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"/>')
            z.writestr('META-INF/manifest.xml', b'<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/><manifest:file-entry manifest:full-path="content.xml"/><manifest:file-entry manifest:full-path="styles.xml"/></manifest:manifest>')
            z.writestr('Pictures/picture.bin', bytes(range(256)))
            z.comment = b'preserve package comment'
        self.original = self.source.read_bytes()
        self.plan = {'source_sha256': editor.sha(self.original),
                     'edits': [{'paragraph': 0, 'before': 'Old & title', 'after': 'New <title> & value'}]}

    def test_preserves_all_unselected_bytes_and_package(self):
        _, edited, receipt = editor.prepare(self.source, self.output, self.plan)
        self.assertFalse(self.output.exists())
        self.assertEqual(edited, self.xml.replace(b'Old &amp; title', b'New &lt;title&gt; &amp; value', 1))
        result = editor.apply(self.source, self.output, self.plan, receipt)
        self.assertEqual(result['status'], 'written')
        self.assertEqual(self.source.read_bytes(), self.original)
        with zipfile.ZipFile(self.source) as before, zipfile.ZipFile(self.output) as after:
            for name in before.namelist():
                self.assertEqual(after.read(name), edited if name == 'content.xml' else before.read(name))
        with self.assertRaises(ValueError):
            editor.apply(self.source, self.output, self.plan, receipt)

    def test_refusal_boundaries(self):
        variants = []
        for key, value in [('paragraph', 1), ('paragraph', -1), ('paragraph', True),
                           ('before', 'wrong'), ('after', 'two  spaces'), ('after', '\nnew')]:
            plan = copy.deepcopy(self.plan)
            plan['edits'][0][key] = value
            variants.append(plan)
        duplicate = copy.deepcopy(self.plan)
        duplicate['edits'] *= 2
        variants += [duplicate, {**self.plan, 'source_sha256': 'wrong'}]
        for plan in variants:
            with self.subTest(plan=plan), self.assertRaises(ValueError):
                editor.prepare(self.source, self.output, plan)
            self.assertFalse(self.output.exists())
        with self.assertRaises(ValueError):
            editor.apply(self.source, self.output, self.plan, {})
        with self.assertRaises(ValueError):
            editor.prepare(self.source, self.source, self.plan)

    def test_receipt_bound_to_plan_and_output(self):
        _, _, receipt = editor.prepare(self.source, self.output, self.plan)
        plan = copy.deepcopy(self.plan)
        plan['edits'][0]['after'] = 'Different'
        with self.assertRaises(ValueError):
            editor.apply(self.source, self.output, plan, receipt)
        with self.assertRaises(ValueError):
            editor.apply(self.source, self.root / 'other.odt', self.plan, receipt)
        self.assertFalse(self.output.exists())

    def test_leaf_span_preserves_mixed_runs_and_bookmark(self):
        self.plan['edits'] = [{'node': 2, 'before': 'mixed', 'after': 'changed span'}]
        _, edited, receipt = editor.prepare(self.source, self.output, self.plan)
        self.assertEqual(edited, self.xml.replace(b'>mixed</', b'>changed span</'))
        editor.apply(self.source, self.output, self.plan, receipt)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_fill_empty_leaf_after_clear_and_keep_neighbor_segments(self):
        self.plan['edits'] = [{'node': 2, 'before': 'mixed', 'after': ''},
                              {'paragraph': 0, 'before': 'Old & title', 'after': ''}]
        _, _, receipt = editor.prepare(self.source, self.output, self.plan)
        editor.apply(self.source, self.output, self.plan, receipt)
        cleared = self.output.read_bytes()
        refilled = self.root / 'refilled.odt'
        plan = {'source_sha256': editor.sha(cleared), 'edits': [
            {'node': 2, 'before': '', 'after': 'School <address> & phone'},
            {'paragraph': 0, 'before': '', 'after': 'New title'},
            {'paragraph': 2, 'before': 'Old & title', 'after': 'Changed neighbor'}]}
        _, edited, receipt = editor.prepare(self.output, refilled, plan)
        expected = (self.xml.replace(b'Old &amp; title', b'New title', 1)
                    .replace(b'>mixed</', b'>School &lt;address&gt; &amp; phone</')
                    .replace(b'Old &amp; title', b'Changed neighbor'))
        self.assertEqual(edited, expected)
        editor.apply(self.output, refilled, plan, receipt)
        self.assertEqual(self.output.read_bytes(), cleared)
        with zipfile.ZipFile(self.output) as before, zipfile.ZipFile(refilled) as after:
            for name in before.namelist():
                self.assertEqual(after.read(name), edited if name == 'content.xml' else before.read(name))

    def test_duplicate_alias_address_refused(self):
        self.plan['edits'].append({'node': 0, 'before': 'Old & title', 'after': 'Other'})
        with self.assertRaises(ValueError):
            editor.prepare(self.source, self.output, self.plan)

    def test_cli_dry_run_required_and_reopen(self):
        plan = self.root / 'plan.json'
        receipt = self.root / 'receipt.json'
        plan.write_text(json.dumps(self.plan), encoding='utf-8')
        args = ['--source', str(self.source), '--output', str(self.output),
                '--plan', str(plan), '--receipt', str(receipt)]
        self.assertEqual(editor.main(args + ['--apply']), 2)
        self.assertEqual(editor.main(args + ['--dry-run']), 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(editor.main(args + ['--dry-run']), 2)
        self.assertEqual(editor.main(args + ['--apply']), 0)
        self.assertEqual(editor.main(['--source', str(self.output), '--inspect']), 0)

    def test_unsafe_xml_refused(self):
        with self.assertRaises(ValueError):
            editor.paragraphs(b'<!DOCTYPE x [<!ENTITY test "value">]><x/>')
        for xml in [b'<text:p xmlns:text="' + editor.TEXT.encode() + b'"><![CDATA[value]]></text:p>',
                    b'<text:p xmlns:text="' + editor.TEXT.encode() + b'"/>']:
            self.assertFalse(editor.paragraphs(xml)[0]['editable'])

    def test_existing_nonstandard_mimetype_layout_preserved(self):
        with zipfile.ZipFile(self.source) as z:
            members = [(n, z.read(n)) for n in z.namelist()]
        with zipfile.ZipFile(self.source, 'w') as z:
            for name, data in reversed(members):
                z.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
        self.plan['source_sha256'] = editor.sha(self.source.read_bytes())
        _, _, receipt = editor.prepare(self.source, self.output, self.plan)
        self.assertFalse(receipt['source_mimetype_conventional'])
        editor.apply(self.source, self.output, self.plan, receipt)
        with zipfile.ZipFile(self.output) as z:
            self.assertEqual(z.namelist(), [n for n, _ in reversed(members)])
            self.assertEqual(z.getinfo('mimetype').compress_type, zipfile.ZIP_DEFLATED)

    def test_bad_manifest_and_roots_refused(self):
        with zipfile.ZipFile(self.source) as z:
            members = {n: z.read(n) for n in z.namelist()}
        for target, replacement in [('styles.xml', b'<wrong/>'),
                                    ('META-INF/manifest.xml', members['META-INF/manifest.xml'].replace(b'content.xml', b'missing.xml')),
                                    ('content.xml', b'<wrong/>')]:
            with self.subTest(target=target):
                bad = self.root / 'bad.odt'
                with zipfile.ZipFile(bad, 'w') as z:
                    for n, value in members.items():
                        z.writestr(n, replacement if n == target else value)
                with self.assertRaises(ValueError):
                    editor.package(bad.read_bytes())

    def test_segments_keep_bookmark_spaces_and_runs(self):
        mixed = (b'<text:p><text:span text:style-name="bold"><text:bookmark-start text:name="b"/>'
                 b'1. Related &amp; original<text:bookmark-end text:name="b"/></text:span>'
                 b'<text:span><text:s/><text:s text:c="1"/>a. Name</text:span>'
                 b'<text:span>Attachment <text:s text:c="1"/>1. File <text:span>nested</text:span> tail</text:span></text:p>')
        xml = self.xml.replace(b'<text:p>Old &amp; title</text:p>', mixed)
        with zipfile.ZipFile(self.source) as z:
            members = {n: z.read(n) for n in z.namelist()}
        with zipfile.ZipFile(self.source, 'w') as z:
            for n, data in members.items():
                z.writestr(n, xml if n == 'content.xml' else data)
        segs = editor.text_segments(xml)
        changes = {'1. Related & original': '1. Related & changed', 'a. Name': 'a. New name',
                   'Attachment ': 'Enclosure ', '1. File ': '1. New file ', ' tail': ' new tail'}
        self.plan = {'source_sha256': editor.sha(self.source.read_bytes()), 'edits': [
            {'segment': s['segment'], 'before': s['text'], 'after': changes[s['text']]}
            for s in segs if s['text'] in changes]}
        self.assertEqual(len(self.plan['edits']), 5)
        _, edited, receipt = editor.prepare(self.source, self.output, self.plan)
        expected = xml
        for before, after in changes.items():
            expected = expected.replace(editor.escape(before).encode(), editor.escape(after).encode())
        self.assertEqual(edited, expected)
        editor.apply(self.source, self.output, self.plan, receipt)
        self.plan['edits'][0]['after'] = ' changed boundary'
        with self.assertRaises(ValueError):
            editor.prepare(self.source, self.root / 'bad.odt', self.plan)

    def test_segment_alias_refused_and_empty_value_preserved(self):
        self.plan['edits'].append({'segment': 0, 'before': 'Old & title', 'after': 'Alias'})
        with self.assertRaises(ValueError):
            editor.prepare(self.source, self.output, self.plan)
        self.plan['edits'] = [{'segment': 0, 'before': 'Old & title', 'after': ''}]
        _, edited, receipt = editor.prepare(self.source, self.output, self.plan)
        self.assertEqual(edited, self.xml.replace(b'Old &amp; title', b'', 1))
        editor.apply(self.source, self.output, self.plan, receipt)

    def test_clear_mixed_segment_and_edit_later_address(self):
        segments = editor.text_segments(self.xml)
        self.plan['edits'] = [
            {'segment': s['segment'], 'before': s['text'], 'after': '' if s['text'] == 'tail' else 'Later value'}
            for s in segments if s['text'] == 'tail' or s['segment'] == segments[-1]['segment']]
        _, edited, receipt = editor.prepare(self.source, self.output, self.plan)
        expected = self.xml.replace(b'/>tail', b'/>').replace(b'<text:p>Old &amp; title</text:p>', b'<text:p>Later value</text:p>')
        self.assertEqual(edited, expected)
        editor.apply(self.source, self.output, self.plan, receipt)

    def inspect_body(self, body):
        xml = self.xml[:self.xml.index(b'<office:text>') + len(b'<office:text>')]
        xml += body.encode() + b'</office:text></office:body></office:document-content>'
        xml = xml.replace(b'<office:document-content ', (
            '<office:document-content xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
        ).encode(), 1)
        with zipfile.ZipFile(self.source) as archive:
            members = {n: archive.read(n) for n in archive.namelist()}
        with zipfile.ZipFile(self.source, 'w') as archive:
            for name, data in members.items():
                archive.writestr(name, xml if name == 'content.xml' else data)
        original = self.source.read_bytes()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(editor.main(['--source', str(self.source), '--inspect']), 0)
        self.assertEqual(self.source.read_bytes(), original)
        result = json.loads(out.getvalue())
        self.assertEqual(result['source_sha256'], editor.sha(original))
        # Existing addresses, text and editability remain exactly the same.
        self.assertEqual([{k: v for k, v in item.items() if k != 'context'}
                          for item in result['paragraphs']],
                         [{k: item[k] for k in ('paragraph', 'text', 'editable')}
                          for item in editor.paragraphs(xml)])
        self.assertEqual([{k: v for k, v in item.items() if k != 'context'}
                          for item in result['nodes']],
                         [{'node': item['paragraph'], 'text': item['text'], 'editable': item['editable']}
                          for item in editor.paragraphs(xml, node_mode=True)])
        self.assertEqual([{k: v for k, v in item.items() if k != 'context'}
                          for item in result['segments']],
                         [{k: item[k] for k in ('segment', 'node', 'text', 'editable')}
                          for item in editor.text_segments(xml)])
        return xml, result

    def assert_validator_context(self, result):
        records = validator.document(self.source)
        for group in ('paragraphs', 'nodes', 'segments'):
            for item in result[group]:
                context = item['context']
                for locator in ([context['paragraph']] if context['paragraph'] else []) + context['cells']:
                    matches = [record for record in records if record['locator'] == locator]
                    self.assertEqual(len(matches), 1, locator)
                    # Mixed nodes concatenate only direct character data, which
                    # need not be contiguous in the validator's complete text.
                    if item['editable']:
                        self.assertIn(item['text'], matches[0]['text'])

    def test_inspect_paragraph_span_and_segment_context(self):
        _, result = self.inspect_body(
            '<text:h>Heading</text:h><text:p>Before<text:span>'
            '<text:bookmark text:name="x"/>Inner<text:span>Nested</text:span>'
            'Tail</text:span>After</text:p><text:p/><text:p></text:p>')
        self.assertEqual([n['context']['paragraph']['index'] for n in result['nodes']],
                         [0, 1, 1, 1, 2, 3])
        self.assertEqual([s['context']['paragraph']['index'] for s in result['segments']],
                         [0, 1, 1, 1, 1, 1])
        self.assertTrue(all(n['context']['cells'] == [] for n in result['nodes']))
        self.assert_validator_context(result)

    def test_inspect_merged_repeated_and_nested_table_context(self):
        _, result = self.inspect_body(
            '<text:p>Outside</text:p><table:table><table:table-header-rows>'
            '<table:table-row><table:table-cell table:number-columns-spanned="2" '
            'table:number-rows-spanned="2"><text:p><text:span>Merged</text:span></text:p>'
            '</table:table-cell><table:covered-table-cell/></table:table-row>'
            '</table:table-header-rows><table:table-row><table:covered-table-cell/>'
            '<table:covered-table-cell/></table:table-row>'
            '<table:table-row-group><table:table-rows>'
            '<table:table-row table:number-rows-repeated="2">'
            '<table:table-cell table:number-columns-repeated="2"><text:p>Repeated</text:p>'
            '</table:table-cell><table:table-cell><text:p>Outer</text:p>'
            '<table:table><table:table-row><table:table-cell><text:p><text:span>'
            'Nested</text:span></text:p></table:table-cell></table:table-row></table:table>'
            '</table:table-cell></table:table-row></table:table-rows>'
            '</table:table-row-group></table:table><table:table><table:table-row>'
            '<table:table-cell><text:p>Last</text:p></table:table-cell>'
            '</table:table-row></table:table><text:p>After</text:p>')
        contexts = {n['text']: n['context'] for n in result['nodes'] if n['text']}
        cell = lambda table, row, col: {'kind': 'cell', 'table': table, 'row': row, 'col': col}
        self.assertEqual(contexts['Merged']['cells'], [cell(0, 0, 0)])
        self.assertEqual(contexts['Repeated']['cells'],
                         [cell(0, r, c) for r in (2, 3) for c in (0, 1)])
        self.assertEqual(contexts['Nested']['cells'],
                         [cell(0, 2, 2), cell(0, 3, 2), cell(1, 0, 0)])
        self.assertEqual(contexts['Last']['cells'], [cell(2, 0, 0)])
        self.assertEqual(contexts['After']['cells'], [])
        self.assertEqual(contexts['Nested']['paragraph'], {'kind': 'paragraph', 'index': 4})
        self.assert_validator_context(result)

    def test_inspect_unsupported_repetition_does_not_change_editing(self):
        for repetition in ('10001', '0', '-1', 'invalid'):
            with self.subTest(repetition=repetition):
                xml, result = self.inspect_body(
                    '<table:table><table:table-row table:number-rows-repeated="' + repetition + '">'
                    '<table:table-cell><text:p>Value</text:p></table:table-cell>'
                    '</table:table-row></table:table>')
                context = result['nodes'][0]['context']
                self.assertEqual(context['paragraph'], {'kind': 'paragraph', 'index': 0})
                self.assertEqual(context['cells'], [])
                self.assertEqual(context['cell_context_status'], 'unsupported')
                plan = {'source_sha256': result['source_sha256'],
                        'edits': [{'node': 0, 'before': 'Value', 'after': 'Changed'}]}
                _, edited, _ = editor.prepare(self.source, self.output, plan)
                self.assertEqual(edited, xml.replace(b'>Value<', b'>Changed<'))

    def test_inspect_large_repeat_product_and_unsupported_rows(self):
        for body in (
            '<table:table><table:table-row table:number-rows-repeated="101">'
            '<table:table-cell table:number-columns-repeated="100"><text:p>Value</text:p>'
            '</table:table-cell></table:table-row></table:table>',
            '<table:table><table:unknown-wrapper><table:table-row>'
            '<table:table-cell><text:p>Value</text:p></table:table-cell>'
            '</table:table-row></table:unknown-wrapper></table:table>',
        ):
            with self.subTest(body=body):
                _, result = self.inspect_body(body)
                for group in ('paragraphs', 'nodes', 'segments'):
                    self.assertEqual(result[group][0]['context']['cells'], [])
                    self.assertEqual(result[group][0]['context']['cell_context_status'], 'unsupported')


if __name__ == '__main__':
    unittest.main()
