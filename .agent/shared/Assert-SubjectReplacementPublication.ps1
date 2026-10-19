[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$JobPath,[Parameter(Mandatory=$true)][string[]]$SourceFile,[Parameter(Mandatory=$true)][string]$ReceiptPath)
$ErrorActionPreference='Stop'
$job=(Resolve-Path -LiteralPath $JobPath).Path
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$runtime=Get-Content -Raw -Encoding UTF8 (Join-Path $workspace '.agent\index\hwpx-runtime.json') | ConvertFrom-Json
$python=Join-Path $workspace ($runtime.runtimeDirectory+'\Scripts\python.exe')
$request=Join-Path $job ('wip\receipts\subject-publication-check-'+[guid]::NewGuid().ToString('N')+'.json')
[ordered]@{job=$job;receipt=$ReceiptPath;sources=@($SourceFile)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $request -Encoding UTF8
$env:PYTHONIOENCODING='utf-8'
$result=& $python (Join-Path $PSScriptRoot 'subject-replacement\verify.py') $request
if($LASTEXITCODE -ne 0){throw 'Native subject replacement publication verification failed'}
$result
