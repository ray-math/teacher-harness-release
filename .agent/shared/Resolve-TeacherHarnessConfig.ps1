function Resolve-TeacherHarnessConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Workspace,
        [Parameter(Mandatory=$true)][object]$Config
    )

    $workspaceRoot = [IO.Path]::GetFullPath($Workspace)
    # Return a copy so reading a portable config never writes or mutates it.
    $resolved = $Config | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    if (-not $resolved.PSObject.Properties['receiveInputs']) {
        $resolved | Add-Member -NotePropertyName receiveInputs -NotePropertyValue $true
    } elseif ($resolved.receiveInputs -isnot [bool]) {
        throw 'Teacher harness receiveInputs must be a JSON boolean.'
    }
    $baseRoot = $workspaceRoot
    if ($resolved.PSObject.Properties['pathBase']) {
        if ($resolved.pathBase -eq 'desktop') {
            $baseRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
            if ([string]::IsNullOrWhiteSpace($baseRoot)) { throw 'Windows DesktopDirectory is unavailable.' }
        } elseif ($resolved.pathBase -ne 'workspace') { throw 'Unsupported delivery pathBase.' }
    }
    foreach ($name in @('humanCabinet', 'incomingRoot')) {
        $property = $resolved.PSObject.Properties[$name]
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw "Teacher harness config requires a non-empty '$name'."
        }
        $path = [string]$property.Value
        if (-not [IO.Path]::IsPathRooted($path)) {
            $property.Value = [IO.Path]::GetFullPath((Join-Path $baseRoot $path))
        }
    }
    # openTargetManifest is interpreted by its own consumer; retain that value.
    return $resolved
}

function Read-TeacherHarnessConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Workspace,
        [string]$ConfigPath = '.agent/index/delivery-system.json'
    )

    $workspaceRoot = [IO.Path]::GetFullPath($Workspace)
    $path = $ConfigPath
    if (-not [IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $workspaceRoot $path
    }
    $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json
    return Resolve-TeacherHarnessConfig -Workspace $workspaceRoot -Config $config
}
