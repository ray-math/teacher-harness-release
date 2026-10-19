param()
$ErrorActionPreference='Stop'
$ws=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture=Join-Path $ws ('.agent\cache\lifecycle-'+[guid]::NewGuid().ToString('N'))
$shared=Join-Path $fixture '.agent\shared'
$index=Join-Path $fixture '.agent\index'
$cabinet=Join-Path $fixture 'cabinet'
New-Item -ItemType Directory -Path $shared,$index,(Join-Path $shared 'bin') -Force|Out-Null
$checks=0
function Check($ok,$label){if(-not $ok){throw $label};$script:checks++}
try{
 foreach($name in @('WorkStorage.ps1','WorkLayout.ps1','Find-HwpxContext.ps1','Prepare-WorkWorkflow.ps1','Install-PortableCabinet.ps1','Initialize-PortableCabinet.ps1','Update-HumanWorkConsole.ps1','Register-HumanWorkOpenProtocol.ps1','HumanWorkOpenLauncher.cs','Open-HumanWorkPath.ps1','DocumentScope.ps1','DocumentBasis.ps1','Resolve-TeacherHarnessConfig.ps1','Receive-TeacherHarnessInputs.ps1','Start-HwpxWork.ps1','Publish-HumanResult.ps1','Get-PriorWorkLayout.ps1','Sync-HumanSourcePreservation.ps1','New-HwpxJob.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared}
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'bin\HumanWorkOpenLauncher.exe') -Destination (Join-Path $shared 'bin')
 $config=Get-Content (Join-Path $ws '.agent\index\delivery-system.json') -Raw -Encoding utf8|ConvertFrom-Json
 $config.humanCabinet=$cabinet
 $config|Add-Member -NotePropertyName priorMaterialsRoot -NotePropertyValue (Join-Path $cabinet '이전자료') -Force
 $config|ConvertTo-Json -Depth 12|Set-Content (Join-Path $index 'delivery-system.json') -Encoding utf8
 $first=(& (Join-Path $shared 'Install-PortableCabinet.ps1') -NoRegister)|ConvertFrom-Json
 Check ($first.ok -and -not $first.reused) 'Empty cabinet bootstrap'
 Check (-not(Test-Path -LiteralPath (Join-Path $cabinet '이전자료'))) 'Installation does not create a default prior-material tree'
 $installedConfig=Get-Content -LiteralPath (Join-Path $cabinet '.agent\index\delivery-system.json') -Raw -Encoding utf8|ConvertFrom-Json
 Check (-not($installedConfig.PSObject.Properties.Name -contains 'priorMaterialsRoot')) 'Portable configuration does not retain an automatic prior-material root'
 Check (([IO.File]::GetAttributes((Join-Path $cabinet '.agent')) -band [IO.FileAttributes]::Hidden) -ne 0) 'Runtime folder hidden on Windows'
 $cabinetHome=Join-Path $cabinet 'StartHere.html'
 $stamp=(Get-Item $cabinetHome).LastWriteTimeUtc
 $second=(& (Join-Path $shared 'Install-PortableCabinet.ps1') -NoRegister)|ConvertFrom-Json
 Check ($second.reused -and (Get-Item $cabinetHome).LastWriteTimeUtc -eq $stamp) 'Repeat installation does not regenerate home'
 $runtimeFile=Join-Path $cabinet '.agent\shared\Open-HumanWorkPath.ps1'
 [IO.File]::AppendAllText($runtimeFile,"`r`n# fixture change")
 $repaired=(& (Join-Path $shared 'Install-PortableCabinet.ps1') -NoRegister)|ConvertFrom-Json
 Check (-not $repaired.reused -and (Get-FileHash $runtimeFile).Hash -eq (Get-FileHash (Join-Path $shared 'Open-HumanWorkPath.ps1')).Hash) 'Modified runtime invalidates reuse and is repaired'
 $selectedPrior=Join-Path $fixture 'user-selected-prior'
 New-Item -ItemType Directory -Path $selectedPrior -Force|Out-Null
 $prior=Join-Path $selectedPrior 'Prior.txt'
 [IO.File]::WriteAllText($prior,'last year')
 $args=@{UpdateConsole=$true;Mode='New';TaskTitle='Lifecycle';WorkFolderName='20260908_Lifecycle';JobSlug='lifecycle';CreatedDate='20260908';IntakeSummary='test';DecisionReason='new cycle';UserProvidedFile=@($prior);ReferenceFile=@($prior)}
 $start=(& (Join-Path $shared 'Start-HwpxWork.ps1') @args)|ConvertFrom-Json
 Check (Test-Path -LiteralPath (Join-Path $start.workRoot '.ai\sources.json')) 'New intake creates registered work'
 Check (([IO.File]::GetAttributes((Join-Path $start.workRoot '.ai')) -band [IO.FileAttributes]::Hidden) -ne 0) 'New work metadata hidden on Windows'
 $workConsole=Join-Path $start.workRoot '업무현황.html'
 Remove-Item -LiteralPath $workConsole
 $staleRoot=Join-Path $cabinet '20260908_removed'
 @{workFolders=@(@{workFolder=$start.workRoot;console=$workConsole;targets=@()},@{workFolder=$staleRoot;console=(Join-Path $staleRoot '업무현황.html');targets=@()})}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $index 'human-open-targets.json') -Encoding utf8
 [IO.File]::AppendAllText($runtimeFile,"`r`n# repair stale registration fixture")
 $staleRepair=(& (Join-Path $shared 'Install-PortableCabinet.ps1') -NoRegister)|ConvertFrom-Json
 Check ($staleRepair.ok -and -not(Test-Path -LiteralPath $workConsole) -and -not(Test-Path -LiteralPath $staleRoot)) 'Runtime repair preserves a missing optional console and skips removed work'
 & (Join-Path $shared 'Update-HumanWorkConsole.ps1') -WorkFolder $start.workRoot|Out-Null
 $again=(& (Join-Path $shared 'Start-HwpxWork.ps1') @args)|ConvertFrom-Json
 Check $again.reused 'Identical intake reuses successful receipt'
 $job=$start.jobPath
 $draft=Join-Path $job 'wip\docs\Result.txt'
 [IO.File]::WriteAllText($draft,'this year')
 & (Join-Path $shared 'Publish-HumanResult.ps1') -Stage Review -TaskTitle Lifecycle -CreatedDate 20260908 -SourceFile $draft -ExplicitTextArtifact|Out-Null
 Check ((Get-Content -LiteralPath (Join-Path $start.workRoot 'Result.txt') -Raw) -eq 'this year') 'Review publishes revised copy'
 Check ((Get-Content -LiteralPath $prior -Raw) -eq 'last year') 'Prior input remains unchanged'
 $discovery=(& (Join-Path $shared 'Prepare-WorkWorkflow.ps1') -JobPath $job -TaskTitle Lifecycle -SeedFile $prior)|ConvertFrom-Json
 Check ($discovery.candidates -gt 0) 'Prior-source discovery finds supplied seed'
 $repeatDiscovery=(& (Join-Path $shared 'Prepare-WorkWorkflow.ps1') -JobPath $job -TaskTitle Lifecycle -SeedFile $prior)|ConvertFrom-Json
 Check $repeatDiscovery.reused 'Unchanged discovery reused'
 $planFile=Join-Path $job 'wip\workflow-test.json'
 @{taskTitle='Lifecycle';steps=@(@{period='September';action='Review prior plan';basis='prior';sourcePath=$prior;sourceSha256=(Get-FileHash $prior).Hash;evidence='last year';locator='line 1'})}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $planFile -Encoding utf8
 & (Join-Path $shared 'Prepare-WorkWorkflow.ps1') -UpdateConsole -JobPath $job -TaskTitle Lifecycle -PlanPath $planFile -WorkFolder $start.workRoot|Out-Null
 Check ((Get-Content (Join-Path $start.workRoot '업무현황.html') -Raw -Encoding utf8).Contains('올해 확인 필요')) 'Prior workflow visibly marked tentative'
 $invalid=Get-Content $planFile -Raw -Encoding utf8|ConvertFrom-Json
 $invalid.steps[0].sourceSha256='0'*64
 $invalid|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $planFile -Encoding utf8
 $blocked=$false
 try{& (Join-Path $shared 'Prepare-WorkWorkflow.ps1') -JobPath $job -TaskTitle Lifecycle -PlanPath $planFile -WorkFolder $start.workRoot|Out-Null}catch{$blocked=$true}
 Check $blocked 'Unregistered evidence hash rejected'
 Check (-not(Test-Path -LiteralPath (Join-Path $cabinet '업무현황.html'))) 'No root index recreated'
 $follow=@{Mode='FollowUp';TaskTitle='Lifecycle';JobSlug='lifecycle';CreatedDate='20260908';IntakeSummary='revise';DecisionReason='follow up'}
 & (Join-Path $shared 'Start-HwpxWork.ps1') @follow|Out-Null
 [IO.File]::WriteAllText($draft,'updated this year')
 & (Join-Path $shared 'Publish-HumanResult.ps1') -Stage Final -TaskTitle Lifecycle -CreatedDate 20260908 -SourceFile $draft -ExplicitTextArtifact|Out-Null
 Check ((Get-Content -LiteralPath (Join-Path $start.workRoot 'Result.txt') -Raw) -eq 'updated this year') 'Follow-up and Final publish from registered human revision'
 Check (@(Get-ChildItem -LiteralPath $start.workRoot -Filter 'Result_fix*.txt' -File).Count -gt 0) 'Replaced current result retained beside current file'
 Check (-not(Test-Path -LiteralPath (Join-Path $start.workRoot 'previous_versions'))) 'Intake and publication create no previous-versions folder'
 [pscustomobject]@{ok=$true;checks=$checks;firstInstallSeconds=$first.seconds;repeatInstallSeconds=$second.seconds;documentType='synthetic TXT; Hanword gates not bypassed or exercised'}|ConvertTo-Json
}finally{
 if([IO.Path]::GetDirectoryName($fixture) -ine (Join-Path $ws '.agent\cache') -or [IO.Path]::GetFileName($fixture) -notlike 'lifecycle-*'){throw 'Unsafe cleanup'}
 Remove-Item -LiteralPath $fixture -Recurse -Force
}
