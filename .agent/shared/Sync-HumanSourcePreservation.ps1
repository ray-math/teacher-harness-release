[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkFolder,
    [object[]]$Source = @(),
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$watch = [Diagnostics.Stopwatch]::StartNew()
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Get-Content -Raw -Encoding utf8 (Join-Path $workspace '.agent/index/delivery-system.json') | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$root = [IO.Path]::GetFullPath($WorkFolder).TrimEnd('\')
if ([IO.Path]::GetDirectoryName($root) -ine (Get-WorkContainerRoot $config) -and [IO.Path]::GetDirectoryName($root) -ine [IO.Path]::GetFullPath([string]$config.humanCabinet).TrimEnd('\')) { throw 'Preservation requires a direct child of the human cabinet.' }
$history = Join-Path $root $config.archiveFolderName
$metadata = Join-Path $root $config.metadataFolderName
$originals = Join-Path $metadata 'originals'
$ledgerPath = Join-Path $metadata 'source-preservations.json'

function Assert-RegularPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not allowed: $cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}
function Write-Ledger {
    $temp = Join-Path $metadata ('preservation-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [ordered]@{schemaVersion='hwpx-source-preservations/v1';updatedAt=(Get-Date -Format o);records=@($records)} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $ledgerPath -Force
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
Assert-RegularPath $root
Assert-RegularPath $history
Assert-RegularPath $ledgerPath
if (-not $VerifyOnly) { New-Item -ItemType Directory -Path $metadata -Force | Out-Null }
# Serialize intake with a process-held lock; a killed process releases it automatically.
$lock = $null
if (-not $VerifyOnly) { $lock = [IO.File]::Open((Join-Path $metadata 'source-preservations.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
try {
    $records = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $ledgerPath) {
        foreach ($record in @((Get-Content -Raw -Encoding utf8 -LiteralPath $ledgerPath | ConvertFrom-Json).records)) { if ($record) { $records.Add($record) } }
    }
    $results = [Collections.Generic.List[object]]::new()
    $snapshot = $null
    foreach ($item in @($Source | Where-Object { $_.userProvided -eq $true })) {
        $origin = [IO.Path]::GetFullPath([string]$item.path)
        $hash = [string]$item.sha256
        if ($hash -notmatch '^[A-Fa-f0-9]{64}$') { throw "A selected source needs an intake SHA256: $origin" }
        $matches = @($records | Where-Object { $_.path -ieq $origin -and $_.sha256 -ieq $hash })
        if ($matches.Count -gt 1) { throw "Ambiguous preservation records: $origin" }
        $record = if ($matches.Count) { $matches[0] } else { $null }
        if (-not $VerifyOnly) {
            Assert-RegularPath $origin
            if ((Get-FileHash -LiteralPath $origin -Algorithm SHA256).Hash -ine $hash) { throw "Source changed since intake: $origin" }
        }
        # Adopt a matching, previously recorded manual preservation without copying again.
        if (-not $record -and -not $VerifyOnly -and $item.copyRelativePath) {
            $legacyTarget = [IO.Path]::GetFullPath((Join-Path $root $item.copyRelativePath))
            if ($legacyTarget.StartsWith($history.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase) -or $legacyTarget.StartsWith($originals.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) {
                Assert-RegularPath $legacyTarget
                if (-not (Test-Path -LiteralPath $legacyTarget -PathType Leaf) -or (Get-FileHash -LiteralPath $legacyTarget).Hash -ine $hash) { throw 'Previously preserved original is missing or changed.' }
                $record = [pscustomobject][ordered]@{path=$origin;sha256=$hash;roles=@([string]$item.role);copyRelativePath=$item.copyRelativePath;selectedAt=$item.selectedAt;preservedAt=(Get-Date -Format o);state='preserved'}
                $records.Add($record)
                Write-Ledger
            }
        }
        if (-not $record) {
            if ($VerifyOnly) { throw "User-provided original has not been preserved. Run Start-HwpxWork.ps1 with UserProvidedFile: $origin" }
            if (-not $snapshot) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $snapshot = Join-Path $originals ($stamp + '_접수원본')
                # A second independent intake in the same second uses the next free second.
                while (Test-Path -LiteralPath $snapshot) { $stamp = ([datetime]::ParseExact($stamp,'yyyyMMdd-HHmmss',$null)).AddSeconds(1).ToString('yyyyMMdd-HHmmss'); $snapshot = Join-Path $originals ($stamp + '_접수원본') }
                New-Item -ItemType Directory -Path $snapshot -Force | Out-Null
            }
            $target = Join-Path $snapshot ([IO.Path]::GetFileName($origin))
            if (@($records | Where-Object { (Join-Path $root $_.copyRelativePath) -ieq $target }).Count -or (Test-Path -LiteralPath $target)) {
                $folderHash = [Security.Cryptography.SHA256]::Create()
                try { $key = [BitConverter]::ToString($folderHash.ComputeHash([Text.Encoding]::UTF8.GetBytes($origin.ToLowerInvariant()))).Replace('-','').Substring(0,12) } finally { $folderHash.Dispose() }
                $target = Join-Path (Join-Path $snapshot ('동명-' + $key)) ([IO.Path]::GetFileName($origin))
            }
            $record = [pscustomobject][ordered]@{path=$origin;sha256=$hash;roles=@([string]$item.role);copyRelativePath=$target.Substring($root.Length+1);selectedAt=$item.selectedAt;preservedAt=$null;state='pending'}
            $records.Add($record)
            # Persist the planned destination before copying, so retries recover this exact file.
            Write-Ledger
        }
        $target = [IO.Path]::GetFullPath((Join-Path $root $record.copyRelativePath))
        if (-not ($target.StartsWith($history.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($originals.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase))) { throw 'Preserved path escaped the approved originals storage.' }
        Assert-RegularPath $target
        if ($VerifyOnly) {
            if ($record.state -ne 'preserved' -or -not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $hash) { throw "Preserved original is missing or changed: $target" }
        } else {
            Assert-RegularPath $origin
            if ((Get-FileHash -LiteralPath $origin -Algorithm SHA256).Hash -ine $hash) { throw "Source changed since intake: $origin" }
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
            if (-not (Test-Path -LiteralPath $target)) {
                $temp = $target + '.' + [guid]::NewGuid().ToString('N') + '.partial'
                try {
                    [IO.File]::Copy($origin,$temp,$false)
                    if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ine $hash -or (Get-FileHash -LiteralPath $origin -Algorithm SHA256).Hash -ine $hash) { throw "Source/copy hash mismatch: $origin" }
                    [IO.File]::Move($temp,$target)
                } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
            }
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $hash -or (Get-FileHash -LiteralPath $origin -Algorithm SHA256).Hash -ine $hash) { throw "Source/copy hash mismatch: $origin" }
            $record.roles = @(@($record.roles) + @([string]$item.role) | Select-Object -Unique)
            if (-not $record.preservedAt) { $record.preservedAt = Get-Date -Format o }
            $record.state = 'preserved'
            Write-Ledger
        }
        $results.Add([ordered]@{path=$origin;role=$item.role;sha256=$hash;copyRelativePath=$record.copyRelativePath;preservedAt=$record.preservedAt;verified=$true})
    }
    [ordered]@{ok=$true;verifyOnly=[bool]$VerifyOnly;records=@($results);seconds=[Math]::Round($watch.Elapsed.TotalSeconds,3)} | ConvertTo-Json -Depth 8
} finally { if ($lock) { $lock.Dispose() } }
