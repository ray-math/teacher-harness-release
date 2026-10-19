[CmdletBinding()]
param([string]$ReceiptPath='')
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixtureParent=Join-Path $env:TEMP 'hwpx-harness-20260930'
$fixture=Join-Path $fixtureParent ('explicit-prior-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Ok,[string]$Name){if(-not $Ok){throw "FAIL: $Name"};$checks.Add($Name)}
function Save($Path,$Value){$Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $Path -Encoding utf8}
try{
 $shared=Join-Path $fixture '.agent\shared';$index=Join-Path $fixture '.agent\index';$cabinet=Join-Path $fixture 'cabinet'
 $work=Join-Path $cabinet '20260929_Explicit';$prior=Join-Path $fixture 'selected prior';$automatic=Join-Path $fixture 'automatic prior'
 $legacy=Join-Path $fixture 'source';$history=Join-Path $work 'previous_versions';$references=Join-Path $work '참고자료';$other=Join-Path $cabinet '20260930_Explicit old'
 foreach($path in @($shared,$index,$work,$prior,$automatic,$legacy,$history,$references,$other)){New-Item -ItemType Directory -Path $path -Force|Out-Null}
 foreach($name in @('Find-HwpxContext.ps1','Get-PriorWorkLayout.ps1','WorkStorage.ps1','WorkRegistry.ps1','WorkReferenceScope.ps1','Set-WorkReferenceScope.ps1','Prepare-WorkWorkflow.ps1','WorkLayout.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared}
 Save (Join-Path $index 'delivery-system.json') @{humanCabinet=$cabinet;incomingRoot=$automatic;priorMaterialsRoot=$automatic;archiveFolderName='previous_versions';metadataFolderName='.ai';workMetadataName='work.json';consoleFileName='업무현황.html';defaultEvidenceFolderName='업무근거';defaultCollectionFolderName='취합자료';defaultReferenceFolderName='참고자료'}
 $metadata=Join-Path $work '.ai';New-Item -ItemType Directory -Path $metadata -Force|Out-Null
 Save (Join-Path $metadata 'work.json') @{title='Explicit';folderName='20260929_Explicit';currentFiles=@()}
 $sources=@($prior,$automatic,$legacy,$history,$references,$other)
 foreach($path in $sources){[IO.File]::WriteAllText((Join-Path $path 'Explicit plan.txt'),'unselected prior material')}
 $find=Join-Path $shared 'Find-HwpxContext.ps1'
 $without=(& $find -TaskTitle Explicit)|ConvertFrom-Json
 Check (@($without.candidates).Count -eq 0) 'omitted prior folders do not scan configured prior, legacy source, work history, reference folder or sibling work'
 Check ($without.status -eq 'needs_input') 'unknown source selection asks for input'
 $with=(& $find -TaskTitle Explicit -PriorFolder $prior)|ConvertFrom-Json
 Check (@($with.candidates).Count -eq 1 -and $with.candidates[0].path -eq (Join-Path $prior 'Explicit plan.txt')) 'only the user-selected prior folder contributes a prior candidate'
 Check (@($with.priorFolders).Count -eq 1 -and $with.priorFolders[0] -eq $prior) 'discovery receipt records the selected prior directory'
 $unregistered=(& $find -TaskTitle 'Explicit old')|ConvertFrom-Json
 Check (@($unregistered.candidates).Count -eq 0) 'an unregistered matching old folder is not assumed to be the current work'
 $layout=(& (Join-Path $shared 'Get-PriorWorkLayout.ps1') -TaskTitle Explicit)|ConvertFrom-Json
 Check (@($layout.candidates).Count -eq 0) 'layout survey without a supplied folder reads no cabinet work'
 $layout=(& (Join-Path $shared 'Get-PriorWorkLayout.ps1') -TaskTitle Explicit -PriorFolder $other)|ConvertFrom-Json
 Check (@($layout.candidates).Count -eq 1 -and $layout.candidates[0].path -eq $other) 'layout survey reads the explicitly selected work folder'
 foreach($path in $sources){Check ([IO.File]::ReadAllText((Join-Path $path 'Explicit plan.txt')) -eq 'unselected prior material') 'prior source remains unchanged'}
 $numbered=Join-Path $work '01_Review';$metadata=Join-Path $work '.ai'
 New-Item -ItemType Directory -Path $numbered,$metadata -Force|Out-Null
 $current=Join-Path $numbered 'Explicit 계획.hwpx';$nestedFix=Join-Path $numbered 'Explicit 계획_fix01_20260929-010101.hwpx';$rootFix=Join-Path $work 'Explicit 계획_fix01_20260929-010101.hwpx'
 foreach($path in @($current,$nestedFix,$rootFix)){[IO.File]::WriteAllText($path,'synthetic filename discovery only')}
 Save (Join-Path $metadata 'work.json') @{title='Explicit';folderName='20260929_Explicit';currentFiles=@('01_Review/Explicit 계획.hwpx');revisionHistory=@(@{relativePath='01_Review/Explicit 계획_fix01_20260929-010101.hwpx'},@{relativePath='Explicit 계획_fix01_20260929-010101.hwpx'})}
 $nested=(& $find -TaskTitle Explicit)|ConvertFrom-Json
 Check (@($nested.candidates).Count -eq 1 -and $nested.candidates[0].path -eq $current -and $nested.candidates[0].role -eq 'human-current' -and $nested.candidates[0].formCandidate) 'registered numbered-folder current form retains authority and recorded fix files are not automatically discovered'
 $selectedFix=(& $find -TaskTitle Explicit -SeedFile $nestedFix)|ConvertFrom-Json
 Check (@($selectedFix.candidates|Where-Object path -eq $nestedFix).Count -eq 1) 'a specifically selected historical file can still be reviewed'
 Save (Join-Path $metadata 'work.json') @{title='Explicit';folderName='20260929_Explicit';currentFiles=@()}
 $job=Join-Path $metadata 'jobs\20260930-scope-test';New-Item -ItemType Directory -Path $job -Force|Out-Null
 $prepare=Join-Path $shared 'Prepare-WorkWorkflow.ps1'
 $unset=(& $prepare -JobPath $job -TaskTitle Explicit)|ConvertFrom-Json
 Check ($unset.status -eq 'needs_input' -and -not (Test-Path -LiteralPath (Join-Path $job 'wip\workflow\plan-template.json'))) 'unselected sources never produce a successful empty workflow template'
 $setScope=Join-Path $shared 'Set-WorkReferenceScope.ps1'
 & $setScope -WorkFolder $work -PriorPath $references|Out-Null
 $saved=Get-Content -LiteralPath (Join-Path $metadata 'reference-scope.json') -Raw -Encoding utf8|ConvertFrom-Json
 Check ($saved.roots[0].path -eq '참고자료') 'in-work source path is stored relative to the work folder'
 foreach($name in @('.ai','.agent','.agents','previous_versions','HiddenChild','SystemChild')){
  $child=Join-Path $references $name;New-Item -ItemType Directory -Path $child -Force|Out-Null
  [IO.File]::WriteAllText((Join-Path $child 'Explicit plan.txt'),'excluded internal material')
  if($name -eq 'HiddenChild'){[IO.File]::SetAttributes($child,[IO.FileAttributes]::Directory -bor [IO.FileAttributes]::Hidden)}
  if($name -eq 'SystemChild'){[IO.File]::SetAttributes($child,[IO.FileAttributes]::Directory -bor [IO.FileAttributes]::System)}
 }
 [IO.File]::WriteAllText((Join-Path $references 'Explicit plan_fix01_20260930-010101.txt'),'revision')
 $selected=(& $find -TaskTitle Explicit -WorkFolder $work)|ConvertFrom-Json
 Check ($selected.status -eq 'ready' -and @($selected.candidates).Count -eq 1 -and $selected.candidates[0].path -eq (Join-Path $references 'Explicit plan.txt')) 'saved selection prunes internal hidden system and revision entries recursively'
 $discovery=(& $prepare -JobPath $job -TaskTitle Explicit)|ConvertFrom-Json
 $repeat=(& $prepare -JobPath $job -TaskTitle Explicit)|ConvertFrom-Json
 Check ($discovery.ok -and -not $discovery.reused -and $repeat.reused) 'unchanged scope and sources reuse discovery'
 & $setScope -WorkFolder $work -CurrentPath $references|Out-Null
 $changed=(& $prepare -JobPath $job -TaskTitle Explicit)|ConvertFrom-Json
 Check ($changed.ok -and -not $changed.reused) 'changed reference role invalidates discovery fingerprint'
 & $setScope -WorkFolder $work -NoReferences|Out-Null
 $empty=(& $find -TaskTitle Explicit)|ConvertFrom-Json
 Check ($empty.status -eq 'ready' -and $empty.referenceScope.noReferences -and @($empty.candidates).Count -eq 0) 'explicit NoReferences is a valid empty selection'
 & $setScope -WorkFolder $work -PriorPath $prior|Out-Null
 $moved=Join-Path $fixture 'renamed selected prior'
 if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($prior)) -ine $fixture -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($moved)) -ine $fixture){throw 'Unsafe fixture move'}
 Move-Item -LiteralPath $prior -Destination $moved
 $missing=(& $prepare -JobPath $job -TaskTitle Explicit)|ConvertFrom-Json
 Check ($missing.status -eq 'needs_input' -and $missing.reason -eq 'selected_reference_path_missing') 'missing saved source prompts again instead of reusing a receipt'
 $blocked=$false;try{& $find -TaskTitle Explicit -OutputPath (Join-Path $fixture '.agent\cache\discovery.json')|Out-Null}catch{$blocked=$true}
 Check $blocked 'discovery cannot write into the shared harness cache'
 $report=[ordered]@{ok=$true;count=$checks.Count;checks=@($checks);fixtureOnly=$true};$json=$report|ConvertTo-Json -Depth 6
 if($ReceiptPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReceiptPath),$json,[Text.UTF8Encoding]::new($true))};$json
}finally{
 if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fixture)) -ine [IO.Path]::GetFullPath($fixtureParent) -or [IO.Path]::GetFileName($fixture) -notlike 'explicit-prior-*'){throw 'Unsafe test cleanup'}
 if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
