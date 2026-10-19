[CmdletBinding()]
param([string]$ReceiptPath)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
# Fixtures must have visible ancestors: the workspace .agent is intentionally hidden.
$fixture = Join-Path $workspace ('native-safety-fixture-' + [guid]::NewGuid().ToString('N'))
$results = New-Object 'System.Collections.Generic.List[object]'
$junction = $null
function Invoke-Validation([string]$Name, [string]$Path, [int]$Expected, [string]$Action = 'open') {
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Path)).TrimEnd('=').Replace('+','-').Replace('/','_')
    $uri = $scheme + ':' + $Action + '/' + $payload
    if ($Action -eq 'refresh') { $uri += '/0123456789abcdef0123456789abcdef' }
    $process = Start-Process -FilePath $launcher -ArgumentList @('--validate', $uri, ('"' + $manifestPath + '"')) -WindowStyle Hidden -Wait -PassThru
    $results.Add([pscustomobject]@{case=$Name;expected=$Expected;actual=$process.ExitCode;ok=($process.ExitCode -eq $Expected)})
}
try {
    & (Join-Path $PSScriptRoot 'Register-HumanWorkOpenProtocol.ps1') -BuildOnly | Out-Null
    $launcher = Join-Path $PSScriptRoot 'bin\HumanWorkOpenLauncher.exe'
    $scheme = (Get-Content -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') -Raw -Encoding utf8 | ConvertFrom-Json).openProtocol
    $work = Join-Path $fixture 'work'
    $nested = Join-Path $work 'support\nested'
    $internal = Join-Path $work '.ai'
    $actual = Join-Path $fixture 'actual'
    foreach ($dir in @($nested,$internal,$actual)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $plain = Join-Path $nested 'ordinary.txt'
    $private = Join-Path $internal 'internal.txt'
    $external = Join-Path $actual 'linked.txt'
    $executable = Join-Path $work 'blocked.exe'
    foreach ($path in @($plain,$private,$external,$executable)) { [IO.File]::WriteAllText($path,'Synthetic test data.') }
    $junction = Join-Path $work 'linked'
    New-Item -ItemType Junction -Path $junction -Target $actual | Out-Null
    $linked = Join-Path $junction 'linked.txt'
    $missing = Join-Path $work 'missing.txt'
    $manifestPath = Join-Path $fixture 'manifest.json'
    @{workFolders=@(@{workFolder=$work;targets=@($plain,$private,$linked,$missing,$executable)})} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    Invoke-Validation 'ordinary registered file' $plain 0
    Invoke-Validation 'ordinary registered refresh' $work 0 'refresh'
    Invoke-Validation 'unregistered file' $external 7
    Invoke-Validation 'missing registered file' $missing 6
    Invoke-Validation 'executable registered file' $executable 6
    Invoke-Validation 'internal metadata path' $private 6
    Invoke-Validation 'junction ancestor' $linked 6
    foreach ($flag in @([IO.FileAttributes]::Hidden,[IO.FileAttributes]::System)) {
        $before = [IO.File]::GetAttributes($plain)
        try {
            [IO.File]::SetAttributes($plain,($before -bor $flag))
            Invoke-Validation ('file became ' + $flag) $plain 6
        } finally { [IO.File]::SetAttributes($plain,$before) }
        $ancestor = Split-Path $nested -Parent
        $before = [IO.File]::GetAttributes($ancestor)
        try {
            [IO.File]::SetAttributes($ancestor,($before -bor $flag))
            Invoke-Validation ('ancestor became ' + $flag) $plain 6
        } finally { [IO.File]::SetAttributes($ancestor,$before) }
    }
    Invoke-Validation 'restored ordinary file' $plain 0
    $before = [IO.File]::GetAttributes($fixture)
    try {
        [IO.File]::SetAttributes($fixture,($before -bor [IO.FileAttributes]::Hidden))
        Invoke-Validation 'unrelated hidden container above work boundary' $plain 0
    } finally { [IO.File]::SetAttributes($fixture,$before) }
    Invoke-Validation 'refresh remains registered' $work 0 'refresh'
    $failed = @($results | Where-Object { -not $_.ok })
    $receipt = [ordered]@{ok=($failed.Count -eq 0);mode='native --validate only';cases=@($results.ToArray());documentOpened=$false;registryChanged=$false;fixture=$fixture}
    $json = $receipt | ConvertTo-Json -Depth 6
    if ($ReceiptPath) { $json | Set-Content -LiteralPath $ReceiptPath -Encoding utf8 }
    $json
    if ($failed.Count) { throw ('Native safety validation failed: ' + (($failed | ForEach-Object {$_.case}) -join ', ')) }
} finally {
    # Delete the link itself first; never recursively traverse a junction.
    if ($junction -and [IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction) }
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith($workspace + '\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'native-safety-fixture-*') { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
