[CmdletBinding()]
param([switch]$NoRegister)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$cabinet=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$runtimeFolder=Join-Path $cabinet '.agent'
if([IO.File]::GetAttributes($runtimeFolder) -band [IO.FileAttributes]::ReparsePoint){throw 'Runtime folder must not be a reparse point.'}
[IO.File]::SetAttributes($runtimeFolder,([IO.File]::GetAttributes($runtimeFolder) -bor [IO.FileAttributes]::Hidden))
$configPath=Join-Path $cabinet '.agent\index\delivery-system.json'
$config=Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $cabinet -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$previousCabinet=if($config.previousCabinet){[string]$config.previousCabinet}else{[string]$config.humanCabinet}
$config | Add-Member -NotePropertyName portableCabinet -NotePropertyValue $true -Force
$config | Add-Member -NotePropertyName previousCabinet -NotePropertyValue $previousCabinet -Force
$config.humanCabinet=$cabinet
$config.incomingRoot=$cabinet
$config.PSObject.Properties.Remove('priorMaterialsRoot')
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding utf8
$manifestPath=Join-Path $cabinet $config.openTargetManifest
if(-not(Test-Path -LiteralPath $manifestPath)){
    @{schemaVersion='hwpx-human-open-targets/v1';workFolders=@()}|ConvertTo-Json|Set-Content -LiteralPath $manifestPath -Encoding utf8
}
if(Test-Path -LiteralPath $manifestPath){
    $old=Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
    $old.workFolders=@($old.workFolders | Where-Object { [IO.Path]::GetDirectoryName($_.workFolder) -ieq $cabinet })
    $old | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
}
$count=0
foreach($work in Get-ChildItem -LiteralPath $cabinet -Directory) {
    if(-not (Test-WorkFolderName $work.Name) -or ($work.Attributes -band [IO.FileAttributes]::ReparsePoint)) {continue}
    if(-not(Test-Path -LiteralPath (Join-Path $work.FullName '.ai\work.json'))) {continue}
    $metaFolder=Join-Path $work.FullName '.ai'
    if([IO.File]::GetAttributes($metaFolder) -band [IO.FileAttributes]::ReparsePoint){throw 'Metadata folder must not be a reparse point.'}
    [IO.File]::SetAttributes($metaFolder,([IO.File]::GetAttributes($metaFolder) -bor [IO.FileAttributes]::Hidden))
    # Setup refreshes an existing requested console; metadata alone does not request one.
    if(-not(Test-Path -LiteralPath (Join-Path $work.FullName ([string]$config.consoleFileName)) -PathType Leaf)){continue}
    & (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -WorkFolder $work.FullName | Out-Null
    $count++
}
$manifest=Get-Content -LiteralPath (Join-Path $cabinet $config.openTargetManifest) -Raw -Encoding utf8 | ConvertFrom-Json
foreach($entry in $manifest.workFolders){foreach($target in $entry.targets){
    if(-not $target.StartsWith($cabinet.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'A console still depends on a file outside this folder.'}
}}

if(-not $NoRegister){ & (Join-Path $PSScriptRoot 'Register-HumanWorkOpenProtocol.ps1') | Out-Null }
Write-Output ('Setup complete. Work folders: '+$count)
