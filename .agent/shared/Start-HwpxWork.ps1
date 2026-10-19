[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('New', 'FollowUp')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TaskTitle,

    [string]$JobPath = '',
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,48}$')]
    [string]$JobSlug = '',
    [string]$Goal = '',
    [ValidateSet('Document','Workflow')][string]$Purpose = 'Document',
    # Stable for retries; a new human request uses a new RequestId or RequestText.
    [string]$RequestText = '',
    [string]$RequestId = '',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$IntakeSummary,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DecisionReason,

    [string]$WorkFolderName = '',
    [ValidatePattern('^\d{8}$')]
    [string]$CreatedDate = (Get-Date -Format 'yyyyMMdd'),
    [string[]]$AuthorityFile = @(),
    [string[]]$FormFile = @(),
    [string[]]$HumanRevisionFile = @(),
    [string[]]$CurrentReferenceFile = @(),
    [string[]]$ManualFile = @(),
    [string[]]$ReferenceFile = @(),
    [string[]]$UserProvidedFile = @(),
    [string[]]$CopyEvidenceFile = @(),
    [string[]]$CopyReferenceFile = @(),
    [string[]]$SupportFolderName = @(),
    [string]$LayoutReferenceFolder = '',
    [string]$LayoutReason = '',
    [switch]$Collection,
    [switch]$SelectedFilesOnly,
    [switch]$FinalPolishAuthorized,
    [switch]$VisualReviewAuthorized,
    [string]$FormattingRequestText = '',
    [string]$VisualReviewRequestText = '',
    [switch]$RevokeDocumentScope,
    [switch]$UpdateConsole,
    [switch]$PlanOnly,
    [switch]$Summary
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DocumentScope.ps1')
. (Join-Path $PSScriptRoot 'DocumentBasis.ps1')
if ($FinalPolishAuthorized) { Assert-ExplicitDocumentRequest $FormattingRequestText 'format_edit' }
if ($VisualReviewAuthorized) { Assert-ExplicitDocumentRequest $VisualReviewRequestText 'visual_review' }
if ($RevokeDocumentScope -and ($FinalPolishAuthorized -or $VisualReviewAuthorized -or $FormattingRequestText -or $VisualReviewRequestText)) { throw 'Scope revocation cannot be combined with scope expansion.' }
if ($FormattingRequestText -and -not $FinalPolishAuthorized) { throw 'FormattingRequestText requires FinalPolishAuthorized.' }
if ($VisualReviewRequestText -and -not $VisualReviewAuthorized) { throw 'VisualReviewRequestText requires VisualReviewAuthorized.' }
$intakeWatch = [Diagnostics.Stopwatch]::StartNew()
function Write-IntakeResponse($Receipt) {
    if (-not $Summary) { $Receipt | ConvertTo-Json -Depth 8; return }
    [ordered]@{
        schemaVersion='hwpx-work-intake.summary/v1'; status='ready'; reused=[bool]$Receipt.reused
        mode=$Receipt.mode; workFolderName=$Receipt.workFolderName; workRoot=$Receipt.workRoot
        jobPath=$Receipt.jobPath; workingDocuments=$Receipt.workingDocuments
        sourcesRegistered=$Receipt.sourcesRegistered; editingMode=$Receipt.editingMode
        finalPolishAuthorized=[bool]$Receipt.finalPolishAuthorized
        deliveryCycleId=$Receipt.deliveryCycle.id
        receiptPath=(Join-Path $Receipt.jobPath 'wip/receipts/work-intake.json')
        elapsedSeconds=[Math]::Round($intakeWatch.Elapsed.TotalSeconds,3)
    } | ConvertTo-Json -Depth 4 -Compress
}




