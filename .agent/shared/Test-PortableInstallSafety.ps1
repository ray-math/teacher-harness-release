[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hwpx-install-safety-'+[guid]::NewGuid().ToString('N'))
$core=Join-Path $fixture 'harness'
$shared=Join-Path $core '.agent\shared'
$sourceConfig=Join-Path $core '.agent\index\delivery-system.json'
$installer=Join-Path $shared 'Install-PortableCabinet.ps1'
$runtimeNames=@('Update-HumanWorkConsole.ps1','Open-HumanWorkPath.ps1','Register-HumanWorkOpenProtocol.ps1','HumanWorkOpenLauncher.cs','Initialize-PortableCabinet.ps1','WorkStorage.ps1','Resolve-TeacherHarnessConfig.ps1','bin\HumanWorkOpenLauncher.exe','bin\HumanWorkOpenLauncher.build.json')
$links=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[string]]::new()
$skipped=[Collections.Generic.List[string]]::new()
$lockedPath=''
$lockedAttributes=[IO.FileAttributes]::Normal
$scheme='hwpx-install-safety-'+[guid]::NewGuid().ToString('N')
$registryPath='HKCU:\Software\Classes\'+$scheme
function Check([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks.Add($Message)
}
function Write-Json([string]$Path,$Value) {
    [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($true))
}
function Set-Cabinet([string]$Path) {
    $script:config.humanCabinet=$Path
    $script:config.incomingRoot=$Path
    Write-Json $sourceConfig $script:config
}
function Snapshot([string]$Root) {
    # Explicit traversal stops at links, so an unsafe fixture never enumerates an external target.
    if (-not (Test-Path -LiteralPath $Root)) { return '<missing>' }
    $items=[Collections.Generic.List[string]]::new()
    $pending=[Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count) {
        $path=$pending.Pop()
        $item=Get-Item -LiteralPath $path -Force
        $relative=$path.Substring($Root.Length)
        $entry=$relative+'|'+[int]$item.Attributes
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $items.Add($entry+'|LINK|'+($item.Target -join ','))
        } elseif ($item.PSIsContainer) {
            $items.Add($entry+'|DIR')
            foreach ($child in @(Get-ChildItem -LiteralPath $path -Force)) { $pending.Push($child.FullName) }
        } else { $items.Add($entry+'|'+(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash) }
    }
    @($items|Sort-Object) -join "`n"
}
function Registry-Snapshot([string]$Path=$registryPath) {
    if (-not (Test-Path -LiteralPath $Path)) { return '<missing>' }
    $rows=@(foreach ($item in @((Get-Item -LiteralPath $Path))+@(Get-ChildItem -LiteralPath $Path -Recurse)) {
        foreach ($name in @($item.GetValueNames())) {
            $item.Name+'|'+$name+'|'+$item.GetValueKind($name)+'|'+($item.GetValue($name)|ConvertTo-Json -Compress -Depth 8)
        }
        $item.Name+'|KEY'
    })
    @($rows|Sort-Object) -join "`n"
}
function Fails([scriptblock]$Action,[string]$Pattern) {
    $caught=$false
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        $caught=$true
    }
    Check $caught ('Expected failure: '+$Pattern)
}
function Invoke-Install { (& $installer -NoRegister | Out-String) | ConvertFrom-Json }
function Remove-Link([string]$Path,[bool]$Directory) {
    if ($Directory) { [IO.Directory]::Delete($Path) } else { [IO.File]::Delete($Path) }
    for ($i=$script:links.Count-1;$i -ge 0;$i--) {
        if ($script:links[$i].path -ieq $Path) { $script:links.RemoveAt($i) }
    }
}
function Reject-WithoutWrites([string]$Cabinet,[string]$External,[string]$Label) {
    Set-Cabinet $Cabinet
    $beforeCore=Snapshot $core
    $beforeCabinet=Snapshot $Cabinet
    $beforeExternal=Snapshot $External
    Fails { Invoke-Install } 'reparse point'
    Check ((Snapshot $core) -ceq $beforeCore) ($Label+': source build and settings unchanged before rejection.')
    Check ((Snapshot $Cabinet) -ceq $beforeCabinet) ($Label+': destination unchanged before rejection.')
    Check ((Snapshot $External) -ceq $beforeExternal) ($Label+': external target hashes and attributes unchanged.')
}
try {
    foreach ($directory in @($shared,(Join-Path $core '.agent\index'))) { [void][IO.Directory]::CreateDirectory($directory) }
    # Copy current dependencies, but do not assume a checked-in bin: the real installer builds it.
    foreach ($name in ($runtimeNames|Where-Object { $_ -notlike 'bin\*' })+@('Install-PortableCabinet.ps1','Sync-HumanSourcePreservation.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $shared $name)
    }
    $script:config=Get-Content -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8|ConvertFrom-Json
    $script:config.openProtocol=$scheme
    $registryBefore=Registry-Snapshot

    # Even the initial build must wait until all intended destination paths are safe.
    $linkedCabinet=Join-Path $fixture 'agent-link-cabinet'
    $externalAgent=Join-Path $fixture 'outside-agent'
    foreach ($directory in @($linkedCabinet,$externalAgent)) { [void][IO.Directory]::CreateDirectory($directory) }
    [IO.File]::WriteAllText((Join-Path $externalAgent 'sentinel.txt'),'external agent bytes')
    $agentLink=Join-Path $linkedCabinet '.agent'
    New-Item -ItemType Junction -Path $agentLink -Target $externalAgent|Out-Null
    $links.Add(@{path=$agentLink;directory=$true})
    Reject-WithoutWrites $linkedCabinet $externalAgent '.agent junction'
    Remove-Link $agentLink $true

    $outsideParent=Join-Path $fixture 'outside-parent'
    $outsideCabinet=Join-Path $outsideParent 'cabinet'
    [void][IO.Directory]::CreateDirectory($outsideCabinet)
    [IO.File]::WriteAllText((Join-Path $outsideCabinet 'sentinel.txt'),'external parent bytes')
    $parentLink=Join-Path $fixture 'linked-parent'
    New-Item -ItemType Junction -Path $parentLink -Target $outsideParent|Out-Null
    $links.Add(@{path=$parentLink;directory=$true})
    Reject-WithoutWrites (Join-Path $parentLink 'cabinet') $outsideParent 'Cabinet ancestor junction'
    Remove-Link $parentLink $true

    $fileLinkCabinet=Join-Path $fixture 'file-link-cabinet'
    $fileLinkShared=Join-Path $fileLinkCabinet '.agent\shared'
    [void][IO.Directory]::CreateDirectory($fileLinkShared)
    $outsideFile=Join-Path $fixture 'outside-runtime.txt'
    [IO.File]::WriteAllText($outsideFile,'external runtime bytes')
    $fileLink=Join-Path $fileLinkShared 'WorkStorage.ps1'
    $madeFileLink=$false
    try {
        New-Item -ItemType SymbolicLink -Path $fileLink -Target $outsideFile -ErrorAction Stop|Out-Null
        $madeFileLink=$true
        $links.Add(@{path=$fileLink;directory=$false})
    } catch { $skipped.Add('File symbolic-link case requires Windows symbolic-link permission: '+$_.Exception.Message) }
    if ($madeFileLink) {
        Reject-WithoutWrites $fileLinkCabinet $outsideFile 'Individual runtime symbolic link'
        Remove-Link $fileLink $false
    }
    Check (-not (Test-Path -LiteralPath (Join-Path $shared 'bin'))) 'Rejected destinations did not build the source launcher.'

    $cabinet=Join-Path $fixture 'cabinet'
    $installed=Join-Path $cabinet '.agent\shared'
    $works=@((Join-Path $cabinet '20261020_First'),(Join-Path $cabinet '20261020_Second'))
    foreach ($work in $works) {
        [void][IO.Directory]::CreateDirectory((Join-Path $work '.ai'))
        Write-Json (Join-Path $work '.ai\work.json') @{title=[IO.Path]::GetFileName($work);currentFiles=@('current.hwpx');layout=@{supportFolders=@()}}
        Write-Json (Join-Path $work '.ai\sources.json') @{sources=@()}
        [IO.File]::WriteAllText((Join-Path $work 'current.hwpx'),'synthetic document - preserve')
        [IO.File]::WriteAllText((Join-Path $work 'current_fix01_20261019.hwpx'),'synthetic earlier version - preserve')
        [IO.File]::WriteAllText((Join-Path $work $config.consoleFileName),'previously requested console')
    }
    $unrequested=Join-Path $cabinet '20261020_Unrequested'
    [void][IO.Directory]::CreateDirectory((Join-Path $unrequested '.ai'))
    Write-Json (Join-Path $unrequested '.ai\work.json') @{title='No requested console';currentFiles=@();layout=@{supportFolders=@()}}
    $documentHashes=@(foreach ($work in $works) { foreach ($name in @('current.hwpx','current_fix01_20261019.hwpx','.ai\work.json','.ai\sources.json')) { $path=Join-Path $work $name;[pscustomobject]@{path=$path;hash=(Get-FileHash -LiteralPath $path).Hash} } })
    Set-Cabinet $cabinet
    $first=Invoke-Install
    Check ($first.ok -and -not $first.reused) 'First full installation succeeds and reports a fresh installation.'
    foreach ($name in $runtimeNames) { Check ((Get-FileHash -LiteralPath (Join-Path $installed $name)).Hash -eq (Get-FileHash -LiteralPath (Join-Path $shared $name)).Hash) ('Installed current runtime: '+$name) }
    Check (-not (Test-Path -LiteralPath (Join-Path $unrequested $config.consoleFileName))) 'Installation does not create a console that was never requested.'
    $beforeReuse=Snapshot $cabinet
    $second=Invoke-Install
    Check ($second.ok -and $second.reused) 'Second full installation reuses the complete installation.'
    Check ((Snapshot $cabinet) -ceq $beforeReuse) 'Reused installation preserves all cabinet bytes and attributes.'
    $resolver=Join-Path $installed 'Resolve-TeacherHarnessConfig.ps1'
    [IO.File]::Delete($resolver)
    $repaired=Invoke-Install
    Check ($repaired.ok -and -not $repaired.reused -and (Test-Path -LiteralPath $resolver)) 'A missing installed resolver invalidates reuse and is repaired.'
    [IO.File]::WriteAllText((Join-Path $installed 'Open-HumanWorkPath.ps1'),'corrupted runtime')
    $repaired=Invoke-Install
    Check ($repaired.ok -and -not $repaired.reused) 'A corrupted runtime invalidates reuse and is repaired.'
    Check ((Get-FileHash -LiteralPath (Join-Path $installed 'Open-HumanWorkPath.ps1')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $shared 'Open-HumanWorkPath.ps1')).Hash) 'Corrupted runtime is restored from the current source.'
    $launcherSettingsPath=Join-Path $cabinet '.agent\index\human-open-launcher.json'
    $launcherSettings=Get-Content -LiteralPath $launcherSettingsPath -Raw -Encoding utf8|ConvertFrom-Json
    $launcherSettings.handler=Join-Path $fixture 'wrong-handler.ps1'
    Write-Json $launcherSettingsPath $launcherSettings
    $repaired=Invoke-Install
    $launcherSettings=Get-Content -LiteralPath $launcherSettingsPath -Raw -Encoding utf8|ConvertFrom-Json
    Check ($repaired.ok -and -not $repaired.reused -and $launcherSettings.handler -ieq (Join-Path $installed 'Open-HumanWorkPath.ps1')) 'A wrong installed launcher handler invalidates reuse and is repaired.'
    [IO.File]::WriteAllText($launcherSettingsPath,'malformed launcher JSON')
    $repaired=Invoke-Install
    Check ($repaired.ok -and -not $repaired.reused) 'Malformed installed launcher JSON invalidates reuse and is repaired.'
    $installedConfigPath=Join-Path $cabinet '.agent\index\delivery-system.json'
    $installedConfig=Get-Content -LiteralPath $installedConfigPath -Raw -Encoding utf8|ConvertFrom-Json
    $installedConfig.humanCabinet=Join-Path $fixture 'wrong-installed-cabinet'
    Write-Json $installedConfigPath $installedConfig
    $repaired=Invoke-Install
    $installedConfig=Get-Content -LiteralPath $installedConfigPath -Raw -Encoding utf8|ConvertFrom-Json
    Check ($repaired.ok -and -not $repaired.reused -and $installedConfig.humanCabinet -ieq $cabinet) 'A wrong installed cabinet setting invalidates reuse and is repaired.'

    # The second payload cannot be overwritten. The first payload is deliberately empty.
    [IO.File]::WriteAllBytes((Join-Path $installed $runtimeNames[0]),[byte[]]@())
    $lockedPath=Join-Path $installed $runtimeNames[1]
    [IO.File]::WriteAllText($lockedPath,'read-only stale runtime')
    $lockedAttributes=[IO.File]::GetAttributes($lockedPath)
    [IO.File]::SetAttributes($lockedPath,($lockedAttributes -bor [IO.FileAttributes]::ReadOnly))
    try {
        $beforeFailure=Snapshot $cabinet
        Fails { Invoke-Install } 'denied|WriteAllBytes|read.only|access'
        Check ((Snapshot $cabinet) -ceq $beforeFailure) 'Copy failure restores every file, setting, console and directory attribute, including an empty runtime.'
    } finally { [IO.File]::SetAttributes($lockedPath,$lockedAttributes);$lockedPath='' }
    $recovered=Invoke-Install
    Check ($recovered.ok) 'Installation recovers after the forced copy failure is removed.'

    # Run the real initializer and both real console generators, then fail before commit.
    # The evidence lives outside the cabinet transaction and proves both consoles changed.
    $init=Join-Path $shared 'Initialize-PortableCabinet.ps1'
    $initialBytes=[IO.File]::ReadAllBytes($init)
    $marker=Join-Path $fixture 'initializer-failure-evidence.json'
    $legacyMarker=Join-Path $fixture 'legacy-preservation-evidence.txt'
    $oldConsoleHashes=@()
    foreach ($work in $works) {
        [IO.File]::WriteAllText((Join-Path $work $config.consoleFileName),'previous console before failing Initialize')
        $oldConsoleHashes+=(Get-FileHash -LiteralPath (Join-Path $work $config.consoleFileName)).Hash
        [IO.File]::SetAttributes((Join-Path $work '.ai'),[IO.FileAttributes]::Directory)
    }
    [IO.File]::SetAttributes((Join-Path $cabinet '.agent'),[IO.FileAttributes]::Directory)
    $failureTail=@'

$testCabinet=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$testHashes=@(foreach ($testName in @('20261020_First','20261020_Second')) {
    (Get-FileHash -LiteralPath (Join-Path (Join-Path $testCabinet $testName) '__CONSOLE__')).Hash
})
[IO.File]::WriteAllText('__MARKER__',($testHashes|ConvertTo-Json),[Text.UTF8Encoding]::new($true))
$testLegacy=Join-Path (Join-Path $testCabinet '20261020_First') '__ARCHIVE__\missing.txt'
if (Test-Path -LiteralPath $testLegacy) {
    [IO.File]::WriteAllText('__LEGACYMARKER__',(Get-FileHash -LiteralPath $testLegacy).Hash)
}
throw 'SYNTHETIC_INITIALIZE_FAILURE_AFTER_TWO_CONSOLES'
'@
    $failureTail=$failureTail.Replace('__MARKER__',$marker.Replace("'","''")).Replace('__CONSOLE__',([string]$config.consoleFileName).Replace("'","''"))
    $failureTail=$failureTail.Replace('__LEGACYMARKER__',$legacyMarker.Replace("'","''")).Replace('__ARCHIVE__',([string]$config.archiveFolderName).Replace("'","''"))
    [IO.File]::AppendAllText($init,$failureTail,[Text.UTF8Encoding]::new($false))
    try {
        $beforeFailure=Snapshot $cabinet
        Fails { Invoke-Install } 'SYNTHETIC_INITIALIZE_FAILURE_AFTER_TWO_CONSOLES'
        Check (Test-Path -LiteralPath $marker) 'Injected failure ran after the real initializer completed both console refreshes.'
        $changedHashes=Get-Content -LiteralPath $marker -Raw -Encoding utf8|ConvertFrom-Json
        Check ($changedHashes.Count -eq 2 -and $changedHashes[0] -ne $oldConsoleHashes[0] -and $changedHashes[1] -ne $oldConsoleHashes[1]) ('Both pre-existing requested consoles were changed before the injected failure. Expected old: '+($oldConsoleHashes -join ',')+'; observed: '+($changedHashes -join ',')+'; count: '+$changedHashes.Count)
        Check ((Snapshot $cabinet) -ceq $beforeFailure) 'Initialize failure restores runtime, configuration, manifest, both consoles and directory attributes.'

        # A pending legacy preservation can create an archive folder before Initialize fails.
        $externalSource=Join-Path $fixture 'selected-external-source.txt'
        [IO.File]::WriteAllText($externalSource,'synthetic external original - preserve')
        $externalHash=(Get-FileHash -LiteralPath $externalSource).Hash
        $externalBefore=Snapshot $externalSource
        $legacyRoot=Join-Path $works[0] ([string]$config.archiveFolderName)
        Check (-not (Test-Path -LiteralPath $legacyRoot)) 'Legacy destination directory is absent before preservation.'
        Write-Json (Join-Path $works[0] '.ai\source-preservations.json') @{schemaVersion='hwpx-source-preservations/v1';records=@(@{path=$externalSource;sha256=$externalHash;roles=@('authority');copyRelativePath=([string]$config.archiveFolderName+'\missing.txt');selectedAt='2026-10-20T00:00:00Z';preservedAt=$null;state='pending'})}
        $manifestPath=Join-Path $cabinet ([string]$config.openTargetManifest)
        $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8|ConvertFrom-Json
        $manifestEntry=@($manifest.workFolders|Where-Object { $_.workFolder -ieq $works[0] })[0]
        $manifestEntry.targets=@($manifestEntry.targets)+@($externalSource)
        Write-Json $manifestPath $manifest
        $beforeExternalFailure=Snapshot $cabinet
        Fails { & $installer -NoRegister -IncludeExternalSources } 'SYNTHETIC_INITIALIZE_FAILURE_AFTER_TWO_CONSOLES'
        Check ((Test-Path -LiteralPath $legacyMarker) -and [IO.File]::ReadAllText($legacyMarker) -eq $externalHash) 'External preservation created the recorded legacy destination before the injected failure.'
        Check ((Snapshot $cabinet) -ceq $beforeExternalFailure) 'External-source rollback restores pending ledger, manifest, consoles, runtime and the originally absent legacy directory.'
        Check ((Snapshot $externalSource) -ceq $externalBefore) 'External-source rollback preserves the selected original hash and attributes.'
    } finally { [IO.File]::WriteAllBytes($init,$initialBytes) }
    Check ((Invoke-Install).ok) 'Installation recovers after the injected initializer failure is removed.'
    Check ((Invoke-Install).reused) 'A recovered full installation can be reused.'
    foreach ($item in $documentHashes) { Check ((Get-FileHash -LiteralPath $item.path).Hash -eq $item.hash) 'Synthetic documents, earlier versions and work metadata are preserved.' }
    # Existing regression tests consume this synthetic, genuinely built source runtime.
    # Their own fixture cabinets also remain in TEMP; never build into the actual harness.
    $legacyRegistryPath='HKCU:\Software\Classes\hwpx-work-open'
    $legacyRegistryBefore=Registry-Snapshot $legacyRegistryPath
    $legacySourceConfig=Get-Content -LiteralPath $sourceConfig -Raw -Encoding utf8|ConvertFrom-Json
    $legacySourceConfig.openProtocol='hwpx-work-open'
    Write-Json $sourceConfig $legacySourceConfig
    try {
        foreach ($testName in @('Test-PortableCabinet.ps1','Test-PortableRuntimeOnly.ps1')) {
            $testPath=Join-Path $shared $testName
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $testName) -Destination $testPath
            $legacyResult=(& $testPath | Out-String)|ConvertFrom-Json
            Check ($legacyResult.ok) ('Existing regression passed in built synthetic source: '+$testName)
        }
    } finally { Write-Json $sourceConfig $config }
    Check ((Registry-Snapshot $legacyRegistryPath) -ceq $legacyRegistryBefore) 'Existing synthetic regressions preserve the standard protocol registration.'
    Check ((Registry-Snapshot) -ceq $registryBefore) 'Every -NoRegister install, rejection and rollback leaves protocol registration unchanged.'
    [ordered]@{ok=$true;passed=$checks.Count;checks=@($checks);skipped=@($skipped);fixture='synthetic full-install safety';registryChanged=$false}|ConvertTo-Json -Depth 5
} finally {
    if ($lockedPath -and (Test-Path -LiteralPath $lockedPath)) { [IO.File]::SetAttributes($lockedPath,$lockedAttributes) }
    foreach ($link in @($links.ToArray())) { Remove-Link $link.path $link.directory }
    $safe=[IO.Path]::GetFullPath($fixture)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($safe) -ine $tempRoot -or [IO.Path]::GetFileName($safe) -notmatch '^hwpx-install-safety-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $safe) {
        if ((Get-Item -LiteralPath $safe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixture root became a reparse point.' }
        if (@(Get-ChildItem -LiteralPath $safe -Recurse -Force|Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Unexpected reparse point in fixture cleanup.' }
        foreach ($file in @(Get-ChildItem -LiteralPath $safe -Recurse -File -Force)) {
            if ($file.Attributes -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($file.FullName,($file.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly))) }
        }
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
