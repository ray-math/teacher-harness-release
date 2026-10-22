[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string[]]$SourceFile,
    [string]$Workspace = '',
    [string]$ConfigPath = '.agent/index/delivery-system.json'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1')

function Assert-ReceiveSupportedPath {
    param([string]$Path, [ValidateSet('File', 'Directory')][string]$Kind)
    # This transaction uses Windows PowerShell 5.1 providers and ordinary .NET
    # paths throughout, including rollback. Do not depend on machine-specific
    # long-path policy or accept extended paths that only some operations support.
    if ($Path.StartsWith('\\?\') -or $Path.StartsWith('\\.\')) {
        throw "Unsupported receive path: extended/device paths are not supported by the Windows PowerShell 5.1 receipt transaction: $Path"
    }
    $limit = 259
    if ($Kind -eq 'Directory') { $limit = 247 }
    if ($Path.Length -gt $limit) {
        throw "Unsupported receive path length: $Kind path has $($Path.Length) characters; Windows PowerShell 5.1 receipt transactions support at most $limit characters. No input files have been received: $Path"
    }
    foreach ($component in ($Path -split '[\\/]')) {
        if ($component.Length -gt 255) {
            throw "Unsupported receive path length: a path component has $($component.Length) characters; at most 255 are supported. No input files have been received: $Path"
        }
    }
}

function Assert-ReceiveSafePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -Force -LiteralPath $cursor
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse paths are not accepted: $cursor"
            }
            if ($cursor -ne $Path -and -not $item.PSIsContainer) {
                throw "A parent path is not a directory: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-ReceiveFileHash {
    param([string]$Path)
    # Opening a FileStream also verifies that the supplied file is readable.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Assert-ReceiveReceipt {
    param([string]$Path, [string]$Fingerprint, [object[]]$Files)
    Assert-ReceiveSafePath -Path $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Expected a receipt file: $Path" }
    $existingReceipt = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    if ($existingReceipt.schemaVersion -ne 'teacher-harness-input-receipt/v1' -or
        $existingReceipt.status -ne 'received' -or $existingReceipt.inputFingerprint -ne $Fingerprint -or
        @($existingReceipt.files).Count -ne $Files.Count) { throw "Existing input receipt is invalid: $Path" }
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $oldFile = @($existingReceipt.files)[$i]
        $newFile = $Files[$i]
        if (-not [string]::Equals($oldFile.sourcePath, $newFile.sourcePath, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($oldFile.receivedPath, $newFile.receivedPath, [StringComparison]::OrdinalIgnoreCase) -or
            $oldFile.sha256 -ne $newFile.sha256) { throw "Existing input receipt mapping differs: $Path" }
    }
}
function New-ReceiveDirectory {
    param([string]$Path, [System.Collections.Generic.List[string]]$CreatedDirectories)
    if (Test-Path -LiteralPath $Path) {
        if (-not (Get-Item -Force -LiteralPath $Path).PSIsContainer) { throw "Expected a directory: $Path" }
        return
    }
    $parent = [IO.Path]::GetDirectoryName($Path)
    if ($parent) { New-ReceiveDirectory -Path $parent -CreatedDirectories $CreatedDirectories }
    $null = [IO.Directory]::CreateDirectory($Path)
    $CreatedDirectories.Add($Path)
}

if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = Join-Path $PSScriptRoot '..\..' }
$workspaceRoot = [IO.Path]::GetFullPath($Workspace)
$config = Read-TeacherHarnessConfig -Workspace $workspaceRoot -ConfigPath $ConfigPath
$incomingRoot = [IO.Path]::GetFullPath([string]$config.incomingRoot)
if ($config.receiveInputs) {
    $receiptRoot = Join-Path $incomingRoot '.ai\input-receipts'
    Assert-ReceiveSupportedPath -Path $incomingRoot -Kind Directory
    Assert-ReceiveSupportedPath -Path $receiptRoot -Kind Directory
    # Receipt names are always 64 hexadecimal characters plus .json. Check their
    # complete future path before inspecting/copying inputs or creating directories.
    Assert-ReceiveSupportedPath -Path (Join-Path $receiptRoot (('0' * 64) + '.json')) -Kind File
    Assert-ReceiveSafePath -Path $incomingRoot
    Assert-ReceiveSafePath -Path $receiptRoot
    if ((Test-Path -LiteralPath $incomingRoot) -and -not (Get-Item -Force -LiteralPath $incomingRoot).PSIsContainer) {
        throw "incomingRoot must be a directory: $incomingRoot"
    }
}

