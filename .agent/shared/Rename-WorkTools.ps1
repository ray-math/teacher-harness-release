[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$NewName,
    [string]$CodexConfigPath=(Join-Path $env:USERPROFILE '.codex\config.toml'),
    [switch]$Apply
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$oldRoot=(Assert-WorkStoragePath (Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$parent=[IO.Path]::GetDirectoryName($oldRoot)
if ([string]::IsNullOrWhiteSpace($NewName) -or $NewName -in @('.','..') -or $NewName -match '[\x00-\x1f\\/<>:"|?*]' -or $NewName.TrimEnd(' ','.') -ne $NewName -or $NewName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw 'Choose a safe folder name, without a path.' }
$newRoot=Assert-WorkStoragePath (Join-Path $parent $NewName)
if ([IO.Path]::GetDirectoryName($newRoot) -ine $parent -or $newRoot -ieq $oldRoot) { throw 'Choose a different folder name in the same parent directory.' }
if (Test-Path -LiteralPath $newRoot) { throw 'The destination already exists; no folders will be merged.' }
$configPath=Assert-WorkStoragePath $CodexConfigPath
$spec=Get-Content -LiteralPath (Join-Path $oldRoot '.agent\index\hwpx-runtime.json') -Raw -Encoding utf8 | ConvertFrom-Json
$runtime=Assert-WorkStoragePath (Join-Path $oldRoot ([string]$spec.runtimeDirectory))
if (-not $runtime.StartsWith($oldRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Runtime must be inside the selected tool folder.' }
$python=Join-Path $runtime 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'The verified Python runtime is missing.' }
$stage=Join-Path ([IO.Path]::GetTempPath()) ('work-tools-rename-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stage)
$transform=@"
from pathlib import Path
import copy, hashlib, json, re, sys, tomllib
old,new,p,stage,runtime=map(Path,sys.argv[1:6])
raw=p.read_bytes() if p.is_file() else None
changed=raw
fields=[]
if raw is not None:
 s=raw.decode('utf-8-sig');d=tomllib.loads(s);expected=copy.deepcopy(d)
 m=d.get('mcp_servers',{}).get('hwpx')
 if m and str(m.get('command','')).lower().startswith(str(old).lower()+'\\'):
  known=[str(runtime/'Scripts/python.exe').lower(),str(runtime/'Scripts/hwpx-automation-mcp.exe').lower()]
  if str(m['command']).lower() not in known:raise SystemExit('Unrecognized workspace MCP command; no changes.')
  oldargs=m.get('args',[])
  launcher=old/'.agent/shared/hwpx_mcp_launch.py'
  if len(oldargs)==2 and oldargs[0]=='-B' and oldargs[1].lower()==str(launcher).lower():
   args=['-B',str(new/'.agent/shared/hwpx_mcp_launch.py')]
  else:
   args=[str(new) if x.lower()==str(old).lower() else x for x in oldargs]
   prefix=['-B','-m','hwpx_automation.mcp_cli']
   if args[:3]!=prefix:
    if args and args[0]!='--workspace-root':raise SystemExit('Unrecognized MCP arguments; no changes.')
    args=prefix+args
  command=str(new/runtime.relative_to(old)/'Scripts/python.exe')
  match=re.search(r'(?ms)^\[mcp_servers\.hwpx\][^\S\r\n]*\r?\n.*?(?=^\[|\Z)',s)
  if not match:raise SystemExit('MCP section missing.')
  block=match.group()
  block,n1=re.subn(r'(?m)^command\s*=[^\r\n]*',lambda _: 'command = '+json.dumps(command,ensure_ascii=False),block)
  block,n2=re.subn(r'(?ms)^args[^\S\r\n]*=[^\S\r\n]*\[.*?\]',lambda _: 'args = '+json.dumps(args,ensure_ascii=False),block)
  if (n1,n2)!=(1,1):raise SystemExit('Unrecognized MCP section shape.')
  s=s[:match.start()]+block+s[match.end():]
  expected['mcp_servers']['hwpx'].update(command=command,args=args)
  fields+=['mcp_servers.hwpx.command','mcp_servers.hwpx.args']
 for key in [k for k in d.get('projects',{}) if k.lower()==str(old).lower()]:
  target=str(new)
  if any(k.lower()==target.lower() for k in expected['projects']):raise SystemExit('Destination project registration exists.')
  options=["[projects.'"+key+"']",'[projects.'+json.dumps(key,ensure_ascii=False)+']']
  found=[x for x in options if x in s]
  if len(found)!=1:raise SystemExit('Unrecognized project header.')
  s=s.replace(found[0],'[projects.'+json.dumps(target,ensure_ascii=False)+']',1)
  expected['projects'][target]=expected['projects'].pop(key)
  fields+=['projects.path']
 if tomllib.loads(s)!=expected:raise SystemExit('Unrelated settings would change.')
 changed=(b'\xef\xbb\xbf' if raw.startswith(b'\xef\xbb\xbf') else b'')+s.encode('utf-8')
 if fields:
  (stage/'config-before.toml').write_bytes(raw)
  (stage/'config-after.toml').write_bytes(changed)
print(json.dumps({'fields':fields,'beforeSha256':hashlib.sha256(raw).hexdigest() if raw is not None else None,'afterSha256':hashlib.sha256(changed).hexdigest() if changed is not None else None}))
"@
$transformPath=Join-Path $stage 'prepare.py'
[IO.File]::WriteAllText($transformPath,$transform,[Text.UTF8Encoding]::new($false))
$priorEncoding=$env:PYTHONUTF8;$priorBytecode=$env:PYTHONDONTWRITEBYTECODE
$renamed=$false;$configWritten=$false
try {
    $env:PYTHONUTF8='1';$env:PYTHONDONTWRITEBYTECODE='1'
    $preparedText=(& $python -B $transformPath $oldRoot $newRoot $configPath $stage $runtime | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Configuration preflight failed; the folder is unchanged.' }
    $prepared=$preparedText | ConvertFrom-Json
    if (-not $Apply) {
        @{ok=$true;applied=$false;oldRoot=$oldRoot;newRoot=$newRoot;configurationFields=@($prepared.fields);note='Close applications using the folder, then repeat with -Apply.'}|ConvertTo-Json -Depth 4
        return
    }
    # Verify exact roots before the single same-parent directory rename. No child
    # paths are enumerated, copied or deleted; embedded links are not followed.
    [void](Assert-WorkStoragePath $oldRoot);[void](Assert-WorkStoragePath $newRoot)
    if (@($prepared.fields).Count -and (Get-FileHash -LiteralPath $configPath).Hash -ine $prepared.beforeSha256) { throw 'Codex settings changed during preparation; retry.' }
    Set-Location -LiteralPath $parent
    Rename-Item -LiteralPath $oldRoot -NewName $NewName -ErrorAction Stop
    $renamed=$true
    $movedPython=Join-Path $newRoot ($python.Substring($oldRoot.Length+1))
    & $movedPython -B -c 'import hwpx, hwpx_automation.mcp_cli' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The relocated runtime failed verification.' }
    if (@($prepared.fields).Count) {
        if ((Get-FileHash -LiteralPath $configPath).Hash -ine $prepared.beforeSha256) { throw 'Codex settings changed before replacement; retry.' }
        $tempConfig=Join-Path ([IO.Path]::GetDirectoryName($configPath)) ('.rename-'+[guid]::NewGuid().ToString('N')+'.tmp')
        try {
            [IO.File]::WriteAllBytes($tempConfig,[IO.File]::ReadAllBytes((Join-Path $stage 'config-after.toml')))
            [IO.File]::Replace($tempConfig,$configPath,[NullString]::Value)
            $configWritten=$true
        } finally {if(Test-Path -LiteralPath $tempConfig){Remove-Item -LiteralPath $tempConfig -Force}}
        if ((Get-FileHash -LiteralPath $configPath).Hash -ine $prepared.afterSha256) { throw 'Codex configuration verification failed.' }
    }
    @{ok=$true;applied=$true;newRoot=$newRoot;configurationFields=@($prepared.fields);backupFolder=$stage;note='Open the renamed folder as a Codex project. Restart Codex to load its MCP path.'}|ConvertTo-Json -Depth 4
} catch {
    $failure=$_
    if ($configWritten) {
        if ((Get-FileHash -LiteralPath $configPath).Hash -ine $prepared.afterSha256) { throw 'Concurrent settings change prevents automatic rollback. Inspect the rename backup.' }
        [IO.File]::WriteAllBytes($configPath,[IO.File]::ReadAllBytes((Join-Path $stage 'config-before.toml')))
    }
    if ($renamed) { Rename-Item -LiteralPath $newRoot -NewName ([IO.Path]::GetFileName($oldRoot)) -ErrorAction Stop }
    throw $failure
} finally {
    $env:PYTHONUTF8=$priorEncoding;$env:PYTHONDONTWRITEBYTECODE=$priorBytecode
    if (-not $renamed) {
        $safe=Assert-WorkStoragePath $stage
        if ([IO.Path]::GetDirectoryName($safe) -ine [IO.Path]::GetTempPath().TrimEnd('\') -or [IO.Path]::GetFileName($safe) -notmatch '^work-tools-rename-[a-f0-9]{32}$') { throw 'Unsafe staging cleanup path.' }
        foreach ($leaf in @('prepare.py','config-before.toml','config-after.toml')) { $path=Join-Path $safe $leaf;if(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path -Force} }
        [IO.Directory]::Delete($safe,$false)
    }
}
