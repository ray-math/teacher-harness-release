$ErrorActionPreference='Stop'
Import-Module ScheduledTasks
$name='HwpxWorkspace-OfficialModule-'+[guid]::NewGuid().ToString('N')
$script=Join-Path $PSScriptRoot 'Install-DesktopModule.ps1'
$action=New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$script+'"')
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$task=New-ScheduledTask -Action $action -Principal $principal
try {
    Register-ScheduledTask -TaskName $name -InputObject $task | Out-Null
    Start-ScheduledTask -TaskName $name
    Start-Sleep -Seconds 5
    $state=Get-ScheduledTask -TaskName $name
    if($state.State -eq 'Running'){throw "Installer still running: $name"}
    Get-ScheduledTaskInfo -TaskName $name | Select-Object LastTaskResult
} finally { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
