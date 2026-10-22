[CmdletBinding()]
param([switch]$IncludeExternalSources,[switch]$NoRegister,[switch]$RuntimeOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config=Get-Content (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$cabinet=[IO.Path]::GetFullPath($config.humanCabinet)
$watch=[Diagnostics.Stopwatch]::StartNew()
$runtimeNames=@('Update-HumanWorkConsole.ps1','Open-HumanWorkPath.ps1','Register-HumanWorkOpenProtocol.ps1','HumanWorkOpenLauncher.cs','Initialize-PortableCabinet.ps1','WorkStorage.ps1','Resolve-TeacherHarnessConfig.ps1','bin\HumanWorkOpenLauncher.exe','bin\HumanWorkOpenLauncher.build.json')
function Assert-RuntimePath([string]$Path,[switch]$MustExist) {
    $full=Assert-WorkStoragePath $Path
    if ($full.Length -ge 260) { throw 'Runtime path exceeds the supported Windows PowerShell 5.1 path length.' }
    if ($MustExist -and -not (Test-Path -LiteralPath $full)) { throw 'Required installed runtime path is missing.' }
    $part=$full
    while ($part) {
        if (Test-Path -LiteralPath $part) {
            if ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Runtime paths must not traverse a reparse point.' }
        }
        $parent=[IO.Path]::GetDirectoryName($part)
        if ($parent -eq $part) { break }
        $part=$parent
    }
    return $full
}
if ($RuntimeOnly) {
    if ($IncludeExternalSources) { throw 'RuntimeOnly cannot import external sources.' }
    if (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'RuntimeOnly needs an absolute configured cabinet.' }
    $cabinet=(Assert-RuntimePath $cabinet -MustExist).TrimEnd('\')
    $installedShared=Assert-RuntimePath (Join-Path $cabinet '.agent\shared') -MustExist
    $installedBin=Assert-RuntimePath (Join-Path $installedShared 'bin') -MustExist
    $installedConfigPath=Assert-RuntimePath (Join-Path $cabinet '.agent\index\delivery-system.json') -MustExist
    $installedConfig=Get-Content -LiteralPath $installedConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not [IO.Path]::IsPathRooted([string]$installedConfig.humanCabinet) -or [IO.Path]::GetFullPath([string]$installedConfig.humanCabinet).TrimEnd('\') -ine $cabinet) { throw 'Installed cabinet configuration does not match the selected cabinet.' }
    if ([string]$installedConfig.openProtocol -cne [string]$config.openProtocol -or [string]$installedConfig.openProtocol -notmatch '^[a-z][a-z0-9+.-]+$') { throw 'Installed protocol configuration does not match the runtime source.' }
    if ([string]$installedConfig.openTargetManifest -cne [string]$config.openTargetManifest -or [string]::IsNullOrWhiteSpace([string]$installedConfig.openTargetManifest) -or [IO.Path]::IsPathRooted([string]$installedConfig.openTargetManifest)) { throw 'Installed manifest configuration does not match the runtime source.' }
    $manifestPath=[IO.Path]::GetFullPath((Join-Path $cabinet ([string]$installedConfig.openTargetManifest)))
    if (-not $manifestPath.StartsWith($cabinet+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Installed manifest must stay inside the cabinet.' }
    [void](Assert-RuntimePath $manifestPath -MustExist)
    $null=Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $launcherConfigPath=Assert-RuntimePath (Join-Path $cabinet '.agent\index\human-open-launcher.json') -MustExist
    $launcherConfig=Get-Content -LiteralPath $launcherConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not [IO.Path]::IsPathRooted([string]$launcherConfig.handler) -or [IO.Path]::GetFullPath([string]$launcherConfig.handler) -ine (Join-Path $installedShared 'Open-HumanWorkPath.ps1')) { throw 'Installed launcher handler does not match the selected cabinet.' }
    [void](Assert-RuntimePath (Join-Path $workspace '.agent\index\delivery-system.json') -MustExist)
    foreach ($name in $runtimeNames) {
        $source=Assert-RuntimePath (Join-Path $PSScriptRoot $name)
        $destination=Assert-RuntimePath (Join-Path $installedShared $name)
        if ((Test-Path -LiteralPath $source -PathType Container) -or (Test-Path -LiteralPath $destination -PathType Container)) { throw 'Runtime payload paths must be files.' }
    }
    # Validate both installations before a build, copy, or setting change. BuildOnly
    # only updates the maintenance runtime; never invoke registration or Setup here.
    & (Join-Path $PSScriptRoot 'Register-HumanWorkOpenProtocol.ps1') -BuildOnly | Out-Null
    $payloads=@(foreach ($name in $runtimeNames) {
        $source=Assert-RuntimePath (Join-Path $PSScriptRoot $name) -MustExist
        $destination=Assert-RuntimePath (Join-Path $installedShared $name)
        $previous=$null
        $previousHash=''
        if (Test-Path -LiteralPath $destination -PathType Leaf) { $previous=[IO.File]::ReadAllBytes($destination);$previousHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash }
        [pscustomobject]@{name=$name;destination=$destination;bytes=[IO.File]::ReadAllBytes($source);hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash;previous=$previous;previousHash=$previousHash;existed=(Test-Path -LiteralPath $destination -PathType Leaf);changed=$false}
    })
    $changed=0
    try {
        foreach ($item in $payloads) {
            [void](Assert-RuntimePath $item.destination)
            if ($item.existed -and (Get-FileHash -LiteralPath $item.destination -Algorithm SHA256).Hash -eq $item.hash) { continue }
            $item.changed=$true
            [IO.File]::WriteAllBytes($item.destination,$item.bytes)
            if ((Get-FileHash -LiteralPath $item.destination -Algorithm SHA256).Hash -ne $item.hash) { throw 'Runtime copy verification failed.' }
            $changed++
        }
        foreach ($item in $payloads) {
            [void](Assert-RuntimePath $item.destination -MustExist)
            if ((Get-FileHash -LiteralPath $item.destination -Algorithm SHA256).Hash -ne $item.hash) { throw 'Runtime verification failed.' }
        }
    } catch {
        $failure=$_
        $rollbackErrors=@()
        for ($i=$payloads.Count-1;$i -ge 0;$i--) {
            $item=$payloads[$i]
            if (-not $item.changed) { continue }
            try {
                [void](Assert-RuntimePath $item.destination)
                if ($item.existed) {
                    if ((Test-Path -LiteralPath $item.destination -PathType Leaf) -and (Get-FileHash -LiteralPath $item.destination -Algorithm SHA256).Hash -eq $item.previousHash) { continue }
                    [IO.File]::WriteAllBytes($item.destination,[byte[]]$item.previous)
                    if ((Get-FileHash -LiteralPath $item.destination -Algorithm SHA256).Hash -ne $item.previousHash) { throw 'Runtime rollback verification failed.' }
                }
                elseif (Test-Path -LiteralPath $item.destination) { Remove-Item -LiteralPath $item.destination -Force }
            } catch { $rollbackErrors+= $_.Exception.Message }
        }
        if ($rollbackErrors.Count) { throw ('Runtime update failed and rollback needs attention: '+($rollbackErrors -join '; ')) }
        throw $failure
    }
    [ordered]@{ok=$true;runtimeOnly=$true;reused=($changed -eq 0);changedRuntimeFiles=$changed;cabinet=$cabinet;settingsChanged=$false;registryChanged=$false;seconds=$watch.Elapsed.TotalSeconds}|ConvertTo-Json
    return
}
# Full installation uses the same path boundary as RuntimeOnly, before even a build.
$cabinet=(Assert-RuntimePath $cabinet).TrimEnd('\')
if ($cabinet -ieq ([IO.Path]::GetPathRoot($cabinet).TrimEnd('\'))) { throw 'The cabinet must be a dedicated directory, not a drive root.' }
if ($cabinet -ieq $workspace.TrimEnd('\')) { throw 'The cabinet must be separate from the maintenance harness.' }
if ([string]$config.openProtocol -notmatch '^[a-z][a-z0-9+.-]+$') { throw 'Invalid direct-open protocol.' }
foreach ($name in @('consoleFileName','metadataFolderName','workMetadataName','archiveFolderName')) {
    $value=[string]$config.$name
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\\/:*?"<>|\x00-\x1f]' -or $value -in @('.','..') -or $value.TrimEnd(' ','.') -cne $value) { throw "Invalid cabinet filename setting: $name" }
}
$shared=Join-Path $cabinet '.agent\shared'
$index=Join-Path $cabinet '.agent\index'
$stampPath=Join-Path $index 'runtime-install.json'
$manifestPath=[IO.Path]::GetFullPath((Join-Path $cabinet ([string]$config.openTargetManifest)))
if (-not $manifestPath.StartsWith($index+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'The open-target manifest must stay inside the cabinet runtime index.' }
foreach ($path in @($cabinet,(Join-Path $cabinet '.agent'),$shared,$index,(Join-Path $shared 'bin'))) {
    [void](Assert-RuntimePath $path)
    if (Test-Path -LiteralPath $path -PathType Leaf) { throw 'Runtime directory path is occupied by a file.' }
}
foreach ($name in $runtimeNames) {
    $source=Assert-RuntimePath (Join-Path $PSScriptRoot $name)
    $dest=Assert-RuntimePath (Join-Path $shared $name)
    if ((Test-Path -LiteralPath $source -PathType Container) -or (Test-Path -LiteralPath $dest -PathType Container)) { throw 'Runtime payload paths must be files.' }
    if (-not $name.StartsWith('bin\') -and -not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Required source runtime file is missing.' }
}
foreach ($path in @($manifestPath,$stampPath,(Join-Path $index 'delivery-system.json'),(Join-Path $index 'human-open-launcher.json'),(Join-Path $cabinet 'StartHere.html'),(Join-Path $cabinet 'Setup.cmd'))) {
    [void](Assert-RuntimePath $path)
    if (Test-Path -LiteralPath $path -PathType Container) { throw 'Runtime output path is occupied by a directory.' }
}

# Serialize installation with console publication; nested console updates use this
# process/thread's reentrant mutex, while other readers cannot publish mid-rollback.
$installMutex=[Threading.Mutex]::new($false,'Local\HwpxHumanOpenTargets')
$installLocked=$false
$journal=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$trees=[Collections.Generic.List[string]]::new()
$registryBefore=@()
$registryTouched=$false
$transactionStarted=$false
function Get-InstallItems([string]$Path) {
    [void](Assert-RuntimePath $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item=Get-Item -LiteralPath $Path -Force
    $item
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Force) {
            # Check a child before recursing, never traverse a junction to inspect it.
            Get-InstallItems $child.FullName
        }
    }
}
function Save-InstallPath([string]$Path,[switch]$Tree) {
    $full=Assert-RuntimePath $Path
    if ($full -ine $cabinet -and -not $full.StartsWith($cabinet+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Installation snapshots must stay inside the selected cabinet.' }
    if ($Tree -and -not $trees.Contains($full)) { $trees.Add($full) }
    $items=if ($Tree) { @(Get-InstallItems $full) } elseif (Test-Path -LiteralPath $full) { @(Get-Item -LiteralPath $full -Force) } else { @() }
    if (-not $items.Count -and -not $journal.ContainsKey($full)) { $journal.Add($full,[pscustomobject]@{path=$full;existed=$false;directory=$false;bytes=$null;attributes=0;time=$null}) }
    foreach ($item in $items) {
        if ($journal.ContainsKey($item.FullName)) { continue }
        $bytes=$null
        if (-not $item.PSIsContainer) { $bytes=[IO.File]::ReadAllBytes($item.FullName) }
        $journal.Add($item.FullName,[pscustomobject]@{path=$item.FullName;existed=$true;directory=[bool]$item.PSIsContainer;bytes=$bytes;attributes=$item.Attributes;time=$item.LastWriteTimeUtc})
    }
}
function New-InstallDirectory([string]$Path) {
    [void](Assert-RuntimePath $Path)
    if (Test-Path -LiteralPath $Path -PathType Container) { return }
    Save-InstallPath $Path
    $parent=[IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-InstallDirectory $parent }
    [void][IO.Directory]::CreateDirectory($Path)
}
function Write-InstallFile([string]$Path,[byte[]]$Bytes) {
    [void](Assert-RuntimePath $Path)
    Save-InstallPath $Path
    New-InstallDirectory ([IO.Path]::GetDirectoryName($Path))
    $temporary=Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.install-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [void](Assert-RuntimePath $temporary)
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        $hash=(Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
        [void](Assert-RuntimePath $Path)
        [IO.File]::Copy($temporary,$Path,$true)
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $hash) { throw 'Installed file verification failed.' }
    } finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { [IO.File]::Delete($temporary) } }
}
function Restore-Install {
    # Remove only entries created in managed trees, then restore their old bytes.
    foreach ($tree in $trees) {
        foreach ($item in @(Get-InstallItems $tree | Sort-Object { $_.FullName.Length } -Descending)) {
            if ($journal.ContainsKey($item.FullName) -and $journal[$item.FullName].existed) { continue }
            [void](Assert-RuntimePath $item.FullName)
            if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName) } else { [IO.File]::Delete($item.FullName) }
        }
    }
    foreach ($entry in @($journal.Values | Where-Object { -not $_.directory } | Sort-Object { $_.path.Length } -Descending)) {
        [void](Assert-RuntimePath $entry.path)
        if (-not $entry.existed) {
            if (Test-Path -LiteralPath $entry.path -PathType Leaf) { [IO.File]::Delete($entry.path) }
            elseif (Test-Path -LiteralPath $entry.path -PathType Container) { [IO.Directory]::Delete($entry.path) }
            continue
        }
        $same=$false
        if (Test-Path -LiteralPath $entry.path -PathType Leaf) {
            $sha=[Security.Cryptography.SHA256]::Create()
            try { $oldHash=[BitConverter]::ToString($sha.ComputeHash([byte[]]$entry.bytes)) } finally { $sha.Dispose() }
            $same=(Get-FileHash -LiteralPath $entry.path -Algorithm SHA256).Hash -ceq $oldHash.Replace('-','')
        }
        if (-not $same) { [IO.File]::WriteAllBytes($entry.path,[byte[]]$entry.bytes) }
        [IO.File]::SetAttributes($entry.path,$entry.attributes)
        [IO.File]::SetLastWriteTimeUtc($entry.path,$entry.time)
    }
    foreach ($entry in @($journal.Values | Where-Object { $_.directory } | Sort-Object { $_.path.Length } -Descending)) {
        [void](Assert-RuntimePath $entry.path)
        [IO.File]::SetAttributes($entry.path,$entry.attributes)
        [IO.Directory]::SetLastWriteTimeUtc($entry.path,$entry.time)
    }
}
function Save-InstallRegistration {
    foreach ($suffix in @('','\shell','\shell\open','\shell\open\command')) {
        $path='Software\Classes\'+$config.openProtocol+$suffix
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
        $values=@()
        if ($null -ne $key) {
            try { foreach ($name in $key.GetValueNames()) { $values+= [pscustomobject]@{name=$name;value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);kind=$key.GetValueKind($name)} } } finally { $key.Dispose() }
        }
        [pscustomobject]@{path=$path;existed=($null -ne $key);values=$values}
    }
}
function Restore-InstallRegistration {
    foreach ($entry in @($registryBefore | Sort-Object { $_.path.Length } -Descending)) {
        if (-not $entry.existed) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($entry.path,$false);continue }
        $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($entry.path)
        try {
            foreach ($name in $key.GetValueNames()) { if ($name -notin @($entry.values | ForEach-Object { $_.name })) { $key.DeleteValue($name,$false) } }
            foreach ($value in $entry.values) { $key.SetValue($value.name,$value.value,$value.kind) }
        } finally { $key.Dispose() }
    }
}
try {
    try { $installLocked=$installMutex.WaitOne([TimeSpan]::FromSeconds(15)) } catch [Threading.AbandonedMutexException] { $installLocked=$true }
    if (-not $installLocked) { throw 'Timed out waiting for cabinet installation.' }
    # Snapshot only the installed runtime and explicitly affected work metadata/HTML.
    # Backup bytes stay in memory; no school information is left in TEMP diagnostics.
    Save-InstallPath $cabinet
    Save-InstallPath (Join-Path $cabinet '.agent') -Tree
    Save-InstallPath (Join-Path $cabinet 'Setup.cmd')
    Save-InstallPath (Join-Path $cabinet 'StartHere.html')
    if (Test-Path -LiteralPath $cabinet -PathType Container) {
        foreach ($work in Get-ChildItem -LiteralPath $cabinet -Directory -Force) {
            if (-not (Test-WorkFolderName $work.Name) -or ($work.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $meta=Join-Path $work.FullName '.ai'
            if (-not (Test-Path -LiteralPath (Join-Path $meta 'work.json') -PathType Leaf)) { continue }
            Save-InstallPath $work.FullName
            Save-InstallPath $meta -Tree:$IncludeExternalSources
            Save-InstallPath (Join-Path $work.FullName ([string]$config.consoleFileName))
        }
    }
    $manifest=if(Test-Path -LiteralPath $manifestPath){Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json}else{@{workFolders=@()}}
    # Validate external-source import destinations before build or preservation writes.
    foreach ($work in $manifest.workFolders) {
        if ([IO.Path]::GetDirectoryName([string]$work.workFolder) -ine $cabinet -or -not (Test-Path -LiteralPath $work.workFolder -PathType Container)) { continue }
        [void](Assert-RuntimePath $work.workFolder)
        if ($IncludeExternalSources) {
            Save-InstallPath (Join-Path $work.workFolder ([string]$config.metadataFolderName)) -Tree
            # Legacy preservation records can restore a missing copy in this tree.
            Save-InstallPath (Join-Path $work.workFolder ([string]$config.archiveFolderName)) -Tree
        }
    }
    & (Join-Path $PSScriptRoot 'Register-HumanWorkOpenProtocol.ps1') -BuildOnly | Out-Null
    # Stage and verify the complete payload before changing any cabinet file.
    $payloads=@(foreach ($name in $runtimeNames) {
        $source=Assert-RuntimePath (Join-Path $PSScriptRoot $name) -MustExist
        [pscustomobject]@{path=(Join-Path $shared $name);bytes=[IO.File]::ReadAllBytes($source);hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash}
    })
    $signature=(@($payloads | ForEach-Object { $_.hash }) -join ':')+':'+(Get-FileHash -LiteralPath $PSCommandPath).Hash+':'+(Get-FileHash -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json')).Hash
    $valid=$false
    if (-not $IncludeExternalSources -and (Test-Path -LiteralPath $stampPath -PathType Leaf)) {
        try {
            $stamp=Get-Content -LiteralPath $stampPath -Raw -Encoding utf8 | ConvertFrom-Json
            $valid=$stamp.signature -ceq $signature -and $stamp.cabinet -ieq $cabinet
            foreach ($item in $payloads) { if (-not (Test-Path -LiteralPath $item.path -PathType Leaf) -or (Get-FileHash -LiteralPath $item.path).Hash -cne $item.hash) { $valid=$false } }
            foreach ($path in @((Join-Path $cabinet 'StartHere.html'),(Join-Path $cabinet 'Setup.cmd'),(Join-Path $index 'delivery-system.json'),(Join-Path $index 'human-open-launcher.json'),$manifestPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $valid=$false } }
            $installedConfig=Get-Content -LiteralPath (Join-Path $index 'delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
            if ([IO.Path]::GetFullPath([string]$installedConfig.humanCabinet).TrimEnd('\') -ine $cabinet -or [IO.Path]::GetFullPath([string]$installedConfig.incomingRoot).TrimEnd('\') -ine $cabinet) { $valid=$false }
            foreach ($name in @('openProtocol','openTargetManifest','consoleFileName','metadataFolderName','workMetadataName')) { if ([string]$installedConfig.$name -cne [string]$config.$name) { $valid=$false } }
            $launcherSettings=Get-Content -LiteralPath (Join-Path $index 'human-open-launcher.json') -Raw -Encoding utf8 | ConvertFrom-Json
            if ([string]$launcherSettings.handler -ine (Join-Path $shared 'Open-HumanWorkPath.ps1') -or [string]$launcherSettings.shell -ine (Get-Command powershell.exe -ErrorAction Stop).Source) { $valid=$false }
            foreach ($entry in $manifest.workFolders) { foreach ($target in $entry.targets) { if (-not ([string]$target).StartsWith($cabinet+'\',[StringComparison]::OrdinalIgnoreCase)) { $valid=$false } } }
        } catch { $valid=$false }
    }
    $transactionStarted=$true
    if (-not $valid) {
        foreach ($work in $manifest.workFolders) {
            if ([IO.Path]::GetDirectoryName([string]$work.workFolder) -ine $cabinet -or -not (Test-Path -LiteralPath $work.workFolder -PathType Container)) { continue }
            $selected=@(if ($IncludeExternalSources) { foreach ($target in $work.targets) {
                if (-not $target.StartsWith($cabinet+'\',[StringComparison]::OrdinalIgnoreCase)) { [pscustomobject]@{path=$target;sha256=(Get-FileHash -LiteralPath $target).Hash;userProvided=$true;role='handover_reference';selectedAt=(Get-Date -Format o)} }
            } })
            if ($selected.Count) { & (Join-Path $PSScriptRoot 'Sync-HumanSourcePreservation.ps1') -WorkFolder $work.workFolder -Source $selected | Out-Null }
        }
        foreach ($item in $payloads) { Write-InstallFile $item.path $item.bytes }
        $config.humanCabinet=$cabinet
        $config.incomingRoot=$cabinet
        $config.PSObject.Properties.Remove('priorMaterialsRoot')
        Write-InstallFile (Join-Path $index 'delivery-system.json') ([Text.UTF8Encoding]::new($true).GetBytes(($config | ConvertTo-Json -Depth 10)))
$cmd=@'
@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0.agent\shared\Initialize-PortableCabinet.ps1"
if errorlevel 1 (
  echo 설정에 실패했습니다. 위의 오류 내용을 확인해 주세요.
) else (
  echo 설정이 끝났습니다. 선택한 업무 폴더 안의 업무현황.html을 Edge 또는 Chrome에서 열어 주세요.
)
pause
'@
        Write-InstallFile (Join-Path $cabinet 'Setup.cmd') ([Text.UTF8Encoding]::new($false).GetBytes(($cmd -replace '\r?\n',"`r`n")))
$guide=@'
<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>처음 사용 안내</title>
<style>body{font:18px/1.7 system-ui;background:#f4f6f8;color:#172638;margin:0}main{max-width:720px;margin:40px auto;padding:32px;background:white;border-radius:16px}h1{font-size:30px}li{margin:16px 0}code{background:#eef2f6;padding:4px 8px}</style>
<main><h1>업무 폴더, 처음 사용하시나요?</h1><ol><li>받은 압축파일을 먼저 풀어 주세요.</li><li>이 안내와 같은 폴더의 <code>Setup.cmd</code>를 더블클릭하세요.</li><li>설정이 끝나면 선택한 업무 폴더를 열고, 그 안의 <code>업무현황.html</code>을 Edge 또는 Chrome에서 여세요.</li><li>문서 이름을 누르고 앱 실행 확인창이 나오면 ‘열기’를 선택하세요.</li></ol>
<h2>이전 자료 활용하기</h2><p>참고할 이전 자료가 필요하면 사용할 폴더나 파일을 직접 지정하세요. 선택한 파일만 현재 업무로 접수하고, 이전 자료 원본은 그대로 보존합니다.</p>
<h2>설정은 처음 한 번</h2><p>폴더를 다른 위치로 옮겼거나 다른 Windows 계정에서 사용할 때는 Setup.cmd를 다시 실행하세요. 이후에는 이 안내를 열 필요가 없습니다.</p>
<p>한글·Excel 문서를 편집하려면 해당 프로그램과 라이선스가 필요합니다. 파일 열기 설정만으로 유료 프로그램이 설치되지는 않습니다.</p><p>공유할 때는 숨겨진 파일을 포함한 업무 폴더 전체를 전달하세요.</p></main></html>
'@
        Write-InstallFile (Join-Path $cabinet 'StartHere.html') ([Text.UTF8Encoding]::new($true).GetBytes($guide))
        $launcherSettings=[ordered]@{schemaVersion='hwpx-human-open-launcher/v3';shell=(Get-Command powershell.exe -ErrorAction Stop).Source;handler=(Join-Path $shared 'Open-HumanWorkPath.ps1')}
        Write-InstallFile (Join-Path $index 'human-open-launcher.json') ([Text.UTF8Encoding]::new($true).GetBytes(($launcherSettings | ConvertTo-Json)))
        & (Join-Path $shared 'Initialize-PortableCabinet.ps1') -NoRegister | Out-Null
        Write-InstallFile $stampPath ([Text.UTF8Encoding]::new($true).GetBytes(([ordered]@{signature=$signature;cabinet=$cabinet}|ConvertTo-Json)))
    } else {
        foreach ($entry in $journal.Values) {
            if ($entry.directory -and ([IO.Path]::GetFileName($entry.path) -in @('.agent','.ai'))) { [IO.File]::SetAttributes($entry.path,($entry.attributes -bor [IO.FileAttributes]::Hidden)) }
        }
    }
    # Registration is the last step. Roll back only this protocol's own key values.
    if (-not $NoRegister) {
        $registryBefore=@(Save-InstallRegistration)
        $registryTouched=$true
        & (Join-Path $shared 'Register-HumanWorkOpenProtocol.ps1') | Out-Null
    }
    [ordered]@{ok=$true;reused=$valid;cabinet=$cabinet;backup=$null;seconds=$watch.Elapsed.TotalSeconds}|ConvertTo-Json
} catch {
    $failure=$_
    $rollbackErrors=@()
    if ($registryTouched) { try { Restore-InstallRegistration } catch { $rollbackErrors+=$_.Exception.Message } }
    if ($transactionStarted) { try { Restore-Install } catch { $rollbackErrors+=$_.Exception.Message } }
    if ($rollbackErrors.Count) { throw ('Cabinet installation failed and rollback needs attention: '+($rollbackErrors -join '; ')) }
    throw $failure
} finally {
    if ($installLocked) { $installMutex.ReleaseMutex() }
    $installMutex.Dispose()
}
