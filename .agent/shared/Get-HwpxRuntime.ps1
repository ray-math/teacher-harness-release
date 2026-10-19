[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$env:PYTHONDONTWRITEBYTECODE = '1'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$spec = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $workspace '.agent/index/hwpx-runtime.json') | ConvertFrom-Json
$directory = [IO.Path]::GetFullPath((Join-Path $workspace $spec.runtimeDirectory))
if (-not $directory.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Runtime must be inside this workspace.' }
$python = Join-Path $directory 'Scripts/python.exe'
$server = $python
$entryPoint = Join-Path $directory 'Lib/site-packages/hwpx_automation/mcp_cli.py'
foreach ($file in @($python, $entryPoint)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Verified HWPX runtime missing: $file. Restore it during maintenance; do not install during document work." }
}
$delivery = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $workspace '.agent/index/delivery-system.json') | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $delivery = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $delivery
} elseif (-not [IO.Path]::IsPathRooted([string]$delivery.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
# distlib's generated .exe embeds the original absolute Python path. Invoke the
# verified package entry point through this runtime's Python after tool renames.
$serverArguments = @('-B', '-m', 'hwpx_automation.mcp_cli', '--workspace-root', $workspace)
foreach ($selectedRoot in @([string]$delivery.humanCabinet, [string]$delivery.incomingRoot)) {
    # Do not broaden a missing root to its parent or create it during document work.
    if (Test-Path -LiteralPath $selectedRoot) { $serverArguments += @('--workspace-root', $selectedRoot) }
}
[pscustomobject]@{ Workspace=$workspace; Python=$python; Server=$server; Arguments=$serverArguments; Spec=$spec }
