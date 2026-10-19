[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$InputFile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$JobPath,

    [string]$ConverterPath = '',
    [ValidateRange(10, 1800)]
    [int]$TimeoutSeconds = 180,
    [switch]$PlanOnly
)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$jobInfo = Get-WorkJobInfo -Workspace $workspace -Path $JobPath -RequireJobRoot -RequireExists
$resolvedJob = $jobInfo.jobRoot

function Get-OfficialConverter([string]$ExplicitPath) {
    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidates.Add([IO.Path]::GetFullPath((Resolve-Path -LiteralPath $ExplicitPath).Path))
    }

    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        foreach ($relative in @(
            'Hnc\HwpxConverter\HwpConverter.exe',
            'Hnc\HwpxConverter\HwpxConverter.exe',
            'Hnc\HwpConverter\HwpConverter.exe',
            'Hnc\HwpConverter\HwpxConverter.exe',
            'Programs\HwpxConverter\HwpConverter.exe',
            'Programs\HwpxConverter\HwpxConverter.exe',
            'Programs\HwpConverter\HwpConverter.exe',
            'Programs\HwpConverter\HwpxConverter.exe'
        )) {
            $candidate = Join-Path $base $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidates.Add([IO.Path]::GetFullPath($candidate)) }
        }
    }

    foreach ($registryRoot in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        if (-not (Test-Path -LiteralPath $registryRoot)) { continue }
        foreach ($entry in @(Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue)) {
            $property = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction SilentlyContinue
            if ([string]$property.DisplayName -notmatch '(?i)HWPX.*(Converter|변환)|(?:Converter|변환).*HWPX') { continue }
            if ([string]::IsNullOrWhiteSpace([string]$property.InstallLocation)) { continue }
            foreach ($name in @('HwpConverter.exe','HwpxConverter.exe')) {
                $candidate = Join-Path ([string]$property.InstallLocation) $name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidates.Add([IO.Path]::GetFullPath($candidate)) }
            }
        }
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $parentName = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($candidate))
        $isBundledOfficeBinary = $candidate -match '(?i)\\HOffice\d*\\Bin\\'
        $isOfficialPackageLayout = $parentName -match '(?i)^Hwpx?Converter$'
        if ($isBundledOfficeBinary) { continue }
        if (-not $isOfficialPackageLayout -or [IO.Path]::GetFileName($candidate) -notin @('HwpConverter.exe','HwpxConverter.exe')) { continue }
        $version = (Get-Item -LiteralPath $candidate).VersionInfo
        $signature = Get-AuthenticodeSignature -LiteralPath $candidate
        if ($signature.Status -ne 'Valid' -or [string]$signature.SignerCertificate.Subject -notmatch '(?i)Hancom|HAN(?:GUL)?\s*(?:AND|&)\s*COMPUTER' -or
            ([string]$version.CompanyName + ' ' + [string]$version.ProductName) -notmatch '(?i)Hancom|Hnc|한글과컴퓨터') { continue }
        return $candidate
    }
    return $null
}

function Get-UniqueOutputPath([string]$Root, [string]$SourcePath, [string]$Hash, [Collections.Generic.HashSet[string]]$Reserved) {
    $baseName = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
    $candidate = Join-Path $Root ($baseName + '.hwpx')
    if ($Reserved.Add($candidate)) { return $candidate }
    $candidate = Join-Path $Root ($baseName + '__' + $Hash.Substring(0, 8).ToLowerInvariant() + '.hwpx')
    if (-not $Reserved.Add($candidate)) { throw "Duplicate canonical output path: $candidate" }
    return $candidate
}

function Test-HwpxPackage([string]$Path) {
    & (Join-Path $PSScriptRoot 'Test-HwpxPackageIntegrity.ps1') -Path $Path | Out-Null
}

function Invoke-OfficialConversion([string]$Executable, [string]$Source, [string]$Destination, [int]$Timeout) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # Windows PowerShell 5.1/.NET Framework has no ProcessStartInfo.ArgumentList.
    # Both arguments are resolved file paths (no quotes or trailing directory slash).
    if ($Source.Contains('"') -or $Destination.Contains('"')) { throw 'Invalid quote in conversion file path.' }
    $startInfo.Arguments = '"' + $Source + '" "' + $Destination + '"'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'The official HWPX converter did not start.' }
        if (-not $process.WaitForExit($Timeout * 1000)) {
            try { $process.Kill() } catch {}
            throw "The official HWPX converter exceeded the ${Timeout}-second timeout."
        }
        $stdout = $process.StandardOutput.ReadToEnd().Trim()
        $stderr = $process.StandardError.ReadToEnd().Trim()
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            $detail = @($stderr, $stdout | Where-Object { $_ }) -join ' / '
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'no output file was created' }
            throw "HWP to HWPX conversion failed (exit $($process.ExitCode)): $detail"
        }
    } finally {
        $process.Dispose()
    }
}

