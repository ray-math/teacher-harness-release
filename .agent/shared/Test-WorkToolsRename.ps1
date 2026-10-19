[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Run with Windows PowerShell 5.1.'}
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$runtime=(& (Join-Path $PSScriptRoot 'Get-HwpxRuntime.ps1')).Python
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('work-tools-rename-test-'+[guid]::NewGuid().ToString('N'))
$passed=0
function Check([bool]$Value,[string]$Name){if(-not $Value){throw $Name};$script:passed++}
function Fail([scriptblock]$Action){try{& $Action | Out-Null}catch{return $true};return $false}
function Make-Tool([string]$Root,[switch]$Broken){
 $shared=Join-Path $Root '.agent\shared';$rt=Join-Path $Root '.agent\cache\test-runtime'
 foreach($dir in @($shared,(Join-Path $Root '.agent\index'),(Join-Path $rt 'Scripts'),(Join-Path $rt 'Lib\site-packages\hwpx_automation'))){[void][IO.Directory]::CreateDirectory($dir)}
 foreach($name in @('WorkStorage.ps1','Rename-WorkTools.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared}
 Copy-Item -LiteralPath $runtime -Destination (Join-Path $rt 'Scripts\python.exe')
 Copy-Item -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($runtime))) 'pyvenv.cfg') -Destination $rt
 [IO.File]::WriteAllText((Join-Path $rt 'Lib\site-packages\hwpx.py'),$(if($Broken){'raise RuntimeError("synthetic failure")'}else{''}))
 [IO.File]::WriteAllText((Join-Path $rt 'Lib\site-packages\hwpx_automation\mcp_cli.py'),'')
 @{runtimeDirectory='.agent\cache\test-runtime'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Root '.agent\index\hwpx-runtime.json') -Encoding utf8
 [IO.File]::WriteAllText((Join-Path $Root 'keep.txt'),'preserve exact content')
 $Root
}
function Config([string]$Root,[string]$Path){
 $lines=@("title = 'unchanged'",'[mcp_servers.hwpx]',("command = '"+(Join-Path $Root '.agent\cache\test-runtime\Scripts\hwpx-automation-mcp.exe')+"'"),("args = ['--workspace-root', '"+$Root+"', '--workspace-root', 'D:\SelectedCabinet']"),'startup_timeout_sec = 90',("[projects.'"+$Root+"']"),"trust_level = 'trusted'","[projects.'D:\OtherProject']","trust_level = 'untrusted'")
 [IO.File]::WriteAllText($Path,($lines -join [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}
try{
 [void][IO.Directory]::CreateDirectory($fixture)
 $root=Make-Tool (Join-Path $fixture 'old-tools');$cfg=Join-Path $fixture 'codex.toml';Config $root $cfg
 $rename=Join-Path $root '.agent\shared\Rename-WorkTools.ps1';$before=(Get-FileHash $cfg).Hash
 $preview=(& $rename -NewName 'new-tools' -CodexConfigPath $cfg)|ConvertFrom-Json
 Check (-not $preview.applied -and (Test-Path -LiteralPath $root) -and (Get-FileHash $cfg).Hash -eq $before) 'Planning changed files'
 Check (@($preview.configurationFields).Count -eq 3) 'Expected exact MCP/project fields'
 Check (Fail {& $rename -NewName '..\outside' -CodexConfigPath $cfg -Apply}) 'Traversal accepted'
 Check (Fail {& $rename -NewName 'NUL' -CodexConfigPath $cfg -Apply}) 'Windows device name accepted'
 [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'occupied'))
 Check (Fail {& $rename -NewName 'occupied' -CodexConfigPath $cfg -Apply}) 'Existing destination accepted'
 $result=(& $rename -NewName 'new-tools' -CodexConfigPath $cfg -Apply)|ConvertFrom-Json
 $newRoot=Join-Path $fixture 'new-tools'
 Check ($result.applied -and -not (Test-Path -LiteralPath $root) -and (Test-Path -LiteralPath $newRoot)) 'Tool folder was not renamed'
 Check ([IO.File]::ReadAllText((Join-Path $newRoot 'keep.txt')) -ceq 'preserve exact content') 'Tool content changed'
 Check ((Get-FileHash -LiteralPath (Join-Path $result.backupFolder 'config-before.toml')).Hash -eq $before) 'Original settings backup differs'
 $inspection=@'
from pathlib import Path
import json,sys,tomllib
p,root=map(Path,sys.argv[1:])
d=tomllib.loads(p.read_text(encoding='utf-8-sig'))
m=d['mcp_servers']['hwpx']
print(json.dumps({'module':m['args'][:3]==['-B','-m','hwpx_automation.mcp_cli'],'command':m['command']==str(root/'.agent/cache/test-runtime/Scripts/python.exe'),'root':m['args'][4]==str(root),'external':m['args'][-1]==r'D:\SelectedCabinet','other':d['projects'][r'D:\OtherProject']['trust_level']=='untrusted' and d['title']=='unchanged' and m['startup_timeout_sec']==90,'trust':d['projects'][str(root)]['trust_level']=='trusted'}))
'@
 $inspectPath=Join-Path $fixture 'inspect.py';[IO.File]::WriteAllText($inspectPath,$inspection)
 $checked=(& $runtime -B $inspectPath $cfg $newRoot)|ConvertFrom-Json
 foreach($name in @('module','command','root','external','other','trust')){Check ([bool]$checked.$name) ('Relocated setting failed: '+$name)}
 $dynamic=Make-Tool (Join-Path $fixture 'dynamic-tools');$dynamicCfg=Join-Path $fixture 'dynamic.toml';Config $dynamic $dynamicCfg
 $dynamicText=[IO.File]::ReadAllText($dynamicCfg)
 $dynamicText=$dynamicText.Replace("args = ['--workspace-root', '"+$dynamic+"', '--workspace-root', 'D:\SelectedCabinet']", "args = ['-B', '"+(Join-Path $dynamic '.agent\shared\hwpx_mcp_launch.py')+"']")
 [IO.File]::WriteAllText($dynamicCfg,$dynamicText)
 $dynamicResult=(& (Join-Path $dynamic '.agent\shared\Rename-WorkTools.ps1') -NewName 'moved-dynamic-tools' -CodexConfigPath $dynamicCfg -Apply)|ConvertFrom-Json
 $dynamicMoved=Join-Path $fixture 'moved-dynamic-tools'
 Check ($dynamicResult.applied) 'Dynamic launcher rename failed'
 $dynamicConfig=[IO.File]::ReadAllText($dynamicCfg)
 Check ($dynamicConfig.Contains(('args = ["-B", '+(('"'+(Join-Path $dynamicMoved '.agent\shared\hwpx_mcp_launch.py').Replace('\','\\')+'"'))+']'))) 'Dynamic launcher argument was not relocated'
 $bad=Make-Tool (Join-Path $fixture 'bad-tools') -Broken;$badCfg=Join-Path $fixture 'bad.toml';Config $bad $badCfg;$badHash=(Get-FileHash $badCfg).Hash
 Check (Fail {& (Join-Path $bad '.agent\shared\Rename-WorkTools.ps1') -NewName 'failed-tools' -CodexConfigPath $badCfg -Apply 2>$null}) 'Broken runtime did not fail'
 Check ((Test-Path -LiteralPath $bad) -and -not (Test-Path -LiteralPath (Join-Path $fixture 'failed-tools')) -and (Get-FileHash $badCfg).Hash -eq $badHash) 'Failed runtime did not roll back folder/settings'
 $other=Make-Tool (Join-Path $fixture 'bad-config-tools');$parse=Join-Path $fixture 'invalid.toml';[IO.File]::WriteAllText($parse,'broken = [')
 Check (Fail {& (Join-Path $other '.agent\shared\Rename-WorkTools.ps1') -NewName 'ignored' -CodexConfigPath $parse -Apply 2>$null}) 'Invalid config did not fail'
 Check ((Test-Path -LiteralPath $other) -and -not (Test-Path -LiteralPath (Join-Path $fixture 'ignored'))) 'Config preflight failure renamed folder'
 @{ok=$true;passed=$passed;syntheticOnly=$true}|ConvertTo-Json
}finally{
 Set-Location -LiteralPath $workspace
 $full=[IO.Path]::GetFullPath($fixture)
 if([IO.Path]::GetDirectoryName($full)-ine[IO.Path]::GetTempPath().TrimEnd('\')-or[IO.Path]::GetFileName($full)-notmatch'^work-tools-rename-test-[a-f0-9]{32}$'){throw 'Unsafe fixture cleanup'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
