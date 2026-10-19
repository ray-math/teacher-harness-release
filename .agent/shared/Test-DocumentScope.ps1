[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DocumentScope.ps1')
$gatePath = Join-Path $PSScriptRoot 'Assert-DocumentOperationScope.ps1'
$fixtureParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureName = 'document-scope-test-' + [guid]::NewGuid().ToString('N')
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $fixtureParent $fixtureName))
$fixtureJob = Join-Path $fixtureRoot '.ai\jobs\synthetic'
$script:scopeChecks = 0

function Write-FixtureJson([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}
function Set-FixtureScope([bool]$Format = $false, [bool]$Visual = $false) {
    $scope = New-DocumentScope -JobPath $fixtureJob -FinalPolishAuthorized:$Format -VisualReviewAuthorized:$Visual `
        -FormattingRequestText $(if ($Format) { 'format change' } else { '' }) `
        -VisualReviewRequestText $(if ($Visual) { 'visual review' } else { '' })
    Write-FixtureJson (Join-Path $fixtureJob 'inputs.json') @{delivery=@{workRoot=$fixtureRoot};documentScope=$scope}
    Write-FixtureJson (Join-Path $fixtureRoot '.ai\work.json') @{editing=@{documentScope=$scope}}
}
function Assert-FixtureOutcome([string]$Name, [bool]$Allowed, [scriptblock]$Action, [string]$ExpectedError = '') {
    $actual = $true
    $failure = ''
    try { & $Action | Out-Null } catch { $actual = $false; $failure = $_.Exception.Message }
    if ($actual -ne $Allowed) { throw "Unexpected scope result for ${Name}: $failure" }
    if (-not $Allowed -and $ExpectedError -and $failure -notlike ('*' + $ExpectedError + '*')) {
        throw "Unexpected denial reason for ${Name}: $failure"
    }
    $script:scopeChecks++
}

try {
    New-Item -ItemType Directory -Path $fixtureJob -Force | Out-Null
    $cases = @(
        @{name='paragraph text';grant=$false;allow=$true;step=@{op='paragraph_patch';args=@{patches=@(@{paragraph_index=0;text='new'})}}},
        @{name='cell text';grant=$false;allow=$true;step=@{op='fill_cells';args=@{cells=@(@{table_index=0;row=0;col=0;text='new'})}}},
        @{name='nested body text';grant=$false;allow=$true;step=@{op='apply_body_ops';args=@{ops=@(@{op='replace_text';find='old';replace='new';count=1},@{op='set_paragraph_text';index=0;text='new'})}}},
        @{name='nested cell anchor text';grant=$false;allow=$true;step=@{op='apply_table_ops';args=@{ops=@(@{op='fill_cell';table_anchor='head';cell_anchor=@{label='name';dir='right'};text='new'})}}},
        @{name='row height blocked';grant=$false;allow=$false;step=@{op='apply_table_ops';args=@{ops=@(@{op='set_row_heights';heights=@{'0'=42000}})}}},
        @{name='cell max_lines blocked';grant=$false;allow=$false;step=@{op='fill_cells';args=@{cells=@(@{table_index=0;row=0;col=0;text='new';max_lines=2})}}},
        @{name='font fitting blocked';grant=$false;allow=$false;step=@{op='fill_cells';args=@{cells=@(@{table_index=0;row=0;col=0;text='new'});fit_max_lines=2;min_font_pt=8}}},
        @{name='hidden style blocked';grant=$false;allow=$false;step=@{op='paragraph_patch';args=@{patches=@(@{paragraph_index=0;text='new';style='red'})}}},
        @{name='anchor hidden style blocked';grant=$false;allow=$false;step=@{op='apply_table_ops';args=@{ops=@(@{op='fill_cell';table_anchor='head';cell_anchor=@{label='name';font='new'};text='new'})}}},
        @{name='unrecognized op blocked';grant=$false;allow=$false;step=@{op='set_cell_text';args=@{text='new'}}},
        @{name='wrong key case blocked';grant=$false;allow=$false;step=@{op='fill_cells';args=@{cells=@(@{table_index=0;row=0;col=0;text='new';Font='Arial'})}}},
        @{name='granted formatting allowed';grant=$true;allow=$true;step=@{op='apply_table_ops';args=@{ops=@(@{op='set_row_heights';heights=@{'0'=42000}})}}}
    )
    foreach ($case in $cases) {
        Set-FixtureScope -Format $case.grant
        $planPath = Join-Path $fixtureJob 'plan.json'
        Write-FixtureJson $planPath @{steps=@($case.step)}
        Assert-FixtureOutcome $case.name $case.allow { & $gatePath -JobPath $fixtureJob -Capability edit_plan -PlanPath $planPath } 'Document scope blocks format_edit'
    }

    Set-FixtureScope
    Assert-FixtureOutcome 'visual review denied by default' $false { & $gatePath -JobPath $fixtureJob -Capability visual_review } 'Document scope blocks visual_review'
    Set-FixtureScope -Format $true
    Assert-FixtureOutcome 'format permission does not grant render' $false { & $gatePath -JobPath $fixtureJob -Capability visual_review } 'Document scope blocks visual_review'
    Set-FixtureScope -Visual $true
    Assert-FixtureOutcome 'visual request grants render scope' $true { & $gatePath -JobPath $fixtureJob -Capability visual_review }

    $inputsPath = Join-Path $fixtureJob 'inputs.json'
    $inputs = Get-Content -LiteralPath $inputsPath -Raw -Encoding utf8 | ConvertFrom-Json
    $inputs.documentScope.visualRequest.sha256 = '0' * 64
    Write-FixtureJson $inputsPath $inputs
    Assert-FixtureOutcome 'one-sided scope record tampering denied' $false { & $gatePath -JobPath $fixtureJob -Capability visual_review } 'records disagree'
    $workPath = Join-Path $fixtureRoot '.ai\work.json'
    $work = Get-Content -LiteralPath $workPath -Raw -Encoding utf8 | ConvertFrom-Json
    $work.editing.documentScope.visualRequest.sha256 = '0' * 64
    Write-FixtureJson $workPath $work
    Assert-FixtureOutcome 'request hash tampering denied' $false { & $gatePath -JobPath $fixtureJob -Capability visual_review } 'Document scope request hash changed'

    Set-FixtureScope -Visual $true
    $inputs = Get-Content -LiteralPath $inputsPath -Raw -Encoding utf8 | ConvertFrom-Json
    $inputs.documentScope.jobPath = Join-Path $fixtureRoot '.ai\jobs\other'
    Write-FixtureJson $inputsPath $inputs
    Assert-FixtureOutcome 'different job denied' $false { & $gatePath -JobPath $fixtureJob -Capability visual_review } 'Document scope is bound to another job'

    Set-FixtureScope -Visual $true
    $workPath = Join-Path $fixtureRoot '.ai\work.json'
    $work = Get-Content -LiteralPath $workPath -Raw -Encoding utf8 | ConvertFrom-Json
    $work.editing.documentScope.id = [guid]::NewGuid().ToString('D')
    Write-FixtureJson $workPath $work
    Assert-FixtureOutcome 'revoked active scope denied' $false { & $gatePath -JobPath $fixtureJob -Capability visual_review } 'Document scope blocks visual_review'
} finally {
    # Recursive cleanup is confined to this freshly generated temporary fixture.
    $cleanupPath = [IO.Path]::GetFullPath($fixtureRoot)
    if (-not $cleanupPath.StartsWith($fixtureParent + '\', [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($cleanupPath) -cne $fixtureName) { throw 'Unsafe document-scope fixture cleanup path.' }
    if (Test-Path -LiteralPath $cleanupPath) {
        $fixtureItems = @(Get-Item -LiteralPath $cleanupPath -Force) + @(Get-ChildItem -LiteralPath $cleanupPath -Recurse -Force)
        if (@($fixtureItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
            throw 'Fixture cleanup refuses reparse points.'
        }
        Remove-Item -LiteralPath $cleanupPath -Recurse -Force
    }
}
[ordered]@{ok=$true;checks=$script:scopeChecks;powershell=$PSVersionTable.PSVersion.ToString();fixtureRemoved=(-not (Test-Path -LiteralPath $fixtureRoot))} | ConvertTo-Json -Compress
