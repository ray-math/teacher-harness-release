[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1')
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$desktop=[Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
$config=[pscustomobject]@{pathBase='desktop';humanCabinet='TeacherWork';incomingRoot='Received'}
$resolved=Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
if ($resolved.humanCabinet -ine (Join-Path $desktop 'TeacherWork')) {throw 'Desktop base was not resolved'}
if ($resolved.incomingRoot -ine (Join-Path $desktop 'Received')) {throw 'Desktop incoming base was not resolved'}
if ($config.humanCabinet -cne 'TeacherWork') {throw 'Reading mutated the source config'}
$legacy=[pscustomobject]@{humanCabinet='../LegacyWork';incomingRoot='../LegacyReceived'}
$old=Resolve-TeacherHarnessConfig -Workspace $workspace -Config $legacy
if ($old.humanCabinet -ine [IO.Path]::GetFullPath((Join-Path $workspace '../LegacyWork'))) {throw 'Legacy base changed'}
$explicit=Join-Path ([IO.Path]::GetTempPath()) 'ExplicitWork'
$config.humanCabinet=$explicit
if ((Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config).humanCabinet -ine $explicit) {throw 'Explicit absolute path changed'}
$config.pathBase='unsupported'
$rejected=$false
try {Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config | Out-Null} catch {$rejected=$true}
if (-not $rejected) {throw 'Unsupported base accepted'}
[pscustomobject]@{ok=$true;count=6;desktop=$desktop;filesCreated=0} | ConvertTo-Json
