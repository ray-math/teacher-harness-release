# Work state is owned by each work folder. This reader never writes a workspace index.
function Get-WorkRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Workspace,[string]$DeliveryConfigPath='')
    . (Join-Path $PSScriptRoot 'WorkStorage.ps1')
    $configPath = if ($DeliveryConfigPath) { $DeliveryConfigPath } else { Join-Path $Workspace '.agent/index/delivery-system.json' }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json
    $pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
    if (Test-Path -LiteralPath $pathResolver) {
        . $pathResolver
        $config = Resolve-TeacherHarnessConfig -Workspace $Workspace -Config $config
    } elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
    $cabinet = Assert-WorkStoragePath (Get-WorkContainerRoot $config)
    $containers = @($cabinet)
    if ($config.outputLayout -eq 'flat') { $containers += [IO.Path]::GetFullPath([string]$config.humanCabinet) }
    $entries = @(
      foreach ($cabinet in $containers) {
        if (Test-Path -LiteralPath $cabinet -PathType Container) {
            foreach ($folder in @(Get-ChildItem -LiteralPath $cabinet -Directory -Force | Where-Object { (Test-WorkFolderName $_.Name) -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })) {
                $metadataPath = Assert-WorkStoragePath (Join-Path (Join-Path $folder.FullName ([string]$config.metadataFolderName)) ([string]$config.workMetadataName))
                if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { continue }
                $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json
                if ([string]::IsNullOrWhiteSpace([string]$metadata.title)) { throw 'Registered work metadata requires a title.' }
                if ($metadata.folderName -and [string]$metadata.folderName -ine $folder.Name) { throw 'Work metadata folderName does not match its containing folder.' }
                $entry = [ordered]@{}
                if ($metadata.registration) { foreach ($property in $metadata.registration.PSObject.Properties) { $entry[$property.Name]=$property.Value } }
                foreach ($field in @('workId','title','createdDate','lastIntakeAt','stage','publishedAt','currentFileRecords')) {
                    if ($metadata.PSObject.Properties.Name -contains $field) { $entry[$field]=$metadata.$field }
                }
                # Keep the exact original registration timestamp through migration.
                # The local work timestamp can encode the same instant differently.
                if (-not $entry.Contains('firstIntakeAt') -and $metadata.PSObject.Properties.Name -contains 'firstIntakeAt') { $entry['firstIntakeAt']=$metadata.firstIntakeAt }
                $entry['folderName']=$folder.Name
                $entry['workRoot']=$folder.FullName
                if (-not $entry['createdDate'] -and $folder.Name -match '^\d{8}_') { $entry['createdDate']=$folder.Name.Substring(0,8) }
                $entry['files']=@($metadata.currentFiles | Where-Object { $_ })
                $entry['metadataFolder']=[string]$config.metadataFolderName
                $entry['supportFolders']=@($metadata.layout.supportFolders | Where-Object { $_ })
                $entry['layoutReference']=$metadata.layout.referenceFolder
                if (-not $entry.Contains('workState')) { $entry['workState']=if($metadata.stage -eq 'Final'){'Complete'}elseif($metadata.stage -eq 'Review'){'ReviewPending'}else{'Intake'} }
                if (-not $entry.Contains('console')) { $entry['console']=if(Test-Path -LiteralPath (Join-Path $folder.FullName ([string]$config.consoleFileName)) -PathType Leaf){[string]$config.consoleFileName}else{$null} }
                [pscustomobject]$entry
            }
        }
      }
    )
    [pscustomobject]@{schemaVersion='hwpx-human-current/work-local-v1';works=@($entries)}
}

function Set-WorkRegistration {
    param([Parameter(Mandatory=$true)][Collections.IDictionary]$Metadata,[Parameter(Mandatory=$true)][Collections.IDictionary]$Entry)
    # Preserve extension fields during migration and later updates; current files stay in work.json.
    $registration=[ordered]@{}
    if ($Metadata.Contains('registration') -and $Metadata.registration -is [Collections.IDictionary]) {
        foreach($key in $Metadata.registration.Keys){$registration[$key]=$Metadata.registration[$key]}
    }
    foreach($key in $Entry.Keys){$registration[$key]=$Entry[$key]}
    foreach($key in @('workId','title','createdDate','folderName','lastIntakeAt','stage','publishedAt','files','currentFileRecords','metadataFolder','supportFolders','layoutReference')){ $registration.Remove($key) }
    $Metadata['registration']=$registration
}
