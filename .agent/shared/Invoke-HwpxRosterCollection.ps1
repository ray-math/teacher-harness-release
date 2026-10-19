[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ConfigPath)
$ErrorActionPreference='Stop'
$runtime = & (Join-Path $PSScriptRoot 'Get-HwpxRuntime.ps1')
$python = $runtime.Python
$env:PYTHONUTF8 = '1'
$runner=Join-Path $PSScriptRoot 'collect-hwpx-rosters/collect.py'
& $python $runner --config ([IO.Path]::GetFullPath($ConfigPath))
if($LASTEXITCODE -ne 0){throw 'Roster collection stopped; inspect job receipts before retrying'}
