# Shared job-location policy. Read-only: callers decide when to create files.
function Test-WorkFolderName {
    param([AllowNull()][string]$Name)
    # Names do not require a classification number. Keep path and device guards.
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.StartsWith('.') -or $Name -match '[\x00-\x1f\\/<>:"|?*]' -or $Name.Trim(' ','.') -ne $Name -or $Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') { return $false }
    $title = $Name -replace '^(?:\d{8}|\d{2}(?:-\d{2})*)_', ''
    return -not [string]::IsNullOrWhiteSpace($title)
}

function Assert-WorkStoragePath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ($Path.Substring([Math]::Min(2,$Path.Length)).Contains(':')) { throw 'Alternate data streams are not allowed in storage paths.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Substring([IO.Path]::GetPathRoot($full).Length).Contains(':')) { throw 'Alternate data streams are not allowed in storage paths.' }
    $walk = [IO.Path]::GetPathRoot($full)
    foreach ($part in @($full.Substring($walk.Length) -split '[\\/]')) {
        if (-not $part) { continue }
        $walk = Join-Path $walk $part
        if ((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Storage path uses a reparse point: $walk" }
    }
    $full
}

function Get-WorkJobInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Workspace,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$DeliveryConfigPath = '',
        [switch]$RequireJobRoot,
        [switch]$RequireExists
    )
    $full = Assert-WorkStoragePath $Path
    if ($RequireExists -and -not (Test-Path -LiteralPath $full)) { throw "Job path does not exist: $full" }
    $configPath = if ($DeliveryConfigPath) { $DeliveryConfigPath } else { Join-Path $Workspace '.agent/index/delivery-system.json' }
    $config = Get-Content -Raw -Encoding utf8 -LiteralPath $configPath | ConvertFrom-Json
    $pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
    if (Test-Path -LiteralPath $pathResolver) {
        . $pathResolver
        $config = Resolve-TeacherHarnessConfig -Workspace $Workspace -Config $config
    } elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
    $cabinet = Get-WorkContainerRoot $config
    $legacyCabinet = [IO.Path]::GetFullPath([string]$config.humanCabinet).TrimEnd('\')
    if ($config.outputLayout -eq 'flat' -and -not $full.StartsWith($cabinet + '\', [StringComparison]::OrdinalIgnoreCase)) { $cabinet = $legacyCabinet }
    if (-not $full.StartsWith($cabinet + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Job path is outside the selected work storage: $full" }
    $parts = @($full.Substring($cabinet.Length + 1) -split '[\\/]')
    $metadataName = if ($config.metadataFolderName) { [string]$config.metadataFolderName } else { '.ai' }
    if ($parts.Count -lt 4 -or -not (Test-WorkFolderName $parts[0]) -or $parts[1] -ine $metadataName -or $parts[2] -ne 'jobs') { throw "Job path must be inside the selected work .ai/jobs tree: $full" }
    $workRoot = Join-Path $cabinet $parts[0]
    $jobName = $parts[3]
    $jobRoot = Join-Path (Join-Path (Join-Path $workRoot $parts[1]) $parts[2]) $jobName
    $kind = 'work'
    if ($jobName -notmatch '^\d{8}-[a-z0-9][a-z0-9-]{1,48}$') { throw "Invalid job folder name: $jobName" }
    if ($RequireJobRoot -and $full.TrimEnd('\') -ine $jobRoot) { throw "Expected the job root: $full" }
    $inputsPath = Join-Path $jobRoot 'inputs.json'
    if ($kind -eq 'work' -and (Test-Path -LiteralPath $inputsPath -PathType Leaf)) {
        $inputs = Get-Content -Raw -Encoding utf8 -LiteralPath $inputsPath | ConvertFrom-Json
        if ($inputs.delivery.workId) {
            $metadataFile = if ($config.workMetadataName) { [string]$config.workMetadataName } else { 'work.json' }
            $metadataPath = Assert-WorkStoragePath (Join-Path (Join-Path $workRoot $metadataName) $metadataFile)
            if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw 'Job work identity cannot be verified: work metadata is missing.' }
            $metadata = Get-Content -Raw -Encoding utf8 -LiteralPath $metadataPath | ConvertFrom-Json
            if (-not $metadata.workId -or [string]$inputs.delivery.workId -cne [string]$metadata.workId) { throw 'Job is bound to a different human work identity.' }
        } elseif ($inputs.delivery.workRoot -and [IO.Path]::GetFullPath([string]$inputs.delivery.workRoot) -ine $workRoot) { throw 'Job is bound to a different human work folder.' }
    }
    [pscustomobject]@{ jobRoot=$jobRoot; workRoot=$workRoot; storageKind=$kind }
}

function Get-WorkCurrentTarget {
    param([Parameter(Mandatory=$true)][string]$WorkRoot,[Parameter(Mandatory=$true)][string]$RelativePath,[string[]]$ReservedNames=@('.ai','previous_versions'))
    $WorkRoot = Get-WorkCurrentRoot $WorkRoot
    if ($RelativePath -match '[\x00-\x1f]') { throw "Unsafe current-file relative path: control character" }
    $parts = @($RelativePath -split '[\\/]')
    if ([IO.Path]::IsPathRooted($RelativePath) -or @($parts | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' -or $_.StartsWith('.') -or $_ -match '[\x00-\x1f<>:"|?*]' -or $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $_.TrimEnd(' ','.') -ne $_ }).Count -gt 0 -or $parts[0] -in $ReservedNames) { throw "Unsafe current-file relative path: $RelativePath" }
    $target = Assert-WorkStoragePath (Join-Path $WorkRoot ($parts -join '\'))
    $walk = $WorkRoot
    if ((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System))) { throw "Work root is hidden or system: $walk" }
    foreach ($part in $parts) {
        $walk = Join-Path $walk $part
        if ((Test-Path -LiteralPath $walk) -and ((Get-Item -LiteralPath $walk -Force).Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System))) { throw "Current-file path is hidden or system: $walk" }
    }
    if (-not $target.StartsWith([IO.Path]::GetFullPath($WorkRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Current-file target escaped its work folder.' }
    $target
}
function Get-WorkContainerRoot {
    param($Config)
    $root = [IO.Path]::GetFullPath([string]$Config.humanCabinet).TrimEnd('\')
    if ($Config.outputLayout -eq 'flat') { return Join-Path $root '.ai\works' }
    $root
}

function Get-WorkCurrentRoot {
    param([string]$WorkRoot)
    # Internal work identities remain separate while their current files share Output.
    $root = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
    $parent = [IO.Path]::GetDirectoryName($root)
    if ([IO.Path]::GetFileName($parent) -eq 'works' -and [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($parent)) -eq '.ai') {
        return [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($parent))
    }
    $root
}

function Resolve-WorkDeliveryName {
    param([string]$WorkRoot,[string]$RelativePath)
    $output = Get-WorkCurrentRoot $WorkRoot
    if ($output -ieq [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')) { return $RelativePath }
    if ([IO.Path]::GetFileName($RelativePath) -cne $RelativePath -or -not (Test-WorkFolderName $RelativePath)) { throw "Flat output requires a safe filename without subfolders: $RelativePath" }
    $metadata = Assert-WorkStoragePath (Join-Path $output '.ai')
    New-Item -ItemType Directory -Path $metadata -Force | Out-Null
    [IO.File]::SetAttributes($metadata,([IO.File]::GetAttributes($metadata) -bor [IO.FileAttributes]::Hidden))
    $lock = [IO.File]::Open((Assert-WorkStoragePath (Join-Path $metadata 'output-names.lock')),'OpenOrCreate','ReadWrite','None')
    try {
        $mapPath = Assert-WorkStoragePath (Join-Path $metadata 'output-names.json')
        $records = @()
        if (Test-Path -LiteralPath $mapPath) { $records = @((Get-Content -Raw -Encoding utf8 -LiteralPath $mapPath | ConvertFrom-Json) | ForEach-Object { $_ }) }
        $owned = @($records | Where-Object { $_.workRoot -ieq $WorkRoot -and ($_.requested -ieq $RelativePath -or $_.name -ieq $RelativePath) })
        if ($owned.Count -gt 1) { throw 'Duplicate flat output ownership records.' }
        if ($owned.Count -eq 1) { return [string]$owned[0].name }
        $title = $RelativePath -replace '^\d+_', ''
        if (-not (Test-WorkFolderName $title)) { throw 'Flat output title is empty or unsafe.' }
        $used = @($records | ForEach-Object name) + @(Get-ChildItem -LiteralPath $output -Force | ForEach-Object Name)
        $index = 0
        while (@($used | Where-Object { $_ -match ('^' + ('{0:D2}' -f $index) + '_') }).Count -gt 0) { $index++ }
        $name = ('{0:D2}_{1}' -f $index,$title)
        $records += [pscustomobject]@{workRoot=$WorkRoot;requested=$RelativePath;name=$name}
        $temp = Join-Path $metadata ('names-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try { ConvertTo-Json -InputObject @($records) -Depth 5 | Set-Content -LiteralPath $temp -Encoding utf8; Move-Item -LiteralPath $temp -Destination $mapPath -Force }
        finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        $name
    } finally { $lock.Dispose() }
}
