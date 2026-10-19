param()
$ErrorActionPreference='Stop'
$ws=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hwpx-portable-test-'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $fixture 'moved cabinet'
$shared=Join-Path $root '.agent\shared'
$index=Join-Path $root '.agent\index'
$work=Join-Path $root '23_Test'
$old=Join-Path $fixture 'unavailable cabinet'
New-Item -ItemType Directory -Path $shared,$index,(Join-Path $shared 'bin'),(Join-Path $work '.ai'),(Join-Path $root '이전자료\2025') -Force|Out-Null
$checks=0
function Check($ok,$label){if(-not $ok){throw $label};$script:checks++}
try{
 foreach($name in @('WorkStorage.ps1','Update-HumanWorkConsole.ps1','Initialize-PortableCabinet.ps1','Open-HumanWorkPath.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $shared}
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'bin\HumanWorkOpenLauncher.exe') -Destination (Join-Path $shared 'bin')
 $config=Get-Content (Join-Path $ws '.agent\index\delivery-system.json') -Raw -Encoding utf8|ConvertFrom-Json
 $config.humanCabinet=$old
 $config|ConvertTo-Json -Depth 12|Set-Content (Join-Path $index 'delivery-system.json') -Encoding utf8
 $file=Join-Path $work 'current.pdf'
 [IO.File]::WriteAllText($file,'test')
 $prior=Join-Path $root '이전자료\2025\reference.pdf'
 [IO.File]::WriteAllText($prior,'reference')
 @{title='Test';currentFiles=@('current.pdf');layout=@{supportFolders=@()}}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $work '.ai\work.json') -Encoding utf8
 @{sources=@(@{path=(Join-Path $old 'reference.pdf');sha256=(Get-FileHash $prior).Hash;role='reference';name='reference.pdf'})}|ConvertTo-Json -Depth 6|Set-Content (Join-Path $work '.ai\sources.json') -Encoding utf8
 @(@{path=(Join-Path $old 'reference.pdf');relativePath='이전자료\2025\reference.pdf';sha256=(Get-FileHash $prior).Hash})|ConvertTo-Json|Set-Content (Join-Path $index 'prior-materials.json') -Encoding utf8
 [IO.File]::WriteAllText((Join-Path $work '업무현황.html'),'previously requested console')
 & (Join-Path $shared 'Initialize-PortableCabinet.ps1') -NoRegister|Out-Null
 & (Join-Path $shared 'Initialize-PortableCabinet.ps1') -NoRegister|Out-Null
 $manifest=Get-Content (Join-Path $index 'human-open-targets.json') -Raw -Encoding utf8|ConvertFrom-Json
 Check ($manifest.workFolders.Count -eq 1) 'Only work registration after repeated initialization'
 foreach($entry in $manifest.workFolders){foreach($target in $entry.targets){
  Check ($target.StartsWith($root+'\') -and (Test-Path -LiteralPath $target)) 'Every target relocated inside the new cabinet'
  $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($target)).TrimEnd('=').Replace('+','-').Replace('/','_')
  $args=@('--validate',('hwpx-work-open://open/'+$payload))
  $p=Start-Process -FilePath (Join-Path $shared 'bin\HumanWorkOpenLauncher.exe') -ArgumentList $args -WindowStyle Hidden -Wait -PassThru
  Check ($p.ExitCode -eq 0) 'Native launcher accepts relocated link'
 }}
 $html=Get-Content (Join-Path $work '업무현황.html') -Raw -Encoding utf8
 Check ($html -notmatch '공유본에 없음|원본 위치에서 찾을 수 없음') 'Prior reference resolved locally'
 $base=[regex]::Match($html,'id="refresh-console" href="([^"]+)"').Groups[1].Value
 $nonce=[guid]::NewGuid().ToString('N')
 & (Join-Path $shared 'Open-HumanWorkPath.ps1') -Uri ($base+'/'+$nonce)|Out-Null
 Check ((Get-Content (Join-Path $work '.ai\console-refresh.js') -Raw).Contains($nonce)) 'Refresh works in copied runtime'
 Check (-not(Test-Path (Join-Path $root '업무현황.html'))) 'No root index'
 [pscustomobject]@{ok=$true;checks=$checks;fixture='synthetic relocated cabinet';registryChanged=$false}|ConvertTo-Json
}finally{
 if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($fixture)) -ine ([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')) -or [IO.Path]::GetFileName($fixture) -notmatch '^hwpx-portable-test-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
 if((Get-Item -LiteralPath $fixture -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Fixture root became a reparse point.'}
 Remove-Item -LiteralPath $fixture -Recurse -Force
}