# Validate and hash every input before making any directory, copy, or receipt.
$inputs = @()
foreach ($path in $SourceFile) {
    if ([string]::IsNullOrWhiteSpace($path)) { throw 'SourceFile must contain readable file paths.' }
    $fullPath = [IO.Path]::GetFullPath($path)
    Assert-ReceiveSupportedPath -Path $fullPath -Kind File
    Assert-ReceiveSafePath -Path $fullPath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Source file does not exist: $fullPath" }
    $item = Get-Item -Force -LiteralPath $fullPath
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::Device) -ne 0) {
        throw "Source must be a regular file: $fullPath"
    }
    $inputs += [pscustomobject]@{ sourcePath = $fullPath; sha256 = (Get-ReceiveFileHash -Path $fullPath) }
}

if (-not $config.receiveInputs) {
    # Reference-only mode never creates an incoming folder or receipt. The
    # receivedPath alias lets existing readers access the validated source.
    $files = @($inputs | ForEach-Object {
        [pscustomobject][ordered]@{
            sourcePath = $_.sourcePath
            receivedPath = $_.sourcePath
            sha256 = $_.sha256
            reused = $true
            status = 'referenced'
        }
    })
    $identity = @($files | ForEach-Object {
        [pscustomobject][ordered]@{ sourcePath = $_.sourcePath.ToLowerInvariant(); sha256 = $_.sha256 }
    }) | ConvertTo-Json -Depth 10 -Compress
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = ([BitConverter]::ToString($algorithm.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($identity)))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    [pscustomobject][ordered]@{
        status = 'referenced'
        receiptPath = ''
        receiptReused = $false
        inputFingerprint = $fingerprint
        files = $files
    } | ConvertTo-Json -Depth 10
    return
}
$planned = @{}
$files = @()
foreach ($inputFile in $inputs) {
    $sourcePath = $inputFile.sourcePath
    $sha256 = $inputFile.sha256
    $leaf = [IO.Path]::GetFileName($sourcePath)
    $stem = [IO.Path]::GetFileNameWithoutExtension($leaf)
    $extension = [IO.Path]::GetExtension($leaf)
    $attempt = 0
    while ($true) {
        if ($attempt -eq 0) { $candidateName = $leaf }
        elseif ($attempt -eq 1) { $candidateName = $stem + '__' + $sha256.Substring(0, 12) + $extension }
        elseif ($attempt -eq 2) { $candidateName = $stem + '__' + $sha256 + $extension }
        else { $candidateName = $stem + '__' + $sha256 + '__' + ($attempt - 2) + $extension }
        $destination = Join-Path $incomingRoot $candidateName
        # A collision suffix can exceed the limit even when the original name fits.
        Assert-ReceiveSupportedPath -Path $destination -Kind File
        Assert-ReceiveSafePath -Path $destination
        if ($planned.ContainsKey($destination)) {
            if ($planned[$destination] -eq $sha256) { $reused = $true; break }
        }
        elseif (Test-Path -LiteralPath $destination) {
            $existing = Get-Item -Force -LiteralPath $destination
            if (-not $existing.PSIsContainer -and (Get-ReceiveFileHash -Path $destination) -eq $sha256) {
                $reused = $true
                $planned[$destination] = $sha256
                break
            }
        }
        else {
            $reused = $false
            $planned[$destination] = $sha256
            break
        }
        $attempt++
    }
    $files += [pscustomobject][ordered]@{ sourcePath = $sourcePath; receivedPath = $destination; sha256 = $sha256; reused = $reused }
}

