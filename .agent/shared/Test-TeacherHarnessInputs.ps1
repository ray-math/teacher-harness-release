[CmdletBinding()]
param([string]$Workspace = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = Join-Path $PSScriptRoot '..\..' }
$workspaceRoot = [IO.Path]::GetFullPath($Workspace)
$receiver = Join-Path $workspaceRoot '.agent\shared\Receive-TeacherHarnessInputs.ps1'
$qaRoot = [IO.Path]::GetTempPath().TrimEnd('\')
$testRoot = Join-Path $qaRoot ('thi-' + [guid]::NewGuid().ToString('N'))
$testWorkspace = Join-Path $testRoot '하네스'
$incomingRoot = Join-Path $testRoot '받은 자료'
$sourceRoot = Join-Path $testRoot '원본 자료'
$checks = New-Object 'System.Collections.Generic.List[string]'
$junction = $null

function Assert-InputTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $checks.Add($Message)
}
function Write-InputFixture {
    param([string]$Path, [string]$Text)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($true)))
}
function Get-InputFixtureHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Invoke-InputReceive {
    param([string[]]$Paths, [string]$Config = 'settings.json')
    return (& $receiver -SourceFile $Paths -Workspace $testWorkspace -ConfigPath $Config | Out-String | ConvertFrom-Json)
}
function Assert-InputRejected {
    param([string[]]$Paths, [string]$Config, [string]$Message, [string]$Pattern = '')
    $failed = $false
    try { $null = Invoke-InputReceive -Paths $Paths -Config $Config }
    catch {
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw }
        $failed = $true
    }
    Assert-InputTest -Condition $failed -Message $Message
}
function New-InputLengthPath {
    param([string]$Prefix, [int]$Length)
    $padding = $Length - $testRoot.Length - 1 - $Prefix.Length
    if ($padding -lt 1) { throw 'TEMP is too long for the path-boundary fixture.' }
    return Join-Path $testRoot ($Prefix + ('x' * $padding))
}
function Get-InputTreeState {
    param([string]$Path)
    @((Get-Item -Force -LiteralPath $Path)) + @(Get-ChildItem -Force -Recurse -LiteralPath $Path) |
        Sort-Object FullName | ForEach-Object {
            # Directory enumeration can return cached timestamps from before a
            # child handle closed; read current metadata for stable snapshots.
            $_.Refresh()
            [ordered]@{ path = $_.FullName; directory = $_.PSIsContainer; writeTicks = $_.LastWriteTimeUtc.Ticks; hash = $(if (-not $_.PSIsContainer) { Get-InputFixtureHash -Path $_.FullName }) }
        } | ConvertTo-Json -Depth 4 -Compress
}

