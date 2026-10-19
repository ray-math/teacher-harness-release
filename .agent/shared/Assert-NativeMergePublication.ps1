[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$JobPath,[Parameter(Mandatory=$true)][string]$SourceFile,[Parameter(Mandatory=$true)][string]$ReceiptPath)
$ErrorActionPreference='Stop'
$job=(Resolve-Path -LiteralPath $JobPath).Path
$receipt=(Resolve-Path -LiteralPath $ReceiptPath).Path
$source=(Resolve-Path -LiteralPath $SourceFile).Path
if(-not $receipt.StartsWith((Join-Path $job 'wip\receipts')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Native receipt must be in the active job'}
if(-not $source.StartsWith((Join-Path $job 'wip\docs')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Publication source must be in job wip/docs'}
$r=Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
if($r.ok -ne $true -or $r.stage -ne 'verified' -or $r.securityModuleRegistered -ne $true){throw 'Native merge not verified'}
if($r.verification.nativeReopen -ne $true -or $r.verification.inputHashesUnchanged -ne $true -or $r.verification.openSafety.upstream.ok -ne $true){throw 'Native reopening and unmodified upstream open-safety must pass'}
$hash=(Get-FileHash -LiteralPath $source).Hash
if($hash -ine $r.outputSha256 -or (Get-FileHash -LiteralPath $r.output).Hash -ine $hash){throw 'Output revision differs from verified native result'}
$planPath=Join-Path $job 'native-plan.json'
if((Get-FileHash -LiteralPath $planPath).Hash -ine $r.manifestSha256){throw 'Merge plan changed after verification'}
$plan=Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($plan.renderPdf) {
    . (Join-Path $PSScriptRoot 'DocumentScope.ps1')
    Assert-DocumentCapability $job 'visual_review' | Out-Null
}
$intake=Get-Content -LiteralPath (Join-Path $job 'inputs.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(@($plan.inputs).Count -lt 2 -or @($plan.inputs).Count -ne @($r.inputs).Count){throw 'Merge input count mismatch'}
if(@($r.insertions).Count -ne @($plan.inputs).Count-1 -or @($r.verification.fullTextInOrder).Count -ne @($plan.inputs).Count){throw 'Incomplete insertion or content checks'}
for($i=0;$i -lt @($plan.inputs).Count;$i++){
    $entry=$plan.inputs[$i];$record=$r.inputs[$i];$check=$r.verification.fullTextInOrder[$i]
    if($entry.path -ine $record.path -or $entry.sha256 -ine $record.sha256 -or $check.index -ne $i -or $check.foundInOrder -ne $true -or $check.characters -le 0){throw 'Input order or content receipt mismatch'}
    if($i -gt 0 -and $r.insertions[$i-1] -ne $i){throw 'Insertion order mismatch'}
    $copy=(Resolve-Path -LiteralPath $entry.path).Path
    if(-not $copy.StartsWith($job+'\',[StringComparison]::OrdinalIgnoreCase) -or (Get-FileHash -LiteralPath $copy).Hash -ine $entry.sha256){throw 'Input copy changed or outside job'}
    if(-not $entry.sourcePath){throw 'Original source association missing'}
    if((Get-FileHash -LiteralPath $entry.sourcePath).Hash -ine $entry.sha256){throw 'Original source changed'}
    $matching=@($intake.sources | Where-Object { $_.path -ieq $entry.sourcePath -and $_.sha256 -ieq $entry.sha256 -and $_.userProvided -eq $true })
    if(-not $matching.Count){throw 'Merge source was not preserved through user intake'}
    if($i -eq 0 -and -not @($matching | Where-Object { $_.role -eq 'human_revision' }).Count){throw 'Base must be the registered current human revision'}
}
& (Join-Path $PSScriptRoot 'Test-HwpxPackageIntegrity.ps1') -Path $source | Out-Null
[ordered]@{schemaVersion='hwpx-publish-form-gate/v1';ok=$true;route='native_whole_document_merge';receipt=$receipt;outputSha256=$hash;inputCount=@($plan.inputs).Count;verificationLevel='native_reopen_full_text_order_and_package';nativeReopen=$true;realHancomVerified=$false;visualReview=$false} | ConvertTo-Json -Depth 6
