"""Recheck document scope before runtime work, including cached execution.

The PowerShell implementation is shared with intake/publication. This is a
guard against unsubstantiated scope expansion, not a trusted human identity API.
"""
from pathlib import Path
import subprocess


def assert_scope(job, capability, plan_path=None):
    script = Path(__file__).with_name('Assert-DocumentOperationScope.ps1')
    command = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', str(script), '-JobPath', str(job), '-Capability', capability]
    if plan_path is not None:
        command += ['-PlanPath', str(plan_path)]
    result = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace',
                            creationflags=subprocess.CREATE_NO_WINDOW, timeout=30)
    if result.returncode:
        raise ValueError('Document scope denied before execution: ' + result.stderr.strip())
