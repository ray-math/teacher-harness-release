[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$GroupId,
    [string]$DefinitionPath='',
    [string[]]$WorkFolder=@(),
    [string]$CategoryCode='',
    [switch]$ConfirmedByUser
)
$ErrorActionPreference='Stop'
if (-not $ConfirmedByUser) { throw 'Only user-confirmed shared context may be saved. Existing explicit agreement is sufficient.' }
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
. (Join-Path $PSScriptRoot 'WorkReferenceScope.ps1')
. (Join-Path $PSScriptRoot 'WorkGroup.ps1')
$config=Get-Content -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$cabinet=(Assert-WorkStoragePath ([string]$config.humanCabinet)).TrimEnd('\')
if (-not (Test-Path -LiteralPath $cabinet -PathType Container)) { throw 'The selected cabinet must already exist.' }
$groupPath=Get-WorkGroupPath -Cabinet $cabinet -GroupId $GroupId
if (-not $DefinitionPath -and -not @($WorkFolder).Count) { throw 'Provide an explicit group update or work folders to link.' }
$mutex=[Threading.Mutex]::new($false,'Local\HwpxWorkGroupRecords')
$locked=$false
try {
    $locked=$mutex.WaitOne([TimeSpan]::FromSeconds(15))
    if (-not $locked) { throw 'Timed out while saving confirmed context.' }
    $exists=Test-Path -LiteralPath $groupPath -PathType Leaf
    if ($exists) { $record=Get-Content -LiteralPath $groupPath -Raw -Encoding utf8 | ConvertFrom-Json;Assert-WorkGroupRecord $record $GroupId }
    else { $record=[pscustomobject]@{schemaVersion='hwpx-work-group/v1';groupId=$GroupId;confirmedBy='user';title='';categories=@();decisions=@();referenceScope=$null} }
    if ($DefinitionPath) {
        $definition=Get-Content -LiteralPath (Assert-WorkStoragePath $DefinitionPath) -Raw -Encoding utf8 | ConvertFrom-Json
        $allowed=@('title','year','workflowPath','categories','referenceScope','decisions')
        foreach ($property in $definition.PSObject.Properties) {
            if ($property.Name -notin $allowed) { throw 'Unsupported shared-context field. Only confirmed common methods and selected source paths belong here.' }
            $record | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
        if ($record.workflowPath) {
            $workflow=Resolve-WorkGroupReferencePath -Cabinet $cabinet -Path ([string]$record.workflowPath)
            if (-not (Test-Path -LiteralPath $workflow -PathType Leaf)) { throw 'WorkflowPath must identify the user-supplied workflow file.' }
            $record.workflowPath=ConvertTo-WorkGroupReferencePath -Cabinet $cabinet -Path $workflow
        }
        if ($null -ne $definition.PSObject.Properties['referenceScope'] -and $null -ne $record.referenceScope) {
            $sources=@(foreach ($source in @($record.referenceScope.roots | Where-Object {$null -ne $_})) {
                [pscustomobject]@{role=[string]$source.role;path=(ConvertTo-WorkGroupReferencePath -Cabinet $cabinet -Path ([string]$source.path))}
            })
            $record.referenceScope=[pscustomobject]@{selectedBy='user';selectedAt=(Get-Date -Format o);noReferences=[bool]$record.referenceScope.noReferences;roots=$sources}
        }
        $record.categories=@(foreach ($category in @($record.categories | Where-Object {$null -ne $_})) { [pscustomobject]@{code=[string]$category.code;title=[string]$category.title} })
        $record.decisions=@(foreach ($decision in @($record.decisions | Where-Object {$null -ne $_})) { [pscustomobject]@{key=[string]$decision.key;text=[string]$decision.text;appliesTo=@($decision.appliesTo | Where-Object {$null -ne $_})} })
        $record | Add-Member -NotePropertyName confirmedAt -NotePropertyValue (Get-Date -Format o) -Force
    } elseif (-not $exists) { throw 'A new group needs an explicit definition; no group or year is inferred.' }
    Assert-WorkGroupRecord -Record $record -GroupId $GroupId
    if ($DefinitionPath -and $exists) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $cabinet -Directory -Force | Where-Object {Test-WorkFolderName -Name $_.Name})) {
            $linkedPath=Assert-WorkStoragePath (Join-Path $directory.FullName '.ai\work.json')
            if (-not (Test-Path -LiteralPath $linkedPath -PathType Leaf)) {continue}
            $linked=Get-Content -LiteralPath $linkedPath -Raw -Encoding utf8 | ConvertFrom-Json
            if ($linked.groupId -eq $GroupId -and $linked.groupCategoryCode -and -not @($record.categories | Where-Object { [string]$_.code -eq [string]$linked.groupCategoryCode }).Count) { throw 'A category linked to existing work cannot be removed from its group.' }
        }
    }
    if ($CategoryCode -and -not @($record.categories | Where-Object { [string]$_.code -eq $CategoryCode }).Count) { throw 'Select an existing group category code.' }
    $writes=[Collections.Generic.List[object]]::new()
    if ($DefinitionPath) { $writes.Add([pscustomobject]@{path=$groupPath;value=$record}) }
    $seen=@{}
    foreach ($raw in @($WorkFolder)) {
        $work=Assert-WorkStoragePath $raw
        if ([IO.Path]::GetDirectoryName($work) -ine $cabinet -or -not (Test-WorkFolderName -Name ([IO.Path]::GetFileName($work))) -or -not (Test-Path -LiteralPath $work -PathType Container)) { throw 'WorkFolder must be an existing direct human work folder.' }
        if ($seen.ContainsKey($work)) { continue };$seen[$work]=$true
        $path=Assert-WorkStoragePath (Join-Path $work '.ai\work.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Register the work before explicitly linking it to a group.' }
        $metadata=Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
        if ($metadata.groupId -and $metadata.groupId -ne $GroupId) { throw 'The work is linked to another group. Relinking requires a separately reviewed migration.' }
        $metadata | Add-Member -NotePropertyName groupId -NotePropertyValue $GroupId -Force
        if ($PSBoundParameters.ContainsKey('CategoryCode')) { $metadata | Add-Member -NotePropertyName groupCategoryCode -NotePropertyValue $CategoryCode -Force }
        if ($metadata.groupCategoryCode -and -not @($record.categories | Where-Object { [string]$_.code -eq [string]$metadata.groupCategoryCode }).Count) { throw 'The work category is absent from the confirmed group.' }
        $writes.Add([pscustomobject]@{path=$path;value=$metadata})
    }
    # Validate all targets before the first write. Restore original bytes if a later write fails.
    $before=@(foreach ($item in $writes) { [pscustomobject]@{path=$item.path;existed=(Test-Path -LiteralPath $item.path -PathType Leaf);bytes=$(if(Test-Path -LiteralPath $item.path -PathType Leaf){[IO.File]::ReadAllBytes($item.path)}else{$null})} })
    $applied=0
    try {
        foreach ($item in $writes) { Write-WorkContextJson -Path $item.path -Value $item.value;$applied++ }
        if ($DefinitionPath) { $hidden=Assert-WorkStoragePath (Join-Path $cabinet '.ai');[IO.File]::SetAttributes($hidden,([IO.File]::GetAttributes($hidden) -bor [IO.FileAttributes]::Hidden)) }
    } catch {
        $failure=$_;$rollback=[Collections.Generic.List[string]]::new()
        for ($i=$applied-1;$i -ge 0;$i--) { try { if($before[$i].existed){[IO.File]::WriteAllBytes($before[$i].path,$before[$i].bytes)}else{Remove-Item -LiteralPath $before[$i].path -Force} }catch{$rollback.Add($_.Exception.Message)} }
        if ($rollback.Count) { throw ('Save failed; rollback incomplete: '+($rollback -join '; ')) };throw $failure
    }
    @{ok=$true;groupPath=$groupPath;updated=[bool]$DefinitionPath;linkedWorks=$seen.Count;documentsRewritten=0} | ConvertTo-Json
} finally { if($locked){$mutex.ReleaseMutex()};$mutex.Dispose() }
