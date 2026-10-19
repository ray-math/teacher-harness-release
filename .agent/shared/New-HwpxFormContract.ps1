[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('existing', 'absent', 'unreadable')]
    [string]$FormStatus,

    [string[]]$AuthoritativeForm = @(),

    [Parameter(Mandatory = $true)]
    [ValidateSet('combined', 'separate', 'unknown')]
    [string]$FormLayout,

    [string[]]$ContainedSection = @(),
    [string[]]$ReplicationAxis = @(),
    [string[]]$Variant = @(),
    [ValidateSet('blank', 'filled', 'source', 'not_applicable')]
    [string]$Dates = 'source',
    [ValidateSet('blank', 'filled', 'source', 'not_applicable')]
    [string]$Times = 'source',
    [ValidateSet('blank', 'filled', 'source', 'not_applicable')]
    [string]$Roster = 'source',
    [ValidateSet('blank', 'filled', 'source', 'not_applicable')]
    [string]$EnrollmentCount = 'source',
    [ValidateSet('blank', 'filled', 'source', 'not_applicable')]
    [string]$LessonContent = 'source',
    [switch]$ExplicitInternalSplit,
    [switch]$FreeFormAuthorized,
    [string]$ExplicitNewFormInstruction = '',
    [string]$DiscoveryResultPath = '',
    [ValidateSet('blank_form', 'standard_template', 'completed_baseline', 'current_human_revision', 'mixed', 'unspecified')]
    [string]$StructureAuthorityKind = 'unspecified',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
# This harness fills an existing document; legacy free-form switches never
# authorize creating a layout without a selected existing draft/form.
if ($FreeFormAuthorized) { throw 'needs_input: New form authoring is disabled. Ask for an existing draft or form.' }

function Get-RelativePathCompat([string]$Root, [string]$Path) {
    # [IO.Path]::GetRelativePath is .NET Core only; this host runs Windows PowerShell 5.1.
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ($pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) { return $pathFull.Substring($rootFull.Length + 1) }
    if ($pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return '.' }
    [Uri]::UnescapeDataString(([Uri]($rootFull + '\')).MakeRelativeUri([Uri]$pathFull).ToString()).Replace('/', '\')
}
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$forms = [Collections.Generic.List[object]]::new()
foreach ($path in @($AuthoritativeForm | Where-Object { $_ })) {
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path).Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "AuthoritativeForm is not a file: $resolved" }
    $forms.Add([ordered]@{
        path = $resolved
        extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
        sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    })
}
if ($FormStatus -eq 'existing' -and $forms.Count -eq 0) { throw 'FormStatus existing requires at least one AuthoritativeForm.' }
if ($FormStatus -eq 'unreadable' -and $forms.Count -eq 0) { throw 'FormStatus unreadable requires the unreadable candidate in AuthoritativeForm.' }
if ($FormStatus -eq 'absent' -and $forms.Count -gt 0) { throw 'FormStatus absent cannot include AuthoritativeForm.' }
if ($FormStatus -eq 'existing' -and $FormLayout -eq 'unknown') { throw 'An existing form requires combined or separate FormLayout.' }
if ($FormLayout -eq 'combined' -and $ContainedSection.Count -eq 0) { throw 'A combined form requires at least one ContainedSection.' }
if ($ExplicitInternalSplit -and $FormLayout -ne 'combined') { throw 'ExplicitInternalSplit is meaningful only for a combined form.' }

$discoveryEvidence = $null
if (-not [string]::IsNullOrWhiteSpace($DiscoveryResultPath)) {
    $resolvedDiscovery = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $DiscoveryResultPath).Path)
    if (-not (Test-Path -LiteralPath $resolvedDiscovery -PathType Leaf)) { throw "DiscoveryResultPath is not a file: $resolvedDiscovery" }
    $discoveryEvidence = Get-Content -Raw -Encoding utf8 -LiteralPath $resolvedDiscovery | ConvertFrom-Json
}
if ($FormStatus -eq 'absent') {
    if ($null -eq $discoveryEvidence) { throw 'FormStatus absent requires a saved bounded-discovery result.' }
    $reusableCandidates = @($discoveryEvidence.candidates | Where-Object { $_.reusableBaselineCandidate -eq $true -or $_.formCandidate -eq $true })
    if ($reusableCandidates.Count -gt 0) {
        throw 'FormStatus cannot be absent while bounded discovery contains a reusable form or completed baseline.'
    }
}

$newFormPattern = '(?i)(새(?:로운)?\s*양식|양식을?\s*새로\s*(?:만들|작성|디자인)|자유\s*형식|백지(?:에서|로)|기존\s*양식.{0,20}(?:쓰지|사용하지|버리고)|new\s+form|free[ -]?form|from\s+scratch)'
$negativeNewFormPattern = '(?i)(새(?:로운)?\s*양식|자유\s*형식|백지).{0,30}(만들지|작성하지|하지\s*마|안\s*(만들|돼)|금지|필요\s*없)|(?:do\s*not|don.t|never).{0,30}(new\s+form|free[ -]?form|scratch)'
$explicitNewFormAuthorized = [bool]$FreeFormAuthorized -and -not [string]::IsNullOrWhiteSpace($ExplicitNewFormInstruction) -and $ExplicitNewFormInstruction -match $newFormPattern -and $ExplicitNewFormInstruction -notmatch $negativeNewFormPattern
if ($FreeFormAuthorized -and -not $explicitNewFormAuthorized) {
    throw 'FreeFormAuthorized requires the user''s explicit new-form instruction. “새 문서를 작성” alone does not authorize a new layout.'
}

