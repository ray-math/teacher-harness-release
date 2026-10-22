<#
.SYNOPSIS
Internal component setup. Use the root Install.ps1 for installation.
.DESCRIPTION
The default operation resolves the two user data folders against this script's
folder, creates them, and saves their absolute paths. -CheckOnly makes no writes.
Package downloads and Codex MCP registration require their respective switches.
#>
[CmdletBinding()]
param(
    [string]$CabinetRoot,
    [string]$IncomingRoot,
    [switch]$CheckOnly,
    [switch]$InstallRuntime,
    [switch]$InstallOdt,
    [switch]$RegisterMcp,
    [string]$CodexExecutable,
    [string]$CodexHomePath
)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$shared = Join-Path $workspace '.agent/shared'
$configPath = Join-Path $workspace '.agent/index/delivery-system.json'
. (Join-Path $shared 'Resolve-TeacherHarnessConfig.ps1')

if ($CheckOnly -and ($InstallRuntime -or $InstallOdt -or $RegisterMcp)) {
    throw '-CheckOnly cannot be combined with installation or registration switches.'
}
if ($RegisterMcp -and ([string]::IsNullOrWhiteSpace($CodexExecutable) -or [string]::IsNullOrWhiteSpace($CodexHomePath))) {
    throw '-RegisterMcp requires explicit -CodexExecutable and -CodexHomePath values.'
}

$config = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
if ($PSBoundParameters.ContainsKey('CabinetRoot')) {
    if ([string]::IsNullOrWhiteSpace($CabinetRoot)) { throw '-CabinetRoot cannot be empty.' }
    $config.humanCabinet = $CabinetRoot
}
if ($PSBoundParameters.ContainsKey('IncomingRoot')) {
    if ([string]::IsNullOrWhiteSpace($IncomingRoot)) { throw '-IncomingRoot cannot be empty.' }
    $config.incomingRoot = $IncomingRoot
}
$config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
$runtimeSpecPath = Join-Path $workspace '.agent/index/hwpx-runtime.json'
$spec = Get-Content -Raw -Encoding UTF8 -LiteralPath $runtimeSpecPath | ConvertFrom-Json
$runtimeDirectory = [IO.Path]::GetFullPath((Join-Path $workspace $spec.runtimeDirectory))
if (-not $runtimeDirectory.StartsWith($workspace + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Runtime must be inside this harness folder.'
}
$runtimePython = Join-Path $runtimeDirectory 'Scripts/python.exe'
$runtimeEntryPoint = Join-Path $runtimeDirectory 'Lib/site-packages/hwpx_automation/mcp_cli.py'
$odtRoot = Join-Path $shared 'official-odt-draft'
$odtDependencies = Join-Path $odtRoot '.deps'
$odtRuntimeRecordPath = Join-Path $workspace '.agent/index/odt-runtime.json'
$odtRuntimeRecord = $null
if (Test-Path -LiteralPath $odtRuntimeRecordPath -PathType Leaf) {
    $odtRuntimeRecord = Get-Content -Raw -Encoding UTF8 -LiteralPath $odtRuntimeRecordPath | ConvertFrom-Json
}

function Get-SetupState {
    [pscustomobject]@{
        Workspace = $workspace
        ConfigPath = $configPath
        HumanCabinet = $config.humanCabinet
        HumanCabinetExists = [bool](Test-Path -LiteralPath $config.humanCabinet -PathType Container)
        ReceiveInputs = $config.receiveInputs
        IncomingRoot = $config.incomingRoot
        IncomingRootExists = [bool](Test-Path -LiteralPath $config.incomingRoot -PathType Container)
        RuntimeDirectory = $runtimeDirectory
        RuntimePythonExists = [bool](Test-Path -LiteralPath $runtimePython -PathType Leaf)
        RuntimeEntryPointExists = [bool](Test-Path -LiteralPath $runtimeEntryPoint -PathType Leaf)
        RuntimeReady = [bool]((Test-Path -LiteralPath $runtimePython -PathType Leaf) -and (Test-Path -LiteralPath $runtimeEntryPoint -PathType Leaf))
        RuntimeVersions = $spec.versions
        OdtDependencyDirectory = $odtDependencies
        OdtDependencyDirectoryExists = [bool](Test-Path -LiteralPath $odtDependencies -PathType Container)
        OdtRuntimeRecordPath = $odtRuntimeRecordPath
        OdtRuntimeRecorded = [bool]($null -ne $odtRuntimeRecord)
        OdtPythonPath = $(if ($odtRuntimeRecord) { [string]$odtRuntimeRecord.pythonPath } elseif (Test-Path -LiteralPath $runtimePython -PathType Leaf) { $runtimePython } else { $null })
        OdtRecordedDependencyDirectory = $(if ($odtRuntimeRecord) { [string]$odtRuntimeRecord.dependencyDirectory } else { $null })
        CheckOnly = [bool]$CheckOnly
    }
}

if ($CheckOnly) {
    Get-SetupState
    Write-Host 'Read-only check complete. RuntimeReady reports file presence; use Start-HwpxMcpWindows.ps1 -CheckOnly to verify installed package versions.'
    return
}

$folders = @([string]$config.humanCabinet)
if ($config.receiveInputs) { $folders += [string]$config.incomingRoot }
foreach ($folder in $folders) {
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
}
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($configPath, (($config | ConvertTo-Json -Depth 100) + [Environment]::NewLine), $utf8Bom)

if ($InstallRuntime -or $InstallOdt) {
    $uv = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $uv) { throw 'uv is required for optional package installation. Install uv, then run this setup again with the desired installation switch.' }
    $uvExecutable = $uv.Source
}

