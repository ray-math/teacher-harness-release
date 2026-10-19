[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function ConvertTo-HashtableDeep {
    # ConvertFrom-Json -AsHashtable is PowerShell 7 only; this host runs Windows PowerShell 5.1.
    # Ordered maps keep the JSON key order these metadata files are written back with.
    [CmdletBinding()]
    param([Parameter(Position = 0, ValueFromPipeline = $true)]$Value)
    process {
        if ($null -eq $Value) { return $null }
        if ($Value -is [Management.Automation.PSCustomObject]) {
            $map = [ordered]@{}
            foreach ($property in $Value.PSObject.Properties) { $map[$property.Name] = ConvertTo-HashtableDeep $property.Value }
            return $map
        }
        if ($Value -is [Collections.IDictionary]) {
            $map = [ordered]@{}
            foreach ($key in @($Value.Keys)) { $map[$key] = ConvertTo-HashtableDeep $Value[$key] }
            return $map
        }
        if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
            return @(foreach ($item in $Value) { ConvertTo-HashtableDeep $item })
        }
        $Value
    }
}
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$errors = [Collections.Generic.List[string]]::new()
$checks = [Collections.Generic.List[string]]::new()
$token = [guid]::NewGuid().ToString('N')
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$discoveryRoot = Join-Path $tempBase ("hwpx-form-discovery-$token")
$cacheFixtureRoot = Join-Path (Join-Path $workspace '.agent\cache') ("form-console-test-$token")
$normalizationFixtureRoot = Join-Path (Join-Path $workspace '.agent\jobs') ("normalization-test-$token")
$workFolderName = "20260903_콘솔회귀-$($token.Substring(0, 8))"

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $checks.Add($Message) } else { $errors.Add($Message) }
}

