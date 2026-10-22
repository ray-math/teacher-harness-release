[CmdletBinding()]
param([ValidateSet('work','flat')][string]$OutputLayout='work',[string]$PythonPath = (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'))
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('content-validation-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $checks.Add($Name) }
function Json($Value) { ($Value -join [Environment]::NewLine)|ConvertFrom-Json }
function Reject([scriptblock]$Action,[string]$Pattern,[string]$Name) {
    $caught=$false
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; $caught=$true }
    Check $caught $Name
}
try {
    $shared=Join-Path $fixture '.agent\shared';$index=Join-Path $fixture '.agent\index';$cabinet=Join-Path $fixture 'cabinet'
    New-Item -ItemType Directory -Path $shared,$index,$cabinet -Force | Out-Null
    foreach ($name in @('WorkStorage.ps1','WorkRegistry.ps1','DocumentScope.ps1','HumanDeliveryContract.ps1','HumanRevisionStorage.ps1','Complete-HumanDraft.ps1','DocumentBasis.ps1','Resolve-TeacherHarnessConfig.ps1','Receive-TeacherHarnessInputs.ps1','Start-HwpxWork.ps1','New-HwpxJob.ps1','Publish-HumanResult.ps1','Sync-HumanSourcePreservation.ps1','Assert-ContentValidation.ps1','validate_content_contract.py')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared
    }
    $config=Get-Content -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $config | Add-Member outputLayout $OutputLayout -Force
    $config.incomingRoot=Join-Path $fixture 'incoming';$config.humanCabinet=$cabinet
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $index 'delivery-system.json') -Encoding utf8
    @{pythonPath=$PythonPath} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $index 'odt-runtime.json') -Encoding utf8
    $baseline=Join-Path $fixture 'form.odt';$source=Join-Path $fixture 'evidence.xlsx'
    & $PythonPath -B -c 'import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); from test_content_contract import odt,xlsx; odt(Path(sys.argv[2])); xlsx(Path(sys.argv[3]))' $PSScriptRoot $baseline $source
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic document setup failed.' }
    $start=Join-Path $shared 'Start-HwpxWork.ps1';$complete=Join-Path $shared 'Complete-HumanDraft.ps1';$publish=Join-Path $shared 'Publish-HumanResult.ps1'
    $intake=Json (& $start -Mode New -FormFile $baseline -ReferenceFile $source -TaskTitle 'Content fixture' -WorkFolderName '23_Content fixture' -JobSlug 'content-test' -IntakeSummary 'Fill verified content' -DecisionReason 'Synthetic regression' -RequestText 'Fill verified content' -RequestId 'one' -RequireContentValidation -Summary)
    $job=$intake.jobPath;$draft=Join-Path $job 'wip\docs\result.odt'
    Copy-Item -LiteralPath $baseline -Destination $draft
    $pub=@{Stage='Final';TaskTitle='Content fixture';WorkFolderName=$intake.workFolderName;SourceFile=@($draft);TargetRelativePath=@('result.odt')}
    function Ready { & $complete -JobPath $job -SourceFile $draft -TargetRelativePath 'result.odt' -Stage Final -ChecksCompleted @('content','integrity') | Out-Null }
    function Validate { & $PythonPath -B (Join-Path $shared 'validate_content_contract.py') --job $job | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'Content fixture validation failed.' } }
    Reject { Ready } 'content validation receipt is missing' 'required missing receipt blocks completion'
    $contract=@{schemaVersion='content-contract/v1';sources=@(@{id='evidence';path=$source;sha256=(Get-FileHash -LiteralPath $source).Hash});outputs=@(@{id='out';path='wip/docs/result.odt';targetRelativePath='result.odt'});assertions=@(@{id='name';output='out';locator=@{kind='cell';table=0;row=0;col=0};op='exact';sourceRef=@{source='evidence';sheet='Data';cell='A1'}},@{id='phone';output='out';locator=@{kind='cell';table=0;row=0;col=1};op='blank'})}
    $contractPath=Join-Path $job 'content-contract.json'
    $contract|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $contractPath -Encoding utf8
    Validate;Ready
    Check (Test-Path -LiteralPath (Join-Path $job 'wip\receipts\human-delivery-ready.json')) 'valid saved content permits completion'
    $draftBytes=[IO.File]::ReadAllBytes($draft)
    & $PythonPath -B -c 'import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); from test_content_contract import odt; odt(Path(sys.argv[2]),phone=sys.argv[3])' $PSScriptRoot $draft 'invented'
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic changed output setup failed.' }
    Reject { Ready } 'stale, changed, or failed' 'changed saved output blocks completion'
    & $PythonPath -B (Join-Path $shared 'validate_content_contract.py') --job $job | Out-Null
    Check ($LASTEXITCODE -ne 0) 'invalid saved output creates a failing content result'
    Reject { Ready } 'stale, changed, or failed' 'failed receipt blocks completion'
    [IO.File]::WriteAllBytes($draft,$draftBytes);Validate;Ready
    $sourceBytes=[IO.File]::ReadAllBytes($source)
    [IO.File]::WriteAllText($source,'changed source')
    Reject { Ready } 'Source hash changed' 'source change blocks completion'
    Reject { & $publish @pub } 'Source hash changed' 'source change blocks publication'
    [IO.File]::WriteAllBytes($source,$sourceBytes)
    $contract.assertions[1].normalize=@('trim')
    $contract|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $contractPath -Encoding utf8
    Reject { & $publish @pub } 'stale, changed, or failed' 'changed contract blocks publication before revalidation'
    Validate
    Reject { & $publish @pub } 'changed or was not bound at completion' 'fresh check after contract change requires completion again'
    Ready
    $validationPath=Join-Path $job 'wip\receipts\content-validation.json'
    $validationBytes=[IO.File]::ReadAllBytes($validationPath)
    Remove-Item -LiteralPath $validationPath
    Reject { & $publish @pub } 'content validation receipt is missing' 'missing receipt blocks publication'
    [IO.File]::WriteAllBytes($validationPath,$validationBytes)
    $other=Join-Path $job 'wip\docs\other.odt';Copy-Item -LiteralPath $draft -Destination $other
    Reject { & $complete -JobPath $job -SourceFile $other -TargetRelativePath 'result.odt' -Stage Final -ChecksCompleted @('content','integrity') } 'output binding disagrees' 'check cannot be borrowed by another output'
    $retry=Json (& $start -Mode FollowUp -JobPath $job -FormFile $baseline -ReferenceFile $source -TaskTitle 'Content fixture' -WorkFolderName $intake.workFolderName -IntakeSummary 'Fill verified content' -DecisionReason 'Synthetic regression' -RequestText 'Fill verified content' -RequestId 'one' -Summary)
    $inputs=Get-Content -LiteralPath (Join-Path $job 'inputs.json') -Raw -Encoding utf8|ConvertFrom-Json
    Check ([bool]$inputs.deliveryCycle.requireContentValidation) 'same request cannot downgrade required validation by omitting switch'
    Ready
    $result=Json (& $publish @pub -Summary)
    Check ($result.status -eq 'published') 'validated request reaches actual publication'
    $current=if ($OutputLayout -eq 'flat') { Join-Path $cabinet '00_result.odt' } else { Join-Path $intake.workRoot 'result.odt' }
    Check ((Get-FileHash -LiteralPath $current).Hash -eq (Get-FileHash -LiteralPath $draft).Hash) 'publication preserves validated saved bytes'
    # Independently pinned requirements survive retries and cannot be omitted
    # from a model-authored contract or silently weakened at completion.
    $profilePath=Join-Path $fixture 'required-profile.json'
    $profile=@{schemaVersion='content-required-profile/v1';sourceHashes=@{evidence=(Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()};requiredOutputs=@('out');assertions=@($contract.assertions[0])}
    $profile | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $profilePath -Encoding utf8
    $profileIntake=Json (& $start -Mode FollowUp -JobPath $job -FormFile $baseline -ReferenceFile $source -TaskTitle 'Content fixture' -WorkFolderName $intake.workFolderName -IntakeSummary 'Fill verified content' -DecisionReason 'Synthetic profile regression' -RequestText 'Fill verified content with required profile' -RequestId 'profile-one' -ContentProfilePath $profilePath -Summary)
    $profileInputs=Get-Content -LiteralPath (Join-Path $job 'inputs.json') -Raw -Encoding utf8|ConvertFrom-Json
    Check ($profileInputs.requiredContentProfile.path -ieq $profilePath -and $profileInputs.deliveryCycle.requireContentValidation) 'profile intake pins path hash and requires validation automatically'
    & $PythonPath -B (Join-Path $shared 'validate_content_contract.py') --job $job | Out-Null
    Check ($LASTEXITCODE -ne 0) 'contract cannot omit pinned required profile'
    $contract.requiredProfile=$profileInputs.requiredContentProfile
    $contract.assertions=@($contract.assertions[1])
    $contract|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $contractPath -Encoding utf8
    Validate;Ready
    Check $true 'profile assertions are enforced independently of local contract assertions'
    $profileRetry=Json (& $start -Mode FollowUp -JobPath $job -FormFile $baseline -ReferenceFile $source -TaskTitle 'Content fixture' -WorkFolderName $intake.workFolderName -IntakeSummary 'Fill verified content' -DecisionReason 'Synthetic profile regression' -RequestText 'Fill verified content with required profile' -RequestId 'profile-one' -Summary)
    $profileInputs=Get-Content -LiteralPath (Join-Path $job 'inputs.json') -Raw -Encoding utf8|ConvertFrom-Json
    Check ($profileInputs.requiredContentProfile.sha256 -ieq (Get-FileHash -LiteralPath $profilePath).Hash) 'retry omission preserves pinned profile'
    Ready
    $inputBytes=[IO.File]::ReadAllBytes((Join-Path $job 'inputs.json'))
    $profileInputs.PSObject.Properties.Remove('requiredContentProfile')
    $profileInputs|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $job 'inputs.json') -Encoding utf8
    Reject { Ready } 'profile binding' 'removing input profile binding blocks completion'
    [IO.File]::WriteAllBytes((Join-Path $job 'inputs.json'),$inputBytes)
    $profileBytes=[IO.File]::ReadAllBytes($profilePath)
    Add-Content -LiteralPath $profilePath -Value ' ' -Encoding utf8
    Reject { Ready } 'profile is missing or its hash changed' 'changed required profile blocks completion'
    Reject { & $publish @pub } 'profile is missing or its hash changed' 'changed required profile blocks publication'
    [IO.File]::WriteAllBytes($profilePath,$profileBytes)
    $badProfilePath=Join-Path $fixture 'wrong-profile.json'
    $profile.sourceHashes.evidence=('a'*64)
    $profile|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $badProfilePath -Encoding utf8
    Reject { & $start -Mode FollowUp -JobPath $job -FormFile $baseline -ReferenceFile $source -TaskTitle 'Content fixture' -WorkFolderName $intake.workFolderName -IntakeSummary 'Fill verified content' -DecisionReason 'Synthetic profile regression' -RequestText 'Changed required profile request' -RequestId 'profile-two' -ContentProfilePath $badProfilePath -Summary } 'source hash is not among selected inputs' 'profile source hashes must match selected intake sources'
    Ready
    $profilePublished=Json (& $publish @pub -Summary)
    Check ($profilePublished.status -eq 'published') 'profile-bound request reaches publication after validation'
    @{ok=$true;count=$checks.Count;checks=@($checks);verification='synthetic TEMP saved-content and completion/publication boundaries; not visual'}|ConvertTo-Json -Depth 5
} finally {
    $safe=[IO.Path]::GetFullPath($fixture);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($safe) -ine $tempRoot -or [IO.Path]::GetFileName($safe) -notmatch '^content-validation-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $safe) {
        if (@(Get-ChildItem -LiteralPath $safe -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -or ((Get-Item -LiteralPath $safe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Fixture contains a reparse point.' }
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
