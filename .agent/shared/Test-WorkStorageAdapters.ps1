[CmdletBinding()]
param([string]$ReceiptPath = '')
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('hwpx-storage-adapters-' + [guid]::NewGuid().ToString('N'))
$checks = [Collections.Generic.List[string]]::new()
function Check([bool]$Ok,[string]$Name) { if (-not $Ok) { throw "FAIL: $Name" }; $checks.Add($Name) }
function Json($Lines) { ($Lines -join [Environment]::NewLine) | ConvertFrom-Json }
function Save($Path,$Value) { $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Fails([scriptblock]$Action,[string]$Pattern,[string]$Name) {
    $failed = $false
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; $failed = $true }
    Check $failed $Name
}
try {
    $shared = Join-Path $fixture '.agent\shared'; $index = Join-Path $fixture '.agent\index'
    $cabinet = Join-Path $fixture 'cabinet'; $folder = '20260929_Path test'; $work = Join-Path $cabinet $folder
    $job = Join-Path $work '.ai\jobs\20260929-adapter-test'
    $legacy = Join-Path $fixture '.agent\jobs\20260929-legacy-test'
    foreach ($p in @($shared,$index,(Join-Path $shared 'hancom-native'),(Join-Path $job 'wip\receipts'),(Join-Path $legacy 'wip\receipts'),(Join-Path $work '.ai'))) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    foreach ($name in @('WorkStorage.ps1','WorkRegistry.ps1','WorkReferenceScope.ps1','Resolve-HwpxJobStorage.ps1','work_storage.py','document_scope.py','Assert-DocumentOperationScope.ps1','DocumentScope.ps1','run_hwpx_edit_plan.py','paragraph_target_preflight.py','Convert-SelectedInputsToHwpx.ps1','New-HwpxFormContract.ps1','Find-HwpxContext.ps1','Invoke-HancomMerge.ps1','Publish-HumanConsoleContent.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $shared $name) }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'hancom-native\prepare_merge.py') -Destination (Join-Path $shared 'hancom-native\prepare_merge.py')
    Save (Join-Path $index 'delivery-system.json') @{humanCabinet=$cabinet;incomingRoot=(Join-Path $fixture 'incoming');archiveFolderName='previous_versions';metadataFolderName='.ai';workMetadataName='work.json';sourceMetadataName='sources.json';consoleFileName='업무현황.html';defaultEvidenceFolderName='업무근거';defaultCollectionFolderName='취합자료';defaultReferenceFolderName='참고자료';openTargetManifest='.agent\index\human-open-targets.json'}
    Save (Join-Path $work '.ai\work.json') @{title='Path test';currentFiles=@();currentFileRecords=@();stage='Draft'}
    Save (Join-Path $work '.ai\sources.json') @{sources=@()}
    Save (Join-Path $job 'inputs.json') @{delivery=@{workRoot=$work};sources=@()}
    Save (Join-Path $legacy 'inputs.json') @{sources=@()}
    $seed = Join-Path $fixture 'selected.hwp'
    [IO.File]::WriteAllText($seed,'synthetic selected path; never converted or opened')
    $seedHash = (Get-FileHash -LiteralPath $seed).Hash

    $normalize = Join-Path $shared 'Convert-SelectedInputsToHwpx.ps1'
    $plan = Json (& $normalize -InputFile $seed -JobPath $job -PlanOnly)
    Check ($plan.planOnly -and $plan.outputRoot -eq (Join-Path $job 'wip\docs\normalized')) 'normalization plan retains the selected job storage'
    Check (-not (Test-Path -LiteralPath $plan.outputRoot)) 'normalization plan makes no document copy'
    Fails { & $normalize -InputFile $seed -JobPath $legacy -PlanOnly } 'outside the selected work storage' 'normalization rejects legacy shared storage'
    Fails { & $normalize -InputFile $seed -JobPath $work -PlanOnly } 'job|storage' 'normalization rejects the human current-file root'

    $contractScript = Join-Path $shared 'New-HwpxFormContract.ps1'
    $contract = Join-Path $job 'wip\receipts\hwpx-form-contract.json'
    $null = & $contractScript -FormStatus unreadable -AuthoritativeForm $seed -FormLayout separate -OutputPath $contract
    Check (Test-Path -LiteralPath $contract -PathType Leaf) 'form contract is stored beside the work job receipts'
    Fails { & $contractScript -FormStatus unreadable -AuthoritativeForm $seed -FormLayout separate -OutputPath (Join-Path $job 'wip\wrong\hwpx-form-contract.json') } 'canonical contract path' 'noncanonical work contract path rejected'
    Fails { & $contractScript -FormStatus unreadable -AuthoritativeForm $seed -FormLayout separate -OutputPath (Join-Path $work 'hwpx-form-contract.json') } 'job|storage' 'form contract cannot appear at the human current-file root'
    $discovery = Join-Path $job 'wip\receipts\context.json'
    $discovered = Json (& (Join-Path $shared 'Find-HwpxContext.ps1') -TaskTitle 'Path test' -SummaryOnly -OutputPath $discovery)
    Check (Test-Path -LiteralPath $discovery -PathType Leaf) 'bounded discovery accepts work job receipt output'
    Check ($discovered.status -eq 'needs_input') 'discovery asks for references when none were selected'

    $content = Join-Path $job 'wip\content.json'
    Save $content @{schemaVersion='hwpx-console-content/v1';sections=@()}
    $console = Json (& (Join-Path $shared 'Publish-HumanConsoleContent.ps1') -WorkFolderName $folder -ConsoleContentPath $content -PlanOnly)
    Check ($console.planOnly -and $console.receiptPath.StartsWith((Join-Path $job 'wip\receipts\'),[StringComparison]::OrdinalIgnoreCase)) 'console plan keeps receipts with its work job'
    Check (-not (Test-Path -LiteralPath $console.receiptPath)) 'console planning writes no publication receipt'
    $other = Join-Path $cabinet '20260929_Other'; $otherJob = Join-Path $other '.ai\jobs\20260929-other-test'
    New-Item -ItemType Directory -Path $otherJob -Force | Out-Null
    Save (Join-Path $otherJob 'inputs.json') @{delivery=@{workRoot=$other};sources=@()}
    $otherContent = Join-Path $otherJob 'content.json'; Copy-Item -LiteralPath $content -Destination $otherContent
    Fails { & (Join-Path $shared 'Publish-HumanConsoleContent.ps1') -WorkFolderName $folder -ConsoleContentPath $otherContent -PlanOnly } 'different human work' 'console rejects a different work job'
    Fails { & (Join-Path $shared 'Invoke-HancomMerge.ps1') -Manifest $content } 'directly' 'native merge rejects a nested manifest before native execution'

    $runtimeSpec = Get-Content -LiteralPath (Join-Path $workspace '.agent\index\hwpx-runtime.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $python = Join-Path (Join-Path $workspace $runtimeSpec.runtimeDirectory) 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Existing pinned Python runtime is required for adapter path verification.' }
    $planPath = Join-Path $job 'plan.json'
    Save $planPath @{source=$seed;output=(Join-Path $job 'wip\planned.hwpx');steps=@()}
    $result = & $python -B (Join-Path $shared 'run_hwpx_edit_plan.py') --job $job --plan $planPath --source-sha256 $seedHash --status
    Check ($LASTEXITCODE -eq 0 -and (Json $result).status -eq 'not_started') 'Python edit adapter resolves Unicode work storage without editing'
    Check (-not (Test-Path -LiteralPath (Join-Path $job 'wip\planned.hwpx'))) 'Python status does not create a document'
    $emptyInputs = Join-Path $job 'empty-inputs.json'; [IO.File]::WriteAllText($emptyInputs,'[]')
    $process = [Diagnostics.ProcessStartInfo]::new()
    $process.FileName=$python; $process.UseShellExecute=$false; $process.CreateNoWindow=$true; $process.RedirectStandardOutput=$true; $process.RedirectStandardError=$true
    $process.Arguments='-B "' + (Join-Path $shared 'hancom-native\prepare_merge.py') + '" --job "' + $job + '" --inputs "' + $emptyInputs + '"'
    $child=[Diagnostics.Process]::Start($process)
    try { $stdout=$child.StandardOutput.ReadToEnd(); $stderr=$child.StandardError.ReadToEnd(); $child.WaitForExit(); if ($stderr -notmatch 'Input list must contain') { throw "Unexpected preparation diagnostic: $stderr" }; Check ($child.ExitCode -ne 0) 'native preparation resolves work job before rejecting the empty input list' } finally { $child.Dispose() }
    Check (-not (Test-Path -LiteralPath (Join-Path $job 'native-plan.json')) -and (Get-FileHash -LiteralPath $seed).Hash -eq $seedHash) 'path tests preserve inputs and create no merge manifest'
    Check (-not (Test-Path -LiteralPath (Join-Path $index 'human-current.json'))) 'adapters do not generate a global work registry'
    $report=[ordered]@{ok=$true;count=$checks.Count;checks=@($checks);powershell=$PSVersionTable.PSVersion.ToString();nativeExecution=$false;documentCreation=$false}
    $reportJson=$report | ConvertTo-Json -Depth 8
    if ($ReceiptPath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReceiptPath),$reportJson,[Text.UTF8Encoding]::new($true)) }
    $reportJson
} finally {
    $safe=[IO.Path]::GetFullPath($fixture)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($safe) -ine $tempRoot -or [IO.Path]::GetFileName($safe) -notmatch '^hwpx-storage-adapters-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $safe) {
        if ((Get-Item -LiteralPath $safe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixture root became a reparse point.' }
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
