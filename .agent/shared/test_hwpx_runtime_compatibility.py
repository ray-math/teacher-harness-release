"""Real pinned-package/MCP regressions using only disposable synthetic documents.

Run with the candidate runtime's Python. Windows worker/file-lock coverage lives
in test_paragraph_target_preflight.py; this smoke also runs on other platforms.
"""
import asyncio
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

from hwpx import HwpxDocument
from jsonschema import validate
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.shared.exceptions import McpError

from check_hwpx_mcp import verify


ROOT = Path(__file__).resolve().parents[2]
SPEC = json.loads((ROOT / ".agent/index/hwpx-runtime.json").read_text(encoding="utf-8-sig"))


def payload(result):
    if result.structuredContent is not None:
        return result.structuredContent
    for block in result.content:
        if block.type == "text":
            try:
                return json.loads(block.text)
            except (TypeError, ValueError):
                continue
    raise AssertionError("MCP tool returned no JSON payload")


def server_parameters(root):
    environment = dict(os.environ)
    # The test's explicit root must be independent of a developer's MCP settings.
    for key in ("HWPX_AUTOMATION_WORKSPACE_ROOTS", "HWPX_MCP_WORKSPACE_ROOTS"):
        environment.pop(key, None)
    environment.update(PYTHONUTF8="1", PYTHONDONTWRITEBYTECODE="1",
                       HWPX_SKILL_VERSION=SPEC["skillVersion"], HWPX_STACK_AUTO_UPDATE="0")
    return StdioServerParameters(command=sys.executable,
        args=["-B", "-m", "hwpx_automation.mcp_cli", "--workspace-root", str(root)],
        env=environment)


