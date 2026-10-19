[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CabinetRoot,
    [string]$ExpectedPreviousRoot='',
    [switch]$BindLegacyJobs,
    [switch]$Apply
)

# Explicit selection only. This never moves folders, edits documents, installs a
# runtime, registers a URL handler, or rewrites historical source/receipt paths.
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$configPath=Assert-WorkStoragePath (Join-Path $workspace '.agent\index\delivery-system.json')
$config=Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
if (-not [IO.Path]::IsPathRooted($CabinetRoot)) { throw 'CabinetRoot must be an explicit absolute path.' }
$target=Assert-WorkStoragePath $CabinetRoot
$target=$target.TrimEnd('\')
if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw 'Select an existing cabinet folder; no folder is created automatically.' }
if ($target -ieq [IO.Path]::GetPathRoot($target).TrimEnd('\') -or $target -ieq $workspace -or $target.StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase) -or $workspace.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'A cabinet must be a distinct work folder outside the tool workspace.' }
if ((Get-Item -LiteralPath $target -Force).Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) { throw 'CabinetRoot must be a visible work folder.' }
$previous=Assert-WorkStoragePath ([string]$config.humanCabinet)
$previous=$previous.TrimEnd('\')
if ($ExpectedPreviousRoot) {
    if (-not [IO.Path]::IsPathRooted($ExpectedPreviousRoot)) { throw 'ExpectedPreviousRoot must be an absolute path.' }
    $expected=(Assert-WorkStoragePath $ExpectedPreviousRoot).TrimEnd('\')
    if ($expected -ine $previous) { throw 'The configured cabinet changed or does not match ExpectedPreviousRoot.' }
}
if ($BindLegacyJobs -and -not $ExpectedPreviousRoot) { throw 'BindLegacyJobs requires ExpectedPreviousRoot to identify the old binding explicitly.' }

foreach ($field in @('metadataFolderName','workMetadataName')) {
    $name=[string]$config.$field
    if ([string]::IsNullOrWhiteSpace($name) -or $name -in @('.','..') -or $name -match '[\\/:<>"|?*\x00-\x1f]' -or $name.TrimEnd(' ','.') -ne $name) { throw "Unsafe metadata component in configuration: $field" }
}
$changes=[Collections.Generic.List[object]]::new()
$utf8=[Text.UTF8Encoding]::new($false)
function Add-JsonChange([string]$Path,$Value) {
    $safe=Assert-WorkStoragePath $Path
    $before=[IO.File]::ReadAllBytes($safe)
    $after=$utf8.GetBytes(($Value | ConvertTo-Json -Depth 80)+[Environment]::NewLine)
    $changes.Add([pscustomobject]@{path=$safe;before=$before;after=$after})
}
function Assert-Guid([string]$Value) {
    $parsed=[guid]::Empty
    if (-not [guid]::TryParse($Value,[ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'A registered workId must be a nonempty GUID.' }
}
$workCount=0
$jobCount=0
if ($BindLegacyJobs) {
    $ids=@{}
    foreach ($folder in @(Get-ChildItem -LiteralPath $target -Directory -Force)) {
        if (-not (Test-WorkFolderName $folder.Name)) { continue }
        $workRoot=Assert-WorkStoragePath $folder.FullName
        $meta=Assert-WorkStoragePath (Join-Path (Join-Path $workRoot ([string]$config.metadataFolderName)) ([string]$config.workMetadataName))
        if (-not (Test-Path -LiteralPath $meta -PathType Leaf)) { continue }
        $data=Get-Content -LiteralPath $meta -Raw -Encoding utf8 | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$data.title)) { throw 'Registered work metadata requires a title before rebinding.' }
        if ($data.folderName -and [string]$data.folderName -ine $folder.Name) { throw 'Legacy binding requires an unchanged work folder name.' }
        $newId=[string]$data.workId
        if ($newId) { Assert-Guid $newId } else { $newId=[guid]::NewGuid().ToString('D') }
        if ($ids.ContainsKey($newId)) { throw 'Duplicate workId in the selected cabinet.' }
        $ids[$newId]=$true
        $jobsRoot=Assert-WorkStoragePath (Join-Path (Join-Path $workRoot ([string]$config.metadataFolderName)) 'jobs')
        if (Test-Path -LiteralPath $jobsRoot -PathType Container) {
            foreach ($job in @(Get-ChildItem -LiteralPath $jobsRoot -Directory -Force)) {
                if ($job.Name -notmatch '^\d{8}-[a-z0-9][a-z0-9-]{1,48}$') { throw 'Unexpected job directory; resolve it explicitly before binding legacy jobs.' }
                $inputsPath=Assert-WorkStoragePath (Join-Path $job.FullName 'inputs.json')
                if (-not (Test-Path -LiteralPath $inputsPath -PathType Leaf)) { throw 'A legacy job has no inputs.json; no binding was inferred.' }
                $inputs=Get-Content -LiteralPath $inputsPath -Raw -Encoding utf8 | ConvertFrom-Json
                if (-not $inputs.delivery) { throw 'A legacy job has no explicit delivery binding.' }
                if ($inputs.delivery.workId) {
                    Assert-Guid ([string]$inputs.delivery.workId)
                    if ([string]$inputs.delivery.workId -cne $newId) { throw 'A job workId belongs to a different work folder.' }
                } else {
                    $oldWork=Join-Path $previous $folder.Name
                    $bound=[string]$inputs.delivery.workRoot
                    if ([string]::IsNullOrWhiteSpace($bound) -or -not [IO.Path]::IsPathRooted($bound) -or [IO.Path]::GetFullPath($bound).TrimEnd('\') -ine $oldWork) { throw 'A legacy job is not bound to the expected previous work folder.' }
                    $inputs.delivery | Add-Member -NotePropertyName workId -NotePropertyValue $newId -Force
                    Add-JsonChange $inputsPath $inputs
                    $jobCount++
                }
            }
        }
        if (-not $data.workId) {
            $data | Add-Member -NotePropertyName workId -NotePropertyValue $newId -Force
            Add-JsonChange $meta $data
            $workCount++
        }
    }
}
if ($previous -ine $target) {
    $config.humanCabinet=$target
    Add-JsonChange $configPath $config
}
function Write-AtomicBytes([string]$Path,[byte[]]$Bytes) {
    $temp=Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.cabinet-binding-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [IO.File]::WriteAllBytes($temp,$Bytes)
        # Windows PowerShell 5.1 converts $null to an empty string for this .NET
        # string parameter; NullString preserves the intended absent backup.
        [IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value)
    } finally { if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force } }
}
function Same-Bytes([byte[]]$Left,[byte[]]$Right) { [Convert]::ToBase64String($Left) -ceq [Convert]::ToBase64String($Right) }
if ($Apply) {
    $done=[Collections.Generic.List[object]]::new()
    try {
        # Preflight every target before changing any file; detect stale plans and
        # reject write-protected metadata without partial migration.
        foreach ($change in $changes) {
            [void](Assert-WorkStoragePath $change.path)
            if ((Get-Item -LiteralPath $change.path -Force).Attributes -band [IO.FileAttributes]::ReadOnly) { throw 'Binding metadata is read-only.' }
            if (-not (Same-Bytes ([IO.File]::ReadAllBytes($change.path)) $change.before)) { throw 'Binding metadata changed during planning; retry.' }
        }
        foreach ($change in $changes) {
            if (-not (Same-Bytes ([IO.File]::ReadAllBytes($change.path)) $change.before)) { throw 'Binding metadata changed before writing; retry.' }
            Write-AtomicBytes $change.path $change.after
            $done.Add($change)
        }
    } catch {
        $original=$_
        for ($i=$done.Count-1;$i -ge 0;$i--) {
            if (-not (Same-Bytes ([IO.File]::ReadAllBytes($done[$i].path)) $done[$i].after)) { throw 'Concurrent metadata change prevents safe rollback; inspect the selected cabinet.' }
            Write-AtomicBytes $done[$i].path $done[$i].before
        }
        throw $original
    }
}
[ordered]@{
    ok=$true;applied=[bool]$Apply;previousRoot=$previous;cabinetRoot=$target
    changedFiles=$(if($Apply){$changes.Count}else{0});plannedFiles=$changes.Count
    workIdsAdded=$workCount;jobBindingsAdded=$jobCount
    documentsChanged=$false;consoleChanged=$false;externalConfigurationChanged=$false
} | ConvertTo-Json -Depth 4
