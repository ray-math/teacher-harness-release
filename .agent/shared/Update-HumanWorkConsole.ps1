[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkFolder,

    [string]$CabinetRoot = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
$owner=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$ownerConfig=Get-Content -LiteralPath (Join-Path $owner '.agent\index\delivery-system.json') -Raw -Encoding utf8|ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $ownerConfig = Resolve-TeacherHarnessConfig -Workspace $owner -Config $ownerConfig
} elseif (-not [IO.Path]::IsPathRooted([string]$ownerConfig.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$portableGenerator=Join-Path $ownerConfig.humanCabinet '.agent\shared\Update-HumanWorkConsole.ps1'
if(-not $CabinetRoot -and $owner -ine [string]$ownerConfig.humanCabinet -and (Test-Path -LiteralPath $portableGenerator)){
    & $portableGenerator @PSBoundParameters
    return
}

if ($owner -ine [string]$ownerConfig.humanCabinet) {
    throw 'The optional cabinet console runtime must be installed explicitly before console generation. The harness cannot store work manifests.'
}

# The console is regenerated from a browser click, so it must run on the shell that is
# always present on this host (Windows PowerShell 5.1) as well as on PowerShell 7.
# These shims replace the PowerShell 7 / .NET Core only APIs this script used to call.
function ConvertTo-HashtableDeep {
    # ConvertFrom-Json -AsHashtable is PowerShell 7 only; this host runs Windows PowerShell 5.1.
    # Ordered maps keep the JSON key order these metadata files are written back with.
    [CmdletBinding()]
    param([Parameter(Position = 0, ValueFromPipeline = $true)]$Value)
    process {
        if ($null -eq $Value) { return $null }
        if ($Value -is [Management.Automation.PSCustomObject]) {
            $map = [ordered]@{}
            foreach ($property in $Value.PSObject.Properties) { $map[$property.Name] = ConvertTo-HashtableDeep $property.Value }
            return $map
        }
        if ($Value -is [Collections.IDictionary]) {
            $map = [ordered]@{}
            foreach ($key in @($Value.Keys)) { $map[$key] = ConvertTo-HashtableDeep $Value[$key] }
            return $map
        }
        if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
            return @(foreach ($item in $Value) { ConvertTo-HashtableDeep $item })
        }
        $Value
    }
}

function Get-RelativePathCompat([string]$Root, [string]$Path) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ($pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return $pathFull.Substring($rootFull.Length + 1)
    }
    if ($pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return '.' }
    $rootUri = [Uri]($rootFull + '\')
    $pathUri = [Uri]$pathFull
    [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function Move-FileOverwrite([string]$Source, [string]$Destination) {
    if ([IO.File]::Exists($Destination)) {
        # File.Replace is unreliable for an HTML file currently mapped by Edge on
        # Windows PowerShell 5.1. Copy with overwrite succeeds while the browser is open.
        [IO.File]::Copy($Source, $Destination, $true)
        [IO.File]::Delete($Source)
    } else {
        [IO.File]::Move($Source, $Destination)
    }
}

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$config = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $workspace '.agent\index\delivery-system.json') | ConvertFrom-Json
$pathResolver = Join-Path $PSScriptRoot 'Resolve-TeacherHarnessConfig.ps1'
if (Test-Path -LiteralPath $pathResolver) {
    . $pathResolver
    $config = Resolve-TeacherHarnessConfig -Workspace $workspace -Config $config
} elseif (-not [IO.Path]::IsPathRooted([string]$config.humanCabinet)) { throw 'Relative delivery paths require Resolve-TeacherHarnessConfig.ps1.' }
$cabinet = if ([string]::IsNullOrWhiteSpace($CabinetRoot)) {
    [IO.Path]::GetFullPath([string]$config.humanCabinet)
} else {
    [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $CabinetRoot).Path)
}
$resolvedWork = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $WorkFolder).Path)
if (-not (Test-Path -LiteralPath $resolvedWork -PathType Container)) { throw "WorkFolder is not a directory: $resolvedWork" }
if ([IO.Path]::GetDirectoryName($resolvedWork).TrimEnd('\') -ine $cabinet.TrimEnd('\')) {
    throw "WorkFolder must be a direct child of the configured cabinet: $resolvedWork"
}
$folderName = [IO.Path]::GetFileName($resolvedWork)
if (-not (Test-WorkFolderName $folderName)) { throw "Invalid work-folder name: $folderName" }

$consoleName = [string]$config.consoleFileName
$defaultOutput = Join-Path $resolvedWork $consoleName
$resolvedOutput = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    [IO.Path]::GetFullPath($defaultOutput)
} else { [IO.Path]::GetFullPath($OutputPath) }
if ([IO.Path]::GetDirectoryName($resolvedOutput).TrimEnd('\') -ine $resolvedWork.TrimEnd('\')) {
    throw 'The human console must be written directly under its work folder.'
}
if ([IO.Path]::GetFileName($resolvedOutput) -ine $consoleName) {
    throw "The human console filename must be $consoleName"
}

$metadataRoot = Join-Path $resolvedWork ([string]$config.metadataFolderName)
$workMetadataPath = Join-Path $metadataRoot ([string]$config.workMetadataName)
$sourceMetadataPath = Join-Path $metadataRoot ([string]$config.sourceMetadataName)
if (-not (Test-Path -LiteralPath $workMetadataPath -PathType Leaf)) { throw "Hidden work metadata is missing: $workMetadataPath" }
$workMetadata = Get-Content -Raw -Encoding utf8 -LiteralPath $workMetadataPath | ConvertFrom-Json | ConvertTo-HashtableDeep
$sourceMetadata = if (Test-Path -LiteralPath $sourceMetadataPath -PathType Leaf) {
    Get-Content -Raw -Encoding utf8 -LiteralPath $sourceMetadataPath | ConvertFrom-Json | ConvertTo-HashtableDeep
} else { @{ sources=@() } }

function Encode-Html([AllowNull()][string]$Value) {
    if ($null -eq $Value) { return '' }
    [Net.WebUtility]::HtmlEncode($Value)
}

function Get-DirectOpenUri([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    [void]$script:openTargets.Add($full)
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($full)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    ([string]$config.openProtocol) + '://open/' + $payload
}

function Get-VisibilityBoundary([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        $cabinet,
        [string]$config.incomingRoot,
        [IO.Path]::GetTempPath()
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $root = [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $roots.Add($root)
        }
    }
    if ($roots.Count -gt 0) { return @($roots | Sort-Object Length -Descending)[0] }
    # A source explicitly registered outside the known roots is inspected only within
    # its own parent folder. OS attributes on C:\ (or another volume root) must not
    # make an ordinary selected file disappear from the console.
    [IO.Path]::GetDirectoryName($full)
}

function Test-HiddenItem([IO.FileSystemInfo]$Item, [string]$Boundary = '') {
    # Leaf-only checks leak ordinary files inside hidden directories and .ai. Stop at
    # the relevant content root so unrelated attributes on OS ancestors are ignored.
    $scanBoundary = if ([string]::IsNullOrWhiteSpace($Boundary)) {
        Get-VisibilityBoundary $Item.FullName
    } else { [IO.Path]::GetFullPath($Boundary).TrimEnd('\') }
    $cursor = $Item
    while ($null -ne $cursor) {
        # School jobs now live with the work, but their metadata, scripts and
        # intermediate drafts are not user-facing console files or open targets.
        if ($cursor -is [IO.DirectoryInfo] -and $cursor.Name -eq '_작업중' -and $cursor.Parent.Name -ieq [string]$config.archiveFolderName) { return $true }
        if ($cursor.Name -ieq '.ai' -or ($cursor.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint)) -ne 0) { return $true }
        if ($cursor.FullName.TrimEnd('\') -ieq $scanBoundary) { break }
        $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
    }
    $false
}

function Test-SensitiveText([AllowNull()][string]$Value) {
    # This console is a local, user-only view. Privacy masking remains in chat and indexes,
    # but local TXT/control text is shown as the user requested.
    $false
}

function Test-SensitiveSourceLabel([AllowNull()][string]$Value) {
    $false
}

function Test-SecretText([AllowNull()][string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $Value -match '(?i)(비밀번호|password|passwd|api[_ -]?key|client[_ -]?secret|access[_ -]?token)\s*[:=]\s*\S+' -or
    $Value -match '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
}

function Read-TextFile([IO.FileInfo]$File) {
    if (Test-SecretText $File.FullName) {
        return [pscustomobject]@{ Embedded=$false; Reason='자격증명 또는 비밀 가능성이 있어 이 화면에는 내용을 넣지 않았습니다.'; Text='' }
    }
    if (Test-SensitiveText $File.FullName) {
        return [pscustomobject]@{ Embedded=$false; Reason='개인정보 가능성이 있어 이 화면에는 내용을 넣지 않았습니다.'; Text='' }
    }
    if ($File.Length -gt 2MB) {
        return [pscustomobject]@{ Embedded=$false; Reason='파일이 커서 이 화면에는 내용을 넣지 않았습니다.'; Text='' }
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($File.FullName)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $text = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
        } else {
            try {
                $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
                $text = $strictUtf8.GetString($bytes)
            } catch {
                [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
                $text = [Text.Encoding]::GetEncoding(949).GetString($bytes)
            }
        }
    } catch {
        return [pscustomobject]@{ Embedded=$false; Reason='텍스트를 안전하게 읽지 못해 내용을 넣지 않았습니다.'; Text='' }
    }
    if (Test-SecretText $text) {
        return [pscustomobject]@{ Embedded=$false; Reason='자격증명 또는 비밀 가능성이 있어 이 화면에는 내용을 넣지 않았습니다.'; Text='' }
    }
    if (Test-SensitiveText $text) {
        return [pscustomobject]@{ Embedded=$false; Reason='개인정보 가능성이 있어 이 화면에는 내용을 넣지 않았습니다.'; Text='' }
    }
    [pscustomobject]@{ Embedded=$true; Reason=''; Text=$text }
}

$script:textToggleCount = 0
$script:fileLinkCount = 0
$script:privacyOmittedCount = 0
$script:openTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:revisionPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($revision in @($workMetadata.revisionHistory)) {
    if ($revision.relativePath) { [void]$script:revisionPaths.Add(([string]$revision.relativePath).Replace('/','\')) }
}

function Test-RevisionFile([string]$Path) {
    $relative = (Get-RelativePathCompat $resolvedWork $Path).Replace('/','\')
    $script:revisionPaths.Contains($relative) -or $relative.StartsWith(([string]$config.archiveFolderName + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function New-FileRow([IO.FileInfo]$File, [string]$Label) {
    if (Test-RevisionFile $File.FullName) { $Label += ' · 이전 버전' }
    $encodedLabel = Encode-Html $Label
    if ($File.Extension -ieq '.lnk') {
        return '<div class="missing-file"><span>' + $encodedLabel + ' · Windows 파일 탐색기에서 실행</span></div>'
    }
    if ($File.Extension -ieq '.txt') {
        $script:textToggleCount++
        $payload = Read-TextFile $File
        if (-not $payload.Embedded) { $script:privacyOmittedCount++ }
        $body = if ($payload.Embedded) {
            '<pre>' + (Encode-Html $payload.Text) + '</pre>'
        } else { '<p class="notice">' + (Encode-Html $payload.Reason) + '</p>' }
        return '<details class="text-file"><summary><span class="chevron" aria-hidden="true"></span><span>' + $encodedLabel + '</span></summary><div class="text-body">' + $body + '</div></details>'
    }
    $script:fileLinkCount++
    '<a class="file-link" href="' + (Encode-Html (Get-DirectOpenUri $File.FullName)) + '" title="연결된 프로그램으로 바로 열기"><span class="file-mark" aria-hidden="true">&#128196;</span><span>' + $encodedLabel + '</span></a>'
}

function Get-WorkflowId([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').Substring(0,24) } finally { $sha.Dispose() }
}
function New-WorkflowReferenceHtml($Reference) {
    $registered=@($sourceMetadata.sources | Where-Object { $_.path -ieq $Reference.path -and $_.sha256 -ieq $Reference.sha256 })
    if(-not $registered.Count){return '<p class="notice">참고 파일 등록 확인 필요</p>'}
    $path=Resolve-ConsoleSourcePath $registered[0]
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return '<p class="notice">참고 파일을 현재 위치에서 찾을 수 없습니다.</p>'}
    $file=Get-Item -LiteralPath $path -Force
    if((Test-HiddenItem $file) -or ($config.portableCabinet -and -not $path.StartsWith($cabinet.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){return '<p class="notice">이 공유본에서 열 수 없는 참고 파일입니다.</p>'}
    New-FileRow -File $file -Label $file.Name
}
function New-ConsoleContentHtml {
    if (-not $workMetadata.consoleContent) { return '' }
    # Preserve nested table row arrays; the legacy hashtable converter flattens them.
    $content = (Get-Content -Raw -Encoding utf8 -LiteralPath $workMetadataPath | ConvertFrom-Json).consoleContent
    if ($content.schemaVersion -ne 'hwpx-console-content/v1') { throw 'Unsupported console content schema.' }
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($section in @($content.sections)) {
        if (-not $section.id -or -not $section.title -or $section.body -isnot [string]) { throw 'Invalid console content section.' }
        $body = '<h2>' + (Get-SafeMetadataText ([string]$section.title)) + '</h2><div class="console-content-body">' + (Get-SafeMetadataText ([string]$section.body)) + '</div>'
        if ($section.presentation -eq 'message') {
            $messageId = 'message-' + [string]$section.id
            $lines = [Collections.Generic.List[string]]::new()
            foreach ($line in ([string]$section.body -split "`r?`n")) {
                if ($line -match '^(\[[123]학년 [^\]]+\])(.*)$') {
                    $lines.Add('<strong>' + (Get-SafeMetadataText $Matches[1]) + '</strong>' + (Get-SafeMetadataText $Matches[2]))
                } else { $lines.Add((Get-SafeMetadataText $line)) }
            }
            $body = '<h2>' + (Get-SafeMetadataText ([string]$section.title)) + '</h2><button type="button" class="copy-message-button" data-copy-message="' + (Encode-Html $messageId) + '">메시지 복사</button><span class="message-copy-status" aria-live="polite"></span><div class="copy-message-text" id="' + (Encode-Html $messageId) + '">' + ($lines -join '<br>') + '</div>'
        }
        foreach ($table in @($section.tables)) {
            if (-not $table) { continue }
            $body += '<div class="console-table-scroll" tabindex="0" role="region" aria-label="' + (Encode-Html ([string]$table.caption)) + '"><table class="console-report-table"><caption>' + (Get-SafeMetadataText ([string]$table.caption)) + '</caption><thead><tr>'
            foreach ($column in $table.columns) { $body += '<th scope="col">' + (Get-SafeMetadataText ([string]$column)) + '</th>' }
            $body += '</tr></thead><tbody>'
            foreach ($cells in $table.rows) {
                $body += '<tr>'
                foreach ($cell in $cells) { $body += '<td>' + (Get-SafeMetadataText ([string]$cell)) + '</td>' }
                $body += '</tr>'
            }
            $body += '</tbody></table></div>'
        }
        if ($section.references) {
            $body += '<details class="workflow-evidence"><summary>참고 자료</summary>'
            foreach ($reference in @($section.references)) {
                $body += New-WorkflowReferenceHtml $reference
                if ($reference.locator) { $body += '<p class="notice">' + (Get-SafeMetadataText ([string]$reference.locator)) + '</p>' }
            }
            $body += '</details>'
        }
        $rows.Add('<section class="console-content" id="content-' + (Encode-Html ([string]$section.id)) + '">' + $body + '</section>')
    }
    $rows -join [Environment]::NewLine
}

function New-StatusHtml {
    $rows = [Collections.Generic.List[string]]::new()
    if($workMetadata.workflow -and $workMetadata.workflow.steps){
        foreach($step in $workMetadata.workflow.steps){
            $basis=if($step.basis -eq 'prior'){'이전 자료 기준 · 올해 확인 필요'}elseif($step.basis -eq 'user'){'사용자 지정 순서'}else{'현재 자료 기준'}
            $heading=Get-SafeMetadataText ([string]$step.period)
            if($step.title){$heading+=' · '+(Get-SafeMetadataText ([string]$step.title))}
            $stepId=if($step.id){[string]$step.id}else{Get-WorkflowId (([string]$step.period)+'|'+([string]$step.action))}
            $items=if($step.items){@($step.items)}else{@(foreach($line in ([string]$step.action -split '\r?\n')){if($line.Trim()){@{id=(Get-WorkflowId $line);text=$line}}})}
            $body='<h2>'+$heading+' <span class="step-progress"></span></h2><p class="workflow-basis">'+$basis+'</p><div class="workflow-checks">'
            foreach($item in $items){
                $key=$stepId+'/'+[string]$item.id
                $body+='<label class="workflow-check"><input type="checkbox" data-work-check="'+(Encode-Html $key)+'"><span>'+(Get-SafeMetadataText ([string]$item.text))+'</span></label>'
            }
            $body+='</div>'
            $references=if($step.references){@($step.references)}else{@(@{path=$step.sourcePath;sha256=$step.sourceSha256})}
            $body+='<div class="workflow-references"><strong>참고 파일</strong>'
            foreach($reference in $references){if($reference.path){$body+=(New-WorkflowReferenceHtml $reference)}}
            $body+='</div>'
            if($step.result){$body+='<p class="workflow-result"><strong>완료 기준</strong> '+(Get-SafeMetadataText ([string]$step.result))+'</p>'}
            if($step.confirm){$body+='<p class="workflow-confirm"><strong>확인 필요</strong> '+(Get-SafeMetadataText ([string]$step.confirm))+'</p>'}
            if($step.evidence){$body+='<details class="workflow-evidence"><summary>근거 보기</summary><p>'+(Get-SafeMetadataText ([string]$step.evidence))+'</p><p class="notice">'+(Get-SafeMetadataText ([string]$step.locator))+'</p></details>'}
            $rows.Add('<li class="workflow-step">'+$body+'</li>')
        }
        return '<div class="workflow-toolbar"><button type="button" id="workflow-resume">이어서 할 단계로</button><span id="workflow-progress" role="status"></span></div><p class="workflow-storage" id="workflow-storage">체크는 이 브라우저에 저장됩니다. 다른 PC·브라우저로는 전달되지 않습니다.</p><ol class="workflow-list">'+($rows -join '')+'</ol>'
    }
    if(-not [string]::IsNullOrWhiteSpace([string]$workMetadata.nextAction)){
        return '<div class="workflow-action workflow-legacy">'+(Get-SafeMetadataText ([string]$workMetadata.nextAction))+'</div>'
    }
    '<p class="empty">자료를 검토한 뒤 업무 흐름을 작성합니다.</p>'
}

function New-IntakeFooterHtml {
    $raw=[string]$workMetadata.lastIntakeAt
    if([string]::IsNullOrWhiteSpace($raw)){return ''}
    $parsed=[DateTimeOffset]::MinValue
    $label=if([DateTimeOffset]::TryParse($raw,[ref]$parsed)){$parsed.ToString('yyyy-MM-dd HH:mm')}else{$raw}
    '<footer class="intake-footer">최근 접수 <time datetime="'+(Get-SafeMetadataText $raw)+'">'+(Get-SafeMetadataText $label)+'</time></footer>'
}

function New-ReviewHtml {
    $reviewQuestion = if ($workMetadata.review -is [Collections.IDictionary]) { [string]$workMetadata.review.question } else { '' }
    if ([string]::IsNullOrWhiteSpace($reviewQuestion)) { return '' }
    '<details class="review-request"><summary><span class="review-badge" aria-hidden="true">!</span><strong>확인 요청</strong><span class="chevron" aria-hidden="true"></span></summary><div class="review-copy">' + (Get-SafeMetadataText $reviewQuestion) + '</div></details>'
}

function Get-SafeMetadataText([string]$Value) {
    if (Test-SecretText $Value) {
        $script:privacyOmittedCount++
        return '자격증명 또는 비밀 가능성이 있어 내용을 표시하지 않았습니다.'
    }
    Encode-Html $Value
}

function Get-SourceLocationLabel([string]$Folder) {
    $full = [IO.Path]::GetFullPath($Folder)
    foreach ($rootInfo in @(
        [pscustomobject]@{ Root=[string]$config.incomingRoot; Label='공문' },
        [pscustomobject]@{ Root=$cabinet; Label='업무' }
    )) {
        $root = [IO.Path]::GetFullPath($rootInfo.Root).TrimEnd('\')
        if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $rootInfo.Label }
        if ($full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $rootInfo.Label + ' / ' + ((Get-RelativePathCompat $root $full) -replace '\\', ' / ')
        }
    }
    $leaf = [IO.Path]::GetFileName($full.TrimEnd('\'))
    if ([string]::IsNullOrWhiteSpace($leaf)) { return '외부 자료' }
    '외부 자료 / ' + $leaf
}

$script:sourceIndexesLoaded=$false
$script:priorSourceMap=@{}
$script:preservedSourceMap=@{}
$script:sourceHashCache=@{}
function Get-ConsoleSourceHash([string]$Path) {
    if(-not $script:sourceHashCache.ContainsKey($Path)){
        try { $script:sourceHashCache[$Path]=(Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash }
        catch { $script:sourceHashCache[$Path]='unavailable' } # Display refresh cannot certify a locked source or block unrelated edits.
    }
    $script:sourceHashCache[$Path]
}
function Initialize-ConsoleSourceIndexes {
    if($script:sourceIndexesLoaded){return}
    $priorIndex=Join-Path $cabinet '.agent\index\prior-materials.json'
    if(Test-Path -LiteralPath $priorIndex){
        foreach($r in @(Get-Content -LiteralPath $priorIndex -Raw -Encoding utf8|ConvertFrom-Json)){
            $key=([string]$r.path)+'|'+([string]$r.sha256)
            $script:priorSourceMap[$key]=@($script:priorSourceMap[$key])+@($r)
        }
    }
    $ledger=Join-Path $metadataRoot 'source-preservations.json'
    if(Test-Path -LiteralPath $ledger){
        foreach($r in (Get-Content -LiteralPath $ledger -Raw -Encoding utf8|ConvertFrom-Json).records){
            if($r.state -ne 'preserved'){continue}
            $key=[string]$r.sha256
            $script:preservedSourceMap[$key]=@($script:preservedSourceMap[$key])+@($r)
        }
    }
    $script:sourceIndexesLoaded=$true
}
function Resolve-ConsoleSourcePath($Source) {
    $original = [IO.Path]::GetFullPath([string]$Source.path)
    Initialize-ConsoleSourceIndexes
    $key=$original+'|'+([string]$Source.sha256)
    if($script:priorSourceMap.ContainsKey($key)){
        foreach($r in $script:priorSourceMap[$key]){
            if(-not $r){continue}
            $p=[IO.Path]::GetFullPath((Join-Path $cabinet $r.relativePath))
            if($p.StartsWith($cabinet.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $p -PathType Leaf) -and -not(Test-HiddenItem (Get-Item -LiteralPath $p -Force)) -and (Get-ConsoleSourceHash $p) -ieq $r.sha256){return $p}
        }
    }
    if ($script:preservedSourceMap.ContainsKey([string]$Source.sha256)) {
        foreach ($record in $script:preservedSourceMap[[string]$Source.sha256]) {
            if(-not $record){continue}
            $local = [IO.Path]::GetFullPath((Join-Path $resolvedWork $record.copyRelativePath))
            if ($local.StartsWith($resolvedWork.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -and
                (Test-Path -LiteralPath $local -PathType Leaf) -and -not (Test-HiddenItem (Get-Item -LiteralPath $local -Force)) -and
                (Get-ConsoleSourceHash $local) -ieq $record.sha256) { return $local }
        }
    }
    if ($config.portableCabinet -and $config.previousCabinet -and $original.StartsWith(([string]$config.previousCabinet).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {
        $relocated=Join-Path $cabinet $original.Substring(([string]$config.previousCabinet).TrimEnd('\').Length+1)
        if ((Test-Path -LiteralPath $relocated -PathType Leaf) -and
            -not (Test-HiddenItem (Get-Item -LiteralPath $relocated -Force)) -and
            (Get-ConsoleSourceHash $relocated) -ieq [string]$Source.sha256) { return $relocated }
    }
    if (Test-Path -LiteralPath $original -PathType Leaf) { return $original }
    # A moved PC must not make a same-named file authoritative. Resolve only
    # selected copies or the same relative path under a known moved root,
    # and require the recorded content hash. Original provenance is immutable.
    if ([string]$Source.sha256 -notmatch '^[a-fA-F0-9]{64}$') { return $original }
    $candidates = [Collections.Generic.List[string]]::new()
    if ($Source.copyRelativePath -and -not [IO.Path]::IsPathRooted([string]$Source.copyRelativePath)) {
        $copy = [IO.Path]::GetFullPath((Join-Path $resolvedWork ([string]$Source.copyRelativePath)))
        if ($copy.StartsWith($resolvedWork.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $candidates.Add($copy) }
    }
    foreach ($root in @($cabinet, [string]$config.incomingRoot, $workspace)) {
        $root = [IO.Path]::GetFullPath($root).TrimEnd('\')
        $token = '\' + [IO.Path]::GetFileName($root) + '\'
        $offset = $original.IndexOf($token, [StringComparison]::OrdinalIgnoreCase)
        if ($offset -ge 0) { $candidates.Add((Join-Path $root $original.Substring($offset + $token.Length))) }
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if (Test-HiddenItem (Get-Item -LiteralPath $candidate -Force)) { continue }
        if ((Get-ConsoleSourceHash $candidate) -ieq [string]$Source.sha256) { return $candidate }
    }
    $original
}

function New-SourceTabHtml([AllowNull()][IO.DirectoryInfo]$EvidenceFolder) {
    $groups = [ordered]@{}
    $seenSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $omitted = 0
    foreach ($source in @($sourceMetadata.sources)) {
        $path = [string]$source.path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $full = Resolve-ConsoleSourcePath $source
        if ($full -match '(?i)[\\/]\.ai(?:[\\/]|$)') { $omitted++; continue }
        if ([string]$source.role -eq 'human_revision' -or [IO.Path]::GetDirectoryName($full).TrimEnd('\').Equals($resolvedWork.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { continue }
        $name = if ($source.name) { [string]$source.name } else { [IO.Path]::GetFileName($full) }
        if (Test-SensitiveSourceLabel ($name + ' ' + $full)) { $omitted++; continue }
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $sourceItem = Get-Item -LiteralPath $full -Force
            if (Test-HiddenItem $sourceItem) { $omitted++; continue }
        }
        if (-not $seenSources.Add($full)) { continue }
        $folder = [IO.Path]::GetDirectoryName($full)
        if (-not $groups.Contains($folder)) { $groups[$folder] = [Collections.Generic.List[object]]::new() }
        $groups[$folder].Add([pscustomobject]@{ Path=$full; Name=$name; Role=$(if($source.role){[string]$source.role}else{'reference'}) })
    }
    if ($EvidenceFolder) {
        foreach ($file in @(Get-ChildItem -LiteralPath $EvidenceFolder.FullName -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not (Test-HiddenItem $_) } | Sort-Object FullName)) {
            if (Test-SensitiveSourceLabel $file.FullName) { $omitted++; continue }
            if (-not $seenSources.Add($file.FullName)) { continue }
            $folder = $file.DirectoryName
            if (-not $groups.Contains($folder)) { $groups[$folder] = [Collections.Generic.List[object]]::new() }
            $groups[$folder].Add([pscustomobject]@{ Path=$file.FullName; Name=$file.Name; Role='selected-copy' })
        }
    }
    $html = [Collections.Generic.List[string]]::new()
    foreach ($folder in @($groups.Keys | Sort-Object)) {
        $items = [Collections.Generic.List[string]]::new()
        foreach ($item in @($groups[$folder] | Sort-Object Name)) {
            $label = Encode-Html $item.Name
            $outsidePortable = $config.portableCabinet -and -not $item.Path.StartsWith($cabinet.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)
            if ($outsidePortable) {
                $items.Add('<div class="missing-file"><span>' + $label + ' · 공유본에 없음 (외부 자료)</span></div>')
            } elseif (Test-Path -LiteralPath $item.Path -PathType Leaf) {
                $script:fileLinkCount++
                $items.Add('<a class="file-link source-file-link" href="' + (Encode-Html (Get-DirectOpenUri $item.Path)) + '" title="연결된 프로그램으로 바로 열기"><span class="file-mark" aria-hidden="true">&#128196;</span><span>' + $label + '</span></a>')
            } else {
                $items.Add('<div class="missing-file"><span class="file-mark" aria-hidden="true">&#9888;</span><span>' + $label + ' · 원본 위치에서 찾을 수 없음</span></div>')
            }
        }
        $html.Add('<section class="source-group"><h2>' + (Encode-Html (Get-SourceLocationLabel $folder)) + '</h2>' + ($items -join '') + '</section>')
    }
    $html -join [Environment]::NewLine
}

$visibleRootFiles = @(
    Get-ChildItem -LiteralPath $resolvedWork -File -Force |
        Where-Object { $_.Name -ine $consoleName -and -not (Test-HiddenItem $_) } |
        Sort-Object Name
)
$unexpectedRootNames = @()
$missingRootNames = @()
if ($workMetadata.Contains('currentFiles')) {
    $registeredRootNames = @($workMetadata.currentFiles | Where-Object { $_ } | Select-Object -Unique)
    $revisionNames = @($workMetadata.revisionHistory | ForEach-Object { $_.relativePath })
    $unexpectedRootNames = @($visibleRootFiles | ForEach-Object { $_.Name } | Where-Object { $registeredRootNames -notcontains $_ -and $revisionNames -notcontains $_ })
    $missingRootNames = @($registeredRootNames | Where-Object { -not (Test-Path -LiteralPath (Join-Path $resolvedWork $_) -PathType Leaf) })
    # The console reflects files the human has added, renamed or removed. Intake
    # and publish still enforce registered-current authority before any replacement.
    # Displaying a file does not register it as an approved result or edit base.
}

$folderMap = @{}
foreach ($folder in Get-ChildItem -LiteralPath $resolvedWork -Directory -Force) {
    if ($folder.Name -ieq [string]$config.metadataFolderName -or (Test-HiddenItem $folder)) { continue }
    $folderMap[$folder.Name] = $folder
}
$orderedFolders = [Collections.Generic.List[IO.DirectoryInfo]]::new()
$evidenceFolder = $null
if ($folderMap.ContainsKey([string]$config.defaultEvidenceFolderName)) {
    $evidenceFolder = $folderMap[[string]$config.defaultEvidenceFolderName]
    $folderMap.Remove([string]$config.defaultEvidenceFolderName)
}
$preferred = @()
if ($workMetadata.layout -is [Collections.IDictionary] -and $workMetadata.layout.supportFolders) {
    $preferred = @($workMetadata.layout.supportFolders)
}
foreach ($name in $preferred) {
    if ($folderMap.ContainsKey([string]$name) -and [string]$name -ine [string]$config.archiveFolderName) {
        $orderedFolders.Add($folderMap[[string]$name]); $folderMap.Remove([string]$name)
    }
}
$archiveFolder = $null
if ($folderMap.ContainsKey([string]$config.archiveFolderName)) {
    $archiveFolder = $folderMap[[string]$config.archiveFolderName]
    $folderMap.Remove([string]$config.archiveFolderName)
}
foreach ($folder in @($folderMap.Values | Sort-Object Name)) { $orderedFolders.Add($folder) }
if ($archiveFolder) { $orderedFolders.Add($archiveFolder) }

$tabDefinitions = [Collections.Generic.List[object]]::new()
$tabDefinitions.Add([pscustomobject]@{ Label='workflow'; Folder=$null; Files=@(); Home=$false; Source=$false; Workflow=$true })
$tabDefinitions.Add([pscustomobject]@{ Label='홈'; Folder=$resolvedWork; Files=$visibleRootFiles; Home=$true; Source=$false })
$sourceTabHtml = New-SourceTabHtml -EvidenceFolder $evidenceFolder
if (-not [string]::IsNullOrWhiteSpace($sourceTabHtml)) {
    $tabDefinitions.Add([pscustomobject]@{ Label='업무근거'; Folder=$null; Files=@(); Home=$false; Source=$true; SourceHtml=$sourceTabHtml })
}
foreach ($folder in $orderedFolders) {
    $label = if ($folder.Name -ieq [string]$config.archiveFolderName) { '이전버전' } else { $folder.Name }
    $files = @(
        Get-ChildItem -LiteralPath $folder.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-HiddenItem $_) } |
            Sort-Object FullName
    )
    $tabDefinitions.Add([pscustomobject]@{ Label=$label; Folder=$folder.FullName; Files=$files; Home=$false; Source=$false })
}

$tabHtml = [Collections.Generic.List[string]]::new()
$panelHtml = [Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $tabDefinitions.Count; $index++) {
    $tab = $tabDefinitions[$index]
    $tabId = "work-tab-$index"; $panelId = "work-panel-$index"
    $selected = if ($index -eq 0) { 'true' } else { 'false' }
    $tabIndex = if ($index -eq 0) { '0' } else { '-1' }
    $tabHtml.Add('<button type="button" role="tab" id="' + $tabId + '" aria-controls="' + $panelId + '" aria-selected="' + $selected + '" tabindex="' + $tabIndex + '">' + (Encode-Html $tab.Label) + '</button>')
    $rows = [Collections.Generic.List[string]]::new()
    if ($tab.Home) { $rows.Add((New-ConsoleContentHtml)) }
    if ($tab.Workflow) { $rows.Add((New-StatusHtml)) }
    if ($tab.Source) { $rows.Add([string]$tab.SourceHtml) }
    foreach ($file in @($tab.Files)) {
        $label = if ($tab.Home) { $file.Name } else { ((Get-RelativePathCompat ([string]$tab.Folder) $file.FullName) -replace '\\', ' / ') }
        $rows.Add((New-FileRow -File $file -Label $label))
    }
    if ($tab.Home) {
        $reviewHtml = New-ReviewHtml
        if (-not [string]::IsNullOrWhiteSpace($reviewHtml)) { $rows.Add('<section class="overview review-overview">' + $reviewHtml + '</section>') }
    }
    if ($tab.Files.Count -eq 0 -and -not $tab.Home -and -not $tab.Source -and -not $tab.Workflow) { $rows.Add('<p class="empty">현재 표시할 파일이 없습니다.</p>') }
    $hidden = if ($index -eq 0) { '' } else { ' hidden' }
    $panelHtml.Add('<section class="file-panel" role="tabpanel" id="' + $panelId + '" aria-labelledby="' + $tabId + '"' + $hidden + '>' + [Environment]::NewLine + ($rows -join [Environment]::NewLine) + [Environment]::NewLine + '</section>')
}

$displayTitle = $folderName -replace '^(?:\d{8}|\d{2}(?:-\d{2})*)_', ''
$refreshPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($resolvedWork)).TrimEnd('=').Replace('+','-').Replace('/','_')
$refreshUri = [string]$config.openProtocol + '://refresh/' + $refreshPayload
$template = @'
<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="referrer" content="no-referrer">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline' file:">
  <title>@@TITLE@@</title>
  <style>
    :root { color-scheme: light dark; --bg:#edf8ff; --surface:#fff; --soft:#dff2ff; --text:#17394e; --muted:#58788a; --line:#b9def2; --accent:#087bad; --hover:#eef9ff; --review-bg:#fff7df; --review-line:#d88708; --review-text:#573900; font-family:"Malgun Gothic","Apple SD Gothic Neo","Segoe UI",sans-serif; font-size:16px; }
    * { box-sizing:border-box; } body { margin:0; min-width:280px; background:var(--bg); color:var(--text); }
    .shell { width:min(1100px,calc(100% - 32px)); margin:24px auto; background:var(--surface); border:1px solid var(--line); border-radius:14px; overflow:hidden; box-shadow:0 12px 36px rgb(28 100 137 / 10%); }
    header { padding:22px 26px; border-bottom:1px solid var(--line); } h1 { margin:0; font-size:clamp(1.15rem,3vw,1.45rem); line-height:1.35; overflow-wrap:anywhere; }
    .home-banner { display:flex; align-items:center; justify-content:space-between; gap:14px; margin:-10px; padding:10px; border-radius:10px; color:inherit; text-decoration:none; cursor:pointer; }
    .home-banner:hover { background:var(--hover); color:var(--accent); } .home-banner[aria-disabled="true"] { opacity:.65; cursor:wait; }
    .home-banner:focus-visible { outline:3px solid var(--accent); outline-offset:2px; }
    .refresh-hint { flex:0 0 auto; color:var(--muted); font-size:.82rem; font-weight:700; }
    .action-help { margin:10px 0 0; font-size:.84rem; line-height:1.5; color:var(--muted); overflow-wrap:anywhere; }
    [role="tablist"] { display:flex; flex-wrap:wrap; gap:6px; padding:12px 18px 0; background:var(--soft); border-bottom:1px solid var(--line); }
    [role="tab"] { min-height:44px; padding:10px 16px; border:1px solid transparent; border-bottom:0; border-radius:9px 9px 0 0; background:transparent; color:var(--muted); font:inherit; font-weight:700; cursor:pointer; overflow-wrap:anywhere; }
    [role="tab"][aria-selected="true"] { background:var(--surface); border-color:var(--line); color:var(--text); box-shadow:inset 0 -3px 0 var(--accent); }
    [role="tab"]:hover { color:var(--accent); } [role="tab"]:focus-visible,summary:focus-visible,.file-link:focus-visible { outline:3px solid color-mix(in srgb,var(--accent) 50%,transparent); outline-offset:2px; }
    .file-panel { padding:10px 26px 22px; } .file-panel[hidden] { display:none; } .overview { margin:4px 0 12px; border-bottom:1px solid var(--line); } .review-overview { margin-top:14px; border-top:1px solid var(--line); border-bottom:0; }
    .review-request { margin:10px 0 16px; border:1px solid color-mix(in srgb,var(--review-line) 50%,var(--line)); border-left:5px solid var(--review-line); border-radius:12px; background:var(--review-bg); color:var(--review-text); box-shadow:0 5px 16px color-mix(in srgb,var(--review-line) 12%,transparent); }
    .review-request summary { display:flex; align-items:center; gap:9px; min-height:52px; padding:13px 16px; cursor:pointer; list-style:none; }
    .review-request summary .chevron { margin-left:auto; color:var(--review-line); background:color-mix(in srgb,var(--review-bg) 70%,var(--surface)); }
    .review-badge { display:inline-grid; place-items:center; width:24px; height:24px; border-radius:999px; background:var(--review-line); color:#fff; font-weight:900; }
    .review-copy { margin:0 16px 16px; padding:14px 16px; border-left:3px solid var(--review-line); background:color-mix(in srgb,var(--review-bg) 78%,var(--surface)); white-space:pre-wrap; overflow-wrap:anywhere; line-height:1.65; font-weight:600; }
    .meta-block summary,.text-file summary { display:flex; align-items:center; gap:11px; min-height:48px; padding:13px 2px; cursor:pointer; list-style:none; font-weight:700; overflow-wrap:anywhere; }
    summary::-webkit-details-marker { display:none; } summary:hover { color:var(--accent); background:var(--hover); }
    .chevron { display:inline-grid; place-items:center; flex:0 0 24px; width:24px; height:24px; border:1px solid var(--line); border-radius:999px; background:var(--soft); color:var(--accent); transition:background .14s ease,border-color .14s ease; }
    .chevron::before { content:""; display:block; width:7px; height:7px; border-right:2px solid currentColor; border-bottom:2px solid currentColor; transform:rotate(-45deg); transition:transform .16s ease; }
    details[open] > summary .chevron { background:var(--accent); border-color:var(--accent); color:var(--surface); }
    details[open] > summary .chevron::before { transform:rotate(45deg); }
    dl { display:grid; grid-template-columns:max-content 1fr; gap:8px 16px; margin:0 0 16px 22px; padding:14px 16px; border-left:3px solid var(--line); background:var(--hover); } dt { color:var(--muted); font-weight:700; } dd { margin:0; overflow-wrap:anywhere; }
    .source-group { margin:14px 0 22px; border:1px solid var(--line); border-radius:12px; overflow:hidden; background:var(--surface); } .source-group h2 { margin:0; padding:13px 16px 8px; border-bottom:1px solid var(--line); font-size:1rem; overflow-wrap:anywhere; }
    .file-link,.text-file,.missing-file { border-bottom:1px solid var(--line); } .file-link,.missing-file { display:flex; align-items:flex-start; gap:9px; min-height:52px; padding:15px 12px; color:var(--accent); text-decoration-thickness:1px; text-underline-offset:4px; overflow-wrap:anywhere; }
    .file-mark { flex:0 0 auto; }
    .missing-file { color:var(--muted); }
    .console-table-scroll { overflow-x:auto; margin:14px 0; } .console-report-table { width:100%; min-width:640px; border-collapse:collapse; font-size:.94rem; } .console-report-table caption { text-align:left; font-weight:700; padding:10px 0; } .console-report-table th,.console-report-table td { border:1px solid var(--line); padding:11px 13px; text-align:left; vertical-align:top; white-space:pre-wrap; line-height:1.65; overflow-wrap:anywhere; } .console-report-table th { background:#edf2f7; color:#24344a; } .console-report-table tbody tr:nth-child(even) { background:#f8fafc; }
    .copy-message-text { margin-top:16px; line-height:1.85; overflow-wrap:anywhere; } .copy-message-text strong { font-weight:700; } .message-copy-status { margin-left:12px; }
    .console-content { padding:18px 0; border-bottom:1px solid var(--line); } .console-content h2 { font-size:1.1rem; } .console-content-body { white-space:pre-wrap; overflow-wrap:anywhere; line-height:1.8; }
    .workflow-list { list-style:none; margin:8px 0; padding:0; }
    .workflow-toolbar { display:flex; align-items:center; gap:14px; padding:16px 0 0; font-size:.85rem; }
    .workflow-toolbar button { border:1px solid var(--line); background:var(--hover); color:var(--text); border-radius:7px; padding:8px 12px; font:inherit; cursor:pointer; }
    .workflow-storage { font-size:.75rem; color:var(--muted); }
    .workflow-check { display:flex; align-items:flex-start; gap:10px; padding:7px 0; line-height:1.7; cursor:pointer; }
    .workflow-check input { width:19px; height:19px; flex-shrink:0; margin-top:4px; accent-color:var(--accent); }
    .workflow-check:has(input:checked) span { color:var(--muted); text-decoration:line-through; }
    .workflow-step.is-complete { opacity:.6; }
    .workflow-step.is-current { border-left:3px solid var(--accent); padding-left:16px; }
    .step-progress { color:var(--muted); font-size:.78rem; font-weight:400; margin-left:8px; }
    .workflow-references { margin-top:16px; font-size:.88rem; }
    .workflow-references .file-link { min-height:0; padding:9px 8px; }
    .workflow-confirm { line-height:1.7; white-space:pre-wrap; padding:10px 14px; border-left:3px solid var(--review-line); background:var(--review-bg); color:var(--review-text); }
    .workflow-step { padding:20px 0 22px; border-bottom:1px solid var(--line); }
    .workflow-step:last-child { border-bottom:0; }
    .workflow-step h2 { margin:0; font-size:1.08rem; line-height:1.5; overflow-wrap:anywhere; }
    .workflow-basis { margin:5px 0 12px; font-size:.82rem; color:var(--muted); }
    .workflow-action { white-space:pre-wrap; overflow-wrap:anywhere; line-height:1.85; }
    .workflow-legacy { padding:18px 0; }
    .workflow-result { padding:10px 14px; margin:14px 0 0; background:var(--hover); line-height:1.7; white-space:pre-wrap; overflow-wrap:anywhere; }
    .workflow-result strong { margin-right:8px; }
    .workflow-evidence { margin-top:12px; font-size:.85rem; line-height:1.65; color:var(--muted); overflow-wrap:anywhere; }
    .workflow-evidence summary { cursor:pointer; width:fit-content; }
    .workflow-evidence p { white-space:pre-wrap; }
    .intake-footer { padding:8px 26px 16px; text-align:right; font-size:.72rem; color:#91979d; }
    .file-link:hover { background:var(--hover); } .text-file summary { font-weight:600; } .text-body { margin:0 0 16px 22px; padding:14px 16px; border-left:3px solid var(--line); background:var(--hover); }
    pre { margin:0; color:var(--text); font:inherit; white-space:pre-wrap; overflow-wrap:anywhere; } .notice,.empty { color:var(--muted); overflow-wrap:anywhere; }
    @media (prefers-color-scheme: dark) { :root { --bg:#10222d; --surface:#172f3c; --soft:#1c3a49; --text:#ecf8ff; --muted:#aac5d3; --line:#365d70; --accent:#79d2fa; --hover:#203f4e; --review-bg:#3d321b; --review-line:#f0b34a; --review-text:#fff2cf; } .shell { box-shadow:0 12px 36px rgb(0 0 0 / 28%); } }
    @media (max-width: 520px) { .shell { width:100%; min-height:100vh; margin:0; border:0; border-radius:0; } header { padding:18px; } [role="tablist"] { padding:10px; } [role="tab"] { flex:1 1 auto; border:1px solid var(--line); border-radius:8px; padding:9px 11px; } [role="tab"][aria-selected="true"] { border-color:var(--accent); } .file-panel { padding:8px 18px 18px; } .text-body,dl { margin-left:12px; padding:12px; } .review-copy { margin:0 12px 12px; padding:12px; } dl { grid-template-columns:1fr; gap:3px; } dd { margin-bottom:8px; } }
    @media (prefers-reduced-motion: reduce) { .chevron,.chevron::before { transition:none; } }
  </style>
</head>
<body>
  <main class="shell">
    <header><a class="home-banner" id="refresh-console" href="@@REFRESH_URI@@" title="업무폴더를 다시 읽어 최신 목록으로 갱신"><h1>@@HEADING@@</h1><span class="refresh-hint"><span aria-hidden="true">↻</span> 제목 또는 F5로 갱신</span></a><p class="action-help" id="console-action-status" role="status" aria-live="polite">파일명을 누르면 연결된 프로그램으로 엽니다. 업무 설명과 확인사항은 이 화면에서 확인할 수 있습니다.</p></header>
    <nav role="tablist" aria-label="업무폴더">@@TABS@@</nav>
    @@PANELS@@
    @@INTAKE_FOOTER@@
  </main>
  <script>
    (() => {
      document.querySelectorAll('[data-copy-message]').forEach(button => {
        button.addEventListener('click', () => {
          const box = document.getElementById(button.dataset.copyMessage);
          const selection = window.getSelection();
          const range = document.createRange(); range.selectNodeContents(box);
          selection.removeAllRanges(); selection.addRange(range);
          const plain = box.innerHTML.replace(/<br\s*\/?\s*>/gi, '\n');
          const decoder = document.createElement('div'); decoder.innerHTML = plain;
          const onCopy = event => {
            event.preventDefault();
            event.clipboardData.setData('text/plain', decoder.textContent.replace(/\n/g, '\r\n'));
            event.clipboardData.setData('text/html', '<div>' + box.innerHTML + '</div>');
          };
          document.addEventListener('copy', onCopy);
          let ok = false;
          try { ok = document.execCommand('copy'); } finally { document.removeEventListener('copy', onCopy); }
          button.nextElementSibling.textContent = ok ? '복사했습니다.' : '선택된 내용을 Ctrl+C로 복사해 주세요.';
          if (ok) selection.removeAllRanges();
        });
      });
      const refresh = document.getElementById('refresh-console');
      const status = document.getElementById('console-action-status');
      const refreshBase = refresh.getAttribute('href');
      let refreshPending = false;
      // Poll only a tiny completion marker following a title click or F5 gesture.
      // No directory watching, local server, or permanent background timer.
      const beginRefresh = event => {
        if (event.button!==0||event.ctrlKey||event.metaKey||event.shiftKey||event.altKey)return;
        if (refreshPending) { event.preventDefault(); return; }
        if (location.protocol !== 'file:') {
          event.preventDefault();
          status.textContent = '업무폴더의 업무현황.html을 Edge 또는 Chrome에서 직접 열어 주세요.';
          return;
        }
        const bytes = new Uint8Array(16); crypto.getRandomValues(bytes);
        const requestId = Array.from(bytes, b => b.toString(16).padStart(2,'0')).join('');
        refresh.href = refreshBase + '/' + requestId;
        refreshPending = true; refresh.setAttribute('aria-disabled','true');
        window.__hwpxConsoleRefresh = null;
        status.textContent = '업무폴더를 다시 읽고 있습니다.';
        // The anchor's default action preserves the browser's external-app gesture.
        const started = Date.now();
        const finish = message => { refreshPending=false; refresh.removeAttribute('aria-disabled'); refresh.href=refreshBase; status.textContent=message; };
        const poll = () => {
          if (Date.now() - started > 30000) { finish('목록 갱신 응답을 받지 못했습니다. 이 화면의 기존 내용은 유지됩니다. 요청 코드: ' + requestId + ''); return; }
          const marker = document.createElement('script');
          marker.src = '.ai/console-refresh.js?request=' + requestId + '&t=' + Date.now();
          const check = () => {
            marker.remove();
            const result = window.__hwpxConsoleRefresh;
            if (result && result.requestId === requestId) {
              if (result.ok) {
                status.textContent='갱신 완료. 최신 목록을 불러옵니다.';
                const next = new URL(location.href);
                next.searchParams.set('refresh',requestId);
                location.replace(next.href);
              }
              else { finish('목록 갱신에 실패했습니다. 업무폴더 접근 상태를 확인해 주세요.'); }
              return;
            }
            setTimeout(poll,150);
          };
          marker.onload=check; marker.onerror=check; document.head.appendChild(marker);
        };
        setTimeout(poll,150);
      };
      refresh.addEventListener('click', beginRefresh);
      refresh.addEventListener('keydown', event => { if (event.key === ' ') { event.preventDefault(); refresh.click(); } });
      document.addEventListener('keydown', event => { if (event.key === 'F5') { event.preventDefault(); refresh.click(); } });
      // Keep the browser's native anchor navigation in the user's click gesture.
      // Only update its nonce here; replacing navigation with location.href can be
      // handled differently by an external-protocol browser policy.
      // The receipt proves Windows dispatch, not completion of application startup.
      let openGeneration=0;
      for (const link of document.querySelectorAll('a.file-link')) {
        const openBase=link.getAttribute('href');
        link.addEventListener('click', event => {
          if(event.button!==0||event.ctrlKey||event.metaKey||event.shiftKey||event.altKey)return;
          if(location.protocol!=='file:'){
            event.preventDefault();
            status.textContent='업무폴더의 업무현황.html을 Edge 또는 Chrome에서 직접 열어 주세요.';
            return;
          }
          const bytes=new Uint8Array(16);crypto.getRandomValues(bytes);
          const requestId=Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');
          const generation=++openGeneration;
          link.href=openBase+'/'+requestId;
          window.__hwpxConsoleOpen=null;
          status.textContent='파일 열기를 요청했습니다. Windows 응답을 확인하고 있습니다.';
          const started=Date.now();
          const complete=message=>{if(generation===openGeneration){link.href=openBase;status.textContent=message;}};
          const pollOpen=()=>{
            if(generation!==openGeneration)return;
            if(Date.now()-started>15000){complete('파일 실행기의 응답을 받지 못했습니다. 파일을 열었다고 확인할 수 없습니다. 요청 코드: '+requestId+'');return;}
            const marker=document.createElement('script');
            marker.src='.ai/console-open-'+requestId+'.js?t='+Date.now();
            const check=()=>{
              marker.remove();const result=window.__hwpxConsoleOpen;
              if(generation!==openGeneration)return;
              if(result&&result.requestId===requestId){complete(result.ok?'Windows가 파일 열기 요청을 받았습니다. 문서가 실제로 열렸는지는 프로그램에서 확인해야 합니다.':'파일 실행에 실패했습니다. 오류: '+(result.code||result.exitCode||'unknown')+' · 단계: '+(result.stage||'unknown')+' · 요청 코드: '+requestId);return;}
              setTimeout(pollOpen,250);
            };
            marker.onload=check;marker.onerror=check;document.head.appendChild(marker);
          };
          setTimeout(pollOpen,250);
        });
      }
      const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
      const selectTab = (tab, focus) => {
        for (const item of tabs) { const active = item === tab; item.setAttribute('aria-selected', String(active)); item.tabIndex = active ? 0 : -1; document.getElementById(item.getAttribute('aria-controls')).hidden = !active; }
        if (focus) tab.focus();
      };
      for (const tab of tabs) tab.addEventListener('click', () => { selectTab(tab, false); location.hash=tab.id; });
      const restoredTab=tabs.find(tab=>'#'+tab.id===location.hash);
      if(restoredTab)selectTab(restoredTab,false);
      // WORKFLOW_CHECKLIST_BEGIN
      const workflowSteps=Array.from(document.querySelectorAll('.workflow-step'));
      const workflowChecks=Array.from(document.querySelectorAll('[data-work-check]'));
      if(workflowChecks.length){
        const storageKey='hwpx-workflow-v1:'+location.pathname;
        const storageNote=document.getElementById('workflow-storage');
        let saved={};
        const storageFailure=()=>{storageNote.textContent='체크 상태를 저장할 수 없습니다. 이 창을 닫으면 체크가 사라질 수 있습니다.';};
        try { const parsed=JSON.parse(localStorage.getItem(storageKey)||'{}'); if(parsed&&typeof parsed==='object'&&!Array.isArray(parsed))saved=parsed; } catch { storageFailure(); }
        for(const box of workflowChecks)box.checked=saved[box.getAttribute('data-work-check')]===true;
        const updateWorkflow=()=>{
          let first=null,complete=0;
          for(const step of workflowSteps){
            const boxes=Array.from(step.querySelectorAll('[data-work-check]'));
            const count=boxes.filter(box=>box.checked).length;
            const done=boxes.length>0&&count===boxes.length;
            step.classList.toggle('is-complete',done);
            step.classList.remove('is-current');
            step.querySelector('.step-progress').textContent=count+'/'+boxes.length+(done?' · 완료':'');
            if(done)complete++;else if(!first)first=step;
          }
          if(first)first.classList.add('is-current');
          document.getElementById('workflow-progress').textContent=complete===workflowSteps.length?'모든 단계를 완료했습니다.':complete+'/'+workflowSteps.length+'단계 완료';
          return first;
        };
        const resumeWorkflow=()=>{
          const first=updateWorkflow();
          if(first)first.scrollIntoView({block:'start',behavior:'auto'});
        };
        for(const box of workflowChecks)box.addEventListener('change',()=>{
          // Store booleans only. No completion date and no scrolling on a check.
          const state={};for(const item of workflowChecks)state[item.getAttribute('data-work-check')]=item.checked;
          try{localStorage.setItem(storageKey,JSON.stringify(state));}catch{storageFailure();}
          updateWorkflow();
        });
        document.getElementById('workflow-resume').addEventListener('click',resumeWorkflow);
        updateWorkflow();
        if(!document.getElementById('work-panel-0').hidden)requestAnimationFrame(resumeWorkflow);
      }
      // WORKFLOW_CHECKLIST_END
      document.querySelector('[role="tablist"]').addEventListener('keydown', event => {
        const index = tabs.indexOf(event.target); if (index < 0) return; let next = null;
        if (event.key === 'ArrowRight') next = (index + 1) % tabs.length; if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length; if (event.key === 'Home') next = 0; if (event.key === 'End') next = tabs.length - 1;
        if (next === null) return; event.preventDefault(); selectTab(tabs[next], true);
      });
    })();
  </script>
</body>
</html>
'@

$html = $template.Replace('@@TITLE@@',(Encode-Html ($displayTitle + ' - 업무현황'))).Replace('@@HEADING@@',(Encode-Html $displayTitle)).Replace('@@REFRESH_URI@@',(Encode-Html $refreshUri)).Replace('@@TABS@@',($tabHtml -join [Environment]::NewLine)).Replace('@@PANELS@@',($panelHtml -join [Environment]::NewLine)).Replace('@@INTAKE_FOOTER@@',(New-IntakeFooterHtml))
# BEGIN EXAM COMMON RECORD V1
# Enabled work folders render the canonical record in the existing console.
# Other work folders keep the legacy renderer and its storage keys unchanged.
if ($workMetadata.commonRecord -and $workMetadata.commonRecord.enabled -eq $true) {
    if ($workMetadata.commonRecord.schemaVersion -ne 'exam-workspace/v1') { throw 'Unsupported common record marker schema.' }
    $examRecordPath = Join-Path $metadataRoot 'exam-record.json'
    $examTemplatePath = Join-Path $metadataRoot 'exam-system\template.html'
    foreach ($requiredPath in @($examRecordPath, $examTemplatePath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Common record input is missing: $requiredPath" }
        $cursor = Get-Item -LiteralPath $requiredPath -Force
        while ($null -ne $cursor -and $cursor.FullName.TrimEnd('\') -ine $resolvedWork.TrimEnd('\')) {
            if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Common record input cannot be a reparse point: $requiredPath" }
            $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
        }
    }
    $examRecord = Get-Content -LiteralPath $examRecordPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($examRecord.schemaVersion -ne 'exam-workspace/v1') { throw 'Canonical common record has an unsupported or missing schemaVersion.' }
    $examTemplate = [IO.File]::ReadAllText($examTemplatePath, [Text.Encoding]::UTF8)
    foreach ($token in @('__EXAM_RECORD_JSON__','__EXAM_FILE_LIST_JSON__')) {
        if (([regex]::Matches($examTemplate, [regex]::Escape($token))).Count -ne 1) { throw "Common record template must contain exactly one $token token." }
    }
    # Matches the deployed native helper. Never expose executable/script targets.
    $examExtensions = @('.hwp','.hwpx','.hwt','.hwtx','.pdf','.doc','.docx','.xls','.xlsx','.xlsm','.odt','.mp3','.ppt','.pptx','.csv','.txt','.png','.jpg','.jpeg','.gif','.bmp','.webp','.htm','.html','.md','.zip')
    $examCandidates = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($target in @($script:openTargets)) { [void]$examCandidates.Add($target) }
    foreach ($tab in $tabDefinitions) {
        foreach ($file in @($tab.Files)) { if ($file) { [void]$examCandidates.Add($file.FullName) } }
    }
    $script:openTargets.Clear()
    $examFiles = [Collections.Generic.List[object]]::new()
    foreach ($candidate in @($examCandidates | Sort-Object)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $file = Get-Item -LiteralPath $candidate -Force
        if ((Test-HiddenItem $file) -or (Test-SecretText $file.FullName) -or $examExtensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
        if ($file.FullName -ieq $resolvedOutput) { continue }
        if ($config.portableCabinet -and -not $file.FullName.StartsWith($cabinet.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = Get-RelativePathCompat $resolvedWork $file.FullName
        $isLocal = $file.FullName.StartsWith($resolvedWork.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        $group = if (-not $isLocal) { '업무근거' } elseif ($relative.Contains('\')) { $relative.Split('\')[0] } else { '주요 문서' }
        $examFiles.Add([ordered]@{
            path = $file.FullName
            name = $file.Name
            relativePath = $relative
            group = $group
            uri = Get-DirectOpenUri $file.FullName
            size = $file.Length
            modifiedAt = $file.LastWriteTime.ToString('o')
            archived = (Test-RevisionFile $file.FullName)
        })
    }
    # JSON is data inside a script element; escape HTML boundaries and JS separators.
    function ConvertTo-ExamEmbeddedJson($Value) {
        $json = ConvertTo-Json -InputObject $Value -Depth 100 -Compress
        $json.Replace('&','\u0026').Replace('<','\u003c').Replace('>','\u003e').Replace([string][char]0x2028,'\u2028').Replace([string][char]0x2029,'\u2029')
    }
    $examRecordJson = ConvertTo-ExamEmbeddedJson $examRecord
    $examFileListJson = ConvertTo-ExamEmbeddedJson @($examFiles.ToArray())
    $html = $examTemplate.Replace('__EXAM_RECORD_JSON__', $examRecordJson).Replace('__EXAM_FILE_LIST_JSON__', $examFileListJson)
    # Optional metadata token supports the existing native refresh acknowledgement.
    $examConsoleJson = ConvertTo-ExamEmbeddedJson ([ordered]@{
        workFolder = $resolvedWork
        recordPath = $examRecordPath
        refreshUri = $refreshUri
        generatedAt = (Get-Date -Format 'o')
        unregisteredRootFileCount = $unexpectedRootNames.Count
        missingRegisteredFileCount = $missingRootNames.Count
    })
    $html = $html.Replace('__EXAM_CONSOLE_JSON__', $examConsoleJson)
    $script:fileLinkCount = $examFiles.Count
    $script:textToggleCount = 0
}
# END EXAM COMMON RECORD V1
function Save-ConsoleHtml {
    $tempPath = Join-Path $resolvedWork ('.console-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($tempPath, $html, [Text.UTF8Encoding]::new($false))
        Move-FileOverwrite $tempPath $resolvedOutput
    } finally {
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
}

$configuredCabinet = [IO.Path]::GetFullPath([string]$config.humanCabinet).TrimEnd('\')
if ($cabinet.TrimEnd('\').Equals($configuredCabinet, [StringComparison]::OrdinalIgnoreCase)) {
    $manifestPath = [IO.Path]::GetFullPath((Join-Path $workspace ([string]$config.openTargetManifest)))
    $manifestParent = [IO.Path]::GetDirectoryName($manifestPath)
    New-Item -ItemType Directory -Path $manifestParent -Force | Out-Null
    $mutex = [Threading.Mutex]::new($false, 'Local\HwpxHumanOpenTargets')
    $lockTaken = $false
    try {
        try { $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(15)) } catch [Threading.AbandonedMutexException] { $lockTaken = $true }
        if (-not $lockTaken) { throw 'Timed out while updating the trusted direct-open target list.' }
        $previous = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            Get-Content -Raw -Encoding utf8 -LiteralPath $manifestPath | ConvertFrom-Json
        } else { $null }
        $entries = [Collections.Generic.List[object]]::new()
        foreach ($entry in @($previous.workFolders)) {
            if (-not $entry.workFolder) { continue }
            $entryRoot = [IO.Path]::GetFullPath([string]$entry.workFolder)
            if ($entryRoot.Equals($resolvedWork, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (Test-Path -LiteralPath $entryRoot -PathType Container) { $entries.Add($entry) }
        }
        $entries.Add([ordered]@{
            workFolder = $resolvedWork
            console = $resolvedOutput
            generatedAt = Get-Date -Format 'o'
            targets = @($script:openTargets | Sort-Object)
        })
        $manifest = [ordered]@{
            schemaVersion = 'hwpx-human-open-targets/v1'
            generatedAt = Get-Date -Format 'o'
            workFolders = @($entries)
        }
        $manifestTemp = Join-Path $manifestParent ('.human-open-targets-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $oldManifest = if ([IO.File]::Exists($manifestPath)) { [IO.File]::ReadAllBytes($manifestPath) } else { $null }
        $oldHtml = if ([IO.File]::Exists($resolvedOutput)) { [IO.File]::ReadAllBytes($resolvedOutput) } else { $null }
        $changed = $false
        try {
            [IO.File]::WriteAllText($manifestTemp, ($manifest | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
            # Native readers must never see partially overwritten JSON.
            $changed = $true
            if ([IO.File]::Exists($manifestPath)) { [IO.File]::Replace($manifestTemp, $manifestPath, [NullString]::Value) }
            else { [IO.File]::Move($manifestTemp, $manifestPath) }
            Save-ConsoleHtml
        } catch {
            if ($changed) {
                if ($null -ne $oldManifest) {
                    [IO.File]::WriteAllBytes($manifestTemp, $oldManifest)
                    if ([IO.File]::Exists($manifestPath)) { [IO.File]::Replace($manifestTemp, $manifestPath, [NullString]::Value) }
                    else { [IO.File]::Move($manifestTemp, $manifestPath) }
                } elseif ([IO.File]::Exists($manifestPath)) { [IO.File]::Delete($manifestPath) }
                if ($null -ne $oldHtml) { [IO.File]::WriteAllBytes($resolvedOutput, $oldHtml) }
                elseif ([IO.File]::Exists($resolvedOutput)) { [IO.File]::Delete($resolvedOutput) }
            }
            throw
        } finally {
            if (Test-Path -LiteralPath $manifestTemp -PathType Leaf) { Remove-Item -LiteralPath $manifestTemp -Force -ErrorAction SilentlyContinue }
        }
    } finally {
        if ($lockTaken) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
} else { Save-ConsoleHtml }

[ordered]@{
    schemaVersion = 'hwpx-human-console/v5'
    generatedAt = Get-Date -Format 'o'
    workFolder = $resolvedWork
    output = $resolvedOutput
    tabs = @($tabDefinitions | ForEach-Object Label)
    textToggleCount = $script:textToggleCount
    fileLinkCount = $script:fileLinkCount
    directOpenTargetCount = $script:openTargets.Count
    privacyOmittedCount = $script:privacyOmittedCount
    unregisteredRootFileCount = $unexpectedRootNames.Count
    missingRegisteredFileCount = $missingRootNames.Count
    metadataSource = $workMetadataPath
} | ConvertTo-Json -Depth 5
