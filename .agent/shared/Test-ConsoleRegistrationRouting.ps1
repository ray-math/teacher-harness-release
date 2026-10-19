[CmdletBinding()]
param([string]$ReceiptPath='')
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture=Join-Path $workspace ('.agent\cache\reg-'+[guid]::NewGuid().ToString('N').Substring(0,8))
try {
    $shared=Join-Path $fixture '.agent\shared';$index=Join-Path $fixture '.agent\index';$cabinet=Join-Path $fixture 'cabinet'
    $installed=Join-Path $cabinet '.agent\shared'
    foreach($p in @($shared,$index,$installed)){[void][IO.Directory]::CreateDirectory($p)}
    $registration=Join-Path $shared 'Register-HumanWorkOpenProtocol.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Register-HumanWorkOpenProtocol.ps1') -Destination $registration
    @{humanCabinet=$cabinet;openProtocol='hwpx-work-open'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $index 'delivery-system.json') -Encoding utf8
    [void][IO.Directory]::CreateDirectory((Join-Path $cabinet '.agent\index'))
    Copy-Item -LiteralPath (Join-Path $index 'delivery-system.json') -Destination (Join-Path $cabinet '.agent\index\delivery-system.json')
    $stub=@'
param()
@{ok=$true;route='installed';path=$PSCommandPath;registryChanged=$false}|ConvertTo-Json
'@
    Set-Content -LiteralPath (Join-Path $installed 'Register-HumanWorkOpenProtocol.ps1') -Value $stub -Encoding utf8
    $first=(& $registration)|ConvertFrom-Json
    if($first.route -ne 'installed' -or $first.path -ine (Join-Path $installed 'Register-HumanWorkOpenProtocol.ps1')){throw 'Workspace registration did not delegate to cabinet'}
    Remove-Item -LiteralPath (Join-Path $installed 'Register-HumanWorkOpenProtocol.ps1')
    $bootstrap=@'
param()
@{ok=$true;route='bootstrap';registryChanged=$false}|ConvertTo-Json
'@
    Set-Content -LiteralPath (Join-Path $shared 'Install-PortableCabinet.ps1') -Value $bootstrap -Encoding utf8
    $second=(& $registration)|ConvertFrom-Json
    if($second.route -ne 'bootstrap'){throw 'Missing installation registered workspace instead of bootstrapping cabinet'}
    Set-Content -LiteralPath (Join-Path $installed 'Register-HumanWorkOpenProtocol.ps1') -Value $stub -Encoding utf8
    @{humanCabinet=(Join-Path $fixture 'old-cabinet');openProtocol='hwpx-work-open'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $cabinet '.agent\index\delivery-system.json') -Encoding utf8
    $moved=(& $registration)|ConvertFrom-Json
    if($moved.route -ne 'bootstrap'){throw 'Moved cabinet configuration was not repaired before delegation'}
    # Exercise only the audit's runtime-selection block; the broad school-file audit
    # is unrelated to this repair and must not open school files for this test.
    $audit=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-HwpxWorkspace.ps1') -Raw -Encoding utf8
    $selection=[regex]::Match($audit,'(?s)\$consoleConfig =.*?(?=if \(-not \(Test-Path -LiteralPath \$launcher)').Value
    if(-not $selection){throw 'Audit runtime selection block missing'}
    $deliveryConfigPath=Join-Path $index 'delivery-system.json'
    . ([scriptblock]::Create($selection))
    if($launcher -ine (Join-Path $cabinet '.agent\shared\bin\HumanWorkOpenLauncher.exe') -or $openManifestPath -ine (Join-Path $cabinet '.agent\index\human-open-targets.json')){throw 'Audit still expects workspace instead of cabinet'}
    $report=@{ok=$true;checks=4;registryChanged=$false;mode='isolated registration delegation and actual audit path selection'}|ConvertTo-Json
    if($ReceiptPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReceiptPath),$report,[Text.UTF8Encoding]::new($true))}
    $report
}finally{
    $safe=[IO.Path]::GetFullPath($fixture)
    if([IO.Path]::GetDirectoryName($safe) -ine (Join-Path $workspace '.agent\cache') -or [IO.Path]::GetFileName($safe) -notlike 'reg-*'){throw 'Unsafe fixture cleanup'}
    if(Test-Path -LiteralPath $safe){Remove-Item -LiteralPath $safe -Recurse -Force}
}
