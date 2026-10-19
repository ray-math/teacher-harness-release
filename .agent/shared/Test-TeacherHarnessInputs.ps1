[CmdletBinding()]
param([string]$Workspace = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = Join-Path $PSScriptRoot '..\..' }
$workspaceRoot = [IO.Path]::GetFullPath($Workspace)
$receiver = Join-Path $workspaceRoot '.agent\shared\Receive-TeacherHarnessInputs.ps1'
$qaRoot = Join-Path ([IO.Path]::GetDirectoryName($workspaceRoot)) 'HarnessQA'
$testRoot = Join-Path $qaRoot ('teacher-inputs-' + [guid]::NewGuid().ToString('N'))
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
    param([string[]]$Paths, [string]$Config, [string]$Message)
    $failed = $false
    try { $null = Invoke-InputReceive -Paths $Paths -Config $Config } catch { $failed = $true }
    Assert-InputTest -Condition $failed -Message $Message
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
        throw 'Refusing fixture cleanup outside HarnessQA.'
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) {
        $items = @((Get-Item -Force -LiteralPath $resolvedTestRoot)) + @(Get-ChildItem -Force -Recurse -LiteralPath $resolvedTestRoot)
        foreach ($item in $items) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing recursive cleanup across a reparse path: $($item.FullName)" }
        }
        Remove-Item -Force -Recurse -LiteralPath $resolvedTestRoot
    }
}
