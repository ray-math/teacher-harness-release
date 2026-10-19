# Explicit, portable shared context. Reading never creates or rewrites work records.
function Assert-WorkGroupId {
    param([string]$GroupId)
    if ($GroupId -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$') { throw 'GroupId must be a stable lowercase identifier.' }
    $GroupId
}

function Get-WorkGroupPath {
    param([string]$Cabinet,[string]$GroupId)
    $id = Assert-WorkGroupId $GroupId
    Assert-WorkStoragePath (Join-Path (Assert-WorkStoragePath $Cabinet) ('.ai\work-groups\'+$id+'.json'))
}

function Resolve-WorkGroupReferencePath {
    param([string]$Cabinet,[string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A selected reference path is required.' }
    if ([IO.Path]::IsPathRooted($Path)) { return (Assert-WorkStoragePath $Path) }
    $parts = @($Path -split '[\\/]')
    if (@($parts | Where-Object { $_ -in @('','.', '..') }).Count) { throw 'Relative reference paths must not contain parent traversal or empty segments.' }
    $root = (Assert-WorkStoragePath $Cabinet).TrimEnd('\')
    $full = Assert-WorkStoragePath (Join-Path $root $Path)
    if (-not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Reference path escaped its cabinet.' }
    $full
}

function ConvertTo-WorkGroupReferencePath {
    param([string]$Cabinet,[string]$Path)
    $root = (Assert-WorkStoragePath $Cabinet).TrimEnd('\')
    $full = Resolve-WorkGroupReferencePath -Cabinet $root -Path $Path
    if ($full -ieq $root) { throw 'Select specific reference materials rather than the whole cabinet.' }
    if (-not (Test-Path -LiteralPath $full) -or -not (Test-ReferenceVisiblePath $full)) { throw 'Select an existing visible reference file or folder.' }
    if ($full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($root.Length+1) }
    $full
}

function Assert-WorkGroupRecord {
    param($Record,[string]$GroupId)
    if ($Record.schemaVersion -ne 'hwpx-work-group/v1' -or $Record.groupId -cne $GroupId -or $Record.confirmedBy -ne 'user' -or [string]::IsNullOrWhiteSpace([string]$Record.title)) { throw 'Invalid confirmed work group record.' }
    $codes = @{}
    foreach ($category in @($Record.categories)) {
        if ([string]$category.code -notmatch '^\d{2}$' -or [string]::IsNullOrWhiteSpace([string]$category.title) -or $codes.ContainsKey([string]$category.code)) { throw 'Categories require unique two-digit codes and titles.' }
        $codes[[string]$category.code] = $true
    }
    $keys = @{}
    foreach ($decision in @($Record.decisions)) {
        if ([string]$decision.key -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$' -or [string]::IsNullOrWhiteSpace([string]$decision.text) -or $keys.ContainsKey([string]$decision.key)) { throw 'Confirmed decisions require unique stable keys and text.' }
        $keys[[string]$decision.key] = $true
        foreach ($code in @($decision.appliesTo | Where-Object { $null -ne $_ })) { if (-not $codes.ContainsKey([string]$code)) { throw 'Decision applicability refers to an unknown category.' } }
    }
    if ($null -ne $Record.referenceScope) {
        if ($Record.referenceScope.selectedBy -ne 'user') { throw 'Group references must be selected by the user.' }
        if ([bool]$Record.referenceScope.noReferences -and @($Record.referenceScope.roots).Count) { throw 'NoReferences cannot be combined with selected roots.' }
        foreach ($source in @($Record.referenceScope.roots)) {
            if ($source.role -notin @('manual','current-source','prior-source') -or [string]::IsNullOrWhiteSpace([string]$source.path)) { throw 'Invalid group source role or path.' }
        }
    }
}

function Get-WorkGroupRecord {
    param([Parameter(Mandatory=$true)][string]$WorkFolder)
    $work = Assert-WorkStoragePath $WorkFolder
    $metadataPath = Assert-WorkStoragePath (Join-Path $work '.ai\work.json')
    $metadata = if (Test-Path -LiteralPath $metadataPath -PathType Leaf) { Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json } else { $null }
    $result = [ordered]@{status='none';reason=$null;groupId=$null;categoryCode=$null;path=$null;sha256=$null;record=$null;metadata=$metadata;cabinet=[IO.Path]::GetDirectoryName($work)}
    if (-not $metadata.groupId) { return [pscustomobject]$result }
    $result.groupId = Assert-WorkGroupId ([string]$metadata.groupId)
    $result.categoryCode = [string]$metadata.groupCategoryCode
    $result.path = Get-WorkGroupPath -Cabinet $result.cabinet -GroupId $result.groupId
    if (-not (Test-Path -LiteralPath $result.path -PathType Leaf)) { $result.status='needs_input';$result.reason='linked_work_group_missing';return [pscustomobject]$result }
    $record = Get-Content -LiteralPath $result.path -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-WorkGroupRecord -Record $record -GroupId $result.groupId
    if ($result.categoryCode -and -not @($record.categories | Where-Object { [string]$_.code -eq $result.categoryCode }).Count) { throw 'The linked category no longer exists in this work group.' }
    $result.record=$record;$result.sha256=(Get-FileHash -LiteralPath $result.path -Algorithm SHA256).Hash;$result.status='ready'
    [pscustomobject]$result
}

function Get-EffectiveWorkDecisions {
    param($Group)
    $resolved = [ordered]@{}
    if ($Group.status -eq 'ready') {
        foreach ($decision in @($Group.record.decisions)) {
            $appliesTo=@($decision.appliesTo | Where-Object { $null -ne $_ })
            if ($appliesTo.Count -and $appliesTo -notcontains [string]$Group.categoryCode) { continue }
            $resolved[[string]$decision.key] = [pscustomobject]@{key=[string]$decision.key;text=[string]$decision.text;origin='group';groupId=$Group.groupId;appliesTo=@($decision.appliesTo)}
        }
    }
    foreach ($decision in @($Group.metadata.decisionOverrides | Where-Object { $null -ne $_ })) {
        if ($decision.confirmedBy -ne 'user' -or [string]$decision.key -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$') { throw 'Invalid confirmed work decision override.' }
        if ([bool]$decision.disabled) { $resolved.Remove([string]$decision.key);continue }
        if ([string]::IsNullOrWhiteSpace([string]$decision.text)) { throw 'An active work decision override needs text.' }
        $resolved[[string]$decision.key] = [pscustomobject]@{key=[string]$decision.key;text=[string]$decision.text;origin='work';groupId=$Group.groupId;appliesTo=@()}
    }
    @($resolved.Values)
}

function Write-WorkContextJson {
    param([string]$Path,$Value)
    $target = Assert-WorkStoragePath $Path
    $parent = [IO.Path]::GetDirectoryName($target)
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent ('.context-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $target -PathType Leaf) { [IO.File]::Replace($temp,$target,[NullString]::Value) } else { [IO.File]::Move($temp,$target) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
