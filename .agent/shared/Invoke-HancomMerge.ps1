[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Manifest)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$worker=Join-Path $PSScriptRoot 'hancom-native\run_merge.py'
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$manifestInfo=Get-WorkJobInfo -Workspace $workspace -Path $Manifest -RequireExists
$manifestPath=[IO.Path]::GetFullPath($Manifest)
if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf) -or [IO.Path]::GetDirectoryName($manifestPath) -ine $manifestInfo.jobRoot){throw 'Manifest must belong directly to an active job'}
$mergePlan=Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
if ($mergePlan.renderPdf) {
    . (Join-Path $PSScriptRoot 'DocumentScope.ps1')
    Assert-DocumentCapability $manifestInfo.jobRoot 'visual_review' | Out-Null
}
$runtime = & (Join-Path $PSScriptRoot 'Get-HwpxRuntime.ps1')
$python=$runtime.Python
& $python $worker $manifestPath
if($LASTEXITCODE -ne 0){throw 'Native merge did not pass; inspect the returned receipt. Do not blindly retry.'}
