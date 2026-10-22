# Focused synthetic wrapper regression. No school documents or live Output used.
$ErrorActionPreference='Stop'
$fixture=Join-Path $env:TEMP ('draft-publish-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$shared=Join-Path $fixture '.agent/shared'; $index=Join-Path $fixture '.agent/index'; $out=Join-Path $fixture 'Output'
New-Item -ItemType Directory -Path $shared,$index,$out -Force | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $shared -Recurse
$config=Get-Content (Join-Path $PSScriptRoot '../index/delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
$config.humanCabinet=$out; $config.incomingRoot=Join-Path $fixture 'incoming'
$config | Add-Member outputLayout 'flat' -Force
$config | Add-Member receiveInputs $false -Force
$configPath=Join-Path $index 'delivery-system.json'
$config | ConvertTo-Json -Depth 20 | Set-Content $configPath -Encoding utf8
$form=Join-Path $fixture 'form.csv'; Set-Content $form 'name,value' -Encoding utf8
function J($x) { ($x -join "`n") | ConvertFrom-Json }
function BeginWork($title,$slug,[switch]$Strict) {
    $options=@{Mode='New';TaskTitle=$title;JobSlug=$slug;FormFile=$form;UserProvidedFile=$form;IntakeSummary='Synthetic';DecisionReason='Synthetic';RequestId=$slug}
    if ($Strict) { $options.RequireContentValidation=$true } else { $options.DraftFirst=$true }
    J (& (Join-Path $shared 'Start-HwpxWork.ps1') @options)
}
function Draft($work,$value) { $path=Join-Path $work.jobPath 'wip/docs/result.csv'; Set-Content $path $value -Encoding utf8; $path }
function Publish($work,$path) { J (& (Join-Path $shared 'Publish-DocumentDraft.ps1') -JobPath $work.jobPath -SourceFile $path -TargetRelativePath 'result.csv' -ChecksCompleted content,integrity) }
function MustFail([scriptblock]$Action,[string]$Pattern) {
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -match $Pattern) { return }; throw }
    throw "Expected failure: $Pattern"
}
$a=BeginWork Alpha alpha; $source=Draft $a 'A'
$ready=Join-Path $a.jobPath 'wip/receipts/human-delivery-ready.json'
$nameMap=Join-Path $out '.ai/output-names.json'
MustFail { & (Join-Path $shared 'Publish-DocumentDraft.ps1') -JobPath $a.jobPath -SourceFile $source -TargetRelativePath draft.csv -ChecksCompleted content,integrity } 'filename'
MustFail { & (Join-Path $shared 'Publish-DocumentDraft.ps1') -JobPath $a.jobPath -SourceFile $source -TargetRelativePath result.odt -ChecksCompleted content,integrity } 'extension'
$fakeHwpx=Join-Path $a.jobPath 'wip/docs/synthetic.hwpx'
Set-Content -LiteralPath $fakeHwpx -Value 'Not a real document; rejected before package read.'
MustFail { & (Join-Path $shared 'Publish-DocumentDraft.ps1') -JobPath $a.jobPath -SourceFile $fakeHwpx -TargetRelativePath result.hwpx -ChecksCompleted content,integrity } 'FormContractPath'
$fakeContract=Join-Path $a.jobPath 'wip/receipts/hwpx-form-contract.json'
@{form_status='existing'; authoritative_form=@(@{path=$fakeHwpx;sha256=(Get-FileHash $fakeHwpx).Hash})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fakeContract -Encoding utf8
MustFail { & (Join-Path $shared 'Publish-DocumentDraft.ps1') -JobPath $a.jobPath -SourceFile $fakeHwpx -TargetRelativePath result.hwpx -ChecksCompleted content,integrity -FormContractPath $fakeContract -FormBaseFile $fakeHwpx } 'not registered'
if ((Test-Path $nameMap) -or (Test-Path $ready)) { throw 'Invalid draft arguments consumed numbering or wrote a ready receipt' }
MustFail { & (Join-Path $shared 'Publish-DocumentDraft.ps1') -JobPath $a.jobPath -SourceFile $source -TargetRelativePath result.csv -ChecksCompleted content } 'integrity'
if (Test-Path $ready) { throw 'Missing checks wrote a ready receipt' }
MustFail { & (Join-Path $shared 'Publish-DocumentDraft.ps1') -JobPath $a.jobPath -SourceFile $source -TargetRelativePath result.csv -ChecksCompleted content,integrity -DeliveryConfigPath $configPath } 'only with PlanOnly'
if (Test-Path $ready) { throw 'Invalid override wrote a ready receipt' }
$preview=J (& (Join-Path $shared 'Publish-DocumentDraft.ps1') -JobPath $a.jobPath -SourceFile $source -TargetRelativePath result.csv -ChecksCompleted content,integrity -DeliveryConfigPath $configPath -PlanOnly)
if (Test-Path $ready) { throw 'PlanOnly wrote a ready receipt' }
if (Test-Path (Join-Path $out '00_result.csv')) { throw 'PlanOnly published a file' }
$published=Publish $a $source
if ($published.status -ne 'published' -or $published.stage -ne 'Review' -or $published.fileCount -ne 1) { throw 'Wrong publication summary' }
if ((Get-Content (Join-Path $out '00_result.csv') -Raw).Trim() -ne 'A') { throw 'Draft was not published' }
$b=BeginWork Beta beta; $second=Publish $b (Draft $b 'B')
if ((Get-Content (Join-Path $out '01_result.csv') -Raw).Trim() -ne 'B') { throw 'Collision allocation failed' }
Set-Content (Join-Path $out '00_result.csv') 'Human revision' -Encoding utf8
$a=J (& (Join-Path $shared 'Start-HwpxWork.ps1') -Mode FollowUp -TaskTitle Alpha -JobPath $a.jobPath -IntakeSummary 'Change A' -DecisionReason Synthetic -RequestId alpha-two)
$published=Publish $a (Draft $a 'A2')
$receipt=Get-Content $published.receiptPath -Raw -Encoding utf8 | ConvertFrom-Json
if (-not @($receipt.archivedFiles | Where-Object { (Get-Content $_.archive -Raw).Trim() -eq 'Human revision' }).Count) { throw 'Human revision was not preserved' }
if ((Get-Content (Join-Path $out '01_result.csv') -Raw).Trim() -ne 'B') { throw 'Another work was overwritten' }
$strict=BeginWork Strict strict -Strict
MustFail { Publish $strict (Draft $strict 'S') } 'content|validation|receipt'
if (Test-Path (Join-Path $strict.jobPath 'wip/receipts/human-delivery-ready.json')) { throw 'Required content validation was bypassed' }
if (Test-Path (Join-Path $fixture 'incoming')) { throw 'Reference-only input handling changed' }
Write-Output "PASS draft wrapper: Review, explicit checks, isolated preview, numbering, human revision, required validation. Fixture: $fixture"
