[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TaskTitle,

    [string]$WorkFolder = '',
    [string[]]$Keyword = @(),
    [string[]]$SeedFile = @(),
    [string[]]$PriorFolder = @(),
    [switch]$IncludeSiblingFiles,
    [string[]]$SiblingKeyword = @(
        '양식', '서식', '일지', '출석부', '신청서', '계획', '계획서', '시행계획',
        '활동일지', '운영일지', '보고서', '확인서', '대장'
    ),
    [ValidateRange(1, 100)]
    [int]$Limit = 30,
    [switch]$SummaryOnly,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
. (Join-Path $PSScriptRoot 'WorkRegistry.ps1')
. (Join-Path $PSScriptRoot 'WorkReferenceScope.ps1')
$registry = Get-WorkRegistry -Workspace $workspace
$currentYear = (Get-Date).Year.ToString()
$allowed = @('.hwpx', '.hwtx', '.hwp', '.hwt', '.pdf', '.docx', '.xlsx', '.xls', '.pptx', '.txt')
$formKeywords = @($SiblingKeyword | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
if ($formKeywords.Count -eq 0) {
    $formKeywords = @('양식', '서식', '일지', '출석부', '신청서', '계획', '계획서', '시행계획', '활동일지', '운영일지', '보고서', '확인서', '대장')
}

function Get-CoreTokens([string]$value) {
    $value = $value.Trim("'`"")
    $clean = $value -replace '\[[^\]]+\]', ' '
    $clean = $clean -replace '20\d{2}\s*학년도?', ' '
    $clean = $clean -replace '[12]\s*학기', ' '
    $clean = $clean -replace '\d+\s*차', ' '
    $clean = $clean -replace '(본문|붙임\d*|첨부|알림|안내|협조|관련)', ' '
    @($clean -split '[\s_\-().,''"「」\[\]]+' | Where-Object { $_.Length -ge 2 } | Select-Object -Unique)
}

$tokens = @(Get-CoreTokens $TaskTitle) + @($Keyword | ForEach-Object { Get-CoreTokens $_ })
$tokens = @($tokens | Where-Object { $_ } | Select-Object -Unique)
if ($tokens.Count -eq 0) { throw 'No usable search token was derived from TaskTitle or Keyword.' }
$taskYear = if ($TaskTitle -match '(20\d{2})') { $Matches[1] } else { $currentYear }
$taskSemester = if ($TaskTitle -match '([12])\s*학기') { $Matches[1] } else { $null }

$cabinet = Assert-WorkStoragePath ([string]$config.humanCabinet)
$matchingWorks = @($registry.works | Where-Object { $_.title -eq $TaskTitle })
$registeredWork = @()
$workRoot = $null
if ($WorkFolder) {
    $workRoot = Assert-WorkStoragePath $WorkFolder
    if ([IO.Path]::GetDirectoryName($workRoot) -ine $cabinet.TrimEnd('\') -or -not (Test-WorkFolderName -Name ([IO.Path]::GetFileName($workRoot))) -or -not (Test-Path -LiteralPath $workRoot -PathType Container)) { throw 'WorkFolder must be an existing direct human work folder.' }
    $registeredWork = @($registry.works | Where-Object { $_.folderName -ieq [IO.Path]::GetFileName($workRoot) })
    if ($registeredWork.Count -and $registeredWork[0].title -ne $TaskTitle) { throw 'TaskTitle must match the selected work folder.' }
} elseif ($matchingWorks.Count -eq 1) {
    $registeredWork = $matchingWorks
    $workRoot = Join-Path $cabinet ([string]$registeredWork[0].folderName)
}
$scope = Get-WorkReferenceScope -WorkFolder $workRoot
$registeredCurrentPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
if ($registeredWork.Count) {
    foreach ($name in @($registeredWork[0].files | Where-Object { $_ })) {
        $path = Get-WorkCurrentTarget -WorkRoot $workRoot -RelativePath ([string]$name)
        if (Test-Path -LiteralPath $path -PathType Leaf) { [void]$registeredCurrentPaths.Add($path) }
    }
}
$resolvedPriorFolders = @(foreach ($folder in @($PriorFolder | Where-Object { $_ } | Select-Object -Unique)) {
    $resolved = Assert-WorkStoragePath $folder
    if (-not (Test-Path -LiteralPath $resolved -PathType Container) -or -not (Test-ReferenceVisiblePath $resolved)) { throw 'PriorFolder must be an existing visible directory.' }
    $resolved
})
$explicitRequest = @($SeedFile | Where-Object { $_ }).Count -gt 0 -or $resolvedPriorFolders.Count -gt 0
$status = if ($scope.status -eq 'ready' -or $explicitRequest -or ($scope.reason -eq 'reference_scope_not_selected' -and $registeredCurrentPaths.Count)) { 'ready' } else { 'needs_input' }
$reason = if ($status -eq 'needs_input') { if (-not $WorkFolder -and $matchingWorks.Count -gt 1) { 'multiple_matching_work_folders' } else { $scope.reason } } else { $null }
$roots = @()
if ($status -eq 'ready') {
    # Read only exact registered current files. Adjacent work folders are not source consent.
    $roots += @(foreach ($path in $registeredCurrentPaths) { [pscustomobject]@{ Role='human-current'; Path=$path; Base=115 } })
    if ($scope.status -eq 'ready') {
        $roots += @(foreach ($root in $scope.roots) {
            $base = switch ($root.role) { 'manual' { 105 }; 'current-source' { 98 }; default { 55 } }
            [pscustomobject]@{ Role=$root.role; Path=$root.path; Base=$base }
        })
    }
    $roots += @(foreach ($folder in $resolvedPriorFolders) { [pscustomobject]@{ Role='prior-source'; Path=$folder; Base=55 } })
}
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Get-FormKeywordHits([string]$Value) {
    @($formKeywords | Where-Object { $Value.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

function Get-FormPriority([string]$Role) {
    switch ($Role) {
        'designated-form' { 6 }
        'sibling-form' { 5 }
        'manual' { 4 }
        'human-current' { 4 }
        'current-source' { 3 }
        'prior-source' { 1 }
        default { 0 }
    }
}

function Get-ReuseKind([IO.FileInfo]$File) {
    if ($File.Extension -in @('.hwt', '.hwtx')) { return 'standard_template' }
    if ($File.Name -match '(양식|서식|빈\s*양식|template)') { return 'blank_form' }
    'completed_baseline'
}

$candidateBuffer = [Collections.Generic.List[object]]::new()
$resolvedSeeds = [Collections.Generic.List[string]]::new()
foreach ($seed in @($SeedFile | Where-Object { $_ })) {
    $resolved = Assert-WorkStoragePath $seed
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or -not (Test-ReferenceVisiblePath $resolved -AllowRevision)) { throw 'SeedFile must be an existing visible document.' }
    $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($allowed -notcontains $extension) { throw 'SeedFile has an unsupported document extension.' }
    $resolvedSeeds.Add($resolved)
    $seedFileInfo = Get-Item -LiteralPath $resolved -Force
    $formHits = @(Get-FormKeywordHits $seedFileInfo.Name)
    # An explicitly supplied seed with a document-type match is designated by the user/caller,
    # so it may be a form even when it was previously registered as a deliverable.
    $isForm = ($formHits.Count -gt 0 -and $extension -in @('.hwp', '.hwt', '.hwpx', '.hwtx'))
    $role = if ($isForm) { 'designated-form' } else { 'seed' }
    if ($seen.Add($resolved)) {
        $candidateBuffer.Add([pscustomobject]@{
            score = $(if ($isForm) { 220 } else { 170 })
            role = $role
            path = $resolved
            extension = $extension
            modifiedAt = $seedFileInfo.LastWriteTime.ToString('o')
            matchedTokens = @($tokens | Where-Object { $resolved.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
            matchedFormKeywords = @($formHits)
            formCandidate = [bool]$isForm
            reusableBaselineCandidate = [bool]$isForm
            candidateKind = $(if($isForm){Get-ReuseKind $seedFileInfo}else{'reference'})
            formPriority = $(Get-FormPriority $role)
            candidatePriority = $(if ($isForm) { 600 } else { 450 })
            discovery = 'seed'
        })
    }

    if (-not $IncludeSiblingFiles) { continue }
    $parent = [IO.Path]::GetDirectoryName($resolved)
    $siblings = @(
        Get-ReferenceFiles -Path $parent -DirectOnly |
            Where-Object { $allowed -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 500
    )
    $siblingMatches = foreach ($file in $siblings) {
        if ($file.FullName -ieq $resolved -or $seen.Contains($file.FullName)) { continue }
        $hits = @(Get-FormKeywordHits $file.Name)
        if ($hits.Count -eq 0) { continue }
        $taskHits = @($tokens | Where-Object { $file.FullName.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($taskHits.Count -eq 0 -and $file.Name -notmatch '(양식|서식|template)') { continue }
        $score = 180 + ($hits.Count * 8) + ($taskHits.Count * 10)
        if ($file.Name -match '(양식|서식)') { $score += 24 }
        if ($file.Name -match '(출석부.*(?:활동|운영)?일지|(?:활동|운영)?일지.*출석부)') { $score += 20 }
        if ($file.FullName -match [regex]::Escape($taskYear)) { $score += 12 }
        if ($taskSemester -and $file.Name -match ([regex]::Escape($taskSemester) + '\s*학기')) { $score += 10 }
        if ($file.Extension -in @('.hwp', '.hwt', '.hwpx', '.hwtx')) { $score += 8 }
        [pscustomobject]@{ File=$file; Score=$score; Hits=$hits; TaskHits=$taskHits }
    }
    foreach ($match in @($siblingMatches | Sort-Object @{Expression='Score';Descending=$true}, @{Expression={$_.File.LastWriteTime};Descending=$true} | Select-Object -First 12)) {
        if (-not $seen.Add($match.File.FullName)) { continue }
        $candidateBuffer.Add([pscustomobject]@{
            score = [int]$match.Score
            role = 'sibling-form'
            path = $match.File.FullName
            extension = $match.File.Extension.ToLowerInvariant()
            modifiedAt = $match.File.LastWriteTime.ToString('o')
            matchedTokens = @($match.TaskHits)
            matchedFormKeywords = @($match.Hits)
            formCandidate = $true
            reusableBaselineCandidate = $true
            candidateKind = Get-ReuseKind $match.File
            formPriority = 5
            candidatePriority = 500
            discovery = 'seed-sibling'
        })
    }
}

foreach ($root in $roots) {
    if ([string]::IsNullOrWhiteSpace([string]$root.Path)) { continue }
    foreach ($file in @(Get-ReferenceFiles -Path ([string]$root.Path))) {
        if ($allowed -notcontains $file.Extension.ToLowerInvariant()) { continue }
        if (-not $seen.Add($file.FullName)) { continue }
        $effectiveRole = [string]$root.Role
        $effectiveBase = [int]$root.Base
        if ($registeredCurrentPaths.Contains($file.FullName)) { $effectiveRole='human-current'; $effectiveBase=115 }
        $haystack = $file.FullName.ToLowerInvariant()
        $hits = @($tokens | Where-Object { $haystack.Contains($_.ToLowerInvariant()) })
        if ($hits.Count -eq 0) { continue }
        $formHits = @(Get-FormKeywordHits $file.Name)
        $isCurrentWorkFile = $effectiveRole -eq 'human-current'
        $isForm = ($formHits.Count -gt 0 -and $file.Extension.ToLowerInvariant() -in @('.hwp', '.hwt', '.hwpx', '.hwtx'))
        $score = $effectiveBase + ($hits.Count * 12)
        if ($file.Name -like "*$TaskTitle*") { $score += 30 }
        if ($file.FullName -match [regex]::Escape($taskYear)) { $score += 8 }
        if ($taskSemester -and $file.Name -match ([regex]::Escape($taskSemester) + '\s*학기')) { $score += 8 }
        if ($isForm) { $score += 18 }
        if ($file.Extension -ieq '.hwpx') { $score += 5 }
        $candidateBuffer.Add([pscustomobject]@{
            score = $score
            role = $effectiveRole
            path = $file.FullName
            extension = $file.Extension.ToLowerInvariant()
            modifiedAt = $file.LastWriteTime.ToString('o')
            matchedTokens = @($hits)
            matchedFormKeywords = @($formHits)
            formCandidate = [bool]$isForm
            reusableBaselineCandidate = [bool]$isForm
            candidateKind = $(if($isForm -and $isCurrentWorkFile){'current_human_revision'}elseif($isForm){Get-ReuseKind $file}else{'reference'})
            formPriority = $(if ($isForm) { Get-FormPriority $effectiveRole } else { 0 })
            candidatePriority = $(if ($isForm) { (Get-FormPriority $effectiveRole) * 100 } else { 0 })
            discovery = 'selected-source'
        })
    }
}

$ranked = @(
    $candidateBuffer |
        Sort-Object @{Expression='candidatePriority';Descending=$true}, @{Expression='score';Descending=$true}, @{Expression='modifiedAt';Descending=$true} |
        Select-Object -First $Limit
)
$result = if ($SummaryOnly) {
    [ordered]@{
        schemaVersion = 'hwpx-context.summary/v1'
        status = $status
        reason = $reason
        workFolder = $workRoot
        referenceScope = [ordered]@{ path=$scope.scopePath; sha256=$scope.scopeSha256; source=$scope.source; groupId=$scope.groupId; status=$scope.status; noReferences=$scope.noReferences; roots=@($scope.roots); missingPaths=@($scope.missingPaths) }
        taskTitle = $TaskTitle
        tokens = @($tokens)
        seedFiles = @($resolvedSeeds)
        priorFolders = @($resolvedPriorFolders)
        candidateCount = $ranked.Count
        formCandidateCount = @($ranked | Where-Object formCandidate).Count
        reusableBaselineCandidateCount = @($ranked | Where-Object reusableBaselineCandidate).Count
        siblingCandidateCount = @($ranked | Where-Object discovery -eq 'seed-sibling').Count
        byRole = @($ranked | Group-Object role | Sort-Object Name | ForEach-Object { [ordered]@{ role=$_.Name; count=$_.Count } })
        byExtension = @($ranked | Group-Object extension | Sort-Object Name | ForEach-Object { [ordered]@{ extension=$_.Name; count=$_.Count } })
    }
} else {
    [ordered]@{
        schemaVersion = 'hwpx-context.candidates/v1'
        status = $status
        reason = $reason
        workFolder = $workRoot
        referenceScope = [ordered]@{ path=$scope.scopePath; sha256=$scope.scopeSha256; source=$scope.source; groupId=$scope.groupId; status=$scope.status; noReferences=$scope.noReferences; roots=@($scope.roots); missingPaths=@($scope.missingPaths) }
        taskTitle = $TaskTitle
        tokens = @($tokens)
        seedFiles = @($resolvedSeeds)
        priorFolders = @($resolvedPriorFolders)
        candidates = @($ranked)
    }
}
if ($status -eq 'needs_input') { $result['next'] = 'Ask which manual, current materials and prior-year folder to use, then save the selected scope. Use NoReferences only when the user says no references are needed.' }
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.Path]::GetExtension($resolvedOutput) -ine '.json') { throw 'OutputPath must end in .json.' }
    $resolvedOutput = Assert-WorkStoragePath $resolvedOutput
    $outputInfo = Get-WorkJobInfo -Workspace $workspace -Path $resolvedOutput
    if ($workRoot -and $outputInfo.workRoot -ine $workRoot) { throw 'OutputPath belongs to a different work folder.' }
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($resolvedOutput)) -Force | Out-Null
    [IO.File]::WriteAllText($resolvedOutput, ($result | ConvertTo-Json -Depth 9), [Text.UTF8Encoding]::new($false))
}
$result | ConvertTo-Json -Depth 9