class RuntimeCompatibilityTests(unittest.TestCase):
    def test_adapter_observation_hooks_and_pinned_versions(self):
        for package, expected in SPEC["versions"].items():
            with self.subTest(package=package):
                self.assertEqual(version(package), expected)
        from hwpx.plan import _execute as engine
        for name in ("validate_edit_plan", "validate_editor_open_safety", "write_bytes_atomically"):
            with self.subTest(hook=name):
                self.assertTrue(callable(getattr(engine, name, None)), name)
        self.assertIsInstance(engine._DISPATCH, dict)
        self.assertTrue({"paragraph_patch", "fill_cells", "apply_body_ops"}.issubset(engine._DISPATCH))
        self.assertTrue(all(callable(operation) for operation in engine._DISPATCH.values()))

    def test_mcp_verify_read_edit_reopen_and_root_denial(self):
        asyncio.run(asyncio.wait_for(self.exercise_mcp(), timeout=90))

    async def exercise_mcp(self):
        with tempfile.TemporaryDirectory(prefix="teacher-hwpx-compatibility-") as temporary:
            fixture = Path(temporary)
            root = fixture / "allowed"
            root.mkdir()
            source = root / "한글 경로 O'Brien 원본.hwpx"
            output = root / "작성 결과.hwpx"
            outside = fixture / "outside.hwpx"
            document = HwpxDocument.new()
            document.add_paragraph("ORIGINAL_BODY")
            document.add_paragraph("UNTOUCHED_BODY")
            table = document.add_table(1, 2)
            table.set_cell_text(0, 0, "UNCHANGED_LABEL")
            table.set_cell_text(0, 1, "ORIGINAL_CELL")
            document.save_to_path(str(source))
            original = source.read_bytes()
            source_revision = "sha256:" + hashlib.sha256(original).hexdigest()
            outside.write_bytes(original)
            parameters = server_parameters(root)

            # Exercise the production installation checker, including tool listing
            # and capability/workspace health, without writing a registration.
            checked = await verify(parameters)
            self.assertTrue(checked["ok"])
            self.assertTrue(checked["stdioInitializeVerified"])
            self.assertTrue(checked["requiredToolsVerified"])
            self.assertTrue(checked["healthVerified"])

            async with stdio_client(parameters) as (reader, writer):
                async with ClientSession(reader, writer) as session:
                    await session.initialize()
                    schemas, cursor = {}, None
                    while True:
                        page = await session.list_tools(cursor=cursor)
                        schemas.update((tool.name, tool.inputSchema) for tool in page.tools)
                        cursor = page.nextCursor
                        if not cursor:
                            break

                    async def call(name, arguments):
                        validate(arguments, schemas[name])
                        result = await session.call_tool(name, arguments)
                        self.assertFalse(result.isError, result.model_dump_json())
                        data = payload(result)
                        self.assertIsInstance(data, dict)
                        return data

                    body = await call("get_document_text", {"filename": str(source)})
                    self.assertFalse(body["truncated"])
                    self.assertIn("ORIGINAL_BODY", body["text"])
                    self.assertIn("UNTOUCHED_BODY", body["text"])
                    self.assertEqual(body["document_revision"], source_revision)
                    cells = await call("get_table_text", {"filename": str(source), "table_index": 0})
                    self.assertEqual(cells["data"], [["UNCHANGED_LABEL", "ORIGINAL_CELL"]])
                    self.assertEqual(cells["document_revision"], source_revision)

                    try:
                        denied = await session.call_tool("get_document_text", {"filename": str(outside)})
                    except McpError as error:
                        self.assertIn("WORKSPACE_OUTSIDE_ROOT", str(error))
                    else:
                        self.assertTrue(denied.isError)
                        self.assertIn("WORKSPACE_OUTSIDE_ROOT", denied.model_dump_json())
                    self.assertEqual(outside.read_bytes(), original)

                    plan = {
                        "schemaVersion": "hwpx.edit-plan/v1",
                        "source": str(source), "output": str(output),
                        "steps": [
                            {"id": "body", "op": "apply_body_ops", "args": {"ops": [
                                {"op": "replace_text", "find": "ORIGINAL_BODY",
                                 "replace": "UPDATED_BODY", "count": 1}]}},
                            {"id": "cell", "op": "fill_cells", "args": {"cells": [
                                {"table_index": 0, "row": 0, "col": 1, "text": "UPDATED_CELL"}]}},
                        ],
                    }
                    dry = await call("run_edit_plan", {"plan": plan, "dry_run": True})
                    self.assertTrue(dry["ok"], dry)
                    self.assertTrue(dry["dryRun"])
                    self.assertFalse(dry["executed"])
                    self.assertEqual([step["status"] for step in dry["steps"]], ["would_apply"] * 2)
                    self.assertFalse(output.exists())
                    self.assertEqual(source.read_bytes(), original)

                    committed = await call("run_edit_plan", {"plan": plan, "dry_run": False})
                    self.assertTrue(committed["ok"], committed)
                    self.assertTrue(committed["executed"])
                    self.assertFalse(committed["dryRun"])
                    self.assertEqual([step["status"] for step in committed["steps"]], ["applied"] * 2)
                    self.assertEqual(Path(committed["outputPath"]).resolve(), output.resolve())
                    self.assertEqual(source.read_bytes(), original)

                    body = await call("get_document_text", {"filename": str(output)})
                    self.assertFalse(body["truncated"])
                    self.assertIn("UPDATED_BODY", body["text"])
                    self.assertIn("UNTOUCHED_BODY", body["text"])
                    self.assertNotIn("ORIGINAL_BODY", body["text"])
                    self.assertEqual(body["document_revision"],
                                     "sha256:" + hashlib.sha256(output.read_bytes()).hexdigest())
                    cells = await call("get_table_text", {"filename": str(output), "table_index": 0})
                    self.assertEqual(cells["data"], [["UNCHANGED_LABEL", "UPDATED_CELL"]])

            reopened = HwpxDocument.open(str(output))
            self.assertIn("UPDATED_BODY", [paragraph.text for paragraph in reopened.paragraphs])
            self.assertIn("UNTOUCHED_BODY", [paragraph.text for paragraph in reopened.paragraphs])
            self.assertEqual(reopened.tables.all[0].cell(0, 1).text, "UPDATED_CELL")
            # Both operations promise byte-preserving patches. Check actual member
            # payloads, so unchanged text, styles and table geometry are preserved.
            with zipfile.ZipFile(source) as before, zipfile.ZipFile(output) as after:
                self.assertEqual(before.namelist(), after.namelist())
                self.assertIsNone(after.testzip())
                for name in before.namelist():
                    expected = before.read(name)
                    if name == "Contents/section0.xml":
                        expected = expected.replace(b"ORIGINAL_BODY", b"UPDATED_BODY")
                        expected = expected.replace(b"ORIGINAL_CELL", b"UPDATED_CELL")
                    self.assertEqual(after.read(name), expected, name + " changed beyond selected text")
            self.assertEqual(source.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
