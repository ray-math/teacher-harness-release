# File-free publication. Invoked by Publish-HumanResult.ps1 -ConsoleContentPath.
# Input: {schemaVersion:'hwpx-console-content/v1',sections:[{id,title,body,
#          references?:[{path,sha256,locator}]}]}. Sections replace consoleContent only.
# Inputs and publication receipts live in the selected work's job tree.
# Run isolated tests from a copied workspace, never by overriding a live config.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ConsoleContentPath,
    [string]$TaskTitle = '',
    [string]$WorkFolderName = '',
    [string]$DeliveryConfigPath = '',
    [string]$RegistryPath = '',
    [switch]$PlanOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Assert-PlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Substring([IO.Path]::GetPathRoot($full).Length).Contains(':')) { throw 'Alternate data streams are not allowed.' }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse-point paths are not allowed: $cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}
function Is-Within([string]$Path, [string]$Root) {
    $Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Assert-LeafName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in @('.','..') -or $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw 'Expected a direct child filename.' }
}
function Assert-Fields($Value, [string[]]$Required, [string[]]$Optional = @()) {
    if ($Value -isnot [Management.Automation.PSCustomObject]) { throw 'Console content objects must be JSON objects.' }
    $names = @($Value.PSObject.Properties.Name)
    foreach ($name in $Required) { if ($names -cnotcontains $name) { throw "Missing console content field: $name" } }
    foreach ($name in $names) { if (($Required + $Optional) -cnotcontains $name) { throw "Unknown console content field: $name" } }
}
function Assert-Text($Value, [string]$Name, [switch]$AllowEmpty) {
    if ($Value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value))) { throw "Console content $Name must be a string$(if(-not $AllowEmpty){' with content'})." }
}
function Bytes-Hash([byte[]]$Bytes) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hasher.ComputeHash($Bytes)).Replace('-','') } finally { $hasher.Dispose() }
}
function Write-Bytes([string]$Path, [byte[]]$Bytes) {
    $temp = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.console-publish-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        # Match the renderer's browser-compatible overwrite (mapped HTML may reject File.Replace).
        if ([IO.File]::Exists($Path)) { [IO.File]::Copy($temp, $Path, $true) } else { [IO.File]::Move($temp, $Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Write-Json([string]$Path, $Value) {
    Write-Bytes $Path ([Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 100)))
}

if (($DeliveryConfigPath -or $RegistryPath) -and -not $PlanOnly) { throw 'DeliveryConfigPath and RegistryPath overrides are allowed only with PlanOnly for isolated verification.' }
$configPath = if ($DeliveryConfigPath) { Assert-PlainPath $DeliveryConfigPath } else { Join-Path $workspace '.agent\index\delivery-system.json' }
$registryFile = if ($RegistryPath) { Assert-PlainPath $RegistryPath } else { $null }
$config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$cabinet = Assert-PlainPath ([string]$config.humanCabinet)
. (Join-Path $PSScriptRoot 'WorkRegistry.ps1')
$registry = if ($RegistryPath) { Get-Content -LiteralPath $registryFile -Raw -Encoding utf8 | ConvertFrom-Json } else { Get-WorkRegistry -Workspace $workspace -DeliveryConfigPath $configPath }
if (-not $TaskTitle -and -not $WorkFolderName) { throw 'TaskTitle or WorkFolderName is required to identify registered work.' }
$entries = @(if ($WorkFolderName) { $registry.works | Where-Object folderName -eq $WorkFolderName } else { $registry.works | Where-Object title -eq $TaskTitle })
if ($entries.Count -ne 1) { throw 'Exactly one registered work must match; use WorkFolderName to disambiguate.' }
$entry = $entries[0]
$WorkFolderName = [string]$entry.folderName
Assert-LeafName $WorkFolderName
if (-not (Test-WorkFolderName $WorkFolderName)) { throw 'Invalid work-folder name.' }
$workRoot = Assert-PlainPath (Join-Path $cabinet $WorkFolderName)
if ([IO.Path]::GetDirectoryName($workRoot).TrimEnd('\') -ine $cabinet.TrimEnd('\')) { throw 'Work must be a direct child of the configured cabinet.' }
foreach ($name in @($config.metadataFolderName,$config.workMetadataName,$config.sourceMetadataName,$config.consoleFileName)) { Assert-LeafName ([string]$name) }
$metadataRoot = Assert-PlainPath (Join-Path $workRoot ([string]$config.metadataFolderName))
$metadataPath = Assert-PlainPath (Join-Path $metadataRoot ([string]$config.workMetadataName))
$sourcesPath = Assert-PlainPath (Join-Path $metadataRoot ([string]$config.sourceMetadataName))
$consolePath = Assert-PlainPath (Join-Path $workRoot ([string]$config.consoleFileName))
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw 'Hidden work metadata is missing.' }

$sourcePath = Assert-PlainPath $ConsoleContentPath
$sourceJob = Get-WorkJobInfo -Workspace $workspace -Path $sourcePath -DeliveryConfigPath $configPath -RequireExists
if ($sourceJob.workRoot -ine $workRoot) { throw 'Console content belongs to a different human work folder.' }
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or [IO.Path]::GetExtension($sourcePath) -ine '.json') { throw 'ConsoleContentPath must be a JSON file.' }
$sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
$content = [Text.Encoding]::UTF8.GetString($sourceBytes).TrimStart([char]0xfeff) | ConvertFrom-Json
Assert-Fields $content @('schemaVersion','sections')
if ($content.schemaVersion -cne 'hwpx-console-content/v1') { throw 'Unsupported console content schemaVersion.' }
if ($content.sections -isnot [array]) { throw 'Console content sections must be an array.' }
$ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($section in $content.sections) {
    Assert-Fields $section @('id','title','body') @('references','tables','presentation')
    Assert-Text $section.id 'id'
    Assert-Text $section.title 'title'
    Assert-Text $section.body 'body' -AllowEmpty
    if ($section.PSObject.Properties.Name -contains 'presentation') { if ($section.presentation -cne 'message') { throw 'Unsupported section presentation.' } }
    if ($section.PSObject.Properties.Name -contains 'tables') {
        if ($section.tables -isnot [array]) { throw 'Section tables must be an array.' }
        foreach ($table in $section.tables) {
            Assert-Fields $table @('caption','columns','rows')
            Assert-Text $table.caption 'table caption'
            if ($table.columns -isnot [array] -or $table.columns.Count -lt 1) { throw 'Table columns must be a nonempty array.' }
            foreach ($column in $table.columns) { Assert-Text $column 'table column' }
            if ($table.rows -isnot [array]) { throw 'Table rows must be an array.' }
            foreach ($row in $table.rows) {
                if ($row -isnot [array] -or $row.Count -ne $table.columns.Count) { throw 'Table row width must match columns.' }
                foreach ($cell in $row) { Assert-Text $cell 'table cell' -AllowEmpty }
            }
        }
    }
    if (-not $ids.Add($section.id)) { throw 'Duplicate console content section id.' }
    if ($section.PSObject.Properties.Name -contains 'references') {
        if ($section.references -isnot [array]) { throw 'Section references must be an array.' }
        foreach ($reference in $section.references) {
            Assert-Fields $reference @('path','sha256','locator')
            foreach ($name in @('path','sha256','locator')) { Assert-Text $reference.$name $name }
            if ($reference.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or -not [IO.Path]::IsPathRooted($reference.path)) { throw 'Reference requires an absolute path and SHA256.' }
            [void](Assert-PlainPath $reference.path)
        }
    }
}
$receiptRoot = if ($sourceJob) {
    if ($sourcePath -ieq $sourceJob.jobRoot) { throw 'Console content source must be inside a job directory.' }
    Join-Path $sourceJob.jobRoot 'wip\receipts'
} else { Join-Path ([IO.Path]::GetDirectoryName($sourcePath)) 'receipts' }
$receiptRoot = Assert-PlainPath $receiptRoot
$attemptId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
$attemptRoot = Join-Path $receiptRoot ('console-publish-' + $attemptId)
$receiptPath = Join-Path $attemptRoot 'receipt.json'
$latestPath = Assert-PlainPath (Join-Path $receiptRoot 'work-console-publish.json')
if ($sourcePath -ieq $latestPath) { throw 'Console content input cannot be a publication receipt.' }

# The renderer uses this same reentrant mutex for the shared open-target manifest.
# Hold it from snapshot through receipt/rollback so another work's manifest entry
# cannot be lost when a failed regeneration is restored. Do not modify the registry.
$mutex = [Threading.Mutex]::new($false, 'Local\HwpxHumanOpenTargets')
$locked = $false
$snapshots = [Collections.Generic.List[object]]::new()
$mutating = $false
$receipt = $null
try {
    try { $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(15)) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Timed out waiting for console publication lock.' }
    $metadataBytes = [IO.File]::ReadAllBytes($metadataPath)
    $metadata = [Text.Encoding]::UTF8.GetString($metadataBytes).TrimStart([char]0xfeff) | ConvertFrom-Json
    if ($metadata -isnot [Management.Automation.PSCustomObject]) { throw 'Invalid work metadata.' }
    $names = @($entry.files | Where-Object { $_ })
    foreach ($name in $names) { [void](Get-WorkCurrentTarget -WorkRoot $workRoot -RelativePath $name) }
    $actual = @(Get-ChildItem -LiteralPath $workRoot -File -Force | Where-Object Name -ine $config.consoleFileName | ForEach-Object Name)
    # Reporting cannot confer file authority or repair registration. Surface differences
    # in the receipt without blocking the explicitly requested communication update.
    $registrationDifferences=[ordered]@{
        missingCount=@($names | Where-Object { $_ -notin $actual }).Count
        unregisteredCount=@($actual | Where-Object { $_ -notin $names }).Count
        metadataMismatch=(@($metadata.currentFiles).Count -ne $names.Count -or @($metadata.currentFiles | Where-Object { $_ -notin $names }).Count -gt 0)
    }
    $ledger = if (Test-Path -LiteralPath $sourcesPath -PathType Leaf) { Get-Content -LiteralPath $sourcesPath -Raw -Encoding utf8 | ConvertFrom-Json } else { $null }
    $referenceChecks = [Collections.Generic.List[object]]::new()
    foreach ($section in $content.sections) {
        foreach ($reference in @($section.references)) {
            if ($null -eq $reference) { continue }
            $registered = @($ledger.sources | Where-Object { $_.path -ieq $reference.path -and $_.sha256 -ieq $reference.sha256 })
            if (-not $registered.Count) { throw 'Console reference is not a registered source with the supplied hash.' }
            # Verify the selected revision, preferring the immutable intake copy.
            $verificationPath = $reference.path
            $preserved = @($registered | Where-Object { $_.copyRelativePath } | Select-Object -First 1)
            if ($preserved.Count) {
                $verificationPath = Assert-PlainPath (Join-Path $workRoot ([string]$preserved[0].copyRelativePath))
                if (-not (Is-Within $verificationPath $workRoot)) { throw 'Registered source copy escaped the work folder.' }
            }
            if (-not (Test-Path -LiteralPath $verificationPath -PathType Leaf) -or (Get-FileHash -LiteralPath $verificationPath -Algorithm SHA256).Hash -ine $reference.sha256) { throw 'Registered console reference is missing or changed since intake.' }
            $referenceChecks.Add([ordered]@{sectionId=$section.id;path=$reference.path;sha256=$reference.sha256;locator=$reference.locator;verifiedPath=$verificationPath})
        }
    }
    $receipt = [ordered]@{
        schemaVersion='hwpx-human-console-content.publish/v1'; mode='ConsoleContent'; ok=$false
        workFolder=$workRoot; source=[ordered]@{path=$sourcePath;sha256=(Bytes-Hash $sourceBytes)}
        sectionIds=@($content.sections | ForEach-Object id); references=@($referenceChecks)
        preservedFields=@('currentFiles','currentFileRecords','stage','status','review','workflow','history','nextAction')
        stage=$metadata.stage; documentFilesChanged=$false; registryChanged=$false; registrationDifferences=$registrationDifferences
        verification='schema_registered_work_source_hashes_and_console_regeneration'
        receiptPath=$receiptPath; latestReceiptPath=$latestPath
    }
    if ($PlanOnly) { $receipt['planOnly']=$true; $receipt | ConvertTo-Json -Depth 12; return }
    if (-not $PSCmdlet.ShouldProcess($workRoot, 'Publish console sections without changing document or administrative state')) { return }

    # Match the generator's installed-runtime delegation. Back up the manifest
    # actually used by the registered Windows helper, not a stale workspace copy.
    $activeRuntime = $cabinet
    if (-not (Test-Path -LiteralPath (Join-Path $cabinet '.agent\shared\Update-HumanWorkConsole.ps1') -PathType Leaf)) { throw 'Optional cabinet console runtime is not installed. Install it explicitly before publishing a console.' }
    $manifestPath = Assert-PlainPath (Join-Path $activeRuntime ([string]$config.openTargetManifest))
    if (-not (Is-Within $manifestPath (Join-Path $activeRuntime '.agent\index'))) { throw 'Open target manifest must remain inside the runtime index.' }
    $entryFolder = Assert-PlainPath (Join-Path $workRoot '문서 열기')
    $shortcutPath = Assert-PlainPath (Join-Path $entryFolder '문서 열기.lnk')
    $entryFolderExisted = Test-Path -LiteralPath $entryFolder -PathType Container
    [void][IO.Directory]::CreateDirectory($attemptRoot)
    foreach ($path in @($metadataPath,$consolePath,$manifestPath,$shortcutPath,$latestPath)) {
        if (Test-Path -LiteralPath $path -PathType Container) { throw 'A publication output is a directory.' }
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $backup = Join-Path $attemptRoot ('before-' + $snapshots.Count + '.bin')
        if ($exists) { [IO.File]::WriteAllBytes($backup, [IO.File]::ReadAllBytes($path)) }
        $snapshots.Add([ordered]@{path=$path;existed=[bool]$exists;backup=$backup})
    }
    $receipt['recovery'] = @($snapshots)
    $receipt['status'] = 'prepared'
    Write-Json $receiptPath $receipt
    $mutating = $true
    # Keep JSON arrays (including empty/singleton arrays) and all unrelated fields.
    $metadata | Add-Member -MemberType NoteProperty -Name consoleContent -Value $content -Force
    Write-Json $metadataPath $metadata
    $consoleJson = & (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -WorkFolder $workRoot
    $consoleReceipt = ($consoleJson -join [Environment]::NewLine) | ConvertFrom-Json
    if ($null -eq $consoleReceipt -or ($consoleReceipt.PSObject.Properties.Name -contains 'ok' -and $consoleReceipt.ok -ne $true) -or
        [string]$consoleReceipt.workFolder -ine $workRoot -or [string]$consoleReceipt.output -ine $consolePath -or
        -not (Test-Path -LiteralPath $consolePath -PathType Leaf)) { throw 'Console regeneration returned no matching successful receipt.' }
    $receipt['console'] = $consoleReceipt
    $receipt['metadataSha256'] = (Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash
    $receipt['consoleSha256'] = (Get-FileHash -LiteralPath $consolePath -Algorithm SHA256).Hash
    $receipt['publishedAt'] = Get-Date -Format 'o'
    $receipt['status'] = 'published'; $receipt.ok = $true
    Write-Json $latestPath $receipt
    Write-Json $receiptPath $receipt
    $mutating = $false
    $receipt | ConvertTo-Json -Depth 12
} catch {
    $failure = $_
    if ($mutating) {
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        foreach ($snapshot in $snapshots) {
            try {
                if ($snapshot.existed) { Write-Bytes $snapshot.path ([IO.File]::ReadAllBytes($snapshot.backup)) }
                elseif (Test-Path -LiteralPath $snapshot.path -PathType Leaf) { [IO.File]::Delete($snapshot.path) }
            } catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        if (-not $entryFolderExisted -and (Test-Path -LiteralPath $entryFolder -PathType Container)) {
            try { if (@(Get-ChildItem -LiteralPath $entryFolder -Force).Count -eq 0) { [IO.Directory]::Delete($entryFolder) } } catch { $rollbackErrors.Add($_.Exception.Message) }
        }
        $receipt.ok=$false; $receipt['status']='failed'; $receipt['error']=$failure.Exception.Message
        $receipt['rollback']=[ordered]@{ok=($rollbackErrors.Count -eq 0);errors=@($rollbackErrors)}
        try { Write-Json $receiptPath $receipt } catch { $rollbackErrors.Add('Failure receipt could not be saved: ' + $_.Exception.Message) }
        if ($rollbackErrors.Count) { throw "Console publication failed; rollback requires recovery using $attemptRoot. $($rollbackErrors -join '; ')" }
        throw "Console publication failed and was rolled back. Receipt: $receiptPath. $($failure.Exception.Message)"
    }
    throw
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