function ConvertTo-HashtableDeep {
    # ConvertFrom-Json -AsHashtable is PowerShell 7 only; this host runs Windows PowerShell 5.1.
    # Ordered maps keep the JSON key order these metadata files are written back with.
    [CmdletBinding()]
    param([Parameter(Position = 0, ValueFromPipeline = $true)]$Value)
    process {
        if ($null -eq $Value) { return $null }
        if ($Value -is [Management.Automation.PSCustomObject]) {
            $map = [ordered]@{}
            foreach ($property in $Value.PSObject.Properties) { $map[$property.Name] = ConvertTo-HashtableDeep $property.Value }
            return $map
        }
        if ($Value -is [Collections.IDictionary]) {
            $map = [ordered]@{}
            foreach ($key in @($Value.Keys)) { $map[$key] = ConvertTo-HashtableDeep $Value[$key] }
            return $map
        }
        if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
            return ,@(foreach ($item in $Value) { ConvertTo-HashtableDeep $item })
        }
        $Value
    }
}
function Get-RelativePathCompat([string]$Root, [string]$Path) {
    # [IO.Path]::GetRelativePath is .NET Core only; this host runs Windows PowerShell 5.1.
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ($pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { return $pathFull.Substring($rootFull.Length + 1) }
    if ($pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return '.' }
    [Uri]::UnescapeDataString(([Uri]($rootFull + '\')).MakeRelativeUri([Uri]$pathFull).ToString()).Replace('/', '\')
}
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
. (Join-Path $PSScriptRoot 'WorkRegistry.ps1')
$createdJob = $false
$pendingJobCreation = $false

foreach ($value in @($IntakeSummary, $DecisionReason, $LayoutReason)) {
    if ($value -match '\b\d{6}-?\d{7}\b|\b01[016789][ -]?\d{3,4}[ -]?\d{4}\b|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}') {
        throw 'Human-work metadata must exclude or mask personal identifiers, phone numbers, and email addresses.'
    }
}

$configPath = Join-Path $workspace '.agent\index\delivery-system.json'
$config = Get-Content -Raw -Encoding utf8 -LiteralPath $configPath | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$registry = Get-WorkRegistry -Workspace $workspace
$cabinet = [IO.Path]::GetFullPath([string]$config.humanCabinet)
$cabinetPrefix = $cabinet.TrimEnd('\') + '\'

function Get-SafeName([string]$Value) {
    $result = $Value.Trim()
    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) { $result = $result.Replace([string]$char, ' ') }
    ($result -replace '\s+', ' ').Trim(' ', '.')
}

function Resolve-SourceList([string[]]$Paths, [string]$Role) {
    foreach ($item in @($Paths | Where-Object { $_ })) {
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $item).Path)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Source is not a file: $resolved" }
        [ordered]@{
            path = $resolved
            role = $Role
            sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
            name = [IO.Path]::GetFileName($resolved)
        }
    }
}

function Write-JsonAtomic([string]$Path, [object]$Value, [int]$Depth = 12) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = Join-Path $parent ('.json-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $temp -Encoding utf8
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

$safeTitle = Get-SafeName $TaskTitle
if ([string]::IsNullOrWhiteSpace($safeTitle)) { throw 'TaskTitle did not contain a usable name.' }
if (-not $WorkFolderName -and (Test-WorkFolderName $safeTitle)) {
    $WorkFolderName = $safeTitle
    $safeTitle = $safeTitle -replace '^(?:\d{8}|\d{2}(?:-\d{2})*)_', ''
}
$entry = $null
if ($Mode -eq 'New' -and [string]::IsNullOrWhiteSpace($WorkFolderName)) {
    $existingMatches = @($registry.works | Where-Object title -eq $safeTitle)
    if ($existingMatches.Count -gt 1) { throw 'More than one registered work matches. Pass WorkFolderName explicitly.' }
    if ($existingMatches.Count -eq 1) { $Mode = 'FollowUp'; $WorkFolderName = [string]$existingMatches[0].folderName }
    else { throw 'New work needs an explicit numbered WorkFolderName from the selected workflow (for example 23_Second exam). No date or classification number is assigned automatically.' }
}
if ($Mode -eq 'FollowUp') {
    $matches = if ($WorkFolderName) { @($registry.works | Where-Object folderName -eq $WorkFolderName) } else { @($registry.works | Where-Object title -eq $safeTitle) }
    if ($matches.Count -eq 0) { throw 'No registered work matches this follow-up. Use Mode New or pass the correct WorkFolderName.' }
    if ($matches.Count -gt 1) { throw 'More than one registered work matches. Pass WorkFolderName explicitly.' }
    $entry = $matches[0]
    $WorkFolderName = [string]$entry.folderName
    $CreatedDate = [string]$entry.createdDate
}

if (-not (Test-WorkFolderName $WorkFolderName)) { throw "Invalid work-folder name: $WorkFolderName" }
$workRoot = [IO.Path]::GetFullPath((Join-Path $cabinet $WorkFolderName))
if (-not $workRoot.StartsWith($cabinetPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Work target escaped the human cabinet: $workRoot" }
$existingNewFolder = $Mode -eq 'New' -and (Test-Path -LiteralPath $workRoot)
$existingWorkMetadataPath = Join-Path (Join-Path $workRoot ([string]$config.metadataFolderName)) ([string]$config.workMetadataName)
$registeredRevisionNames = @()
if (Test-Path -LiteralPath $existingWorkMetadataPath -PathType Leaf) { $existingWork = Get-Content -Raw -Encoding utf8 -LiteralPath $existingWorkMetadataPath | ConvertFrom-Json; $registeredRevisionNames = @($existingWork.revisionHistory | ForEach-Object relativePath) }
if ($Mode -eq 'FollowUp' -and -not (Test-Path -LiteralPath $workRoot -PathType Container)) { throw "Follow-up work folder is missing: $workRoot" }
if ($Mode -eq 'FollowUp') {
    $registeredNames = @($entry.files | Where-Object { $_ } | Select-Object -Unique)
    $actualNames = @(
        Get-ChildItem -LiteralPath $workRoot -File -Force |
            Where-Object { $_.Name -ne [string]$config.consoleFileName } |
            ForEach-Object Name
    )
    $unexpected = @($actualNames | Where-Object { $registeredNames -notcontains $_ -and $registeredRevisionNames -notcontains $_ })
    $missing = @($registeredNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $workRoot $_) -PathType Leaf) })
    if ($unexpected.Count -gt 0) { throw "Unregistered human-facing file(s) must be reconciled before follow-up: $($unexpected -join ', ')" }
    if ($missing.Count -gt 0) { throw "Registered current file(s) are missing before follow-up: $($missing -join ', ')" }
}

$metadataRoot = Join-Path $workRoot ([string]$config.metadataFolderName)
function Hide-WorkMetadata {
    if(Test-Path -LiteralPath $metadataRoot -PathType Container){
        $attributes=[IO.File]::GetAttributes($metadataRoot)
        if($attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Metadata folder must not be a reparse point.'}
        [IO.File]::SetAttributes($metadataRoot,($attributes -bor [IO.FileAttributes]::Hidden))
    }
}
$workMetadataPath = Join-Path $metadataRoot ([string]$config.workMetadataName)
$sourceMetadataPath = Join-Path $metadataRoot ([string]$config.sourceMetadataName)
$jobDate = Get-Date -Format 'yyyyMMdd'
if ([string]::IsNullOrWhiteSpace($JobPath)) {
    if ($PlanOnly) { throw 'PlanOnly requires an existing JobPath.' }
    if ([string]::IsNullOrWhiteSpace($JobSlug)) { throw 'Pass JobPath or JobSlug.' }
    $JobPath = Join-Path (Join-Path $metadataRoot 'jobs') ("$jobDate-$JobSlug")
    $pendingJobCreation = -not (Test-Path -LiteralPath $JobPath)
}
$jobInfo = Get-WorkJobInfo -Workspace $workspace -Path $JobPath -RequireJobRoot
$resolvedJob = $jobInfo.jobRoot
if ($jobInfo.storageKind -eq 'work' -and $jobInfo.workRoot -ine $workRoot) { throw 'JobPath belongs to another human work folder.' }
if (-not $pendingJobCreation -and -not (Test-Path -LiteralPath $resolvedJob -PathType Container)) { throw 'An explicit JobPath must already exist; use JobSlug to create a school job.' }
$existingInputsPath = Join-Path $resolvedJob 'inputs.json'
if (Test-Path -LiteralPath $existingInputsPath -PathType Leaf) {
    $existingInputs = Get-Content -Raw -Encoding utf8 -LiteralPath $existingInputsPath | ConvertFrom-Json
    # Get-WorkJobInfo has already checked a stable identity when present.
    if (-not $existingInputs.delivery.workId -and $existingInputs.delivery.workRoot -and [IO.Path]::GetFullPath([string]$existingInputs.delivery.workRoot) -ine $workRoot) { throw 'Existing job intake is bound to another human work folder.' }
}
$consolePath = Join-Path $workRoot ([string]$config.consoleFileName)
$now = Get-Date -Format 'o'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$allItems = @(
    @(Resolve-SourceList $AuthorityFile 'authority')
    @(Resolve-SourceList $FormFile 'form')
    @(Resolve-SourceList $HumanRevisionFile 'human_revision')
    @(Resolve-SourceList $CurrentReferenceFile 'current_reference')
    @(Resolve-SourceList $ManualFile 'manual')
    @(Resolve-SourceList $ReferenceFile 'prior_example')
)
$autoHumanRevisions = [Collections.Generic.List[object]]::new()
if ($SelectedFilesOnly -and ($Mode -ne 'FollowUp' -or $HumanRevisionFile.Count -eq 0)) { throw 'SelectedFilesOnly requires FollowUp and explicit HumanRevisionFile targets.' }
if ($Mode -eq 'FollowUp') {
    foreach ($name in @($entry.files | Where-Object { $_ } | Select-Object -Unique)) {
        $currentPath = Join-Path $workRoot ([string]$name)
        if ($SelectedFilesOnly -and @($allItems | Where-Object { $_.role -eq 'human_revision' -and $_.path -ieq $currentPath }).Count -eq 0) { continue }
        if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { continue }
        try { $currentHash = (Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash }
        catch { throw "Close the current human file before follow-up so its exact saved revision can be protected: $currentPath" }
        $item = [ordered]@{
            path = [IO.Path]::GetFullPath($currentPath)
            role = 'human_revision'
            sha256 = $currentHash
            name = [IO.Path]::GetFileName($currentPath)
            detected = 'current-human-deliverable'
        }
        $autoHumanRevisions.Add($item)
        $allItems += $item
    }
}
$deduped = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($item in $allItems) { if ($seen.Add(([string]$item.path + '|' + $item.role + '|' + $item.sha256))) { $deduped.Add($item) } }
$allItems = @($deduped)
$provided = @($UserProvidedFile | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $_).Path) })
foreach ($path in $provided) { if (@($allItems | Where-Object { $_.path -ieq $path }).Count -eq 0) { throw "UserProvidedFile must also have a source role (FormFile, ReferenceFile, etc.): $path" } }
foreach ($item in $allItems) {
    $item['userProvided'] = ($provided -contains $item.path -or $item.role -in @('form','human_revision'))
    $item['selectedAt'] = $now
}
# Receiving supplied files is independent of authoring: keep their copies even
# when the authoring gate below must ask for an existing draft/form.
$incomingReceipt = $null
if (-not $PlanOnly -and $provided.Count -gt 0) {
    $incomingJson = & (Join-Path $PSScriptRoot 'Receive-TeacherHarnessInputs.ps1') -SourceFile $provided
    $incomingReceipt = ($incomingJson -join [Environment]::NewLine) | ConvertFrom-Json
}
$basisSources = @($allItems | Where-Object { $_.role -in @('form','human_revision') })
if ($Purpose -eq 'Document' -and $basisSources.Count -eq 0) {
    throw 'needs_input: Existing draft or form required. Stop authoring and ask the user to provide or select one. Received materials remain saved.'
}


$copyEvidenceResolved = @($CopyEvidenceFile | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $_).Path) })
$copyReferenceResolved = @($CopyReferenceFile | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $_).Path) })
$authorityPaths = @($allItems | Where-Object { $_.role -in @('authority','form','human_revision','current_reference') } | ForEach-Object path)
$referencePaths = @($allItems | Where-Object { $_.role -in @('manual','prior_example') } | ForEach-Object path)
foreach ($copy in $copyEvidenceResolved) { if ($authorityPaths -notcontains $copy) { throw "CopyEvidenceFile must also be registered as AuthorityFile or FormFile: $copy" } }
foreach ($copy in $copyReferenceResolved) { if ($referencePaths -notcontains $copy) { throw "CopyReferenceFile must also be registered as ReferenceFile: $copy" } }

