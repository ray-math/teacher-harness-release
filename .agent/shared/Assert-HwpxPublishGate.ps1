[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$JobPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SourceFile,

    [string]$FormContractPath = '',
    [string[]]$FormBaseFile = @(),
    [string]$NormalizationReceiptPath = '',
    [switch]$FinalPolishAuthorized,
    [switch]$FormGateNotApplicable,
    [string]$FormGateReason = ''
)

$ErrorActionPreference = 'Stop'
$resolvedJob = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $JobPath).Path)
. (Join-Path $PSScriptRoot 'DocumentScope.ps1')
if ($FinalPolishAuthorized) { Assert-DocumentCapability $resolvedJob 'format_edit' | Out-Null }
$workspace = [IO.Path]::GetFullPath((Join-Path $resolvedJob '..\..\..'))
$jobPrefix = $resolvedJob.TrimEnd('\') + '\'
$docsPrefix = [IO.Path]::GetFullPath((Join-Path $resolvedJob 'wip\docs')).TrimEnd('\') + '\'
$receiptsPrefix = [IO.Path]::GetFullPath((Join-Path $resolvedJob 'wip\receipts')).TrimEnd('\') + '\'

function Resolve-JobFile([string]$Path, [string]$ExpectedPrefix, [string]$Label) {
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "$Label is not a file: $resolved" }
    if (-not $resolved.StartsWith($ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay inside the active job: $resolved"
    }
    $resolved
}

function Resolve-DeclaredPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    if ($Path -match '^(?i)wip[\\/]') { return [IO.Path]::GetFullPath((Join-Path $resolvedJob $Path)) }
    [IO.Path]::GetFullPath((Join-Path $workspace $Path))
}

function Get-EntryBytes([IO.Compression.ZipArchive]$Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if ($null -eq $entry) { return $null }
    $stream = $entry.Open()
    try {
        $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); $memory.ToArray() } finally { $memory.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-BytesHash([byte[]]$Bytes) {
    if ($null -eq $Bytes) { return $null }
    $sha = [Security.Cryptography.SHA256]::Create()
    # [Convert]::ToHexString is .NET Core only; this host runs Windows PowerShell 5.1.
    try { ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('X2') }) -join '' } finally { $sha.Dispose() }
}

function Get-XmlShapeHash([byte[]]$Bytes, [string]$Label) {
    if ($null -eq $Bytes) { throw "Missing HWPX XML member: $Label" }
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    try { $document = [xml]$text } catch { throw "Invalid HWPX XML member $Label`: $($_.Exception.Message)" }
    $tokens = [Collections.Generic.List[string]]::new()
    function Add-ShapeNode([Xml.XmlNode]$Node, [Collections.Generic.List[string]]$Target) {
        if ($Node.NodeType -ne [Xml.XmlNodeType]::Element) { return }
        # Plain text in an existing run may materialize an absent text container.
        # Keep run attributes and any inline controls in the structural signature.
        if ($Node.LocalName -eq 't' -and $Node.NamespaceURI -eq 'http://www.hancom.co.kr/hwpml/2011/paragraph' -and
            $Node.ParentNode.LocalName -eq 'run' -and $Node.Attributes.Count -eq 0 -and
            @($Node.ChildNodes | Where-Object { $_.NodeType -eq [Xml.XmlNodeType]::Element }).Count -eq 0) { return }
        # Cached line metrics are regenerated on ordinary text edits, not a new form.
        if ($Node.LocalName -eq 'linesegarray') { return }
        if ($FinalPolishAuthorized -and $Node.LocalName -in @('lineBreak','lineSpacing','paraMargin','pagePr','pageBorderFill','pos','sz','outMargin','inMargin','cellMargin','cellSz')) { return }
        $Target.Add('E|' + $Node.NamespaceURI + '|' + $Node.LocalName)
        foreach ($attribute in @($Node.Attributes | Sort-Object NamespaceURI, LocalName)) {
            if ($attribute.Prefix -eq 'xmlns' -or $attribute.Name -eq 'xmlns') { continue }
            if ($FinalPolishAuthorized -and $attribute.LocalName -notin @('rowCnt','colCnt','rowAddr','colAddr','rowSpan','colSpan','sectionCnt','binaryItemIDRef')) { continue }
            $Target.Add('A|' + $attribute.NamespaceURI + '|' + $attribute.LocalName + '=' + $attribute.Value)
        }
        foreach ($child in @($Node.ChildNodes)) { Add-ShapeNode -Node $child -Target $Target }
        $Target.Add('/E')
    }
    Add-ShapeNode -Node $document.DocumentElement -Target $tokens
    Get-BytesHash ([Text.Encoding]::UTF8.GetBytes(($tokens -join "`n")))
}

function Test-FormLineage([string]$BasePath, [string]$CandidatePath) {
    $basePackage = & (Join-Path $PSScriptRoot 'Test-HwpxPackageIntegrity.ps1') -Path $BasePath
    $candidatePackage = & (Join-Path $PSScriptRoot 'Test-HwpxPackageIntegrity.ps1') -Path $CandidatePath
    if (($basePackage.spine -join '|') -ne ($candidatePackage.spine -join '|') -or
        ($basePackage.references -join '|') -ne ($candidatePackage.references -join '|')) {
        return [pscustomobject]@{Ok=$false;Reason='section order or package references changed'}
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $baseArchive = [IO.Compression.ZipFile]::OpenRead($BasePath)
    $candidateArchive = [IO.Compression.ZipFile]::OpenRead($CandidatePath)
    try {
        foreach ($required in @('mimetype','META-INF/manifest.xml','Contents/content.hpf','Contents/header.xml','settings.xml')) {
            if ($null -eq $baseArchive.GetEntry($required) -or $null -eq $candidateArchive.GetEntry($required)) {
                return [pscustomobject]@{ Ok=$false; Reason="missing required member: $required" }
            }
        }
        $invariants = @($baseArchive.Entries.FullName | Where-Object { $_ -match '^BinData/' })
        if (-not $FinalPolishAuthorized) { $invariants += @('Contents/header.xml','settings.xml') }
        foreach ($invariant in $invariants) {
            if ((Get-BytesHash (Get-EntryBytes $baseArchive $invariant)) -ne (Get-BytesHash (Get-EntryBytes $candidateArchive $invariant))) {
                if ($invariant -eq 'Contents/header.xml') {
                    # Repair may reserialize the XML declaration only. Keep the entire root byte-exact.
                    $oldHeader=[Text.Encoding]::UTF8.GetString((Get-EntryBytes $baseArchive $invariant))
                    $newHeader=[Text.Encoding]::UTF8.GetString((Get-EntryBytes $candidateArchive $invariant))
                    $oldRoot=[regex]::Replace($oldHeader,'\A<\?xml\s+[^?]*\?>\s*','')
                    $newRoot=[regex]::Replace($newHeader,'\A<\?xml\s+[^?]*\?>\s*','')
                    if ($oldRoot -ceq $newRoot) { continue }
                }
                return [pscustomobject]@{ Ok=$false; Reason="invariant member changed: $invariant" }
            }
        }
        $baseSections = @($baseArchive.Entries.FullName | Where-Object { $_ -match '^Contents/section\d+\.xml$' } | Sort-Object)
        $candidateSections = @($candidateArchive.Entries.FullName | Where-Object { $_ -match '^Contents/section\d+\.xml$' } | Sort-Object)
        if (($baseSections -join '|') -ne ($candidateSections -join '|')) {
            return [pscustomobject]@{ Ok=$false; Reason='section member set changed' }
        }
        foreach ($section in $baseSections) {
            $baseShape = Get-XmlShapeHash (Get-EntryBytes $baseArchive $section) $section
            $candidateShape = Get-XmlShapeHash (Get-EntryBytes $candidateArchive $section) $section
            if ($baseShape -ne $candidateShape) {
                return [pscustomobject]@{ Ok=$false; Reason="section structure changed: $section" }
            }
        }
        [pscustomobject]@{ Ok=$true; Reason='' }
    } finally {
        $candidateArchive.Dispose()
        $baseArchive.Dispose()
    }
}

$sources = @($SourceFile | ForEach-Object { Resolve-JobFile $_ $docsPrefix 'SourceFile' })
if ($sources.Count -eq 0) { throw 'At least one HWPX SourceFile is required for the form gate.' }
$inputsPath = Join-Path $resolvedJob 'inputs.json'
if (-not (Test-Path -LiteralPath $inputsPath -PathType Leaf)) { throw "Active job inputs are missing: $inputsPath" }
$inputs = Get-Content -Raw -Encoding utf8 -LiteralPath $inputsPath | ConvertFrom-Json
$registeredForms = @($inputs.sources | Where-Object role -eq 'form')

if ([string]::IsNullOrWhiteSpace($FormContractPath)) {
    if (-not $FormGateNotApplicable) {
        throw 'HWPX publish requires a canonical form contract or an explicit non-form reason.'
    }
    if ([string]::IsNullOrWhiteSpace($FormGateReason) -or $FormGateReason.Trim().Length -lt 12) {
        throw 'FormGateNotApplicable requires a concrete reason recorded for this document.'
    }
    if ($registeredForms.Count -gt 0) { throw 'A registered form cannot be bypassed with FormGateNotApplicable.' }
    if (Test-Path -LiteralPath (Join-Path $resolvedJob 'wip\receipts\hwpx-form-contract.json')) { throw 'An active form contract cannot be bypassed with FormGateNotApplicable.' }
    foreach ($source in $sources) {
        if ([IO.Path]::GetExtension($source) -ieq '.hwpx') { & (Join-Path $PSScriptRoot 'Test-HwpxPackageIntegrity.ps1') -Path $source | Out-Null }
    }
    [ordered]@{schemaVersion='hwpx-publish-form-gate/v1';ok=$true;route='not_form_like';reason=$FormGateReason.Trim();sources=$sources} | ConvertTo-Json -Depth 5
    return
}
if ($FormGateNotApplicable) { throw 'Do not combine FormContractPath with FormGateNotApplicable.' }

$contractPath = Resolve-JobFile $FormContractPath $receiptsPrefix 'FormContractPath'
if ($contractPath -ine (Join-Path $resolvedJob 'wip\receipts\hwpx-form-contract.json')) {
    throw 'The form contract must use the canonical receipt name wip/receipts/hwpx-form-contract.json; stale or parallel contracts are not accepted.'
}
$contract = Get-Content -Raw -Encoding utf8 -LiteralPath $contractPath | ConvertFrom-Json
if ([string]$contract.schemaVersion -ne 'hwpx-form-contract/v1') { throw 'Unsupported form contract schema.' }
if ([string]$contract.form_status -eq 'unreadable') { throw 'An unreadable form candidate cannot be published; normalize and establish an existing-form contract first.' }

# Recompute decisions from evidence instead of trusting editable boolean flags.
$recheckArgs = @{
    FormStatus=[string]$contract.form_status; FormLayout=[string]$contract.form_layout
    AuthoritativeForm=@($contract.authoritative_form | ForEach-Object path)
    ContainedSection=@($contract.contained_sections); ReplicationAxis=@($contract.replication_axis); Variant=@($contract.variants)
    StructureAuthorityKind=[string]$contract.structure_authority_kind
    ExplicitInternalSplit=[bool]$contract.explicit_internal_split
    FreeFormAuthorized=[bool]$contract.explicit_new_form_authorized
    ExplicitNewFormInstruction=[string]$contract.explicit_new_form_instruction
    DiscoveryResultPath=[string]$contract.discovery_evidence
}
if ($contract.discovery_evidence -and ((Get-FileHash -LiteralPath $contract.discovery_evidence -Algorithm SHA256).Hash -ne [string]$contract.discovery_sha256)) {
    throw 'Bounded discovery evidence changed after the contract decision.'
}
$rechecked = (& (Join-Path $PSScriptRoot 'New-HwpxFormContract.ps1') @recheckArgs) | ConvertFrom-Json
foreach ($field in @('operation_mode','deliverable_count','copy_fill_required','typed_authoring_allowed','explicit_new_form_authorized')) {
    if ($contract.$field -ne $rechecked.$field) { throw "Inconsistent form contract field: $field" }
}
if ([int]$contract.deliverable_count -ne $sources.Count) {
    throw "Deliverable count disagrees with the form contract: expected $($contract.deliverable_count), got $($sources.Count)."
}
if ([string]$contract.structure_authority_kind -eq 'current_human_revision') {
    $registeredForms = @($inputs.sources | Where-Object { $_.role -in @('form','human_revision') })
}

foreach ($form in @($contract.authoritative_form)) {
    $formPath = [IO.Path]::GetFullPath([string]$form.path)
    if (-not (Test-Path -LiteralPath $formPath -PathType Leaf)) { throw "Authoritative form is missing: $formPath" }
    $actualHash = (Get-FileHash -LiteralPath $formPath -Algorithm SHA256).Hash
    if ($actualHash -ne [string]$form.sha256) { throw "Authoritative form hash changed: $formPath" }
    if (@($registeredForms | Where-Object { [IO.Path]::GetFullPath([string]$_.path) -ieq $formPath -and [string]$_.sha256 -eq $actualHash }).Count -eq 0) {
        throw "Authoritative form is not registered with the same hash in inputs.json: $formPath"
    }
}

if ([string]$contract.operation_mode -eq 'explicit_new_form_authoring') {
    foreach ($source in $sources) { & (Join-Path $PSScriptRoot 'Test-HwpxPackageIntegrity.ps1') -Path $source | Out-Null }
    [ordered]@{schemaVersion='hwpx-publish-form-gate/v1';ok=$true;route='explicit_new_form';contract=$contractPath;sources=$sources;verificationLevel='package_xml_reopen';realHancomVerified=$false} | ConvertTo-Json -Depth 5
    return
}
if ([string]$contract.form_status -eq 'existing') {
    if ([bool]$contract.typed_authoring_allowed -or -not [bool]$contract.copy_fill_required -or [string]$contract.operation_mode -ne 'copy_and_fill_existing') {
        throw 'Existing-form contract is inconsistent: typed authoring must be disabled and copy/fill must be required.'
    }
    if ([int]$contract.deliverable_count -ne $sources.Count) {
        throw "Deliverable count disagrees with the form contract: expected $($contract.deliverable_count), got $($sources.Count)."
    }
    $bases = @($FormBaseFile | ForEach-Object { Resolve-JobFile $_ $docsPrefix 'FormBaseFile' })
    if ($bases.Count -eq 0) { throw 'Existing-form publication requires at least one canonical HWPX FormBaseFile.' }
    if ($bases.Count -ne @($contract.authoritative_form).Count) { throw 'FormBaseFile must cover every authoritative form, in contract order.' }
    if ($contract.form_layout -eq 'combined' -and $bases.Count -ne 1) { throw 'A combined form requires one authoritative document; classify multiple forms as separate.' }
    if ($contract.explicit_internal_split) { throw 'Explicit internal splitting requires a separately verified structural transformation; the content-only publisher cannot certify it.' }
    $normalizationReceipt = $null
    if (-not [string]::IsNullOrWhiteSpace($NormalizationReceiptPath)) {
        $resolvedNormalizationReceipt = Resolve-JobFile $NormalizationReceiptPath $receiptsPrefix 'NormalizationReceiptPath'
        $normalizationReceipt = Get-Content -Raw -Encoding utf8 -LiteralPath $resolvedNormalizationReceipt | ConvertFrom-Json
    }
    $normalizationAnchored = $false
    for ($baseIndex = 0; $baseIndex -lt $bases.Count; $baseIndex++) {
        $base = $bases[$baseIndex]
        $expectedAuthority = @($contract.authoritative_form)[$baseIndex]
        if ([IO.Path]::GetExtension($base) -ine '.hwpx') { throw "FormBaseFile must be a canonical HWPX document: $base" }
        $baseHash = (Get-FileHash -LiteralPath $base -Algorithm SHA256).Hash
        $directAuthority = [string]$expectedAuthority.extension -eq '.hwpx' -and [string]$expectedAuthority.sha256 -eq $baseHash
        if (-not $directAuthority) {
            if ($null -eq $normalizationReceipt) { throw "Form base is not anchored to an authoritative form or normalization receipt: $base" }
            $receiptMatch = $false
            foreach ($item in @($normalizationReceipt.items)) {
                $declaredSource = if ($item.sourcePath) { [string]$item.sourcePath } else { [string]$item.source }
                $declaredOutput = if ($item.canonicalPath) { [string]$item.canonicalPath } else { [string]$item.output }
                if ([string]::IsNullOrWhiteSpace($declaredSource) -or [string]::IsNullOrWhiteSpace($declaredOutput)) { continue }
                $itemSource = Resolve-DeclaredPath $declaredSource
                $itemOutput = Resolve-DeclaredPath $declaredOutput
                $authorityMatch = @($expectedAuthority | Where-Object {
                    [IO.Path]::GetFullPath([string]$_.path) -ieq $itemSource -and [string]$_.sha256 -eq [string]$item.sourceSha256
                }).Count -gt 0
                if ($authorityMatch -and $itemOutput -ieq $base -and [string]$item.outputSha256 -eq $baseHash -and ([string]::IsNullOrWhiteSpace([string]$item.status) -or [string]$item.status -eq 'ready')) {
                    $receiptMatch = $true
                    $normalizationAnchored = $true
                    break
                }
            }
            if (-not $receiptMatch) { throw "Form base is not anchored by matching source/output hashes in the normalization receipt: $base" }
        }
    }
    $matches = [Collections.Generic.List[object]]::new()
    $variantCount = [Math]::Max(1, @($contract.variants).Count)
    for ($sourceIndex = 0; $sourceIndex -lt $sources.Count; $sourceIndex++) {
        $source = $sources[$sourceIndex]
        if ([IO.Path]::GetExtension($source) -ine '.hwpx') { throw 'Existing-form results must be published as canonical HWPX files.' }
        $matchedBase = $null
        $lastReason = ''
        # Form-major, then variant order: A/course1, A/course2, B/course1, B/course2.
        $requiredBase = $bases[[int][Math]::Floor($sourceIndex / $variantCount)]
        foreach ($base in @($requiredBase)) {
            try { $lineage = Test-FormLineage $base $source } catch { $lineage = [pscustomobject]@{Ok=$false;Reason=$_.Exception.Message} }
            if ($lineage.Ok) { $matchedBase = $base; break }
            $lastReason = $lineage.Reason
        }
        if (-not $matchedBase) { throw "HWPX form lineage failed for $source`: $lastReason" }
        $variant = if (@($contract.variants).Count) { @($contract.variants)[$sourceIndex % $variantCount] } else { 'default' }
        $matches.Add([ordered]@{source=$source;sourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash;base=$matchedBase;baseSha256=(Get-FileHash -LiteralPath $matchedBase -Algorithm SHA256).Hash;variant=$variant})
    }
    [ordered]@{schemaVersion='hwpx-publish-form-gate/v1';ok=$true;route='existing_form_fill';contract=$contractPath;normalizationAnchored=$normalizationAnchored;matches=@($matches);verificationLevel='package_and_form_structure';realHancomVerified=$false;finalPolishAuthorized=[bool]$FinalPolishAuthorized} | ConvertTo-Json -Depth 6
    return
}

if ([string]$contract.form_status -eq 'absent') {
    if (-not [bool]$contract.explicit_new_form_authorized -or -not [bool]$contract.typed_authoring_allowed -or [string]$contract.operation_mode -ne 'explicit_new_form_authoring') {
        throw "New-layout publication requires the user's explicit new-form authorization in the canonical contract."
    }
    [ordered]@{schemaVersion='hwpx-publish-form-gate/v1';ok=$true;route='explicit_new_form';contract=$contractPath;sources=$sources} | ConvertTo-Json -Depth 5
    return
}

throw "Unsupported form status: $($contract.form_status)"
