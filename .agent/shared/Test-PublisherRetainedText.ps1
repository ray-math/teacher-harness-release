[CmdletBinding()]
param([string]$ReceiptPath = '')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path $workspace ('.agent/cache/publisher-retained-txt-' + [guid]::NewGuid().ToString('N'))
$checks = [Collections.Generic.List[string]]::new()
function Check([bool]$Ok, [string]$Name) { if (-not $Ok) { throw "FAIL: $Name" }; $checks.Add($Name) }
function Write-Json([string]$Path, $Value) { $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Rejects-Text([scriptblock]$Action) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch 'TXT publication requires ExplicitTextArtifact') { throw }
        return $true
    }
    return $false
}
try {
    $shared = Join-Path $fixture '.agent/shared'
    $index = Join-Path $fixture '.agent/index'
    $cabinet = Join-Path $fixture 'cabinet'
    $work = Join-Path $cabinet '20260918_fixture'
    $job = Join-Path $fixture '.agent/jobs/20260918-fixture'
    $docs = Join-Path $job 'wip/docs'
    foreach ($path in @($shared,$index,(Join-Path $work '.ai'),$docs)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $publisher = Join-Path $shared 'Publish-HumanResult.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Publish-HumanResult.ps1') -Destination $publisher
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'WorkStorage.ps1') -Destination $shared
    Write-Json (Join-Path $index 'delivery-system.json') @{humanCabinet=$cabinet;archiveFolderName='previous_versions';metadataFolderName='.ai';workMetadataName='work.json';sourceMetadataName='sources.json';consoleFileName='console.html'}
    Write-Json (Join-Path $index 'human-current.json') @{works=@(@{title='fixture';folderName='20260918_fixture';createdDate='20260918';stage='Review';files=@('existing.txt')})}
    Write-Json (Join-Path $work '.ai/work.json') @{currentFiles=@('existing.txt');editing=@{mode='content_only';finalPolishAuthorized=$false}}
    Write-Json (Join-Path $job 'inputs.json') @{userProvidedSelectionRecorded=$true;sources=@()}
    $liveText = Join-Path $work 'existing.txt'
    $stagedText = Join-Path $docs 'existing.txt'
    $newText = Join-Path $docs 'new.txt'
    $pdf = Join-Path $docs 'handout.pdf'
    [IO.File]::WriteAllText($liveText,'preserve these bytes')
    Copy-Item -LiteralPath $liveText -Destination $stagedText
    [IO.File]::WriteAllText($newText,'new text artifact')
    [IO.File]::WriteAllText($pdf,'%PDF-synthetic-gate-fixture')
    $before = (Get-FileHash -LiteralPath $liveText -Algorithm SHA256).Hash
    $argsForPublish = @{Stage='Review';TaskTitle='fixture';WorkFolderName='20260918_fixture';PlanOnly=$true}
    $plan = (& $publisher @argsForPublish -SourceFile @($stagedText,$pdf)) | ConvertFrom-Json
    Check ($plan.files.Count -eq 2 -and -not $plan.partialUpdate -and -not $plan.explicitTextArtifact) 'full-set addition carries existing identical TXT without explicit TXT authorization'
    Check (@($plan.files | Where-Object { $_.name -eq 'existing.txt' -and $_.unchangedCurrent }).Count -eq 1) 'existing TXT is proven registered and byte-identical'
    Check (Rejects-Text { & $publisher @argsForPublish -SourceFile @($stagedText,$pdf,$newText) }) 'new TXT remains rejected without explicit authorization'
    [IO.File]::WriteAllText($stagedText,'changed text artifact')
    Check (Rejects-Text { & $publisher @argsForPublish -SourceFile @($stagedText,$pdf) }) 'changed registered TXT remains rejected without explicit authorization'
    Copy-Item -LiteralPath $liveText -Destination $stagedText -Force
    $authorized = (& $publisher @argsForPublish -SourceFile @($stagedText,$pdf,$newText) -ExplicitTextArtifact) | ConvertFrom-Json
    Check ($authorized.files.Count -eq 3 -and $authorized.explicitTextArtifact) 'explicitly requested new TXT remains supported'
    Check ((Get-FileHash -LiteralPath $liveText -Algorithm SHA256).Hash -eq $before) 'planning and rejection leave current TXT bytes unchanged'
    $report = [ordered]@{ok=$true;powershell=$PSVersionTable.PSVersion.ToString();verification='isolated publisher PlanOnly integration';checks=@($checks);publisherSha256=(Get-FileHash -LiteralPath $publisher -Algorithm SHA256).Hash}
    if ($ReceiptPath) { Write-Json $ReceiptPath $report }
    $report | ConvertTo-Json -Depth 6
} finally {
    $safe = [IO.Path]::GetFullPath($fixture)
    $expectedPrefix = [IO.Path]::GetFullPath((Join-Path $workspace '.agent/cache/publisher-retained-txt-'))
    if ($safe.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $safe)) { Remove-Item -LiteralPath $safe -Recurse -Force }
}
