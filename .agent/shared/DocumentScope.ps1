# This is a scope-evidence gate, not authentication of the human speaker.
function Get-DocumentScopeTextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','') }
    finally { $sha.Dispose() }
}

function Assert-ExplicitDocumentRequest([string]$Text, [string]$Capability) {
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Document scope requires the exact explicit user request; a Boolean flag is not authorization.' }
    # Supply the relevant affirmative clause verbatim, never an agent-written rationale.
    if ($Text -match '(하지\s*마|지\s*말|바꾸지|건드리지|다듬지|변경\s*없이|수정\s*없이|금지|중단|원래대로|되돌|취소|do\s+not|don.t|stop|revoke)') { throw 'Document scope request contains a prohibition or revocation.' }
    if ($Capability -eq 'format_edit') {
        $target = '(서식|글꼴|서체|폰트|정렬|줄\s*간격|행\s*높이|열\s*너비|여백|쪽\s*(배치|구성)|레이아웃|format|layout|font|spacing|margin)'
        $action = '(수정|변경|바꿔|바꾸|고쳐|조정|다듬|맞춰|맞추|줄여|늘려|설정|해줘|해주세요|change|adjust|polish|set|fix)'
        $pattern = "($target.*$action|$action.*$target|새\s*양식.*(만들|작성|설계))"
    } else {
        $target = '(서식|시각|외관|쪽\s*배치|레이아웃|모든\s*쪽|PDF|visual|layout|render)'
        $action = '(점검|검수|확인|검사|렌더|출력|변환|생성|만들|저장|봐|check|review|render|export|convert|save)'
        $pattern = "($target.*$action|$action.*$target)"
    }
    if ($Text -notmatch $pattern) { throw "Document scope requires an explicit $Capability request; final/submission/merge/continue alone is insufficient." }
}

function New-DocumentScope {
    param([string]$JobPath, [switch]$FinalPolishAuthorized, [switch]$VisualReviewAuthorized,
          [string]$FormattingRequestText='', [string]$VisualReviewRequestText='')
    if ($FinalPolishAuthorized) { Assert-ExplicitDocumentRequest $FormattingRequestText 'format_edit' }
    elseif ($FormattingRequestText) { throw 'FormattingRequestText requires FinalPolishAuthorized.' }
    if ($VisualReviewAuthorized) { Assert-ExplicitDocumentRequest $VisualReviewRequestText 'visual_review' }
    elseif ($VisualReviewRequestText) { throw 'VisualReviewRequestText requires VisualReviewAuthorized.' }
    [ordered]@{
        schemaVersion='hwpx-document-scope/v1'; id=[guid]::NewGuid().ToString('D')
        jobPath=[IO.Path]::GetFullPath($JobPath); recordedAt=(Get-Date -Format 'o')
        formatEditAllowed=[bool]$FinalPolishAuthorized; visualReviewAllowed=[bool]$VisualReviewAuthorized
        formatRequest=$(if($FinalPolishAuthorized){[ordered]@{text=$FormattingRequestText;sha256=(Get-DocumentScopeTextHash $FormattingRequestText)}}else{$null})
        visualRequest=$(if($VisualReviewAuthorized){[ordered]@{text=$VisualReviewRequestText;sha256=(Get-DocumentScopeTextHash $VisualReviewRequestText)}}else{$null})
    }
}

function Get-ActiveDocumentScope([string]$JobPath) {
    $job = [IO.Path]::GetFullPath($JobPath)
    $inputPath = Join-Path $job 'inputs.json'
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw 'Document scope requires active job inputs.' }
    $inputs = Get-Content -LiteralPath $inputPath -Raw -Encoding utf8 | ConvertFrom-Json
    $scope = $inputs.documentScope
    if (-not $scope) { return $null } # Legacy content-only jobs remain usable.
    if ($scope.schemaVersion -ne 'hwpx-document-scope/v1' -or $scope.jobPath -ine $job) { throw 'Document scope is bound to another job or an unsupported schema.' }
    if (-not $inputs.delivery.workRoot) { throw 'Document scope requires a work binding.' }
    $workPath = Join-Path ([string]$inputs.delivery.workRoot) '.ai\work.json'
    $work = Get-Content -LiteralPath $workPath -Raw -Encoding utf8 | ConvertFrom-Json
    # The current work intake is also checked, so an old job or cached receipt
    # cannot restore a scope after a newer intake/revocation.
    if (-not $work.editing.documentScope -or $work.editing.documentScope.id -ne $scope.id) { return $null }
    if ($inputs.delivery.workId -and $inputs.delivery.workId -ne $work.workId) { throw 'Document scope work identity changed.' }
    if (($work.editing.documentScope | ConvertTo-Json -Depth 10 -Compress) -cne ($scope | ConvertTo-Json -Depth 10 -Compress)) { throw 'Document scope records disagree between job and current work.' }
    foreach ($pair in @(@('formatEditAllowed','formatRequest','format_edit'),@('visualReviewAllowed','visualRequest','visual_review'))) {
        if ($scope.($pair[0]) -eq $true) {
            $request = $scope.($pair[1])
            Assert-ExplicitDocumentRequest ([string]$request.text) $pair[2]
            if ($request.sha256 -ine (Get-DocumentScopeTextHash ([string]$request.text))) { throw 'Document scope request hash changed.' }
        }
    }
    $scope
}

function Assert-DocumentCapability([string]$JobPath, [string]$Capability) {
    $scope = Get-ActiveDocumentScope $JobPath
    $allowed = $scope -and $(if($Capability -eq 'format_edit'){$scope.formatEditAllowed -eq $true}else{$scope.visualReviewAllowed -eq $true})
    if (-not $allowed) { throw "Document scope blocks ${Capability}: no active explicit user-request evidence for this job. Do not enable a flag or invent permission." }
    $scope
}
