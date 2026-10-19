[CmdletBinding()]
param([string]$ReceiptPath='')
$ErrorActionPreference='Stop'
$ws=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixtureParent=Join-Path $env:TEMP 'hwpx-harness-20260930'
$fixture=Join-Path $fixtureParent ('workflow-layout-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[string]]::new()
function Check($value,$label){if(-not $value){throw "FAIL: $label"};$checks.Add($label)}
function Save($path,$data){$data|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $path -Encoding UTF8}
function Reject($action){try{& $action|Out-Null}catch{return $true};return $false}
function Step($id,$kind,$name){@{id=$id;period='사용자 지정 착수 순서';title=$name;action='요청한 업무를 처리한다.';items=@(@{id='perform';text='요청한 업무를 처리한다.'});basis='user';evidence='사용자가 제공한 업무 목록';locator='현재 요청의 단계 목록';storage=@{kind=$kind;name=$name}}}
try {
 $shared=Join-Path $fixture '.agent/shared';$index=Join-Path $fixture '.agent/index';$cabinet=Join-Path $fixture 'cabinet';$work=Join-Path $cabinet '20270901_새 담당 업무'
 $job=Join-Path $work '.ai/jobs/20270901-workflow'
 foreach($p in @($shared,$index,$job,(Join-Path $work '.ai'))){New-Item -ItemType Directory -Path $p -Force|Out-Null}
 foreach($name in @('WorkStorage.ps1','WorkLayout.ps1','WorkReferenceScope.ps1','Prepare-WorkWorkflow.ps1','Update-HumanWorkConsole.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared}
 $config=Get-Content -LiteralPath (Join-Path $ws '.agent/index/delivery-system.json') -Raw -Encoding UTF8|ConvertFrom-Json;$config.humanCabinet=$cabinet
 Save (Join-Path $index 'delivery-system.json') $config
 $portableShared=Join-Path $cabinet '.agent/shared';$portableIndex=Join-Path $cabinet '.agent/index'
 foreach($p in @($portableShared,$portableIndex)){New-Item -ItemType Directory -Path $p -Force|Out-Null}
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -Destination $portableShared
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'WorkStorage.ps1') -Destination $portableShared
 Save (Join-Path $portableIndex 'delivery-system.json') $config
 Save (Join-Path $job 'inputs.json') @{delivery=@{workRoot=$work};sources=@()}
 Save (Join-Path $work '.ai/sources.json') @{sources=@()}
 $knownRevision='보존_fix01_20270901-010101.csv';$unknownRevision='미등록_fix01_20270901-010101.csv'
 foreach($name in @($knownRevision,$unknownRevision)){[IO.File]::WriteAllText((Join-Path $work $name),'synthetic history')}
 $meta=Join-Path $work '.ai/work.json';Save $meta @{title='새 담당 업무';folderName='20270901_새 담당 업무';currentFiles=@();revisionHistory=@(@{relativePath=$knownRevision;revisionOf='보존.csv'});layout=@{supportFolders=@()}}
 $plan=Join-Path $job 'plan.json';$runner=Join-Path $shared 'Prepare-WorkWorkflow.ps1'
 $first=Step 'collect' 'folder' '자료 취합·확인';$last=Step 'report' 'file' '결과 보고 기안.odt'
 Save $plan @{taskTitle='새 담당 업무';steps=@($first,$last)}
 & $runner -UpdateConsole -JobPath $job -TaskTitle '새 담당 업무' -PlanPath $plan -WorkFolder $work|Out-Null
 $state=Get-Content -LiteralPath $meta -Raw -Encoding UTF8|ConvertFrom-Json
 Check (Test-Path -LiteralPath (Join-Path $work '01_자료 취합·확인') -PathType Container) 'user workflow creates numbered action folder without prior-year source'
 Check ($state.workflow.steps[1].storage.relativePath -eq '02_결과 보고 기안.odt' -and -not(Test-Path -LiteralPath (Join-Path $work '02_결과 보고 기안.odt'))) 'singleton records a numbered file destination without a dummy file'
 $html=Get-Content -LiteralPath (Join-Path $work '업무현황.html') -Raw -Encoding UTF8
 Check ($html.Contains('사용자 지정 순서') -and $html.Contains('collect/perform')) 'console distinguishes user order and retains stable check ids'
 Check (-not $html.Contains('_작업중') -and -not $html.Contains('inputs.json')) 'work-local job metadata and drafts are excluded from console links'
 $decoded=[Net.WebUtility]::HtmlDecode($html)
 Check ($decoded.Contains($knownRevision+' · 이전 버전') -and -not $decoded.Contains($unknownRevision+' · 이전 버전')) 'console marks only exactly registered fix files as history'
 $proof=Join-Path $work '01_자료 취합·확인/보존.csv';[IO.File]::WriteAllText($proof,'same bytes');$hash=(Get-FileHash -LiteralPath $proof).Hash
 $middle=Step 'inspect' 'folder' '추가 검토·확인'
 Save $plan @{taskTitle='새 담당 업무';steps=@($first,$middle,$last)}
 & $runner -UpdateConsole -JobPath $job -TaskTitle '새 담당 업무' -PlanPath $plan -WorkFolder $work|Out-Null
 $state=Get-Content -LiteralPath $meta -Raw -Encoding UTF8|ConvertFrom-Json
 Check ($state.workflow.steps[1].storage.relativePath -eq '01-01_추가 검토·확인' -and $state.workflow.steps[2].storage.relativePath -eq '02_결과 보고 기안.odt') 'middle task insertion preserves existing step paths'
 Check ((Get-FileHash -LiteralPath $proof).Hash -eq $hash -and $state.workflow.steps[0].id -eq 'collect') 'existing document content and stable step identity preserved'
 $metaBefore=(Get-FileHash -LiteralPath $meta).Hash
 $middle.storage.name='../escape';Save $plan @{taskTitle='새 담당 업무';steps=@($first,$middle,$last)}
 Check (Reject {& $runner -UpdateConsole -JobPath $job -TaskTitle '새 담당 업무' -PlanPath $plan -WorkFolder $work}) 'unsafe folder path rejected'
 Check ((Get-FileHash -LiteralPath $meta).Hash -eq $metaBefore) 'rejection leaves registered workflow unchanged'
 $middle.storage.name='추가 검토·확인';$last.storage.name='renamed.odt';Save $plan @{taskTitle='새 담당 업무';steps=@($first,$middle,$last)}
 Check (Reject {& $runner -UpdateConsole -JobPath $job -TaskTitle '새 담당 업무' -PlanPath $plan -WorkFolder $work}) 'silent renaming of an existing destination rejected'
 $last.storage.name='결과 보고 기안.odt';$extra=Step 'later' 'folder' '후속 정리';Save $plan @{taskTitle='새 담당 업무';steps=@($first,$middle,$last,$extra)}
 'param($WorkFolder);throw "Injected layout generation failure"'|Set-Content -LiteralPath (Join-Path $shared 'Update-HumanWorkConsole.ps1') -Encoding UTF8
 Check (Reject {& $runner -UpdateConsole -JobPath $job -TaskTitle '새 담당 업무' -PlanPath $plan -WorkFolder $work}) 'console failure aborts layout application'
 Check (-not(Test-Path -LiteralPath (Join-Path $work '03_후속 정리')) -and (Get-FileHash -LiteralPath $meta).Hash -eq $metaBefore) 'failure rolls back new empty folders and exact workflow bytes'
 Check (-not(Test-Path -LiteralPath (Join-Path $fixture '.agent/jobs'))) 'school workflow creates no agent job or school document copy'
 Check (-not(Test-Path -LiteralPath (Join-Path $work 'previous_versions'))) 'workflow creates no separate previous-versions folder'
 $report=@{ok=$true;checks=@($checks);powershell=$PSVersionTable.PSVersion.ToString();verification='isolated synthetic workflow layout and console'}
 if($ReceiptPath){Save $ReceiptPath $report};$report|ConvertTo-Json -Depth 5
} finally {
 $full=[IO.Path]::GetFullPath($fixture);$cache=[IO.Path]::GetFullPath($fixtureParent)
 if([IO.Path]::GetDirectoryName($full) -ne $cache -or [IO.Path]::GetFileName($full) -notlike 'workflow-layout-*'){throw 'Unsafe test cleanup'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
