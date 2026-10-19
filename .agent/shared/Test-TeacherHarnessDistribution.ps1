[CmdletBinding()]
param([string]$QaRoot = '')
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $QaRoot) { $QaRoot = Join-Path ([IO.Path]::GetDirectoryName($workspace)) 'HarnessQA' }
$qa = [IO.Path]::GetFullPath($QaRoot).TrimEnd('\')
New-Item -ItemType Directory -Path $qa -Force | Out-Null
if ((Get-Item -LiteralPath $qa -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'QA root cannot be a reparse point.' }
$fixture = Join-Path $qa ('teacher-distribution-' + [guid]::NewGuid().ToString('N'))
$harness = Join-Path $fixture 'harness'
$shared = Join-Path $harness '.agent\shared'
$index = Join-Path $harness '.agent\index'
$cabinet = Join-Path $fixture '업무'
$incoming = Join-Path $fixture '받은자료'
$checks = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $checks.Add($Name) }
function Json($Value) { ($Value -join [Environment]::NewLine) | ConvertFrom-Json }
function Reject([scriptblock]$Action, [string]$Pattern, [string]$Name) {
    $caught = $false
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; $caught = $true }
    Check $caught $Name
}
function CwdState {
    @('C:\업무\21_자료취합', 'C:\받은자료') | ForEach-Object {
        $exists = Test-Path -LiteralPath $_
        [ordered]@{path=$_;exists=[bool]$exists;lastWriteTime=$(if ($exists) {(Get-Item -LiteralPath $_ -Force).LastWriteTimeUtc.Ticks} else {$null})}
    } | ConvertTo-Json -Compress
}
$cwdBefore = CwdState
$locationPushed = $false
try {
    New-Item -ItemType Directory -Path $shared,$index,$incoming -Force | Out-Null
    foreach ($name in @('Resolve-TeacherHarnessConfig.ps1','WorkStorage.ps1','WorkRegistry.ps1','DocumentScope.ps1','HumanDeliveryContract.ps1','HumanRevisionStorage.ps1','Complete-HumanDraft.ps1','DocumentBasis.ps1','Resolve-TeacherHarnessConfig.ps1','Receive-TeacherHarnessInputs.ps1','Start-HwpxWork.ps1','New-HwpxJob.ps1','Publish-HumanResult.ps1','Sync-HumanSourcePreservation.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared
    }
    $config = Get-Content -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $config.humanCabinet = '../업무'
    $config.incomingRoot = '../받은자료'
    $configPath = Join-Path $index 'delivery-system.json'
    $config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $configBefore = (Get-FileHash -LiteralPath $configPath).Hash
    $source = Join-Path $incoming '합성자료.csv'
    @([pscustomobject]@{항목='가';값=10}, [pscustomobject]@{항목='나';값=20}) | Export-Csv -LiteralPath $source -NoTypeInformation -Encoding UTF8
    $baseline = Join-Path $incoming '기존취합양식.csv'
    [IO.File]::WriteAllText($baseline,"구분,건수,합계,메모`r`n,,,",[Text.UTF8Encoding]::new($true))
    $sourceBefore = (Get-FileHash -LiteralPath $source).Hash
    Push-Location 'C:\Windows'; $locationPushed = $true
    . (Join-Path $shared 'Resolve-TeacherHarnessConfig.ps1')
    $resolved = Read-TeacherHarnessConfig -Workspace $harness
    Check ($resolved.humanCabinet -ieq $cabinet -and $resolved.incomingRoot -ieq $incoming) 'initial relative config resolves from extracted harness'
    $start = Join-Path $shared 'Start-HwpxWork.ps1'
    $complete = Join-Path $shared 'Complete-HumanDraft.ps1'
    $publish = Join-Path $shared 'Publish-HumanResult.ps1'
    $request = '합성 자료 취합 결과 CSV를 21_자료취합에 작성'
    $intake = Json (& $start -Mode New -TaskTitle '자료취합' -WorkFolderName '21_자료취합' -JobSlug 'synthetic-collection' -IntakeSummary $request -DecisionReason 'Synthetic distribution verification' -RequestText $request -RequestId 'synthetic-new' -FormFile $baseline -AuthorityFile $source -UserProvidedFile @($source,$baseline) -Collection -Summary)
    $job = $intake.jobPath
    $work = $intake.workRoot
    $draft = Join-Path $job 'wip\docs\취합결과.csv'
    $current = Join-Path $cabinet '21_자료취합\취합결과.csv'
    $checkReceipt = Join-Path $job 'wip\receipts\synthetic-content-check.json'
    $rows = @(Import-Csv -LiteralPath $source -Encoding UTF8)
    $sum = ($rows | ForEach-Object {[int]$_.값} | Measure-Object -Sum).Sum
    @([pscustomobject]@{구분='합계';건수=$rows.Count;합계=$sum;메모=''}) | Export-Csv -LiteralPath $draft -NoTypeInformation -Encoding UTF8
    $pub = @{Stage='Final';TaskTitle='자료취합';WorkFolderName='21_자료취합';SourceFile=@($draft);TargetRelativePath=@('취합결과.csv');Summary=$true}
    function Ready([int]$ExpectedSum, [string]$ExpectedMemo) {
        $actual = @(Import-Csv -LiteralPath $draft -Encoding UTF8)
        Check ($actual.Count -eq 1 -and [int]$actual[0].합계 -eq $ExpectedSum -and [string]$actual[0].메모 -ceq $ExpectedMemo) 'synthetic CSV content verified'
        @{ok=$true;checks=@('content','integrity');expectedSum=$ExpectedSum;expectedMemo=$ExpectedMemo;sha256=(Get-FileHash -LiteralPath $draft).Hash} | ConvertTo-Json | Set-Content -LiteralPath $checkReceipt -Encoding UTF8
        Json (& $complete -JobPath $job -SourceFile $draft -TargetRelativePath '취합결과.csv' -Stage Final -ChecksCompleted @('content','integrity') -CheckReceiptFile $checkReceipt)
    }
    function Follow([string]$Id, [string]$Text) {
        Json (& $start -Mode FollowUp -TaskTitle '자료취합' -WorkFolderName '21_자료취합' -JobPath $job -IntakeSummary $Text -DecisionReason 'Synthetic follow-up verification' -RequestText $Text -RequestId $Id -Summary)
    }
    Reject { & $publish @pub } 'Complete-HumanDraft|completion' 'unfinished internal result cannot publish'
    $ready = Ready 30 ''
    $one = Json (& $publish @pub)
    Check ($one.files[0] -ieq $current -and (Test-Path -LiteralPath $current -PathType Leaf)) 'first result published beneath fixture cabinet'
    Check ($work -ieq (Join-Path $cabinet '21_자료취합') -and $job.StartsWith($work + '\', [StringComparison]::OrdinalIgnoreCase)) 'intake and WIP remain inside selected fixture work'
    Check ((Test-Path -LiteralPath $intake.receiptPath) -and (Test-Path -LiteralPath $ready.receiptPath) -and (Test-Path -LiteralPath $one.receiptPath)) 'intake check completion and publish receipts remain in fixture'
    $firstHash = (Get-FileHash -LiteralPath $current).Hash
    $follow = Follow 'synthetic-followup' '합계만 35로 수정'
    $next = Import-Csv -LiteralPath $current -Encoding UTF8
    $next.합계 = 35
    $next | Export-Csv -LiteralPath $draft -NoTypeInformation -Encoding UTF8
    $ready = Ready 35 ''
    $two = Json (& $publish @pub)
    $fullTwo = Json (Get-Content -LiteralPath $two.receiptPath -Raw -Encoding UTF8)
    Check ($fullTwo.archivedFiles.Count -eq 1 -and (Get-FileHash -LiteralPath $fullTwo.archivedFiles[0].archive).Hash -ceq $firstHash) 'follow-up publishes update and preserves exact previous current'
    $follow = Follow 'synthetic-reviewed' '합계를 40으로 수정하고 현재 메모 유지'
    $human = Import-Csv -LiteralPath $current -Encoding UTF8
    $human.메모 = '사람 검토 완료'
    $human | Export-Csv -LiteralPath $current -NoTypeInformation -Encoding UTF8
    $humanHash = (Get-FileHash -LiteralPath $current).Hash
    $next = Import-Csv -LiteralPath $current -Encoding UTF8
    $next.합계 = 40
    $next | Export-Csv -LiteralPath $draft -NoTypeInformation -Encoding UTF8
    $ready = Ready 40 '사람 검토 완료'
    Reject { & $publish @pub } 'exact hash as human_revision' 'saved human edit after intake cannot be overwritten'
    Check ((Get-FileHash -LiteralPath $current).Hash -ceq $humanHash) 'rejected publish preserves current human bytes'
    $follow = Follow 'synthetic-reviewed' '합계를 40으로 수정하고 현재 메모 유지'
    $ready = Ready 40 '사람 검토 완료'
    $three = Json (& $publish @pub)
    $fullThree = Json (Get-Content -LiteralPath $three.receiptPath -Raw -Encoding UTF8)
    Check ($fullThree.archivedFiles.Count -eq 1 -and (Get-FileHash -LiteralPath $fullThree.archivedFiles[0].archive).Hash -ceq $humanHash) 'renewed intake preserves exact saved human revision'
    $final = Import-Csv -LiteralPath $current -Encoding UTF8
    Check ([int]$final.합계 -eq 40 -and $final.메모 -ceq '사람 검토 완료') 'requested final content preserves unrelated human memo'
    Check ((Get-FileHash -LiteralPath $source).Hash -ceq $sourceBefore) 'synthetic incoming source remains byte-identical'
    Check ((Get-FileHash -LiteralPath $configPath).Hash -ceq $configBefore) 'core flow leaves portable relative config unchanged'
    Check ((CwdState) -ceq $cwdBefore) 'alternate CWD data paths were not created or changed'
    [ordered]@{ok=$true;count=$checks.Count;verification='portable relative config without Setup; isolated synthetic CSV intake, completion, publication and saved revision';checks=@($checks);fixtureRoot=$fixture;publishedPath=$current;cleanup='fixture removed after verification'} | ConvertTo-Json -Depth 6
} finally {
    if ($locationPushed) { Pop-Location }
    $safe = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($safe) -ine $qa -or [IO.Path]::GetFileName($safe) -notmatch '^teacher-distribution-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $safe) {
        if ((Get-Item -LiteralPath $safe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixture became a reparse point.' }
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
