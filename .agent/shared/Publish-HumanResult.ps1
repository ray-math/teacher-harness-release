[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Files')]
    [ValidateSet('Review', 'Final')]
    [string]$Stage,

    [Parameter(Mandatory = $true, ParameterSetName = 'Files')]
    [Parameter(ParameterSetName = 'ConsoleContent')]
    [ValidateNotNullOrEmpty()]
    [string]$TaskTitle,

    [string]$WorkFolderName = '',

    [Parameter(Mandatory = $true, ParameterSetName = 'Files')]
    [ValidateNotNullOrEmpty()]
    [string[]]$SourceFile,
    [Parameter(ParameterSetName = 'Files')]
    [string[]]$TargetRelativePath = @(),
    [Parameter(ParameterSetName = 'Files')]
    [switch]$PartialUpdate,
    # Only an actual user-requested text artifact may opt in; never infer this from its name/content.
    [Parameter(ParameterSetName = 'Files')]
    [switch]$ExplicitTextArtifact,
    [Parameter(ParameterSetName = 'Files')]
    [switch]$UpdateConsole,
    [Parameter(Mandatory = $true, ParameterSetName = 'ConsoleContent')]
    [ValidateNotNullOrEmpty()]
    [string]$ConsoleContentPath,

    [ValidatePattern('^\d{8}$')]
    [string]$CreatedDate = (Get-Date -Format 'yyyyMMdd'),
    [string]$ReviewQuestion = '',
    [string]$FormContractPath = '',
    [string[]]$FormBaseFile = @(),
    [string]$NormalizationReceiptPath = '',
    [string]$NativeMergeReceiptPath = '',
    [string]$SubjectReplacementReceiptPath = '',
    [switch]$FormGateNotApplicable,
    [string]$FormGateReason = '',
    [string]$DeliveryConfigPath = '',
    [string]$RegistryPath = '',
    [switch]$PlanOnly,
    [Parameter(ParameterSetName = 'Files')]
    [switch]$Summary
)

$ErrorActionPreference = 'Stop'
if ($PSCmdlet.ParameterSetName -eq 'ConsoleContent') {
    # Console publication is independent of document completion and replacement.
    $consoleArgs = @{}
    foreach ($key in @('TaskTitle','WorkFolderName','ConsoleContentPath','DeliveryConfigPath','RegistryPath','PlanOnly','WhatIf','Confirm')) {
        if ($PSBoundParameters.ContainsKey($key)) { $consoleArgs[$key] = $PSBoundParameters[$key] }
    }
    foreach ($key in @('CreatedDate','ReviewQuestion','FormContractPath','FormBaseFile','NormalizationReceiptPath','NativeMergeReceiptPath','SubjectReplacementReceiptPath','FormGateNotApplicable','FormGateReason')) {
        if ($PSBoundParameters.ContainsKey($key)) { throw "ConsoleContentPath cannot be combined with document publication parameter: $key" }
    }
    & (Join-Path $PSScriptRoot 'Publish-HumanConsoleContent.ps1') @consoleArgs
    return
}
$publishWatch = [Diagnostics.Stopwatch]::StartNew()
function Write-PublishResponse($Receipt, [string]$ReceiptPath) {
    if (-not $Summary) { $Receipt | ConvertTo-Json -Depth 7; return }
    [ordered]@{
        schemaVersion='hwpx-human-delivery.summary/v1'; status='published'; stage=$Receipt.stage
        reusedCurrentFiles=[bool]$Receipt.reusedCurrentFiles; idempotentRetry=[bool]$Receipt.idempotentRetry
        currentRoot=$Receipt.currentRoot; fileCount=@($Receipt.files).Count
        files=@($Receipt.files | ForEach-Object { $_.target })
        archivedFileCount=@($Receipt.archivedFiles).Count
        deliveryCycleId=$Receipt.deliveryCycleId; receiptPath=$ReceiptPath
        elapsedSeconds=$Receipt.elapsedSeconds
    } | ConvertTo-Json -Depth 4 -Compress
}

