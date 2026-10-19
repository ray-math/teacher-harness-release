"""Resolve a job through the shared Windows storage policy without creating files."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess


def resolve_job(workspace: Path, path: str | Path) -> Path:
    """Validate work-local jobs with the PowerShell policy; no workspace jobs."""
    validator = workspace / '.agent' / 'shared' / 'Resolve-HwpxJobStorage.ps1'
    command = [
        'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        str(validator), '-JobPath', str(Path(path).absolute()),
    ]
    result = subprocess.run(
        command, capture_output=True, encoding='utf-8-sig', errors='replace',
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
        timeout=30, check=False,
    )
    if result.returncode:
        raise ValueError('Job storage validation failed: ' + (result.stderr or result.stdout).strip())
    info = json.loads(result.stdout)
    return Path(info['jobRoot']).resolve(strict=True)
