[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$ws=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$cache=Join-Path $env:TEMP 'hwpx-harness-20260930'
$fixture=Join-Path $cache ('workflow-safety-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[string]]::new()
$failures=[Collections.Generic.List[string]]::new()
function Assert([bool]$Condition,[string]$Label){if($Condition){$checks.Add($Label)}else{$failures.Add($Label)}}
function Write-Json($Path,$Value){$Value|ConvertTo-Json -Depth 25|Set-Content -LiteralPath $Path -Encoding utf8}
try {
 $shared=Join-Path $fixture '.agent\shared';$index=Join-Path $fixture '.agent\index'
 $cabinet=Join-Path $fixture 'cabinet';$work=Join-Path $cabinet '20260908_test'
 $job=Join-Path $work '.ai\jobs\20260929-test'
 foreach($dir in @($shared,$index,$job,(Join-Path $work '.ai'))){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
 $runner=Join-Path $shared 'Prepare-WorkWorkflow.ps1'
 foreach($name in @('Prepare-WorkWorkflow.ps1','WorkStorage.ps1','WorkLayout.ps1','WorkReferenceScope.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared}
 Write-Json (Join-Path $index 'delivery-system.json') @{humanCabinet=$cabinet;openTargetManifest='.agent\index\human-open-targets.json'}
 @'
param($TaskTitle,$WorkFolder,$Keyword,$SeedFile,$PriorFolder,$Limit)
@{status='ready';candidates=@()}|ConvertTo-Json
'@|Set-Content -LiteralPath (Join-Path $shared 'Find-HwpxContext.ps1') -Encoding utf8
 & $runner -UpdateConsole -JobPath $job -TaskTitle test|Out-Null
 $template=Join-Path $job 'wip\workflow\plan-template.json'
 Assert ((Get-Content -LiteralPath $template -Raw)-match 'workflow-format.md') 'New template references workflow format'
 [IO.File]::WriteAllText($template,'{"taskTitle":"test","steps":[{"action":"edited draft"}]}')
 $draftHash=(Get-FileHash -LiteralPath $template).Hash
 & $runner -UpdateConsole -JobPath $job -TaskTitle test -Refresh|Out-Null
 Assert ((Get-FileHash -LiteralPath $template).Hash -eq $draftHash) 'Refresh preserves edited plan bytes'
 & $runner -UpdateConsole -JobPath $job -TaskTitle changed|Out-Null
 Assert ((Get-FileHash -LiteralPath $template).Hash -eq $draftHash) 'Changed discovery request preserves edited plan bytes'
 $source=Join-Path $fixture 'source.txt';Set-Content -LiteralPath $source -Value 'Evidence' -Encoding utf8
 $hash=(Get-FileHash -LiteralPath $source).Hash
 Write-Json (Join-Path $work '.ai\sources.json') @{sources=@(@{path=$source;sha256=$hash})}
 $meta=Join-Path $work '.ai\work.json';Write-Json $meta @{title='test';workflow=@{steps=@(@{action='old'})}}
 $html=Join-Path $work ([string][char]0xc5c5+[char]0xbb34+[char]0xd604+[char]0xd669+'.html')
 [IO.File]::WriteAllText($html,'original console')
 $manifest=Join-Path $index 'human-open-targets.json'
 Write-Json $manifest @{schemaVersion='test';workFolders=@(@{workFolder=$work;targets=@('old')},@{workFolder=(Join-Path $cabinet 'other');targets=@('before')})}
 $plan=Join-Path $fixture 'plan.json'
 $step=@{period='tentative';action="First action`nSecond action";title='Stage title';result='Expected result';basis='prior';sourcePath=$source;sourceSha256=$hash;evidence='Evidence';locator='line 1'}
 Write-Json $plan @{taskTitle='test';steps=@($step)}
 $generator=Join-Path $shared 'Update-HumanWorkConsole.ps1'
 @'
param($WorkFolder)
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$manifest=Join-Path $root '.agent\index\human-open-targets.json'
$m=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json
$m.workFolders[0].targets=@('failed-new')
$m.workFolders[1].targets=@('unrelated-new')
$m|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifest -Encoding utf8
$html=Join-Path $WorkFolder ([string][char]0xc5c5+[char]0xbb34+[char]0xd604+[char]0xd669+'.html')
Set-Content -LiteralPath $html -Value 'failed console' -Encoding utf8
throw 'Injected console failure'
'@|Set-Content -LiteralPath $generator -Encoding utf8
 $metaHash=(Get-FileHash -LiteralPath $meta).Hash;$htmlHash=(Get-FileHash -LiteralPath $html).Hash
 $caught=$false
 try{& $runner -UpdateConsole -JobPath $job -TaskTitle test -PlanPath $plan -WorkFolder $work|Out-Null}catch{$caught=$_.Exception.Message -eq 'Injected console failure';if(-not $caught){Write-Output $_.Exception.Message}}
 Assert $caught 'Generation failure surfaces'
 Assert ((Get-FileHash -LiteralPath $meta).Hash -eq $metaHash) 'Generation failure restores metadata bytes'
 Assert ((Get-FileHash -LiteralPath $html).Hash -eq $htmlHash) 'Generation failure restores console bytes'
 $m=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json
 Assert ($m.workFolders[0].targets[0] -eq 'old') 'Generation failure restores target manifest entry'
 Assert ($m.workFolders[1].targets[0] -eq 'unrelated-new') 'Rollback preserves unrelated manifest updates'
 # A failed first generation must not leave an orphan console or target entry.
 Remove-Item -LiteralPath $html -Force
 Write-Json $manifest @{schemaVersion='test';workFolders=@(@{workFolder=$work;targets=@('old')},@{workFolder=(Join-Path $cabinet 'other');targets=@('before')})}
 try{& $runner -UpdateConsole -JobPath $job -TaskTitle test -PlanPath $plan -WorkFolder $work|Out-Null}catch{}
 Assert (-not (Test-Path -LiteralPath $html)) 'First generation failure removes newly created console'
 'param($WorkFolder)'|Set-Content -LiteralPath $generator -Encoding utf8
 & $runner -UpdateConsole -JobPath $job -TaskTitle test -PlanPath $plan -WorkFolder $work|Out-Null
 $saved=(Get-Content -LiteralPath $meta -Raw|ConvertFrom-Json).workflow.steps[0]
 Assert ($saved.title -eq $step.title -and $saved.result -eq $step.result -and $saved.action -ceq $step.action) 'Optional title/result and multiline action survive application'
 $step.id='review';$step.items=@(@{id='first';text='First action'},@{id='second';text='Second action'})
 $step.confirm='Confirm current scope';$step.references=@(@{path=$step.sourcePath;sha256=$step.sourceSha256})
 Write-Json $plan @{taskTitle='test';steps=@($step)}
 & $runner -UpdateConsole -JobPath $job -TaskTitle test -PlanPath $plan -WorkFolder $work|Out-Null
 $saved=(Get-Content -LiteralPath $meta -Raw|ConvertFrom-Json).workflow.steps[0]
 Assert ($saved.items.Count -eq 2 -and $saved.items[0].id -eq 'first' -and $saved.confirm -eq $step.confirm -and $saved.references.Count -eq 1) 'Checklist identifiers and registered references survive application'
 $step.items[1].id='first';Write-Json $plan @{taskTitle='test';steps=@($step)}
 $caught=$false;try{& $runner -UpdateConsole -JobPath $job -TaskTitle test -PlanPath $plan -WorkFolder $work|Out-Null}catch{$caught=$true}
 Assert $caught 'Duplicate checklist ids rejected'
 $step.items[1].id='second'
 $step.action=@('array','invalid');Write-Json $plan @{taskTitle='test';steps=@($step)}
 $caught=$false;try{& $runner -UpdateConsole -JobPath $job -TaskTitle test -PlanPath $plan -WorkFolder $work|Out-Null}catch{$caught=$true}
 Assert $caught 'Structured action rejected instead of silently flattened'
 $step.action="First action`nSecond action";Write-Json $plan @{taskTitle='test';steps=@($step)}
 $config=Get-Content -LiteralPath (Join-Path $ws '.agent\index\delivery-system.json') -Raw -Encoding utf8|ConvertFrom-Json
 $config.humanCabinet=$cabinet
 Write-Json (Join-Path $index 'delivery-system.json') $config
 $portableShared=Join-Path $cabinet '.agent\shared';$portableIndex=Join-Path $cabinet '.agent\index'
 foreach($dir in @($portableShared,$portableIndex)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
 Write-Json (Join-Path $portableIndex 'delivery-system.json') $config
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -Destination $portableShared -Force
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'WorkStorage.ps1') -Destination $portableShared -Force
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -Destination $generator -Force
 & $runner -UpdateConsole -JobPath $job -TaskTitle test -PlanPath $plan -WorkFolder $work|Out-Null
 Assert ((Test-Path -LiteralPath $html) -and (Get-Content -LiteralPath $html -Raw)-match 'First action') 'Actual console generation succeeds while holding reentrant manifest lock'
 # Mirror the generator's existing portable-runtime delegation and fault after writing.
 $portableShared=Join-Path $cabinet '.agent\shared';$portableIndex=Join-Path $cabinet '.agent\index'
 foreach($dir in @($portableShared,$portableIndex)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
 Write-Json (Join-Path $portableIndex 'delivery-system.json') $config
 $portableManifest=Join-Path $portableIndex 'human-open-targets.json'
 Write-Json $portableManifest @{schemaVersion='test';workFolders=@(@{workFolder=$work;targets=@('portable-old')})}
 @'
param($WorkFolder)
$manifest=Join-Path $PSScriptRoot '..\index\human-open-targets.json'
$m=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json
$m.workFolders[0].targets=@('failed-new')
$m|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $manifest -Encoding utf8
throw 'Injected portable failure'
'@|Set-Content -LiteralPath (Join-Path $portableShared 'Update-HumanWorkConsole.ps1') -Encoding utf8
 $localManifestHash=(Get-FileHash -LiteralPath $manifest).Hash
 try{& $runner -UpdateConsole -JobPath $job -TaskTitle test -PlanPath $plan -WorkFolder $work|Out-Null}catch{}
 $m=Get-Content -LiteralPath $portableManifest -Raw|ConvertFrom-Json
 Assert ($m.workFolders[0].targets[0] -eq 'portable-old') 'Portable delegated generator target entry is restored'
 Assert ((Get-FileHash -LiteralPath $manifest).Hash -eq $localManifestHash) 'Portable rollback does not rewrite workspace manifest'
 $differentMeta=Get-Content -LiteralPath $meta -Raw|ConvertFrom-Json
 $differentMeta.title='different work';Write-Json $meta $differentMeta
 $metaHash=(Get-FileHash -LiteralPath $meta).Hash
 $caught=$false
 try{& $runner -UpdateConsole -JobPath $job -TaskTitle test -PlanPath $plan -WorkFolder $work|Out-Null}catch{$caught=$_.Exception.Message -match 'registered work title'}
 Assert ($caught -and (Get-FileHash -LiteralPath $meta).Hash -eq $metaHash) 'Task title must match registered work before mutation'
 @{ok=($failures.Count -eq 0);passed=@($checks);failed=@($failures)}|ConvertTo-Json -Depth 5
 if($failures.Count){throw "$($failures.Count) workflow safety checks failed"}
} finally {
 $resolved=[IO.Path]::GetFullPath($fixture)
 if($resolved.StartsWith([IO.Path]::GetFullPath($cache)+'\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
