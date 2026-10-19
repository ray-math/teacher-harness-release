[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$JobPath)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$info = Get-WorkJobInfo -Workspace $workspace -Path $JobPath -RequireJobRoot -RequireExists
$info | ConvertTo-Json -Depth 6 -Compress
