[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$JobPath,
    [Parameter(Mandatory=$true)][string[]]$SourceFile,
    [Parameter(Mandatory=$true)][string[]]$TargetRelativePath,
    [Parameter(Mandatory=$true)][ValidateSet('Review','Final')][string]$Stage,
    [Parameter(Mandatory=$true)][string[]]$ChecksCompleted,
    [string[]]$CheckReceiptFile=@(),
    [string]$DeliveryConfigPath=''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HumanDeliveryContract.ps1')
$context = Get-HumanDeliveryContext -JobPath $JobPath -DeliveryConfigPath $DeliveryConfigPath
Assert-HumanDeliveryChecks $ChecksCompleted
$files = @(Get-HumanDeliveryFiles -Context $context -SourceFile $SourceFile -TargetRelativePath $TargetRelativePath)
$checks = @(foreach ($item in $CheckReceiptFile) {
    $path = Assert-WorkStoragePath $item
    if (-not $path.StartsWith((Join-Path $context.jobPath 'wip\receipts') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Completion check receipts must stay in this job receipts tree.' }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Check receipt is not a file: $path" }
    [ordered]@{path=$path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
})
$receipt = [ordered]@{
    schemaVersion='human-delivery-ready/v1';jobPath=$context.jobPath;stage=$Stage
    deliveryCycleId=[string]$context.cycle.id;requestKey=[string]$context.cycle.requestKey;requestTextSha256=(Get-DocumentScopeTextHash ([string]$context.cycle.requestText))
    documentBasis=$context.basis
    completedAt=(Get-Date -Format 'o');documentScope=(Get-HumanDeliveryScopeSnapshot $context.scope)
    checksCompleted=@($ChecksCompleted);checkReceipts=$checks;files=$files
}
$path = Assert-WorkStoragePath (Join-Path $context.jobPath 'wip\receipts\human-delivery-ready.json')
$parent = [IO.Path]::GetDirectoryName($path)
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$temporary = Join-Path $parent ('.ready-' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    $receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $path -Force
} finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
}
# Output only a compact reference; publication revalidates the complete evidence.
[pscustomobject]@{status='ready';receiptPath=$path;deliveryCycleId=$receipt.deliveryCycleId;fileCount=$files.Count;stage=$Stage} | ConvertTo-Json -Compress