# Stable identity excludes transient reused flags and timestamps. Repeating the
# same source/copy/hash mapping reuses the original receipt without modifying it.
$identity = @($files | ForEach-Object {
    [pscustomobject][ordered]@{
        sourcePath = $_.sourcePath.ToLowerInvariant()
        receivedPath = $_.receivedPath.ToLowerInvariant()
        sha256 = $_.sha256
    }
}) | ConvertTo-Json -Depth 10 -Compress
$identityBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($identity)
$identityAlgorithm = [Security.Cryptography.SHA256]::Create()
try { $fingerprint = ([BitConverter]::ToString($identityAlgorithm.ComputeHash($identityBytes))).Replace('-', '').ToLowerInvariant() }
finally { $identityAlgorithm.Dispose() }
$receiptPath = Join-Path $receiptRoot ($fingerprint + '.json')
Assert-ReceiveSupportedPath -Path $receiptPath -Kind File
Assert-ReceiveSafePath -Path $receiptPath
if (Test-Path -LiteralPath $receiptPath) { Assert-ReceiveReceipt -Path $receiptPath -Fingerprint $fingerprint -Files $files }
$createdCopies = New-Object 'System.Collections.Generic.List[string]'
$createdDirectories = New-Object 'System.Collections.Generic.List[string]'
$receiptCreated = $false
try {
    Assert-ReceiveSafePath -Path $incomingRoot
    New-ReceiveDirectory -Path $incomingRoot -CreatedDirectories $createdDirectories
    foreach ($file in $files) {
        if ($file.reused) { continue }
        Assert-ReceiveSafePath -Path $file.sourcePath
        Assert-ReceiveSafePath -Path $file.receivedPath
        $inputStream = [IO.File]::Open($file.sourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $outputStream = $null
        try {
            # CreateNew is the final no-overwrite gate, including concurrent calls.
            $outputStream = [IO.File]::Open($file.receivedPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $createdCopies.Add($file.receivedPath)
            $inputStream.CopyTo($outputStream)
            $outputStream.Flush($true)
        }
        finally {
            if ($null -ne $outputStream) { $outputStream.Dispose() }
            $inputStream.Dispose()
        }
        if ((Get-ReceiveFileHash -Path $file.receivedPath) -ne $file.sha256) {
            throw "Source changed during receipt or copy verification failed: $($file.sourcePath)"
        }
    }
    # Reused copies are verified again before committing the receipt.
    foreach ($file in $files) {
        Assert-ReceiveSafePath -Path $file.receivedPath
        if ((Get-ReceiveFileHash -Path $file.receivedPath) -ne $file.sha256) { throw "Received file changed: $($file.receivedPath)" }
    }
    Assert-ReceiveSafePath -Path $receiptRoot
    New-ReceiveDirectory -Path $receiptRoot -CreatedDirectories $createdDirectories
    $receiptReused = Test-Path -LiteralPath $receiptPath
    if ($receiptReused) { Assert-ReceiveReceipt -Path $receiptPath -Fingerprint $fingerprint -Files $files }
    $result = [pscustomobject][ordered]@{
        status = 'received'
        receiptPath = $receiptPath
        receiptReused = $receiptReused
        inputFingerprint = $fingerprint
        files = @($files)
    }
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 'teacher-harness-input-receipt/v1'
        inputFingerprint = $fingerprint
        status = $result.status
        receivedAtUtc = [DateTime]::UtcNow.ToString('o')
        files = @($files)
    }
    if (-not $receiptReused) {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($receipt | ConvertTo-Json -Depth 10))
        $receiptStream = [IO.File]::Open($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $receiptCreated = $true
        try { $receiptStream.Write($bytes, 0, $bytes.Length); $receiptStream.Flush($true) }
        finally { $receiptStream.Dispose() }
    }
    $result | ConvertTo-Json -Depth 10
}
catch {
    $failure = $_
    if ($receiptCreated -and [IO.File]::Exists($receiptPath)) { [IO.File]::Delete($receiptPath) }
    for ($i = $createdCopies.Count - 1; $i -ge 0; $i--) {
        if ([IO.File]::Exists($createdCopies[$i])) { [IO.File]::Delete($createdCopies[$i]) }
    }
    for ($i = $createdDirectories.Count - 1; $i -ge 0; $i--) {
        if ([IO.Directory]::Exists($createdDirectories[$i]) -and [IO.Directory]::GetFileSystemEntries($createdDirectories[$i]).Length -eq 0) {
            [IO.Directory]::Delete($createdDirectories[$i], $false)
        }
    }
    throw $failure
}
