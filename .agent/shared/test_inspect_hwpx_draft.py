"""Synthetic read-map tests against the real pinned editor, in TEMP only."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from hwpx import HwpxDocument, table_patch
from inspect_hwpx_draft import inspect
from paragraph_target_preflight import paragraph_records, OPERATIONS


class InspectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hwpx-inspect-")
        self.root = Path(self.temp.name)
        self.source = self.root / "original.hwpx"
        doc = HwpxDocument.new()
        doc.add_paragraph("BEFORE 한글 & <text>")
        table = doc.add_table(2, 2)
        table.merge_cells(0, 0, 0, 1)
        table.set_cell_text(0, 0, "MERGED")
        table.set_cell_text(1, 0, "OUTER")
        inner = table.cell(1, 0).add_table(1, 1)
        inner.set_cell_text(0, 0, "INNER")
        table.set_cell_text(1, 1, "SIBLING")
        doc.add_paragraph("AFTER")
        doc.save_to_path(str(self.source))
        self.sha = hashlib.sha256(self.source.read_bytes()).hexdigest()

    def tearDown(self):
        self.assertEqual(self.sha, hashlib.sha256(self.source.read_bytes()).hexdigest())
        self.temp.cleanup()

    def test_paragraph_coordinates_match_preflight_including_nested_tables(self):
        result = inspect(self.source, paragraph_operation="both", include_cell_paragraphs=True)
        self.assertEqual(result["source_sha256"], self.sha)
        for operation in OPERATIONS:
            actual = [r for r in result["records"] if r.get("operation") == operation]
            expected = paragraph_records(self.source, operation)
            self.assertEqual(len(actual), len(expected))
            for a, b in zip(actual, expected):
                for key in ("paragraph_index", "section_path", "editable"):
                    self.assertEqual(a[key], b[key])
                if b["editable"]:
                    self.assertEqual(a["before"], b["before"])
                    self.assertIn("paraPrIDRef", a["styles"])
                else:
                    self.assertIsNone(a["before"])

    def test_default_omits_duplicate_cell_paragraphs_and_containers(self):
        result = inspect(self.source)
        paras = [r for r in result["records"] if r["kind"] == "paragraph"]
        self.assertTrue(paras)
        self.assertEqual({r["operation"] for r in paras}, {"paragraph_patch"})
        self.assertTrue(all(r["editable"] for r in paras))
        self.assertTrue(all(r["before"] not in ("INNER", "SIBLING", "MERGED", "OUTER") for r in paras))
        self.assertTrue(result["omitted_paragraphs"]["cell_paragraphs"])
        self.assertTrue(result["omitted_paragraphs"]["containers_or_unsupported"])
        body = inspect(self.source, paragraph_operation="set_paragraph_text")
        self.assertEqual({r["operation"] for r in body["records"] if r["kind"] == "paragraph"}, {"set_paragraph_text"})

    def test_unsupported_cell_paragraph_never_looks_like_empty_complete_text(self):
        from hwpx import patch as engine
        original = engine._text_edit_for_paragraph
        def unsupported(payload, text):
            return None if b"SIBLING" in payload else original(payload, text)
        with patch.object(engine, "_text_edit_for_paragraph", side_effect=unsupported) as replacement:
            # preflight checks that the two engine aliases agree.
            with patch("hwpx.body_patch._text_edit_for_paragraph", replacement):
                result = inspect(self.source)
        cell = next(r for r in result["records"] if r["kind"] == "cell" and r["table_index"] == 0 and r["row"] == 1 and r["col"] == 1)
        self.assertFalse(cell["text_complete"])
        self.assertTrue(cell["requires_full_read"])
        self.assertEqual(cell["unsupported_paragraphs"], 1)
        self.assertIn("full read required", cell["text"])
        self.assertEqual(result["unsupported_cells"], 1)

    def test_merged_and_nested_addresses_work_in_real_editor(self):
        result = inspect(self.source)
        cells = [r for r in result["records"] if r["kind"] == "cell"]
        merged = next(r for r in cells if r["text"] == "MERGED")
        inner = next(r for r in cells if r["text"] == "INNER")
        outer = next(r for r in cells if r["text"] == "OUTER\n")
        self.assertEqual((merged["row"], merged["col"], merged["col_span"]), (0, 0, 2))
        self.assertEqual(inner["table_index"], 1)
        self.assertTrue(outer["contains_nested_table"])
        self.assertNotIn("INNER", outer["text"])
        specs = [dict(table_index=r["table_index"], row=r["row"], col=r["col"],
                      section_path=r["section_path"], text="UPDATED_" + r["text"])
                 for r in (merged, inner)]
        # A covered logical address must resolve to the same merged anchor.
        specs[0]["col"] = 1
        output = self.root / "edited.hwpx"
        table_patch.fill_cells(str(self.source), specs, output_path=str(output))
        after = inspect(output)
        text = [r.get("text") for r in after["records"] if r["kind"] == "cell"]
        self.assertIn("UPDATED_MERGED", text)
        self.assertIn("UPDATED_INNER", text)
        self.assertIn("SIBLING", text)
        self.assertEqual(next(r for r in after["records"] if r["kind"] == "table" and r["table_index"] == 1)["parent_table_index"], 0)

    def test_pagination_and_truncation_are_explicit(self):
        complete = inspect(self.source)
        found, offset = [], 0
        while offset is not None:
            page = inspect(self.source, limit=3, offset=offset)
            found.extend(page["records"])
            offset = page["next_offset"]
        self.assertEqual(found, complete["records"])
        small = inspect(self.source, max_text=2)
        self.assertTrue(any(r.get("before_truncated") for r in small["records"]))
        self.assertTrue(any(r.get("text_truncated") for r in small["records"]))

    def test_cli_utf8_and_exclusive_output(self):
        script = Path(__file__).with_name("inspect_hwpx_draft.py")
        command = [sys.executable, "-B", str(script), "--source", str(self.source)]
        result = subprocess.run(command, capture_output=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("한글", result.stdout)
        self.assertTrue(json.loads(result.stdout)["ok"])
        output = self.root / "map.json"
        result = subprocess.run(command + ["--output", str(output)], capture_output=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        before = output.read_bytes()
        result = subprocess.run(command + ["--output", str(output)], capture_output=True, encoding="utf-8")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(before, output.read_bytes())


if __name__ == "__main__":
    unittest.main()
