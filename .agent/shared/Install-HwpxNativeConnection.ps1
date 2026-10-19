[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CodexExecutable,
    [Parameter(Mandatory=$true)][string]$CodexHomePath
)
$ErrorActionPreference='Stop'
$runtime = & (Join-Path $PSScriptRoot 'Get-HwpxRuntime.ps1')
& (Join-Path $PSScriptRoot 'Start-HwpxMcpWindows.ps1') -CheckOnly
$config = Join-Path $CodexHomePath 'config.toml'
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw 'Expected existing Codex config.' }
$backup = Join-Path ([IO.Path]::GetTempPath()) ('hwpx-config-' + [guid]::NewGuid().ToString('N') + '.before.toml')
Copy-Item -LiteralPath $config -Destination $backup
# A host-local server of the same name overrides the plugin launcher. Keep the
# upstream plugin enabled for its specialized skills and contracts.
$previousCodexHome = $env:CODEX_HOME
try {
    $env:CODEX_HOME = [IO.Path]::GetFullPath($CodexHomePath)
    # Resolve authorized roots from the current delivery config at each start.
    $launcher = Join-Path $PSScriptRoot 'hwpx_mcp_launch.py'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Dynamic HWPX launcher is missing.' }
    $cliArgs = @('mcp','add','hwpx','--env','HWPX_STACK_AUTO_UPDATE=0','--env','PYTHONUTF8=1','--env',('HWPX_SKILL_VERSION=' + $runtime.Spec.skillVersion),'--',$runtime.Server,'-B',$launcher)
    & $CodexExecutable @cliArgs
    if ($LASTEXITCODE -ne 0) { throw "Codex MCP registration failed; original config: $backup" }
    & $CodexExecutable mcp get hwpx --json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read back native HWPX registration.' }
} finally {
    $env:CODEX_HOME = $previousCodexHome
}
Write-Output "Original config preserved: $backup"
