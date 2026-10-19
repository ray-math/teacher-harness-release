[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hwpx-cabinet-root-test-'+[guid]::NewGuid().ToString('N'))
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Value,[string]$Name) { if (-not $Value) { throw "FAIL: $Name" }; $checks.Add($Name) }
function Save([string]$Path,$Value) { New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Path)) -Force | Out-Null; $Value | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Read([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json }
function Json($Value) { ($Value -join [Environment]::NewLine) | ConvertFrom-Json }
function Fails([scriptblock]$Action,[string]$Pattern) { try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return $true }; return $false }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
try {
    $tool=Join-Path $fixture 'tools';$shared=Join-Path $tool '.agent\shared';$configPath=Join-Path $tool '.agent\index\delivery-system.json'
    $old=Join-Path $fixture 'old-cabinet';$cabinet=Join-Path $fixture '2026-work';$empty=Join-Path $fixture 'next-work'
    foreach ($folder in @($shared,(Split-Path $configPath),$cabinet,$empty)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    foreach ($name in @('WorkStorage.ps1','Set-HumanCabinetRoot.ps1','Open-HumanWorkPath.ps1','Get-HwpxRuntime.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared }
    Save (Join-Path $tool '.agent\index\hwpx-runtime.json') @{runtimeDirectory='.agent\cache\runtime';skillVersion='test'}
    foreach ($stub in @('.agent\cache\runtime\Scripts\python.exe','.agent\cache\runtime\Lib\site-packages\hwpx_automation\mcp_cli.py')) {
        $path=Join-Path $tool $stub;New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force | Out-Null;[IO.File]::WriteAllText($path,'fixture only')
    }
    $config=@{humanCabinet=$old;incomingRoot=(Join-Path $fixture 'incoming');metadataFolderName='.ai';workMetadataName='work.json';sourceMetadataName='sources.json';consoleFileName='console.html';openProtocol='hwpx-work-open';openTargetManifest='.agent\index\human-open-targets.json'}
    Save $configPath $config
    $bind=Join-Path $shared 'Set-HumanCabinetRoot.ps1'
    $work=Join-Path $cabinet '23_exam';$meta=Join-Path $work '.ai\work.json';$job=Join-Path $work '.ai\jobs\20260930-root-test';$inputs=Join-Path $job 'inputs.json'
    Save $meta @{title='exam';folderName='23_exam';currentFiles=@('result.txt');layout=@{supportFolders=@()};referenceScope=@{roots=@(@{role='prior';path='..\previous'})}}
    Save $inputs @{job='20260930-root-test';delivery=@{workRoot=(Join-Path $old '23_exam');storageKind='work'};sources=@(@{path=(Join-Path $old '23_exam\source.hwpx');sha256='original'})}
    $document=Join-Path $work 'result.txt';[IO.File]::WriteAllText($document,'original document bytes')
    $before=@{config=(Hash $configPath);meta=(Hash $meta);inputs=(Hash $inputs);document=(Hash $document)}
    $plan=Json (& $bind -CabinetRoot $cabinet -ExpectedPreviousRoot $old -BindLegacyJobs)
    Check (-not $plan.applied -and $plan.plannedFiles -eq 3 -and $plan.changedFiles -eq 0) 'default invocation only plans config and explicit legacy identities'
    Check ((Hash $configPath) -eq $before.config -and (Hash $meta) -eq $before.meta -and (Hash $inputs) -eq $before.inputs) 'planning preserves every original byte'
    Check (Fails { & $bind -CabinetRoot $cabinet -BindLegacyJobs -Apply } 'ExpectedPreviousRoot') 'legacy binding requires old-root identity'
    Check (Fails { & $bind -CabinetRoot $cabinet -ExpectedPreviousRoot $empty -Apply } 'does not match') 'stale previous-root selection rejected'
    Check (Fails { & $bind -CabinetRoot '.\relative' -Apply } 'absolute') 'relative cabinet root rejected'
    Check (Fails { & $bind -CabinetRoot (Join-Path $fixture 'missing') -Apply } 'existing cabinet') 'missing cabinet is not silently created'
    Check (Fails { & $bind -CabinetRoot $tool -Apply } 'distinct') 'tool workspace cannot become cabinet'
    Check (Fails { & $bind -CabinetRoot $fixture -Apply } 'distinct') 'parent of tool workspace cannot become cabinet'
    [IO.File]::SetAttributes($inputs,[IO.FileAttributes]::ReadOnly)
    try { Check (Fails { & $bind -CabinetRoot $cabinet -ExpectedPreviousRoot $old -BindLegacyJobs -Apply } 'read-only') 'read-only metadata fails before migration' } finally { [IO.File]::SetAttributes($inputs,[IO.FileAttributes]::Normal) }
    Check ((Hash $configPath) -eq $before.config -and (Hash $meta) -eq $before.meta -and (Hash $inputs) -eq $before.inputs) 'failed preflight leaves no partial identities'
    $bad=Read $inputs;$bad.delivery.workRoot=Join-Path $old '24_other';Save $inputs $bad
    Check (Fails { & $bind -CabinetRoot $cabinet -ExpectedPreviousRoot $old -BindLegacyJobs -Apply } 'expected previous') 'cross-work legacy binding rejected'
    $bad.delivery.workRoot=Join-Path $old '23_exam';Save $inputs $bad
    $applied=Json (& $bind -CabinetRoot $cabinet -ExpectedPreviousRoot $old -BindLegacyJobs -Apply)
    $savedMeta=Read $meta;$savedInputs=Read $inputs
    Check ($applied.applied -and $applied.changedFiles -eq 3 -and (Read $configPath).humanCabinet -eq $cabinet) 'explicit apply selects moved cabinet and migrates only identities'
    Check ($savedMeta.workId -and $savedMeta.workId -ceq $savedInputs.delivery.workId) 'work and legacy job share one stable identity'
    Check ($savedInputs.delivery.workRoot -eq (Join-Path $old '23_exam') -and $savedInputs.sources[0].path -eq (Join-Path $old '23_exam\source.hwpx')) 'historical paths and provenance are not rewritten'
    Check ((Hash $document) -eq $before.document -and $savedMeta.referenceScope.roots[0].path -eq '..\previous') 'document bytes and explicit reference paths remain unchanged'
    . (Join-Path $shared 'WorkStorage.ps1')
    $info=Get-WorkJobInfo -Workspace $tool -Path $job -RequireJobRoot -RequireExists
    Check ($info.jobRoot -eq $job -and $info.workRoot -eq $work) 'moved legacy job resolves by verified work identity'
    $again=Json (& $bind -CabinetRoot $cabinet -ExpectedPreviousRoot $cabinet -BindLegacyJobs -Apply)
    Check ($again.changedFiles -eq 0) 'repeated migration is idempotent'
    $archiveMeta=Hash $meta;$archiveInputs=Hash $inputs
    $selected=Json (& $bind -CabinetRoot $empty -ExpectedPreviousRoot $cabinet -Apply)
    Check ($selected.changedFiles -eq 1 -and (Hash $meta) -eq $archiveMeta -and (Hash $inputs) -eq $archiveInputs -and @(Get-ChildItem -LiteralPath $empty -Force).Count -eq 0) 'new-year selection changes config only and leaves old cabinet read-only'

    # A relocated tool folder resolves its runtime/config from its own location.
    $relocated=Join-Path $fixture 'work-by-flow';Move-Item -LiteralPath $tool -Destination $relocated
    $shared=Join-Path $relocated '.agent\shared';$configPath=Join-Path $relocated '.agent\index\delivery-system.json';$bind=Join-Path $shared 'Set-HumanCabinetRoot.ps1'
    $relocatedResult=Json (& $bind -CabinetRoot $cabinet -ExpectedPreviousRoot $empty -Apply)
    Check ($relocatedResult.changedFiles -eq 1 -and (Read $configPath).humanCabinet -eq $cabinet) 'tool-folder rename does not require internal hardcoded path updates'
    $runtime=& (Join-Path $shared 'Get-HwpxRuntime.ps1')
    Check ($runtime.Server -eq (Join-Path $relocated '.agent\cache\runtime\Scripts\python.exe') -and $runtime.Arguments[0] -eq '-B' -and $runtime.Arguments[1] -eq '-m' -and $runtime.Arguments[2] -eq 'hwpx_automation.mcp_cli' -and $runtime.Arguments[4] -eq $relocated) 'renamed tool runtime uses current Python and verified module without embedded old executable paths'

    # Console lookup uses cabinet registrations without recreating a tool manifest.
    $installedConfigPath=Join-Path $cabinet '.agent\index\delivery-system.json';$config.humanCabinet=$cabinet;Save $installedConfigPath $config
    $manifest=Join-Path $cabinet '.agent\index\human-open-targets.json';Save $manifest @{workFolders=@(@{workFolder=$work;console=(Join-Path $work 'console.html');targets=@($document)})}
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($work)).TrimEnd('=').Replace('+','-').Replace('/','_')
    $uri='hwpx-work-open:refresh/'+$payload+'/'+[guid]::NewGuid().ToString('N')
    $opened=Json (& (Join-Path $shared 'Open-HumanWorkPath.ps1') -Uri $uri -ValidateOnly)
    Check ($opened.ok -and $opened.target -eq $work -and -not $opened.launched) 'direct core handler validates against installed cabinet manifest'
    Check (-not (Test-Path -LiteralPath (Join-Path $relocated '.agent\index\human-open-targets.json'))) 'console validation creates no tool-owned opening state'
    $config.openProtocol='other-protocol';Save $installedConfigPath $config
    Check (Fails { & (Join-Path $shared 'Open-HumanWorkPath.ps1') -Uri $uri -ValidateOnly } 'does not match') 'mismatched installed runtime is rejected'
    Check ((Hash $document) -eq $before.document) 'all relocation and console checks preserve document bytes'
    [ordered]@{ok=$true;count=$checks.Count;verification='isolated cabinet root selection, legacy identities, tool relocation and console lookup';checks=@($checks)} | ConvertTo-Json -Depth 5
} finally {
    $safe=[IO.Path]::GetFullPath($fixture);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($safe) -ine $tempRoot -or [IO.Path]::GetFileName($safe) -notmatch '^hwpx-cabinet-root-test-[a-f0-9]{32}$') { throw 'Unsafe test cleanup target.' }
    if (Test-Path -LiteralPath $safe) {
        if (@(Get-ChildItem -LiteralPath $safe -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Test fixture contains a reparse point; refusing recursive cleanup.' }
        Remove-Item -LiteralPath $safe -Recurse -Force
    }
}