try {
    $null = [IO.Directory]::CreateDirectory($testWorkspace)
    Write-InputFixture -Path (Join-Path $testWorkspace 'settings.json') -Text '{"humanCabinet":"../업무","incomingRoot":"../받은 자료"}'
    Write-InputFixture -Path (Join-Path $testWorkspace 'invalid-settings.json') -Text '{"humanCabinet":"../업무","incomingRoot":"../검사 실패 받은자료"}'
    $first = Join-Path $sourceRoot 'A\한글 자료.txt'
    $identical = Join-Path $sourceRoot 'B\한글 자료.txt'
    $different = Join-Path $sourceRoot 'C\한글 자료.txt'
    Write-InputFixture -Path $first -Text '첫 번째 원본 내용'
    Write-InputFixture -Path $identical -Text '첫 번째 원본 내용'
    Write-InputFixture -Path $different -Text '서로 다른 원본 내용'
    $originalHashes = @{}
    foreach ($path in @($first, $identical, $different)) { $originalHashes[$path] = Get-InputFixtureHash -Path $path }

    $referenceRoot = Join-Path $testRoot 'Output'
    Write-InputFixture -Path (Join-Path $testWorkspace 'reference-settings.json') -Text (@{humanCabinet=$referenceRoot;incomingRoot=(Join-Path $referenceRoot '.ai\inputs');receiveInputs=$false} | ConvertTo-Json)
    $sourceBefore = Get-InputTreeState -Path $sourceRoot
    $referenced = Invoke-InputReceive -Paths @($first,$identical,$different) -Config 'reference-settings.json'
    Assert-InputTest -Condition ($referenced.status -eq 'referenced' -and $referenced.receiptPath -eq '' -and -not $referenced.receiptReused) -Message 'Reference mode reports references without claiming a stored receipt'
    Assert-InputTest -Condition (@($referenced.files).Count -eq 3) -Message 'Reference mode retains all source mappings'
    foreach ($file in $referenced.files) {
        Assert-InputTest -Condition ($file.status -eq 'referenced' -and $file.sourcePath -eq $file.receivedPath -and $file.sha256 -eq $originalHashes[$file.sourcePath]) -Message 'Reference mapping retains source location and verified hash'
    }
    $referencedAgain = Invoke-InputReceive -Paths @($first,$identical,$different) -Config 'reference-settings.json'
    Assert-InputTest -Condition ($referenced.inputFingerprint -eq $referencedAgain.inputFingerprint) -Message 'Reference fingerprints are stable on repeated reads'
    Assert-InputRejected -Paths @($first,(Join-Path $sourceRoot 'missing.txt')) -Config 'reference-settings.json' -Message 'Reference mode rejects missing sources'
    Assert-InputTest -Condition (-not (Test-Path -LiteralPath $referenceRoot)) -Message 'Reference mode creates no output, received-data, or receipt directories'
    Assert-InputTest -Condition ((Get-InputTreeState -Path $sourceRoot) -ceq $sourceBefore) -Message 'Reference reads preserve source bytes and modification timestamps'
    Write-InputFixture -Path (Join-Path $testWorkspace 'bad-flag.json') -Text '{"humanCabinet":"../Output","incomingRoot":"../inputs","receiveInputs":"false"}'
    Assert-InputRejected -Paths @($first) -Config 'bad-flag.json' -Pattern 'JSON boolean' -Message 'A string receiveInputs flag cannot silently enable copying'

    # Run setup only in a disposable harness with synthetic configuration.
    $setupWorkspace = Join-Path $testRoot 'setup-fixture'
    Write-InputFixture -Path (Join-Path $setupWorkspace '.agent/index/delivery-system.json') -Text '{"humanCabinet":"Output","incomingRoot":"Output/.ai/inputs","receiveInputs":false,"outputLayout":"flat"}'
    Write-InputFixture -Path (Join-Path $setupWorkspace '.agent/index/hwpx-runtime.json') -Text '{"runtimeDirectory":"runtime","versions":{}}'
    $null = [IO.Directory]::CreateDirectory((Join-Path $setupWorkspace '.agent/shared'))
    Copy-Item -LiteralPath (Join-Path $workspaceRoot '.agent/shared/Setup-TeacherHarness.ps1') -Destination (Join-Path $setupWorkspace '.agent/shared/Setup-TeacherHarness.ps1')
    Copy-Item -LiteralPath (Join-Path $workspaceRoot '.agent/shared/Resolve-TeacherHarnessConfig.ps1') -Destination (Join-Path $setupWorkspace '.agent/shared/Resolve-TeacherHarnessConfig.ps1')
    $null = & (Join-Path $setupWorkspace '.agent/shared/Setup-TeacherHarness.ps1') -CheckOnly
    Assert-InputTest -Condition (-not (Test-Path -LiteralPath (Join-Path $setupWorkspace 'Output'))) -Message 'Setup CheckOnly with references creates no folders'
    $null = & (Join-Path $setupWorkspace '.agent/shared/Setup-TeacherHarness.ps1')
    $savedConfig = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $setupWorkspace '.agent/index/delivery-system.json') | ConvertFrom-Json
    Assert-InputTest -Condition ($savedConfig.receiveInputs -eq $false -and $savedConfig.outputLayout -eq 'flat') -Message 'Setup preserves reference and flat-layout configuration'
    Assert-InputTest -Condition ((Test-Path -LiteralPath (Join-Path $setupWorkspace 'Output')) -and -not (Test-Path -LiteralPath (Join-Path $setupWorkspace 'Output/.ai'))) -Message 'Setup creates only the output root when receipt copying is disabled'
    Push-Location 'D:\'
    try { $result = Invoke-InputReceive -Paths @($first, $identical, $different) } finally { Pop-Location }
    Assert-InputTest -Condition ($result.status -eq 'received' -and @($result.files).Count -eq 3) -Message 'JSON status and three input mappings'
    Assert-InputTest -Condition ($result.files[0].receivedPath -eq (Join-Path $incomingRoot '한글 자료.txt')) -Message 'ConfigPath and workspace-relative incomingRoot work from a different CWD'
    Assert-InputTest -Condition (-not $result.files[0].reused -and $result.files[1].reused -and $result.files[0].receivedPath -eq $result.files[1].receivedPath) -Message 'Identical content and filename reuse a single copy'
    $differentLeaf = '한글 자료__' + $originalHashes[$different].Substring(0,12) + '.txt'
    Assert-InputTest -Condition (-not $result.files[2].reused -and [IO.Path]::GetFileName($result.files[2].receivedPath) -eq $differentLeaf) -Message 'Different content with the same filename gets a hash suffix'
    foreach ($file in $result.files) {
        Assert-InputTest -Condition ($file.sha256 -eq (Get-InputFixtureHash -Path $file.receivedPath)) -Message ('Received copy hash: ' + [IO.Path]::GetFileName($file.receivedPath))
        Assert-InputTest -Condition ((Get-InputFixtureHash -Path $file.sourcePath) -eq $originalHashes[$file.sourcePath]) -Message ('Original content preserved: ' + [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($file.sourcePath)))
    }
    Assert-InputTest -Condition ($result.receiptPath.StartsWith((Join-Path $incomingRoot '.ai\input-receipts\'), [StringComparison]::OrdinalIgnoreCase)) -Message 'Receipt lives under the received-data root'
    $receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath $result.receiptPath | ConvertFrom-Json
    Assert-InputTest -Condition ($receipt.schemaVersion -eq 'teacher-harness-input-receipt/v1' -and @($receipt.files).Count -eq 3) -Message 'Receipt schema and source mappings'
    foreach ($file in $receipt.files) {
        Assert-InputTest -Condition ($originalHashes[$file.sourcePath] -eq $file.sha256 -and (Get-InputFixtureHash -Path $file.receivedPath) -eq $file.sha256) -Message 'Receipt hashes match original and received files'
    }
    Assert-InputTest -Condition (-not (Test-Path -LiteralPath (Join-Path $testWorkspace '.ai'))) -Message 'No actual-file records accumulate in the harness workspace'
    $receiptHashBeforeRepeat = Get-InputFixtureHash -Path $result.receiptPath
    $receiptWriteTimeBeforeRepeat = [IO.File]::GetLastWriteTimeUtc($result.receiptPath)
    $receiptCountBeforeRepeat = @(Get-ChildItem -LiteralPath (Join-Path $incomingRoot '.ai\input-receipts') -File).Count
    $sameBatch = Invoke-InputReceive -Paths @($first, $identical, $different)
    Assert-InputTest -Condition ($sameBatch.receiptReused -and $sameBatch.receiptPath -eq $result.receiptPath) -Message 'Repeated identical batch reuses a stable fingerprint receipt'
    Assert-InputTest -Condition ((Get-InputFixtureHash -Path $result.receiptPath) -eq $receiptHashBeforeRepeat -and [IO.File]::GetLastWriteTimeUtc($result.receiptPath) -eq $receiptWriteTimeBeforeRepeat) -Message 'Reused receipt content and timestamp are unchanged'
    Assert-InputTest -Condition (@(Get-ChildItem -LiteralPath (Join-Path $incomingRoot '.ai\input-receipts') -File).Count -eq $receiptCountBeforeRepeat) -Message 'Repeated identical batch creates no additional receipt'
    $again = Invoke-InputReceive -Paths @($first, $different)
    Assert-InputTest -Condition ($again.files[0].reused -and $again.files[1].reused) -Message 'A repeated receive reuses both existing copies'
    $inPlace = Invoke-InputReceive -Paths @($result.files[0].receivedPath)
    Assert-InputTest -Condition ($inPlace.files[0].reused -and $inPlace.files[0].sourcePath -eq $inPlace.files[0].receivedPath) -Message 'An already received file is reused in place'

    $invalidIncoming = Join-Path $testRoot '검사 실패 받은자료'
    Assert-InputRejected -Paths @($first, (Join-Path $sourceRoot 'missing.txt')) -Config 'invalid-settings.json' -Message 'Missing later input rejects the whole batch'
    Assert-InputTest -Condition (-not (Test-Path -LiteralPath $invalidIncoming)) -Message 'Missing input creates no incoming directory, copies, or receipt'
    Assert-InputRejected -Paths @($first, $sourceRoot) -Config 'invalid-settings.json' -Message 'Directory input is rejected without recursive copying'
    Assert-InputTest -Condition (-not (Test-Path -LiteralPath $invalidIncoming)) -Message 'Directory input causes no writes'
    $locked = Join-Path $sourceRoot 'locked.txt'
    Write-InputFixture -Path $locked -Text '잠긴 합성 자료'
    $lock = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-InputRejected -Paths @($first, $locked) -Config 'invalid-settings.json' -Message 'Unreadable locked input is rejected during preflight' } finally { $lock.Dispose() }
    Assert-InputTest -Condition (-not (Test-Path -LiteralPath $invalidIncoming)) -Message 'Unreadable input causes no writes'

    # Ordinary PS5.1 paths must work up to the documented transaction limit.
    # Receipt paths grow much longer than incomingRoot; no actual long path needs
    # to be created to prove that an unsupported batch rejects before any writes.
    $receiptTail = '\.ai\input-receipts\' + ('0' * 64) + '.json'
    $boundaryIncoming = New-InputLengthPath -Prefix 'boundary-' -Length (259 - $receiptTail.Length)
    $boundaryConfig = Join-Path $testWorkspace 'boundary-settings.json'
    Write-InputFixture -Path $boundaryConfig -Text (@{ humanCabinet = '../업무'; incomingRoot = $boundaryIncoming } | ConvertTo-Json)
    $boundaryResult = Invoke-InputReceive -Paths @($first) -Config 'boundary-settings.json'
    Assert-InputTest -Condition ($boundaryResult.receiptPath.Length -eq 259 -and (Test-Path -LiteralPath $boundaryResult.receiptPath -PathType Leaf)) -Message 'A 259-character final receipt path is supported'
    Assert-InputTest -Condition ((Get-InputFixtureHash -Path $first) -eq $originalHashes[$first]) -Message 'Boundary-length receipt preserves the source'

    $missingLongIncoming = New-InputLengthPath -Prefix 'missing-' -Length (260 - $receiptTail.Length)
    Write-InputFixture -Path (Join-Path $testWorkspace 'missing-long-settings.json') -Text (@{ humanCabinet = '../업무'; incomingRoot = $missingLongIncoming } | ConvertTo-Json)
    Assert-InputRejected -Paths @($first, $different) -Config 'missing-long-settings.json' -Pattern 'Unsupported receive path length: File path has 260 characters' -Message 'A 260-character final receipt path is clearly rejected during preflight'
    Assert-InputTest -Condition (-not (Test-Path -LiteralPath $missingLongIncoming)) -Message 'Overlong receipt creates no incoming directory, copies, or receipt'

    $existingLongIncoming = New-InputLengthPath -Prefix 'existing-' -Length (260 - $receiptTail.Length)
    Write-InputFixture -Path (Join-Path $existingLongIncoming 'keep.txt') -Text 'pre-existing received content'
    Write-InputFixture -Path (Join-Path $existingLongIncoming '.ai\input-receipts\keep.json') -Text 'pre-existing receipt bytes'
    Write-InputFixture -Path (Join-Path $testWorkspace 'existing-long-settings.json') -Text (@{ humanCabinet = '../업무'; incomingRoot = $existingLongIncoming } | ConvertTo-Json)
    $existingLongBefore = Get-InputTreeState -Path $existingLongIncoming
    Assert-InputRejected -Paths @($first, $different) -Config 'existing-long-settings.json' -Pattern 'Unsupported receive path length' -Message 'Overlong receipt is rejected for an existing incoming root'
    Assert-InputTest -Condition ((Get-InputTreeState -Path $existingLongIncoming) -ceq $existingLongBefore) -Message 'Overlong receipt leaves existing copies, receipts, directories, and timestamps unchanged'

    $collisionLeaf = ('c' * 72) + '.txt'
    $collisionSource = Join-Path $sourceRoot $collisionLeaf
    Write-InputFixture -Path $collisionSource -Text 'new collision bytes'
    Write-InputFixture -Path (Join-Path $boundaryIncoming $collisionLeaf) -Text 'existing collision bytes'
    $collisionHash = Get-InputFixtureHash -Path $collisionSource
    $boundaryBefore = Get-InputTreeState -Path $boundaryIncoming
    Assert-InputRejected -Paths @($different, $collisionSource) -Config 'boundary-settings.json' -Pattern 'Unsupported receive path length' -Message 'A collision hash suffix exceeding the path limit rejects the entire batch before copying'
    Assert-InputTest -Condition ((Get-InputTreeState -Path $boundaryIncoming) -ceq $boundaryBefore) -Message 'Overlong collision suffix preserves all existing incoming data and receipt timestamps'
    Assert-InputTest -Condition ((Get-InputFixtureHash -Path $collisionSource) -eq $collisionHash -and (Get-InputFixtureHash -Path $different) -eq $originalHashes[$different]) -Message 'Rejected long-path batch preserves every source'

    $junction = Join-Path $testRoot 'source-junction'
    $null = New-Item -Path $junction -ItemType Junction -Value $sourceRoot
    Assert-InputRejected -Paths @((Join-Path $junction 'A\한글 자료.txt')) -Config 'invalid-settings.json' -Message 'Reparse-point source ancestor is rejected'
    Assert-InputTest -Condition (-not (Test-Path -LiteralPath $invalidIncoming)) -Message 'Reparse input causes no writes'
    Write-InputFixture -Path (Join-Path $testWorkspace 'junction-settings.json') -Text '{"humanCabinet":"../업무","incomingRoot":"../source-junction"}'
    Assert-InputRejected -Paths @($first) -Config 'junction-settings.json' -Message 'Reparse-point destination is rejected'
    [IO.Directory]::Delete($junction, $false)
    $junction = $null

    # Inject a deterministic source disappearance after preflight. The first copy
    # must roll back, while a copy reused from an earlier transaction must remain.
    $rollbackFirst = Join-Path $sourceRoot 'rollback-first.txt'
    $rollbackSecond = Join-Path $sourceRoot 'rollback-second.txt'
    Write-InputFixture -Path $rollbackFirst -Text 'rollback copy one'
    Write-InputFixture -Path $rollbackSecond -Text 'rollback copy two'
    $receiverLines = Get-Content -LiteralPath $receiver
    $copyLine = 0
    for ($i = 0; $i -lt $receiverLines.Count; $i++) {
        if ($receiverLines[$i].Trim() -eq 'Assert-ReceiveSafePath -Path $file.sourcePath') { $copyLine = $i + 1; break }
    }
    Assert-InputTest -Condition ($copyLine -gt 0) -Message 'Copy-phase failure injection point is available'
    $global:TeacherInputRollbackSource = $rollbackSecond
    $breakpoint = Set-PSBreakpoint -Script $receiver -Line $copyLine -Action {
        if ([IO.File]::Exists($global:TeacherInputRollbackSource)) { [IO.File]::Delete($global:TeacherInputRollbackSource) }
    }
    $receiptCount = @(Get-ChildItem -LiteralPath (Join-Path $incomingRoot '.ai\input-receipts') -File).Count
    try { Assert-InputRejected -Paths @($first, $rollbackFirst, $rollbackSecond) -Config 'settings.json' -Message 'Copy-phase failure rejects the transaction' }
    finally { Remove-PSBreakpoint -Breakpoint $breakpoint; Remove-Variable -Name TeacherInputRollbackSource -Scope Global }
    Assert-InputTest -Condition (-not (Test-Path -LiteralPath (Join-Path $incomingRoot 'rollback-first.txt'))) -Message 'Copy-phase failure rolls back only newly created copies'
    Assert-InputTest -Condition ((Get-InputFixtureHash -Path $result.files[0].receivedPath) -eq $originalHashes[$first]) -Message 'Rollback preserves a pre-existing received copy'
    Assert-InputTest -Condition (@(Get-ChildItem -LiteralPath (Join-Path $incomingRoot '.ai\input-receipts') -File).Count -eq $receiptCount) -Message 'Copy-phase failure leaves no partial receipt'

    [pscustomobject]@{ status = 'passed'; checks = $checks.Count; details = @($checks) } | ConvertTo-Json -Depth 6
}
finally {
    # Never pass a computed or reparse-containing target to recursive deletion.
    if ($null -ne $junction -and [IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction, $false) }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith($qaRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing fixture cleanup outside TEMP.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) {
        $items = @((Get-Item -Force -LiteralPath $resolvedTestRoot)) + @(Get-ChildItem -Force -Recurse -LiteralPath $resolvedTestRoot)
        foreach ($item in $items) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing recursive cleanup across a reparse path: $($item.FullName)" }
        }
        Remove-Item -Force -Recurse -LiteralPath $resolvedTestRoot
    }
}
