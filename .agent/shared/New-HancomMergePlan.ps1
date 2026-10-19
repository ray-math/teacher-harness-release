[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$JobPath,[Parameter(Mandatory=$true)][string]$InputList,[string]$OutputName='merged.hwpx')
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$runtime = & (Join-Path $PSScriptRoot 'Get-HwpxRuntime.ps1')
& $runtime.Python (Join-Path $PSScriptRoot 'hancom-native\prepare_merge.py') --job $JobPath --inputs $InputList --name $OutputName
if($LASTEXITCODE -ne 0){throw 'Merge plan preparation failed'}
