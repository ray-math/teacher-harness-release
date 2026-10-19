[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$JobPath,
 [Parameter(Mandatory=$true)][string]$TaskTitle,
 [string[]]$Keyword=@(),[string[]]$SeedFile=@(),[string[]]$PriorFolder=@(),
 [string]$PlanPath='', [string]$WorkFolder='', [switch]$Refresh, [switch]$UpdateConsole
)
$ErrorActionPreference='Stop'
$ws=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
. (Join-Path $PSScriptRoot 'WorkLayout.ps1')
. (Join-Path $PSScriptRoot 'WorkReferenceScope.ps1')
$jobInfo=Get-WorkJobInfo -Workspace $ws -Path $JobPath -RequireJobRoot -RequireExists
$job=$jobInfo.jobRoot
if (-not $WorkFolder) { $WorkFolder=$jobInfo.workRoot }
$work=Assert-WorkStoragePath $WorkFolder
if ($jobInfo.workRoot -ine $work) { throw 'Workflow job belongs to another work folder.' }
$out=Join-Path $job 'wip\workflow'
if(-not $PlanPath){
 $scope=Get-WorkReferenceScope -WorkFolder $work
 $receipt=Join-Path $out 'discovery.json'
 $request=([ordered]@{title=$TaskTitle;workFolder=$work;keywords=@($Keyword);seeds=@($SeedFile|ForEach-Object {[IO.Path]::GetFullPath($_)});priorFolders=@($PriorFolder|ForEach-Object {[IO.Path]::GetFullPath($_)});referenceScopeSha256=$scope.scopeSha256;referenceScopeStatus=$scope.status;referenceScopeReason=$scope.reason}|ConvertTo-Json -Compress)
 if(-not $Refresh -and (Test-Path -LiteralPath $receipt)){
  $old=Get-Content -LiteralPath $receipt -Raw -Encoding utf8|ConvertFrom-Json
  $valid=$old.request -eq $request -and $old.status -eq 'ready'
  foreach($s in $old.sources){if(-not(Test-Path -LiteralPath $s.path) -or (Get-FileHash -LiteralPath $s.path).Hash -ine $s.sha256){$valid=$false}}
  if($valid){@{ok=$true;reused=$true;discovery=$receipt;note='Selected candidates unchanged. Use Refresh to discover added files.'}|ConvertTo-Json;return}
 }
 $found=(& (Join-Path $PSScriptRoot 'Find-HwpxContext.ps1') -TaskTitle $TaskTitle -WorkFolder $work -Keyword $Keyword -SeedFile $SeedFile -PriorFolder $PriorFolder -Limit 12)|ConvertFrom-Json
 if($found.status -ne 'ready'){
  @{ok=$false;status='needs_input';reason=$found.reason;workFolder=$work;referenceScope=$found.referenceScope;next=$found.next}|ConvertTo-Json -Depth 10;return
 }
 New-Item -ItemType Directory -Path $out -Force|Out-Null
 $sources=@(foreach($s in $found.candidates){@{path=$s.path;sha256=(Get-FileHash -LiteralPath $s.path).Hash;role=$s.role;reason='Candidate only; read content before deriving tasks'}})
 @{status='ready';request=$request;createdAt=(Get-Date -Format o);referenceScope=$found.referenceScope;sources=$sources}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $receipt -Encoding utf8
 $templatePath=Join-Path $out 'plan-template.json'
 if(-not (Test-Path -LiteralPath $templatePath)){
  @{taskTitle=$TaskTitle;steps=@();instructions='Use the supplied workflow first and .agents/skills/work-planning/references/workflow-format.md. Read selected documents only for missing steps or evidence. Minimal steps use stable id, title, period, nonempty string action, basis (user/prior/current), evidence, locator and storage {kind: folder/file/none, name when applicable}. Keep existing ids and paths for unchanged tasks. prior/current require registered sourcePath and sourceSha256. Add items, references and confirm only for an explicit console request; action remains a string. Prior dates are tentative; do not invent current schedules or official facts.'}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $templatePath -Encoding utf8
 }
 @{ok=$true;reused=$false;candidates=$sources.Count;discovery=$receipt;next='Read selected sources and fill plan-template.json; apply with PlanPath and WorkFolder.'}|ConvertTo-Json;return
}
New-Item -ItemType Directory -Path $out -Force|Out-Null
$config=Get-Content (Join-Path $ws '.agent/index/delivery-system.json') -Raw -Encoding utf8|ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $ws -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$work=[IO.Path]::GetFullPath($WorkFolder)
if([IO.Path]::GetDirectoryName($work) -ine [IO.Path]::GetFullPath($config.humanCabinet)){throw 'WorkFolder must be a registered direct child.'}
Assert-WorkStoragePath $work|Out-Null
if($jobInfo.storageKind -eq 'work' -and $jobInfo.workRoot -ine $work){throw 'Workflow job belongs to another work folder.'}
$meta=Join-Path $work '.ai\work.json'
$sourcesPath=Join-Path $work '.ai\sources.json'
$registered=(Get-Content -LiteralPath $sourcesPath -Raw -Encoding utf8|ConvertFrom-Json).sources
$plan=Get-Content -LiteralPath $PlanPath -Raw -Encoding utf8|ConvertFrom-Json
if($plan.taskTitle -ne $TaskTitle -or @($plan.steps).Count -eq 0){throw 'Matching title and nonempty evidence-backed steps required.'}
$steps=@(foreach($s in $plan.steps){
 if(-not $s.period -or $s.action -isnot [string] -or [string]::IsNullOrWhiteSpace($s.action) -or $s.evidence -isnot [string] -or -not $s.evidence -or $s.locator -isnot [string] -or -not $s.locator -or $s.basis -notin @('user','prior','current')){throw 'Incomplete step evidence; action must be a nonempty plain string.'}
 if($s.basis -ne 'user'){
  if(-not @($registered|Where-Object {$_.path -ieq $s.sourcePath -and $_.sha256 -ieq $s.sourceSha256}).Count){throw 'Intake must register each selected source and its hash first.'}
  if((Get-FileHash -LiteralPath $s.sourcePath).Hash -ine $s.sourceSha256){throw 'Source changed; review again'}
 }
 $step=@{period=[string]$s.period;action=[string]$s.action;basis=[string]$s.basis;sourcePath=$s.sourcePath;sourceSha256=$s.sourceSha256;evidence=$s.evidence;locator=$s.locator}
 if($s.storage){$step['storage']=$s.storage}
 foreach($field in @('id','title','result','confirm')){
  if($null -ne $s.PSObject.Properties[$field]){
   if($s.$field -isnot [string]){throw "Optional $field must be a plain string."}
   $step[$field]=$s.$field
  }
 }
 if($s.items){
  if([string]::IsNullOrWhiteSpace([string]$s.id)){throw 'Checklist steps require a stable id.'}
  $seen=@{}
  $step.items=@(foreach($item in $s.items){
   if($item.id -isnot [string] -or $item.id -notmatch '^[a-zA-Z0-9_-]+$' -or $item.text -isnot [string] -or [string]::IsNullOrWhiteSpace($item.text) -or $seen.ContainsKey($item.id)){throw 'Checklist items require unique stable ids and nonempty text.'}
   $seen[$item.id]=$true
   @{id=$item.id;text=$item.text}
  })
 }
 if($s.references){
  $step.references=@(foreach($reference in $s.references){
   if(-not @($registered|Where-Object {$_.path -ieq $reference.path -and $_.sha256 -ieq $reference.sha256}).Count){throw 'Register workflow references through intake first.'}
   if((Get-FileHash -LiteralPath $reference.path).Hash -ine $reference.sha256){throw 'Workflow reference changed; review again.'}
   @{path=$reference.path;sha256=$reference.sha256}
  })
 }
 $step
})
$stepIds=@{}
foreach($step in $steps){if($step.id){if($step.id -notmatch '^[a-zA-Z0-9_-]+$' -or $stepIds.ContainsKey($step.id)){throw 'Step ids must be unique stable identifiers.'};$stepIds[$step.id]=$true}}
$consolePath=Join-Path $work '업무현황.html'
$manifestRoot=$ws
$manifestConfig=$config
# Match Update-HumanWorkConsole's portable-runtime delegation when selecting the
# shared manifest that generation can actually change.
$portableGenerator=Join-Path $config.humanCabinet '.agent\shared\Update-HumanWorkConsole.ps1'
if($UpdateConsole -and $ws -ine [string]$config.humanCabinet -and (Test-Path -LiteralPath $portableGenerator)){
 $manifestRoot=[IO.Path]::GetFullPath([string]$config.humanCabinet)
 $manifestConfig=Get-Content -LiteralPath (Join-Path $manifestRoot '.agent\index\delivery-system.json') -Raw -Encoding utf8|ConvertFrom-Json
}
$manifestPath=[IO.Path]::GetFullPath((Join-Path $manifestRoot ([string]$manifestConfig.openTargetManifest)))
# The console uses this same reentrant mutex. Hold it across snapshot/apply/rollback
# so another console update cannot be overwritten by restoring this work's entry.
$mutex=[Threading.Mutex]::new($false,'Local\HwpxHumanOpenTargets')
$lockTaken=$false
try {
 $lockTaken=$mutex.WaitOne([TimeSpan]::FromSeconds(15))
 if(-not $lockTaken){throw 'Timed out while applying workflow.'}
 $metaBefore=[IO.File]::ReadAllBytes($meta)
 $data=[Text.Encoding]::UTF8.GetString($metaBefore).TrimStart([char]0xfeff)|ConvertFrom-Json
 if([string]::IsNullOrWhiteSpace([string]$data.title) -or $data.title -ne $TaskTitle){throw 'TaskTitle must match the registered work title.'}
 $layout=Resolve-WorkWorkflowLayout -WorkRoot $work -Steps $steps -ExistingSteps @($data.workflow.steps)
 $steps=$layout.steps
 $createdFolders=[Collections.Generic.List[string]]::new()
 $consoleExisted=$UpdateConsole -and (Test-Path -LiteralPath $consolePath -PathType Leaf)
 $consoleBefore=if($consoleExisted){[IO.File]::ReadAllBytes($consolePath)}else{$null}
 $manifestBefore=if($UpdateConsole -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)){Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8|ConvertFrom-Json}else{$null}
 $oldEntries=@($manifestBefore.workFolders|Where-Object {$_.workFolder -ieq $work})
 [IO.File]::WriteAllBytes((Join-Path $out ('work-before-'+[guid]::NewGuid().ToString('N')+'.json')),$metaBefore)
 try {
  foreach($relative in $layout.foldersToCreate){$folder=Get-WorkCurrentTarget -WorkRoot $work -RelativePath $relative;New-Item -ItemType Directory -Path $folder|Out-Null;$createdFolders.Add($folder)}
  if(-not $data.layout){$data|Add-Member -NotePropertyName layout -NotePropertyValue ([pscustomobject]@{}) -Force}
  $data.layout|Add-Member -NotePropertyName supportFolders -NotePropertyValue @(@($layout.supportFolders)+@($data.layout.supportFolders)|Where-Object {$_}|Select-Object -Unique) -Force
  $data|Add-Member -NotePropertyName workflow -NotePropertyValue @{version=1;updatedAt=(Get-Date -Format o);steps=$steps} -Force
  $data|ConvertTo-Json -Depth 25|Set-Content -LiteralPath $meta -Encoding utf8
  if($UpdateConsole){& (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -WorkFolder $work|Out-Null}
 } catch {
  $applyError=$_
  $rollbackErrors=[Collections.Generic.List[string]]::new()
  foreach($folder in $createdFolders){try{if((Test-Path -LiteralPath $folder) -and @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0){Remove-Item -LiteralPath $folder -Force}}catch{$rollbackErrors.Add('folder: '+$_.Exception.Message)}}
  try{[IO.File]::WriteAllBytes($meta,$metaBefore)}catch{$rollbackErrors.Add('metadata: '+$_.Exception.Message)}
  if($UpdateConsole){try{
   if($consoleExisted){[IO.File]::WriteAllBytes($consolePath,$consoleBefore)}
   elseif(Test-Path -LiteralPath $consolePath -PathType Leaf){Remove-Item -LiteralPath $consolePath -Force}
  }catch{$rollbackErrors.Add('console: '+$_.Exception.Message)}
  try{
   # Read the latest manifest; never restore an entire stale shared snapshot.
   if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
    $latest=Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8|ConvertFrom-Json
    $entries=[Collections.Generic.List[object]]::new()
    $restored=$false
    foreach($entry in @($latest.workFolders)){
     if($entry.workFolder -ieq $work){
      if(-not $restored){foreach($oldEntry in $oldEntries){$entries.Add($oldEntry)};$restored=$true}
     }else{$entries.Add($entry)}
    }
    if(-not $restored){foreach($oldEntry in $oldEntries){$entries.Add($oldEntry)}}
    $latest|Add-Member -NotePropertyName workFolders -NotePropertyValue @($entries) -Force
    $manifestTemp=Join-Path ([IO.Path]::GetDirectoryName($manifestPath)) ('.workflow-rollback-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
     [IO.File]::WriteAllText($manifestTemp,($latest|ConvertTo-Json -Depth 25),[Text.UTF8Encoding]::new($false))
     [IO.File]::Replace($manifestTemp,$manifestPath,[NullString]::Value)
    }finally{if(Test-Path -LiteralPath $manifestTemp -PathType Leaf){Remove-Item -LiteralPath $manifestTemp -Force}}
   }elseif($null -ne $manifestBefore){
    # A missing file cannot contain concurrent entries to retain.
    $manifestBefore|ConvertTo-Json -Depth 25|Set-Content -LiteralPath $manifestPath -Encoding utf8
   }
  }catch{$rollbackErrors.Add('manifest: '+$_.Exception.Message)}}
  if($rollbackErrors.Count){throw ('Workflow application failed: '+$applyError.Exception.Message+'. Rollback incomplete: '+($rollbackErrors -join '; '))}
  throw $applyError
 }
} finally {
 if($lockTaken){$mutex.ReleaseMutex()}
 $mutex.Dispose()
}
@{ok=$true;steps=$steps.Count;console=$(if($UpdateConsole){$consolePath}else{$null})}|ConvertTo-Json
