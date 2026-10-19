[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkFolder,
    [string[]]$ManualPath=@(),[string[]]$CurrentPath=@(),[string[]]$PriorPath=@(),
    [switch]$NoReferences
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
. (Join-Path $PSScriptRoot 'WorkReferenceScope.ps1')
$config=Get-Content -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$work=Assert-WorkStoragePath $WorkFolder
$cabinet=[IO.Path]::GetFullPath([string]$config.humanCabinet).TrimEnd('\')
if ([IO.Path]::GetDirectoryName($work) -ine $cabinet -or -not (Test-WorkFolderName -Name ([IO.Path]::GetFileName($work))) -or -not (Test-Path -LiteralPath $work -PathType Container)) { throw 'WorkFolder must be an existing direct human work folder.' }
$roots=[Collections.Generic.List[object]]::new()
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($group in @(@{role='manual';paths=$ManualPath},@{role='current-source';paths=$CurrentPath},@{role='prior-source';paths=$PriorPath})) {
    foreach ($raw in @($group.paths | Where-Object {$_})) {
        $path=if ([IO.Path]::IsPathRooted($raw)) {Assert-WorkStoragePath $raw} else {Assert-WorkStoragePath (Join-Path $work $raw)}
        if (-not (Test-Path -LiteralPath $path) -or -not (Test-ReferenceVisiblePath $path)) { throw 'Select an existing visible source file or folder.' }
        if ($path -ieq $cabinet -or $path -ieq $work) { throw 'Select specific reference materials rather than the whole cabinet or work folder.' }
        $pathBase='external';$stored=$path
        if ($path.StartsWith($work.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {$pathBase='work';$stored=$path.Substring($work.TrimEnd('\').Length+1)}
        elseif ($path.StartsWith($cabinet+'\',[StringComparison]::OrdinalIgnoreCase)) {$pathBase='cabinet';$stored=$path.Substring($cabinet.Length+1)}
        if ($seen.Add($group.role+'|'+$path)) { $roots.Add([ordered]@{role=$group.role;pathBase=$pathBase;path=$stored}) }
    }
}
if (($NoReferences -and $roots.Count) -or (-not $NoReferences -and $roots.Count -eq 0)) { throw 'Choose source paths or explicitly choose NoReferences.' }
$target=Get-WorkReferenceScopePath $work
$parent=[IO.Path]::GetDirectoryName($target)
New-Item -ItemType Directory -Path $parent -Force | Out-Null
[IO.File]::SetAttributes($parent,([IO.File]::GetAttributes($parent) -bor [IO.FileAttributes]::Hidden))
$value=[ordered]@{schemaVersion='hwpx-reference-scope/v2';selectedBy='user';selectedAt=(Get-Date -Format o);noReferences=[bool]$NoReferences;roots=@($roots)}
$temp=Join-Path $parent ('.reference-scope-'+[guid]::NewGuid().ToString('N')+'.tmp')
try {
    [IO.File]::WriteAllText($temp,($value|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $target -PathType Leaf) {[IO.File]::Replace($temp,$target,[NullString]::Value)} else {[IO.File]::Move($temp,$target)}
} finally { if (Test-Path -LiteralPath $temp) {Remove-Item -LiteralPath $temp -Force} }
@{ok=$true;scopePath=$target;selectedRoots=$roots.Count;noReferences=[bool]$NoReferences}|ConvertTo-Json
