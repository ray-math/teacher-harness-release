# Synthetic flat delivery regression; all artifacts stay in TEMP.
$ErrorActionPreference='Stop'
$fixture=Join-Path $env:TEMP ('fo-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$shared=Join-Path $fixture '.agent/shared';$index=Join-Path $fixture '.agent/index';$out=Join-Path $fixture 'Output'
New-Item -ItemType Directory -Path $shared,$index,$out -Force|Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $shared -Recurse
$config=Get-Content (Join-Path $PSScriptRoot '../index/delivery-system.json') -Raw -Encoding utf8|ConvertFrom-Json
$config.humanCabinet=$out;$config.incomingRoot=Join-Path $fixture 'incoming'
$config|Add-Member outputLayout 'flat' -Force
$config|Add-Member receiveInputs $false -Force
$config|ConvertTo-Json -Depth 20|Set-Content (Join-Path $index 'delivery-system.json') -Encoding utf8
$form=Join-Path $fixture 'form.csv';Set-Content $form 'x,y' -Encoding utf8
function J($x){($x -join "`n")|ConvertFrom-Json}
function BeginWork($title,$slug){J (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode New -TaskTitle $title -JobSlug $slug -FormFile $form -UserProvidedFile $form -DraftFirst -IntakeSummary 'Synthetic' -DecisionReason 'Synthetic' -RequestId $slug)}
function Deliver($w,$name,$value){$s=Join-Path $w.jobPath ('wip/docs/'+$name);Set-Content $s $value -Encoding utf8;& (Join-Path $shared 'Complete-HumanDraft.ps1') -JobPath $w.jobPath -SourceFile $s -TargetRelativePath $name -Stage Review -ChecksCompleted content,integrity |Out-Null;J (& (Join-Path $shared 'Publish-HumanResult.ps1') -Stage Review -TaskTitle $w.taskTitle -WorkFolderName $w.workFolderName -SourceFile $s -TargetRelativePath $name)}

$a=BeginWork 'Alpha' 'alpha';$b=BeginWork 'Beta' 'beta'
$pa=Deliver $a 'result.csv' 'A';$pb=Deliver $b 'result.csv' 'B'
if(-not(Test-Path (Join-Path $out '00_result.csv')) -or -not(Test-Path (Join-Path $out '01_result.csv'))){throw 'Numbering/collision failed'}
Set-Content (Join-Path $out '00_result.csv') 'Human revision'
$a=J (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode FollowUp -TaskTitle Alpha -JobPath $a.jobPath -IntakeSummary 'Change A' -DecisionReason Synthetic -RequestId 'alpha-two')
$pa=Deliver $a 'result.csv' 'A2'
if((Get-Content (Join-Path $out '00_result.csv') -Raw).Trim() -ne 'A2'){throw 'Follow-up filename changed'}
if((Get-Content (Join-Path $out '01_result.csv') -Raw).Trim() -ne 'B'){throw 'Other work changed'}
if(Test-Path (Join-Path $fixture 'incoming')){throw 'Received folder created despite reference-only setting'}
Set-Content (Join-Path $out '02_collision.csv') 'Keep me'
$c=BeginWork 'Gamma' 'gamma';$pc=Deliver $c '00_result.csv' 'C'
if(-not(Test-Path (Join-Path $out '03_result.csv'))){throw 'Collision or repeated prefix numbering failed'}
if((Get-Content (Join-Path $out '02_collision.csv') -Raw).Trim() -ne 'Keep me'){throw 'Collision overwritten'}
if(@(Get-ChildItem $out -Directory).Count -ne 0){throw 'Visible work directory created'}
if(-not(@($pa.archivedFiles | Where-Object {(Get-Content $_.archive -Raw).Trim() -eq 'Human revision'}).Count)){throw 'Human revision not archived'}
Write-Output "PASS flat two works, collision, followup, human revision preservation: $fixture"
# Existing explicitly registered folders remain usable after selecting flat for new work.
$config.outputLayout='work';$config|ConvertTo-Json -Depth 20|Set-Content (Join-Path $index 'delivery-system.json') -Encoding utf8
$legacy=BeginWork 'Legacy' 'legacy';$null=Deliver $legacy 'result.csv' 'L'
$config.outputLayout='flat';$config|ConvertTo-Json -Depth 20|Set-Content (Join-Path $index 'delivery-system.json') -Encoding utf8
$legacyFollow=J (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode FollowUp -TaskTitle Legacy -JobPath $legacy.jobPath -IntakeSummary 'Change legacy' -DecisionReason Synthetic -RequestId 'legacy-two')
if($legacyFollow.workRoot -ine $legacy.workRoot){throw 'Legacy selected folder changed'}
$null=Deliver $legacyFollow 'result.csv' 'L2'
if((Get-Content (Join-Path $legacy.workRoot 'result.csv') -Raw).Trim() -ne 'L2'){throw 'Legacy selected output changed'}
Write-Output 'PASS legacy work root retained after switching flat'
