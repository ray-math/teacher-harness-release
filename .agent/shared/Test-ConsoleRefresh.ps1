[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$cache=[IO.Path]::GetFullPath((Join-Path $workspace '.agent\cache'))
$fixture=Join-Path $cache ('console-refresh-test-' + [guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[string]]::new()
function Assert([bool]$Condition,[string]$Label) { if (-not $Condition) { throw $Label }; $checks.Add($Label) }
try {
    $shared=Join-Path $fixture '.agent\shared'
    $index=Join-Path $fixture '.agent\index'
    $cabinet=Join-Path $fixture 'cabinet'
    $work=Join-Path $cabinet '20260904_새로고침 시험'
    $sourceRoot=Join-Path $fixture 'source'
    foreach ($dir in @($shared,$index,$sourceRoot,(Join-Path $work '.ai'))) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    foreach ($name in @('WorkStorage.ps1','Open-HumanWorkPath.ps1','Update-HumanWorkConsole.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $shared $name) }
    $config=Get-Content -Raw -Encoding utf8 (Join-Path $workspace '.agent\index\delivery-system.json') | ConvertFrom-Json
    $config.humanCabinet=$cabinet
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $index 'delivery-system.json') -Encoding utf8
    @{title='새로고침 시험';layout=@{supportFolders=@()};lastIntakeAt='2026-09-08T14:07:35.6350787+09:00';workflow=@{steps=@(@{period='9월';title='운영 준비';action="계획 확인`n대상 확인";result='검토 완료';basis='prior';evidence='<확인>';locator='2쪽'})}} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $work '.ai\work.json') -Encoding utf8
    $sourceFile=Join-Path $sourceRoot '정상 근거.hwpx'
    [IO.File]::WriteAllBytes($sourceFile,[Text.Encoding]::UTF8.GetBytes('fixture'))
    @{sources=@(@{path=$sourceFile;name='정상 근거.hwpx';role='authority'})} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $work '.ai\sources.json') -Encoding utf8
    $metadataPath=Join-Path $work '.ai\work.json'
    $metadata=Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8|ConvertFrom-Json
    $metadata|Add-Member -NotePropertyName consoleContent -NotePropertyValue @{schemaVersion='hwpx-console-content/v1';sections=@(@{id='analysis';title='업무 판단 <제목>';body="첫 줄`n<script>alert('x')</script>"})}
    $metadata|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $metadataPath -Encoding utf8
    $generator=Join-Path $shared 'Update-HumanWorkConsole.ps1'
    $handler=Join-Path $shared 'Open-HumanWorkPath.ps1'
    & $generator -WorkFolder $work | Out-Null
    $htmlPath=Join-Path $work '업무현황.html'
    $html=Get-Content -Raw -Encoding utf8 $htmlPath
    Assert ($html -match 'id="content-analysis"' -and $html -match '업무 판단 &lt;제목&gt;' -and $html -match '&lt;script&gt;alert' -and $html -notmatch '<script>alert') 'Console content renders escaped multiline text inside the same HTML.'
    Assert (@(Get-ChildItem -LiteralPath $work -File -Filter '*.txt').Count -eq 0) 'Console content does not create a human TXT artifact.'
    Assert (-not(Test-Path -LiteralPath (Join-Path $work '문서 열기'))) 'No standalone document launcher is generated.'
    Assert ($html -match '>workflow</button>[\s\S]*?>홈</button>') 'Workflow is the first tab before Home.'
    Assert ($html -notmatch '<dt>다음 할 일</dt>|<span>업무 현황</span>' -and $html -match 'workflow-step' -and $html -match '검토 완료') 'Workflow renders stages and completion criteria without legacy labels.'
    Assert ($html -match '<footer class="intake-footer">최근 접수 <time[^>]*>2026-09-08 14:07</time></footer>' -and $html -match '&lt;확인&gt;') 'Receipt time is in the compact footer and evidence is escaped.'
    $baseUri=[regex]::Match($html,'id="refresh-console" href="([^"]+)"').Groups[1].Value
    Assert ($baseUri -match '^hwpx-work-open://refresh/') '실제 업무 경로의 제목 배너 갱신 URI를 생성한다.'
    Assert ($html -match 'class="home-banner"' -and $html -notmatch '> 목록 새로고침</a>') '별도 버튼 없이 업무 제목 배너를 갱신 동작으로 사용한다.'
    Assert ($html -match "event.key === 'F5'" -and $html -match 'refresh.click\(\)') 'F5를 누르면 정적 재표시 대신 업무폴더 갱신 링크를 실행한다.'
    Assert ($html -match '30000' -and $html -match 'location.replace\(next.href\)' -and $html -match 'result.requestId === requestId') '새로고침은 제한시간 내 일치하는 완료 신호 뒤에 캐시와 구별되는 주소로 다시 읽는다.'
    Assert ($html -match '정상 근거\.hwpx' -and $html -notmatch '숨김·시스템 위치의 근거') '자료 루트 위쪽의 드라이브 속성 때문에 정상 근거 파일을 숨기지 않는다.'
    $newFolder=Join-Path $work '새 취합자료'
    New-Item -ItemType Directory -Path (Join-Path $newFolder '하위묶음') -Force | Out-Null
    $newFile=Join-Path $newFolder '하위묶음\새 문서.pdf'
    [IO.File]::WriteAllBytes($newFile,[Text.Encoding]::ASCII.GetBytes('%PDF-1.4'))
    Set-Content -LiteralPath (Join-Path $newFolder '안내.txt') -Value '변경 전 내용' -Encoding utf8
    Assert ((Get-Content -Raw -Encoding utf8 $htmlPath) -notmatch '새 문서.pdf') '폴더 추가만으로 이전 정적 HTML이 바뀐 것처럼 가장하지 않는다.'
    $nonce=[guid]::NewGuid().ToString('N')
    $validated=(& $handler -Uri ($baseUri+'/'+$nonce) -ValidateOnly) | ConvertFrom-Json
    Assert ($validated.action -eq 'refresh' -and -not $validated.launched) '등록된 폴더만 새로고침 검증을 통과한다.'
    $result=(& $handler -Uri ($baseUri+'/'+$nonce)) | ConvertFrom-Json
    $updated=Get-Content -Raw -Encoding utf8 $htmlPath
    Assert ($updated -match 'id="content-analysis"') 'Refresh preserves embedded console communication.'
    Assert ($result.ok -and $updated -match '>새 취합자료</button>' -and $updated -match '하위묶음 / 새 문서.pdf') '제목/F5 실행 경로가 새 탭과 하위 상대경로 문서를 생성한다.'
    $ack=Get-Content -Raw -Encoding utf8 (Join-Path $work '.ai\console-refresh.js')
    Assert ($ack -match $nonce -and $ack -match '"ok":true' -and $ack -notmatch [regex]::Escape($work)) '숨김 완료 신호에는 요청 번호와 성공 여부만 포함한다.'
    $launcher=Join-Path $workspace '.agent\shared\bin\HumanWorkOpenLauncher.exe'
    if(-not (Test-Path -LiteralPath $launcher -PathType Leaf)){ throw 'Native console launcher is not built.' }
    $fixtureManifest=Join-Path $fixture '.agent\index\human-open-targets.json'
    $newFilePayload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($newFile))).TrimEnd('=').Replace('+','-').Replace('/','_')
    $newFileRegistered=$false
    foreach($match in [regex]::Matches($updated,'href="(hwpx-work-open:(?!refresh/)[^"]+)"')) {
        $nativeValidation=Start-Process -FilePath $launcher -ArgumentList @('--validate',$match.Groups[1].Value,$fixtureManifest) -WindowStyle Hidden -Wait -PassThru
        if($nativeValidation.ExitCode -eq 0 -and $match.Groups[1].Value -match [regex]::Escape($newFilePayload)){ $newFileRegistered=$true; break }
    }
    Assert $newFileRegistered '새로 추가된 문서도 직접 실행 허용 목록에 등록된다.'
    Assert ($updated -match 'console-open-' -and $updated -match 'pollOpen' -and $updated -match '15000' -and $updated -match 'Windows가 파일 열기 요청을 받았습니다') '파일 링크는 브라우저 기본 동작으로 실행하고 승인 대기와 Windows 전달 응답을 구분한다.'
    Set-Content -LiteralPath (Join-Path $newFolder '안내.txt') -Value '변경 후 내용' -Encoding utf8
    Rename-Item -LiteralPath $newFile -NewName '이름 바꾼 문서.pdf'
    & $handler -Uri ($baseUri+'/'+[guid]::NewGuid().ToString('N')) | Out-Null
    $renamed=Get-Content -Raw -Encoding utf8 $htmlPath
    Assert ($renamed -match '변경 후 내용' -and $renamed -match '이름 바꾼 문서.pdf' -and $renamed -notmatch '새 문서.pdf') 'TXT 변경과 문서 이름 변경을 반영한다.'
    $removePath=[IO.Path]::GetFullPath($newFolder)
    if ([IO.Path]::GetDirectoryName($removePath) -ine $work) { throw 'Unsafe fixture removal' }
    Remove-Item -LiteralPath $removePath -Recurse -Force
    & $handler -Uri ($baseUri+'/'+[guid]::NewGuid().ToString('N')) | Out-Null
    Assert ((Get-Content -Raw -Encoding utf8 $htmlPath) -notmatch '>새 취합자료</button>|이름 바꾼 문서.pdf') '삭제된 폴더의 탭과 문서를 제거한다.'
    $outsidePayload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fixture)).TrimEnd('=').Replace('+','-').Replace('/','_')
    $blocked=$false
    try { & $handler -Uri ('hwpx-work-open:refresh/'+$outsidePayload+'/'+$nonce) | Out-Null } catch { $blocked=$_.Exception.Message -match 'not a registered work folder' }
    Assert $blocked '등록되지 않은 폴더는 새로고침할 수 없다.'
    $malformed=$false
    try { & $handler -Uri ($baseUri+'/bad-request') -ValidateOnly | Out-Null } catch { $malformed=$true }
    Assert $malformed '잘못된 새로고침 요청은 실행하지 않는다.'
    $workMetaPath=Join-Path $work '.ai\work.json'
    @{title='새로고침 시험';layout=@{supportFolders=@()};currentFiles=@('사라진 등록 문서.hwpx')} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $workMetaPath -Encoding utf8
    $metadataHash=(Get-FileHash -LiteralPath $workMetaPath).Hash
    $addedRoot=Join-Path $work '사람이 추가한 문서.hwpx'
    [IO.File]::WriteAllBytes($addedRoot,[Text.Encoding]::UTF8.GetBytes('fixture'))
    $rootReceipt=(& $generator -WorkFolder $work)|ConvertFrom-Json
    Assert ($rootReceipt.unregisteredRootFileCount -eq 1 -and $rootReceipt.missingRegisteredFileCount -eq 1 -and (Get-Content -Raw -Encoding utf8 $htmlPath) -match '사람이 추가한 문서.hwpx') '등록 차이가 있어도 현재 실제 파일 목록은 갱신된다.'
    Assert ((Get-FileHash -LiteralPath $workMetaPath).Hash -eq $metadataHash) '목록 갱신은 추가 파일을 승인된 현재본으로 등록하지 않는다.'
    New-Item -ItemType Directory -Path (Join-Path $work 'copies') -Force | Out-Null
    $selectedCopy=Join-Path $work 'copies\selected-copy.pdf'
    [IO.File]::WriteAllText($selectedCopy,'selected content')
    $sourceIndex=Join-Path $work '.ai\sources.json'
    $oldPath=Join-Path $fixture 'absent\original.pdf'
    @{sources=@(@{path=$oldPath;name='original.pdf';role='authority';copyRelativePath='copies\selected-copy.pdf';sha256=(Get-FileHash -LiteralPath $selectedCopy).Hash})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $sourceIndex -Encoding utf8
    $sourceHash=(Get-FileHash -LiteralPath $sourceIndex).Hash
    & $generator -WorkFolder $work | Out-Null
    $movedHtml=Get-Content -LiteralPath $htmlPath -Raw -Encoding utf8
    $copyPayload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($selectedCopy)).TrimEnd('=').Replace('+','-').Replace('/','_')
    Assert (([regex]::Matches($movedHtml,[regex]::Escape($copyPayload))).Count -eq 2) 'A selected copy with the recorded hash appears in both current files and source links after relocation.'
    Assert ((Get-FileHash -LiteralPath $sourceIndex).Hash -eq $sourceHash) 'Relocation preserves original source provenance.'
    [IO.File]::WriteAllText($selectedCopy,'different content')
    & $generator -WorkFolder $work | Out-Null
    $mismatchHtml=Get-Content -LiteralPath $htmlPath -Raw -Encoding utf8
    Assert ($mismatchHtml -match 'missing-file[^>]*>[\s\S]*?original.pdf') 'A changed copy does not replace the missing registered source.'
    [IO.File]::WriteAllText($selectedCopy,'selected content')
    $oldCabinetPath=Join-Path (Join-Path $fixture 'absent\cabinet') ((Split-Path $work -Leaf)+'\copies\selected-copy.pdf')
    @{sources=@(@{path=$oldCabinetPath;name='original.pdf';role='authority';sha256=(Get-FileHash -LiteralPath $selectedCopy).Hash})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $sourceIndex -Encoding utf8
    & $generator -WorkFolder $work | Out-Null
    $rootMovedHtml=Get-Content -LiteralPath $htmlPath -Raw -Encoding utf8
    Assert (([regex]::Matches($rootMovedHtml,[regex]::Escape($copyPayload))).Count -eq 2) 'A source under a moved cabinet is resolved only after matching its recorded hash.'
    $rootRevision='result_fix01_20260929-100000.csv'
    $nestedRevision='copies\result_fix02_20260929-100001.csv'
    foreach($relative in @($rootRevision,$nestedRevision)){[IO.File]::WriteAllText((Join-Path $work $relative),'old revision')}
    $revisionMetadata=Get-Content -LiteralPath $workMetaPath -Raw -Encoding utf8|ConvertFrom-Json
    $revisionMetadata|Add-Member -NotePropertyName revisionHistory -NotePropertyValue @(@{relativePath=$rootRevision;revisionOf='result.csv';sha256=(Get-FileHash -LiteralPath (Join-Path $work $rootRevision)).Hash},@{relativePath=$nestedRevision;revisionOf='copies\result.csv';sha256=(Get-FileHash -LiteralPath (Join-Path $work $nestedRevision)).Hash})
    $revisionMetadata|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $workMetaPath -Encoding utf8
    $revisionReceipt=(& $generator -WorkFolder $work)|ConvertFrom-Json
    $revisionHtml=Get-Content -LiteralPath $htmlPath -Raw -Encoding utf8
    $decodedRevisionHtml=[Net.WebUtility]::HtmlDecode($revisionHtml)
    Assert ($revisionReceipt.unregisteredRootFileCount -eq 1 -and $decodedRevisionHtml.Contains($rootRevision+' · 이전 버전') -and $decodedRevisionHtml.Contains('result_fix02_20260929-100001.csv · 이전 버전')) 'Registered same-folder revisions are labeled previous versions and do not create current-registration mismatch.'
    Assert (-not(Test-Path -LiteralPath (Join-Path $work 'previous_versions')) -and -not(Test-Path -LiteralPath (Join-Path $work '공통기록_변경이력'))) 'Console refresh creates no document history folders.'
    # Exercise the optional UI file-list contract with synthetic metadata, not real exam records.
    $examSystem=Join-Path $work '.ai/exam-system';New-Item -ItemType Directory -Path $examSystem -Force|Out-Null
    $revisionMetadata|Add-Member -NotePropertyName commonRecord -NotePropertyValue @{enabled=$true;schemaVersion='exam-workspace/v1'}
    $revisionMetadata|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $workMetaPath -Encoding utf8
    '{"schemaVersion":"exam-workspace/v1"}'|Set-Content -LiteralPath (Join-Path $work '.ai/exam-record.json') -Encoding utf8
    '__EXAM_RECORD_JSON__<files>__EXAM_FILE_LIST_JSON__</files>__EXAM_CONSOLE_JSON__'|Set-Content -LiteralPath (Join-Path $examSystem 'template.html') -Encoding utf8
    & $generator -WorkFolder $work|Out-Null
    $uiHtml=Get-Content -LiteralPath $htmlPath -Raw -Encoding utf8
    $uiFiles=([regex]::Match($uiHtml,'<files>([\s\S]*?)</files>').Groups[1].Value)|ConvertFrom-Json
    Assert (@($uiFiles|Where-Object {$_.relativePath -in @($rootRevision,$nestedRevision) -and $_.archived}).Count -eq 2) 'Optional UI file list classifies exact registered same-folder fix files as archived.'
    Assert (@($uiFiles|Where-Object {$_.relativePath -eq '사람이 추가한 문서.hwpx' -and -not $_.archived}).Count -eq 1) 'Unregistered current-looking file remains visible and is not silently classified as revision.'
    $revisionMetadata.commonRecord.enabled=$false;$revisionMetadata|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $workMetaPath -Encoding utf8
    & $generator -WorkFolder $work|Out-Null
    $trustedManifest=Join-Path $index 'human-open-targets.json'
    $manifestBefore=[IO.File]::ReadAllBytes($trustedManifest)
    $htmlBefore=(Get-FileHash -LiteralPath $htmlPath).Hash
    [IO.File]::WriteAllText($trustedManifest,'invalid manifest')
    $invalidBlocked=$false
    try { & $generator -WorkFolder $work|Out-Null } catch { $invalidBlocked=$true }
    Assert ($invalidBlocked -and (Get-FileHash -LiteralPath $htmlPath).Hash -eq $htmlBefore -and [IO.File]::ReadAllText($trustedManifest) -eq 'invalid manifest') 'A malformed manifest cannot overwrite HTML or erase other work registrations.'
    [IO.File]::WriteAllBytes($trustedManifest,$manifestBefore)
    [pscustomobject]@{ok=$true;count=$checks.Count;checks=@($checks)} | ConvertTo-Json -Depth 4
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -ine $cache -or [IO.Path]::GetFileName($resolved) -notlike 'console-refresh-test-*') { throw 'Unsafe fixture cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
