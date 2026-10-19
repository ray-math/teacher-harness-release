[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkFolder,
    [Parameter(Mandatory=$true)][string]$Key,
    [string]$Text='',
    [switch]$Disabled,
    [switch]$RemoveOverride,
    [switch]$ConfirmedByUser
)
$ErrorActionPreference='Stop'
if (-not $ConfirmedByUser) { throw 'Only user-confirmed work exceptions may be saved.' }
if ($Key -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$' -or ($Disabled -and $RemoveOverride) -or (($Disabled -or $RemoveOverride) -and $Text) -or (-not $Disabled -and -not $RemoveOverride -and [string]::IsNullOrWhiteSpace($Text))) { throw 'Choose a stable key and either confirmed text, Disabled, or RemoveOverride.' }
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
. (Join-Path $PSScriptRoot 'WorkGroup.ps1')
$config=Get-Content -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$work=Assert-WorkStoragePath $WorkFolder
if ([IO.Path]::GetDirectoryName($work) -ine (Assert-WorkStoragePath ([string]$config.humanCabinet)).TrimEnd('\') -or -not (Test-WorkFolderName -Name ([IO.Path]::GetFileName($work)))) { throw 'WorkFolder must be an existing direct human work folder.' }
$path=Assert-WorkStoragePath (Join-Path $work '.ai\work.json')
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Register the work before saving a confirmed exception.' }
$mutex=[Threading.Mutex]::new($false,'Local\HwpxWorkGroupRecords');$locked=$false
try {
    $locked=$mutex.WaitOne([TimeSpan]::FromSeconds(15));if(-not $locked){throw 'Timed out while saving confirmed context.'}
    $metadata=Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    $overrides=@($metadata.decisionOverrides | Where-Object { $null -ne $_ -and $_.key -ne $Key })
    if (-not $RemoveOverride) { $overrides+= [pscustomobject]@{key=$Key;text=$Text;disabled=[bool]$Disabled;confirmedBy='user';confirmedAt=(Get-Date -Format o)} }
    $metadata | Add-Member -NotePropertyName decisionOverrides -NotePropertyValue @($overrides) -Force
    Write-WorkContextJson -Path $path -Value $metadata
    @{ok=$true;workFolder=$work;key=$Key;removed=[bool]$RemoveOverride;groupChanged=$false;documentsRewritten=0} | ConvertTo-Json
} finally { if($locked){$mutex.ReleaseMutex()};$mutex.Dispose() }
