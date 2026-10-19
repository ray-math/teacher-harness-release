[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$fixtureParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureName = 'document-scope-publish-test-' + [guid]::NewGuid().ToString('N')
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $fixtureParent $fixtureName))
$script:publicationChecks = 0

function Write-PublicationFixtureJson([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding utf8
}
function New-PublicationTestPackage([string]$Path, [string]$HeaderToken, [string]$BodyText) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force | Out-Null
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entries = [ordered]@{
            'mimetype'='application/hwp+zip'
            'META-INF/manifest.xml'='<manifest />'
            'Contents/content.hpf'='<package><manifest><item id="header" href="Contents/header.xml" media-type="application/xml" /><item id="section0" href="Contents/section0.xml" media-type="application/xml" /></manifest><spine><itemref idref="header" /><itemref idref="section0" /></spine></package>'
            'Contents/header.xml'=('<hh:head xmlns:hh="urn:test:head"><hh:refList token="{0}" /></hh:head>' -f $HeaderToken)
            'settings.xml'='<hs:settings xmlns:hs="urn:test:settings"><hs:beginNumber page="1" /></hs:settings>'
            'Contents/section0.xml'=('<hs:sec xmlns:hs="urn:test:section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"><hp:p id="1"><hp:run><hp:t>{0}</hp:t></hp:run></hp:p></hs:sec>' -f [Security.SecurityElement]::Escape($BodyText))
        }
        foreach ($pair in $entries.GetEnumerator()) {
            $stream = $archive.CreateEntry($pair.Key).Open()
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            try { $writer.Write([string]$pair.Value) } finally { $writer.Dispose(); $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
}
function Assert-PublicationOutcome([string]$Name, [bool]$Allowed, [string]$Source, [string]$ErrorText='') {
    $actual = $true
    $failure = ''
    try {
        & $publishPath -Stage Final -TaskTitle $taskTitle -WorkFolderName $workFolderName -SourceFile $Source `
            -TargetRelativePath 'result.hwpx' -FormContractPath $contractPath -FormBaseFile $basePath -PlanOnly | Out-Null
    } catch { $actual = $false; $failure = $_.Exception.Message }
    if ($actual -ne $Allowed) { throw "Unexpected publication result for ${Name}: $failure" }
    if (-not $Allowed -and $ErrorText -and $failure -notlike ('*' + $ErrorText + '*')) {
        throw "Unexpected publication denial for ${Name}: $failure"
    }
    $script:publicationChecks++
}

try {
    $sharedFixture = Join-Path $fixtureRoot '.agent\shared'
    $indexFixture = Join-Path $fixtureRoot '.agent\index'
    $cabinetFixture = Join-Path $fixtureRoot 'cabinet'
    New-Item -ItemType Directory -Path $sharedFixture,$indexFixture,$cabinetFixture -Force | Out-Null
    # Copy executable PowerShell dependencies only, never caches or school data.
    foreach ($scriptFile in @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.ps1')) {
        Copy-Item -LiteralPath $scriptFile.FullName -Destination (Join-Path $sharedFixture $scriptFile.Name)
    }
    Write-PublicationFixtureJson (Join-Path $indexFixture 'delivery-system.json') @{
        schemaVersion='hwpx-human-delivery/v11';humanCabinet=$cabinetFixture;incomingRoot=(Join-Path $fixtureRoot 'incoming')
        archiveFolderName='previous_versions';metadataFolderName='.ai';workMetadataName='work.json';sourceMetadataName='sources.json'
        legacyMetadataFolderName='legacy';consoleFileName='console.html';defaultEvidenceFolderName='evidence';evidenceCopyFolderName='original'
        defaultCollectionFolderName='collection';defaultReferenceFolderName='reference';openProtocol='hwpx-work-open'
        openTargetManifest='.agent\index\human-open-targets.json'
    }
    $seedPath = Join-Path $fixtureRoot 'source\base.hwpx'
    New-PublicationTestPackage $seedPath 'original-style' 'original text'
    $startPath = Join-Path $sharedFixture 'Start-HwpxWork.ps1'
    $publishPath = Join-Path $sharedFixture 'Publish-HumanResult.ps1'
    $taskTitle = 'Scope publication fixture'
    $workFolderName = '87_scope-fixture'
    $startArgs = @{
        TaskTitle=$taskTitle;WorkFolderName=$workFolderName;IntakeSummary='Synthetic scope regression';DecisionReason='Isolated fixture only'
        FormFile=@($seedPath);UserProvidedFile=@($seedPath)
    }
    $receipt = (& $startPath -Mode New -JobSlug publication-scope @startArgs) | ConvertFrom-Json
    $jobPath = [string]$receipt.jobPath
    $workPath = Join-Path ([string]$receipt.workRoot) '.ai\work.json'
    $basePath = Join-Path $jobPath 'wip\docs\base.hwpx'
    $filledPath = Join-Path $jobPath 'wip\docs\filled.hwpx'
    $changedPath = Join-Path $jobPath 'wip\docs\headerchanged.hwpx'
    Copy-Item -LiteralPath $seedPath -Destination $basePath
    New-PublicationTestPackage $filledPath 'original-style' 'new text'
    New-PublicationTestPackage $changedPath 'changed-style' 'new text'
    $contractPath = Join-Path $jobPath 'wip\receipts\hwpx-form-contract.json'
    & (Join-Path $sharedFixture 'New-HwpxFormContract.ps1') -FormStatus existing -FormLayout separate `
        -AuthoritativeForm $seedPath -StructureAuthorityKind blank_form -OutputPath $contractPath | Out-Null

    Assert-PublicationOutcome 'content-only fill preserves style' $true $filledPath
    Assert-PublicationOutcome 'content-only header edit rejected' $false $changedPath 'HWPX form lineage failed'
    $metadata = Get-Content -LiteralPath $workPath -Raw -Encoding utf8 | ConvertFrom-Json
    $metadata.editing.finalPolishAuthorized = $true
    Write-PublicationFixtureJson $workPath $metadata
    Assert-PublicationOutcome 'Boolean-only permission rejected' $false $changedPath 'Document scope blocks publication'

    # Build the exact Korean request without relying on the test source encoding.
    $formatRequest = -join @([char]0xC11C,[char]0xC2DD,[char]0xC744,[char]0x20,[char]0xC218,[char]0xC815,[char]0xD574,[char]0xC918)
    & $startPath -Mode FollowUp -JobPath $jobPath @startArgs -FinalPolishAuthorized -FormattingRequestText $formatRequest | Out-Null
    Assert-PublicationOutcome 'explicit formatting request allows header edit' $true $changedPath
    & $startPath -Mode FollowUp -JobPath $jobPath @startArgs -RevokeDocumentScope | Out-Null
    Assert-PublicationOutcome 'revoked formatting request rejects header edit' $false $changedPath 'HWPX form lineage failed'

    & $startPath -Mode FollowUp -JobPath $jobPath @startArgs -FinalPolishAuthorized -FormattingRequestText $formatRequest | Out-Null
    & $startPath -Mode FollowUp -JobSlug another-scope @startArgs -FinalPolishAuthorized -FormattingRequestText $formatRequest | Out-Null
    Assert-PublicationOutcome 'another active job cannot grant old job permission' $false $changedPath 'Document scope blocks publication'
} finally {
    $cleanupPath = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $cleanupPath.StartsWith($fixtureParent + '\', [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($cleanupPath) -cne $fixtureName) { throw 'Unsafe publication fixture cleanup path.' }
    if (Test-Path -LiteralPath $cleanupPath) {
        $items = @(Get-Item -LiteralPath $cleanupPath -Force) + @(Get-ChildItem -LiteralPath $cleanupPath -Recurse -Force)
        if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Publication cleanup refuses reparse points.' }
        Remove-Item -LiteralPath $cleanupPath -Recurse -Force
    }
}
[ordered]@{ok=$true;checks=$script:publicationChecks;powershell=$PSVersionTable.PSVersion.ToString();fixtureRemoved=(-not (Test-Path -LiteralPath $fixtureRoot))} | ConvertTo-Json -Compress
