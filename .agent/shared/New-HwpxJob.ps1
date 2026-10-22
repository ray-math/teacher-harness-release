[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,48}$')]
    [string]$Slug,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Goal,

    [ValidatePattern('^\d{8}$')]
    [string]$Date = (Get-Date -Format 'yyyyMMdd'),
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkFolder
)

$ErrorActionPreference = 'Stop'
$workspace = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$jobsRoot = $null
if ($WorkFolder) {
    $config = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $workspace '.agent/index/delivery-system.json') | ConvertFrom-Json
    $pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
    if (Test-Path -LiteralPath $pathResolver) {
        . $pathResolver
        $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
    } elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
    $workRoot = Assert-WorkStoragePath $WorkFolder
    $cabinet = Get-WorkContainerRoot $config
    if ($config.outputLayout -eq 'flat' -and [IO.Path]::GetDirectoryName($workRoot) -ieq [IO.Path]::GetFullPath([string]$config.humanCabinet).TrimEnd('\')) { $cabinet = [IO.Path]::GetFullPath([string]$config.humanCabinet).TrimEnd('\') }
    if ([IO.Path]::GetDirectoryName($workRoot) -ine $cabinet -or -not (Test-WorkFolderName ([IO.Path]::GetFileName($workRoot)))) { throw 'WorkFolder must be a direct work folder with a safe name in the configured cabinet.' }
    $jobsRoot = Join-Path (Join-Path $workRoot ([string]$config.metadataFolderName)) 'jobs'
}
$jobName = "$Date-$Slug"
$jobRoot = Join-Path $jobsRoot $jobName
[void](Get-WorkJobInfo -Workspace $workspace -Path $jobRoot -RequireJobRoot)

if (-not $jobRoot.StartsWith($jobsRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Job path escaped jobs root: $jobRoot"
}
if (Test-Path -LiteralPath $jobRoot) {
    throw "Job already exists: $jobRoot"
}

$folders = @(
    $jobRoot,
    (Join-Path $jobRoot 'wip'),
    (Join-Path $jobRoot 'wip\docs'),
    (Join-Path $jobRoot 'wip\scripts'),
    (Join-Path $jobRoot 'wip\previews'),
    (Join-Path $jobRoot 'wip\receipts')
)
foreach ($folder in $folders) {
    New-Item -ItemType Directory -Path $folder | Out-Null
}

$createdAt = Get-Date -Format 'o'
$brief = @"
# $jobName

## Goal

$Goal

## Scope

- Record selected inputs and exclusions here.

## Deliverable

- Record the official title and destination here.

## Status

active

## Completion and evidence

Record the requested checkpoint, any unresolved facts or authority decisions, and the checks actually applicable to this job. Follow the workspace AGENTS.md and its document-delivery skill for document work; do not duplicate their policy here. Existing user authorization remains valid. Record verification receipts and remaining limits before closeout.
"@
Set-Content -LiteralPath (Join-Path $jobRoot 'brief.md') -Value $brief -Encoding utf8

$inputs = [ordered]@{
    schemaVersion = 'hwpx-workspace.inputs/v1'
    job = $jobName
    createdAt = $createdAt
    sources = @()
    privacy = [ordered]@{
        containsPersonalData = $false
        maskingRequired = $true
        notes = ''
    }
}
if ($WorkFolder) {
    $inputs['delivery'] = [ordered]@{workRoot=$workRoot;storageKind='work'}
    $workMetadataPath = Assert-WorkStoragePath (Join-Path (Join-Path $workRoot ([string]$config.metadataFolderName)) ([string]$config.workMetadataName))
    if (Test-Path -LiteralPath $workMetadataPath -PathType Leaf) {
        $workMetadata = Get-Content -LiteralPath $workMetadataPath -Raw -Encoding utf8 | ConvertFrom-Json
        if ($workMetadata.workId) { $inputs.delivery['workId'] = [string]$workMetadata.workId }
    }
}
$inputs | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $jobRoot 'inputs.json') -Encoding utf8

Write-Output $jobRoot
