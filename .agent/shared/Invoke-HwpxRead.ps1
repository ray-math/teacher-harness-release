[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [ValidateRange(5,300)][int]$TimeoutSeconds=60
)
$ErrorActionPreference = 'Stop'
$runtime = & (Join-Path $PSScriptRoot 'Get-HwpxRuntime.ps1')
$env:PYTHONUTF8='1'
& $runtime.Python (Join-Path $PSScriptRoot 'hwpx_read_client.py') --request ([IO.Path]::GetFullPath($RequestPath)) --output ([IO.Path]::GetFullPath($OutputPath)) --timeout $TimeoutSeconds
if ($LASTEXITCODE -ne 0) { throw 'HWPX read failed. Inspect the error; do not retry unchanged input automatically.' }