function Get-PublishFileHash {
    param([string]$LiteralPath,[string]$Algorithm='SHA256')
    if($Algorithm -ne 'SHA256'){throw 'Only SHA256 supported'}
    $stream=[IO.File]::Open($LiteralPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { [pscustomobject]@{Hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','');Path=$LiteralPath;Algorithm='SHA256'} }
    finally {$sha.Dispose();$stream.Dispose()}
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
$defaultConfigPath = Join-Path $workspace '.agent\index\delivery-system.json'
if ((-not [string]::IsNullOrWhiteSpace($DeliveryConfigPath) -or -not [string]::IsNullOrWhiteSpace($RegistryPath)) -and -not $PlanOnly) {
    throw 'DeliveryConfigPath and RegistryPath overrides are allowed only with PlanOnly for isolated verification.'
}
$resolvedConfigPath = if ([string]::IsNullOrWhiteSpace($DeliveryConfigPath)) { $defaultConfigPath } else { [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DeliveryConfigPath).Path) }
$resolvedRegistryPath = if ($RegistryPath) { [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RegistryPath).Path) } else { $null }
$config = Get-Content -Raw -Encoding utf8 -LiteralPath $resolvedConfigPath | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$cabinet = [IO.Path]::GetFullPath([string]$config.humanCabinet)
$allowedExtensions = @('.hwpx','.hwp','.pdf','.docx','.odt','.xlsx','.xls','.pptx','.txt','.csv')

function Get-SafeName([string]$Value) {
    $result = $Value.Trim()
    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) { $result = $result.Replace([string]$char, ' ') }
    ($result -replace '\s+', ' ').Trim(' ', '.')
}

function Write-JsonAtomic([string]$Path, [object]$Value, [int]$Depth = 12) {
    $parent = [IO.Path]::GetDirectoryName($Path)
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
$registryPath = $resolvedRegistryPath
$registry = if ($RegistryPath) { Get-Content -Raw -Encoding utf8 -LiteralPath $registryPath | ConvertFrom-Json } else { Get-WorkRegistry -Workspace $workspace -DeliveryConfigPath $resolvedConfigPath }
$currentEntry = if ($WorkFolderName) { @($registry.works | Where-Object folderName -eq $WorkFolderName) } else { @($registry.works | Where-Object title -eq $safeTitle) }
if ($currentEntry.Count -gt 1) { throw 'More than one registered work matches. Pass WorkFolderName explicitly.' }
if ($currentEntry.Count -eq 0) { throw 'No intake record exists for this work. Run Start-HwpxWork.ps1 before publishing.' }
$WorkFolderName = [string]$currentEntry[0].folderName
$CreatedDate = [string]$currentEntry[0].createdDate

$workRoot = [IO.Path]::GetFullPath((Join-Path $cabinet $WorkFolderName))
$cabinetPrefix = $cabinet.TrimEnd('\') + '\'
if (-not $workRoot.StartsWith($cabinetPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Work target escaped the human cabinet: $workRoot" }
if (-not (Test-WorkFolderName $WorkFolderName)) { throw "Invalid work-folder name: $WorkFolderName" }
$metadataRoot = Join-Path $workRoot ([string]$config.metadataFolderName)
$archiveRoot = Join-Path $metadataRoot 'revisions'
$workMetadataPath = Join-Path $metadataRoot ([string]$config.workMetadataName)
if (-not (Test-Path -LiteralPath $workMetadataPath -PathType Leaf)) { throw "Hidden work metadata is missing: $workMetadataPath" }
$prePublishWorkMetadata = Get-Content -Raw -Encoding utf8 -LiteralPath $workMetadataPath | ConvertFrom-Json | ConvertTo-HashtableDeep
# Delivery stage records content completion. Formatting permission remains
# independent and is passed unchanged to the Hanword preservation gate below.

$targetNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($TargetRelativePath.Count -gt 0 -and $TargetRelativePath.Count -ne $SourceFile.Count) { throw 'TargetRelativePath must contain one relative path for every SourceFile.' }
$sourceIndex = 0
$plans = foreach ($item in $SourceFile) {
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $item).Path)
    $sourceJobInfo = Get-WorkJobInfo -Workspace $workspace -Path $resolved -RequireExists
    if ($sourceJobInfo.storageKind -eq 'work' -and $sourceJobInfo.workRoot -ine $workRoot) { throw 'Publish source belongs to a different human work folder.' }
    $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($allowedExtensions -notcontains $extension -and $extension -ne '.xlsm') { throw "Unsupported publish extension: $extension" }
    $name = [IO.Path]::GetFileName($resolved)
    # Full-set publication may carry registered support-folder files unchanged.
    # Only the explicit job/wip/carry tree preserves a relative target name.
    $carryRoot = Join-Path $sourceJobInfo.jobRoot 'wip\carry'
    $docsRoot = Join-Path $sourceJobInfo.jobRoot 'wip\docs'
    $isCarry = $resolved.StartsWith(($carryRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
    if ($sourceJobInfo.storageKind -eq 'work' -and -not $isCarry -and -not $resolved.StartsWith($docsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'School publication source must be inside its job wip/docs tree.' }
    if ($TargetRelativePath.Count -gt 0) { $name = $TargetRelativePath[$sourceIndex] }
    elseif ($sourceJobInfo.storageKind -eq 'work') {
        if (-not $isCarry) { $name = Get-RelativePathCompat $docsRoot $resolved }
    }
    $sourceIndex++
    if ($isCarry) {
        $carryName = Get-RelativePathCompat $carryRoot $resolved
        if ($TargetRelativePath.Count -gt 0 -and $name -ine $carryName) { throw 'Carry files cannot be renamed.' }
        $name = $carryName
        if ($name -notin @($currentEntry[0].files)) { throw "Carry source must match a registered current relative path: $name" }
    }
    $registeredSamePath = Get-WorkCurrentTarget -WorkRoot $workRoot -RelativePath $name -ReservedNames @([string]$config.metadataFolderName,[string]$config.archiveFolderName)
    $name = Get-RelativePathCompat $workRoot $registeredSamePath
    if ([IO.Path]::GetExtension($name) -ine $extension) { throw 'TargetRelativePath must preserve the source extension.' }
    $unchangedCurrent = $name -in @($currentEntry[0].files) -and
        (Test-Path -LiteralPath $registeredSamePath -PathType Leaf) -and
        ((Get-PublishFileHash -LiteralPath $resolved -Algorithm SHA256).Hash -eq (Get-PublishFileHash -LiteralPath $registeredSamePath -Algorithm SHA256).Hash)
    if ($isCarry -and -not $unchangedCurrent) { throw "Carry source differs from the current human file: $name" }
    if ($extension -eq '.xlsm' -and -not ($isCarry -and $unchangedCurrent)) { throw 'Macro workbooks may only be retained byte-identically through the registered carry route.' }
    # Carrying an existing registered TXT forward byte-for-byte does not create a TXT artifact.
    # New or changed TXT output still requires the user's explicit text-artifact request.
    if ($extension -eq '.txt' -and -not $ExplicitTextArtifact -and -not $unchangedCurrent) { throw 'TXT publication requires ExplicitTextArtifact for an actual user-requested TXT artifact. Give explanations in chat unless a separate artifact was requested.' }
    # A partial update must retain unrelated current files byte-for-byte, including their names.
    if ($name -notin @($currentEntry[0].files) -and $name -match '(^\d{8}[_-]|\(안\)|초안|검토용|draft|final|v\d+)') { throw "Human-facing filename contains a date/draft/version marker: $name" }
    if ($name -ieq [string]$config.consoleFileName) { throw "Deliverable filename is reserved for the human console: $name" }
    if (-not $targetNames.Add($name)) { throw "Duplicate target filename: $name" }
    [ordered]@{ source=$resolved; name=$name; target=$registeredSamePath; unchangedCurrent=[bool]$unchangedCurrent; jobRoot=$sourceJobInfo.jobRoot }
}

$priorState = [string]$currentEntry[0].stage
$priorNames = @($currentEntry[0].files | Where-Object { $_ } | Select-Object -Unique)
$retainedNames = @()
if ($PartialUpdate) {
    if (@($plans | Where-Object { $_.name -notin $priorNames }).Count -gt 0) { throw 'PartialUpdate may only replace registered filenames; use full publication for additions, renames or removals.' }
    $retainedNames = @($priorNames | Where-Object { -not $targetNames.Contains($_) })
}
$unchangedNames = @($plans | Where-Object unchangedCurrent | ForEach-Object name)
$affectedPriorNames = @($priorNames | Where-Object { $_ -notin $retainedNames -and $_ -notin $unchangedNames })
$resultNames = @($plans | ForEach-Object name) + @($retainedNames)
$actualRootNames = @(
    Get-ChildItem -LiteralPath $workRoot -File -Force |
        Where-Object { $_.Name -ne [string]$config.consoleFileName } |
        ForEach-Object Name
)
$registeredRevisionNames = @($prePublishWorkMetadata.revisionHistory | ForEach-Object relativePath)
$unexpectedRootNames = @($actualRootNames | Where-Object { $priorNames -notcontains $_ -and $registeredRevisionNames -notcontains $_ })
$missingRegisteredNames = @(
    foreach ($name in $priorNames) {
        # Registered current files can live in a visible support folder. Validate
        # the relative path before checking existence; never traverse a link.
        $parts = @(([string]$name) -split '[\\/]')
        if ([IO.Path]::IsPathRooted($name) -or @($parts | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' -or $_.StartsWith('.') -or $_.Contains(':') }).Count -gt 0) {
            throw "Unsafe registered current-file path: $name"
        }
        $registeredPath = [IO.Path]::GetFullPath((Join-Path $workRoot $name))
        if (-not $registeredPath.StartsWith(($workRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw "Registered file escaped the work folder: $name" }
        $walkPath = $workRoot
        foreach ($part in @('') + $parts) {
            if ($part) { $walkPath = Join-Path $walkPath $part }
            if (Test-Path -LiteralPath $walkPath) {
                $attributes = (Get-Item -LiteralPath $walkPath -Force).Attributes
                if ($attributes -band ([IO.FileAttributes]::ReparsePoint -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)) { throw "Registered file uses a hidden, system or reparse-point path: $name" }
            }
        }
        if (-not (Test-Path -LiteralPath $registeredPath -PathType Leaf)) { $name }
    }
)
if ($missingRegisteredNames.Count -gt 0) { throw 'Registered current files are missing; reconcile before publishing.' }
if ($unexpectedRootNames.Count -gt 0) {
    throw "Unregistered human-facing file(s) must be reconciled before publish: $($unexpectedRootNames -join ', ')"
}
foreach ($plan in $plans) {
    if ((Test-Path -LiteralPath $plan.target) -and ($priorNames -notcontains $plan.name)) { throw "A current file with this name is not registered to this work: $($plan.target)" }
}

$jobInputs = [Collections.Generic.List[object]]::new()
$seenJobRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($plan in $plans) {
    $jobRoot = [string]$plan.jobRoot
    if (-not $seenJobRoots.Add($jobRoot)) { continue }
    $jobInputsPath = Join-Path $jobRoot 'inputs.json'
    if (-not (Test-Path -LiteralPath $jobInputsPath -PathType Leaf)) { throw "Active job inputs are missing: $jobInputsPath" }
    $inputsForJob = Get-Content -Raw -Encoding utf8 -LiteralPath $jobInputsPath | ConvertFrom-Json
    if ($inputsForJob.delivery.workRoot -and [IO.Path]::GetFullPath([string]$inputsForJob.delivery.workRoot) -ine $workRoot) { throw 'Job intake is bound to a different human work folder.' }
    $sourceInfo = Get-WorkJobInfo -Workspace $workspace -Path $jobRoot -RequireJobRoot -RequireExists
    if ($sourceInfo.storageKind -eq 'work' -and -not $inputsForJob.delivery.workRoot) { throw 'School job intake binding is missing. Resume intake before publishing.' }
    $jobInputs.Add($inputsForJob)
}
if (-not $PlanOnly -and @($jobInputs | Where-Object { $_.userProvidedSelectionRecorded -ne $true }).Count -gt 0) {
    throw 'Legacy intake has no user-provided source selection. Resume with Start-HwpxWork.ps1 and identify UserProvidedFile before publishing.'
}
$hanwordPlans = @($plans | Where-Object { -not $_.unchangedCurrent -and [IO.Path]::GetExtension([string]$_.source).ToLowerInvariant() -in @('.hwpx','.hwp') })
$requiredOriginals = @($jobInputs | ForEach-Object { @($_.sources | Where-Object { $_.userProvided -eq $true }) })
$sourcePreservation = [ordered]@{ok=$true;verifyOnly=$true;records=@();seconds=0}
if ($requiredOriginals.Count -gt 0) {
    $sourcePreservationJson = & (Join-Path $PSScriptRoot 'Sync-HumanSourcePreservation.ps1') -WorkFolder $workRoot -Source $requiredOriginals -VerifyOnly
    $sourcePreservation = ($sourcePreservationJson -join [Environment]::NewLine) | ConvertFrom-Json
}
# The human provenance metadata must agree with the durable preservation receipt.
$sourceMetadataPath = Join-Path $metadataRoot ([string]$config.sourceMetadataName)
if ($requiredOriginals.Count -gt 0) {
    $humanSources = Get-Content -Raw -Encoding utf8 -LiteralPath $sourceMetadataPath | ConvertFrom-Json
    foreach ($record in @($sourcePreservation.records)) {
        if (@($humanSources.sources | Where-Object { $_.path -ieq $record.path -and $_.role -eq $record.role -and $_.sha256 -ieq $record.sha256 -and $_.copyRelativePath -ieq $record.copyRelativePath }).Count -eq 0) { throw 'Source preservation metadata is incomplete. Resume intake before publishing.' }
    }
}
$formGate = [ordered]@{schemaVersion='hwpx-publish-form-gate/v1';ok=$true;route='not_applicable_no_hanword';sources=@()}
if ($hanwordPlans.Count -gt 0) {
    if ($seenJobRoots.Count -ne 1) { throw 'A Hanword publish set must come from one active job so one canonical form contract controls it.' }
    $jobRoot = @($seenJobRoots)[0]
    . (Join-Path $PSScriptRoot 'DocumentScope.ps1')
    $publishScope = Get-ActiveDocumentScope $jobRoot
    if ($prePublishWorkMetadata.editing.finalPolishAuthorized -and (-not $publishScope -or -not $publishScope.formatEditAllowed)) {
        throw 'Document scope blocks publication: a Boolean flag without active job request evidence is not authorization.'
    }
    $gateArgs = @{
        JobPath=$jobRoot
        SourceFile=@($hanwordPlans | ForEach-Object source)
        FormContractPath=$FormContractPath
        FormBaseFile=@($FormBaseFile)
        NormalizationReceiptPath=$NormalizationReceiptPath
        FinalPolishAuthorized=[bool]($publishScope -and $publishScope.formatEditAllowed)
        FormGateNotApplicable=[bool]$FormGateNotApplicable
        FormGateReason=$FormGateReason
    }
    if ($SubjectReplacementReceiptPath) {
        if($NativeMergeReceiptPath -or $FormContractPath -or $FormGateNotApplicable -or $FormBaseFile.Count -gt 0 -or $NormalizationReceiptPath){throw 'Subject replacement publication cannot be combined with another form route'}
        $gateJson = & (Join-Path $PSScriptRoot 'Assert-SubjectReplacementPublication.ps1') -JobPath $jobRoot -SourceFile @($hanwordPlans | ForEach-Object source) -ReceiptPath $SubjectReplacementReceiptPath
    } elseif ($NativeMergeReceiptPath) {
        if($hanwordPlans.Count -ne 1 -or $FormContractPath -or $FormGateNotApplicable){throw 'Native merge publication requires exactly one changed Hanword file and no conflicting form route'}
        $gateJson = & (Join-Path $PSScriptRoot 'Assert-NativeMergePublication.ps1') -JobPath $jobRoot -SourceFile $hanwordPlans[0].source -ReceiptPath $NativeMergeReceiptPath
    } else {
        $gateJson = & (Join-Path $PSScriptRoot 'Assert-HwpxPublishGate.ps1') @gateArgs
    }
    $formGate = ($gateJson -join [Environment]::NewLine) | ConvertFrom-Json | ConvertTo-HashtableDeep
}
$humanBaseChecks = [Collections.Generic.List[object]]::new()
foreach ($name in $affectedPriorNames) {
    $priorPath = Join-Path $workRoot $name
    if (-not (Test-Path -LiteralPath $priorPath -PathType Leaf)) { continue }
    $currentHash = (Get-PublishFileHash -LiteralPath $priorPath -Algorithm SHA256).Hash
    $samePublishedSource = @($plans | Where-Object { $_.name -ieq $name -and (Get-PublishFileHash -LiteralPath $_.source -Algorithm SHA256).Hash -eq $currentHash }).Count -gt 0
    $registeredHumanBase = $false
    foreach ($inputs in $jobInputs) {
        if (@($inputs.sources | Where-Object {
            $_.role -eq 'human_revision' -and
            [IO.Path]::GetFullPath([string]$_.path) -ieq [IO.Path]::GetFullPath($priorPath) -and
            [string]$_.sha256 -eq $currentHash
        }).Count -gt 0) { $registeredHumanBase = $true; break }
    }
    $humanBaseChecks.Add([ordered]@{ path=$priorPath; sha256=$currentHash; registered=$registeredHumanBase; unchangedRepublish=$samePublishedSource })
    if (-not $registeredHumanBase -and -not $samePublishedSource) {
        throw "The current human file was not registered with its exact hash as human_revision. Resume with Start-HwpxWork.ps1 before replacing it: $priorPath"
    }
}

$payload = [ordered]@{
    schemaVersion='hwpx-human-delivery.publish/v6'; stage=$Stage; taskTitle=$safeTitle; createdDate=$CreatedDate
    workFolderName=$WorkFolderName; currentRoot=$workRoot; archiveRoot=$archiveRoot; priorState=$priorState
    priorFiles=@($priorNames); files=@($plans); retainedFiles=@($retainedNames); partialUpdate=[bool]$PartialUpdate; console=$(if($UpdateConsole){Join-Path $workRoot ([string]$config.consoleFileName)}else{$null})
    humanRevisionChecks=@($humanBaseChecks); editingMode=$prePublishWorkMetadata.editing.mode; formGate=$formGate
    sourcePreservation=$sourcePreservation
    explicitTextArtifact=[bool]$ExplicitTextArtifact
}
if ($PlanOnly) { $payload | ConvertTo-Json -Depth 6; return }
$sameCurrentSet = $priorNames.Count -eq $resultNames.Count -and @($plans | Where-Object { $priorNames -notcontains $_.name -or -not (Test-Path -LiteralPath $_.target -PathType Leaf) -or (Get-PublishFileHash -LiteralPath $_.source).Hash -ne (Get-PublishFileHash -LiteralPath $_.target).Hash }).Count -eq 0

# Completing a draft is an internal checkpoint, not an additional human approval.
if ($seenJobRoots.Count -ne 1) { throw 'One completed delivery must come from one active job.' }
. (Join-Path $PSScriptRoot 'HumanDeliveryContract.ps1')
$deliveryJobRoot = @($seenJobRoots)[0]
$readyReceipt = Assert-HumanDeliveryReady -JobPath $deliveryJobRoot -SourceFile @($plans | ForEach-Object source) -TargetRelativePath @($plans | ForEach-Object name) -Stage $Stage -DeliveryConfigPath $resolvedConfigPath
$deliveryCycleId = [string]$readyReceipt.deliveryCycleId
foreach ($plan in $plans) {
    $record = @($readyReceipt.files | Where-Object { $_.sourcePath -ieq $plan.source -and $_.targetRelativePath -ceq $plan.name })
    if ($record.Count -ne 1) { throw 'Completion record does not identify one publication source.' }
    $plan['completedSha256'] = [string]$record[0].sha256
}
$publishedCycle = @($prePublishWorkMetadata.publishedDeliveries | Where-Object { $_.cycleId -eq $deliveryCycleId })
if (-not $sameCurrentSet -and $publishedCycle.Count -gt 0) {
    throw 'This request already published its completed result. Keep intermediate revisions in WIP; intake a new actual user request before changing the human result again.'
}
$payload['deliveryCycleId'] = $deliveryCycleId
$payload['completionReceipt'] = Join-Path $deliveryJobRoot 'wip/receipts/human-delivery-ready.json'
if ($sameCurrentSet -and $publishedCycle.Count -gt 0 -and $priorState -eq $Stage -and -not $UpdateConsole) {
    $payload['reusedCurrentFiles']=$true; $payload['archivedFiles']=@(); $payload['archivedSnapshot']=$null
    $payload['idempotentRetry']=$true; $payload['elapsedSeconds']=[Math]::Round($publishWatch.Elapsed.TotalSeconds,3)
    Write-JsonAtomic (Join-Path $deliveryJobRoot 'wip/receipts/work-publish-retry.json') $payload
    Write-PublishResponse $payload (Join-Path $deliveryJobRoot 'wip/receipts/work-publish-retry.json')
    return
}

foreach ($name in $affectedPriorNames) {
    $priorPath = Join-Path $workRoot $name
    if (Test-Path -LiteralPath $priorPath -PathType Leaf) {
        try { $stream=[IO.File]::Open($priorPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $stream.Dispose() }
        catch { throw "Close the current file in its application before publishing a replacement: $priorPath" }
    }
}

$stagingRoot = Join-Path $metadataRoot ('publish-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'HumanRevisionStorage.ps1')
$archivedSnapshot = $null
$archiveMappings = [Collections.Generic.List[object]]::new()
$publishedTargets = [Collections.Generic.List[string]]::new()
$oldWorkMetadata = Get-Content -Raw -Encoding utf8 -LiteralPath $workMetadataPath
try {
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    foreach ($plan in @($plans | Where-Object { -not $_.unchangedCurrent })) {
        $stageTarget = Join-Path $stagingRoot $plan.name
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($stageTarget)) -Force | Out-Null
        Copy-Item -LiteralPath $plan.source -Destination $stageTarget
        if ((Get-PublishFileHash -LiteralPath $stageTarget).Hash -ine $plan.completedSha256) { throw 'WIP source changed while staging completed publication.' }
    }

    $existingPrior = @($affectedPriorNames | Where-Object { Test-Path -LiteralPath (Join-Path $workRoot $_) -PathType Leaf })
    if ($existingPrior.Count -gt 0 -and -not $sameCurrentSet) {
        $archivedSnapshot = Join-Path $metadataRoot 'revisions'
        foreach ($name in $existingPrior) {
            $priorPath = Join-Path $workRoot $name
            if ($PSCmdlet.ShouldProcess($priorPath,"Preserve previous current file in $archivedSnapshot")) {
                $mapping = Save-HumanRevisionObject -WorkRoot $workRoot -MetadataRoot $metadataRoot -CurrentPath $priorPath -RevisionOf $name
                $archiveMappings.Add($mapping)
                $approvedCurrent = @($humanBaseChecks | Where-Object { $_.path -ieq $priorPath })
                if ($approvedCurrent.Count -ne 1 -or $approvedCurrent[0].sha256 -ine $mapping.sha256) { throw 'Current human file changed after publication preflight.' }
                if ((Get-PublishFileHash -LiteralPath $priorPath).Hash -ine $mapping.sha256) { throw "Current file changed during revision preservation: $priorPath" }
                [void](Assert-WorkStoragePath $priorPath)
                Remove-Item -LiteralPath $priorPath -Force
                $mapping.currentRemoved = $true
            }
        }
    }

    foreach ($plan in $plans) {
        $staged = Join-Path $stagingRoot $plan.name
        if (-not $plan.unchangedCurrent -and $PSCmdlet.ShouldProcess($plan.target,'Publish directly in the selected work folder')) {
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName([string]$plan.target)) -Force | Out-Null
            Move-Item -LiteralPath $staged -Destination $plan.target
            $publishedTargets.Add($plan.target)
        }
    }

    $now = Get-Date -Format 'o'
    $workMetadata = $oldWorkMetadata | ConvertFrom-Json | ConvertTo-HashtableDeep
    $workMetadata['status'] = if ($Stage -eq 'Review') { '검토 대기' } else { '완료' }
    $workMetadata['stage'] = $Stage
    $workMetadata['publishedAt'] = $now
    $workMetadata['publishedDeliveries'] = @($workMetadata.publishedDeliveries | Where-Object { $_ }) + @([ordered]@{cycleId=$deliveryCycleId;publishedAt=$now;stage=$Stage;changed=(-not $sameCurrentSet);files=@($resultNames)})
    $workMetadata['currentFiles'] = @($resultNames)
    $workMetadata['revisionHistory'] = @($workMetadata.revisionHistory | Where-Object { $_ }) + @($archiveMappings | ForEach-Object { [ordered]@{relativePath=$_.relativePath;revisionOf=$_.revisionOf;sha256=$_.sha256;archivedAt=$now;storage=$_.storage} })
    $currentFileRecords = @($plans | ForEach-Object {
        $publishedPath = Join-Path $workRoot $_.name
        [ordered]@{ name=$_.name; path=$publishedPath; sha256=(Get-PublishFileHash -LiteralPath $publishedPath -Algorithm SHA256).Hash; recordedAt=$now }
    })
    # Retain historical hash timestamps; do not claim locked, untouched files were reverified.
    $currentFileRecords += @($prePublishWorkMetadata.currentFileRecords | Where-Object { $_.name -in $retainedNames })
    $workMetadata['currentFileRecords'] = @($currentFileRecords)
    $workMetadata['nextAction'] = if ($Stage -eq 'Review') { '사용자 검토 의견 확인' } else { '없음' }
    $question = if ($Stage -eq 'Review') {
        if ([string]::IsNullOrWhiteSpace($ReviewQuestion)) { '문서를 확인하고 수정할 내용이 있으면 Codex 작업에 알려 주세요.' } else { $ReviewQuestion.Trim() }
    } else { '' }
    $workMetadata['review'] = [ordered]@{ state=$(if($Stage -eq 'Review'){'pending'}else{'none'}); question=$question }
    if (-not $workMetadata.Contains('history')) { $workMetadata['history'] = @() }
    $workMetadata['history'] = @($workMetadata.history) + @([ordered]@{ at=$now; event='publish'; stage=$Stage; files=@($plans | ForEach-Object name) })
    $newEntry = [ordered]@{
        title=$safeTitle; createdDate=$CreatedDate; folderName=$WorkFolderName
        workState=$(if($Stage -eq 'Review'){'ReviewPending'}else{'Complete'})
        firstIntakeAt=$currentEntry[0].firstIntakeAt; lastIntakeAt=$currentEntry[0].lastIntakeAt
        stage=$Stage; publishedAt=$now; files=@($resultNames)
        currentFileRecords=@($currentFileRecords)
        metadataFolder=[string]$config.metadataFolderName; console=$(if($UpdateConsole){[string]$config.consoleFileName}elseif($currentEntry[0].console){$currentEntry[0].console}else{$null})
        supportFolders=@($workMetadata.layout.supportFolders); layoutReference=$workMetadata.layout.referenceFolder
    }
    Set-WorkRegistration -Metadata $workMetadata -Entry $newEntry
    Write-JsonAtomic $workMetadataPath $workMetadata

    $consoleReceipt = $null
    if ($UpdateConsole) {
        $consoleJson = & (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -WorkFolder $workRoot
        $consoleReceipt = ($consoleJson -join [Environment]::NewLine) | ConvertFrom-Json
    }
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
} catch {
    $publishFailure = $_
    foreach ($published in $publishedTargets) { if (Test-Path -LiteralPath $published -PathType Leaf) { Remove-Item -LiteralPath $published -Force -ErrorAction SilentlyContinue } }
    $recoveryFailures = @(Restore-HumanRevisionObjects -Mappings @($archiveMappings))
    Set-Content -LiteralPath $workMetadataPath -Value $oldWorkMetadata -Encoding utf8 -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($UpdateConsole) { try { & (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -WorkFolder $workRoot | Out-Null } catch {} }
    if ($recoveryFailures.Count -gt 0) { throw "Publication failed: $($publishFailure.Exception.Message). Recovery objects retained; current-file recovery failed: $($recoveryFailures -join '; ')" }
    throw $publishFailure
}

$payload.archivedSnapshot = $archivedSnapshot
$payload['archivedFiles'] = @($archiveMappings)
$payload['reviewQuestion'] = $(if($Stage -eq 'Review'){$question}else{$null})
$payload['console'] = $consoleReceipt
$payload['elapsedSeconds'] = [Math]::Round($publishWatch.Elapsed.TotalSeconds,3)
$payload['reusedCurrentFiles'] = $sameCurrentSet
foreach ($jobRoot in @($seenJobRoots)) { Write-JsonAtomic (Join-Path $jobRoot 'wip/receipts/work-publish.json') $payload }
Write-PublishResponse $payload (Join-Path $deliveryJobRoot 'wip/receipts/work-publish.json')