$resolvedInputs = [Collections.Generic.List[object]]::new()
foreach ($input in @($InputFile | Where-Object { $_ })) {
    $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $input).Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "InputFile is not a file: $resolved" }
    $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
    if ($extension -notin @('.hwp','.hwpx','.hwtx')) { throw "Unsupported Hanword input type: $extension ($resolved)" }
    $resolvedInputs.Add([ordered]@{
        sourcePath = $resolved
        sourceExtension = $extension
        sourceSha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    })
}
if ($resolvedInputs.Count -eq 0) { throw 'At least one existing InputFile is required.' }

$converter = Get-OfficialConverter $ConverterPath
$outputRoot = Join-Path $resolvedJob 'wip\docs\normalized'
$reserved = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$items = [Collections.Generic.List[object]]::new()
foreach ($input in $resolvedInputs) {
    $outputPath = Get-UniqueOutputPath $outputRoot $input.sourcePath $input.sourceSha256 $reserved
    $action = switch ($input.sourceExtension) {
        '.hwpx' { 'copy_working_document' }
        '.hwp' { 'convert_legacy_document' }
        '.hwtx' { 'instantiate_template' }
    }
    $status = if ($PlanOnly) {
        'planned'
    } elseif ($input.sourceExtension -eq '.hwp' -and -not $converter) {
        'blocked_converter_not_installed'
    } elseif ($input.sourceExtension -eq '.hwtx') {
        'blocked_template_instantiator_required'
    } else {
        'pending'
    }
    $items.Add([ordered]@{
        sourcePath = $input.sourcePath
        sourceExtension = $input.sourceExtension
        sourceSha256 = $input.sourceSha256
        sourceRole = $(if ($input.sourceExtension -eq '.hwtx') { 'template' } else { 'document' })
        action = $action
        canonicalFormat = '.hwpx'
        canonicalPath = $outputPath
        status = $status
        outputSha256 = $null
    })
}

$blocked = @($items | Where-Object status -like 'blocked_*')
if (-not $PlanOnly -and $blocked.Count -eq 0) {
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    foreach ($item in $items) {
        if ($item.sourceExtension -eq '.hwpx') {
            Copy-Item -LiteralPath $item.sourcePath -Destination $item.canonicalPath
        } elseif ($item.sourceExtension -eq '.hwp') {
            Invoke-OfficialConversion -Executable $converter -Source $item.sourcePath -Destination $item.canonicalPath -Timeout $TimeoutSeconds
        }
        Test-HwpxPackage $item.canonicalPath
        $sourceHashAfter = (Get-FileHash -LiteralPath $item.sourcePath -Algorithm SHA256).Hash
        if ($sourceHashAfter -ne $item.sourceSha256) { throw "Source changed during normalization: $($item.sourcePath)" }
        $item.outputSha256 = (Get-FileHash -LiteralPath $item.canonicalPath -Algorithm SHA256).Hash
        $item.status = 'ready'
    }
}

$result = [ordered]@{
    schemaVersion = 'hwpx-input-normalization/v1'
    decidedAt = Get-Date -Format 'o'
    planOnly = [bool]$PlanOnly
    canonicalWorkingFormat = '.hwpx'
    policy = 'selected-inputs-only'
    sourceMutationAllowed = $false
    converter = $converter
    converterInstalled = [bool]$converter
    outputRoot = $outputRoot
    ok = ($blocked.Count -eq 0)
    items = @($items)
    guidance = $(if (@($items | Where-Object sourceExtension -eq '.hwtx').Count -gt 0) {
        'HWTX is a reusable template. Keep it as the authoritative source and instantiate a new HWPX working document through an approved Hancom path; never rename the extension.'
    } elseif (-not $converter -and @($items | Where-Object sourceExtension -eq '.hwp').Count -gt 0) {
        'Install Hancom HWPX Converter, then rerun. The similarly named executable under HOffice\\Bin is intentionally excluded.'
    } else { '' })
}
$receiptPath = Join-Path $resolvedJob 'wip\receipts\selected-input-normalization.json'
$result['receiptPath'] = $(if($PlanOnly){$null}else{$receiptPath})
if (-not $PlanOnly) {
    $receiptParent = [IO.Path]::GetDirectoryName($receiptPath)
    New-Item -ItemType Directory -Path $receiptParent -Force | Out-Null
    $temporaryReceipt = Join-Path $receiptParent ('.normalization-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryReceipt -Encoding utf8
        Move-Item -LiteralPath $temporaryReceipt -Destination $receiptPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryReceipt -PathType Leaf) { Remove-Item -LiteralPath $temporaryReceipt -Force -ErrorAction SilentlyContinue }
    }
}
$result | ConvertTo-Json -Depth 8
if (-not $PlanOnly -and $blocked.Count -gt 0) { exit 2 }
