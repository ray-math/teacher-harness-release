"""Synthetic TEMP-only content gate regressions; no school files."""
import copy
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

import validate_content_contract as gate


def odt(path, value="Alice", phone="", extra=""):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("mimetype", "application/vnd.oasis.opendocument.text")
        z.writestr("content.xml", '<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"><office:body><office:text><text:p>Application 2026</text:p><table:table><table:table-row><table:table-cell><text:p>' + escape(value) + '</text:p></table:table-cell><table:table-cell><text:p>' + escape(phone) + '</text:p></table:table-cell></table:table-row></table:table><text:p>' + escape(extra) + '</text:p></office:text></office:body></office:document-content>')


def xlsx(path, formula=False):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("xl/workbook.xml", '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>')
        z.writestr("xl/_rels/workbook.xml.rels", '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>')
        z.writestr("xl/worksheets/sheet1.xml", '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Alice</t></is></c><c r="B1"><f>1+1</f><v>2</v></c></row></sheetData></worksheet>')


def hwpx_form(path, label="Address", value="", duplicate_label=False):
    cells = []
    for col, text in [(0, label), (0 if duplicate_label else 1, value)]:
        cells.append('<hp:tc><hp:cellAddr rowAddr="0" colAddr="' + str(col) + '"/><hp:subList><hp:p><hp:run><hp:t>' + escape(text) + '</hp:t></hp:run></hp:p></hp:subList></hp:tc>')
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Contents/section0.xml", '<sec xmlns:hp="urn:test"><hp:p><hp:run><hp:tbl><hp:tr>' + ''.join(cells) + '</hp:tr></hp:tbl></hp:run></hp:p></sec>')


class ContentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="content-contract-")
        self.job = Path(self.temp.name)
        (self.job / "wip/docs").mkdir(parents=True)
        (self.job / "inputs.json").write_text(json.dumps({"deliveryCycle": {"id": "cycle", "requestKey": "request"}}))
        self.out = self.job / "wip/docs/result.odt"
        self.source = self.job / "source.xlsx"
        odt(self.out); xlsx(self.source)
        self.contract = {"schemaVersion": "content-contract/v1", "sources": [{"id": "sheet", "path": str(self.source), "sha256": gate.digest(self.source)}],
            "outputs": [{"id": "out", "path": "wip/docs/result.odt", "targetRelativePath": "result.odt"}],
            "assertions": [
                {"id": "name", "output": "out", "locator": {"kind": "cell", "table": 0, "row": 0, "col": 0}, "op": "exact", "sourceRef": {"source": "sheet", "sheet": "Data", "cell": "A1"}},
                {"id": "phone", "output": "out", "locator": {"kind": "cell", "table": 0, "row": 0, "col": 1}, "op": "blank"},
                {"id": "old", "output": "out", "locator": {"kind": "document"}, "op": "absent", "expected": "0000"},
                {"id": "title", "output": "out", "locator": {"kind": "paragraph", "index": 0}, "op": "contains", "expected": "2026", "reason": "User selected year"}]}

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        (self.job / "content-contract.json").write_text(json.dumps(self.contract), encoding="utf-8")

    def validate(self):
        self.save()
        return gate.validate(self.job)

    def cli(self, *args):
        return subprocess.run([sys.executable, "-B", str(Path(gate.__file__)), "--job", str(self.job), *args], capture_output=True, text=True)

    def test_saved_values_and_source_hash(self):
        self.assertTrue(self.validate()["ok"])

    def document_reference(self, suffix):
        form = self.job / ("form" + suffix)
        out = self.job / "wip/docs" / ("result" + suffix)
        writer = hwpx_form if suffix == ".hwpx" else odt
        writer(form, "Address")
        writer(out, "Address", "42 Sample Street")
        self.contract["sources"] = [{"id": "form", "path": str(form), "sha256": gate.digest(form)}]
        self.contract["outputs"] = [{"id": "out", "path": "wip/docs/" + out.name, "targetRelativePath": out.name}]
        locator = {"kind": "cell", "table": 0, "row": 0, "col": 0}
        if suffix == ".hwpx":
            locator["section"] = 0
        self.contract["assertions"] = [{"id": "preserve-label", "output": "out", "locator": locator,
            "op": "exact", "sourceRef": {"source": "form", "locator": copy.deepcopy(locator)}}]
        return form, out, writer

    def test_original_document_label_preserved_or_overwritten(self):
        for suffix in (".hwpx", ".odt"):
            with self.subTest(suffix=suffix):
                form, out, writer = self.document_reference(suffix)
                original_sha = gate.digest(form)
                self.assertTrue(self.validate()["ok"])
                # A valid value placed in the label cell must fail even though
                # the document still contains the intended address text.
                writer(out, "42 Sample Street", "")
                result = self.validate()
                self.assertFalse(result["ok"])
                self.assertEqual([a["id"] for a in result["assertions"] if not a["ok"]], ["preserve-label"])
                self.assertEqual(gate.digest(form), original_sha)

    def test_document_source_invalid_or_missing_locator(self):
        for suffix in (".hwpx", ".odt"):
            self.document_reference(suffix)
            ref = self.contract["assertions"][0]["sourceRef"]
            good = copy.deepcopy(ref["locator"])
            invalid = [None, [], {}, {"kind": "unknown"},
                       {k: v for k, v in good.items() if k != "row"},
                       {**good, "col": 99}, {**good, "col": -1},
                       {**good, "col": True}, {**good, "col": "0"},
                       {**good, "col": 0.0}, {**good, "unexpected": 0}]
            invalid.append({k: v for k, v in good.items() if k != "section"} if suffix == ".hwpx" else {**good, "section": 0})
            for locator in invalid:
                with self.subTest(suffix=suffix, locator=locator):
                    ref["locator"] = locator
                    with self.assertRaises(ValueError): self.validate()

    def test_document_source_ambiguous_and_blank(self):
        form, _, _ = self.document_reference(".hwpx")
        hwpx_form(form, duplicate_label=True)
        self.contract["sources"][0]["sha256"] = gate.digest(form)
        with self.assertRaisesRegex(ValueError, "match exactly once"): self.validate()
        self.document_reference(".hwpx")
        self.contract["assertions"][0]["sourceRef"]["locator"]["col"] = 1
        with self.assertRaisesRegex(ValueError, "Source location is blank"): self.validate()

    def test_source_ref_rejects_mixed_formats(self):
        assertion = self.contract["assertions"][0]
        xlsx_ref = copy.deepcopy(assertion["sourceRef"])
        assertion["sourceRef"]["locator"] = {"kind": "document"}
        with self.assertRaises(ValueError): self.validate()
        self.document_reference(".odt")
        assertion = self.contract["assertions"][0]
        doc_ref = copy.deepcopy(assertion["sourceRef"])
        for ref in ({**doc_ref, "sheet": "Data", "cell": "A1"},
                    {**xlsx_ref, "source": "form"},
                    {**doc_ref, "unexpected": "ignored"}, None, [], {"source": "missing"}):
            with self.subTest(ref=ref):
                assertion["sourceRef"] = ref
                with self.assertRaises(ValueError): self.validate()

    def test_document_source_hash_and_normalization(self):
        form, out, writer = self.document_reference(".odt")
        writer(out, " Address ", "42 Sample Street")
        self.assertFalse(self.validate()["ok"])
        self.contract["assertions"][0]["normalize"] = ["trim"]
        self.assertTrue(self.validate()["ok"])
        writer(form, "Changed label")
        with self.assertRaisesRegex(ValueError, "Source hash"): self.validate()

    def test_invented_phone_and_missing_name(self):
        odt(self.out, "", "010-1234-5678")
        failed = [r["id"] for r in self.validate()["assertions"] if not r["ok"]]
        self.assertEqual(failed, ["name", "phone"])

    def test_residual_example(self):
        odt(self.out, extra="0000 delete instruction")
        self.assertFalse(self.validate()["ok"])

    def test_empty_and_duplicate_assertions(self):
        original = copy.deepcopy(self.contract)
        for assertions in ([], [original["assertions"][0]] * 2):
            self.contract["assertions"] = assertions
            with self.assertRaises(ValueError): self.validate()

    def test_zero_locator_match(self):
        self.contract["assertions"][0]["locator"]["row"] = 99
        with self.assertRaises(ValueError): self.validate()

    def test_missing_file(self):
        self.out.unlink()
        with self.assertRaises(OSError): self.validate()

    def test_source_change(self):
        self.source.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "Source hash"): self.validate()

    def test_uncovered_output(self):
        other = self.job / "wip/docs/other.odt"; odt(other)
        self.contract["outputs"].append({"id": "other", "path": "wip/docs/other.odt", "targetRelativePath": "other.odt"})
        with self.assertRaisesRegex(ValueError, "Every output"): self.validate()

    def test_blank_formula_and_bad_sheet_source(self):
        ref = self.contract["assertions"][0]["sourceRef"]
        for cell in ("C1", "B1"):
            ref["cell"] = cell
            with self.assertRaises(ValueError): self.validate()
        ref.update(sheet="No such sheet", cell="A1")
        with self.assertRaises(ValueError): self.validate()

    def test_explicit_expected_needs_evidence(self):
        a = self.contract["assertions"][0]; a.pop("sourceRef"); a["expected"] = "Alice"
        with self.assertRaises(ValueError): self.validate()
        a["evidence"] = [{"source": "sheet", "location": "Data!A1"}]
        self.assertTrue(self.validate()["ok"])

    def test_normalize_only_explicit(self):
        odt(self.out, " Alice ")
        self.assertFalse(self.validate()["ok"])
        self.contract["assertions"][0]["normalize"] = ["trim"]
        self.assertTrue(self.validate()["ok"])

    def test_missing_stale_tampered_receipt(self):
        self.save()
        self.assertNotEqual(self.cli("--check-existing").returncode, 0)
        self.assertEqual(self.cli().returncode, 0)
        self.assertEqual(self.cli("--check-existing").returncode, 0)
        self.contract["assertions"][3]["reason"] = "Changed decision"; self.save()
        self.assertNotEqual(self.cli("--check-existing").returncode, 0)
        self.assertEqual(self.cli().returncode, 0)
        odt(self.out, extra="Changed but not asserted")
        self.assertNotEqual(self.cli("--check-existing").returncode, 0)
        self.assertEqual(self.cli().returncode, 0)
        receipt = self.job / "wip/receipts/content-validation.json"
        data = json.loads(receipt.read_text()); data["assertions"][0]["actualSha256"] = "fake"
        receipt.write_text(json.dumps(data))
        self.assertNotEqual(self.cli("--check-existing").returncode, 0)

    def test_hwpx_cells_paragraphs_and_repeat_assertion(self):
        path = self.job / "wip/docs/result.hwpx"
        with zipfile.ZipFile(path, "w") as z:
            z.writestr("Contents/section0.xml", '<sec xmlns:hp="urn:test"><hp:p><hp:run><hp:t>Application</hp:t><hp:tbl><hp:tr><hp:tc><hp:cellAddr rowAddr="0" colAddr="0"/><hp:subList><hp:p><hp:run><hp:t>Alice</hp:t></hp:run></hp:p></hp:subList></hp:tc></hp:tr></hp:tbl></hp:run></hp:p><hp:p><hp:run><hp:t>Alice</hp:t></hp:run></hp:p></sec>')
        self.contract["outputs"][0]["path"] = "wip/docs/result.hwpx"
        a = self.contract["assertions"][0]; a["locator"]["section"] = 0
        b = copy.deepcopy(a); b.update(id="consent", locator={"kind": "paragraph", "section": 0, "index": 2})
        self.contract["assertions"] = [a, b]
        self.assertTrue(self.validate()["ok"])
        self.contract["assertions"].append({"id": "parent-text", "output": "out", "locator": {"kind": "document"}, "op": "absent", "expected": "Application"})
        self.assertFalse(self.validate()["ok"])
        content = gate.document(path)[0]["text"]
        self.assertEqual(content.count("Application"), 1)
        self.assertEqual(content.count("Alice"), 2)

    def test_hwpx_space_controls_and_unsupported_controls(self):
        from xml.etree import ElementTree as ET
        value = gate.text_of(ET.fromstring('<p><run><t>old<nbSpace/>example<fwSpace/>tail</t></run></p>'))
        self.assertEqual(value, 'old\u00a0example\u3000tail')
        self.assertEqual(gate.normalize(value, ['collapse_whitespace']), 'old example tail')
        with self.assertRaisesRegex(ValueError, 'Unsupported HWPX text control'):
            gate.text_of(ET.fromstring('<p><run><t>old<hyphen/>example</t></run></p>'))

    def bind_profile(self):
        profile = {"schemaVersion": "content-required-profile/v1",
                   "sourceHashes": {"sheet": gate.digest(self.source)},
                   "requiredOutputs": ["out"], "assertions": copy.deepcopy(self.contract["assertions"])}
        path = self.job / "required-profile.json"
        path.write_text(json.dumps(profile), encoding="utf-8")
        binding = {"path": str(path), "sha256": gate.digest(path)}
        inputs = json.loads((self.job / "inputs.json").read_text())
        inputs["requiredContentProfile"] = binding
        (self.job / "inputs.json").write_text(json.dumps(inputs))
        self.contract["requiredProfile"] = binding
        return path, profile

    def test_required_profile_injects_all_omitted_assertions(self):
        self.bind_profile()
        self.contract["assertions"] = []
        result = self.validate()
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["assertions"]), 4)
        odt(self.out, "Wrong name")
        result = self.validate()
        failed = [a for a in result["assertions"] if not a["ok"]]
        self.assertEqual(failed[0]["id"], "name")
        self.assertEqual(failed[0]["actual"], "Wrong name")
        self.assertEqual(failed[0]["expected"], "Alice")

    def test_required_profile_cannot_be_omitted_overridden_or_changed(self):
        path, profile = self.bind_profile()
        binding = self.contract.pop("requiredProfile")
        with self.assertRaisesRegex(ValueError, "omitted or changed"): self.validate()
        self.contract["requiredProfile"] = binding
        self.contract["assertions"][0]["op"] = "contains"
        with self.assertRaisesRegex(ValueError, "cannot be overridden"): self.validate()
        self.contract["assertions"] = []
        profile["assertions"] = profile["assertions"][1:]
        path.write_text(json.dumps(profile))
        with self.assertRaisesRegex(ValueError, "profile hash changed"): self.validate()

    def test_required_profile_rejects_replaced_source_or_missing_output(self):
        self.bind_profile()
        self.contract["sources"][0]["sha256"] = "a" * 64
        with self.assertRaisesRegex(ValueError, "source missing or changed"): self.validate()
        self.contract["sources"][0]["sha256"] = gate.digest(self.source)
        self.contract["outputs"][0]["id"] = "different"
        with self.assertRaisesRegex(ValueError, "output missing"): self.validate()

    def test_unbound_profile_ref_rejected(self):
        self.contract["requiredProfile"] = {"path": "ignored", "sha256": "a" * 64}
        with self.assertRaisesRegex(ValueError, "bound by intake"): self.validate()

    def test_profile_receipt_becomes_stale_on_profile_change(self):
        path, profile = self.bind_profile()
        self.save()
        self.assertEqual(self.cli().returncode, 0)
        profile["note"] = "Changed"
        path.write_text(json.dumps(profile))
        self.assertNotEqual(self.cli("--check-existing").returncode, 0)

    def numeric_assertion(self, expr, value):
        odt(self.out, value)
        self.contract["assertions"] = [{"id": "calculated", "output": "out",
             "locator": {"kind": "cell", "table": 0, "row": 0, "col": 0},
             "op": "exact", "normalize": ["number"], "expectedExpr": expr}]

    def test_decimal_sum_product_and_malformed_numbers(self):
        expression = {"op": "sum", "args": [
            {"op": "product", "args": [{"literal": "0.1"}, {"literal": "3"}]},
            {"literal": "2,000"}]}
        self.numeric_assertion(expression, "2,000.300원")
        self.assertTrue(self.validate()["ok"])
        odt(self.out, "2,000.4원")
        self.assertFalse(self.validate()["ok"])
        for bad in ("", "2,00.3", "2000 + 0.3", "NaN", "Infinity", "1e3", "총 2000원 추가 3원"):
            odt(self.out, bad)
            with self.subTest(bad=bad), self.assertRaises(ValueError): self.validate()

    def test_expression_reads_actual_hashed_source(self):
        numeric = self.job / "numbers.odt"; odt(numeric, "95", "8", "2")
        self.contract["sources"].append({"id": "numbers", "path": str(numeric), "sha256": gate.digest(numeric)})
        refs = [{"sourceRef": {"source": "numbers", "locator": {"kind": "cell", "table": 0, "row": 0, "col": c}}} for c in [0, 1]]
        expr = {"op": "product", "args": refs + [{"literal": "1000"}, {"literal": "2"}]}
        self.numeric_assertion(expr, "1,520,000원")
        self.assertTrue(self.validate()["ok"])
        odt(numeric, "96", "8", "2")
        with self.assertRaisesRegex(ValueError, "Source hash"): self.validate()

    def test_output_sum_catches_internally_inconsistent_total(self):
        odt(self.out, "2,350,000", "50,000", "2,350,000")
        args = [{"outputRef": {"output": "out", "locator": {"kind": "cell", "table": 0, "row": 0, "col": c}}} for c in [0, 1]]
        self.contract["assertions"] = [{"id": "total", "output": "out", "locator": {"kind": "paragraph", "index": 3},
                                      "op": "exact", "normalize": ["number"], "expectedExpr": {"op": "sum", "args": args}}]
        result = self.validate()
        self.assertFalse(result["ok"])
        self.assertEqual(result["assertions"][0]["expected"], "2400000")
        odt(self.out, "2,350,000", "50,000", "2,400,000")
        self.assertTrue(self.validate()["ok"])

    def test_expression_extraction_date_and_percentage(self):
        expr = {"op": "extract", "arg": {"literal": "Old 24; final 28 students"}, "pattern": r"final (\d+) students", "group": 1}
        self.numeric_assertion(expr, "28명")
        self.assertTrue(self.validate()["ok"])
        self.contract["assertions"][0]["expectedExpr"]["pattern"] = r"(\d+)"
        with self.assertRaisesRegex(ValueError, "exactly once"): self.validate()
        self.numeric_assertion({"op": "product", "args": [{"literal": "0.25"}, {"literal": "100"}]}, "25%")
        self.assertTrue(self.validate()["ok"])
        self.numeric_assertion({"op": "excel_date", "arg": {"literal": "46129"}}, "2026. 4. 17.")
        self.contract["assertions"][0]["normalize"] = ["date"]
        self.assertTrue(self.validate()["ok"])

    def test_actual_extract_does_not_accept_multiple_amounts(self):
        self.numeric_assertion({"literal": "3520000"}, "Amount (￦3,520,000)")
        self.contract["assertions"][0]["actualExtract"] = {"pattern": r"￦([0-9,]+)", "group": 1}
        self.assertTrue(self.validate()["ok"])
        odt(self.out, "Amount ￦3,520,000, other ￦3,520,000")
        with self.assertRaisesRegex(ValueError, "exactly once"): self.validate()

    def test_invalid_expression_shapes_and_depth(self):
        invalid = [{}, {"op": "eval", "args": ["1+1"]}, {"op": "sum", "args": []},
                   {"literal": True}, {"literal": "1", "extra": 2},
                   {"outputRef": {"output": "missing", "locator": {"kind": "document"}}}]
        nested = {"literal": "1"}
        for _ in range(22): nested = {"op": "sum", "args": [nested]}
        invalid.append(nested)
        for expr in invalid:
            self.numeric_assertion(expr, "1")
            with self.subTest(expr=expr), self.assertRaises(ValueError): self.validate()


if __name__ == "__main__":
    unittest.main(verbosity=2)
