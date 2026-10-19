[CmdletBinding()]
param([string]$ReceiptPath = '')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $workspace ('.agent/cache/intake-test-' + [guid]::NewGuid().ToString('N'))
$checks = [Collections.Generic.List[string]]::new()
function Check([bool]$Ok,[string]$Name) { if (-not $Ok) { throw "FAIL: $Name" }; $checks.Add($Name) }
function Json($Value) { ($Value -join [Environment]::NewLine) | ConvertFrom-Json }
function Fails([scriptblock]$Action,[string]$Pattern) { try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return $true }; return $false }
try {
    $shared = Join-Path $fixture '.agent/shared'
    $index = Join-Path $fixture '.agent/index'
    $cabinet = Join-Path $fixture 'cabinet'
    foreach ($p in @($shared,$index,$cabinet,(Join-Path $cabinet '.agent/shared'),(Join-Path $fixture 'sources/a'),(Join-Path $fixture 'sources/b'))) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    # Cabinet bootstrap is covered by Test-CabinetLifecycle. This fixture exercises intake/preservation only.
    '' | Set-Content -LiteralPath (Join-Path $cabinet '.agent/shared/Initialize-PortableCabinet.ps1') -Encoding utf8
    foreach ($name in @('DocumentScope.ps1','DocumentBasis.ps1','Resolve-TeacherHarnessConfig.ps1','Receive-TeacherHarnessInputs.ps1','Start-HwpxWork.ps1','Sync-HumanSourcePreservation.ps1','New-HwpxJob.ps1','Update-HumanWorkConsole.ps1','Publish-HumanResult.ps1','WorkStorage.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $shared $name) }
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'WorkLayout.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'WorkLayout.ps1') -Destination $shared }
    # Any unnecessary layout survey fails the basic scaffold test immediately.
    "throw 'Unexpected layout survey'" | Set-Content -LiteralPath (Join-Path $shared 'Get-PriorWorkLayout.ps1')
    $config = Get-Content -Raw -Encoding utf8 (Join-Path $workspace '.agent/index/delivery-system.json') | ConvertFrom-Json
    $config.humanCabinet = $cabinet
    $config | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $index 'delivery-system.json')
    '{"schemaVersion":"hwpx-human-current/v4","works":[]}' | Set-Content -Encoding utf8 (Join-Path $index 'human-current.json')
    $basic = Json (& (Join-Path $shared 'Start-HwpxWork.ps1') -UpdateConsole -Mode New -TaskTitle '기본 생성 시험' -WorkFolderName '20260907_기본 생성 시험' -JobSlug 'fixture-basic' -CreatedDate '20260907' -IntakeSummary '기본 생성' -DecisionReason '테스트')
    Check ((Test-Path -LiteralPath (Join-Path $basic.workRoot '업무현황.html')) -and $basic.supportFolders.Count -eq 0) 'empty basic scaffold runs without layout discovery'
    $a = Join-Path $fixture 'sources/a/한글 원본.hwp'
    $b = Join-Path $fixture 'sources/b/한글 원본.hwp'
    [IO.File]::WriteAllText($a,'fixture source a')
    [IO.File]::WriteAllText($b,'fixture source b')
    $ah = (Get-FileHash -LiteralPath $a).Hash
    $bh = (Get-FileHash -LiteralPath $b).Hash
    $intakeArgs = @{UpdateConsole=$true;Mode='New';TaskTitle='자동 접수 시험';WorkFolderName='20260907_자동 접수 시험';JobSlug='fixture-intake';CreatedDate='20260907';IntakeSummary='격리 접수';DecisionReason='테스트';FormFile=@($a);ReferenceFile=@($b);UserProvidedFile=@($a,$b)}
    $first = Json (& (Join-Path $shared 'Start-HwpxWork.ps1') @intakeArgs)
    $work = $first.workRoot
    $copies = @($first.sourcePreservation.records)
    Check ($copies.Count -eq 2 -and $copies[0].copyRelativePath -ne $copies[1].copyRelativePath) 'same-name sources preserved separately'
    Check ((Test-Path -LiteralPath (Join-Path $work '업무현황.html')) -and (Get-Item -LiteralPath (Join-Path $work '.ai') -Force).Attributes.HasFlag([IO.FileAttributes]::Hidden)) 'single-call scaffold and hidden metadata'
    foreach ($copy in $copies) { Check ((Get-FileHash -LiteralPath (Join-Path $work $copy.copyRelativePath)).Hash -eq $copy.sha256) 'copy matches intake hash' }
    Check ((Get-FileHash -LiteralPath $a).Hash -eq $ah -and (Get-FileHash -LiteralPath $b).Hash -eq $bh) 'external originals unchanged'
    $retry = Json (& (Join-Path $shared 'Start-HwpxWork.ps1') @intakeArgs)
    Check ([bool]$retry.reused -and @(Get-ChildItem -LiteralPath (Join-Path $work '.ai/originals') -File -Recurse).Count -eq 2) 'identical New intake is idempotent'
    $job = $first.jobPath
    Check ($job.StartsWith((Join-Path $work '.ai/jobs/'),[StringComparison]::OrdinalIgnoreCase) -and -not (Test-Path -LiteralPath (Join-Path $fixture '.agent/jobs'))) 'school job is stored within selected human work'
    Remove-Item -LiteralPath (Join-Path $job 'wip/receipts/work-intake.json')
    $recoveredIntake = Json (& (Join-Path $shared 'Start-HwpxWork.ps1') @intakeArgs)
    Check ($recoveredIntake.sourcePreservation.ok -and @(Get-ChildItem -LiteralPath (Join-Path $work '.ai/originals') -File -Recurse).Count -eq 2) 'reserved intake recovers after interruption before final receipt'
    $out = Join-Path $job 'wip/docs/시험 결과.txt'
    [IO.File]::WriteAllText($out,'published content')
    $pubArgs = @{UpdateConsole=$true;ExplicitTextArtifact=$true;Stage='Review';TaskTitle='자동 접수 시험';SourceFile=@($out);WorkFolderName='20260907_자동 접수 시험'}
    $published = Json (& (Join-Path $shared 'Publish-HumanResult.ps1') @pubArgs)
    Check ($published.sourcePreservation.ok -and $null -eq $published.archivedSnapshot -and (Test-Path -LiteralPath (Join-Path $job 'wip/receipts/work-publish.json'))) 'first publish verifies originals and persists receipt'
    $republish = Json (& (Join-Path $shared 'Publish-HumanResult.ps1') @pubArgs)
    Check ($republish.reusedCurrentFiles -and $null -eq $republish.archivedSnapshot) 'identical publish does not create duplicate previous results'
    $html = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $work '업무현황.html')
    $manifest = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $index 'human-open-targets.json') | ConvertFrom-Json
    $manifestWork = @($manifest.workFolders | Where-Object { [IO.Path]::GetFullPath([string]$_.workFolder) -ieq [IO.Path]::GetFullPath($work) }) | Select-Object -First 1
    foreach ($copy in $copies) {
        $expectedPath = [IO.Path]::GetFullPath((Join-Path $work $copy.copyRelativePath))
        $native = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expectedPath)).TrimEnd('=').Replace('+','-').Replace('/','_')
        Check (-not $html.Contains(([string]$config.openProtocol + '://open/' + $native)) -and (@($manifestWork.targets) -notcontains $expectedPath)) 'hidden preserved source is excluded from user-facing native targets'
    }
    $intakeArgs.Mode='FollowUp'; $intakeArgs.WorkFolderName='20260907_자동 접수 시험'
    [IO.File]::WriteAllText($a,'new source revision')
    $updated = Json (& (Join-Path $shared 'Start-HwpxWork.ps1') @intakeArgs)
    Check (@(Get-ChildItem -LiteralPath (Join-Path $work '.ai/originals') -File -Recurse).Count -eq 3 -and (Get-FileHash -LiteralPath (Join-Path $work $copies[0].copyRelativePath)).Hash -eq $ah) 'changed source adds revision and preserves old copy'
    $sourceJson = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $work '.ai/sources.json') | ConvertFrom-Json
    Check (@($sourceJson.sources | Where-Object { $_.path -eq $a -and $_.role -eq 'form' }).Count -eq 2) 'source revision history retained'
    # Fail metadata persistence after a new original has been preserved, then retry.
    [IO.File]::WriteAllText($a,'third source revision')
    $fixtureStartPath = Join-Path $shared 'Start-HwpxWork.ps1'
    $fixtureStart = Get-Content -Raw -Encoding utf8 -LiteralPath $fixtureStartPath
    $injected = $fixtureStart.Replace('Write-JsonAtomic $sourceMetadataPath $sourceMetadata', "throw 'Injected source metadata write failure'")
    $injected | Set-Content -Encoding utf8 -LiteralPath $fixtureStartPath
    try { Check (Fails { & $fixtureStartPath @intakeArgs } 'Injected source metadata') 'metadata failure is not reported as success' } finally { $fixtureStart | Set-Content -Encoding utf8 -LiteralPath $fixtureStartPath }
    $countAfterFailure = @(Get-ChildItem -LiteralPath (Join-Path $work '.ai/originals') -File -Recurse).Count
    $updated = Json (& (Join-Path $shared 'Start-HwpxWork.ps1') @intakeArgs)
    $countAfterRetry = @(Get-ChildItem -LiteralPath (Join-Path $work '.ai/originals') -File -Recurse).Count
    Check ($countAfterRetry -eq $countAfterFailure) "retry recovers preserved copy without duplicate after metadata failure ($countAfterFailure to $countAfterRetry)"
    [IO.File]::WriteAllText($out,'updated content')
    $next = Json (& (Join-Path $shared 'Publish-HumanResult.ps1') @pubArgs)
    Check ($next.archivedFiles.Count -eq 1 -and [IO.Path]::GetFileName($next.archivedFiles[0].archive) -match '_fix01_\d{8}-\d{6}\.txt$' -and (Get-Content -Raw -LiteralPath $next.archivedFiles[0].archive) -eq 'published content') 'current result archived with dated fix history separately from original sources'
    # Partial replacement must succeed while an unrelated registered file is exclusively locked.
    $extra = Join-Path $job 'wip/docs/별도 파일.txt'
    [IO.File]::WriteAllText($extra,'retain me')
    $pubArgs.SourceFile=@($out,$extra)
    $two = Json (& (Join-Path $shared 'Publish-HumanResult.ps1') @pubArgs)
    $liveTarget=Join-Path $work '시험 결과.txt'
    $liveExtra=Join-Path $work '별도 파일.txt'
    $extraHash=(Get-FileHash $liveExtra).Hash
    $heldExtra=[IO.File]::Open($liveExtra,'Open','ReadWrite','None')
    try {
        $partialIntake=Json (& (Join-Path $shared 'Start-HwpxWork.ps1') -UpdateConsole -Mode FollowUp -SelectedFilesOnly -TaskTitle '자동 접수 시험' -WorkFolderName '20260907_자동 접수 시험' -JobSlug 'fixture-partial' -CreatedDate '20260907' -IntakeSummary '선택 수정' -DecisionReason '잠긴 비대상 보존 시험' -HumanRevisionFile @($liveTarget) -UserProvidedFile @($liveTarget))
        $partialJob=$partialIntake.jobPath
        $partialOut=Join-Path $partialJob 'wip/docs/시험 결과.txt'
        [IO.File]::WriteAllText($partialOut,'partial content')
        $partialArgs=@{ExplicitTextArtifact=$true;Stage='Review';TaskTitle='자동 접수 시험';WorkFolderName='20260907_자동 접수 시험';SourceFile=@($partialOut);PartialUpdate=$true}
        $partialPub=Json (& (Join-Path $shared 'Publish-HumanResult.ps1') @partialArgs)
        Check ($partialPub.retainedFiles -contains '별도 파일.txt') 'partial publish retains locked unrelated file'
        Check ($partialPub.archivedFiles.Count -eq 1 -and [IO.Path]::GetFileName($partialPub.archivedFiles[0].archive) -match '_fix02_') 'partial archive contains only replaced target and increments fix number'
        $partialMeta=Get-Content (Join-Path $work '.ai/work.json') -Raw -Encoding utf8 | ConvertFrom-Json
        Check ($partialMeta.currentFiles.Count -eq 2) 'partial update retains complete registered set'
        $repeatPartial=Json (& (Join-Path $shared 'Publish-HumanResult.ps1') @partialArgs)
        Check ($repeatPartial.reusedCurrentFiles) 'partial republish is idempotent'
        [IO.File]::WriteAllText($liveTarget,'external change')
        Check (Fails { & (Join-Path $shared 'Publish-HumanResult.ps1') @partialArgs } 'exact hash') 'partial target changed after intake is blocked'
        [IO.File]::WriteAllText($liveTarget,'updated content')
    } finally { $heldExtra.Dispose() }
    Check ((Get-FileHash $liveExtra).Hash -eq $extraHash) 'retained file bytes untouched'
    $badSource = [pscustomobject]@{path=$b;role='prior_example';sha256=('0'*64);userProvided=$true}
    Check (Fails { & (Join-Path $shared 'Sync-HumanSourcePreservation.ps1') -WorkFolder $work -Source @($badSource) } 'changed since intake') 'intake hash mismatch blocked'
    $held = [IO.File]::Open($a,'Open','ReadWrite','None')
    try { Check (Fails { & (Join-Path $shared 'Sync-HumanSourcePreservation.ps1') -WorkFolder $work -Source @([pscustomobject]@{path=$a;role='form';sha256=$updated.sourcePreservation.records[0].sha256;userProvided=$true}) } 'process|프로세스') 'locked source copy/read failure blocked' } finally { $held.Dispose() }
    $target = Join-Path $work $copies[0].copyRelativePath
    [IO.File]::WriteAllText($target,'tampered copy')
    Check (Fails { & (Join-Path $shared 'Publish-HumanResult.ps1') @pubArgs } 'missing or changed') 'publish fails closed on changed preserved copy'
    Check ((Get-Content -Raw -LiteralPath (Join-Path $work '시험 결과.txt')) -eq 'updated content') 'failed publish leaves current human result intact'
    $manualWork = Join-Path $cabinet '20260907_수동 보관 시험'
    $manualRelative = 'previous_versions/20260907-090000_접수원본/한글 원본.hwp'
    $manualTarget = Join-Path $manualWork $manualRelative
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($manualTarget)) -Force | Out-Null
    Copy-Item -LiteralPath $b -Destination $manualTarget
    $adopt = Json (& (Join-Path $shared 'Sync-HumanSourcePreservation.ps1') -WorkFolder $manualWork -Source @([pscustomobject]@{path=$b;role='prior_example';sha256=$bh;userProvided=$true;copyRelativePath=$manualRelative}))
    Check ($adopt.records[0].copyRelativePath -eq $manualRelative -and @(Get-ChildItem -LiteralPath (Join-Path $manualWork 'previous_versions') -File -Recurse).Count -eq 1) 'existing recorded manual preservation reused'
    $report = [ordered]@{ok=$true;powershell=$PSVersionTable.PSVersion.ToString();checks=@($checks);basicScaffoldSeconds=$basic.elapsedSeconds;intakeSeconds=$first.elapsedSeconds;publishSeconds=$published.elapsedSeconds}
    if ($ReceiptPath) { $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReceiptPath -Encoding utf8 }
    $report | ConvertTo-Json -Depth 5
} finally {
    $safe = [IO.Path]::GetFullPath($fixture)
    if ($safe.StartsWith((Join-Path $workspace '.agent/cache/intake-test-'),[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $safe)) { Remove-Item -LiteralPath $safe -Recurse -Force }
}
