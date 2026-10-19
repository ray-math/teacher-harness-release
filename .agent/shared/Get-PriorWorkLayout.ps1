[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TaskTitle,

    [string]$ExcludeFolderName = '',
    [string[]]$PriorFolder = @(),
    [ValidateRange(1, 10)]
    [int]$Limit = 3
)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
. (Join-Path $PSScriptRoot 'WorkRegistry.ps1')
. (Join-Path $PSScriptRoot 'WorkReferenceScope.ps1')
$registry = Get-WorkRegistry -Workspace $workspace
$selectedFolders = @(foreach ($path in @($PriorFolder | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not (Test-ReferenceVisiblePath -Path $path)) { throw 'PriorFolder must be an explicitly selected visible, plain directory.' }
    $folder = Get-Item -LiteralPath (Resolve-Path -LiteralPath $path).Path -Force
    if (-not $folder.PSIsContainer -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'PriorFolder must be a plain directory.' }
    $folder
})

function Get-CoreTokens([string]$Value) {
    $clean = $Value -replace '^(?:\d{8}|\d{2}(?:-\d{2})*)_', ' '
    $clean = $clean -replace '\[[^\]]+\]', ' '
    $clean = $clean -replace '20\d{2}\s*학년도?', ' '
    $clean = $clean -replace '[12]\s*학기', ' '
    $clean = $clean -replace '\d+\s*(?:차|회)', ' '
    $clean = $clean -replace '(본문|붙임\d*|첨부|알림|안내|협조|관련|업무|계획)', ' '
    @($clean -split '[\s_\-().,''"「」\[\]·]+' | Where-Object { $_.Length -ge 2 } | Select-Object -Unique)
}

$taskTokens = @(Get-CoreTokens $TaskTitle)
if ($taskTokens.Count -eq 0) { throw 'No usable layout token was derived from TaskTitle.' }
$archiveName = [string]$config.archiveFolderName
$metadataName = [string]$config.metadataFolderName
$candidates = [Collections.Generic.List[object]]::new()

foreach ($folder in $selectedFolders) {
    if ($folder.Name -ieq $ExcludeFolderName) { continue }
    $entry = @(if ($folder.Parent.FullName -ieq [IO.Path]::GetFullPath([string]$config.humanCabinet).TrimEnd('\')) { $registry.works | Where-Object folderName -eq $folder.Name | Select-Object -First 1 })
    $candidateTitle = if ($entry.Count -gt 0 -and $entry[0].title) { [string]$entry[0].title } else { $folder.Name }
    $candidateTokens = @(Get-CoreTokens $candidateTitle)
    $hits = @($taskTokens | Where-Object { $candidateTokens -contains $_ })
    if ($hits.Count -eq 0) { continue }

    $score = ($hits.Count * 30)
    if ($candidateTokens.Count -gt 0) { $score += [math]::Round(40 * $hits.Count / [math]::Max($taskTokens.Count, $candidateTokens.Count)) }
    if ($folder.Name -match ('^' + (Get-Date).Year.ToString())) { $score += 5 }

    $supportFolders = @(
        Get-ChildItem -LiteralPath $folder.FullName -Directory -Force |
            Where-Object {
                $_.Name -ine $archiveName -and $_.Name -ine $metadataName -and
                (Test-ReferenceVisiblePath -Path $_.FullName)
            } |
            Sort-Object Name |
            ForEach-Object {
                [ordered]@{
                    name = $_.Name
                    directFiles = @(Get-ReferenceFiles -Path $_.FullName -DirectOnly).Count
                    totalFiles = @(Get-ReferenceFiles -Path $_.FullName).Count
                }
            }
    )
    $currentExtensions = @(
        Get-ReferenceFiles -Path $folder.FullName -DirectOnly |
            Where-Object { $_.Name -ine [string]$config.consoleFileName } |
            Group-Object { $_.Extension.ToLowerInvariant() } |
            Sort-Object Name |
            ForEach-Object { [ordered]@{ extension=$_.Name; count=$_.Count } }
    )
    $candidates.Add([pscustomobject]@{
        score = [int]$score
        title = $candidateTitle
        folderName = $folder.Name
        path = $folder.FullName
        matchedTokens = @($hits)
        supportFolders = @($supportFolders)
        currentFileExtensions = @($currentExtensions)
    })
}

$ranked = @($candidates | Sort-Object @{Expression='score';Descending=$true}, @{Expression='folderName';Descending=$true} | Select-Object -First $Limit)
[ordered]@{
    schemaVersion = 'hwpx-prior-layout/v1'
    status = $(if ($selectedFolders.Count) { 'ready' } else { 'needs_input' })
    reason = $(if ($selectedFolders.Count) { $null } else { 'prior_folder_not_selected' })
    taskTitle = $TaskTitle
    taskTokens = @($taskTokens)
    candidates = @($ranked)
} | ConvertTo-Json -Depth 8
