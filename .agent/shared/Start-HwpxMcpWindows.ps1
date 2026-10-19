[CmdletBinding()]
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
$runtime = & (Join-Path $PSScriptRoot 'Get-HwpxRuntime.ps1')
$python = $runtime.Python
$env:HWPX_SKILL_VERSION = $runtime.Spec.skillVersion
$env:HWPX_STACK_AUTO_UPDATE = '0'
$env:PYTHONUTF8 = '1'
if ($CheckOnly) {
    @'
import json, sys
from importlib.metadata import version
from hwpx_automation.quality import capability_state
s = capability_state()
spec = json.load(open(sys.argv[1], encoding='utf-8-sig'))
for package, expected in spec['versions'].items():
    assert version(package) == expected, f'{package}: expected {expected}, got {version(package)}'
assert s['ok']
print(json.dumps(s))
'@ | & $python - (Join-Path $runtime.Workspace '.agent/index/hwpx-runtime.json')
} else {
    $serverArguments = $runtime.Arguments
    & $runtime.Server @serverArguments
}
if ($LASTEXITCODE -ne 0) { throw "HWPX Windows runtime exited with code $LASTEXITCODE" }
