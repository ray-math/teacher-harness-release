[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hwpx-runtime-only-'+[guid]::NewGuid().ToString('N'))
$core=Join-Path $fixture 'harness'
$cabinet=Join-Path $fixture 'cabinet'
$shared=Join-Path $core '.agent\shared'
$installed=Join-Path $cabinet '.agent\shared'
$configPath=Join-Path $core '.agent\index\delivery-system.json'
$installedConfigPath=Join-Path $cabinet '.agent\index\delivery-system.json'
$installer=Join-Path $shared 'Install-PortableCabinet.ps1'
$runtimeNames=@('Update-HumanWorkConsole.ps1','Open-HumanWorkPath.ps1','Register-HumanWorkOpenProtocol.ps1','HumanWorkOpenLauncher.cs','Initialize-PortableCabinet.ps1','WorkStorage.ps1','Resolve-TeacherHarnessConfig.ps1','bin\HumanWorkOpenLauncher.exe','bin\HumanWorkOpenLauncher.build.json')
$passed=0
$junction=''
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$script:passed++ }
function Snapshot([string]$Root,[switch]$WithoutRuntime) {
    @((Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName) | ForEach-Object {
        $relative=$_.FullName.Substring($Root.Length+1)
        if (-not $WithoutRuntime -or $relative -notin @($runtimeNames | ForEach-Object { '.agent\shared\'+$_ })) {
            $relative+'='+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }) -join '|'
}
function Fails([scriptblock]$Action,[string]$Pattern) {
    $caught=$false
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw };$caught=$true }
    Check $caught ('Expected failure: '+$Pattern)
}
function Invoke-Install { (& $installer -RuntimeOnly | Out-String) | ConvertFrom-Json }
try {
    foreach ($directory in @($shared,(Join-Path $shared 'bin'),(Join-Path $core '.agent\index'),$installed,(Join-Path $installed 'bin'),(Join-Path $cabinet '.agent\index'),(Join-Path $cabinet '20260930_test\.ai'))) { [void][IO.Directory]::CreateDirectory($directory) }
    foreach ($name in ($runtimeNames+@('Install-PortableCabinet.ps1'))) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $shared $name) }
    $config=Get-Content -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $config.humanCabinet=$cabinet
    $config.openProtocol='hwpx-runtime-only-test'
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding utf8
    Copy-Item -LiteralPath $configPath -Destination $installedConfigPath
    @{handler=(Join-Path $installed 'Open-HumanWorkPath.ps1');shell=(Get-Command powershell.exe).Source}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $cabinet '.agent\index\human-open-launcher.json') -Encoding utf8
    @{workFolders=@()}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $cabinet '.agent\index\human-open-targets.json') -Encoding utf8
    foreach ($relative in @('StartHere.html','Setup.cmd','.agent\index\runtime-install.json','20260930_test\current.hwpx','20260930_test\current_fix01_20260929.hwpx','20260930_test\console.html','20260930_test\.ai\work.json','20260930_test\.ai\sources.json')) { [IO.File]::WriteAllText((Join-Path $cabinet $relative),('preserve byte-for-byte '+$relative)) }
    foreach ($name in $runtimeNames) { [IO.File]::WriteAllText((Join-Path $installed $name),'old runtime '+$name) }
    $untouched=Snapshot $cabinet -WithoutRuntime
    $registryPath='HKCU:\Software\Classes\'+$config.openProtocol
    $registryExists=Test-Path -LiteralPath $registryPath
    $registryBefore=if ($registryExists) { Get-ItemProperty -LiteralPath $registryPath | ConvertTo-Json -Depth 8 -Compress } else { '' }
    $first=Invoke-Install
    Check ($first.ok -and $first.runtimeOnly -and -not $first.reused -and $first.changedRuntimeFiles -eq $runtimeNames.Count) 'First maintenance call must replace all runtime files including the shared work-name policy.'
    foreach ($name in $runtimeNames) { Check ((Get-FileHash -LiteralPath (Join-Path $installed $name)).Hash -eq (Get-FileHash -LiteralPath (Join-Path $shared $name)).Hash) 'Copied runtime hash mismatch.' }
    Check ((Snapshot $cabinet -WithoutRuntime) -ceq $untouched) 'Runtime maintenance changed a document or setting.'
    $installedSnapshot=Snapshot $cabinet
    $second=Invoke-Install
    Check ($second.reused -and $second.changedRuntimeFiles -eq 0) 'Second call must reuse identical runtime files.'
    Check ((Snapshot $cabinet) -ceq $installedSnapshot) 'Repeated maintenance changed installed bytes.'
    $registryAfter=if (Test-Path -LiteralPath $registryPath) { Get-ItemProperty -LiteralPath $registryPath | ConvertTo-Json -Depth 8 -Compress } else { '' }
    Check ((Test-Path -LiteralPath $registryPath) -eq $registryExists -and $registryAfter -ceq $registryBefore) 'RuntimeOnly changed protocol registration.'

    # Bad installed settings must fail before BuildOnly changes even a source build.
    $goodConfig=[IO.File]::ReadAllBytes($installedConfigPath)
    $badConfig=$config | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $badConfig.humanCabinet=Join-Path $fixture 'wrong-cabinet'
    $badConfig|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $installedConfigPath -Encoding utf8
    $before=Snapshot $fixture
    Fails { Invoke-Install } 'configuration does not match'
    Check ((Snapshot $fixture) -ceq $before) 'Invalid configuration wrote files.'
    [IO.File]::WriteAllBytes($installedConfigPath,$goodConfig)

    # An ancestor junction is rejected before source compilation or target writes.
    $junction=Join-Path $fixture 'linked-cabinet'
    New-Item -ItemType Junction -Path $junction -Target $cabinet | Out-Null
    $goodSource=[IO.File]::ReadAllBytes($configPath)
    $config.humanCabinet=$junction
    $config|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $configPath -Encoding utf8
    $beforeCore=Snapshot $core
    $beforeCabinet=Snapshot $cabinet
    Fails { Invoke-Install } 'reparse point'
    Check ((Snapshot $core) -ceq $beforeCore -and (Snapshot $cabinet) -ceq $beforeCabinet) 'A rejected junction wrote files.'
    [IO.File]::WriteAllBytes($configPath,$goodSource)
    [IO.Directory]::Delete($junction)
    $junction=''

    # Force a write failure after one successful replacement, then verify rollback.
    $firstDest=Join-Path $installed $runtimeNames[0]
    $lockedDest=Join-Path $installed $runtimeNames[1]
    [IO.File]::WriteAllBytes($firstDest,[byte[]]@())
    [IO.File]::WriteAllText($lockedDest,'read-only stale runtime')
    $attributes=[IO.File]::GetAttributes($lockedDest)
    [IO.File]::SetAttributes($lockedDest,($attributes -bor [IO.FileAttributes]::ReadOnly))
    try {
        $before=Snapshot $cabinet
        Fails { Invoke-Install } 'denied|WriteAllBytes'
        Check ((Snapshot $cabinet) -ceq $before) 'Failed transaction did not restore every previous byte, including an empty file.'
    } finally { [IO.File]::SetAttributes($lockedDest,$attributes) }
    $recovered=Invoke-Install
    Check ($recovered.ok -and $recovered.changedRuntimeFiles -eq 2) 'Runtime maintenance did not recover after failed copying.'
    Check ((Snapshot $cabinet -WithoutRuntime) -ceq $untouched) 'Maintenance or rollback changed non-runtime files.'
    [ordered]@{ok=$true;passed=$passed;fixture='synthetic runtime-only maintenance';currentFilesAndSettingsUnchanged=$true;registryChanged=$false}|ConvertTo-Json
} finally {
    if ($junction -and (Test-Path -LiteralPath $junction)) { [IO.Directory]::Delete($junction) }
    $safe=[IO.Path]::GetFullPath($fixture)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($safe) -ine $tempRoot -or [IO.Path]::GetFileName($safe) -notmatch '^hwpx-runtime-only-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $safe) {
        if (@(Get-ChildItem -LiteralPath $safe -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Unexpected reparse point in fixture cleanup.' }
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
