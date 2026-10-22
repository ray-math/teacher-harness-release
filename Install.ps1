<#
.SYNOPSIS
Install and verify the teacher harness from one project-local entry point.
.DESCRIPTION
Run after the user asks to install this project. Reuses selected work paths and
healthy runtimes. Missing uv is installed through its official WinGet package.
Existing unrelated MCP connections are never replaced. -CheckOnly is read-only.
#>
[CmdletBinding()]
param(
    [string]$CabinetRoot,
    [string]$IncomingRoot,
    [switch]$CheckOnly,
    [switch]$SkipMcp,
    [string]$CodexExecutable,
    [string]$CodexHomePath
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath($PSScriptRoot)
$setup = Join-Path $workspace '.agent/shared/Setup-TeacherHarness.ps1'
$shared = Join-Path $workspace '.agent/shared'
$steps = [Collections.Generic.List[object]]::new()
$mcpRegistrationVerified = $false
$mcpTransportVerified = $false
$hwpxDocumentVerified = $false
$hwpxDocumentCheck = $null
$pathOptions = @{}
foreach ($name in @('CabinetRoot','IncomingRoot')) {
    if ($PSBoundParameters.ContainsKey($name)) {
        if ([string]::IsNullOrWhiteSpace($PSBoundParameters[$name])) { throw "$name cannot be empty." }
        $pathOptions[$name] = $PSBoundParameters[$name]
    }
}
function Add-InstallStep([string]$Name,[string]$Status,[string]$Detail) {
    $steps.Add([pscustomobject]@{name=$Name;status=$Status;detail=$Detail})
}
function Find-Uv {
    $command = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $candidates = @()
    if ($env:USERPROFILE) { $candidates += Join-Path $env:USERPROFILE '.local/bin/uv.exe' }
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Links/uv.exe'
        $packages = Join-Path $env:LOCALAPPDATA 'Microsoft/WinGet/Packages'
        if (Test-Path -LiteralPath $packages -PathType Container) {
            $candidates += @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'astral-sh.uv_*' |
                ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter 'uv.exe' -Recurse } |
                Select-Object -ExpandProperty FullName)
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}
function Test-HwpxReady {
    try { & (Join-Path $shared 'Start-HwpxMcpWindows.ps1') -CheckOnly | Out-Null; return $true }
    catch { return $false }
}
function Test-OdtReady {
    try {
        $recordPath = Join-Path $workspace '.agent/index/odt-runtime.json'
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { return $false }
        $record = Get-Content -Raw -Encoding UTF8 -LiteralPath $recordPath | ConvertFrom-Json
        if (-not (Test-Path -LiteralPath $record.pythonPath -PathType Leaf)) { return $false }
        $launcher = Join-Path $shared 'official-odt-draft/scripts/run_odt.py'
        & $record.pythonPath -B $launcher --runtime-check | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

if ($CheckOnly) {
    $state = & $setup @pathOptions -CheckOnly
    [pscustomobject]@{
        schemaVersion='teacher-harness-install/v1';checkOnly=$true
        workspace=$workspace;state=$state
        projectSkillsIncluded=[bool](Test-Path -LiteralPath (Join-Path $workspace '.agents/skills') -PathType Container)
        uvAvailable=[bool](Find-Uv)
        codexCliAvailable=[bool](Get-Command codex -CommandType Application -ErrorAction SilentlyContinue)
        note='No folders, settings, packages or MCP registrations were changed.'
    }
    return
}

# Setup resolves existing selections. It never moves existing school files.
& $setup @pathOptions | Out-Null
Add-InstallStep 'work-paths' 'ready' 'Configured output location and input handling; existing selections reused.'
$hwpxReady = Test-HwpxReady
$odtReady = Test-OdtReady
if (-not $hwpxReady -or -not $odtReady) {
    try {
        $uvPath = Find-Uv
        if (-not $uvPath) {
            $winget = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $winget) { throw 'uv and WinGet are unavailable. Codex should prepare uv using the official Astral installation guide, then rerun Install.ps1.' }
            & $winget.Source install --id astral-sh.uv --exact --source winget --scope user --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) { throw "WinGet could not install uv (exit $LASTEXITCODE)." }
            $uvPath = Find-Uv
            if (-not $uvPath) { throw 'uv was not located after installation. Refresh the terminal and rerun Install.ps1.' }
            Add-InstallStep 'uv' 'installed' 'Installed official astral-sh.uv package for the current user.'
        } else { Add-InstallStep 'uv' 'reused' 'Existing uv installation reused; no upgrade requested.' }
        # Make the resolved executable available to internal setup only in this process.
        $savedPath = $env:Path
        try {
            $env:Path = (Split-Path -Parent $uvPath) + [IO.Path]::PathSeparator + $savedPath
            if (-not $hwpxReady) {
                try { & $setup @pathOptions -InstallRuntime | Out-Null; $hwpxReady=Test-HwpxReady
                    if (-not $hwpxReady) { throw 'Installed HWPX runtime did not pass its package/capability check.' }
                    Add-InstallStep 'hwpx-runtime' 'verified' 'Pinned runtime installed and package/capability check passed.'
                } catch { Add-InstallStep 'hwpx-runtime' 'failed' $_.Exception.Message }
            }
            if (-not $odtReady) {
                try { & $setup @pathOptions -InstallOdt | Out-Null; $odtReady=Test-OdtReady
                    if (-not $odtReady) { throw 'Installed ODT dependencies did not pass runtime-check.' }
                    Add-InstallStep 'odt-runtime' 'verified' 'ODT dependencies installed and runtime-check passed.'
                } catch { Add-InstallStep 'odt-runtime' 'failed' $_.Exception.Message }
            }
        } finally { $env:Path=$savedPath }
    } catch { Add-InstallStep 'dependencies' 'attention' $_.Exception.Message }
}
if ($hwpxReady -and -not ($steps | Where-Object name -eq 'hwpx-runtime')) { Add-InstallStep 'hwpx-runtime' 'reused' 'Existing pinned runtime passed its package/capability check.' }
if ($odtReady -and -not ($steps | Where-Object name -eq 'odt-runtime')) { Add-InstallStep 'odt-runtime' 'reused' 'Existing ODT runtime passed runtime-check.' }

