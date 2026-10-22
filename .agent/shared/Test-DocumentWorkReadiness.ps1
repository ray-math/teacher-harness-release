[CmdletBinding()]
param([string[]]$InputFile = @(), [switch]$ProbeWrite)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1')
$config = Read-TeacherHarnessConfig -Workspace $workspace
$checks = [Collections.Generic.List[object]]::new()
foreach ($path in $InputFile) {
    $full = [IO.Path]::GetFullPath($path)
    $exists = Test-Path -LiteralPath $full -PathType Leaf
    $checks.Add([pscustomobject]@{kind='input';path=$full;ok=$exists;sha256=$(if ($exists) {(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash} else {$null})})
}
$destinationNames = @('humanCabinet')
if ($config.receiveInputs) { $destinationNames += 'incomingRoot' }
foreach ($name in $destinationNames) {
    $target = [IO.Path]::GetFullPath([string]$config.$name)
    $parent = $target
    while (-not (Test-Path -LiteralPath $parent)) {
        $next = [IO.Path]::GetDirectoryName($parent)
        if (-not $next -or $next -eq $parent) { throw "No existing parent for $target" }
        $parent = $next
    }
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Destination ancestor is not a directory: $parent" }
    $cursor = $parent
    while ($cursor) {
        if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse ancestor requires explicit path review: $cursor" }
        $next = [IO.Path]::GetDirectoryName($cursor)
        if ($next -eq $cursor) { break }; $cursor = $next
    }
    $writeStatus = 'not_tested'
    if ($ProbeWrite) {
        $probe = Join-Path $parent ('.teacher-write-probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            $stream = [IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $stream.WriteByte(1) } finally { $stream.Dispose() }
            $writeStatus = 'passed'
        } finally { if (Test-Path -LiteralPath $probe -PathType Leaf) { Remove-Item -LiteralPath $probe -Force } }
    }
    $checks.Add([pscustomobject]@{kind=$name;path=$target;existingAncestor=$parent;ok=$true;writeProbe=$writeStatus})
}
$runtimeConfig = Get-Content -LiteralPath (Join-Path $workspace '.agent/index/hwpx-runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$runtime = [string]$runtimeConfig.runtimeDirectory
if (-not [IO.Path]::IsPathRooted($runtime)) { $runtime = Join-Path $workspace $runtime }
$python = Join-Path $runtime 'Scripts/python.exe'
$runtimeOk = Test-Path -LiteralPath $python -PathType Leaf
$versions = $null
if ($runtimeOk) {
    $response = @(& $python -B -c "import json; from importlib.metadata import version; print(json.dumps({n:version(n) for n in ['python-hwpx','python-hwpx-automation']}))")
    if ($LASTEXITCODE -ne 0) { $runtimeOk = $false } else {
        $versions = ($response -join '') | ConvertFrom-Json
        foreach ($property in $runtimeConfig.versions.PSObject.Properties) {
            if ($versions.($property.Name) -ne $property.Value) { $runtimeOk = $false }
        }
    }
}
$checks.Add([pscustomobject]@{kind='hwpxRuntime';path=$python;ok=$runtimeOk;versions=$versions})
$ok = @($checks | Where-Object { -not $_.ok }).Count -eq 0
[pscustomobject]@{schemaVersion='document-work-readiness/v1';ok=$ok;checkedAtUtc=[DateTime]::UtcNow.ToString('o');checks=@($checks);approvalService='not_tested';mcpRoot='not_tested';note='A successful probe verifies this invocation only; it does not grant or predict future approvals. No installation or configuration change was performed.'} | ConvertTo-Json -Depth 8
if (-not $ok) { exit 1 }
