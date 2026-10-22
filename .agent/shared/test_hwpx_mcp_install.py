"""Isolated registration checks; optional real CLI/PowerShell integration in TEMP."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SHARED = Path(__file__).resolve().parent
ROOT = SHARED.parents[1]


def load_checker():
    spec = importlib.util.spec_from_file_location("check_hwpx_mcp", SHARED / "check_hwpx_mcp.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ConfigChecks(unittest.TestCase):
    def inspect(self, path):
        result = subprocess.run([sys.executable, "-B", str(SHARED / "inspect_harness_connection.py"),
            str(path), sys.executable, "launcher.py", "2.1.0"], capture_output=True, text=True)
        return result

    def test_missing_and_invalid_configs(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "config.toml"
            self.assertEqual(json.loads(self.inspect(path).stdout), {"exists": False, "matchesProject": False})
            self.assertFalse(path.exists())
            path.write_text("[broken", encoding="utf-8")
            self.assertNotEqual(self.inspect(path).returncode, 0)
            self.assertEqual(path.read_text(), "[broken")

    def test_disabled_or_filtered_tools_rejected(self):
        checker = load_checker()
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "config.toml"
            for restriction in ('enabled = false', 'disabled_tools = ["run_edit_plan"]',
                                'enabled_tools = ["mcp_server_health"]'):
                path.write_text('[mcp_servers.hwpx]\ncommand = ' + json.dumps(sys.executable)
                    + '\nargs = ["-B", "launcher.py"]\n' + restriction
                    + '\n[mcp_servers.hwpx.env]\nHWPX_STACK_AUTO_UPDATE="0"\n'
                    + 'PYTHONUTF8="1"\nHWPX_SKILL_VERSION="2.1.0"\n', encoding="utf-8")
                self.assertFalse(json.loads(self.inspect(path).stdout)["matchesProject"])
                with self.assertRaises(ValueError):
                    checker.parameters_from_config(path)


def ps_literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def integration(powershell, codex):
    checks = []
    with tempfile.TemporaryDirectory(prefix="hwpx-install-check-") as temporary:
        fixture = Path(temporary)
        harness = fixture / "harness"
        shared = harness / ".agent/shared"
        index = harness / ".agent/index"
        shared.mkdir(parents=True)
        index.mkdir(parents=True)
        (harness / ".agents/skills").mkdir(parents=True)
        for name in ("Install-HwpxNativeConnection.ps1", "inspect_harness_connection.py", "check_hwpx_mcp.py", "check_hwpx_document.py"):
            shutil.copyfile(SHARED / name, shared / name)
        shutil.copyfile(ROOT / "Install.ps1", harness / "Install.ps1")
        # Replace platform/path/dependency provisioning only; registration and smoke
        # checks remain the production code and use the real Codex CLI and MCP server.
        (shared / "Setup-TeacherHarness.ps1").write_text('param([switch]$CheckOnly)\n[pscustomobject]@{fixture=$true}\n')
        (shared / "Start-HwpxMcpWindows.ps1").write_text('param([switch]$CheckOnly)\n')
        (shared / "Test-HwpxWorkspace.ps1").write_text('param([switch]$StructureOnly)\n')
        runtime = "[pscustomobject]@{Server=" + ps_literal(sys.executable) + ";Python=" + ps_literal(sys.executable) + ";Spec=[pscustomobject]@{skillVersion='2.1.0'}}\n"
        (shared / "Get-HwpxRuntime.ps1").write_text(runtime)
        odt = shared / "official-odt-draft/scripts"
        odt.mkdir(parents=True)
        (odt / "run_odt.py").write_text("pass\n")
        (index / "odt-runtime.json").write_text(json.dumps({"pythonPath": sys.executable}))
        (shared / "hwpx_mcp_launch.py").write_text(
            "import runpy,sys\nsys.argv=['hwpx-automation-mcp','--workspace-root',"
            + repr(str(harness)) + "]\nrunpy.run_module('hwpx_automation.mcp_cli',run_name='__main__')\n")
        home = fixture / "codex-home"
        home.mkdir()
        config = home / "config.toml"
        env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}

        def run_install(*extra):
            result = subprocess.run([str(powershell), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(harness / "Install.ps1"),
                "-CodexExecutable", str(codex), "-CodexHomePath", str(home), *extra],
                capture_output=True, text=True, env=env, timeout=100)
            if result.returncode:
                raise AssertionError(result.stdout + result.stderr)
            return json.loads((index / "install-status.json").read_text(encoding="utf-8-sig"))

        preflight = subprocess.run([str(powershell), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(harness / "Install.ps1"),
            "-CheckOnly", "-CodexExecutable", str(codex), "-CodexHomePath", str(home)],
            capture_output=True, text=True, env=env, timeout=30)
        assert preflight.returncode == 0, preflight.stderr
        assert not config.exists() and not (index / "install-status.json").exists()
        checks.append("CheckOnly leaves configuration and install status absent")
        first = run_install()
        assert first["mcpRegistrationVerified"] and first["mcpTransportVerified"], first
        assert not first["currentChatMcpVerified"], first
        assert first["hwpxDocumentVerified"] and first["localDocumentDraftsReady"], first
        assert next(s for s in first["steps"] if s["name"] == "mcp")["status"] == "registered"
        checks.append("default first install creates missing config and verifies real registered stdio server")
        before = config.read_bytes()
        second = run_install()
        assert config.read_bytes() == before and second["mcpTransportVerified"]
        assert next(s for s in second["steps"] if s["name"] == "mcp")["status"] == "reused"
        checks.append("repeat installation reuses registration without rewriting config")
        config.write_text('model = "fixture-model"\n[mcp_servers.other]\ncommand = "fixture-other"\n')
        unrelated = config.read_bytes()
        third = run_install()
        assert third["mcpTransportVerified"]
        import tomllib
        data = tomllib.loads(config.read_text())
        assert data["model"] == "fixture-model" and data["mcp_servers"]["other"]["command"] == "fixture-other"
        backups = [s for s in third["steps"] if s["name"] == "mcp-backup"]
        backup_path = Path(backups[0]["detail"].removeprefix("Original Codex settings: "))
        assert backup_path.read_bytes() == unrelated
        backup_path.unlink()
        checks.append("unrelated settings preserved with byte-identical original backup")
        config.write_text('[mcp_servers.hwpx]\ncommand = "another-hwpx-server"\n')
        conflict = config.read_bytes()
        rejected = run_install()
        assert config.read_bytes() == conflict and not rejected["mcpRegistrationVerified"]
        assert rejected["status"] == "attention"
        # The lower-level registration entry point must enforce the same boundary.
        direct = subprocess.run([str(powershell), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(shared / "Install-HwpxNativeConnection.ps1"),
            "-CodexExecutable", str(codex), "-CodexHomePath", str(home)], capture_output=True, text=True, env=env, timeout=30)
        assert direct.returncode != 0 and config.read_bytes() == conflict
        checks.append("conflicting connection preserved through both install entry points")
        skipped = run_install("-SkipMcp")
        assert config.read_bytes() == conflict and not skipped["mcpTransportVerified"]
        assert next(s for s in skipped["steps"] if s["name"] == "mcp")["status"] == "skipped"
        checks.append("explicit SkipMcp leaves all MCP settings untouched")
        smoke = shared / "check_hwpx_document.py"
        smoke_source = smoke.read_bytes()
        smoke.write_text("raise RuntimeError('synthetic document failure')\n")
        failed_document = run_install("-SkipMcp")
        assert not failed_document["hwpxDocumentVerified"]
        assert not failed_document["localDocumentDraftsReady"]
        assert failed_document["status"] == "attention"
        smoke.write_bytes(smoke_source)
        checks.append("document failure prevents draft-ready status")
        config.unlink()
        # A server that cannot start must never be reported verified after registration.
        (shared / "hwpx_mcp_launch.py").write_text("raise RuntimeError('synthetic startup failure')\n")
        failure = run_install()
        assert failure["mcpRegistrationVerified"] and not failure["mcpTransportVerified"]
        assert failure["status"] == "attention"
        checks.append("failed startup distinguished from successful registration")
        # Parse production PowerShell files with the available parser; native 5.1
        # compatibility and OS integration still require a Windows verification.
        manifest = fixture / "parse-files.json"
        manifest.write_text(json.dumps([str(ROOT / "Install.ps1"), str(SHARED / "Install-HwpxNativeConnection.ps1"),
                                       str(SHARED / "Test-HwpxWorkspace.ps1")]))
        parse_script = fixture / "parse.ps1"
        parse_script.write_text("param([string]$Manifest)\n$problems=@(); foreach($p in (Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json))"
            "{$t=$null;$e=$null;[Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e)|Out-Null;"
            "$problems+=@($e)};if($problems.Count){throw ($problems|Out-String)}")
        parsed = subprocess.run([str(powershell), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(parse_script), str(manifest)], capture_output=True, text=True)
        assert parsed.returncode == 0, parsed.stderr
        checks.append("changed PowerShell files parsed without syntax errors")
    return {"ok": True, "checks": checks, "fixtureRemoved": True,
            "realPersonalConfigChanged": False, "nativeWindowsVerified": os.name == "nt"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--powershell", type=Path)
    parser.add_argument("--codex", type=Path)
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ConfigChecks)
    if not unittest.TextTestRunner().run(suite).wasSuccessful():
        return 1
    if bool(args.powershell) != bool(args.codex):
        parser.error("Use --powershell and --codex together")
    if args.powershell:
        print(json.dumps(integration(args.powershell, args.codex), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
