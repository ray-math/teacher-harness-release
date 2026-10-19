[CmdletBinding()]
param([switch]$NoRegister)
$ErrorActionPreference='Stop'
# Compatibility entry point for cabinet runtime setup. Prior materials are selected
# per request; setup neither discovers nor copies them and creates no year folders.
& (Join-Path $PSScriptRoot 'Install-PortableCabinet.ps1') -NoRegister:$NoRegister