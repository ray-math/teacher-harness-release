[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CodexExecutable,
    [Parameter(Mandatory=$true)][string]$CodexHomePath
)
$ErrorActionPreference='Stop'
$runtime = & (Join-Path $PSScriptRoot 'Get-HwpxRuntime.ps1')
& (Join-Path $PSScriptRoot 'Start-HwpxMcpWindows.ps1') -CheckOnly | Out-Null
$config = Join-Path $CodexHomePath 'config.toml'
$launcher = Join-Path $PSScriptRoot 'hwpx_mcp_launch.py'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Dynamic HWPX launcher is missing.' }
$inspector = Join-Path $PSScriptRoot 'inspect_harness_connection.py'
function Read-Connection {
    $lines = @(& $runtime.Server -B $inspector $config $runtime.Server $launcher $runtime.Spec.skillVersion)
    if ($LASTEXITCODE -ne 0) { throw 'Codex settings could not be parsed; no registration was replaced.' }
    return (($lines -join [Environment]::NewLine) | ConvertFrom-Json)
}
$inspection = Read-Connection
if ($inspection.exists) {
    if (-not $inspection.matchesProject) { throw 'An existing hwpx MCP connection differs from this project. It was preserved.' }
    [pscustomobject]@{ registrationStatus='reused';registrationVerified=$true;configPath=$config;backupPath=$null }
    return
}
$backup = $null
if (Test-Path -LiteralPath $config -PathType Leaf) {
    $backup = Join-Path ([IO.Path]::GetTempPath()) ('hwpx-config-' + [guid]::NewGuid().ToString('N') + '.before.toml')
    Copy-Item -LiteralPath $config -Destination $backup
}
# A host-local server of the same name overrides the plugin launcher. Keep the
# upstream plugin enabled for its specialized skills and contracts.
$previousCodexHome = $env:CODEX_HOME
try {
    $env:CODEX_HOME = [IO.Path]::GetFullPath($CodexHomePath)
    # Resolve authorized roots from the current delivery config at each start.
    $cliArgs = @('mcp','add','hwpx','--env','HWPX_STACK_AUTO_UPDATE=0','--env','PYTHONUTF8=1','--env',('HWPX_SKILL_VERSION=' + $runtime.Spec.skillVersion),'--',$runtime.Server,'-B',$launcher)
    & $CodexExecutable @cliArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Codex MCP registration failed; original config: $backup" }
    & $CodexExecutable mcp get hwpx --json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not read back native HWPX registration.' }
    $after = Read-Connection
    if (-not $after.matchesProject) { throw "HWPX registration did not match the expected launcher; original config: $backup" }
} finally {
    $env:CODEX_HOME = $previousCodexHome
}
[pscustomobject]@{ registrationStatus='registered';registrationVerified=$true;configPath=$config;backupPath=$backup }
