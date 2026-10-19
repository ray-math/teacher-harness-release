[CmdletBinding()]
param([switch]$BuildOnly)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
# There is one Windows URL association. Maintenance builds stay local, but every
# registration entry point must register the cabinet runtime used by the HTML.
if (-not $BuildOnly) {
    $cabinet = [IO.Path]::GetFullPath([string]$config.humanCabinet).TrimEnd('\')
    if ($workspace.TrimEnd('\') -ine $cabinet) {
        $installedRegistration = Join-Path $cabinet '.agent\shared\Register-HumanWorkOpenProtocol.ps1'
        $installedConfigPath = Join-Path $cabinet '.agent\index\delivery-system.json'
        $matchingLocation = $false
        if (Test-Path -LiteralPath $installedConfigPath -PathType Leaf) {
            $installedConfig = Get-Content -LiteralPath $installedConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
            $matchingLocation = [IO.Path]::GetFullPath([string]$installedConfig.humanCabinet).TrimEnd('\') -ieq $cabinet
        }
        if (-not $matchingLocation -or -not (Test-Path -LiteralPath $installedRegistration -PathType Leaf)) {
            & (Join-Path $PSScriptRoot 'Install-PortableCabinet.ps1')
        } else {
            & $installedRegistration
        }
        return
    }
}
$scheme = [string]$config.openProtocol
if ([string]::IsNullOrWhiteSpace($scheme) -or $scheme -notmatch '^[a-z][a-z0-9+.-]+$') {
    throw 'The configured direct-open protocol name is invalid.'
}

$handler = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Open-HumanWorkPath.ps1'))
$source = Join-Path $PSScriptRoot 'HumanWorkOpenLauncher.cs'
$bin = Join-Path $PSScriptRoot 'bin'
$launcher = Join-Path $bin 'HumanWorkOpenLauncher.exe'
foreach ($required in @($handler, $source)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required launcher file is missing: $required" }
}

$shell = (Get-Command powershell.exe -ErrorAction Stop).Source
if (-not (Test-Path -LiteralPath $bin -PathType Container)) { New-Item -ItemType Directory -Path $bin -Force | Out-Null }
$csc = @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $csc) { throw 'The Windows .NET Framework compiler is unavailable.' }
$automationAssembly = (& $shell -NoProfile -Command '[System.Management.Automation.PowerShell].Assembly.Location' | Select-Object -Last 1)
if (-not (Test-Path -LiteralPath $automationAssembly -PathType Leaf)) { throw 'Windows PowerShell 5.1 hosting assembly is unavailable.' }

$buildReceiptPath = Join-Path $bin 'HumanWorkOpenLauncher.build.json'
$sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
$buildIdentity = [ordered]@{
    sourceSha256 = $sourceHash
    registrationScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    automationAssemblySha256 = (Get-FileHash -LiteralPath $automationAssembly -Algorithm SHA256).Hash
    compilerSha256 = (Get-FileHash -LiteralPath $csc -Algorithm SHA256).Hash
}
$reuseBuild = $false
if ((Test-Path -LiteralPath $launcher -PathType Leaf) -and (Test-Path -LiteralPath $buildReceiptPath -PathType Leaf)) {
    try {
        $previousBuild = Get-Content -LiteralPath $buildReceiptPath -Raw -Encoding utf8 | ConvertFrom-Json
        $reuseBuild = $previousBuild.launcherSha256 -eq (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
        foreach ($key in $buildIdentity.Keys) { if ($previousBuild.$key -ne $buildIdentity[$key]) { $reuseBuild = $false } }
    } catch { $reuseBuild = $false }
}
if (-not $reuseBuild) {
    $candidate = Join-Path $bin ('HumanWorkOpenLauncher-build-' + [guid]::NewGuid().ToString('N') + '.exe')
    try {
        & $csc /nologo /target:winexe /optimize+ /reference:System.Web.Extensions.dll "/reference:$automationAssembly" "/out:$candidate" $source
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'Failed to build the native direct-open launcher.' }
        Move-Item -LiteralPath $candidate -Destination $launcher -Force
        $buildIdentity.launcherSha256 = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
        $buildIdentity | ConvertTo-Json | Set-Content -LiteralPath $buildReceiptPath -Encoding utf8
    } finally { if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force } }
}
if ($BuildOnly) { [ordered]@{ok=$true;launcher=$launcher;hosting='Windows PowerShell 5.1';registryChanged=$false;reusedBuild=$reuseBuild;sourceSha256=$sourceHash;launcherSha256=(Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash} | ConvertTo-Json; return }

$launcherConfigPath = Join-Path $workspace '.agent\index\human-open-launcher.json'
[ordered]@{
    schemaVersion = 'hwpx-human-open-launcher/v3'
    shell = $shell
    handler = $handler
} | ConvertTo-Json | Set-Content -LiteralPath $launcherConfigPath -Encoding utf8

$root = "HKCU:\Software\Classes\$scheme"
$commandPath = Join-Path $root 'shell\open\command'
New-Item -Path $commandPath -Force | Out-Null
Set-Item -LiteralPath $root -Value 'URL:업무 파일 열기 및 목록 새로고침'
New-ItemProperty -LiteralPath $root -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
$command = '"' + $launcher + '" "%1"'
Set-Item -LiteralPath $commandPath -Value $command

# Notify already-running shell clients after changing an association. Updating
# registry values alone does not invalidate their cached protocol information.
if (-not ('HumanWorkAssociationNotification' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HumanWorkAssociationNotification {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
}
'@
}
[HumanWorkAssociationNotification]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero)

# Browser preferences and policies stay user-owned. A browser may ask once whether
# the local console may open this registered helper.
[ordered]@{
    schemaVersion = 'hwpx-human-open-registration/v4'
    ok = $true
    protocol = $scheme
    registryPath = $root
    launcher = $launcher
    command = $command
    browserSettingsChanged = $false
    shellAssociationChangeNotified = $true
    browserConfirmationMayAppear = $true
} | ConvertTo-Json -Depth 3
