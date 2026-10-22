# One-call draft delivery. ChecksCompleted attests checks the caller actually ran;
# this wrapper does not perform or invent content/integrity checks.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$JobPath,
    [Parameter(Mandatory=$true)][string[]]$SourceFile,
    [Parameter(Mandatory=$true)][string[]]$TargetRelativePath,
    [Parameter(Mandatory=$true)][string[]]$ChecksCompleted,
    [string[]]$CheckReceiptFile=@(),
    [string[]]$FormBaseFile=@(),
    [string]$FormContractPath='',
    [string]$NormalizationReceiptPath='',
    [string]$NativeMergeReceiptPath='',
    [string]$SubjectReplacementReceiptPath='',
    [switch]$FormGateNotApplicable,
    [string]$FormGateReason='',
    [switch]$PartialUpdate,
    [switch]$ExplicitTextArtifact,
    [string]$ReviewQuestion='',
    [string]$DeliveryConfigPath='',
    [string]$RegistryPath='',
    [switch]$PlanOnly
)
$ErrorActionPreference='Stop'
# Keep the publication API's isolated-preview restriction. In particular, do not
# write a ready receipt before rejecting an invalid override.
if (($DeliveryConfigPath -or $RegistryPath) -and -not $PlanOnly) {
    throw 'DeliveryConfigPath and RegistryPath overrides are allowed only with PlanOnly for isolated verification.'
}
. (Join-Path $PSScriptRoot 'HumanDeliveryContract.ps1')
Assert-HumanDeliveryChecks $ChecksCompleted
$context=Get-HumanDeliveryContext -JobPath $JobPath -DeliveryConfigPath $DeliveryConfigPath
Assert-HumanDeliveryStage -Context $context -Stage Review
$metadata=Get-Content -LiteralPath (Join-Path $context.workRoot '.ai/work.json') -Raw -Encoding utf8 | ConvertFrom-Json
$workName=[IO.Path]::GetFileName($context.workRoot.TrimEnd('\'))
if ([string]::IsNullOrWhiteSpace([string]$metadata.title) -or
    ($metadata.folderName -and [string]$metadata.folderName -ine $workName)) {
    throw 'Work title or folder identity is missing or inconsistent.'
}
# Reject cheap, deterministic input errors before completion reserves output
# numbers. Do not undo allocations: another publisher may already depend on them.
if (-not $SourceFile.Count -or $SourceFile.Count -ne $TargetRelativePath.Count) {
    throw 'Completion requires one explicit target relative path per source file.'
}
$existingNames=@($metadata.currentFiles)
$currentRoot=Get-WorkCurrentRoot $context.workRoot
$nameMap=Join-Path $currentRoot '.ai/output-names.json'
$mappedNames=@()
if (Test-Path -LiteralPath $nameMap -PathType Leaf) {
    $mappedNames=@(Get-Content $nameMap -Raw -Encoding utf8 | ConvertFrom-Json | Where-Object workRoot -IEQ $context.workRoot)
}
for ($i=0; $i -lt $SourceFile.Count; $i++) {
    $name=$TargetRelativePath[$i]
    [void](Get-WorkCurrentTarget -WorkRoot $context.workRoot -RelativePath $name)
    if ([IO.Path]::GetExtension($name) -ine [IO.Path]::GetExtension($SourceFile[$i])) {
        throw 'TargetRelativePath must preserve the source extension.'
    }
    $registered=$name -in $existingNames -or @($mappedNames | Where-Object {
        ($_.requested -ieq $name -or $_.name -ieq $name) -and $_.name -in $existingNames
    }).Count -gt 0
    if (-not $registered -and $name -match '(^\d{8}[_-]|\(안\)|초안|검토용|draft|final|v\d+)') {
        throw "Human-facing filename contains a date/draft/version marker: $name"
    }
}
$hanword=@($SourceFile | Where-Object { [IO.Path]::GetExtension($_).ToLowerInvariant() -in @('.hwpx','.hwp') })
if ($hanword.Count -gt 0 -and -not $NativeMergeReceiptPath -and -not $SubjectReplacementReceiptPath -and -not $FormGateNotApplicable) {
    $canonical=Join-Path $context.jobPath 'wip/receipts/hwpx-form-contract.json'
    if (-not $FormContractPath -or [IO.Path]::GetFullPath($FormContractPath) -ine $canonical -or
        -not (Test-Path -LiteralPath $FormContractPath -PathType Leaf)) {
        throw 'HWPX publish requires FormContractPath at wip/receipts/hwpx-form-contract.json.'
    }
    $contract=Get-Content $FormContractPath -Raw -Encoding utf8 | ConvertFrom-Json
    $inputs=Get-Content (Join-Path $context.jobPath 'inputs.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $roles=if ($contract.structure_authority_kind -eq 'current_human_revision') { @('form','human_revision') } else { @('form') }
    foreach ($form in @($contract.authoritative_form)) {
        if (@($inputs.sources | Where-Object { $_.role -in $roles -and $_.path -ieq $form.path -and $_.sha256 -ieq $form.sha256 }).Count -eq 0) {
            throw 'Authoritative form is not registered with the same hash in inputs.json.'
        }
    }
    if ($contract.form_status -eq 'existing') {
        if ($FormBaseFile.Count -ne @($contract.authoritative_form).Count -or -not $FormBaseFile.Count) {
            throw 'FormBaseFile must cover every authoritative form, in contract order.'
        }
        $docsPrefix=(Join-Path $context.jobPath 'wip/docs').TrimEnd('\')+'\'
        foreach ($base in $FormBaseFile) {
            $resolved=Assert-WorkStoragePath $base
            if (-not $resolved.StartsWith($docsPrefix,[StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw 'FormBaseFile must stay inside the active job wip/docs tree.' }
        }
    }
}
$publish=@{
    Stage='Review'; TaskTitle=[string]$metadata.title; WorkFolderName=$workName
    SourceFile=$SourceFile; TargetRelativePath=$TargetRelativePath; Summary=$true
}
foreach ($key in @('FormBaseFile','FormContractPath','NormalizationReceiptPath','NativeMergeReceiptPath',
    'SubjectReplacementReceiptPath','FormGateNotApplicable','FormGateReason','PartialUpdate',
    'ExplicitTextArtifact','ReviewQuestion','DeliveryConfigPath','RegistryPath','PlanOnly')) {
    if ($PSBoundParameters.ContainsKey($key)) { $publish[$key]=$PSBoundParameters[$key] }
}
if (-not $PlanOnly) {
    & (Join-Path $PSScriptRoot 'Complete-HumanDraft.ps1') -JobPath $context.jobPath `
        -SourceFile $SourceFile -TargetRelativePath $TargetRelativePath -Stage Review `
        -ChecksCompleted $ChecksCompleted -CheckReceiptFile $CheckReceiptFile | Out-Null
}
# The original publication path revalidates scope, basis, file hashes, form,
# content requirements, human revisions and current delivery-cycle identity.
& (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publish
