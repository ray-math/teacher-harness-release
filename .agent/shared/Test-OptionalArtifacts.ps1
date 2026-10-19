[CmdletBinding()]
param([string]$ReceiptPath='')
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture=Join-Path $workspace ('.agent/cache/optional-artifacts-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[string]]::new()
function Check($condition,$label){if(-not $condition){throw "FAIL: $label"};$checks.Add($label)}
function Json($value){($value -join [Environment]::NewLine)|ConvertFrom-Json}
function Save($path,$value){$value|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $path -Encoding UTF8}
try {
 $shared=Join-Path $fixture '.agent/shared';$index=Join-Path $fixture '.agent/index';$cabinet=Join-Path $fixture 'cabinet'
 New-Item -ItemType Directory -Path $shared,$index,$cabinet -Force|Out-Null
 foreach($name in @('WorkStorage.ps1','WorkLayout.ps1','DocumentScope.ps1','DocumentBasis.ps1','Resolve-TeacherHarnessConfig.ps1','Receive-TeacherHarnessInputs.ps1','Start-HwpxWork.ps1','New-HwpxJob.ps1','Sync-HumanSourcePreservation.ps1','Publish-HumanResult.ps1','Prepare-WorkWorkflow.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared}
 "throw 'Unexpected console rendering'"|Set-Content -LiteralPath (Join-Path $shared 'Update-HumanWorkConsole.ps1') -Encoding UTF8
 "throw 'Unexpected portable installation'"|Set-Content -LiteralPath (Join-Path $shared 'Install-PortableCabinet.ps1') -Encoding UTF8
 $config=Get-Content -LiteralPath (Join-Path $workspace '.agent/index/delivery-system.json') -Raw -Encoding UTF8|ConvertFrom-Json
 $config.humanCabinet=$cabinet;Save (Join-Path $index 'delivery-system.json') $config
 Save (Join-Path $index 'human-current.json') @{works=@()}
 $intake=@{Mode='New';TaskTitle='Optional artifacts';WorkFolderName='11_Optional artifacts';CreatedDate='20270901';JobSlug='optional-artifacts';IntakeSummary='Synthetic test';DecisionReason='Create requested work only'}
 $first=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') @intake)
 $work=$first.workRoot;$job=$first.jobPath;$html=Join-Path $work '업무현황.html'
 Check ($null -eq $first.console -and -not(Test-Path -LiteralPath $html)) 'Default intake creates no console and returns no console receipt'
 Check (-not(Test-Path -LiteralPath (Join-Path $cabinet '.agent'))) 'Default intake does not install cabinet runtime or opening protocol'
 $repeat=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') @intake)
 Check $repeat.reused 'Intake receipt can be reused without console HTML'
 $record=(Get-Content -LiteralPath (Join-Path $index 'human-current.json') -Raw -Encoding UTF8|ConvertFrom-Json).works[0]
 Check ($null -eq $record.console) 'New work registration has no implicit console'
 $draft=Join-Path $first.workingDocuments '00_result.csv';[IO.File]::WriteAllText($draft,'initial')
 $pub=@{Stage='Review';TaskTitle='Optional artifacts';WorkFolderName=$first.workFolderName;SourceFile=@($draft)}
 $published=Json (& (Join-Path $shared 'Publish-HumanResult.ps1') @pub)
 Check ($null -eq $published.console -and -not(Test-Path -LiteralPath $html)) 'Default publication creates requested document without console'
 $plan=Join-Path $job 'workflow.json';$step=@{id='collect';period='first';title='Collect';action='Collect requested material';basis='user';evidence='Supplied workflow';locator='Current request';storage=@{kind='folder';name='Collect material'}}
 Save $plan @{taskTitle='Optional artifacts';steps=@($step)}
 $workflow=Json (& (Join-Path $shared 'Prepare-WorkWorkflow.ps1') -JobPath $job -TaskTitle 'Optional artifacts' -PlanPath $plan -WorkFolder $work)
 Check ($null -eq $workflow.console -and -not(Test-Path -LiteralPath $html) -and (Test-Path -LiteralPath (Join-Path $work '01_Collect material'))) 'Default workflow applies numbered folders without console'
 Check (-not(Test-Path -LiteralPath (Join-Path $index 'human-open-targets.json'))) 'Default work operations create no opening-target manifest'
 [IO.File]::WriteAllText($html,'Existing user-owned HTML');$before=(Get-FileHash -LiteralPath $html).Hash
 $follow=@{Mode='FollowUp';TaskTitle='Optional artifacts';WorkFolderName=$first.workFolderName;JobPath=$job;IntakeSummary='Revise requested document';DecisionReason='Existing console is not opt-in'}
 $null=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') @follow)
 [IO.File]::WriteAllText($draft,'revised')
 $null=Json (& (Join-Path $shared 'Publish-HumanResult.ps1') @pub)
 $null=Json (& (Join-Path $shared 'Prepare-WorkWorkflow.ps1') -JobPath $job -TaskTitle 'Optional artifacts' -PlanPath $plan -WorkFolder $work)
 Check ((Get-FileHash -LiteralPath $html).Hash -eq $before) 'Existing console bytes stay untouched during ordinary intake, publication and planning'
 $text=Join-Path $first.workingDocuments 'explanation.txt';[IO.File]::WriteAllText($text,'Explanation belongs in chat')
 $blocked=$false;try{& (Join-Path $shared 'Publish-HumanResult.ps1') -Stage Review -TaskTitle 'Optional artifacts' -SourceFile $text|Out-Null}catch{$blocked=$_.Exception.Message -match 'ExplicitTextArtifact.*chat'}
 Check $blocked 'TXT explanations are rejected without an explicit text-artifact request'
 Check (-not(Test-Path -LiteralPath (Join-Path $work 'explanation.txt'))) 'Rejected explanation produces no visible TXT artifact'
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -Destination $shared -Force
 $workflow=Json (& (Join-Path $shared 'Prepare-WorkWorkflow.ps1') -UpdateConsole -JobPath $job -TaskTitle 'Optional artifacts' -PlanPath $plan -WorkFolder $work)
 Check ($workflow.console -eq $html -and (Get-FileHash -LiteralPath $html).Hash -ne $before) 'Explicit workflow console request generates HTML'
 $explicit=Json (& (Join-Path $shared 'Publish-HumanResult.ps1') @pub -UpdateConsole)
 Check ($null -ne $explicit.console) 'Explicit publication console request remains supported'
 # Setup may relocate an existing requested console, but must leave a work with no console alone.
 $noConsole=Join-Path $cabinet '20270901_No console';New-Item -ItemType Directory -Path (Join-Path $noConsole '.ai') -Force|Out-Null
 Save (Join-Path $noConsole '.ai/work.json') @{title='No console';currentFiles=@()}
 $portableShared=Join-Path $cabinet '.agent/shared';$portableIndex=Join-Path $cabinet '.agent/index'
 New-Item -ItemType Directory -Path $portableShared,$portableIndex -Force|Out-Null
 foreach($name in @('WorkStorage.ps1','Initialize-PortableCabinet.ps1','Update-HumanWorkConsole.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $portableShared}
 Save (Join-Path $portableIndex 'delivery-system.json') $config
 & (Join-Path $portableShared 'Initialize-PortableCabinet.ps1') -NoRegister|Out-Null
 Check (-not(Test-Path -LiteralPath (Join-Path $noConsole '업무현황.html')) -and (Test-Path -LiteralPath $html)) 'Explicit setup refreshes existing consoles without creating missing ones'
 $report=@{ok=$true;checks=@($checks);verification='Synthetic document and workflow lifecycle; no actual school documents or registry writes';powershell=$PSVersionTable.PSVersion.ToString()}
 if($ReceiptPath){Save $ReceiptPath $report};$report|ConvertTo-Json -Depth 5
} finally {
 $full=[IO.Path]::GetFullPath($fixture);$cache=[IO.Path]::GetFullPath((Join-Path $workspace '.agent/cache'))
 if([IO.Path]::GetDirectoryName($full) -ine $cache -or [IO.Path]::GetFileName($full) -notlike 'optional-artifacts-*'){throw 'Unsafe test cleanup'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
