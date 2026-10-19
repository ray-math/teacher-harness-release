# Per-work, user-selected source scope. No default material library or year inference.
function Get-WorkReferenceScopePath {
    param([Parameter(Mandatory=$true)][string]$WorkFolder)
    $work = Assert-WorkStoragePath $WorkFolder
    Join-Path $work '.ai\reference-scope.json'
}

function Test-ReferenceVisiblePath {
    param([Parameter(Mandatory=$true)][string]$Path,[switch]$AllowRevision)
    $full = Assert-WorkStoragePath $Path
    $walk = [IO.Path]::GetPathRoot($full)
    foreach ($part in @($full.Substring($walk.Length) -split '[\\/]')) {
        if (-not $part) { continue }
        if ($part.StartsWith('.') -or $part -ieq 'previous_versions') { return $false }
    }
    # Explicit roots may be below a hidden OS parent (for example AppData/Temp).
    # The selected item itself and every traversed child must remain visible.
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if ($item.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint)) { return $false }
    }
    if (-not $AllowRevision -and [IO.Path]::GetFileNameWithoutExtension($full) -match '_fix\d+_\d{8}(?:-\d{6})?(?:_\d+)?$') { return $false }
    $true
}

function Get-ReferenceFiles {
    param([Parameter(Mandatory=$true)][string]$Path,[switch]$DirectOnly)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-ReferenceVisiblePath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { $item; return }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($item.FullName)
    while ($pending.Count) {
        $directory = $pending.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            if ($child.Name.StartsWith('.') -or $child.Name -ieq 'previous_versions' -or ($child.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint))) { continue }
            if ($child.PSIsContainer) { if (-not $DirectOnly) { $pending.Push($child.FullName) }; continue }
            if ($child.BaseName -match '_fix\d+_\d{8}(?:-\d{6})?(?:_\d+)?$') { continue }
            $child
        }
    }
}

function Get-WorkReferenceScope {
    param([string]$WorkFolder='')
    $result = [ordered]@{status='needs_input';reason='reference_scope_not_selected';scopePath=$null;scopeSha256=$null;source='work';groupId=$null;noReferences=$false;roots=@();missingPaths=@()}
    if (-not $WorkFolder) { return [pscustomobject]$result }
    $path = Get-WorkReferenceScopePath $WorkFolder
    $result.scopePath = $path
    $groupScope=$false
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Assert-WorkStoragePath $path | Out-Null
        $scope = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
        $result.scopeSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($scope.schemaVersion -notin @('hwpx-reference-scope/v1','hwpx-reference-scope/v2') -or $scope.selectedBy -ne 'user') { throw 'Invalid user-selected reference scope.' }
    } else {
        $metadataPath=Assert-WorkStoragePath (Join-Path $WorkFolder '.ai\work.json')
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return [pscustomobject]$result }
        $metadata=Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json
        if (-not $metadata.groupId) { return [pscustomobject]$result }
        . (Join-Path $PSScriptRoot 'WorkGroup.ps1')
        $group=Get-WorkGroupRecord -WorkFolder $WorkFolder
        $result.source='group';$result.groupId=$group.groupId;$result.scopePath=$group.path;$result.scopeSha256=$group.sha256
        if ($group.status -ne 'ready') { $result.reason=$group.reason;return [pscustomobject]$result }
        if ($null -eq $group.record.referenceScope) { return [pscustomobject]$result }
        $scope=$group.record.referenceScope;$groupScope=$true
        # A method-only group update does not invalidate unchanged source discovery.
        $scopeIdentity=[ordered]@{selectedBy=$scope.selectedBy;noReferences=[bool]$scope.noReferences;roots=@($scope.roots)} | ConvertTo-Json -Depth 8 -Compress
        $hasher=[Security.Cryptography.SHA256]::Create()
        try { $result.scopeSha256=[BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($scopeIdentity))).Replace('-','') } finally { $hasher.Dispose() }
    }
    $roots = [Collections.Generic.List[object]]::new()
    $missing = [Collections.Generic.List[string]]::new()
    foreach ($root in @($scope.roots)) {
        if ($root.role -notin @('manual','current-source','prior-source') -or [string]::IsNullOrWhiteSpace([string]$root.path)) { throw 'Invalid reference-scope source role or path.' }
        $raw = [string]$root.path
        if ($groupScope) { $full=Resolve-WorkGroupReferencePath -Cabinet ([IO.Path]::GetDirectoryName($WorkFolder)) -Path $raw }
        else {
            $pathBase=if ($scope.schemaVersion -eq 'hwpx-reference-scope/v1') {if([IO.Path]::IsPathRooted($raw)){'external'}else{'work'}} else {[string]$root.pathBase}
            if ($pathBase -notin @('work','cabinet','external')) { throw 'Invalid reference-scope path base.' }
            if ($pathBase -eq 'external') {
                if (-not [IO.Path]::IsPathRooted($raw)) { throw 'External reference paths must be absolute.' }
                $full=Assert-WorkStoragePath $raw
            } else {
                if ([IO.Path]::IsPathRooted($raw) -or @($raw -split '[\\/]' | Where-Object {$_ -in @('','.', '..')}).Count) { throw 'Relative reference paths must not contain parent traversal.' }
                $base=if($pathBase -eq 'cabinet'){[IO.Path]::GetDirectoryName($WorkFolder)}else{$WorkFolder}
                $full=Assert-WorkStoragePath (Join-Path $base $raw)
                if (-not $full.StartsWith(([IO.Path]::GetFullPath($base).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Relative reference path escaped its base folder.' }
            }
        }
        if (-not (Test-Path -LiteralPath $full)) { $missing.Add($full); continue }
        if (-not (Test-ReferenceVisiblePath $full)) { throw 'Reference scope includes a hidden, internal or revision path.' }
        $roots.Add([pscustomobject]@{role=[string]$root.role;path=$full})
    }
    $result.roots = @($roots)
    $result.missingPaths = @($missing)
    $result.noReferences = [bool]$scope.noReferences
    if ($result.noReferences -and @($scope.roots).Count) { throw 'NoReferences cannot be combined with selected roots.' }
    if ($missing.Count) { $result.reason='selected_reference_path_missing' }
    elseif ($roots.Count -or $result.noReferences) { $result.status='ready';$result.reason=$null }
    [pscustomobject]$result
}
