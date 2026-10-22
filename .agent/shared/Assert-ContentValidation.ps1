[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$JobPath, [Parameter(Mandatory=$true)]$Files)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$validator = Join-Path $PSScriptRoot 'validate_content_contract.py'
$receiptPath = Join-Path $JobPath 'wip\receipts\content-validation.json'
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw 'Required content validation receipt is missing. Run validate_content_contract.py --job before completion.' }
# Reuse an installed interpreter. This read-only gate never installs runtimes.
$candidates = @()
$odtConfig = Join-Path $workspace '.agent\index\odt-runtime.json'
if (Test-Path -LiteralPath $odtConfig -PathType Leaf) {
    $odt = Get-Content -LiteralPath $odtConfig -Raw -Encoding utf8 | ConvertFrom-Json
    if ($odt.pythonPath) { $candidates += [string]$odt.pythonPath }
}
$hwpxConfig = Join-Path $workspace '.agent\index\hwpx-runtime.json'
if (Test-Path -LiteralPath $hwpxConfig -PathType Leaf) {
    $hwpx = Get-Content -LiteralPath $hwpxConfig -Raw -Encoding utf8 | ConvertFrom-Json
    if ($hwpx.runtimeDirectory) { $candidates += Join-Path (Join-Path $workspace ([string]$hwpx.runtimeDirectory)) 'Scripts\python.exe' }
}
$candidates += Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$python = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
if ($python.Count -eq 0) { throw 'Required content validation needs an existing configured or bundled Python runtime; no runtime was installed.' }
$result = @(& $python[0] -B $validator --job $JobPath --check-existing)
if ($LASTEXITCODE -ne 0) { throw ('Required content validation failed: ' + ($result -join ' ')) }
$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 | ConvertFrom-Json
if (-not $receipt.ok -or @($receipt.outputs).Count -ne @($Files).Count) { throw 'Required content validation output set disagrees with completion/publication.' }
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$jobInfo = Get-WorkJobInfo -Workspace $workspace -Path $JobPath -RequireJobRoot
foreach ($record in $receipt.outputs) { $record.targetRelativePath = Resolve-WorkDeliveryName -WorkRoot $jobInfo.workRoot -RelativePath ([string]$record.targetRelativePath) }
foreach ($file in $Files) {
    $matched = @($receipt.outputs | Where-Object { $_.path -ieq $file.sourcePath -and ([string]$_.targetRelativePath).Replace('/','\') -ceq ([string]$file.targetRelativePath).Replace('/','\') -and $_.sha256 -ieq $file.sha256 })
    if ($matched.Count -ne 1) { throw 'Required content validation output binding disagrees with completion/publication.' }
}
[pscustomobject]@{path=$receiptPath;sha256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash}