if ($InstallRuntime) {
    if ($spec.versions.'python-hwpx' -ne '6.3.0' -or $spec.versions.'python-hwpx-automation' -ne '7.0.4' -or $spec.skillVersion -ne '2.1.0') {
        throw 'Unexpected HWPX runtime specification. Review the pinned specification before installation.'
    }
    $requirements = Join-Path $shared 'hwpx-runtime/requirements-verified.txt'
    if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) { throw 'Verified HWPX requirements file is missing.' }
    if (-not (Test-Path -LiteralPath $runtimePython -PathType Leaf)) {
        & $uvExecutable venv --python 3.12 $runtimeDirectory
        if ($LASTEXITCODE -ne 0) { throw "uv could not create the HWPX runtime (exit $LASTEXITCODE)." }
    }
    & $uvExecutable pip install --python $runtimePython -r $requirements
    if ($LASTEXITCODE -ne 0) { throw "HWPX dependency installation failed (exit $LASTEXITCODE)." }
    & (Join-Path $shared 'Start-HwpxMcpWindows.ps1') -CheckOnly
    Write-Host 'HWPX runtime package and capability check passed.'
}

if ($InstallOdt) {
    $requirements = Join-Path $odtRoot 'scripts/requirements.txt'
    $odtLauncher = Join-Path $odtRoot 'scripts/run_odt.py'
    if (-not (Test-Path -LiteralPath $requirements -PathType Leaf) -or -not (Test-Path -LiteralPath $odtLauncher -PathType Leaf)) {
        throw 'ODT requirements or launcher is missing.'
    }
    $odtPython = $runtimePython
    if (-not (Test-Path -LiteralPath $odtPython -PathType Leaf)) {
        & $uvExecutable python install 3.12
        if ($LASTEXITCODE -ne 0) { throw "uv could not provision Python 3.12 for ODT (exit $LASTEXITCODE)." }
        $pythonPaths = @(& $uvExecutable python find 3.12)
        if ($LASTEXITCODE -ne 0 -or $pythonPaths.Count -eq 0) { throw 'uv could not locate Python 3.12 for ODT.' }
        $odtPython = [string]$pythonPaths[-1]
    }
    & $uvExecutable pip install --python $odtPython --target $odtDependencies -r $requirements
    if ($LASTEXITCODE -ne 0) { throw "ODT dependency installation failed (exit $LASTEXITCODE)." }
    & $odtPython -B $odtLauncher --runtime-check
    if ($LASTEXITCODE -ne 0) { throw "ODT dependency check failed (exit $LASTEXITCODE)." }
    $odtRuntimeRecord = [ordered]@{
        schemaVersion = 'teacher-harness-odt-runtime/v1'
        pythonPath = [IO.Path]::GetFullPath($odtPython)
        dependencyDirectory = [IO.Path]::GetFullPath($odtDependencies)
    }
    [IO.File]::WriteAllText($odtRuntimeRecordPath, (($odtRuntimeRecord | ConvertTo-Json -Depth 5) + [Environment]::NewLine), $utf8Bom)
    Write-Host 'ODT dependency check passed.'
}

if ($RegisterMcp) {
    & (Join-Path $shared 'Install-HwpxNativeConnection.ps1') -CodexExecutable $CodexExecutable -CodexHomePath $CodexHomePath
}

Get-SetupState
Write-Host 'Setup complete. No Hancom application, DLL, or plugin installation was performed.'
