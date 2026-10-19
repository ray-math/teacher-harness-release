[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$JobPath,
    [Parameter(Mandatory=$true)][string]$PlanPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$SourceSha256,
    [ValidateRange(5,3600)][int]$TimeoutSeconds = 120,
    [switch]$DryRun,
    [switch]$Status
)
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'run_hwpx_edit_plan.py'
$arguments = @($runner,'--job',([IO.Path]::GetFullPath($JobPath)),'--plan',([IO.Path]::GetFullPath($PlanPath)),'--source-sha256',$SourceSha256,'--timeout',"$TimeoutSeconds")
if ($DryRun) { $arguments += '--dry-run' }
if ($Status) { $arguments += '--status' }
$runtime = & (Join-Path $PSScriptRoot 'Get-HwpxRuntime.ps1')
$env:PYTHONUTF8 = '1'
& $runtime.Python @arguments
if ($LASTEXITCODE -ne 0) { throw "HWPX edit plan did not complete (exit $LASTEXITCODE). Inspect the printed state/receipt path before retrying." }
