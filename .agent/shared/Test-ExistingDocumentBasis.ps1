[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$qa=Join-Path ([IO.Path]::GetDirectoryName($workspace)) 'HarnessQA'
$fixture=Join-Path $qa ('existing-basis-'+[guid]::NewGuid().ToString('N'))
$shared=Join-Path $fixture '.agent\shared'
$index=Join-Path $fixture '.agent\index'
$cabinet=Join-Path $fixture 'work'
$incoming=Join-Path $fixture 'received'
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Ok,[string]$Name) { if(-not $Ok){throw "FAIL: $Name"};$checks.Add($Name) }
function Json($Value) { ($Value -join [Environment]::NewLine) | ConvertFrom-Json }
function Reject([scriptblock]$Action,[string]$Pattern,[string]$Name) {
    $caught=$false
    try { & $Action | Out-Null } catch { if($_.Exception.Message -notmatch $Pattern){throw};$caught=$true }
    Check $caught $Name
}
try {
    New-Item -ItemType Directory -Path $shared,$index -Force | Out-Null
    foreach($name in @('New-HwpxFormContract.ps1','DocumentBasis.ps1','Resolve-TeacherHarnessConfig.ps1','Receive-TeacherHarnessInputs.ps1','WorkStorage.ps1','WorkRegistry.ps1','DocumentScope.ps1','HumanDeliveryContract.ps1','HumanRevisionStorage.ps1','Complete-HumanDraft.ps1','Start-HwpxWork.ps1','New-HwpxJob.ps1','Publish-HumanResult.ps1','Sync-HumanSourcePreservation.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared
    }
    $config=Get-Content -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $config.humanCabinet=$cabinet;$config.incomingRoot=$incoming
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $index 'delivery-system.json') -Encoding utf8
    $data=Join-Path $fixture 'provided-data.csv'
    [IO.File]::WriteAllText($data,"item,value`r`na,12",[Text.UTF8Encoding]::new($true))
    $originalHash=(Get-FileHash -LiteralPath $data).Hash
    $start=Join-Path $shared 'Start-HwpxWork.ps1'
    $complete=Join-Path $shared 'Complete-HumanDraft.ps1'
    $missing=@{Mode='New';TaskTitle='Missing form';WorkFolderName='21_Missing form';JobSlug='missing-form';IntakeSummary='Create a draft';DecisionReason='Synthetic verification';RequestText='Create a new draft without materials';AuthorityFile=@($data);UserProvidedFile=@($data)}
    Reject { & $start @missing } 'needs_input.*draft or form' 'new-draft wording cannot bypass missing baseline'
    Check (-not(Test-Path -LiteralPath (Join-Path $cabinet '21_Missing form'))) 'missing form creates no work or draft folder'
    Check ((Get-FileHash -LiteralPath (Join-Path $incoming 'provided-data.csv')).Hash -eq $originalHash) 'provided facts remain received when authoring stops'
    Check ((Get-FileHash -LiteralPath $data).Hash -eq $originalHash) 'receiving leaves original source unchanged'
    Reject { & (Join-Path $shared 'New-HwpxFormContract.ps1') -FormStatus absent -FormLayout separate -FreeFormAuthorized -ExplicitNewFormInstruction '새 양식을 만들어' } 'needs_input.*New form authoring is disabled' 'legacy free-form flag cannot invent a missing template'
    $form=Join-Path $fixture 'selected-existing-form.csv'
    [IO.File]::WriteAllText($form,"item,value,note`r`na,,preserve",[Text.UTF8Encoding]::new($true))
    $valid=@{Mode='New';TaskTitle='Fill selected form';WorkFolderName='22_Fill selected form';JobSlug='fill-form';IntakeSummary='Fill an existing form';DecisionReason='Synthetic verification';RequestText='Fill the selected existing form';FormFile=@($form);AuthorityFile=@($data);UserProvidedFile=@($form,$data)}
    $intake=Json (& $start @valid)
    $inputsPath=Join-Path $intake.jobPath 'inputs.json'
    $inputs=Get-Content -LiteralPath $inputsPath -Raw -Encoding utf8 | ConvertFrom-Json
    Check ($inputs.documentBasis.purpose -eq 'Document' -and @($inputs.documentBasis.records).Count -eq 1) 'document intake records the selected existing form'
    $snapshot=Join-Path $intake.workRoot $inputs.documentBasis.records[0].preservedRelativePath
    Check ((Get-FileHash -LiteralPath $snapshot).Hash -eq (Get-FileHash -LiteralPath $form).Hash) 'basis points to exact protected form snapshot'
    $output=Join-Path $intake.jobPath 'wip\docs\result.csv'
    Copy-Item -LiteralPath $form -Destination $output
    $row=Import-Csv -LiteralPath $output -Encoding utf8;$row.value='12';$row | Export-Csv -LiteralPath $output -NoTypeInformation -Encoding utf8
    $ready=@{JobPath=$intake.jobPath;SourceFile=@($output);TargetRelativePath=@('result.csv');Stage='Final';ChecksCompleted=@('content','integrity')}
    $receipt=Json (& $complete @ready)
    Check ($receipt.status -eq 'ready' -and (Import-Csv -LiteralPath $output -Encoding utf8).note -eq 'preserve') 'existing structure filled while unrelated value survives'
    $bytes=[IO.File]::ReadAllBytes($snapshot)
    [IO.File]::WriteAllText($snapshot,'changed snapshot')
    Reject { & $complete @ready } 'snapshot is missing or changed' 'changed form snapshot blocks completion'
    [IO.File]::WriteAllBytes($snapshot,$bytes)
    $planning=Json (& $start -Purpose Workflow -Mode New -TaskTitle 'Plan only' -WorkFolderName '23_Plan only' -JobSlug 'plan-only' -IntakeSummary 'Arrange workflow' -DecisionReason 'Synthetic planning request' -RequestText 'Arrange workflow only')
    Check ((Test-Path -LiteralPath $planning.jobPath) -and -not (Test-Path -LiteralPath (Join-Path $planning.workingDocuments 'result.csv'))) 'workflow planning may start without inventing a document'
    $attempt=Join-Path $planning.workingDocuments 'result.csv'
    Copy-Item -LiteralPath $form -Destination $attempt
    Reject { & $complete -JobPath $planning.jobPath -SourceFile $attempt -TargetRelativePath 'result.csv' -Stage Final -ChecksCompleted @('content','integrity') } 'Planning-only intake cannot publish' 'planning-only intake cannot complete or publish a document'
    [ordered]@{ok=$true;count=$checks.Count;checks=@($checks);fixtureOnly=$true} | ConvertTo-Json -Depth 5
} finally {
    $safe=[IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($safe) -ine [IO.Path]::GetFullPath($qa) -or [IO.Path]::GetFileName($safe) -notmatch '^existing-basis-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path.' }
    if(Test-Path -LiteralPath $safe) {
        if(@(Get-ChildItem -LiteralPath $safe -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count){throw 'Unexpected linked fixture path.'}
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
