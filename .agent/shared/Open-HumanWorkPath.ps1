[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Uri,
    [string]$ManifestPath = '',
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

function Move-FileOverwrite([string]$Source, [string]$Destination) {
    if ([IO.File]::Exists($Destination)) {
        [IO.File]::Copy($Source, $Destination, $true)
        [IO.File]::Delete($Source)
    } else {
        [IO.File]::Move($Source, $Destination)
    }
}

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
# A direct maintenance-tool invocation uses the same cabinet manifest as the
# native launcher. Opening registrations are cabinet state, never tool state.
if (-not $ManifestPath -and $config.humanCabinet) {
    $cabinetRoot = [IO.Path]::GetFullPath([string]$config.humanCabinet).TrimEnd('\')
    if ($workspace.TrimEnd('\') -ine $cabinetRoot) {
        $installedConfigPath = Join-Path $cabinetRoot '.agent\index\delivery-system.json'
        $walk = [IO.Path]::GetPathRoot($installedConfigPath)
        foreach ($part in @($installedConfigPath.Substring($walk.Length) -split '[\\/]')) {
            if (-not $part) { continue }
            $walk = Join-Path $walk $part
            if ((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Cabinet configuration must not use reparse points.' }
        }
        if (-not (Test-Path -LiteralPath $installedConfigPath -PathType Leaf)) { throw 'The selected cabinet console runtime is not installed.' }
        $installed = Get-Content -LiteralPath $installedConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        if (-not $installed.humanCabinet -or [IO.Path]::GetFullPath([string]$installed.humanCabinet).TrimEnd('\') -ine $cabinetRoot -or [string]$installed.openProtocol -ine [string]$config.openProtocol) { throw 'Installed console configuration does not match the selected cabinet.' }
        $workspace = $cabinetRoot
        $config = $installed
    }
}
$scheme = [string]$config.openProtocol
$prefix = $scheme + ':'
if (-not $Uri.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsupported console URI.' }
$route = $Uri.Substring($prefix.Length).TrimStart('/')
if ($route -notmatch '^refresh/([A-Za-z0-9_-]+)/([a-f0-9]{32})/?$') {
    throw 'The PowerShell handler only accepts console refresh requests.'
}
$payload = $Matches[1]
$requestId = $Matches[2]
$base64 = $payload.Replace('-', '+').Replace('_', '/')
switch ($base64.Length % 4) {
    2 { $base64 += '==' }
    3 { $base64 += '=' }
    1 { throw 'Invalid refresh payload padding.' }
}
try { $target = [IO.Path]::GetFullPath([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64))) }
catch { throw 'The refresh payload could not be decoded.' }

$resolvedManifest = if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    [IO.Path]::GetFullPath((Join-Path $workspace ([string]$config.openTargetManifest)))
} else {
    [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ManifestPath).Path)
}
if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) { throw 'The trusted console manifest is missing.' }
$manifest = Get-Content -Raw -Encoding utf8 -LiteralPath $resolvedManifest | ConvertFrom-Json
$registration = @($manifest.workFolders | Where-Object { $_.workFolder -and [IO.Path]::GetFullPath([string]$_.workFolder) -ieq $target })
if ($registration.Count -ne 1) { throw 'Refresh target is not a registered work folder.' }
$expectedConsole = Join-Path $target ([string]$config.consoleFileName)
if ([string]$registration[0].console -ine $expectedConsole) { throw 'Refresh registration does not match the work console.' }
$cabinet = [IO.Path]::GetFullPath([string]$config.humanCabinet).TrimEnd('\')
if ([IO.Path]::GetDirectoryName($target).TrimEnd('\') -ine $cabinet) { throw 'Refresh target is outside the human cabinet.' }
$metadataRoot = Join-Path $target ([string]$config.metadataFolderName)
foreach ($path in @($target, $metadataRoot)) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Refresh target or metadata is missing.' }
    if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refresh does not follow reparse points.' }
}

if ($ValidateOnly) {
    [ordered]@{schemaVersion='hwpx-human-refresh/v1';ok=$true;action='refresh';target=$target;launched=$false;requestId=$requestId} | ConvertTo-Json
    return
}

$ackPath = Join-Path $metadataRoot 'console-refresh.js'
$ackTemp = Join-Path $metadataRoot ('.console-refresh-' + $requestId + '.tmp')
$mutex = [Threading.Mutex]::new($false, 'Local\HwpxHumanConsoleRefresh')
$locked = $false
$success = $false
try {
    $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
    if (-not $locked) { throw 'Another console refresh is still running.' }
    & (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -WorkFolder $target | Out-Null
    $success = $true
} finally {
    $ack = [ordered]@{requestId=$requestId;ok=$success} | ConvertTo-Json -Compress
    try {
        [IO.File]::WriteAllText($ackTemp, ('window.__hwpxConsoleRefresh = ' + $ack + ';'), [Text.UTF8Encoding]::new($false))
        Move-FileOverwrite $ackTemp $ackPath
    } finally {
        if (Test-Path -LiteralPath $ackTemp -PathType Leaf) { Remove-Item -LiteralPath $ackTemp -Force }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
[ordered]@{schemaVersion='hwpx-human-refresh/v1';ok=$success;action='refresh';target=$target;launched=$true;requestId=$requestId} | ConvertTo-Json