$supportNames = [Collections.Generic.List[string]]::new()
foreach ($raw in @($SupportFolderName | Where-Object { $_ })) {
    $name = Get-SafeName $raw
    if ($name -ne $raw.Trim()) { throw "SupportFolderName contains unsupported characters: $raw" }
    if ($name -in @([string]$config.metadataFolderName,[string]$config.archiveFolderName) -or $name -ieq [string]$config.consoleFileName) { throw "Reserved support-folder name: $name" }
    if (-not $supportNames.Contains($name)) { $supportNames.Add($name) }
}
if ($Collection -and -not $supportNames.Contains([string]$config.defaultCollectionFolderName)) { $supportNames.Add([string]$config.defaultCollectionFolderName) }
if ($copyEvidenceResolved.Count -gt 0 -and -not $supportNames.Contains([string]$config.defaultEvidenceFolderName)) { $supportNames.Add([string]$config.defaultEvidenceFolderName) }
if ($copyReferenceResolved.Count -gt 0 -and -not $supportNames.Contains([string]$config.defaultReferenceFolderName)) { $supportNames.Add([string]$config.defaultReferenceFolderName) }

$layoutReferencePath = $null
$layoutReferenceTitle = $null
if (-not [string]::IsNullOrWhiteSpace($LayoutReferenceFolder)) {
    $layoutReferencePath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $LayoutReferenceFolder).Path)
    if (-not (Test-Path -LiteralPath $layoutReferencePath -PathType Container)) { throw 'LayoutReferenceFolder must be an explicitly selected directory.' }
    $layoutReferenceTitle = [IO.Path]::GetFileName($layoutReferencePath)
}

