"""TEMP-only paragraph coordinate and adapter regressions using the pinned runtime."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from hwpx import HwpxDocument
import paragraph_target_preflight as gate
import run_hwpx_edit_plan as adapter
import validate_content_contract as content


class ParagraphPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="paragraph-preflight-")
        self.root = Path(self.temp.name)
        self.source = self.root / "synthetic.hwpx"
        doc = HwpxDocument.new()
        doc.add_paragraph("BEFORE_TABLE")
        table = doc.add_table(1, 2)
        table.set_cell_text(0, 0, "CELL_ZERO")
        table.set_cell_text(0, 1, "CELL_ONE")
        doc.add_paragraph("AFTER_TABLE & 한글")
        doc.add_paragraph("UNRELATED")
        doc.save_to_path(str(self.source))
        self.sha = hashlib.sha256(self.source.read_bytes()).hexdigest()
        self.job = self.root / "job"
        self.run = self.job / "wip/receipts/test"
        self.run.mkdir(parents=True)
        (self.job / "inputs.json").write_text(json.dumps({"deliveryCycle": {"requireContentValidation": True}}))
        self.operation = "paragraph_patch"
        self.select()

    def tearDown(self):
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), self.sha)
        self.temp.cleanup()

    def select(self):
        row = next(r for r in gate.paragraph_records(self.source, self.operation) if r["before"] == "AFTER_TABLE & 한글")
        target = {k: row[k] for k in ("section_path", "paragraph_index", "before")}
        self.contract = dict(source_sha256=self.sha, targets=[target])
        item = dict(section_path=row["section_path"], text="UPDATED")
        if self.operation == "paragraph_patch":
            item["paragraph_index"] = row["paragraph_index"]
            step = dict(id="edit", op="paragraph_patch", args=dict(patches=[item]))
        else:
            item.update(op="set_paragraph_text", index=row["paragraph_index"])
            step = dict(id="edit", op="apply_body_ops", args=dict(ops=[item]))
        self.plan = dict(schemaVersion="hwpx.edit-plan/v1", source=str(self.source),
                         output=str(self.job / "wip/result.hwpx"), steps=[step])

    def validate(self):
        return gate.validate_job(self.job, self.source, self.plan, self.contract, self.sha)

    def test_correct_before_both_engines(self):
        for operation in gate.OPERATIONS:
            self.operation = operation
            self.select()
            self.assertEqual(self.validate()["status"], "passed")

    def test_three_coordinate_systems_differ(self):
        flat = gate.paragraph_records(self.source, "paragraph_patch")
        direct = gate.paragraph_records(self.source, "set_paragraph_text")
        tree = content.document(self.source)
        a = next(r["paragraph_index"] for r in flat if r["before"] == "AFTER_TABLE & 한글")
        b = next(r["paragraph_index"] for r in direct if r["before"] == "AFTER_TABLE & 한글")
        c = next(r["locator"]["index"] for r in tree if r["locator"]["kind"] == "paragraph" and r["text"] == "AFTER_TABLE & 한글")
        self.assertEqual(len({a, b, c}), 3)
        # The wrong index is in range but points to a different editable string.
        self.plan["steps"][0]["args"]["patches"][0]["paragraph_index"] = b
        self.contract["targets"][0]["paragraph_index"] = b
        with self.assertRaisesRegex(ValueError, "before mismatch"):
            self.validate()

    def test_wrong_before_missing_duplicate_hash_and_extra(self):
        base = copy.deepcopy(self.contract)
        for mutation, message in (
            (lambda c: c["targets"][0].update(before="WRONG"), "before mismatch"),
            (lambda c: c.update(targets=[]), "missing or extra"),
            (lambda c: c["targets"].append(dict(c["targets"][0])), "Duplicate"),
            (lambda c: c.update(source_sha256="0" * 64), "SHA256 mismatch"),
            (lambda c: c["targets"].append(dict(section_path="Contents/section0.xml", paragraph_index=999, before="")), "missing or extra"),
        ):
            self.contract = copy.deepcopy(base)
            mutation(self.contract)
            with self.assertRaisesRegex(ValueError, message):
                self.validate()

    def test_missing_contract_only_required_for_paragraph_edits(self):
        self.contract = None
        with self.assertRaisesRegex(ValueError, "ParagraphTargetsPath"):
            self.validate()
        self.plan["steps"] = [dict(op="fill_cells", args=dict(cells=[]))]
        self.assertEqual(self.validate()["status"], "not_applicable")
        (self.job / "inputs.json").write_text("{}")
        self.select()
        self.contract = None
        self.assertEqual(self.validate()["status"], "not_required")

    def test_prior_mutations_and_duplicate_edits_refused(self):
        for step in (dict(op="fill_cells", args=dict(cells=[])),
                     dict(op="apply_body_ops", args=dict(ops=[dict(op="delete_paragraph", index=0)]))):
            self.select()
            self.plan["steps"].insert(0, step)
            with self.assertRaisesRegex(ValueError, "Put paragraph edits first"):
                self.validate()
        self.select()
        self.plan["steps"].append(copy.deepcopy(self.plan["steps"][0]))
        with self.assertRaisesRegex(ValueError, "Duplicate paragraph edit"):
            self.validate()

    def test_body_prior_mutation_within_step_and_mixed_engines_refused(self):
        flat_step = copy.deepcopy(self.plan["steps"][0])
        self.operation = "set_paragraph_text"
        self.select()
        self.plan["steps"][0]["args"]["ops"].insert(0, dict(op="replace_text", find="X", replace="Y"))
        with self.assertRaisesRegex(ValueError, "Put paragraph edits first"):
            self.validate()
        self.select()
        self.plan["steps"].append(flat_step)
        with self.assertRaisesRegex(ValueError, "Mixed paragraph coordinate"):
            self.validate()

    def test_unsupported_runtime_fails_closed(self):
        with patch.object(gate, "version", return_value="99.0"):
            with self.assertRaisesRegex(ValueError, "Unsupported paragraph preflight runtime"):
                self.validate()

    def test_table_container_and_nested_paragraph_span_refused(self):
        for operation in gate.OPERATIONS:
            self.operation = operation
            self.select()
            row = next(r for r in gate.paragraph_records(self.source, operation)
                       if r["before"] and "CELL_ZERO" in r["before"] and not r["editable"])
            self.contract["targets"][0] = {k: row[k] for k in ("section_path", "paragraph_index", "before")}
            if operation == "paragraph_patch":
                self.plan["steps"][0]["args"]["patches"][0]["paragraph_index"] = row["paragraph_index"]
            else:
                self.plan["steps"][0]["args"]["ops"][0]["index"] = row["paragraph_index"]
            with self.assertRaisesRegex(ValueError, "unavailable"):
                self.validate()

    def test_duplicate_json_keys_are_rejected(self):
        path = self.root / "duplicate.json"
        path.write_text('{"targets": [], "targets": []}', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Duplicate JSON key"):
            gate.read_contract(path)

    def test_inspection_is_candidate_list_and_refuses_overwrite(self):
        output = self.root / "inspection.json"
        command = [sys.executable, "-B", gate.__file__, "--inspect", str(self.source),
                   "--operation", "paragraph_patch", "--output", str(output)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(output.read_text(encoding="utf-8"))
        self.assertTrue(data["selectionRequired"])
        self.assertNotIn("targets", data)
        self.assertEqual(data["source_sha256"], self.sha)
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_worker_rechecks_and_real_engine_saves_and_reopens(self):
        for operation in gate.OPERATIONS:
            self.operation = operation
            self.select()
            self.plan["output"] = str(self.job / "wip" / (operation + ".hwpx"))
            args = SimpleNamespace(job=str(self.job), source_sha256=self.sha, dry_run=False,
                                   paragraph_contract=self.contract)
            with patch.object(adapter, "assert_scope"):
                self.assertEqual(adapter.worker(args, self.plan, self.run), 0)
            records = content.document(Path(self.plan["output"]))
            text = "\n".join(r["text"] for r in records)
            self.assertIn("UPDATED", text)
            self.assertIn("UNRELATED", text)
            self.assertIn("CELL_ZERO", text)
            self.assertNotIn("AFTER_TABLE", text)
            self.assertEqual(adapter.read_json(self.run / "paragraph-preflight.json")["status"], "passed")

    def test_worker_mismatch_saves_no_candidate(self):
        self.contract["targets"][0]["before"] = "WRONG"
        args = SimpleNamespace(job=str(self.job), source_sha256=self.sha, dry_run=False,
                               paragraph_contract=self.contract)
        with patch.object(adapter, "assert_scope"):
            self.assertEqual(adapter.worker(args, self.plan, self.run), 1)
        self.assertFalse(Path(self.plan["output"]).exists())
        self.assertFalse((self.run / "candidate.hwpx").exists())
        self.assertIn("before mismatch", adapter.read_json(self.run / "state.json")["error"])

    def test_receipt_key_includes_contract_and_path_is_job_local(self):
        self.plan_path = self.job / "plan.json"
        adapter.write_json(self.plan_path, self.plan)
        contract_path = self.job / "targets.json"
        adapter.write_json(contract_path, self.contract)
        args = SimpleNamespace(job=str(self.job), plan=str(self.plan_path), source_sha256=self.sha,
                               dry_run=False, status=True, paragraph_targets=str(contract_path))
        with patch.object(adapter, "resolve_job", return_value=self.job):
            _, original_run = adapter.setup(args)
            self.contract["targets"][0]["before"] = "CHANGED"
            adapter.write_json(contract_path, self.contract)
            _, changed_run = adapter.setup(args)
            self.assertNotEqual(original_run, changed_run)
            args.paragraph_targets = str(self.root / "outside.json")
            with self.assertRaisesRegex(ValueError, "escaped"):
                adapter.setup(args)

    def test_cached_success_cannot_bypass_missing_contract(self):
        args = SimpleNamespace(job=str(self.job), plan="unused", source_sha256=self.sha,
                               dry_run=False, status=False, worker=False, paragraph_targets=None,
                               paragraph_contract=None, timeout=10)
        adapter.write_json(self.run / "state.json", dict(status="dry_run_passed", dryRun=True))
        with patch("argparse.ArgumentParser.parse_args", return_value=args), \
             patch.object(adapter, "setup", return_value=(self.plan, self.run)), \
             patch.object(adapter.subprocess, "Popen") as process:
            with self.assertRaisesRegex(ValueError, "ParagraphTargetsPath"):
                adapter.main()
            process.assert_not_called()


if __name__ == "__main__":
    unittest.main()
