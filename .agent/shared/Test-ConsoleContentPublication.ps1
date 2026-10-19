[CmdletBinding()]
param([string]$ReceiptPath = '')
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Run with Windows PowerShell 5.1.' }
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture = Join-Path $workspace ('.agent\cache\cp-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$checks = [Collections.Generic.List[string]]::new()
function Check([bool]$Ok,[string]$Name) { if (-not $Ok) { throw "FAIL: $Name" }; $checks.Add($Name) }
function Json($Lines) { ($Lines -join [Environment]::NewLine) | ConvertFrom-Json }
function Save($Path,$Value) { $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Hash($Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Fails([scriptblock]$Action,[string]$Pattern,[string]$Name) {
    $failed=$false
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; $failed=$true }
    Check $failed $Name
}
function Without-Content($Value) {
    $clone = $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $clone.PSObject.Properties.Remove('consoleContent')
    $clone | ConvertTo-Json -Depth 100 -Compress
}
try {
    $shared=Join-Path $fixture '.agent\shared'; $index=Join-Path $fixture '.agent\index'
    $cabinet=Join-Path $fixture 'cabinet'; $folder='20260908_Console test'; $work=Join-Path $cabinet $folder
    $job=Join-Path $fixture '.agent\jobs\20260908-test'
    $maintenance=Join-Path $fixture '.agent\archive\2026\maintenance-test'
    foreach ($path in @($shared,$index,(Join-Path $work '.ai'),(Join-Path $work 'previous_versions'),(Join-Path $job 'wip\receipts'),$maintenance)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    foreach ($name in @('Publish-HumanResult.ps1','Publish-HumanConsoleContent.ps1','WorkStorage.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $shared $name) }
    $publisher=Join-Path $shared 'Publish-HumanResult.ps1'; $renderer=Join-Path $shared 'Update-HumanWorkConsole.ps1'
    $configPath=Join-Path $index 'delivery-system.json'; $registryPath=Join-Path $index 'human-current.json'
    $metadataPath=Join-Path $work '.ai\work.json'; $sourcesPath=Join-Path $work '.ai\sources.json'
    $htmlPath=Join-Path $work '업무현황.html'; $manifestPath=Join-Path $index 'human-open-targets.json'
    $target=Join-Path $work 'result.csv'; $retained=Join-Path $work 'retained.pdf'
    $contentPath=Join-Path $job 'wip\content.json'
    $config=[ordered]@{humanCabinet=$cabinet;metadataFolderName='.ai';workMetadataName='work.json';sourceMetadataName='sources.json';consoleFileName='업무현황.html';archiveFolderName='previous_versions';openTargetManifest='.agent\index\human-open-targets.json';openProtocol='hwpx-work-open';incomingRoot=$fixture}
    Save $configPath $config
    [IO.File]::WriteAllText($target,'original csv'); [IO.File]::WriteAllText($retained,'unrelated document')
    [IO.File]::WriteAllText($htmlPath,'original HTML')
    Save $manifestPath @{schemaVersion='test';workFolders=@(@{workFolder='other work';targets=@('other target')})}
    $entry=[ordered]@{title='Console test';folderName=$folder;createdDate='20260908';stage='Review';workState='ReviewPending';files=@('result.csv','retained.pdf');currentFileRecords=@()}
    $registry=[ordered]@{schemaVersion='hwpx-human-current/v4';works=@($entry)}
    Save $registryPath $registry
    $metadata=[ordered]@{title='Console test';stage='Review';status='검토 대기';currentFiles=@('result.csv','retained.pdf');currentFileRecords=@(@{name='retained.pdf';sha256=(Hash $retained);recordedAt='historical'});review=@{state='pending';question='Existing question'};workflow=@{steps=@(@{id='one';items=@();actions=@('one action')})};history=@();nextAction='Existing action';editing=@{mode='content_only';finalPolishAuthorized=$false};layout=@{supportFolders=@()};extensionData=@{empty=@();single=@(@{nested=@()})}}
    Save $metadataPath $metadata; Save $sourcesPath @{sources=@()}
    Save (Join-Path $job 'inputs.json') @{userProvidedSelectionRecorded=$true;sources=@(@{role='human_revision';path=$target;sha256=(Hash $target)})}
    $content=[ordered]@{schemaVersion='hwpx-console-content/v1';sections=@(@{id='analysis';title='분석';body="한글 본문`nSecond line <script>";references=@()})}
    Save $contentPath $content
    $argsConsole=@{WorkFolderName=$folder;ConsoleContentPath=$contentPath}
    $stub=@'
param([string]$WorkFolder,[string]$CabinetRoot)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$work=Get-Content -LiteralPath (Join-Path $WorkFolder '.ai\work.json') -Raw -Encoding utf8|ConvertFrom-Json
$output=Join-Path $WorkFolder '업무현황.html'
[IO.File]::WriteAllText($output, '<html>'+[Net.WebUtility]::HtmlEncode(($work.consoleContent|ConvertTo-Json -Depth 30))+'</html>')
[IO.File]::WriteAllText((Join-Path $root '.agent\index\human-open-targets.json'),'changed manifest')
$flag=Join-Path $root 'renderer-mode'
$mode=if(Test-Path -LiteralPath $flag){[IO.File]::ReadAllText($flag)}else{''}
if($mode -eq 'throw'){
    $entry=Join-Path $WorkFolder '문서 열기'
    New-Item -ItemType Directory -Path $entry -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $entry '문서 열기.lnk'),'synthetic shortcut')
    throw 'Injected renderer failure after outputs'
}
if($mode -eq 'invalid'){ 'not-json'; return }
if($mode -eq 'wrong'){ @{workFolder=$WorkFolder;output='wrong output'}|ConvertTo-Json; return }
if($mode -eq 'false'){ @{ok=$false;workFolder=$WorkFolder;output=$output}|ConvertTo-Json; return }
if($mode -eq 'receipt-lock'){
    $latest=Join-Path $root '.agent\jobs\20260908-test\wip\receipts\work-console-publish.json'
    $global:ConsolePublicationTestLock=[IO.File]::Open($latest,'Open','Read','Read')
}
@{schemaVersion='hwpx-human-console/v5';workFolder=$WorkFolder;output=$output}|ConvertTo-Json
'@
    Set-Content -LiteralPath $renderer -Value $stub -Encoding utf8
    $metadataBefore=Without-Content (Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8|ConvertFrom-Json)
    $registryHash=Hash $registryPath; $metaHash=Hash $metadataPath; $htmlHash=Hash $htmlPath; $manifestHash=Hash $manifestPath
    $plan=Json (& $publisher @argsConsole -PlanOnly)
    Check ($plan.planOnly -and -not $plan.ok -and $plan.mode -eq 'ConsoleContent') 'file-free PlanOnly validates and identifies its mode'
    & $publisher @argsConsole -WhatIf | Out-Null
    Check ((Hash $metadataPath) -eq $metaHash -and (Hash $htmlPath) -eq $htmlHash -and (Hash $manifestPath) -eq $manifestHash -and @(Get-ChildItem -LiteralPath (Join-Path $job 'wip\receipts') -Force).Count -eq 0) 'PlanOnly and WhatIf make no writes or receipts'
    $held=[IO.File]::Open($retained,'Open','ReadWrite','None')
    try { $first=Json (& $publisher @argsConsole) } finally { $held.Dispose() }
    $after=Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8|ConvertFrom-Json
    Check ($first.ok -and $first.mode -eq 'ConsoleContent' -and -not $first.documentFilesChanged) 'file-free publication succeeds with an unrelated current document locked'
    Check ((Without-Content $after) -ceq $metadataBefore -and (Hash $registryPath) -eq $registryHash) 'all unrelated metadata, arrays, administrative state and registry preserved'
    Check ($after.consoleContent.sections.Count -eq 1 -and $after.consoleContent.sections[0].body -ceq $content.sections[0].body -and $after.consoleContent.sections[0].references -is [array]) 'Korean multiline text and singleton/empty arrays preserved'
    Check ((Hash $contentPath) -eq $first.source.sha256 -and (Hash $metadataPath) -eq $first.metadataSha256 -and (Hash $htmlPath) -eq $first.consoleSha256 -and (Test-Path -LiteralPath $first.receiptPath) -and (Test-Path -LiteralPath $first.latestReceiptPath)) 'success receipt binds input, metadata and HTML hashes with durable recovery copies'
    Check (@(Get-ChildItem -LiteralPath (Join-Path $work 'previous_versions') -Force).Count -eq 0 -and [IO.File]::ReadAllText($target) -eq 'original csv' -and [IO.File]::ReadAllText($retained) -eq 'unrelated document') 'no document replacement or document archive created'
    $again=Json (& $publisher @argsConsole)
    Check ($again.ok -and $again.receiptPath -ne $first.receiptPath -and (Without-Content (Get-Content $metadataPath -Raw -Encoding utf8|ConvertFrom-Json)) -ceq $metadataBefore) 'repeat publication has its own receipt without changing state'

    foreach ($mode in @('throw','invalid','wrong','false')) {
        $baseline=@{}; foreach ($path in @($metadataPath,$htmlPath,$manifestPath,$first.latestReceiptPath,$registryPath,$target,$retained)) { $baseline[$path]=Hash $path }
        [IO.File]::WriteAllText((Join-Path $fixture 'renderer-mode'),$mode)
        Fails { & $publisher @argsConsole } 'rolled back' "renderer $mode failure reports rollback"
        foreach ($path in $baseline.Keys) { Check ((Hash $path) -eq $baseline[$path]) "$mode rollback preserves $([IO.Path]::GetFileName($path)) bytes" }
        $failures=@(Get-ChildItem -LiteralPath (Join-Path $job 'wip\receipts') -Filter receipt.json -Recurse | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8|ConvertFrom-Json } | Where-Object status -eq 'failed')
        Check ($failures.Count -gt 0 -and @($failures | Where-Object { -not $_.rollback.ok -or $_.ok }).Count -eq 0) "$mode failure receipt records completed rollback"
    }
    Check (-not (Test-Path -LiteralPath (Join-Path $work '문서 열기'))) 'new shortcut and empty entry folder removed on failed generation'
    Remove-Item -LiteralPath (Join-Path $fixture 'renderer-mode')
    $savedHtml=[IO.File]::ReadAllBytes($htmlPath); $savedManifest=[IO.File]::ReadAllBytes($manifestPath)
    Remove-Item -LiteralPath $htmlPath; Remove-Item -LiteralPath $manifestPath
    [IO.File]::WriteAllText((Join-Path $fixture 'renderer-mode'),'throw')
    Fails { & $publisher @argsConsole } 'rolled back' 'failure without previous HTML or manifest rolls back'
    Check (-not (Test-Path -LiteralPath $htmlPath) -and -not (Test-Path -LiteralPath $manifestPath)) 'rollback removes newly created outputs when none existed'
    [IO.File]::WriteAllBytes($htmlPath,$savedHtml); [IO.File]::WriteAllBytes($manifestPath,$savedManifest)
    Remove-Item -LiteralPath (Join-Path $fixture 'renderer-mode')

    # Schema rejection is pre-mutation, with no failed-render receipt implied.
    $validJson=Get-Content -LiteralPath $contentPath -Raw -Encoding utf8
    foreach ($bad in @(
        '{"schemaVersion":"bad","sections":[]}',
        '{"schemaVersion":"hwpx-console-content/v1","sections":{}}',
        '{"schemaVersion":"hwpx-console-content/v1","sections":[{"id":"x","title":"x","body":1}]}',
        '{"schemaVersion":"hwpx-console-content/v1","sections":[{"id":"x","title":"x","body":null}]}',
        '{"schemaVersion":"hwpx-console-content/v1","sections":[{"id":"x","title":"x","body":""},{"id":"X","title":"x","body":""}]}',
        '{"schemaVersion":"hwpx-console-content/v1","sections":[],"stage":"Final"}',
        '{"schemaVersion":"hwpx-console-content/v1","sections":[{"id":"x","title":"x","body":"","references":{}}]}'
    )) {
        [IO.File]::WriteAllText($contentPath,$bad)
        Fails { & $publisher @argsConsole } 'schemaVersion|array|string|Duplicate|Unknown' 'invalid schema rejected'
    }
    Set-Content -LiteralPath $contentPath -Value $validJson -Encoding utf8
    Fails { & $publisher @argsConsole -Stage Final } 'parameter set|매개 변수 집합' 'console mode cannot advance Stage'
    Fails { & $publisher @argsConsole -ReviewQuestion 'replace' } 'document publication parameter' 'console mode cannot replace review state'
    Fails { & $publisher @argsConsole -PartialUpdate } 'parameter set|매개 변수 집합' 'console and partial file publication are mutually exclusive'
    Fails { & $publisher @argsConsole -DeliveryConfigPath $configPath } 'only with PlanOnly' 'mutating config override remains blocked'
    $overridePlan=Json (& $publisher @argsConsole -DeliveryConfigPath $configPath -RegistryPath $registryPath -PlanOnly)
    Check $overridePlan.planOnly 'read-only isolated config override remains supported'
    $rogue=Join-Path $work 'explanation.txt'; [IO.File]::WriteAllText($rogue,'manual file')
    $withRogue=Json (& $publisher @argsConsole)
    Check ($withRogue.ok -and $withRogue.registrationDifferences.unregisteredCount -eq 1) 'console report preserves and reports unregistered file without blocking'
    Check ([IO.File]::ReadAllText($rogue) -eq 'manual file') 'unregistered file is preserved'
    Remove-Item -LiteralPath $rogue
    Move-Item -LiteralPath $retained -Destination (Join-Path $fixture 'retained.pdf')
    $withMissing=Json (& $publisher @argsConsole)
    Check ($withMissing.ok -and $withMissing.registrationDifferences.missingCount -eq 1) 'console report notes missing file without changing authority'
    Move-Item -LiteralPath (Join-Path $fixture 'retained.pdf') -Destination $retained
    $oldRegistry=[IO.File]::ReadAllBytes($registryPath)
    $registry.works[0].folderName='20260908_parent\20260908_nested'; Save $registryPath $registry
    Fails { & $publisher -WorkFolderName $registry.works[0].folderName -ConsoleContentPath $contentPath } 'direct child' 'nested registered work is rejected'
    [IO.File]::WriteAllBytes($registryPath,$oldRegistry)
    Fails { & $publisher -WorkFolderName '20260908_unknown' -ConsoleContentPath $contentPath } 'registered work' 'unregistered work is rejected'
    $outside=Join-Path $fixture 'content.json'; Copy-Item -LiteralPath $contentPath -Destination $outside
    Fails { & $publisher -WorkFolderName $folder -ConsoleContentPath $outside } 'outside supported storage' 'input outside job and maintenance roots is rejected'
    $junction=Join-Path $job 'linked'
    New-Item -ItemType Junction -Path $junction -Value $fixture | Out-Null
    try { Fails { & $publisher -WorkFolderName $folder -ConsoleContentPath (Join-Path $junction 'content.json') } 'Reparse' 'source junction cannot escape allowed roots' } finally { [IO.Directory]::Delete($junction) }

    $evidence=Join-Path $fixture 'evidence.csv'; [IO.File]::WriteAllText($evidence,'evidence revision')
    $ref=@{path=$evidence;sha256=(Hash $evidence);locator='row 1'}
    $content.sections[0].references=@($ref); Save $contentPath $content
    Fails { & $publisher @argsConsole } 'not a registered' 'unregistered evidence rejected'
    Save $sourcesPath @{sources=@(@{path=$evidence;sha256=$ref.sha256;role='reference'})}
    $withReference=Json (& $publisher @argsConsole)
    Check ($withReference.references.Count -eq 1 -and $withReference.references[0].locator -eq 'row 1') 'registered source hash and locator accepted and receipted'
    [IO.File]::WriteAllText($evidence,'changed evidence')
    Fails { & $publisher @argsConsole } 'missing or changed' 'stale evidence hash rejected'
    $copyRelative='previous_versions\evidence.csv'; $copy=Join-Path $work $copyRelative
    [IO.File]::WriteAllText($copy,'evidence revision')
    Save $sourcesPath @{sources=@(@{path=$evidence;sha256=$ref.sha256;copyRelativePath=$copyRelative;role='reference'})}
    $withCopy=Json (& $publisher @argsConsole)
    Check ($withCopy.references[0].verifiedPath -eq $copy) 'registered preserved revision remains valid after original changes'
    $content.sections[0].references[0].sha256='0'*64; Save $contentPath $content
    Fails { & $publisher @argsConsole } 'not a registered' 'wrong registered hash rejected'
    $content.sections[0].references=@(); Save $contentPath $content
    $maintenanceInput=Join-Path $maintenance 'content.json'; Copy-Item -LiteralPath $contentPath -Destination $maintenanceInput
    $maintenanceResult=Json (& $publisher -TaskTitle 'Console test' -ConsoleContentPath $maintenanceInput)
    Check ($maintenanceResult.ok -and $maintenanceResult.latestReceiptPath.StartsWith($maintenance)) 'maintenance input accepted and receipt stays in maintenance workspace'
    Save $contentPath @{schemaVersion='hwpx-console-content/v1';sections=@()}
    $cleared=Json (& $publisher @argsConsole)
    $empty=Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8|ConvertFrom-Json
    Check ($cleared.ok -and $empty.consoleContent.sections -is [array] -and $empty.consoleContent.sections.Count -eq 0) 'explicit empty sections clear only console content'

    # Real renderer orchestration in a copied workspace; rendering UI belongs to its owner.
    Save $manifestPath @{schemaVersion='hwpx-human-open-targets/v1';workFolders=@()}
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Update-HumanWorkConsole.ps1') -Destination $renderer -Force
    $tableContent=@{schemaVersion='hwpx-console-content/v1';sections=@(@{id='analysis';title='표';body='';tables=@(@{caption='비교';columns=@('과목','판단');rows=@(@('국어','<script>alert(1)</script>'),@('수학','30%'))})})}
    Save $contentPath $tableContent
    $real=Json (& $publisher @argsConsole)
    Check ($real.ok -and $real.console.schemaVersion -match '^hwpx-human-console/' -and (Test-Path -LiteralPath $htmlPath)) 'real renderer integrates in isolated workspace without deployment'
    $tableHtml=Get-Content -LiteralPath $htmlPath -Raw -Encoding utf8
    Check ($tableHtml.Contains('<table class="console-report-table">') -and $tableHtml.Contains('<th scope="col">')) 'semantic report table rendered'
    $renderedTable=[regex]::Match($tableHtml,'(?s)<table class="console-report-table">.*?</table>').Value
    $renderedRows=[regex]::Matches($renderedTable,'(?s)<tbody>(.*?)</tbody>')[0].Groups[1].Value
    Check (([regex]::Matches($renderedRows,'<tr>')).Count -eq 2) 'two data records render as two rows'
    foreach($rowMatch in [regex]::Matches($renderedRows,'(?s)<tr>(.*?)</tr>')) {
        Check (([regex]::Matches($rowMatch.Value,'<td>')).Count -eq 2) 'every data row has two aligned cells'
    }
    Check ($tableHtml.Contains('&lt;script&gt;alert(1)&lt;/script&gt;') -and -not $tableHtml.Contains('<script>alert(1)</script>')) 'table cell HTML escaped'
    Check ((Without-Content (Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8|ConvertFrom-Json)) -eq $metadataBefore) 'table report preserves document metadata'
    $messageContent=@{schemaVersion='hwpx-console-content/v1';sections=@(@{id='copy-message';title='메시지';body="공통 안내`n[2학년 국어] 28+5=33`n`n[3학년 과학] <script>";presentation='message'})}
    Save $contentPath $messageContent
    $messageResult=Json (& $publisher @argsConsole)
    $messageHtml=Get-Content -LiteralPath $htmlPath -Raw -Encoding utf8
    Check ($messageHtml.Contains('<strong>[2학년 국어]</strong>') -and $messageHtml.Contains('<br><br><strong>[3학년 과학]</strong>')) 'message bold labels and explicit blank lines'
    Check ($messageHtml.Contains('&lt;script&gt;') -and $messageHtml.Contains('data-copy-message="message-copy-message"')) 'message escaped with copy control'
    Check ($messageHtml.Contains("setData('text/plain'") -and $messageHtml.Contains("setData('text/html'")) 'copy provides both plain and formatted content'
    $tableContent.sections[0].tables[0].rows=@(@('short'))
    Save $contentPath $tableContent
    Fails { & $publisher @argsConsole } 'row width' 'malformed table rejected'
    Set-Content -LiteralPath $renderer -Value $stub -Encoding utf8

    # Existing file publication still uses its authority and selected-target logic.
    $txt=Join-Path $job 'requested.txt'; [IO.File]::WriteAllText($txt,'actual requested artifact')
    $fileArgs=@{Stage='Review';TaskTitle='Console test';WorkFolderName=$folder}
    Fails { & $publisher @fileArgs -SourceFile $txt -PlanOnly } 'ExplicitTextArtifact' 'TXT rejected by default without content/name heuristics'
    Fails { & $publisher @fileArgs -SourceFile @($txt,$target) -ExplicitTextArtifact -PlanOnly } 'job|jobs' 'explicit TXT cannot publish a file outside the job'
    Save (Join-Path $job 'inputs.json') @{userProvidedSelectionRecorded=$true;sources=@(@{role='human_revision';path=$target;sha256=(Hash $target)},@{role='human_revision';path=$retained;sha256=(Hash $retained)})}
    $textPlan=Json (& $publisher @fileArgs -SourceFile $txt -ExplicitTextArtifact -PlanOnly)
    Check ($null -ne $textPlan) 'explicit requested TXT reaches the normal artifact plan'
    $report=[ordered]@{ok=$true;count=$checks.Count;checks=@($checks);powershell=$PSVersionTable.PSVersion.ToString()}
    $reportJson=$report|ConvertTo-Json -Depth 8
    if($ReceiptPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReceiptPath),$reportJson,[Text.UTF8Encoding]::new($true))}
    $reportJson
} finally {
    if ($global:ConsolePublicationTestLock) { $global:ConsolePublicationTestLock.Dispose(); $global:ConsolePublicationTestLock=$null }
    $safe=[IO.Path]::GetFullPath($fixture)
    $prefix=Join-Path $workspace '.agent\cache\cp-'
    if ($safe.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $safe)) { Remove-Item -LiteralPath $safe -Recurse -Force }
}