$deliveryRequestText = if ($RequestText) { $RequestText.Trim() } else { $IntakeSummary.Trim() }
$deliveryRequestKey = if ($RequestId) { 'id:' + $RequestId.Trim() } else { 'text:' + (Get-DocumentScopeTextHash $deliveryRequestText) }
$priorDeliveryCycle = $null
if (Test-Path -LiteralPath (Join-Path $resolvedJob 'inputs.json')) {
    $priorDeliveryCycle = (Get-Content -LiteralPath (Join-Path $resolvedJob 'inputs.json') -Raw -Encoding utf8 | ConvertFrom-Json).deliveryCycle
}
if ($RequestId -and $priorDeliveryCycle -and $priorDeliveryCycle.requestKey -ceq $deliveryRequestKey -and $priorDeliveryCycle.requestText -cne $deliveryRequestText) { throw 'A RequestId cannot be reused with changed request text.' }
$newExplicitRequest = ($RequestText -or $RequestId) -and $priorDeliveryCycle -and $priorDeliveryCycle.requestKey -cne $deliveryRequestKey
$deliveryCycle = if ($priorDeliveryCycle -and $priorDeliveryCycle.requestKey -ceq $deliveryRequestKey) { $priorDeliveryCycle } else {
    [ordered]@{schemaVersion='human-delivery-cycle/v1';id=[guid]::NewGuid().ToString('D');requestKey=$deliveryRequestKey;requestText=$deliveryRequestText;startedAt=(Get-Date -Format 'o')}
}
$documentScope = $null
if (-not $RevokeDocumentScope -and -not $newExplicitRequest -and (Test-Path -LiteralPath (Join-Path $resolvedJob 'inputs.json'))) {
    $scopeInputs = Get-Content -LiteralPath (Join-Path $resolvedJob 'inputs.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $historicalJob = if ($scopeInputs.delivery.workRoot) { Join-Path (Join-Path (Join-Path ([string]$scopeInputs.delivery.workRoot) ([string]$config.metadataFolderName)) 'jobs') ([IO.Path]::GetFileName($resolvedJob)) } else { '' }
    # Stable identity was verified by Get-WorkJobInfo. A requested cabinet move
    # requires fresh scope/ready evidence, never rewriting old completion receipts.
    $movedScope = $scopeInputs.delivery.workId -and $scopeInputs.documentScope.schemaVersion -eq 'hwpx-document-scope/v1' -and $scopeInputs.documentScope.jobPath -ieq $historicalJob -and $historicalJob -ine $resolvedJob
    if (-not $movedScope) { $documentScope = Get-ActiveDocumentScope $resolvedJob }
}
if ($FinalPolishAuthorized -or $VisualReviewAuthorized) {
    # Existing evidence in the same active job remains valid. Never borrow a
    # Boolean permission from a different job or interpret Final as permission.
    if ($documentScope) {
        if (-not $FinalPolishAuthorized -and $documentScope.formatEditAllowed) { $FinalPolishAuthorized = $true; $FormattingRequestText = $documentScope.formatRequest.text }
        if (-not $VisualReviewAuthorized -and $documentScope.visualReviewAllowed) { $VisualReviewAuthorized = $true; $VisualReviewRequestText = $documentScope.visualRequest.text }
    }
    if (-not $documentScope -or $documentScope.formatRequest.text -cne $FormattingRequestText -or $documentScope.visualRequest.text -cne $VisualReviewRequestText) {
        $documentScope = New-DocumentScope -JobPath $resolvedJob -FinalPolishAuthorized:$FinalPolishAuthorized -VisualReviewAuthorized:$VisualReviewAuthorized -FormattingRequestText $FormattingRequestText -VisualReviewRequestText $VisualReviewRequestText
    }
}
if (-not $documentScope) { $documentScope = New-DocumentScope -JobPath $resolvedJob }
$FinalPolishAuthorized = [bool]$documentScope.formatEditAllowed
$VisualReviewAuthorized = [bool]$documentScope.visualReviewAllowed
$plan = [ordered]@{
    schemaVersion = 'hwpx-work-intake.plan/v2'
    mode = $Mode
    purpose = $Purpose
    taskTitle = $safeTitle
    decisionReason = $DecisionReason.Trim()
    workFolderName = $WorkFolderName
    workRoot = $workRoot
    requiredEntries = @([string]$config.metadataFolderName) + $(if ($UpdateConsole) { @([string]$config.consoleFileName) } else { @() })
    supportFolders = @($supportNames)
    layoutReference = $layoutReferencePath
    sources = @($allItems)
    copiedEvidence = @($copyEvidenceResolved)
    copiedReferences = @($copyReferenceResolved)
    editingMode = $(if ($FinalPolishAuthorized) { 'final_polish' } else { 'content_only' })
    finalPolishAuthorized = [bool]$FinalPolishAuthorized
    documentScope = $documentScope
    deliveryCycle = $deliveryCycle
    autoHumanRevisions = @($autoHumanRevisions)
    internalJobCreated = $createdJob
    jobPath = $resolvedJob
    workingDocuments = (Join-Path $resolvedJob 'wip/docs')
}
if ($PlanOnly) { $plan | ConvertTo-Json -Depth 8; return }
if($UpdateConsole -and -not(Test-Path -LiteralPath (Join-Path $cabinet '.agent\shared\Initialize-PortableCabinet.ps1'))){
    throw 'Optional cabinet console runtime is not installed. Install it explicitly before requesting UpdateConsole.'
}

$requestData = [ordered]@{
    mode=$Mode;purpose=$Purpose;title=$safeTitle;folder=$workRoot;summary=$IntakeSummary;decision=$DecisionReason
    sources=@($allItems | ForEach-Object { [ordered]@{path=$_.path;role=$_.role;sha256=$_.sha256;userProvided=$_.userProvided} })
    support=@($supportNames);layout=$LayoutReferenceFolder;layoutReason=$LayoutReason
    evidence=@($copyEvidenceResolved);references=@($copyReferenceResolved);collection=[bool]$Collection;polish=[bool]$FinalPolishAuthorized;updateConsole=[bool]$UpdateConsole
    documentScope=$documentScope;deliveryRequestKey=$deliveryRequestKey
} | ConvertTo-Json -Depth 8 -Compress
$sha = [Security.Cryptography.SHA256]::Create()
try { $requestFingerprint = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($requestData))).Replace('-','') } finally { $sha.Dispose() }
$priorReceiptPath = Join-Path $resolvedJob 'wip/receipts/work-intake.json'
if (Test-Path -LiteralPath $priorReceiptPath -PathType Leaf) {
    $priorReceipt = Get-Content -Raw -Encoding utf8 -LiteralPath $priorReceiptPath | ConvertFrom-Json
    if ($priorReceipt.requestFingerprint -eq $requestFingerprint -and $priorReceipt.deliveryCycle.id -eq $deliveryCycle.id -and (Test-Path -LiteralPath $workMetadataPath) -and (-not $UpdateConsole -or (Test-Path -LiteralPath $consolePath))) {
        & (Join-Path $PSScriptRoot 'Sync-HumanSourcePreservation.ps1') -WorkFolder $workRoot -Source $allItems -VerifyOnly | Out-Null
        $priorReceipt | Add-Member -NotePropertyName reused -NotePropertyValue $true -Force
        Hide-WorkMetadata
        Write-IntakeResponse $priorReceipt
        return
    }
}
$resumeNew = $false
$reservationPath = Join-Path $metadataRoot 'intake-request.json'
if ($existingNewFolder -and (Test-Path -LiteralPath $reservationPath -PathType Leaf)) {
    $reservation = Get-Content -Raw -Encoding utf8 -LiteralPath $reservationPath | ConvertFrom-Json
    $visibleOutputs = @(Get-ChildItem -LiteralPath $workRoot -File -Force | Where-Object { $_.Name -ine [string]$config.consoleFileName })
    $registeredOutputs = @($registry.works | Where-Object folderName -eq $WorkFolderName | ForEach-Object { $_.files } | Where-Object { $_ })
    $resumeNew = $reservation.requestFingerprint -eq $requestFingerprint -and $reservation.jobPath -ieq $resolvedJob -and $visibleOutputs.Count -eq 0 -and $registeredOutputs.Count -eq 0
}
if ($existingNewFolder -and -not $resumeNew) { throw "New work folder already exists and does not match this intake. Use FollowUp: $workRoot" }