function Remove-TestTree([string]$Path, [string]$AllowedRoot, [string]$RequiredPrefix) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = [IO.Path]::GetFullPath($Path)
    $rootPrefix = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\') + '\'
    if (-not $full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup target: $full" }
    if (-not [IO.Path]::GetFileName($full).StartsWith($RequiredPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unexpected test cleanup name: $full" }
    Remove-Item -LiteralPath $full -Recurse -Force
}

function New-TestHwpxPackage(
    [string]$Path,
    [string]$HeaderToken,
    [string]$BodyText,
    [switch]$AddParagraph,
    [switch]$BrokenReference
) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $parent = [IO.Path]::GetDirectoryName($Path)
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force }
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entries = [ordered]@{
            'mimetype' = 'application/hwp+zip'
            'META-INF/manifest.xml' = '<manifest />'
            'Contents/content.hpf' = ('<package><manifest><item id="header" href="Contents/header.xml" media-type="application/xml" /><item id="section0" href="{0}" media-type="application/xml" /></manifest><spine><itemref idref="header" /><itemref idref="section0" /></spine></package>' -f $(if($BrokenReference){'missing.xml'}else{'Contents/section0.xml'}))
            'Contents/header.xml' = ('<hh:head xmlns:hh="urn:test:head"><hh:refList token="{0}" /></hh:head>' -f $HeaderToken)
            'settings.xml' = '<hs:settings xmlns:hs="urn:test:settings"><hs:beginNumber page="1" /></hs:settings>'
            'Contents/section0.xml' = ('<hs:sec xmlns:hs="urn:test:section" xmlns:hp="urn:test:paragraph"><hp:p id="1"><hp:run><hp:t>{0}</hp:t></hp:run></hp:p>{1}</hs:sec>' -f ([Security.SecurityElement]::Escape($BodyText)), $(if($AddParagraph){'<hp:p id="2"><hp:run><hp:t>새 구조</hp:t></hp:run></hp:p>'}else{''}))
        }
        foreach ($pair in $entries.GetEnumerator()) {
            $entry = $archive.CreateEntry($pair.Key)
            $stream = $entry.Open()
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            try { $writer.Write([string]$pair.Value) } finally { $writer.Dispose(); $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
}

try {
    New-Item -ItemType Directory -Path $cacheFixtureRoot -Force | Out-Null
    $startScript = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $PSScriptRoot 'Start-HwpxWork.ps1')
    $publishScript = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1')
    Assert-True ($startScript -match "Update-HumanWorkConsole\.ps1" -and $publishScript -match "Update-HumanWorkConsole\.ps1") '업무 시작과 게시 흐름이 콘솔 갱신을 호출한다.'
    Assert-True ($startScript -match 'FinalPolishAuthorized' -and $startScript -match 'current-human-deliverable' -and $startScript -match "role = 'human_revision'") '후속 업무는 현재 사람 파일을 자동 human_revision으로 등록하고 최종 다듬기를 별도 승인한다.'
    Assert-True ($publishScript -match 'exact hash as human_revision' -and $publishScript -match 'Get-ActiveDocumentScope' -and $publishScript -match 'FinalPolishAuthorized=\[bool\]\(\$publishScope') '게시 단계는 사람 수정 덮어쓰기를 차단하고 job별 요청 근거를 검증한 서식 허가만 전달한다.'

    New-Item -ItemType Directory -Path (Join-Path $discoveryRoot 'nested') -Force | Out-Null
    $seed = Join-Path $discoveryRoot '참가자 현황.hwpx'
    $combinedForm = Join-Path $discoveryRoot '★2026년 2학기 방과후 출석부 및 활동일지(양식)).hwp'
    $nestedForm = Join-Path $discoveryRoot 'nested\2026년 2학기 방과후 출석부 양식.hwp'
    $standardTemplate = Join-Path $discoveryRoot '2026년 2학기 방과후 출석부 표준 서식.hwtx'
    $completedBaseline = Join-Path $discoveryRoot '2026학년도 1학기 1회고사 시행계획.hwp'
    [IO.File]::WriteAllBytes($seed, [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes($combinedForm, [byte[]](4, 5, 6))
    [IO.File]::WriteAllBytes((Join-Path $discoveryRoot '시간표.hwpx'), [byte[]](7))
    [IO.File]::WriteAllBytes($nestedForm, [byte[]](8))
    [IO.File]::WriteAllBytes($standardTemplate, [byte[]](9))
    [IO.File]::WriteAllBytes($completedBaseline, [byte[]](10, 11))

    $contextArgs = @{
        TaskTitle = '2026학년도 2학기 방과후학교 수업일지 및 출석부'
        SeedFile = @($seed)
        IncludeSiblingFiles = $true
        Limit = 20
    }
    $contextJson = & (Join-Path $PSScriptRoot 'Find-HwpxContext.ps1') @contextArgs
    $context = ($contextJson -join [Environment]::NewLine) | ConvertFrom-Json
    $sibling = @($context.candidates | Where-Object path -eq $combinedForm)
    Assert-True ($sibling.Count -eq 1) '같은 폴더의 결합 HWP 양식을 발견한다.'
    Assert-True ($sibling.Count -eq 1 -and $sibling[0].role -eq 'sibling-form') '인접 양식을 sibling-form으로 분류한다.'
    Assert-True (@($context.candidates | Where-Object path -eq $nestedForm).Count -eq 0) '인접 탐색은 하위 폴더로 재귀하지 않는다.'
    Assert-True (@($context.candidates | Where-Object path -eq $standardTemplate).Count -eq 1) 'HWTX 표준 서식도 인접 양식 후보로 발견한다.'

    $planDiscoveryPath = Join-Path $cacheFixtureRoot 'plan-discovery.json'
    $planContextJson = & (Join-Path $PSScriptRoot 'Find-HwpxContext.ps1') -TaskTitle '2026학년도 2학기 1회고사 시행계획' -SeedFile $seed -IncludeSiblingFiles -OutputPath $planDiscoveryPath
    $planContext = ($planContextJson -join [Environment]::NewLine) | ConvertFrom-Json
    $baselineCandidate = @($planContext.candidates | Where-Object path -eq $completedBaseline)
    Assert-True ($baselineCandidate.Count -eq 1 -and $baselineCandidate[0].reusableBaselineCandidate -eq $true -and $baselineCandidate[0].candidateKind -eq 'completed_baseline') '빈 양식이 아니어도 같은 업무군의 완성 문서를 재사용 구조 양식으로 발견한다.'

    $contractArgs = @{
        FormStatus = 'existing'
        AuthoritativeForm = @($combinedForm)
        FormLayout = 'combined'
        ContainedSection = @('activity_log', 'attendance')
        ReplicationAxis = @('course')
        Variant = @('1학년 수학', '1학년 수학심화')
        Dates = 'blank'
        Times = 'filled'
        Roster = 'filled'
        EnrollmentCount = 'filled'
        LessonContent = 'filled'
    }
    $contractJson = & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') @contractArgs
    $contract = ($contractJson -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($contract.deliverable_count -eq 2) '결합 양식은 강좌 두 개를 문서 두 개로 계산한다.'
    Assert-True ($contract.boundary_preserved -eq $true) '명시적 분리가 없으면 결합 경계를 보존한다.'
    Assert-True ($contract.conversion_required -eq $true) 'HWP 양식은 HWPX 변환 필요 상태로 기록한다.'

    $baselineContractJson = & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus existing -AuthoritativeForm $completedBaseline -FormLayout separate -StructureAuthorityKind completed_baseline
    $baselineContract = ($baselineContractJson -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($baselineContract.operation_mode -eq 'copy_and_fill_existing' -and $baselineContract.copy_fill_required -eq $true -and $baselineContract.typed_authoring_allowed -eq $false) '완성 선행 문서는 새 저작이 아니라 복제·내용 갱신 경로로 강제한다.'

    $hwtxContractJson = & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus existing -AuthoritativeForm $standardTemplate -FormLayout separate
    $hwtxContract = ($hwtxContractJson -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($hwtxContract.template_instantiation_required -eq $true -and $hwtxContract.normalization_mode -eq 'hwtx_template_instantiation') 'HWTX는 변환 파일이 아니라 새 HWPX를 생성할 표준 서식으로 기록한다.'

    New-Item -ItemType Directory -Path (Join-Path $normalizationFixtureRoot 'wip\docs') -Force | Out-Null
    $normalizeJson = & (Join-Path $PSScriptRoot 'Convert-SelectedInputsToHwpx.ps1') -InputFile @($seed,$combinedForm,$standardTemplate) -JobPath $normalizationFixtureRoot -PlanOnly
    $normalize = ($normalizeJson -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($normalize.policy -eq 'selected-inputs-only' -and $normalize.canonicalWorkingFormat -eq '.hwpx') '선택된 입력만 HWPX 작업 형식으로 정규화한다.'
    Assert-True (@($normalize.items | Where-Object action -eq 'convert_legacy_document').Count -eq 1) '선택된 HWP는 별도 HWPX 변환 대상으로 계획한다.'
    Assert-True (@($normalize.items | Where-Object action -eq 'copy_working_document').Count -eq 1) '선택된 HWPX는 내부 작업 사본으로 계획한다.'
    Assert-True (@($normalize.items | Where-Object action -eq 'instantiate_template').Count -eq 1) '선택된 HWTX는 새 HWPX 문서 인스턴스 생성 대상으로 계획한다.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $normalizationFixtureRoot 'wip\docs\normalized'))) '계획 단계에서는 변환본이나 복사본을 만들지 않는다.'

    $contractArgs.ExplicitInternalSplit = $true
    $splitJson = & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') @contractArgs
    $split = ($splitJson -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($split.deliverable_count -eq 4) '사용자가 내부 분리를 명시한 경우에만 문서 수를 늘린다.'

    $emptyDiscoveryPath = Join-Path $cacheFixtureRoot 'empty-discovery.json'
    [ordered]@{schemaVersion='hwpx-context.candidates/v1';taskTitle='없는 양식';candidates=@()} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $emptyDiscoveryPath -Encoding utf8
    $absentJson = & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus absent -FormLayout unknown -DiscoveryResultPath $emptyDiscoveryPath
    $absent = ($absentJson -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($absent.authoring_allowed -eq $false -and $absent.user_confirmation_required -eq $true) '양식 부재 시 자유 형식 허가 전 신규 저작을 차단한다.'
    $missingEvidenceBlocked = $false
    try { & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus absent -FormLayout unknown | Out-Null } catch { $missingEvidenceBlocked = $_.Exception.Message -match 'saved bounded-discovery' }
    Assert-True $missingEvidenceBlocked '저장된 제한 탐색 증거 없이는 form_status=absent 판정을 거부한다.'
    $baselineAbsentBlocked = $false
    try { & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus absent -FormLayout unknown -DiscoveryResultPath $planDiscoveryPath | Out-Null } catch { $baselineAbsentBlocked = $_.Exception.Message -match 'reusable form or completed baseline' }
    Assert-True $baselineAbsentBlocked '재사용 가능한 완성 문서가 발견되면 form_status=absent 판정을 거부한다.'
    $weakAuthorizationBlocked = $false
    try { & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus absent -FormLayout unknown -DiscoveryResultPath $emptyDiscoveryPath -FreeFormAuthorized -ExplicitNewFormInstruction '새 시행계획을 작성해줘' | Out-Null } catch { $weakAuthorizationBlocked = $_.Exception.Message -match 'explicit new-form instruction' }
    Assert-True $weakAuthorizationBlocked '새 문서 작성 요청을 새 양식 설계 승인으로 오해하지 않는다.'
    $explicitNewJson = & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus absent -FormLayout unknown -DiscoveryResultPath $emptyDiscoveryPath -FreeFormAuthorized -ExplicitNewFormInstruction '기존 양식 말고 새 양식으로 만들어줘'
    $explicitNew = ($explicitNewJson -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($explicitNew.typed_authoring_allowed -eq $true -and $explicitNew.operation_mode -eq 'explicit_new_form_authoring') '사용자가 새 양식을 명시한 경우에만 신규 양식 저작을 허용한다.'
    $negativeAuthorizationBlocked = $false
    try { & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus absent -FormLayout unknown -DiscoveryResultPath $emptyDiscoveryPath -FreeFormAuthorized -ExplicitNewFormInstruction '새 양식 만들지 마' | Out-Null } catch { $negativeAuthorizationBlocked = $true }
    Assert-True $negativeAuthorizationBlocked '새 양식을 만들지 말라는 금지 표현은 신규 양식 승인으로 처리하지 않는다.'
    $existingNew = (& (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus existing -AuthoritativeForm $completedBaseline -FormLayout separate -FreeFormAuthorized -ExplicitNewFormInstruction '새 양식으로 만들어줘') | ConvertFrom-Json
    Assert-True ($existingNew.operation_mode -eq 'explicit_new_form_authoring' -and -not $existingNew.copy_fill_required) '기존 양식이 있어도 명시적 새 양식 요청은 모순 없는 별도 저작 계약이 된다.'
    $parallelContractBlocked = $false
    try { & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus existing -AuthoritativeForm $completedBaseline -FormLayout separate -OutputPath (Join-Path $cacheFixtureRoot 'parallel-contract.json') | Out-Null } catch { $parallelContractBlocked = $_.Exception.Message -match 'canonical.*hwpx-form-contract\.json' }
    Assert-True $parallelContractBlocked '저장되는 양식 계약은 작업별 단일 정본명 hwpx-form-contract.json만 허용한다.'

    # 게시 경계 회귀: 계약을 무시한 신규 저작 문서는 PlanOnly에서도 게시 계획을 만들 수 없어야 한다.
    foreach ($relative in @('brief.md','inputs.json','wip\docs\normalized','wip\docs\valid','wip\docs\forged','wip\scripts','wip\previews','wip\receipts')) {
        $fixturePath = Join-Path $normalizationFixtureRoot $relative
        if ([IO.Path]::GetExtension($fixturePath)) { continue }
        New-Item -ItemType Directory -Path $fixturePath -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $normalizationFixtureRoot 'brief.md') -Encoding utf8 -Value '# form gate fixture'
    $baseForm = Join-Path $normalizationFixtureRoot 'wip\docs\normalized\기존 시행계획.hwpx'
    $validFilled = Join-Path $normalizationFixtureRoot 'wip\docs\valid\시행계획.hwpx'
    $forgedLayout = Join-Path $normalizationFixtureRoot 'wip\docs\forged\시행계획.hwpx'
    New-TestHwpxPackage -Path $baseForm -HeaderToken 'official-style' -BodyText '기존 내용'
    New-TestHwpxPackage -Path $validFilled -HeaderToken 'official-style' -BodyText '올해 내용'
    New-TestHwpxPackage -Path $forgedLayout -HeaderToken 'self-authored-style' -BodyText '올해 내용' -AddParagraph
    $normalizationRunJson = & (Join-Path $PSScriptRoot 'Convert-SelectedInputsToHwpx.ps1') -InputFile $validFilled -JobPath $normalizationFixtureRoot
    $normalizationRun = ($normalizationRunJson -join [Environment]::NewLine) | ConvertFrom-Json
    $automaticNormalizationReceipt = Join-Path $normalizationFixtureRoot 'wip\receipts\selected-input-normalization.json'
    $automaticNormalization = if (Test-Path -LiteralPath $automaticNormalizationReceipt -PathType Leaf) { Get-Content -Raw -Encoding utf8 -LiteralPath $automaticNormalizationReceipt | ConvertFrom-Json } else { $null }
    Assert-True ($normalizationRun.ok -eq $true -and $null -ne $automaticNormalization -and $automaticNormalization.items[0].sourceSha256 -eq (Get-FileHash -LiteralPath $validFilled -Algorithm SHA256).Hash) '선택 입력 정규화는 게시 게이트가 검증할 원본·출력 해시 영수증을 자동 저장한다.'
    $formContractPath = Join-Path $normalizationFixtureRoot 'wip\receipts\hwpx-form-contract.json'
    & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus existing -AuthoritativeForm $baseForm -FormLayout separate -StructureAuthorityKind completed_baseline -OutputPath $formContractPath | Out-Null

    $fakeCabinet = Join-Path $cacheFixtureRoot 'publish-cabinet'
    $fakeWorkFolderName = '20260903_게시차단회귀'
    $fakeWork = Join-Path $fakeCabinet $fakeWorkFolderName
    New-Item -ItemType Directory -Path (Join-Path $fakeWork '.ai') -Force | Out-Null
    $currentHuman = Join-Path $fakeWork '시행계획.hwpx'
    New-TestHwpxPackage -Path $currentHuman -HeaderToken 'official-style' -BodyText '현재 사람 내용'
    [ordered]@{schemaVersion='hwpx-human-work/v1';title='게시 차단 회귀';folderName=$fakeWorkFolderName;createdDate='20260903';editing=[ordered]@{mode='content_only';finalPolishAuthorized=$false}} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fakeWork '.ai\work.json') -Encoding utf8
    [ordered]@{schemaVersion='hwpx-human-sources/v1';sources=@()} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $fakeWork '.ai\sources.json') -Encoding utf8
    [ordered]@{schemaVersion='hwpx-workspace.inputs/v1';job=[IO.Path]::GetFileName($normalizationFixtureRoot);sources=@(
        [ordered]@{path=$baseForm;role='form';sha256=(Get-FileHash -LiteralPath $baseForm -Algorithm SHA256).Hash},
        [ordered]@{path=$currentHuman;role='human_revision';sha256=(Get-FileHash -LiteralPath $currentHuman -Algorithm SHA256).Hash}
    )} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $normalizationFixtureRoot 'inputs.json') -Encoding utf8
    $fakeRegistryPath = Join-Path $cacheFixtureRoot 'publish-registry.json'
    [ordered]@{schemaVersion='hwpx-human-current/v4';works=@([ordered]@{title='게시 차단 회귀';createdDate='20260903';folderName=$fakeWorkFolderName;workState='ReviewPending';stage='Review';files=@('시행계획.hwpx');metadataFolder='.ai';console='업무현황.html'})} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fakeRegistryPath -Encoding utf8
    $fakeConfigPath = Join-Path $cacheFixtureRoot 'publish-config.json'
    $fakeConfig = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') | ConvertFrom-Json | ConvertTo-HashtableDeep
    $fakeConfig.humanCabinet = $fakeCabinet
    $fakeConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fakeConfigPath -Encoding utf8
    $publishCommon = @{
        Stage='Review';TaskTitle='게시 차단 회귀';WorkFolderName=$fakeWorkFolderName;PlanOnly=$true
        DeliveryConfigPath=$fakeConfigPath;RegistryPath=$fakeRegistryPath
    }
    $missingContractBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $validFilled | Out-Null } catch { $missingContractBlocked = $_.Exception.Message -match 'form contract' }
    Assert-True $missingContractBlocked 'HWPX 게시에는 양식 계약 또는 명시적인 비양식 사유가 필요하다.'
    $nonFormBypassBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $validFilled -FormGateNotApplicable -FormGateReason '이 문서는 양식과 무관하다고 임의로 주장함' | Out-Null } catch { $nonFormBypassBlocked = $_.Exception.Message -match 'registered form|cannot be bypassed' }
    Assert-True $nonFormBypassBlocked 'inputs.json에 양식이 등록된 업무는 비양식 예외로 게시 게이트를 우회할 수 없다.'
    $validPublishJson = & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $validFilled -FormContractPath $formContractPath -FormBaseFile $baseForm
    $validPublish = ($validPublishJson -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($validPublish.formGate.ok -eq $true -and $validPublish.formGate.route -eq 'existing_form_fill') '기존 양식의 구조를 보존한 채움 결과만 게시 계획을 통과한다.'
    $forgedPublishBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $forgedLayout -FormContractPath $formContractPath -FormBaseFile $baseForm | Out-Null } catch { $forgedPublishBlocked = $_.Exception.Message -match 'structure lineage|form lineage' }
    Assert-True $forgedPublishBlocked '기존 양식 계약 아래에서 새로 설계한 구조의 문서는 게시를 차단한다.'

    $nestedContract = Join-Path $normalizationFixtureRoot 'wip\receipts\old\hwpx-form-contract.json'
    New-Item -ItemType Directory -Path (Split-Path $nestedContract) -Force | Out-Null
    Copy-Item -LiteralPath $formContractPath -Destination $nestedContract
    $nestedBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $validFilled -FormContractPath $nestedContract -FormBaseFile $baseForm | Out-Null } catch { $nestedBlocked = $_.Exception.Message -match 'canonical' }
    Assert-True $nestedBlocked '정본 이름이 같아도 receipts 하위의 오래된 계약은 게시에 사용할 수 없다.'

    $polished = Join-Path $normalizationFixtureRoot 'wip\docs\polished\시행계획.hwpx'
    New-TestHwpxPackage -Path $polished -HeaderToken 'authorized-new-style' -BodyText '올해 내용'
    $polishBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $polished -FormContractPath $formContractPath -FormBaseFile $baseForm | Out-Null } catch { $polishBlocked = $_.Exception.Message -match 'form lineage' }
    Assert-True $polishBlocked '초안에서는 내용과 무관한 서식 변경을 차단한다.'
    $fakeWorkMetadataPath = Join-Path $fakeWork '.ai\work.json'
    $fakeWorkMetadata = Get-Content -Raw $fakeWorkMetadataPath | ConvertFrom-Json | ConvertTo-HashtableDeep
    $fakeWorkMetadata.editing.finalPolishAuthorized = $true
    $fakeWorkMetadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fakeWorkMetadataPath -Encoding utf8
    $booleanScopeBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $polished -FormContractPath $formContractPath -FormBaseFile $baseForm | Out-Null } catch { $booleanScopeBlocked = $_.Exception.Message -match 'Boolean flag' }
    Assert-True $booleanScopeBlocked '서식 Boolean만 임의로 켠 게시 요청은 실제 사용자 요청 근거 없이는 거부한다.'
    . (Join-Path $PSScriptRoot 'DocumentScope.ps1')
    $fixtureScope = New-DocumentScope -JobPath $normalizationFixtureRoot -FinalPolishAuthorized -FormattingRequestText '서식을 수정해줘'
    $fakeWorkMetadata.editing.documentScope = $fixtureScope
    $fakeWorkMetadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fakeWorkMetadataPath -Encoding utf8
    $fixtureInputsPath = Join-Path $normalizationFixtureRoot 'inputs.json'
    $fixtureInputs = Get-Content -LiteralPath $fixtureInputsPath -Raw -Encoding utf8 | ConvertFrom-Json | ConvertTo-HashtableDeep
    $fixtureInputs.documentScope = $fixtureScope
    $fixtureInputs.delivery = @{workRoot=$fakeWork}
    $fixtureInputs | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixtureInputsPath -Encoding utf8
    $polishResult = (& (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $polished -FormContractPath $formContractPath -FormBaseFile $baseForm) | ConvertFrom-Json
    Assert-True ($polishResult.formGate.ok -and $polishResult.formGate.finalPolishAuthorized) '승인된 최종 다듬기는 문단·표 경계를 유지하면서 서식을 변경할 수 있다.'
    $fakeWorkMetadata.editing.finalPolishAuthorized = $false
    $fakeWorkMetadata.editing.documentScope = $null
    $fakeWorkMetadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fakeWorkMetadataPath -Encoding utf8

    $registeredHumanBytes = [IO.File]::ReadAllBytes($currentHuman)
    New-TestHwpxPackage -Path $currentHuman -HeaderToken 'official-style' -BodyText '사람이 고친 내용'
    $staleHumanBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $validFilled -FormContractPath $formContractPath -FormBaseFile $baseForm | Out-Null } catch { $staleHumanBlocked = $_.Exception.Message -match 'exact hash as human_revision' }
    Assert-True $staleHumanBlocked '접수 뒤 사람이 수정한 현재 파일을 오래된 AI 사본으로 덮어쓰지 못한다.'
    [IO.File]::WriteAllBytes($currentHuman, $registeredHumanBytes)

    $broken = Join-Path $normalizationFixtureRoot 'wip\docs\broken\시행계획.hwpx'
    New-TestHwpxPackage -Path $broken -HeaderToken 'official-style' -BodyText '올해 내용' -BrokenReference
    $brokenBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $broken -FormContractPath $formContractPath -FormBaseFile $baseForm | Out-Null } catch { $brokenBlocked = $_.Exception.Message -match 'form lineage' }
    Assert-True $brokenBlocked '겉모양이 같은 ZIP이라도 패키지 참조가 깨진 결과는 게시하지 않는다.'

    $savedInputs = Get-Content -Raw (Join-Path $normalizationFixtureRoot 'inputs.json')
    $secondForm = Join-Path $normalizationFixtureRoot 'wip\docs\normalized\두번째 양식.hwpx'
    $secondOutput = Join-Path $normalizationFixtureRoot 'wip\docs\valid\두번째 문서.hwpx'
    New-TestHwpxPackage -Path $secondForm -HeaderToken 'second-style' -BodyText '둘째 양식' -AddParagraph
    New-TestHwpxPackage -Path $secondOutput -HeaderToken 'second-style' -BodyText '둘째 결과' -AddParagraph
    $twoInputs = $savedInputs | ConvertFrom-Json | ConvertTo-HashtableDeep
    $twoInputs.sources += @{path=$secondForm;role='form';sha256=(Get-FileHash $secondForm).Hash}
    $twoInputs | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $normalizationFixtureRoot 'inputs.json') -Encoding utf8
    & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus existing -AuthoritativeForm @($baseForm,$secondForm) -FormLayout separate -OutputPath $formContractPath | Out-Null
    $missingBaseBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile @($validFilled,$secondOutput) -FormContractPath $formContractPath -FormBaseFile $baseForm | Out-Null } catch { $missingBaseBlocked = $_.Exception.Message -match 'every authoritative form' }
    Assert-True $missingBaseBlocked '별도 양식 중 하나의 기준 파일이 빠지면 산출물 수가 맞아도 게시를 차단한다.'
    $twoResult = (& (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile @($validFilled,$secondOutput) -FormContractPath $formContractPath -FormBaseFile @($baseForm,$secondForm)) | ConvertFrom-Json
    Assert-True ($twoResult.formGate.matches.Count -eq 2) '각 별도 양식과 결과의 일대일 구조 대응이 맞으면 통과한다.'
    Set-Content -LiteralPath (Join-Path $normalizationFixtureRoot 'inputs.json') -Value $savedInputs -Encoding utf8

    & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus absent -FormLayout unknown -DiscoveryResultPath $emptyDiscoveryPath -FreeFormAuthorized -ExplicitNewFormInstruction '새 양식으로 만들어줘' -Variant @('첫째','둘째') -OutputPath $formContractPath | Out-Null
    $absentCountBlocked = $false
    try { & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $validFilled -FormContractPath $formContractPath | Out-Null } catch { $absentCountBlocked = $_.Exception.Message -match 'Deliverable count' }
    Assert-True $absentCountBlocked '명시적 신규 양식 경로에도 계약의 산출물 수를 강제한다.'

    $legacyAuthority = Join-Path $discoveryRoot '기존 시행계획.hwp'
    [IO.File]::WriteAllBytes($legacyAuthority, [byte[]](21, 22, 23, 24))
    & (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') -FormStatus existing -AuthoritativeForm $legacyAuthority -FormLayout separate -StructureAuthorityKind completed_baseline -OutputPath $formContractPath | Out-Null
    [ordered]@{schemaVersion='hwpx-workspace.inputs/v1';job=[IO.Path]::GetFileName($normalizationFixtureRoot);sources=@(
        [ordered]@{path=$legacyAuthority;role='form';sha256=(Get-FileHash -LiteralPath $legacyAuthority -Algorithm SHA256).Hash},
        [ordered]@{path=$currentHuman;role='human_revision';sha256=(Get-FileHash -LiteralPath $currentHuman -Algorithm SHA256).Hash}
    )} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $normalizationFixtureRoot 'inputs.json') -Encoding utf8
    $normalizationReceiptPath = Join-Path $normalizationFixtureRoot 'wip\receipts\selected-input-normalization.json'
    [ordered]@{schemaVersion='hwpx-input-normalization/v1';items=@([ordered]@{
        sourcePath=$legacyAuthority;sourceSha256=(Get-FileHash -LiteralPath $legacyAuthority -Algorithm SHA256).Hash
        canonicalPath=$baseForm;outputSha256=(Get-FileHash -LiteralPath $baseForm -Algorithm SHA256).Hash;status='ready'
    })} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $normalizationReceiptPath -Encoding utf8
    $legacyPublishJson = & (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') @publishCommon -SourceFile $validFilled -FormContractPath $formContractPath -FormBaseFile $baseForm -NormalizationReceiptPath $normalizationReceiptPath
    $legacyPublish = ($legacyPublishJson -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($legacyPublish.formGate.ok -eq $true -and $legacyPublish.formGate.normalizationAnchored -eq $true) 'HWP 원본은 변환 영수증의 원본·정규화본 해시가 일치할 때만 양식 계보로 인정한다.'

    $cabinet = Join-Path $cacheFixtureRoot 'cabinet'
    $work = Join-Path $cabinet $workFolderName
    foreach ($folder in @(
        $work,
        (Join-Path $work '참고자료'),
        (Join-Path $work 'previous_versions\20260903-120000_최종본'),
        (Join-Path $work '추가폴더'),
        (Join-Path $work '.ai')
    )) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $lineBreak = [Environment]::NewLine
    [ordered]@{
        schemaVersion='hwpx-human-work/v1';title='콘솔 회귀';folderName=$workFolderName;createdDate='20260903'
        lastIntakeAt='2026-09-03T12:00:00+09:00';status='완료';nextAction='없음'
        review=[ordered]@{state='pending';question=("첫 번째 확인 항목" + [Environment]::NewLine + "두 번째 확인 항목")}
        layout=[ordered]@{referenceFolder='C:\이전업무';referenceTitle='이전업무';reason='회귀시험';supportFolders=@('추가폴더','참고자료')}
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $work '.ai\work.json') -Encoding utf8
    $hiddenSource = Join-Path $discoveryRoot '숨김 근거.hwpx'
    [IO.File]::WriteAllBytes($hiddenSource, [byte[]](12, 13))
    (Get-Item -LiteralPath $hiddenSource -Force).Attributes = [IO.FileAttributes]::Hidden
    [ordered]@{schemaVersion='hwpx-human-sources/v1';sources=@(
        [ordered]@{role='authority';name=[IO.Path]::GetFileName($combinedForm);path=$combinedForm},
        [ordered]@{role='authority';name=[IO.Path]::GetFileName($hiddenSource);path=$hiddenSource}
    )} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $work '.ai\sources.json') -Encoding utf8
    (Get-Item -LiteralPath (Join-Path $work '.ai') -Force).Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::Hidden
    Set-Content -LiteralPath (Join-Path $work '안내.txt') -Encoding utf8 -Value ("현재 상태: 완료" + $lineBreak + '다음 할 일: 없음')
    Set-Content -LiteralPath (Join-Path $work '학생명단.txt') -Encoding utf8 -Value '학생명: 홍길동 / 연락처: 010-1234-5678'
    Set-Content -LiteralPath (Join-Path $work '참고자료\참고 안내.txt') -Encoding utf8 -Value '참고자료 내용'
    Set-Content -LiteralPath (Join-Path $work 'previous_versions\20260903-120000_최종본\이전 안내.txt') -Encoding utf8 -Value '이전 내용'
    [IO.File]::WriteAllBytes((Join-Path $work '결과 문서.pdf'), [Text.Encoding]::ASCII.GetBytes('%PDF-1.4'))
    $hiddenParent = Join-Path $work '참고자료\숨긴 내부자료'
    New-Item -ItemType Directory -Path $hiddenParent -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $hiddenParent '노출금지.txt') -Value '숨긴 폴더의 일반 파일' -Encoding utf8
    (Get-Item -LiteralPath $hiddenParent -Force).Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::Hidden
    $metaSourcesPath = Join-Path $work '.ai\sources.json'
    $metaSources = Get-Content -Raw $metaSourcesPath | ConvertFrom-Json | ConvertTo-HashtableDeep
    $metaSources.sources += @{role='authority';path=(Join-Path $work '.ai\work.json');name='노출금지 제어정보.json'}
    $metaSources | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metaSourcesPath -Encoding utf8

    $consoleJson = & (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -WorkFolder $work -CabinetRoot $cabinet
    $console = ($consoleJson -join [Environment]::NewLine) | ConvertFrom-Json
    $html = Get-Content -Raw -Encoding utf8 -LiteralPath $console.output
    Assert-True ($console.output -eq (Join-Path $work '업무현황.html')) '업무현황 HTML을 업무폴더 바로 아래에 만든다.'
    Assert-True (($console.tabs -join '|') -eq 'workflow|홈|업무근거|추가폴더|참고자료|이전버전') 'workflow를 첫 탭에 두고 홈·업무근거와 실제 폴더 순서를 유지한다.'
    Assert-True ($console.textToggleCount -eq 4) '실제 TXT 결과·참고파일만 정확히 한 번 토글로 생성한다.'
    Assert-True ($console.fileLinkCount -eq 2) '현재 문서와 업무근거 원본을 각각 직접 실행 링크로 생성한다.'
    Assert-True ($html -notmatch 'href="file:[^"]+\.txt') 'TXT를 파일 링크로 중복 표시하지 않는다.'
    Assert-True ($html -match '현재 상태: 완료') '안전한 TXT 실제 내용을 HTML에 포함한다.'
    Assert-True ($html -match 'workflow-action workflow-legacy' -and $html -match '<footer class="intake-footer">최근 접수') '기존 다음 행동과 접수 시각을 workflow와 하단에 표시한다.'
    Assert-True ($html -notmatch '<dt>현재 상태</dt>') '업무현황 메타데이터에서 현재 상태 행을 표시하지 않는다.'
    Assert-True ($html -match 'aria-selected="true"[^>]*>workflow</button>' -and $html -notmatch '<details class="meta-block"') 'workflow가 처음 열리고 이전 업무 현황 토글을 만들지 않는다.'
    Assert-True ($html -match '<details class="review-request"><summary' -and $html -notmatch '<details class="review-request" open>' -and $html -match '첫 번째 확인 항목\r?\n두 번째 확인 항목' -and $html -match 'white-space:\s*pre-wrap') '확인 요청은 기본 닫힘 토글이며 중요 내용의 줄바꿈을 보존한다.'
    $statusAt = $html.IndexOf('id="work-panel-1"')
    $homeFileAt = $html.IndexOf('결과 문서.pdf')
    $reviewAt = $html.IndexOf('<details class="review-request">')
    Assert-True ($statusAt -ge 0 -and $homeFileAt -gt $statusAt -and $reviewAt -gt $homeFileAt) '홈에는 현재 파일 뒤에 확인 요청을 표시한다.'
    Assert-True ($html -match '\.chevron::before' -and $html -notmatch 'class="chevron"[^>]*>&gt;') '토글 화살표는 CSS 둥근 아이콘으로 표시한다.'
    Assert-True ($html -match '<button[^>]+>업무근거</button>' -and $html -match '<section class="source-group">' -and $html -match '외부 자료') '업무근거는 안전한 원본 위치 카테고리를 전용 탭에 표시한다.'
    Assert-True ($html -notmatch [regex]::Escape([IO.Path]::GetPathRoot($discoveryRoot)) -and $html -notmatch '숨김 근거\.hwpx') '업무근거는 절대경로와 숨김 원본을 HTML에 노출하지 않는다.'
    Assert-True ($html -notmatch '원본 폴더 열기' -and $html -match 'hwpx-work-open:' -and $html -match [regex]::Escape([IO.Path]::GetFileName($combinedForm))) '업무근거 링크는 폴더가 아니라 정확한 원본 파일을 직접 연다.'
    Assert-True ($html -notmatch '>\.ai<|\.ai /') '숨김 AI 폴더를 탭이나 파일 목록에 표시하지 않는다.'
    Assert-True ($html -notmatch '노출금지|숨긴 폴더의 일반 파일') '숨김 조상의 자식과 명시적으로 등록된 .ai 제어파일도 노출하지 않는다.'
    Assert-True ($html -notmatch '업무현황\.html</a>') '콘솔 자신을 파일 링크로 중복 표시하지 않는다.'
    Assert-True ($html -match '010-1234-5678|홍길동') '사용자 전용 로컬 HTML은 TXT 내용을 숨기지 않고 표시한다.'
    Assert-True ($html -notmatch '개인정보 가능성이 있어') '사용자 전용 로컬 HTML에 개인정보 숨김 안내를 만들지 않는다.'
    Assert-True ($html -match 'href="hwpx-work-open:[^"]+"' -and $html -notmatch 'href="file:[^"]+\.(?:hwp|hwpx|pdf|xlsx)') '다른 형식은 다운로드용 file 링크가 아니라 안전한 직접 실행 링크다.'
    $openUri = [regex]::Match($html, 'href="(hwpx-work-open://open/[^"]+)"').Groups[1].Value
    $handlerManifest = Join-Path $cacheFixtureRoot 'handler-manifest.json'
    $allTrusted = @($combinedForm, (Join-Path $work '결과 문서.pdf'))
    [ordered]@{schemaVersion='hwpx-human-open-targets/v1';workFolders=@([ordered]@{workFolder=$work;targets=$allTrusted})} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $handlerManifest -Encoding utf8
    $nativeLauncher = Join-Path $workspace '.agent\shared\bin\HumanWorkOpenLauncher.exe'
    if (-not (Test-Path -LiteralPath $nativeLauncher -PathType Leaf)) { throw 'Native console launcher is not built.' }
    $nativeValidation = Start-Process -FilePath $nativeLauncher -ArgumentList @('--validate',$openUri,$handlerManifest) -WindowStyle Hidden -Wait -PassThru
    Assert-True ($nativeValidation.ExitCode -eq 0) '실제 네이티브 실행기는 HTML에 게시된 정확한 파일만 검증해 연다.'
    $untrustedFile = Join-Path $work '추가폴더\등록되지 않은 문서.pdf'
    [IO.File]::WriteAllBytes($untrustedFile, [Text.Encoding]::ASCII.GetBytes('%PDF-1.4'))
    $untrustedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($untrustedFile)).TrimEnd('=').Replace('+','-').Replace('/','_')
    $nativeValidation = Start-Process -FilePath $nativeLauncher -ArgumentList @('--validate',('hwpx-work-open:open/' + $untrustedPayload),$handlerManifest) -WindowStyle Hidden -Wait -PassThru
    $untrustedBlocked = $nativeValidation.ExitCode -ne 0
    Assert-True $untrustedBlocked '직접 실행 핸들러는 HTML에 게시되지 않은 경로를 거부한다.'
    $scriptFile = Join-Path $work '추가폴더\실행금지.ps1'
    Set-Content -LiteralPath $scriptFile -Encoding utf8 -Value 'Write-Output blocked'
    $scriptPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptFile)).TrimEnd('=').Replace('+','-').Replace('/','_')
    $scriptManifest = Join-Path $cacheFixtureRoot 'script-handler-manifest.json'
    [ordered]@{schemaVersion='hwpx-human-open-targets/v1';workFolders=@([ordered]@{workFolder=$work;targets=@($scriptFile)})} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $scriptManifest -Encoding utf8
    $nativeValidation = Start-Process -FilePath $nativeLauncher -ArgumentList @('--validate',('hwpx-work-open:open/' + $scriptPayload),$scriptManifest) -WindowStyle Hidden -Wait -PassThru
    $scriptBlocked = $nativeValidation.ExitCode -ne 0
    Assert-True $scriptBlocked '직접 실행 핸들러는 실행 파일과 스크립트 형식을 거부한다.'
    Assert-True ($html -notmatch '업무 메시지|예시 링크|파일 실행 미연결') '가짜 메시지와 시안용 문구를 생성하지 않는다.'
    Assert-True ($html -match '<meta name="viewport" content="width=device-width, initial-scale=1">') '모바일 viewport를 선언한다.'
    Assert-True ($html -match '@media \(prefers-color-scheme: dark\)') '운영체제 다크모드 색상 규칙을 포함한다.'
    Assert-True ($html -match '@media \(max-width: 520px\)') '좁은 화면용 반응형 규칙을 포함한다.'
    Assert-True ($html -match '\[role="tablist"\]\s*\{[^}]*flex-wrap:\s*wrap' -and $html -match '\[role="tab"\]\s*\{[^}]*font-weight:\s*700') '탭은 줄바꿈되고 굵게 표시된다.'
    Assert-True ($html -match 'overflow-wrap:\s*anywhere') '긴 파일명은 좁은 화면에서 줄바꿈된다.'
    Assert-True ($html -match 'ArrowRight' -and $html -match 'ArrowLeft' -and $html -match 'aria-selected') '탭 클릭과 키보드 이동 스크립트를 포함한다.'
    $privateMeta = Get-Content -Raw (Join-Path $work '.ai\work.json') | ConvertFrom-Json | ConvertTo-HashtableDeep
    $privateMeta.nextAction = '담당자 010-9999-8888 연락'
    $privateMeta.review.question = 'C:\private\비공개 자료 확인'
    $privateMeta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $work '.ai\work.json') -Encoding utf8
    & (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -WorkFolder $work -CabinetRoot $cabinet | Out-Null
    $privateHtml = Get-Content -Raw -LiteralPath $console.output
    Assert-True ($privateHtml -match '010-9999-8888|C:\\private' -and $privateHtml -notmatch '내용을 숨겼습니다') '사용자 전용 로컬 HTML은 다음 할 일과 확인 요청도 그대로 표시한다.'
} catch {
    $errors.Add($_.Exception.Message)
} finally {
    try { Remove-TestTree -Path $discoveryRoot -AllowedRoot $tempBase -RequiredPrefix 'hwpx-form-discovery-' } catch { $errors.Add($_.Exception.Message) }
    try { Remove-TestTree -Path $cacheFixtureRoot -AllowedRoot (Join-Path $workspace '.agent\cache') -RequiredPrefix 'form-console-test-' } catch { $errors.Add($_.Exception.Message) }
    try { Remove-TestTree -Path $normalizationFixtureRoot -AllowedRoot (Join-Path $workspace '.agent\jobs') -RequiredPrefix 'normalization-test-' } catch { $errors.Add($_.Exception.Message) }
}

[ordered]@{
    schemaVersion = 'hwpx-form-first-console.regression/v1'
    checkedAt = Get-Date -Format 'o'
    ok = ($errors.Count -eq 0)
    checks = @($checks)
    errors = @($errors)
} | ConvertTo-Json -Depth 5
if ($errors.Count -gt 0) { exit 1 }
