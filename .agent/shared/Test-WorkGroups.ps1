[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$fixture=Join-Path $env:TEMP ('hwpx-work-groups-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw "FAIL: $Name"};$checks.Add($Name)}
function Save($Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($true))}
function Reject([scriptblock]$Action,[string]$Name){$rejected=$false;try{& $Action | Out-Null}catch{$rejected=$true};Check $rejected $Name}
try {
    $shared=Join-Path $fixture '.agent\shared';$index=Join-Path $fixture '.agent\index';$cabinet=Join-Path $fixture 'cabinet'
    $work1=Join-Path $cabinet '21_Exam one';$work2=Join-Path $cabinet '22_Exam two';$other=Join-Path $cabinet '40_Another duty';$unlinked=Join-Path $cabinet '24_Unlinked'
    $prior=Join-Path $cabinet 'Prior materials';$external=Join-Path $fixture 'Explicit external';$local=Join-Path $work1 'Local references'
    foreach($path in @($shared,$index,$prior,$external,$local,(Join-Path $work1 '.ai'),(Join-Path $work2 '.ai'),(Join-Path $other '.ai'),(Join-Path $unlinked '.ai'))){New-Item -ItemType Directory -Path $path -Force|Out-Null}
    foreach($name in @('WorkStorage.ps1','WorkRegistry.ps1','WorkGroup.ps1','WorkReferenceScope.ps1','Set-WorkGroup.ps1','Set-WorkDecision.ps1','Get-WorkContext.ps1','Set-WorkReferenceScope.ps1','Find-HwpxContext.ps1','Prepare-WorkWorkflow.ps1','WorkLayout.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared}
    $config=Join-Path $index 'delivery-system.json';Save $config @{humanCabinet=$cabinet;metadataFolderName='.ai';workMetadataName='work.json';archiveFolderName='previous_versions'}
    foreach($work in @($work1,$work2,$other,$unlinked)){Save (Join-Path $work '.ai\work.json') @{title='Exam';folderName=[IO.Path]::GetFileName($work);currentFiles=@();preservedField='original'};[IO.File]::WriteAllText((Join-Path $work 'Original.txt'),'unchanged original')}
    foreach($folder in @($prior,$external,$local)){[IO.File]::WriteAllText((Join-Path $folder 'Exam plan.txt'),'synthetic source')}
    $workflow=Join-Path $cabinet '00_Workflow.html';[IO.File]::WriteAllText($workflow,'synthetic human workflow')
    $definitionPath=Join-Path $fixture 'definition.json'
    $definition=@{title='Annual selected duties';year='2026';workflowPath=$workflow;categories=@(@{code='20';title='Exam'});referenceScope=@{noReferences=$false;roots=@(@{role='prior-source';path=$prior},@{role='manual';path=$external})};decisions=@(@{key='filename';text='Use action names';appliesTo=@()},@{key='exam-method';text='Reuse accepted checks';appliesTo=@('20')},@{key='omitted-scope';text='Common without explicit category'})}
    Save $definitionPath $definition
    $set=Join-Path $shared 'Set-WorkGroup.ps1';$get=Join-Path $shared 'Get-WorkContext.ps1';$setScope=Join-Path $shared 'Set-WorkReferenceScope.ps1';$setDecision=Join-Path $shared 'Set-WorkDecision.ps1';$find=Join-Path $shared 'Find-HwpxContext.ps1'
    Reject {& $set -GroupId annual -DefinitionPath $definitionPath -WorkFolder $work1 -CategoryCode 20} 'unconfirmed shared update is rejected'
    Check (-not(Test-Path -LiteralPath (Join-Path $cabinet '.ai'))) 'unconfirmed update creates no group metadata'
    & $set -GroupId annual -DefinitionPath $definitionPath -WorkFolder $work1,$work2 -CategoryCode 20 -ConfirmedByUser|Out-Null
    $groupPath=Join-Path $cabinet '.ai\work-groups\annual.json';$group=Get-Content -LiteralPath $groupPath -Raw -Encoding utf8|ConvertFrom-Json
    Check ($group.workflowPath -eq '00_Workflow.html' -and $group.referenceScope.roots[0].path -eq 'Prior materials' -and $group.referenceScope.roots[1].path -eq $external) 'cabinet sources and workflow use relative paths; external selection remains absolute'
    $context=(& $get -WorkFolder $work2)|ConvertFrom-Json
    Check ($context.status -eq 'ready' -and $context.referenceScope.source -eq 'group' -and @($context.decisions).Count -eq 3) 'next explicitly linked event inherits confirmed references and decisions'
    $metadata=Get-Content -LiteralPath (Join-Path $work2 '.ai\work.json') -Raw -Encoding utf8|ConvertFrom-Json
    Check ($metadata.preservedField -eq 'original' -and $metadata.groupCategoryCode -eq '20') 'linking preserves unrelated per-work metadata'
    Reject {& $set -GroupId annual -WorkFolder $other -CategoryCode 40 -ConfirmedByUser} 'unknown category requires selection and is not inferred from folder number'
    $unknown=(& $get -WorkFolder $unlinked)|ConvertFrom-Json
    Check ($unknown.group.status -eq 'none' -and $unknown.referenceScope.status -eq 'needs_input' -and @($unknown.decisions).Count -eq 0) 'unlinked work never auto-inherits a matching group'
    $found=(& $find -TaskTitle Exam -WorkFolder $work2)|ConvertFrom-Json
    Check ($found.status -eq 'ready' -and @($found.candidates).Count -eq 2) 'discovery follows the explicitly inherited source scope'
    & $setScope -WorkFolder $work1 -NoReferences|Out-Null
    $context=(& $get -WorkFolder $work1)|ConvertFrom-Json
    Check ($context.referenceScope.source -eq 'work' -and $context.referenceScope.noReferences -and @($context.referenceScope.roots).Count -eq 0) 'event NoReferences completely overrides group sources'
    & $setScope -WorkFolder $work1 -PriorPath $prior -CurrentPath $local|Out-Null
    $scopePath=Join-Path $work1 '.ai\reference-scope.json';$scope=Get-Content -LiteralPath $scopePath -Raw -Encoding utf8|ConvertFrom-Json
    Check ($scope.schemaVersion -eq 'hwpx-reference-scope/v2' -and @($scope.roots|Where-Object pathBase -eq cabinet).Count -eq 1 -and @($scope.roots|Where-Object pathBase -eq work).Count -eq 1) 'event scope stores cabinet siblings and work children relative to their own bases'
    $groupHash=(Get-FileHash -LiteralPath $groupPath).Hash
    & $setDecision -WorkFolder $work1 -Key filename -Text 'This event has a special name' -ConfirmedByUser|Out-Null
    & $setDecision -WorkFolder $work1 -Key exam-method -Disabled -ConfirmedByUser|Out-Null
    $context=(& $get -WorkFolder $work1)|ConvertFrom-Json
    Check (@($context.decisions|Where-Object {$_.key -eq 'filename' -and $_.origin -eq 'work'}).Count -eq 1 -and @($context.decisions|Where-Object key -eq 'exam-method').Count -eq 0 -and (Get-FileHash -LiteralPath $groupPath).Hash -eq $groupHash) 'event override and opt-out do not modify shared decisions'
    $next=(& $get -WorkFolder $work2)|ConvertFrom-Json
    Check (@($next.decisions|Where-Object {$_.key -eq 'filename' -and $_.origin -eq 'group'}).Count -eq 1) 'event exception does not leak into the next event'
    & $setDecision -WorkFolder $work1 -Key filename -RemoveOverride -ConfirmedByUser|Out-Null
    $context=(& $get -WorkFolder $work1)|ConvertFrom-Json
    Check (@($context.decisions|Where-Object {$_.key -eq 'filename' -and $_.origin -eq 'group'}).Count -eq 1) 'removing an exception resumes explicit group inheritance'
    Save $definitionPath @{categories=@(@{code='40';title='Additional duty'})}
    Reject {& $set -GroupId annual -DefinitionPath $definitionPath -ConfirmedByUser} 'linked categories cannot be removed by a shared update'
    Check ((Get-FileHash -LiteralPath $groupPath).Hash -eq $groupHash) 'invalid group update leaves stored definition unchanged'
    Save $definitionPath @{categories=@(@{code='20';title='Exam'},@{code='40';title='Additional duty'})}
    & $set -GroupId annual -DefinitionPath $definitionPath -WorkFolder $other -CategoryCode 40 -ConfirmedByUser|Out-Null
    $context=(& $get -WorkFolder $other)|ConvertFrom-Json
    Check ($context.group.categoryCode -eq '40' -and @($context.decisions|Where-Object key -eq 'exam-method').Count -eq 0) 'new confirmed duty category reuses group-wide decisions only'
    $job=Join-Path $work2 '.ai\jobs\20260930-group-test';New-Item -ItemType Directory -Path $job -Force|Out-Null
    $prepare=Join-Path $shared 'Prepare-WorkWorkflow.ps1'
    $firstDiscovery=(& $prepare -JobPath $job -TaskTitle Exam)|ConvertFrom-Json
    Save $definitionPath @{decisions=@(@{key='filename';text='Improved shared method';appliesTo=@()})}
    & $set -GroupId annual -DefinitionPath $definitionPath -ConfirmedByUser|Out-Null
    $next=(& $get -WorkFolder $work2)|ConvertFrom-Json
    Check ($next.decisions[0].text -eq 'Improved shared method') 'confirmed shared improvement is resolved at the next event read'
    $repeatDiscovery=(& $prepare -JobPath $job -TaskTitle Exam)|ConvertFrom-Json
    Check ($firstDiscovery.ok -and -not $firstDiscovery.reused -and $repeatDiscovery.reused) 'method-only updates reuse unchanged source discovery instead of repeating it'
    foreach($work in @($work1,$work2,$other,$unlinked)){Check ([IO.File]::ReadAllText((Join-Path $work 'Original.txt')) -eq 'unchanged original') 'context updates never rewrite completed documents'}
    $oldScope=@{schemaVersion='hwpx-reference-scope/v1';selectedBy='user';noReferences=$false;roots=@(@{role='current-source';path='Local references'})};Save $scopePath $oldScope
    $context=(& $get -WorkFolder $work1)|ConvertFrom-Json
    Check ($context.referenceScope.status -eq 'ready' -and $context.referenceScope.roots[0].path -eq $local) 'existing v1 relative reference scope remains readable'
    & $setScope -WorkFolder $work1 -PriorPath $prior|Out-Null
    $scope=Get-Content -LiteralPath $scopePath -Raw -Encoding utf8|ConvertFrom-Json;$scope.roots[0].path='..\Explicit external';Save $scopePath $scope
    Reject {& $get -WorkFolder $work1} 'relative scope parent traversal is rejected'
    & $setScope -WorkFolder $work1 -PriorPath $prior|Out-Null
    $savedGroup=Get-Content -LiteralPath $groupPath -Raw -Encoding utf8|ConvertFrom-Json;$savedGroup.referenceScope.roots[0].path='..\Explicit external';Save $groupPath $savedGroup
    Reject {& $get -WorkFolder $work2} 'relative group source parent traversal is rejected'
    $savedGroup.referenceScope.roots[0].path='Prior materials';Save $groupPath $savedGroup
    $renamed=Join-Path $fixture '2026 work'
    if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($cabinet)) -ine $fixture -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($renamed)) -ine $fixture){throw 'Unsafe fixture move'}
    Move-Item -LiteralPath $cabinet -Destination $renamed
    $movedWork1=Join-Path $renamed '21_Exam one';$movedWork2=Join-Path $renamed '22_Exam two'
    $moved1=(& $get -WorkFolder $movedWork1)|ConvertFrom-Json;$moved2=(& $get -WorkFolder $movedWork2)|ConvertFrom-Json
    Check ($moved1.referenceScope.roots[0].path -eq (Join-Path $renamed 'Prior materials') -and $moved2.referenceScope.roots[0].path -eq (Join-Path $renamed 'Prior materials') -and $moved2.workflowPath -eq (Join-Path $renamed '00_Workflow.html')) 'annual cabinet rename preserves event scope, inherited sources and workflow links'
    New-Item -ItemType Directory -Path (Join-Path $cabinet '41_New role\.ai') -Force|Out-Null
    $newWork=Join-Path $cabinet '41_New role';Save (Join-Path $newWork '.ai\work.json') @{title='New role';currentFiles=@()}
    $newContext=(& $get -WorkFolder $newWork)|ConvertFrom-Json
    Check ($newContext.group.status -eq 'none' -and @($newContext.decisions).Count -eq 0) 'new annual cabinet does not inherit last-year group'
    Save $definitionPath @{title='Different role';categories=@(@{code='40';title='Unrelated duties'});referenceScope=@{noReferences=$true;roots=@()};decisions=@()}
    & $set -GroupId new-duty -DefinitionPath $definitionPath -WorkFolder $newWork -CategoryCode 40 -ConfirmedByUser|Out-Null
    $newContext=(& $get -WorkFolder $newWork)|ConvertFrom-Json
    Check ($newContext.status -eq 'ready' -and $newContext.group.title -eq 'Different role' -and $null -eq $newContext.group.year) 'new role and category require no fixed year or exam taxonomy'
    $groupPath=Join-Path $renamed '.ai\work-groups\annual.json';$before=(Get-FileHash -LiteralPath $groupPath).Hash
    & $get -WorkFolder $movedWork2|Out-Null
    Check ((Get-FileHash -LiteralPath $groupPath).Hash -eq $before) 'context reads do not mutate shared state'
    @{ok=$true;count=$checks.Count;checks=@($checks);fixtureOnly=$true}|ConvertTo-Json -Depth 6
} finally {
    $full=[IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($full) -ine [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') -or [IO.Path]::GetFileName($full) -notlike 'hwpx-work-groups-*') {throw 'Unsafe fixture cleanup'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