$personalPattern = '\b\d{6}-?\d{7}\b|(?<!\d)01[016789][ -]?\d{3,4}[ -]?\d{4}(?!\d)|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}'
foreach ($value in @($ReplicationAxis) + @($Variant) + @($ExplicitNewFormInstruction)) {
    if ($value -match $personalPattern) { throw 'The form contract must not persist personal identifiers, phone numbers, or email addresses.' }
}

$variantCount = [Math]::Max(1, @($Variant | Where-Object { $_ }).Count)
$deliverableCount = 0
if ($FormStatus -eq 'existing') {
    if ($FormLayout -eq 'combined') {
        $deliverableCount = $variantCount
        if ($ExplicitInternalSplit) { $deliverableCount *= [Math]::Max(1, @($ContainedSection | Where-Object { $_ }).Count) }
    } elseif ($FormLayout -eq 'separate') {
        $deliverableCount = $variantCount * [Math]::Max(1, $forms.Count)
    }
} elseif ($FormStatus -eq 'absent' -and $explicitNewFormAuthorized) {
    $deliverableCount = $variantCount
}

$legacyHwp = @($forms | Where-Object extension -eq '.hwp').Count -gt 0
$standardTemplate = @($forms | Where-Object extension -eq '.hwtx').Count -gt 0
$normalizationMode = if ($legacyHwp -and $standardTemplate) {
    'mixed_conversion_and_instantiation'
} elseif ($legacyHwp) {
    'legacy_hwp_conversion'
} elseif ($standardTemplate) {
    'hwtx_template_instantiation'
} else {
    'direct_hwpx'
}
$operationMode = if ($explicitNewFormAuthorized -and $FormStatus -ne 'unreadable') {
    'explicit_new_form_authoring'
} elseif ($FormStatus -eq 'existing') {
    'copy_and_fill_existing'
} elseif ($FormStatus -eq 'unreadable') {
    'normalize_then_copy_and_fill'
} elseif ($explicitNewFormAuthorized) {
    'explicit_new_form_authoring'
} else {
    'await_existing_form_or_user_instruction'
}
$contract = [ordered]@{
    status = $(if ($FormStatus -eq 'existing') { 'ready' } else { 'needs_input' })
    schemaVersion = 'hwpx-form-contract/v1'
    decidedAt = Get-Date -Format 'o'
    form_status = $FormStatus
    authoritative_form = @($forms)
    form_layout = $FormLayout
    structure_authority_kind = $StructureAuthorityKind
    operation_mode = $operationMode
    contained_sections = @($ContainedSection | Where-Object { $_ } | Select-Object -Unique)
    replication_axis = @($ReplicationAxis | Where-Object { $_ } | Select-Object -Unique)
    variants = @($Variant | Where-Object { $_ })
    deliverable_count = $deliverableCount
    fill_policy = [ordered]@{
        dates = $Dates
        times = $Times
        roster = $Roster
        enrollment_count = $EnrollmentCount
        lesson_content = $LessonContent
    }
    explicit_internal_split = [bool]$ExplicitInternalSplit
    structural_changes_allowed = ([bool]$ExplicitInternalSplit -or $explicitNewFormAuthorized)
    boundary_preserved = -not [bool]$ExplicitInternalSplit
    authoring_allowed = $explicitNewFormAuthorized
    form_fill_allowed = ($FormStatus -eq 'existing' -and -not $explicitNewFormAuthorized)
    typed_authoring_allowed = $explicitNewFormAuthorized
    copy_fill_required = ($FormStatus -eq 'existing' -and -not $explicitNewFormAuthorized)
    user_confirmation_required = ($FormStatus -ne 'existing')
    explicit_new_form_authorized = $explicitNewFormAuthorized
    explicit_new_form_instruction = $(if($explicitNewFormAuthorized){$ExplicitNewFormInstruction.Trim()}else{''})
    discovery_evidence = $(if($discoveryEvidence){[IO.Path]::GetFullPath($DiscoveryResultPath)}else{$null})
    discovery_sha256 = $(if($discoveryEvidence){(Get-FileHash -LiteralPath $resolvedDiscovery -Algorithm SHA256).Hash}else{$null})
    canonical_working_format = '.hwpx'
    normalization_mode = $normalizationMode
    conversion_required = ($FormStatus -eq 'unreadable' -or $legacyHwp)
    template_instantiation_required = $standardTemplate
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
    if ([IO.Path]::GetExtension($resolvedOutput) -ine '.json') { throw 'OutputPath must end in .json.' }
    if ([IO.Path]::GetFileName($resolvedOutput) -ine 'hwpx-form-contract.json') {
        throw 'Saved form contracts must use the canonical receipt name hwpx-form-contract.json.'
    }
    . (Join-Path $PSScriptRoot 'WorkStorage.ps1')
    $resolvedOutput = Assert-WorkStoragePath $resolvedOutput
    $jobInfo = Get-WorkJobInfo -Workspace $workspace -Path $resolvedOutput
    if ($resolvedOutput -ine (Join-Path $jobInfo.jobRoot 'wip\receipts\hwpx-form-contract.json')) {
        throw 'The canonical contract path must be <job>/wip/receipts/hwpx-form-contract.json, not a nested or parallel receipt.'
    }
    $parent = [IO.Path]::GetDirectoryName($resolvedOutput)
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $contract | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
}
$contract | ConvertTo-Json -Depth 8
