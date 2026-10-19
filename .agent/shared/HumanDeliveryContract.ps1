# Completion evidence for the normal publication route; not human authentication.
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
. (Join-Path $PSScriptRoot 'DocumentScope.ps1')
. (Join-Path $PSScriptRoot 'DocumentBasis.ps1')

function Get-HumanDeliveryContext {
    param([string]$JobPath, [string]$DeliveryConfigPath='')
    $workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $info = Get-WorkJobInfo -Workspace $workspace -Path $JobPath -RequireJobRoot -RequireExists -DeliveryConfigPath $DeliveryConfigPath
    $inputs = Get-Content -LiteralPath (Join-Path $info.jobRoot 'inputs.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $work = Get-Content -LiteralPath (Join-Path $info.workRoot '.ai\work.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $cycle = $inputs.deliveryCycle
    if (-not $cycle -or $cycle.schemaVersion -ne 'human-delivery-cycle/v1' -or -not $cycle.id -or -not $cycle.requestKey -or [string]::IsNullOrWhiteSpace([string]$cycle.requestText) -or -not $cycle.startedAt) {
        throw 'Publication requires a current delivery cycle. Run Start-HwpxWork intake for this user request; legacy jobs cannot declare completion directly.'
    }
    if (-not $inputs.delivery.workRoot -or [IO.Path]::GetFullPath([string]$inputs.delivery.workRoot).TrimEnd('\') -ine $info.workRoot) { throw 'Delivery cycle work binding disagrees with storage.' }
    if (-not $work.deliveryCycle -or ($cycle | ConvertTo-Json -Depth 12 -Compress) -cne ($work.deliveryCycle | ConvertTo-Json -Depth 12 -Compress)) {
        throw 'Delivery cycle is stale or disagrees between job and current work. Intake the current user request.'
    }
    $basis = Assert-WorkDocumentBasis -Inputs $inputs -WorkRoot $info.workRoot
    $scope = Get-ActiveDocumentScope $info.jobRoot
    [pscustomobject]@{jobPath=$info.jobRoot;workRoot=$info.workRoot;cycle=$cycle;scope=$scope;basis=$basis}
}

function Get-HumanDeliveryFiles {
    param($Context, [string[]]$SourceFile, [string[]]$TargetRelativePath)
    if (-not $SourceFile -or $SourceFile.Count -eq 0 -or $SourceFile.Count -ne $TargetRelativePath.Count) { throw 'Completion requires one explicit target relative path per source file.' }
    $sourceRoots = @('wip\docs','wip\carry') | ForEach-Object { Assert-WorkStoragePath (Join-Path $Context.jobPath $_) }
    $targets = @{}
    foreach ($i in 0..($SourceFile.Count-1)) {
        if ([string]::IsNullOrWhiteSpace($SourceFile[$i])) { throw 'Completion source path cannot be empty.' }
        $source = Assert-WorkStoragePath $SourceFile[$i]
        $withinWip = @($sourceRoots | Where-Object { $source.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $withinWip -or -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Completion source must be a file in this job's wip/docs or wip/carry: $source"
        }
        $target = Get-WorkCurrentTarget -WorkRoot $Context.workRoot -RelativePath $TargetRelativePath[$i]
        $relative = $target.Substring($Context.workRoot.TrimEnd('\').Length + 1)
        if ($relative -match '(?i)_fix\d+(?:_|\.|$)') { throw 'Completion cannot target a fix/recovery version.' }
        if ($targets.ContainsKey($relative)) { throw "Duplicate completion target: $relative" }
        $targets[$relative] = $true
        [pscustomobject]@{sourcePath=$source;targetRelativePath=$relative;sha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash}
    }
}

function Get-HumanDeliveryScopeSnapshot($Scope) {
    if (-not $Scope) { return $null }
    [ordered]@{id=[string]$Scope.id;formatEditAllowed=[bool]$Scope.formatEditAllowed;visualReviewAllowed=[bool]$Scope.visualReviewAllowed}
}

function Assert-HumanDeliveryChecks([string[]]$ChecksCompleted) {
    if ('content' -notin $ChecksCompleted -or 'integrity' -notin $ChecksCompleted) { throw "Completion requires explicit ChecksCompleted labels 'content' and 'integrity'." }
    if (@($ChecksCompleted | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'Completion check labels cannot be empty.' }
}

function Assert-HumanDeliveryReady {
    param([string]$JobPath, [string[]]$SourceFile, [string[]]$TargetRelativePath, [ValidateSet('Review','Final')][string]$Stage, [string]$DeliveryConfigPath='')
    $context = Get-HumanDeliveryContext -JobPath $JobPath -DeliveryConfigPath $DeliveryConfigPath
    $files = @(Get-HumanDeliveryFiles -Context $context -SourceFile $SourceFile -TargetRelativePath $TargetRelativePath)
    $receiptPath = Assert-WorkStoragePath (Join-Path $context.jobPath 'wip\receipts\human-delivery-ready.json')
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw 'Publication requires Complete-HumanDraft for the finished WIP files.' }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($receipt.schemaVersion -ne 'human-delivery-ready/v1' -or $receipt.jobPath -ine $context.jobPath -or $receipt.stage -cne $Stage) { throw 'Completion receipt job, schema or stage does not match publication.' }
    if ($receipt.deliveryCycleId -cne [string]$context.cycle.id -or $receipt.requestKey -cne [string]$context.cycle.requestKey -or $receipt.requestTextSha256 -ine (Get-DocumentScopeTextHash ([string]$context.cycle.requestText))) { throw 'Completion receipt belongs to another user request.' }
    if (($receipt.documentBasis | ConvertTo-Json -Depth 8 -Compress) -cne ($context.basis | ConvertTo-Json -Depth 8 -Compress)) { throw 'Selected draft/form changed after completion; recheck before publication.' }
    $scope = Get-HumanDeliveryScopeSnapshot $context.scope
    if (($receipt.documentScope | ConvertTo-Json -Depth 5 -Compress) -cne ($scope | ConvertTo-Json -Depth 5 -Compress)) { throw 'Document scope changed after completion; recheck the WIP result.' }
    Assert-HumanDeliveryChecks @($receipt.checksCompleted)
    if (@($receipt.files).Count -ne $files.Count) { throw 'Completion receipt file set changed.' }
    foreach ($i in 0..($files.Count-1)) {
        $record = @($receipt.files)[$i]
        if ($record.sourcePath -ine $files[$i].sourcePath -or $record.targetRelativePath -cne $files[$i].targetRelativePath -or $record.sha256 -ine $files[$i].sha256) { throw 'Publication files or their content changed after completion.' }
    }
    foreach ($check in @($receipt.checkReceipts)) {
        $path = Assert-WorkStoragePath ([string]$check.path)
        if (-not $path.StartsWith((Join-Path $context.jobPath 'wip\receipts') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Completion check receipts must stay in this job receipts tree.' }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $check.sha256) { throw 'A completion check receipt changed or is missing.' }
    }
    $receipt
}
