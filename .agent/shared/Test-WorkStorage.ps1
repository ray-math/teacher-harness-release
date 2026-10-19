[CmdletBinding()]
param([string]$ReceiptPath='')
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hwpx-work-storage-test-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw "FAIL: $Name"};$checks.Add($Name)}
function Json($Value){($Value -join [Environment]::NewLine)|ConvertFrom-Json}
function Fails([scriptblock]$Action,[string]$Pattern){try{& $Action|Out-Null}catch{if($_.Exception.Message -notmatch $Pattern){throw};return $true};return $false}
try {
    $shared=Join-Path $fixture '.agent/shared';$index=Join-Path $fixture '.agent/index';$cabinet=Join-Path $fixture 'cabinet'
    foreach($p in @($shared,$index,(Join-Path $cabinet '.agent/shared'))){New-Item -ItemType Directory -Path $p -Force|Out-Null}
    ''|Set-Content -LiteralPath (Join-Path $cabinet '.agent/shared/Initialize-PortableCabinet.ps1') -Encoding utf8
    foreach($name in @('WorkStorage.ps1','WorkRegistry.ps1','DocumentScope.ps1','HumanDeliveryContract.ps1','HumanRevisionStorage.ps1','Complete-HumanDraft.ps1','DocumentBasis.ps1','Resolve-TeacherHarnessConfig.ps1','Receive-TeacherHarnessInputs.ps1','Start-HwpxWork.ps1','New-HwpxJob.ps1','Publish-HumanResult.ps1','Sync-HumanSourcePreservation.ps1','Update-HumanWorkConsole.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared}
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'WorkLayout.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'WorkLayout.ps1') -Destination $shared}
    $config=Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $workspace '.agent/index/delivery-system.json')|ConvertFrom-Json
    $baseline=Join-Path $fixture 'existing-form.csv'
    [IO.File]::WriteAllText($baseline,"name,value`r`n,",[Text.UTF8Encoding]::new($true))
    $config.incomingRoot=Join-Path $fixture 'incoming';$config.humanCabinet=$cabinet;$config|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $index 'delivery-system.json') -Encoding utf8
    . (Join-Path $shared 'WorkStorage.ps1')
    function Invoke-ReadyPublication {
        [CmdletBinding()]
        param([string]$Stage,[string]$TaskTitle,[string]$WorkFolderName,[string[]]$SourceFile,[string[]]$TargetRelativePath=@(),[switch]$PartialUpdate,[switch]$ExplicitTextArtifact,[switch]$UpdateConsole,[switch]$PlanOnly)
        if (-not $PlanOnly) {
            $sourceJob=Get-WorkJobInfo -Workspace $fixture -Path $SourceFile[0] -RequireExists
            $completion=@{JobPath=$sourceJob.jobRoot;SourceFile=$SourceFile;Stage=$Stage;ChecksCompleted=@('content','integrity')}
            $completion.TargetRelativePath=if ($TargetRelativePath.Count) {$TargetRelativePath} else {@($SourceFile | ForEach-Object {([IO.Path]::GetFullPath($_)).Substring((Join-Path $sourceJob.jobRoot 'wip\docs').Length + 1)})}
            & (Join-Path $shared 'Complete-HumanDraft.ps1') @completion | Out-Null
        }
        & (Join-Path $shared 'Publish-HumanResult.ps1') @PSBoundParameters
    }
    $first=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode New -FormFile $baseline -TaskTitle 'storage test' -WorkFolderName '23_storage test' -CreatedDate '20260929' -JobSlug 'storage-test' -IntakeSummary 'fixture' -DecisionReason 'isolated test')
    $work=$first.workRoot;$job=$first.jobPath;$docs=$first.workingDocuments
    $info=Get-WorkJobInfo -Workspace $fixture -Path $docs -RequireExists
    Check ($info.storageKind -eq 'work' -and $info.workRoot -eq $work -and $info.jobRoot -eq $job) 'job and draft directories resolve inside selected human work'
    Check (-not(Test-Path -LiteralPath (Join-Path $fixture '.agent/jobs'))) 'intake creates no school job under agent storage'
    Check (-not(Test-Path -LiteralPath (Join-Path $work 'previous_versions'))) 'clean new workflow creates no previous_versions folder'
    Check (Fails {Get-WorkJobInfo -Workspace $fixture -Path $docs -RequireJobRoot} 'Expected the job root') 'root-only validation rejects descendant'
    Check (Fails {Get-WorkJobInfo -Workspace $fixture -Path ($job+':stream')} 'streams') 'alternate data streams rejected'
    foreach($bad in @('../escape.csv','.ai/private.csv','previous_versions/history.csv','01_folder/NUL.csv',"01_folder/bad`nname.csv",'01_folder/trailing.')) { Check (Fails {Get-WorkCurrentTarget -WorkRoot $work -RelativePath $bad} 'Unsafe') "unsafe target rejected: $($bad.Replace("`n",' control '))" }
    $hidden=Join-Path $work 'hidden';New-Item -ItemType Directory -Path $hidden|Out-Null;[IO.File]::SetAttributes($hidden,[IO.FileAttributes]::Hidden)
    Check (Fails {Get-WorkCurrentTarget -WorkRoot $work -RelativePath 'hidden/result.csv'} 'hidden') 'hidden target ancestor rejected'
    $one=Join-Path $docs '00_진행 확인.csv';$nested=Join-Path $docs '02_자료 확인/검토 결과.csv'
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($nested)) -Force|Out-Null
    [IO.File]::WriteAllText($one,'first root');[IO.File]::WriteAllText($nested,'first nested')
    $pub=@{Stage='Review';TaskTitle='storage test';WorkFolderName=$first.workFolderName;SourceFile=@($one,$nested)}
    $published=Json (Invoke-ReadyPublication @pub)
    Check ((Test-Path -LiteralPath (Join-Path $work '00_진행 확인.csv')) -and (Test-Path -LiteralPath (Join-Path $work '02_자료 확인/검토 결과.csv'))) 'singleton root file and numbered workflow subfolder publish together'
    $follow=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode FollowUp -TaskTitle 'storage test' -WorkFolderName $first.workFolderName -JobPath $job -IntakeSummary 'follow' -DecisionReason 'revision test')
    [IO.File]::WriteAllText($nested,'second nested')
    $second=Json (Invoke-ReadyPublication @pub)
    Check ($second.archivedFiles.Count -eq 1 -and $second.archivedFiles[0].revisionOf -eq '02_자료 확인\검토 결과.csv' -and [IO.Path]::GetDirectoryName($second.archivedFiles[0].archive) -eq (Join-Path $work '.ai/revisions') -and [IO.Path]::GetFileName($second.archivedFiles[0].archive) -match '^[A-Fa-f0-9]{64}\.csv$') 'only replaced nested file gets hidden content-addressed history'
    Check ((Get-Content -Raw -LiteralPath $second.archivedFiles[0].archive) -eq 'first nested') 'revision history preserves replaced bytes'
    $follow=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode FollowUp -TaskTitle 'storage test' -WorkFolderName $first.workFolderName -JobPath $job -IntakeSummary 'follow again' -DecisionReason 'rollback test')
    [IO.File]::WriteAllText($nested,'third nested')
    $consolePath=Join-Path $shared 'Update-HumanWorkConsole.ps1';$console=Get-Content -Raw -Encoding utf8 -LiteralPath $consolePath
    "throw 'Injected console failure'"|Set-Content -LiteralPath $consolePath -Encoding utf8
    try {Check (Fails {Invoke-ReadyPublication @pub -UpdateConsole} 'Injected console failure') 'post-publication failure propagates'} finally {$console|Set-Content -LiteralPath $consolePath -Encoding utf8}
    Check ((Get-Content -Raw -LiteralPath (Join-Path $work '02_자료 확인/검토 결과.csv')) -eq 'second nested') 'failed publication restores exact nested current path'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $work '.ai/revisions') -File).Count -eq 1) 'rollback leaves only successful revision history'
    $third=Json (Invoke-ReadyPublication @pub)
    Check ($third.archivedFiles[0].createdObject -and [IO.Path]::GetFileName($third.archivedFiles[0].archive) -match '^[A-Fa-f0-9]{64}\.csv$') 'successful retry creates only one content object after rollback'
    $repeat=Json (Invoke-ReadyPublication @pub)
    Check ($repeat.reusedCurrentFiles -and $repeat.archivedFiles.Count -eq 0) 'unchanged republish produces no extra fix history'
    $follow=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode FollowUp -TaskTitle 'storage test' -WorkFolderName $first.workFolderName -JobPath $job -IntakeSummary 'target mapping' -DecisionReason 'explicit rename test')
    $mapped=Json (Invoke-ReadyPublication -Stage Review -TaskTitle 'storage test' -WorkFolderName $first.workFolderName -SourceFile @($one,$nested) -TargetRelativePath @('00_진행 확인.csv','03_검토 마치기/최종 확인.csv') -PlanOnly)
    Check ($mapped.files[1].name -eq '03_검토 마치기\최종 확인.csv') 'explicit relative target mapping supports newly requested workflow step'
    $mapped=Json (Invoke-ReadyPublication -Stage Review -TaskTitle 'storage test' -WorkFolderName $first.workFolderName -SourceFile @($one,$nested) -TargetRelativePath @('00_진행 확인.csv','03_검토 마치기/최종 확인.csv'))
    Check ((Test-Path -LiteralPath (Join-Path $work '03_검토 마치기/최종 확인.csv')) -and -not (Test-Path -LiteralPath (Join-Path $work '02_자료 확인/검토 결과.csv'))) 'explicit nested mapping publishes and preserves replaced old location in history'
    $rootFollow=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode FollowUp -TaskTitle 'storage test' -WorkFolderName $first.workFolderName -JobPath $job -IntakeSummary 'root revision' -DecisionReason 'same directory root test')
    [IO.File]::WriteAllText($one,'second root')
    $rootPublish=Json (Invoke-ReadyPublication -Stage Review -TaskTitle 'storage test' -SourceFile @($one,$nested) -TargetRelativePath @('00_진행 확인.csv','03_검토 마치기/최종 확인.csv'))
    Check ([IO.Path]::GetDirectoryName($rootPublish.archivedFiles[0].archive) -eq (Join-Path $work '.ai/revisions')) 'root current history is hidden in the same work metadata'
    $rootFollow=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode FollowUp -TaskTitle 'storage test' -WorkFolderName $first.workFolderName -JobPath $job -IntakeSummary 'recorded history' -DecisionReason 'exact registration test')
    Check ($rootFollow.workRoot -eq $work) 'registered root revision does not block followup'
    $unregistered=Join-Path $work 'unknown_fix01_20260929-010101.csv';[IO.File]::WriteAllText($unregistered,'not registered')
    try {Check (Fails {& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode FollowUp -TaskTitle 'storage test' -WorkFolderName $first.workFolderName -JobPath $job -IntakeSummary 'unexpected' -DecisionReason 'fail closed'} 'Unregistered') 'unregistered fix-like filename remains blocked'} finally {Remove-Item -LiteralPath $unregistered}
    Check (-not(Test-Path -LiteralPath (Join-Path $work 'previous_versions'))) 'publishing revisions creates no previous_versions folder'
    Check (Fails {Invoke-ReadyPublication -Stage Review -TaskTitle 'storage test' -SourceFile @($one,$nested) -TargetRelativePath @('one.csv') -PlanOnly} 'one relative path') 'incomplete target mapping rejected'
    $other=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode New -FormFile $baseline -TaskTitle 'other test' -WorkFolderName '24_other test' -CreatedDate '20260929' -JobSlug 'other-test' -IntakeSummary 'fixture other' -DecisionReason 'cross work test')
    Check (Fails {Invoke-ReadyPublication -Stage Review -TaskTitle 'other test' -SourceFile @($one) -PlanOnly} 'different human work') 'cross-work publication rejected'
    $legacy=Join-Path $fixture '.agent/jobs/normalization-test-fixture';New-Item -ItemType Directory -Path $legacy -Force|Out-Null
    Check (Fails {Get-WorkJobInfo -Workspace $fixture -Path $legacy -RequireJobRoot -RequireExists} 'outside the selected work storage') 'old shared job paths are rejected'
    $oldWorkJob=Join-Path $other.workRoot 'previous_versions/_작업중/20260929-existing-job';New-Item -ItemType Directory -Path $oldWorkJob -Force|Out-Null
    Check (Fails {Get-WorkJobInfo -Workspace $fixture -Path $oldWorkJob -RequireJobRoot -RequireExists} 'selected work .ai/jobs tree') 'old previous_versions job paths are rejected'
    $boundJob=Join-Path $work '.ai/jobs/20260929-bound-test';New-Item -ItemType Directory -Path $boundJob -Force|Out-Null
    $boundInputs=[ordered]@{delivery=@{workRoot=$other.workRoot};sources=@()};$boundInputs|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $boundJob 'inputs.json') -Encoding utf8
    Check (Fails {& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode FollowUp -TaskTitle 'storage test' -WorkFolderName $first.workFolderName -JobPath $boundJob -IntakeSummary 'wrong work' -DecisionReason 'binding test'} 'different human work|bound to another') 'existing intake binding cannot be reassigned to another work'
    Check (-not(Test-Path -LiteralPath (Join-Path $index 'human-current.json'))) 'storage operations do not regenerate a global work registry'
    $report=[ordered]@{ok=$true;count=$checks.Count;powershell=$PSVersionTable.PSVersion.ToString();verification='isolated storage and publication integration';checks=@($checks)}
    if($ReceiptPath){$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $ReceiptPath -Encoding utf8}
    $report|ConvertTo-Json -Depth 5
} finally {
    $safe=[IO.Path]::GetFullPath($fixture)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if([IO.Path]::GetDirectoryName($safe) -ine $tempRoot -or [IO.Path]::GetFileName($safe) -notmatch '^hwpx-work-storage-test-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup path.'}
    if(Test-Path -LiteralPath $safe){
        if((Get-Item -LiteralPath $safe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Fixture root became a reparse point.'}
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