if ($hwpxReady) {
    try {
        $runtime = & (Join-Path $shared 'Get-HwpxRuntime.ps1')
        $checkOutput = & $runtime.Python -X utf8 -B (Join-Path $shared 'check_hwpx_document.py')
        if ($LASTEXITCODE -ne 0) { throw 'HWPX synthetic document read/fill/save/reopen check failed.' }
        $hwpxDocumentCheck = ($checkOutput -join "`n") | ConvertFrom-Json
        if ($hwpxDocumentCheck.ok -ne $true) { throw 'HWPX document check did not confirm success.' }
        $hwpxDocumentVerified = $true
        Add-InstallStep 'hwpx-document' 'verified' 'Synthetic document read, cell fill, save and reopen passed; source, table geometry and style definitions preserved. Native Hancom display is not checked.'
    } catch { Add-InstallStep 'hwpx-document' 'failed' $_.Exception.Message }
} else { Add-InstallStep 'hwpx-document' 'attention' 'Runtime unavailable; actual document processing is not verified.' }

if ($SkipMcp) { Add-InstallStep 'mcp' 'skipped' 'MCP registration was explicitly skipped.' }
elseif (-not $hwpxReady) { Add-InstallStep 'mcp' 'attention' 'HWPX runtime is not ready; no MCP settings changed.' }
else {
    try {
        if (-not $CodexExecutable) {
            $cli = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cli) { $CodexExecutable=$cli.Source }
        }
        if (-not $CodexExecutable -or -not (Test-Path -LiteralPath $CodexExecutable -PathType Leaf)) { throw 'Codex CLI was not found. Local document runtimes are available; MCP registration remains pending.' }
        if (-not $CodexHomePath) { $CodexHomePath=if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' } }
        # The first MCP registration may create config.toml through the Codex CLI.
        # The connection installer preserves unrelated settings and rejects name conflicts.
        $runtime = & (Join-Path $shared 'Get-HwpxRuntime.ps1')
        $connection = & (Join-Path $shared 'Install-HwpxNativeConnection.ps1') -CodexExecutable $CodexExecutable -CodexHomePath $CodexHomePath
        $mcpRegistrationVerified = [bool]$connection.registrationVerified
        Add-InstallStep 'mcp' $connection.registrationStatus 'Project launcher registration read back and verified; current chat tool exposure remains unverified.'
        if ($connection.backupPath) { Add-InstallStep 'mcp-backup' 'preserved' ('Original Codex settings: ' + $connection.backupPath) }
        # Windows PowerShell 5.1 can turn harmless native stderr warnings into
        # terminating errors. The verifier's exit code is the success contract.
        $savedErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $runtime.Server -B (Join-Path $shared 'check_hwpx_mcp.py') --config (Join-Path $CodexHomePath 'config.toml') --timeout 60 | Out-Null
            $mcpCheckExitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $savedErrorAction }
        if ($mcpCheckExitCode -ne 0) {
            Add-InstallStep 'mcp-transport' 'failed' 'Registration is present but stdio startup, required-tools or health check failed.'
        } else {
            $mcpTransportVerified = $true
            Add-InstallStep 'mcp-transport' 'verified' 'Registered stdio command initialized, exposed required tools and passed health; verify tool exposure in a new Codex chat.'
        }
    } catch { Add-InstallStep 'mcp' 'attention' $_.Exception.Message }
}

try { & (Join-Path $shared 'Test-HwpxWorkspace.ps1') -StructureOnly | Out-Null; Add-InstallStep 'structure' 'verified' 'Project structure check passed.' }
catch { Add-InstallStep 'structure' 'failed' $_.Exception.Message }
$attention=@($steps | Where-Object { $_.status -in @('failed','attention') })
$summary=[pscustomobject]@{
    schemaVersion='teacher-harness-install/v1';workspace=$workspace;checkOnly=$false
    status=$(if ($attention.Count) {'attention'} else {'ready-for-document-drafts'})
    hwpxRuntimeVerified=[bool]$hwpxReady;odtRuntimeVerified=[bool]$odtReady
    hwpxDocumentVerified=[bool]$hwpxDocumentVerified;hwpxDocumentCheck=$hwpxDocumentCheck
    localDocumentDraftsReady=[bool]($hwpxReady -and $odtReady -and $hwpxDocumentVerified)
    mcpRegistrationVerified=[bool]$mcpRegistrationVerified;mcpTransportVerified=[bool]$mcpTransportVerified
    projectSkillsIncluded=[bool](Test-Path -LiteralPath (Join-Path $workspace '.agents/skills') -PathType Container)
    skillsCopiedToPersonalDirectory=$false
    nativeHancomVerified=$false;currentChatMcpVerified=$false
    steps=@($steps.ToArray())
}
$record=Join-Path $workspace '.agent/index/install-status.json'
[IO.File]::WriteAllText($record,($summary | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
$summary
