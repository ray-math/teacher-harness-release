[CmdletBinding()]
param([string]$ReceiptPath='')
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) {throw 'Run with Windows PowerShell 5.1.'}
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('human-delivery-flow-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Name) {if (-not $Condition) {throw "FAIL: $Name"};$checks.Add($Name)}
function Json($Value) {($Value -join [Environment]::NewLine)|ConvertFrom-Json}
function Reject([scriptblock]$Action,[string]$Pattern,[string]$Name) {
    $caught=$false
    try {& $Action | Out-Null} catch {if ($_.Exception.Message -notmatch $Pattern) {throw};$caught=$true}
    Check $caught $Name
}
try {
    $shared=Join-Path $fixture '.agent\shared';$index=Join-Path $fixture '.agent\index';$cabinet=Join-Path $fixture 'cabinet'
    New-Item -ItemType Directory -Path $shared,$index,$cabinet -Force | Out-Null
    foreach ($name in @('WorkStorage.ps1','WorkRegistry.ps1','DocumentScope.ps1','HumanDeliveryContract.ps1','HumanRevisionStorage.ps1','Complete-HumanDraft.ps1','DocumentBasis.ps1','Resolve-TeacherHarnessConfig.ps1','Receive-TeacherHarnessInputs.ps1','Start-HwpxWork.ps1','New-HwpxJob.ps1','Publish-HumanResult.ps1','Sync-HumanSourcePreservation.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared
    }
    $config=Get-Content -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $baseline=Join-Path $fixture 'existing-form.csv'
    [IO.File]::WriteAllText($baseline,"name,value`r`n,",[Text.UTF8Encoding]::new($true))
    $config | Add-Member outputLayout 'work' -Force
    $config | Add-Member receiveInputs $true -Force
    $config.incomingRoot=Join-Path $fixture 'incoming';$config.humanCabinet=$cabinet
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $index 'delivery-system.json') -Encoding utf8
    $start=Join-Path $shared 'Start-HwpxWork.ps1';$publish=Join-Path $shared 'Publish-HumanResult.ps1';$complete=Join-Path $shared 'Complete-HumanDraft.ps1'
    $intakeOutput=(& $start -Mode New -FormFile $baseline -TaskTitle 'Delivery flow fixture' -WorkFolderName '23_Delivery flow fixture' -JobSlug 'delivery-flow' -IntakeSummary 'Create one CSV result' -DecisionReason 'Synthetic user request' -RequestText 'Create one CSV result' -RequestId 'request-one' -Summary)
    $intake=Json $intakeOutput
    $job=$intake.jobPath;$work=$intake.workRoot;$draft=Join-Path $job 'wip\docs\result.csv';$current=Join-Path $work 'result.csv';$metadata=Join-Path $work '.ai\work.json'
    $intakeEvidence=Get-Content -LiteralPath $intake.receiptPath -Raw -Encoding utf8
    $fullIntake=Json $intakeEvidence
    Check ($intake.schemaVersion -eq 'hwpx-work-intake.summary/v1' -and $fullIntake.jobPath -ceq $intake.jobPath -and $fullIntake.sourcePreservation) 'summary intake preserves complete evidence and required paths'
    $intakeSummaryBytes=[Text.Encoding]::UTF8.GetByteCount(($intakeOutput -join [Environment]::NewLine))
    $intakeFullBytes=[Text.Encoding]::UTF8.GetByteCount($intakeEvidence)
    Check ($intakeSummaryBytes -lt $intakeFullBytes) 'summary intake output is smaller than full evidence'
    $pub=@{Stage='Final';TaskTitle='Delivery flow fixture';WorkFolderName=$intake.workFolderName;SourceFile=@($draft);TargetRelativePath=@('result.csv')}
    function Ready {& $complete -JobPath $job -SourceFile $draft -TargetRelativePath 'result.csv' -Stage Final -ChecksCompleted @('content','integrity') | Out-Null}
    function Follow([string]$Id,[string]$Text) {
        Json (& $start -Mode FollowUp -TaskTitle 'Delivery flow fixture' -WorkFolderName $intake.workFolderName -JobPath $job -IntakeSummary $Text -DecisionReason 'Synthetic follow-up' -RequestText $Text -RequestId $Id)
    }
    function HistoryCount {@((Get-Content -LiteralPath $metadata -Raw -Encoding utf8 | ConvertFrom-Json).publishedDeliveries).Count}
    [IO.File]::WriteAllText($draft,'A')
    Reject {& $publish @pub} 'Complete-HumanDraft|completion' 'unfinished WIP cannot publish'
    Check (-not (Test-Path -LiteralPath $current)) 'denied unfinished publish creates no human file'
    Ready
    [IO.File]::WriteAllText($draft,'changed after ready')
    Reject {& $publish @pub} 'changed after completion' 'completion binds exact output hash'
    [IO.File]::WriteAllText($draft,'A');Ready
    $publishOutput=(& $publish @pub -Summary)
    $publishSummary=Json $publishOutput
    $publishEvidence=Get-Content -LiteralPath $publishSummary.receiptPath -Raw -Encoding utf8
    $one=Json $publishEvidence
    Check ($publishSummary.status -eq 'published' -and $publishSummary.files[0] -ceq $current -and $one.completionReceipt) 'summary publication preserves complete evidence and result path'
    $publishSummaryBytes=[Text.Encoding]::UTF8.GetByteCount(($publishOutput -join [Environment]::NewLine))
    $publishFullBytes=[Text.Encoding]::UTF8.GetByteCount($publishEvidence)
    Check ($publishSummaryBytes -lt $publishFullBytes) 'summary publication output is smaller than full evidence'
    Check (([IO.File]::ReadAllText($current) -ceq 'A') -and (HistoryCount) -eq 1) 'completed result publishes once'
    $publicMetadataHash=(Get-FileHash -LiteralPath $metadata).Hash
    $retry=Json (& $publish @pub)
    Check ($retry.idempotentRetry -and $retry.archivedFiles.Count -eq 0 -and (HistoryCount) -eq 1) 'same-result retry adds no publication or revision'
    Check ((Get-FileHash -LiteralPath $metadata).Hash -ceq $publicMetadataHash) 'same-result retry leaves public metadata byte-identical'
    $repeat=Follow 'request-one' 'Create one CSV result'
    $repeatCycle=(Get-Content -LiteralPath (Join-Path $job 'inputs.json') -Raw -Encoding utf8|ConvertFrom-Json).deliveryCycle.id
    Check ($repeatCycle -ceq $one.deliveryCycleId) 'retry intake with same request ID reuses cycle'
    [IO.File]::WriteAllText($draft,'B');Ready
    Reject {& $publish @pub} 'already published its completed result' 'second changed publication in same request is blocked'
    Check ([IO.File]::ReadAllText($current) -ceq 'A') 'denied extra publish preserves current result'
    $follow=Follow 'request-two' 'Change result to B';Ready
    $two=Json (& $publish @pub)
    Check ($two.archivedFiles.Count -eq 1 -and $two.archivedFiles[0].createdObject -and [IO.File]::ReadAllText($two.archivedFiles[0].archive) -ceq 'A') 'new user request publishes B and preserves A'
    $follow=Follow 'request-three' 'Change result to A';[IO.File]::WriteAllText($draft,'A');Ready
    $three=Json (& $publish @pub)
    Check ($three.archivedFiles[0].createdObject -and [IO.File]::ReadAllText($three.archivedFiles[0].archive) -ceq 'B') 'return to A preserves B content object'
    $follow=Follow 'request-four' 'Change result to B again';[IO.File]::WriteAllText($draft,'B');Ready
    $four=Json (& $publish @pub)
    Check (-not $four.archivedFiles[0].createdObject -and $four.archivedFiles[0].archive -ieq $two.archivedFiles[0].archive) 'A to B to A to B reuses existing A object'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $work '.ai\revisions') -File).Count -eq 2) 'repeated content produces exactly two revision objects'
    Check (@(Get-ChildItem -LiteralPath $work -File -Recurse | Where-Object {$_.FullName -notlike '*\.ai\*' -and $_.Name -match '_fix\d+'}).Count -eq 0) 'machine revisions create no visible fix files'
    $follow=Follow 'request-five' 'Update result after review';[IO.File]::WriteAllText($draft,'C');Ready
    [IO.File]::WriteAllText($current,'Human saved revision')
    Reject {& $publish @pub} 'exact hash as human_revision' 'human edit after intake cannot be overwritten'
    Check ([IO.File]::ReadAllText($current) -ceq 'Human saved revision') 'rejected publish preserves exact human edit'
    $follow=Follow 'request-five' 'Update result after review';Ready
    $five=Json (& $publish @pub)
    Check ([IO.File]::ReadAllText($five.archivedFiles[0].archive) -ceq 'Human saved revision') 'saved human revision is preserved after renewed intake'
    Check ((HistoryCount) -eq 5 -and [IO.File]::ReadAllText($current) -ceq 'C') 'five actual requests produce five completed publications'
    $scope=(Get-Content -LiteralPath (Join-Path $job 'inputs.json') -Raw -Encoding utf8|ConvertFrom-Json).documentScope
    Check (-not $scope.formatEditAllowed -and -not $scope.visualReviewAllowed) 'new content request has no implicit format or visual permission'
    $format=Json (& $start -Mode FollowUp -TaskTitle 'Delivery flow fixture' -WorkFolderName $intake.workFolderName -JobPath $job -IntakeSummary '서식을 수정해줘' -DecisionReason 'Synthetic explicit formatting request' -RequestText '서식을 수정해줘' -RequestId 'request-format' -FinalPolishAuthorized -FormattingRequestText '서식을 수정해줘')
    $scope=(Get-Content -LiteralPath (Join-Path $job 'inputs.json') -Raw -Encoding utf8|ConvertFrom-Json).documentScope
    Check ($scope.formatEditAllowed -and -not $scope.visualReviewAllowed) 'explicit formatting request grants only format permission'
    $formatRetry=Follow 'request-format' '서식을 수정해줘'
    $scope=(Get-Content -LiteralPath (Join-Path $job 'inputs.json') -Raw -Encoding utf8|ConvertFrom-Json).documentScope
    Check $scope.formatEditAllowed 'same formatting request retry retains its explicit permission'
    Ready
    $publicMetadataHash=(Get-FileHash -LiteralPath $metadata).Hash
    Reject {Follow 'request-format' '다른 요청으로 바꿔줘'} 'RequestId cannot be reused with changed request text' 'same request ID cannot be reused for different request text'
    Check ((Get-FileHash -LiteralPath $metadata).Hash -ceq $publicMetadataHash) 'rejected request ID reuse leaves metadata unchanged'
    $content=Follow 'request-content' '내용을 수정해줘'
    $scope=(Get-Content -LiteralPath (Join-Path $job 'inputs.json') -Raw -Encoding utf8|ConvertFrom-Json).documentScope
    Check (-not $scope.formatEditAllowed -and -not $scope.visualReviewAllowed) 'new content request does not inherit previous formatting permission'
    Reject {& $publish @pub} 'another user request|scope changed after completion' 'completion from previous formatting request cannot publish in new content request'
    [IO.File]::WriteAllText($draft,'D')
    $externalCheck=Join-Path $fixture 'outside-check.json'
    [IO.File]::WriteAllText($externalCheck,'{"ok":true}')
    Reject {& $complete -JobPath $job -SourceFile $draft -TargetRelativePath 'result.csv' -Stage Final -ChecksCompleted @('content','integrity') -CheckReceiptFile $externalCheck} 'check receipts must stay in this job receipts tree' 'completion rejects a check receipt outside the active job receipts tree'
    $internalCheck=Join-Path $job 'wip\receipts\content-check.json'
    [IO.File]::WriteAllText($internalCheck,'{"ok":true}')
    $ready=Json (& $complete -JobPath $job -SourceFile $draft -TargetRelativePath 'result.csv' -Stage Final -ChecksCompleted @('content','integrity') -CheckReceiptFile $internalCheck)
    [IO.File]::WriteAllText($internalCheck,'{"ok":false,"changed":true}')
    Reject {& $publish @pub} 'completion check receipt changed or is missing' 'publication rejects a check receipt changed after completion'
    Check ([IO.File]::ReadAllText($current) -ceq 'C') 'changed check receipt rejection leaves human result unchanged'
    [IO.File]::WriteAllText($internalCheck,'{"ok":true}')
    $ready=Json (& $complete -JobPath $job -SourceFile $draft -TargetRelativePath 'result.csv' -Stage Final -ChecksCompleted @('content','integrity') -CheckReceiptFile $internalCheck)
    $six=Json (& $publish @pub)
    Check ($ready.status -eq 'ready' -and $six.deliveryCycleId -ceq $ready.deliveryCycleId -and [IO.File]::ReadAllText($current) -ceq 'D') 'internal immutable check receipt permits completion and publication'
    $noChange=Follow 'request-no-change' 'Keep the completed result as D';Ready
    $unchanged=Json (& $publish @pub)
    Check ($unchanged.reusedCurrentFiles -and $unchanged.archivedFiles.Count -eq 0) 'new request can complete a byte-identical result without a revision object'
    [IO.File]::WriteAllText($draft,'E');Ready
    Reject {& $publish @pub} 'already published its completed result' 'a request completed without changes cannot publish a later changed result'
    Check ([IO.File]::ReadAllText($current) -ceq 'D') 'denied change after unchanged completion preserves human result'
    [IO.File]::WriteAllText($draft,'D');Ready
    $metadataBeforeSummary=(Get-FileHash -LiteralPath $metadata).Hash
    $summaryRetry=Json (& $publish @pub -Summary)
    Check ($summaryRetry.idempotentRetry -and $summaryRetry.receiptPath -like '*work-publish-retry.json' -and (Get-FileHash -LiteralPath $metadata).Hash -ceq $metadataBeforeSummary) 'summary retry does not mutate public metadata'
    $summaryFollow=@{Mode='FollowUp';TaskTitle='Delivery flow fixture';WorkFolderName=$intake.workFolderName;JobPath=$job;IntakeSummary='Keep the completed result as D';DecisionReason='Synthetic follow-up';RequestText='Keep the completed result as D';RequestId='request-no-change';Summary=$true}
    $resume=Json (& $start @summaryFollow)
    $resume=Json (& $start @summaryFollow)
    Check ($resume.reused -and $resume.jobPath -ceq $job -and (Test-Path -LiteralPath $resume.receiptPath)) 'summary reused intake retains same job and evidence'
    $draftArgs=@{Mode='New';FormFile=$baseline;TaskTitle='Draft first fixture';JobSlug='draft-first';IntakeSummary='Save a partial draft';DecisionReason='Synthetic draft request';RequestId='draft-one';DraftFirst=$true;Summary=$true}
    Reject {& $start @draftArgs -RequireContentValidation} 'cannot be combined' 'draft-first rejects contradictory strict validation flags'
    $partial=Json (& $start @draftArgs)
    $partialFile=Join-Path $partial.jobPath 'wip\docs\partial.csv'
    Copy-Item -LiteralPath $baseline -Destination $partialFile
    $partialInputs=Get-Content -LiteralPath (Join-Path $partial.jobPath 'inputs.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Check ($partial.draftFirst -and $partialInputs.deliveryCycle.draftFirst -and -not $partialInputs.deliveryCycle.requireContentValidation -and -not $partialInputs.requiredContentProfile) 'draft-first explicitly records Review mode without mandatory profile'
    Reject {& $complete -JobPath $partial.jobPath -SourceFile $partialFile -TargetRelativePath 'partial.csv' -Stage Final -ChecksCompleted @('content','integrity')} 'only be saved at Review' 'draft-first cannot claim Final completion'
    Reject {& $complete -JobPath $partial.jobPath -SourceFile $partialFile -TargetRelativePath 'partial.csv' -Stage Review -ChecksCompleted @('content')} 'integrity' 'draft-first still requires integrity check'
    $ready=Json (& $complete -JobPath $partial.jobPath -SourceFile $partialFile -TargetRelativePath 'partial.csv' -Stage Review -ChecksCompleted @('content','integrity'))
    $partialPub=@{Stage='Review';TaskTitle='Draft first fixture';WorkFolderName=$partial.workFolderName;SourceFile=@($partialFile);TargetRelativePath=@('partial.csv')}
    $partialResult=Json (& $publish @partialPub)
    Check ((Test-Path -LiteralPath (Join-Path $partial.workRoot 'partial.csv')) -and $ready.stage -eq 'Review') 'incomplete draft saves to visible work folder at Review'
    $partialPub.Stage='Final'
    Reject {& $publish @partialPub} 'only be saved at Review' 'publication also rejects draft-first Final stage'
    $followDraft=Json (& $start -Mode FollowUp -TaskTitle 'Draft first fixture' -WorkFolderName $partial.workFolderName -JobPath $partial.jobPath -IntakeSummary 'Fill the missing value' -DecisionReason 'Synthetic follow-up' -RequestId 'draft-two' -DraftFirst -Summary)
    [IO.File]::WriteAllText($partialFile,"name,value`r`nitem,filled")
    & $complete -JobPath $partial.jobPath -SourceFile $partialFile -TargetRelativePath 'partial.csv' -Stage Review -ChecksCompleted @('content','integrity') | Out-Null
    $partialPub.Stage='Review'
    $followDraftResult=Json (& $publish @partialPub)
    Check ($followDraft.jobPath -ceq $partial.jobPath -and $followDraftResult.archivedFiles.Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $partial.workRoot 'partial.csv')).Contains('filled')) 'draft-first follow-up reuses job and preserves previous current draft'
    $strict=Json (& $start -Mode New -FormFile $baseline -TaskTitle 'Strict fixture' -JobSlug 'strict-fixture' -IntakeSummary 'Strict validation' -DecisionReason 'Synthetic strict request' -RequireContentValidation -Summary)
    Reject {& $start -Mode FollowUp -FormFile $baseline -TaskTitle 'Strict fixture' -WorkFolderName $strict.workFolderName -JobPath $strict.jobPath -IntakeSummary 'Save draft instead' -RequestId 'strict-new' -DecisionReason 'Synthetic request' -DraftFirst} 'cannot weaken' 'draft-first cannot remove existing strict validation even with a new request'
    $strictInputs=Get-Content -LiteralPath (Join-Path $strict.jobPath 'inputs.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Check ([bool]$strictInputs.deliveryCycle.requireContentValidation) 'rejected draft-first leaves strict requirement intact'
    $report=[ordered]@{ok=$true;count=$checks.Count;summaryBytes=@{intake=$intakeSummaryBytes;intakeFull=$intakeFullBytes;publish=$publishSummaryBytes;publishFull=$publishFullBytes};verification='isolated completed publication, retry, content deduplication and human revision preservation';checks=@($checks)}
    if ($ReceiptPath) {$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $ReceiptPath -Encoding utf8}
    $report|ConvertTo-Json -Depth 5
} finally {
    $safe=[IO.Path]::GetFullPath($fixture);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($safe) -ine $tempRoot -or [IO.Path]::GetFileName($safe) -notmatch '^human-delivery-flow-[a-f0-9]{32}$') {throw 'Unsafe fixture cleanup path.'}
    if (Test-Path -LiteralPath $safe) {
        if ((Get-Item -LiteralPath $safe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Fixture root became a reparse point.'}
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
