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
if ($RuntimeOnly) {
    if ($IncludeExternalSources) { throw 'RuntimeOnly cannot import external sources.' }
    function Assert-RuntimePath([string]$Path,[switch]$MustExist) {
        $full=[IO.Path]::GetFullPath($Path)
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
& (Join-Path $PSScriptRoot 'Register-HumanWorkOpenProtocol.ps1') -BuildOnly | Out-Null
$installedIndex=Join-Path $cabinet '.agent\index'
$stampPath=Join-Path $installedIndex 'runtime-install.json'
$signature=(@(foreach($name in $runtimeNames){(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash}) -join ':')+':'+(Get-FileHash -LiteralPath $PSCommandPath).Hash+':'+(Get-FileHash -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json')).Hash
if(-not $IncludeExternalSources -and (Test-Path -LiteralPath $stampPath)){
    $stamp=Get-Content -LiteralPath $stampPath -Raw -Encoding utf8|ConvertFrom-Json
    $valid=$stamp.signature -eq $signature -and $stamp.cabinet -ieq $cabinet
    foreach($name in $runtimeNames){$dest=Join-Path $cabinet ('.agent\shared\'+$name);if(-not(Test-Path -LiteralPath $dest) -or (Get-FileHash -LiteralPath $dest).Hash -ne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash){$valid=$false}}
    foreach($name in @('StartHere.html','Setup.cmd','.agent\index\delivery-system.json','.agent\index\human-open-targets.json')){if(-not(Test-Path -LiteralPath (Join-Path $cabinet $name))){$valid=$false}}
    if($valid){
        $internalFolders=@((Join-Path $cabinet '.agent'))+@(Get-ChildItem -LiteralPath $cabinet -Directory | Where-Object { (Test-WorkFolderName $_.Name) -and -not($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | ForEach-Object { Join-Path $_.FullName '.ai' })
        foreach($internalFolder in $internalFolders){
            if(-not(Test-Path -LiteralPath $internalFolder -PathType Container)){continue}
            $attributes=[IO.File]::GetAttributes($internalFolder)
            if($attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Internal folders must not be reparse points.'}
            [IO.File]::SetAttributes($internalFolder,($attributes -bor [IO.FileAttributes]::Hidden))
        }
        if(-not $NoRegister){
            $key='HKCU:\Software\Classes\'+$config.openProtocol+'\shell\open\command'
            $expected='"'+(Join-Path $cabinet '.agent\shared\bin\HumanWorkOpenLauncher.exe')+'" "%1"'
            if(-not(Test-Path $key) -or (Get-Item $key).GetValue('') -ne $expected){& (Join-Path $cabinet '.agent\shared\Register-HumanWorkOpenProtocol.ps1')|Out-Null}
        }
        [ordered]@{ok=$true;reused=$true;seconds=$watch.Elapsed.TotalSeconds}|ConvertTo-Json
        return
    }
}
New-Item -ItemType Directory -Path $cabinet -Force|Out-Null
$archive=Join-Path ([IO.Path]::GetTempPath()) ('hwpx-portable-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $archive -Force | Out-Null
$manifest=if(Test-Path -LiteralPath (Join-Path $cabinet $config.openTargetManifest)){Get-Content (Join-Path $cabinet $config.openTargetManifest) -Raw -Encoding utf8 | ConvertFrom-Json}else{@{workFolders=@()}}
foreach($work in $manifest.workFolders){
    if([IO.Path]::GetDirectoryName($work.workFolder) -ine $cabinet){continue}
    # Stale registrations and a missing regenerable HTML must not block runtime repair.
    if(-not(Test-Path -LiteralPath $work.workFolder -PathType Container)){continue}
    if((Get-Item -LiteralPath $work.workFolder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Registered work folder must not redirect through a reparse point.'}
    $backup=Join-Path $archive ([IO.Path]::GetFileName($work.workFolder))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    if(Test-Path -LiteralPath $work.console -PathType Leaf){Copy-Item -LiteralPath $work.console -Destination $backup}
    $selected=@(if($IncludeExternalSources){foreach($target in $work.targets){
        if(-not $target.StartsWith($cabinet+'\',[StringComparison]::OrdinalIgnoreCase)){
            [pscustomobject]@{path=$target;sha256=(Get-FileHash -LiteralPath $target).Hash;userProvided=$true;role='handover_reference';selectedAt=(Get-Date -Format o)}
        }
    }})
    if($IncludeExternalSources -and $selected.Count){ & (Join-Path $PSScriptRoot 'Sync-HumanSourcePreservation.ps1') -WorkFolder $work.workFolder -Source $selected | Out-Null }
}
$shared=Join-Path $cabinet '.agent\shared'
$index=Join-Path $cabinet '.agent\index'
New-Item -ItemType Directory -Path $shared,$index,(Join-Path $shared 'bin') -Force | Out-Null
foreach($name in @('Update-HumanWorkConsole.ps1','Open-HumanWorkPath.ps1','Register-HumanWorkOpenProtocol.ps1','HumanWorkOpenLauncher.cs','Initialize-PortableCabinet.ps1','WorkStorage.ps1')){
    $dest=Join-Path $shared $name
    if(Test-Path -LiteralPath $dest){Copy-Item -LiteralPath $dest -Destination (Join-Path $archive $name)}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $dest -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'bin\HumanWorkOpenLauncher.exe') -Destination (Join-Path $shared 'bin') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'bin\HumanWorkOpenLauncher.build.json') -Destination (Join-Path $shared 'bin') -Force
$config.humanCabinet=$cabinet
$config.incomingRoot=$cabinet
$config.PSObject.Properties.Remove('priorMaterialsRoot')
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $index 'delivery-system.json') -Encoding utf8
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
[IO.File]::WriteAllText((Join-Path $cabinet 'Setup.cmd'),($cmd -replace '\r?\n',"`r`n"),[Text.UTF8Encoding]::new($false))
$guide=@'
<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>처음 사용 안내</title>
<style>body{font:18px/1.7 system-ui;background:#f4f6f8;color:#172638;margin:0}main{max-width:720px;margin:40px auto;padding:32px;background:white;border-radius:16px}h1{font-size:30px}li{margin:16px 0}code{background:#eef2f6;padding:4px 8px}</style>
<main><h1>업무 폴더, 처음 사용하시나요?</h1><ol><li>받은 압축파일을 먼저 풀어 주세요.</li><li>이 안내와 같은 폴더의 <code>Setup.cmd</code>를 더블클릭하세요.</li><li>설정이 끝나면 선택한 업무 폴더를 열고, 그 안의 <code>업무현황.html</code>을 Edge 또는 Chrome에서 여세요.</li><li>문서 이름을 누르고 앱 실행 확인창이 나오면 ‘열기’를 선택하세요.</li></ol>
<h2>이전 자료 활용하기</h2><p>참고할 이전 자료가 필요하면 사용할 폴더나 파일을 직접 지정하세요. 선택한 파일만 현재 업무로 접수하고, 이전 자료 원본은 그대로 보존합니다.</p>
<h2>설정은 처음 한 번</h2><p>폴더를 다른 위치로 옮겼거나 다른 Windows 계정에서 사용할 때는 Setup.cmd를 다시 실행하세요. 이후에는 이 안내를 열 필요가 없습니다.</p>
<p>한글·Excel 문서를 편집하려면 해당 프로그램과 라이선스가 필요합니다. 파일 열기 설정만으로 유료 프로그램이 설치되지는 않습니다.</p><p>공유할 때는 숨겨진 파일을 포함한 업무 폴더 전체를 전달하세요.</p></main></html>
'@
[IO.File]::WriteAllText((Join-Path $cabinet 'StartHere.html'),$guide,[Text.UTF8Encoding]::new($true))
& (Join-Path $shared 'Initialize-PortableCabinet.ps1') -NoRegister:$NoRegister | Out-Null
[ordered]@{signature=$signature;cabinet=$cabinet}|ConvertTo-Json|Set-Content -LiteralPath $stampPath -Encoding utf8
[ordered]@{ok=$true;reused=$false;cabinet=$cabinet;backup=$archive;seconds=$watch.Elapsed.TotalSeconds} | ConvertTo-Json
