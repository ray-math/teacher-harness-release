$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') -Force
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Management\Microsoft.PowerShell.Management.psd1') -Force
$receipt=Join-Path $PSScriptRoot 'desktop-install.json'
$state=[ordered]@{ok=$false; registered=$false; error=$null; previousValue=$null}
$h=$null
try {
    $dll=Join-Path $env:LOCALAPPDATA 'HwpxWorkspace\Hancom\FilePathCheckerModuleExample.dll'
    $source=Join-Path $PSScriptRoot 'FilePathCheckerModuleExample.dll'
    if ((Get-FileHash -LiteralPath $source).Hash -ne '9AC5B97C47AC8AED1E8BCA27A3EEF39411361D8F68C262509F0C40A8F9D21BB6') { throw 'Source module hash mismatch' }
    if (Test-Path -LiteralPath $dll) {
        if ((Get-FileHash -LiteralPath $dll).Hash -ne (Get-FileHash -LiteralPath $source).Hash) { throw 'Existing installation differs' }
    } else {
        New-Item -ItemType Directory -Path (Split-Path -Parent $dll) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $dll
    }
    if ((Get-FileHash -LiteralPath $dll).Hash -ne '9AC5B97C47AC8AED1E8BCA27A3EEF39411361D8F68C262509F0C40A8F9D21BB6') { throw 'Module hash mismatch' }
    $key='HKCU:\Software\HNC\HwpAutomation\Modules'
    if (Test-Path $key) { $state.previousValue=(Get-Item $key).GetValue('HwpxWorkspaceOfficial',$null) }
    if ($state.previousValue -and $state.previousValue -ne $dll) { throw 'Existing registration differs' }
    New-Item $key -Force | Out-Null
    New-ItemProperty $key -Name HwpxWorkspaceOfficial -Value $dll -PropertyType String -Force | Out-Null
    $h=New-Object -ComObject HWPFrame.HwpObject
    $state.registered=[bool]$h.RegisterModule('FilePathCheckDLL','HwpxWorkspaceOfficial')
    $state.ok=$state.registered
} catch { $state.error=$_.Exception.Message }
finally { if($h){$h.Quit()}; $state | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8 }