$newWorkCreated = $false
$createdCopyTargets = [Collections.Generic.List[string]]::new()
$oldWorkMetadata = if (Test-Path -LiteralPath $workMetadataPath -PathType Leaf) { Get-Content -Raw -Encoding utf8 -LiteralPath $workMetadataPath } else { $null }
$oldSourceMetadata = if (Test-Path -LiteralPath $sourceMetadataPath -PathType Leaf) { Get-Content -Raw -Encoding utf8 -LiteralPath $sourceMetadataPath } else { $null }
$inputsPath = Join-Path $resolvedJob 'inputs.json'
$oldInputs = if (Test-Path -LiteralPath $inputsPath) { Get-Content -Raw -Encoding utf8 -LiteralPath $inputsPath } else { $null }

try {
    if ($Mode -eq 'New' -and -not $resumeNew) { New-Item -ItemType Directory -Path $workRoot | Out-Null; $newWorkCreated = $true }
    if ($pendingJobCreation) {
        $jobGoal = if ([string]::IsNullOrWhiteSpace($Goal)) { $TaskTitle } else { $Goal.Trim() }
        $createdPath = (& (Join-Path $PSScriptRoot 'New-HwpxJob.ps1') -Slug $JobSlug -Goal $jobGoal -Date $jobDate -WorkFolder $workRoot | Select-Object -Last 1)
        if ([IO.Path]::GetFullPath([string]$createdPath) -ine $resolvedJob) { throw 'Job creation returned an unexpected path.' }
        $createdJob = $true
        $oldInputs = Get-Content -Raw -Encoding utf8 -LiteralPath $inputsPath
    }
    New-Item -ItemType Directory -Path $metadataRoot -Force | Out-Null
    $metadataItem = Get-Item -LiteralPath $metadataRoot -Force
    $metadataItem.Attributes = $metadataItem.Attributes -bor [IO.FileAttributes]::Hidden
    if ($Mode -eq 'New') { Write-JsonAtomic $reservationPath ([ordered]@{requestFingerprint=$requestFingerprint;jobPath=$resolvedJob;createdAt=$now}) }
    foreach ($name in $supportNames) { New-Item -ItemType Directory -Path (Join-Path $workRoot $name) -Force | Out-Null }
    if ($Collection) { New-Item -ItemType Directory -Path (Join-Path (Join-Path $workRoot ([string]$config.defaultCollectionFolderName)) '받은자료') -Force | Out-Null }

    $workMetadata = if ($Mode -eq 'FollowUp') {
        if (-not $oldWorkMetadata) { throw "Selected work metadata is missing. Reconcile its existing current files before intake: $workRoot" }
        $oldWorkMetadata | ConvertFrom-Json | ConvertTo-HashtableDeep
    } else {
        [ordered]@{
            schemaVersion = 'hwpx-human-work/v1'
            title = $safeTitle
            folderName = $WorkFolderName
            createdDate = $CreatedDate
            firstIntakeAt = $now
            lastIntakeAt = $now
            status = '접수'
            stage = 'None'
            publishedAt = $null
            currentFiles = @()
            nextAction = '근거 검토 후 필요한 결과물과 처리 일정을 확정'
            review = [ordered]@{ state='none'; question='' }
            editing = [ordered]@{
                mode='content_only'; finalPolishAuthorized=$false; authorizedAt=$null
                humanRevisionPolicy='preserve_current_file_and_edit_only_empty_or_explicit_targets'
            }
            layout = [ordered]@{ referenceFolder=$layoutReferencePath; referenceTitle=$layoutReferenceTitle; reason=$LayoutReason.Trim(); supportFolders=@($supportNames) }
            collection = [ordered]@{ enabled=[bool]$Collection; receivedFolder=$(if($Collection){([string]$config.defaultCollectionFolderName + '\받은자료')}else{$null}) }
            history = @()
        }
    }
    if (-not $workMetadata['workId']) { $workMetadata['workId'] = [guid]::NewGuid().ToString('D') }
    $workMetadata['deliveryCycle'] = $deliveryCycle
    $workMetadata['lastIntakeAt'] = $now
    $workMetadata['status'] = if ($Mode -eq 'New') { '접수' } else { '후속 접수' }
    $workMetadata['nextAction'] = '근거 검토 후 필요한 결과물과 처리 일정을 확정'
    if (-not $workMetadata.Contains('editing') -or -not ($workMetadata.editing -is [Collections.IDictionary])) { $workMetadata['editing'] = [ordered]@{} }
    $workMetadata.editing['mode'] = if ($FinalPolishAuthorized) { 'final_polish' } else { 'content_only' }
    $workMetadata.editing['finalPolishAuthorized'] = [bool]$FinalPolishAuthorized
    $workMetadata.editing['authorizedAt'] = if ($FinalPolishAuthorized) { $now } else { $null }
    $workMetadata.editing['documentScope'] = $documentScope
    $workMetadata.editing['humanRevisionPolicy'] = 'preserve_current_file_and_edit_only_empty_or_explicit_targets'
    if (-not $workMetadata.Contains('layout') -or -not ($workMetadata.layout -is [Collections.IDictionary])) { $workMetadata['layout'] = [ordered]@{} }
    $workMetadata.layout['referenceFolder'] = $layoutReferencePath
    $workMetadata.layout['referenceTitle'] = $layoutReferenceTitle
    $workMetadata.layout['reason'] = $LayoutReason.Trim()
    $existingSupport = @($workMetadata.layout.supportFolders)
    $workMetadata.layout['supportFolders'] = @($existingSupport + @($supportNames) | Where-Object { $_ } | Select-Object -Unique)
    if (-not $workMetadata.Contains('history')) { $workMetadata['history'] = @() }
    $workMetadata['history'] = @($workMetadata.history) + @([ordered]@{ at=$now; event=$Mode; summary=$IntakeSummary.Trim(); decision=$DecisionReason.Trim(); editingMode=$workMetadata.editing.mode; autoHumanRevisions=$autoHumanRevisions.Count })

    $sourceMetadata = if ($oldSourceMetadata) { $oldSourceMetadata | ConvertFrom-Json | ConvertTo-HashtableDeep } else { [ordered]@{ schemaVersion='hwpx-human-sources/v1'; updatedAt=$now; sources=@() } }
    $sourceList = @($sourceMetadata.sources)
    foreach ($item in $allItems) {
        $existingCopy = @($sourceList | Where-Object { $_.path -ieq $item.path -and $_.sha256 -ieq $item.sha256 -and $_.copyRelativePath }) | Select-Object -First 1
        if ($existingCopy) { $item['copyRelativePath'] = $existingCopy.copyRelativePath }
    }
    $preservationJson = & (Join-Path $PSScriptRoot 'Sync-HumanSourcePreservation.ps1') -WorkFolder $workRoot -Source $allItems
    $preservation = ($preservationJson -join [Environment]::NewLine) | ConvertFrom-Json

    $evidenceCopyRoot = if ($copyEvidenceResolved.Count -gt 0) { Join-Path (Join-Path (Join-Path $workRoot ([string]$config.defaultEvidenceFolderName)) ([string]$config.evidenceCopyFolderName)) "${stamp}_접수" } else { $null }
    $referenceCopyRoot = if ($copyReferenceResolved.Count -gt 0) { Join-Path (Join-Path (Join-Path $workRoot ([string]$config.defaultReferenceFolderName)) '선별자료') "${stamp}_참고" } else { $null }
    foreach ($item in $allItems) {
        $copyRelative = $null
        if ($copyEvidenceResolved -contains $item.path) {
            New-Item -ItemType Directory -Path $evidenceCopyRoot -Force | Out-Null
            $target = Join-Path $evidenceCopyRoot $item.name
            Copy-Item -LiteralPath $item.path -Destination $target
            $createdCopyTargets.Add($target)
            $copyRelative = (Get-RelativePathCompat $workRoot $target)
        } elseif ($copyReferenceResolved -contains $item.path) {
            New-Item -ItemType Directory -Path $referenceCopyRoot -Force | Out-Null
            $target = Join-Path $referenceCopyRoot $item.name
            Copy-Item -LiteralPath $item.path -Destination $target
            $createdCopyTargets.Add($target)
            $copyRelative = (Get-RelativePathCompat $workRoot $target)
        }
        $stored = @($preservation.records | Where-Object { $_.path -ieq $item.path -and $_.sha256 -ieq $item.sha256 }) | Select-Object -First 1
        $existing = @($sourceList | Where-Object { $_.path -ieq $item.path -and $_.role -eq $item.role -and $_.sha256 -ieq $item.sha256 }) | Select-Object -First 1
        if (-not $existing) {
            $existing = [ordered]@{path=$item.path;name=$item.name;role=$item.role;sha256=$item.sha256;selectedAt=$now;copyRelativePath=$copyRelative;userProvided=[bool]$item.userProvided}
            $sourceList += $existing
        }
        if ($stored) { $existing['userProvided']=$true; $existing['copyRelativePath']=$stored.copyRelativePath; $existing['preservedAt']=$stored.preservedAt }
    }
    $sourceMetadata['updatedAt'] = $now
    $sourceMetadata['sources'] = @($sourceList)
    Write-JsonAtomic $sourceMetadataPath $sourceMetadata

    $priorStage = if ($entry) { [string]$entry.stage } else { 'None' }
    $priorPublished = if ($entry) { $entry.publishedAt } else { $null }
    $priorFiles = if ($entry) { @($entry.files) } else { @() }
    $firstIntake = if ($entry -and $entry.firstIntakeAt) { [string]$entry.firstIntakeAt } else { $now }
    $newEntry = [ordered]@{
        workId = [string]$workMetadata.workId
        title = $safeTitle
        createdDate = $CreatedDate
        folderName = $WorkFolderName
        workState = $(if ($Mode -eq 'New') { 'Intake' } else { 'FollowUp' })
        firstIntakeAt = $firstIntake
        lastIntakeAt = $now
        stage = $priorStage
        publishedAt = $priorPublished
        files = @($priorFiles)
        metadataFolder = [string]$config.metadataFolderName
        console = $(if ($UpdateConsole) { [string]$config.consoleFileName } elseif ($entry.console) { $entry.console } else { $null })
        supportFolders = @($workMetadata.layout.supportFolders)
        layoutReference = $layoutReferencePath
        currentFileRecords = @($entry.currentFileRecords)
    }
    Set-WorkRegistration -Metadata $workMetadata -Entry $newEntry
    Write-JsonAtomic $workMetadataPath $workMetadata

    $inputs = $oldInputs | ConvertFrom-Json | ConvertTo-HashtableDeep
    $inputs['documentBasis'] = New-WorkDocumentBasis -Purpose $Purpose -Sources $basisSources -Preserved @($preservation.records)
    $inputs['incomingReceipt'] = $incomingReceipt
    $inputs['documentScope'] = $documentScope
    $inputs['deliveryCycle'] = $deliveryCycle
    $selectedSources = @($inputs.sources)
    $knownInputPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($source in $selectedSources) { if ($source.path) { [void]$knownInputPaths.Add(([string]$source.path + '|' + $source.role + '|' + $source.sha256)) } }
    foreach ($item in $allItems) {
        if (-not $knownInputPaths.Add(([string]$item.path + '|' + $item.role + '|' + $item.sha256))) {
            if ($item.userProvided) { foreach ($existing in @($selectedSources | Where-Object { $_.path -ieq $item.path -and $_.sha256 -ieq $item.sha256 })) { $existing['userProvided']=$true } }
            continue
        }
        $selectedSources += [ordered]@{
            path=$item.path; role=$item.role; sha256=$item.sha256; userProvided=[bool]$item.userProvided
            selection=$(if($item.role -in @('manual','prior_example')){'구조·문구 참고용으로 선택'}else{'현재 업무의 접수 근거로 선택'})
            exclusions=$(if($item.role -eq 'prior_example'){'날짜·사람·금액·마감·법적 근거는 전용 금지'}elseif($item.role -eq 'manual'){'현재 규정·결재 문서와 충돌하면 최신 권위를 우선'}else{''})
        }
    }
    $inputs['sources'] = @($selectedSources)
    $inputs['userProvidedSelectionRecorded'] = $true
    $inputs['delivery'] = [ordered]@{workRoot=$workRoot;workId=[string]$workMetadata.workId;storageKind=$jobInfo.storageKind}
    Write-JsonAtomic $inputsPath $inputs

    Hide-WorkMetadata
    $consoleReceipt = $null
    if ($UpdateConsole) {
        $consoleJson = & (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -WorkFolder $workRoot
        $consoleReceipt = ($consoleJson -join [Environment]::NewLine) | ConvertFrom-Json
    }
    $receipt = [ordered]@{
        schemaVersion='hwpx-work-intake.receipt/v2'; completedAt=$now; mode=$Mode; taskTitle=$safeTitle
        workFolderName=$WorkFolderName; workRoot=$workRoot; workState=$newEntry.workState
        jobPath=$resolvedJob; workingDocuments=(Join-Path $resolvedJob 'wip/docs')
        sourcesRegistered=$allItems.Count; evidenceCopies=$copyEvidenceResolved.Count; referenceCopies=$copyReferenceResolved.Count
        collectionCreated=[bool]$Collection; supportFolders=@($workMetadata.layout.supportFolders); layoutReference=$layoutReferencePath; console=$consoleReceipt
        editingMode=$workMetadata.editing.mode; finalPolishAuthorized=[bool]$FinalPolishAuthorized; autoHumanRevisions=@($autoHumanRevisions)
        sourcePreservation=$preservation; elapsedSeconds=[Math]::Round($intakeWatch.Elapsed.TotalSeconds,3)
        requestFingerprint=$requestFingerprint;deliveryCycle=$deliveryCycle;purpose=$Purpose;incomingReceipt=$incomingReceipt
    }
    Write-JsonAtomic (Join-Path $resolvedJob 'wip\receipts\work-intake.json') $receipt
    Write-IntakeResponse $receipt
} catch {
    Set-Content -LiteralPath $inputsPath -Value $oldInputs -Encoding utf8 -ErrorAction SilentlyContinue
    foreach ($target in $createdCopyTargets) { if (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue } }
    if ($newWorkCreated -and (Test-Path -LiteralPath $workRoot -PathType Container)) {
        $verified = [IO.Path]::GetFullPath($workRoot)
        if ($verified.StartsWith($cabinetPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-WorkFolderName ([IO.Path]::GetFileName($verified)))) { Remove-Item -LiteralPath $verified -Recurse -Force -ErrorAction SilentlyContinue }
    } else {
        if ($null -ne $oldWorkMetadata) { Set-Content -LiteralPath $workMetadataPath -Value $oldWorkMetadata -Encoding utf8 -ErrorAction SilentlyContinue }
        if ($null -ne $oldSourceMetadata) { Set-Content -LiteralPath $sourceMetadataPath -Value $oldSourceMetadata -Encoding utf8 -ErrorAction SilentlyContinue }
        if ($UpdateConsole) { try { & (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -WorkFolder $workRoot | Out-Null } catch {} }
    }
    if ($createdJob -and (Test-Path -LiteralPath $resolvedJob -PathType Container)) {
        $verifiedJob = [IO.Path]::GetFullPath($resolvedJob)
        if ([IO.Path]::GetDirectoryName($verifiedJob) -ieq (Join-Path $metadataRoot 'jobs') -and [IO.Path]::GetFileName($verifiedJob) -match '^\d{8}-[a-z0-9][a-z0-9-]+$') {
            Remove-Item -LiteralPath $verifiedJob -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    throw
}
