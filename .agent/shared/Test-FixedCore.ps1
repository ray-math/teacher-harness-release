[CmdletBinding()]
param([string]$Workspace = '', [string]$ReceiptPath = '')
$ErrorActionPreference='Stop'
if (-not $Workspace) { $Workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$caseRoot=Join-Path ([IO.Path]::GetTempPath()) ('hwpx-fixed-core-' + [guid]::NewGuid().ToString('N'))
try {
$core=Join-Path $caseRoot 'harness'
$cabinet=Join-Path $caseRoot 'cabinet'
$shared=Join-Path $core '.agent\shared'
$index=Join-Path $core '.agent\index'
[void][IO.Directory]::CreateDirectory($shared)
[void][IO.Directory]::CreateDirectory($index)
[void][IO.Directory]::CreateDirectory($cabinet)
$names=@('WorkStorage.ps1','WorkRegistry.ps1','New-HwpxJob.ps1','DocumentScope.ps1','HumanDeliveryContract.ps1','HumanRevisionStorage.ps1','Complete-HumanDraft.ps1','DocumentBasis.ps1','Resolve-TeacherHarnessConfig.ps1','Receive-TeacherHarnessInputs.ps1','Start-HwpxWork.ps1','Sync-HumanSourcePreservation.ps1','Publish-HumanResult.ps1','Resolve-HwpxJobStorage.ps1','work_storage.py')
foreach($name in $names){Copy-Item -LiteralPath (Join-Path $Workspace ('.agent\shared\'+$name)) -Destination (Join-Path $shared $name)}
$config=Get-Content -LiteralPath (Join-Path $Workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
$config.humanCabinet=$cabinet
$config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $index 'delivery-system.json') -Encoding utf8
function Snapshot([string]$Root){@((Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName) | ForEach-Object { $_.FullName.Substring($Root.Length) + '=' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join '|'}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function ExpectFailure([scriptblock]$Action,[string]$Pattern){$caught=$false;try{& $Action | Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};$caught=$true};Assert $caught ('Expected rejection: '+$Pattern)}
$passed=0
$before=Snapshot $core
$source=Join-Path $caseRoot 'source.csv'
[IO.File]::WriteAllText($source,"key,value`nA,1",[Text.UTF8Encoding]::new($false))
$start=Join-Path $shared 'Start-HwpxWork.ps1'
$publishPath=Join-Path $shared 'Publish-HumanResult.ps1'
function Invoke-ReadyPublication {
    [CmdletBinding()]
    param([string]$Stage,[string]$TaskTitle,[string]$WorkFolderName,[string[]]$SourceFile,[string[]]$TargetRelativePath=@(),[switch]$PartialUpdate,[switch]$ExplicitTextArtifact,[switch]$UpdateConsole,[switch]$PlanOnly)
    if (-not $PlanOnly) {
        $sourceJob=Get-WorkJobInfo -Workspace $core -Path $SourceFile[0] -RequireExists
        $completion=@{JobPath=$sourceJob.jobRoot;SourceFile=$SourceFile;Stage=$Stage;ChecksCompleted=@('content','integrity')}
        $completion.TargetRelativePath=if ($TargetRelativePath.Count) {$TargetRelativePath} else {@($SourceFile | ForEach-Object {([IO.Path]::GetFullPath($_)).Substring((Join-Path $sourceJob.jobRoot 'wip\docs').Length + 1)})}
        & (Join-Path $shared 'Complete-HumanDraft.ps1') @completion | Out-Null
    }
    & $publishPath @PSBoundParameters
}
. (Join-Path $shared 'WorkStorage.ps1')
$publish='Invoke-ReadyPublication'
ExpectFailure { & $start -Mode New -TaskTitle 'Unclassified work' -JobSlug 'missing-classification' -IntakeSummary 'Fixture' -DecisionReason 'New request' } 'explicit numbered WorkFolderName'
Assert (@(Get-ChildItem -LiteralPath $cabinet -Force).Count -eq 0) 'Missing classification created a folder'
$intake=(& $start -Mode New -TaskTitle 'Synthetic work' -WorkFolderName '23_Synthetic work' -JobSlug 'first-run' -IntakeSummary 'Fixture' -DecisionReason 'New request' -FormFile $source -UserProvidedFile $source | Out-String) | ConvertFrom-Json
$job=$intake.jobPath
$work=$intake.workRoot
Assert (-not $intake.finalPolishAuthorized) 'Ordinary intake must be content-only'
$scopeCommon=@{Mode='FollowUp';TaskTitle='Synthetic work';WorkFolderName='23_Synthetic work';JobPath=$job;IntakeSummary='Synthetic scope request';DecisionReason='Scope guard regression'}
$metadataScopePath=Join-Path $work '.ai\work.json'
$scopeBefore=[IO.File]::ReadAllBytes($metadataScopePath)
ExpectFailure { & $start @scopeCommon -FinalPolishAuthorized } 'exact explicit user request'
ExpectFailure { & $start @scopeCommon -FinalPolishAuthorized -FormattingRequestText '최종본으로 합쳐줘' } 'explicit format_edit request'
ExpectFailure { & $start @scopeCommon -FinalPolishAuthorized -FormattingRequestText '서식은 바꾸지 말고 내용만 수정해줘' } 'prohibition or revocation'
Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($metadataScopePath)) -ceq [Convert]::ToBase64String($scopeBefore)) 'Rejected expansion changed current metadata'
$granted=(& $start @scopeCommon -FinalPolishAuthorized -FormattingRequestText '글꼴을 바꿔줘' | Out-String) | ConvertFrom-Json
Assert $granted.finalPolishAuthorized 'Explicit format request should be admitted'
$continued=(& $start @scopeCommon | Out-String) | ConvertFrom-Json
Assert $continued.finalPolishAuthorized 'Same active job should retain explicit permission'
$revoked=(& $start @scopeCommon -RevokeDocumentScope | Out-String) | ConvertFrom-Json
Assert (-not $revoked.finalPolishAuthorized -and $revoked.editingMode -eq 'content_only') 'Explicit revocation must restore content-only'
. (Join-Path $shared 'DocumentScope.ps1')
ExpectFailure { Assert-DocumentCapability $job 'format_edit' } 'Document scope blocks'
Assert ($job.StartsWith((Join-Path $work '.ai\jobs'))) 'Job must be work-local'
Assert ((Snapshot $core) -ceq $before) 'Intake changed the core'
Assert (-not(Test-Path -LiteralPath (Join-Path $work 'previous_versions'))) 'Intake created legacy history'
$orig=@(Get-ChildItem -LiteralPath (Join-Path $work '.ai\originals') -File -Recurse -Force)
Assert ($orig.Count -eq 1 -and (Get-FileHash $orig[0].FullName).Hash -eq (Get-FileHash $source).Hash) 'Original preservation failed'
$first=Join-Path $job 'wip\docs\notice.txt'
$second=Join-Path $job 'wip\docs\submit.txt'
[IO.File]::WriteAllText($first,'version one')
[IO.File]::WriteAllText($second,'unrelated current')
$targets=@('00_notice.txt','01_submit\submit.txt')
ExpectFailure { & $publish -Stage Final -TaskTitle 'Synthetic work' -SourceFile @($first,$second) -TargetRelativePath $targets } 'TXT publication requires'
$one=(& $publish -Stage Final -TaskTitle 'Synthetic work' -SourceFile @($first,$second) -TargetRelativePath $targets -ExplicitTextArtifact | Out-String) | ConvertFrom-Json
Assert ($one.archivedFiles.Count -eq 0) 'First publish should have no revision'
Assert ((Snapshot $core) -ceq $before) 'Publish changed the core'
$same=(& $publish -Stage Final -TaskTitle 'Synthetic work' -SourceFile @($first,$second) -TargetRelativePath $targets | Out-String) | ConvertFrom-Json
Assert ($same.reusedCurrentFiles -and $same.archivedFiles.Count -eq 0) 'Identical publication created revisions'
$current=Join-Path $work '01_submit\submit.txt'
[IO.File]::WriteAllText($current,'human current edit')
[IO.File]::WriteAllText($second,'revision output')
ExpectFailure { & $publish -Stage Final -TaskTitle 'Synthetic work' -SourceFile $second -TargetRelativePath '01_submit\submit.txt' -PartialUpdate -ExplicitTextArtifact } 'exact hash as human_revision|delivery cycle|completed|completion|receipt|changed publication'
$follow=(& $start -Mode FollowUp -TaskTitle 'Synthetic work' -JobSlug 'second-run' -IntakeSummary 'Selected correction' -DecisionReason 'Requested follow-up' -HumanRevisionFile $current -SelectedFilesOnly | Out-String) | ConvertFrom-Json
$updated=Join-Path $follow.jobPath 'wip\docs\submit.txt'
[IO.File]::WriteAllText($updated,'revision output')
$unchangedHash=(Get-FileHash -LiteralPath (Join-Path $work '00_notice.txt')).Hash
$two=(& $publish -Stage Final -TaskTitle 'Synthetic work' -SourceFile $updated -TargetRelativePath '01_submit\submit.txt' -PartialUpdate -ExplicitTextArtifact | Out-String) | ConvertFrom-Json
Assert ($two.archivedFiles.Count -eq 1) 'Changed current needs one revision'
$revision=$two.archivedFiles[0].archive
Assert (([IO.Path]::GetDirectoryName($revision) -ieq (Join-Path $work '.ai\revisions')) -and ([IO.Path]::GetFileName($revision) -match '^[A-Fa-f0-9]{64}\.txt$')) 'Revision must be a hidden content-addressed object'
Assert ([IO.File]::ReadAllText($revision) -ceq 'human current edit') 'Revision did not preserve exact human current'
Assert ((Get-FileHash -LiteralPath (Join-Path $work '00_notice.txt')).Hash -eq $unchangedHash) 'Partial update changed unrelated file'
Assert ((Snapshot $core) -ceq $before) 'Follow-up or revision changed the core'
Assert (-not(Test-Path -LiteralPath (Join-Path $work 'previous_versions'))) 'Publish created legacy history'
Assert (-not(Test-Path -LiteralPath (Join-Path $work $config.consoleFileName))) 'Unrequested console was generated'
. (Join-Path $shared 'WorkStorage.ps1')
ExpectFailure {Get-WorkJobInfo -Workspace $core -Path (Join-Path $core ('.agent\jobs\'+(Get-Date -Format 'yyyyMMdd')+'-legacy-run'))} 'outside the selected work storage'
ExpectFailure {Get-WorkCurrentTarget -WorkRoot $work -RelativePath '..\escape.txt'} 'Unsafe current-file'
. (Join-Path $shared 'WorkRegistry.ps1')
$registry=Get-WorkRegistry -Workspace $core
Assert (@($registry.works).Count -eq 1 -and @($registry.works[0].files).Count -eq 2) 'Work-local registry did not reconstruct files'
Assert (-not(Test-Path -LiteralPath (Join-Path $index 'human-current.json'))) 'Global registry was generated'
Assert ((Get-Command (Join-Path $shared 'New-HwpxJob.ps1')).Parameters.WorkFolder.Attributes.Mandatory -contains $true) 'New job needs explicit work selection'
$metadataPath=Join-Path $work '.ai\work.json'
$metadata=Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json
$inputsPath=Join-Path $job 'inputs.json'
$inputs=Get-Content -LiteralPath $inputsPath -Raw -Encoding utf8 | ConvertFrom-Json
Assert ($metadata.workId -and $metadata.workId -ceq $inputs.delivery.workId) 'Work and job need the same stable identity'
Assert ($registry.works[0].workId -ceq $metadata.workId) 'Registry lost stable work identity'
$reuse=(& $start -Mode New -TaskTitle 'Synthetic work' -JobSlug 'reuse-existing' -IntakeSummary 'Another request' -DecisionReason 'Same work' | Out-String) | ConvertFrom-Json
Assert ($reuse.mode -eq 'FollowUp' -and $reuse.workRoot -ieq $work) 'Known work title created a duplicate work instead of reuse'
Assert ((Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json).workId -ceq $metadata.workId) 'Follow-up changed stable work identity'
foreach($name in @('11_Test','23-01_Test','23-01-02_Test','20260930_Test')) { Assert (Test-WorkFolderName $name) ('Valid work name rejected: '+$name) }
foreach($name in @('Test','1_Test','123_Test','23_', '23_ ', '23_Test.', '23_Test\child', '23_Test:stream', "23_bad`nname")) { Assert (-not (Test-WorkFolderName $name)) 'Unsafe or unclassified work name accepted' }
$inserted=(& $start -Mode New -TaskTitle '23-01_Inserted work' -JobSlug 'inserted-run' -IntakeSummary 'Fixture' -DecisionReason 'Explicit inserted work' | Out-String) | ConvertFrom-Json
Assert ($inserted.workFolderName -eq '23-01_Inserted work' -and $inserted.taskTitle -eq 'Inserted work') 'Explicit numbered task title was not used correctly'
$legacy=(& $start -Mode New -TaskTitle 'Legacy work' -WorkFolderName '20260901_Legacy work' -JobSlug 'legacy-run' -IntakeSummary 'Fixture' -DecisionReason 'Explicit legacy selection' | Out-String) | ConvertFrom-Json
Assert ($legacy.workFolderName -eq '20260901_Legacy work') 'Legacy dated work lost compatibility'
$numberedMetadata=Join-Path $inserted.workRoot '.ai\work.json'
$numbered=Get-Content -LiteralPath $numberedMetadata -Raw -Encoding utf8 | ConvertFrom-Json
$numbered.PSObject.Properties.Remove('createdDate')
$numbered | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $numberedMetadata -Encoding utf8
$read=Get-WorkRegistry -Workspace $core
Assert (-not ($read.works | Where-Object folderName -eq '23-01_Inserted work').createdDate) 'Registry inferred a date from a classification number'
$originalInputs=[IO.File]::ReadAllBytes($inputsPath)
try {
    $inputs.delivery.workRoot=Join-Path $caseRoot 'old-cabinet\23_Synthetic work'
    $inputs | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $inputsPath -Encoding utf8
    Assert ((Get-WorkJobInfo -Workspace $core -Path $job).workRoot -ieq $work) 'Stable identity could not resolve a relocated work root'
    $inputs.delivery.workId=[guid]::NewGuid().ToString('D')
    $inputs | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $inputsPath -Encoding utf8
    ExpectFailure { Get-WorkJobInfo -Workspace $core -Path $job } 'different human work identity'
    $inputs.delivery.PSObject.Properties.Remove('workId')
    $inputs | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $inputsPath -Encoding utf8
    ExpectFailure { Get-WorkJobInfo -Workspace $core -Path $job } 'different human work folder'
} finally { [IO.File]::WriteAllBytes($inputsPath,$originalInputs) }
Assert ((Snapshot $core) -ceq $before) 'Numbered and legacy work checks changed the core'
$report=[ordered]@{ok=$true;passed=$passed;coreUnchanged=((Snapshot $core) -ceq $before);currentFiles=@($registry.works[0].files).Count;revisionFiles=$two.archivedFiles.Count}
if ($ReceiptPath) { $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReceiptPath -Encoding utf8 }
$report | ConvertTo-Json -Depth 4
} finally {
    $safe = [IO.Path]::GetFullPath($caseRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($safe) -ine $tempRoot -or [IO.Path]::GetFileName($safe) -notmatch '^hwpx-fixed-core-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $safe) {
        if ((Get-Item -LiteralPath $safe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixture root became a reparse point.' }
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
