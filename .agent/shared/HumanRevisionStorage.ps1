# Immutable, content-addressed copies of prior human-facing current files.
# Callers retain the mapping before removing/replacing the current file.
function Save-HumanRevisionObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$WorkRoot,
        [Parameter(Mandatory=$true)][string]$MetadataRoot,
        [Parameter(Mandatory=$true)][string]$CurrentPath,
        [Parameter(Mandatory=$true)][string]$RevisionOf
    )
    $root = (Assert-WorkStoragePath $WorkRoot).TrimEnd('\')
    $metadata = Assert-WorkStoragePath $MetadataRoot
    $current = Assert-WorkStoragePath $CurrentPath
    $expectedCurrent = Get-WorkCurrentTarget -WorkRoot $root -RelativePath $RevisionOf
    if ($current -ine $expectedCurrent) { throw 'Revision source does not match its registered relative path.' }
    if (-not $metadata.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($metadata) -ine $root) { throw 'Revision metadata root must be a direct child of the selected work folder.' }
    $extension = [IO.Path]::GetExtension($current).ToLowerInvariant()
    if ($extension -notmatch '^\.[a-z0-9]{1,12}$') { throw 'Unsafe revision file extension.' }
    $revisionRoot = Assert-WorkStoragePath (Join-Path $metadata 'revisions')
    New-Item -ItemType Directory -Path $revisionRoot -Force | Out-Null
    [void](Assert-WorkStoragePath $revisionRoot)
    $pending = Join-Path $revisionRoot ('.pending-' + [guid]::NewGuid().ToString('N'))
    $inputStream = $null
    $outputStream = $null
    $createdObject = $false
    $objectPath = $null
    try {
        # Sharing only reads keeps writers out while hashing and making the copy.
        $inputStream = [IO.File]::Open($current,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($inputStream)).Replace('-','') } finally { $sha.Dispose() }
        $inputStream.Position = 0
        $objectPath = Assert-WorkStoragePath (Join-Path $revisionRoot ($hash.ToLowerInvariant() + $extension))
        if (Test-Path -LiteralPath $objectPath) {
            if (-not (Test-Path -LiteralPath $objectPath -PathType Leaf) -or (Get-PublishFileHash -LiteralPath $objectPath).Hash -cne $hash) { throw 'Existing revision object failed its SHA256 identity check.' }
        } else {
            $outputStream = [IO.File]::Open($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $inputStream.CopyTo($outputStream)
            $outputStream.Flush($true)
            $outputStream.Dispose(); $outputStream = $null
            if ((Get-PublishFileHash -LiteralPath $pending).Hash -cne $hash) { throw 'New revision copy failed its SHA256 identity check.' }
            # Never overwrite an object: concurrent arrival is reusable only if valid.
            try { [IO.File]::Move($pending,$objectPath); $createdObject = $true }
            catch {
                [void](Assert-WorkStoragePath $objectPath)
                if (-not (Test-Path -LiteralPath $objectPath -PathType Leaf) -or (Get-PublishFileHash -LiteralPath $objectPath).Hash -cne $hash) { throw }
            }
        }
        [ordered]@{
            current=$current; archive=$objectPath
            workRoot=$root; metadataRoot=$metadata
            relativePath=(Get-RelativePathCompat $root $objectPath)
            revisionOf=$RevisionOf; sha256=$hash
            storage='content-addressed'; createdObject=$createdObject; currentRemoved=$false
        }
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if (Test-Path -LiteralPath $pending -PathType Leaf) { Remove-Item -LiteralPath $pending -Force }
    }
}

function Restore-HumanRevisionObjects {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Mappings)
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($mapping in $Mappings) {
        try {
            $root = (Assert-WorkStoragePath ([string]$mapping.workRoot)).TrimEnd('\')
            $metadata = Assert-WorkStoragePath ([string]$mapping.metadataRoot)
            if ([IO.Path]::GetDirectoryName($metadata) -ine $root) { throw 'Recovery metadata root escaped its work folder.' }
            if ([string]$mapping.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid recovery SHA256 identity.' }
            $expectedCurrent = Get-WorkCurrentTarget -WorkRoot $root -RelativePath ([string]$mapping.revisionOf)
            if ([IO.Path]::GetFullPath([string]$mapping.current) -ine $expectedCurrent) { throw 'Recovery target escaped its registered relative path.' }
            $expectedArchive = Join-Path (Join-Path $metadata 'revisions') (([string]$mapping.sha256).ToLowerInvariant() + [IO.Path]::GetExtension($expectedCurrent).ToLowerInvariant())
            if ([IO.Path]::GetFullPath([string]$mapping.archive) -ine $expectedArchive) { throw 'Recovery object escaped its content-addressed location.' }
            [void](Assert-WorkStoragePath ([string]$mapping.archive))
            [void](Assert-WorkStoragePath ([string]$mapping.current))
            if ((Get-PublishFileHash -LiteralPath $mapping.archive).Hash -ine [string]$mapping.sha256) { throw 'Revision recovery object hash changed.' }
            if (-not $mapping.currentRemoved) { continue }
            Copy-Item -LiteralPath $mapping.archive -Destination $mapping.current -Force
            if ((Get-PublishFileHash -LiteralPath $mapping.current).Hash -ine [string]$mapping.sha256) { throw 'Restored current file hash mismatch.' }
        } catch { $failures.Add("$($mapping.revisionOf): $($_.Exception.Message)") }
    }
    # Keep all objects if any recovery failed; they are the remaining recovery source.
    if ($failures.Count -eq 0) {
        foreach ($path in @($Mappings | Where-Object createdObject | ForEach-Object archive | Select-Object -Unique)) {
            [void](Assert-WorkStoragePath $path)
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
        }
    }
    @($failures)
}
