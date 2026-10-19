[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$JobPath,
      [ValidateSet('format_edit','visual_review','edit_plan')][string]$Capability='edit_plan',
      [string]$PlanPath='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DocumentScope.ps1')
$activeScope = Get-ActiveDocumentScope $JobPath
$capacity = [ordered]@{sourceChecked=$false;checkedCells=0;skippedCells=0}
if ($Capability -ne 'edit_plan') {
    Assert-DocumentCapability $JobPath $Capability | Out-Null
} else {
    if (-not $PlanPath) { throw 'Edit-plan scope check requires PlanPath.' }
    $plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding utf8 | ConvertFrom-Json
    # Match the tested upstream vocabulary, including nested argument contracts.
    # Unknown keys require scope even when the current engine would ignore them.
    function Test-OnlyDocumentKeys($Value, [string[]]$AllowedKeys) {
        if ($null -eq $Value) { return $false }
        if ($Value -is [Collections.IDictionary]) { $keys = @($Value.Keys) }
        elseif ($Value -is [Management.Automation.PSCustomObject]) { $keys = @($Value.PSObject.Properties.Name) }
        else { return $false }
        return @($keys | Where-Object { $_ -cnotin $AllowedKeys }).Count -eq 0
    }
    function Test-TextDocumentRecord($Value, [string[]]$AllowedKeys, [switch]$Cell) {
        if (-not (Test-OnlyDocumentKeys $Value $AllowedKeys)) { return $false }
        foreach ($property in @($Value.PSObject.Properties)) {
            if ($Cell -and $property.Name -cin @('cell_anchor','cellAnchor')) {
                if (-not (Test-TextDocumentRecord $property.Value @('label','dir','direction'))) { return $false }
            } elseif ($property.Value -is [Management.Automation.PSCustomObject] -or
                      $property.Value -is [Collections.IDictionary] -or
                      ($property.Value -is [Collections.IEnumerable] -and $property.Value -isnot [string])) {
                return $false
            }
        }
        return $true
    }
    $sectionKeys = @('section_path','sectionPath')
    $cellKeys = $sectionKeys + @('table_index','tableIndex','row','col','text','table_anchor','tableAnchor','cell_anchor','cellAnchor')
    $needsFormat = $false
    foreach ($step in @($plan.steps)) {
        if (-not (Test-OnlyDocumentKeys $step @('id','op','args'))) { $needsFormat = $true }
        switch -CaseSensitive ($step.op) {
            'paragraph_patch' {
                if (-not (Test-OnlyDocumentKeys $step.args @('patches'))) { $needsFormat = $true }
                foreach ($patch in @($step.args.patches)) {
                    if (-not (Test-TextDocumentRecord $patch ($sectionKeys + @('paragraph_index','paragraphIndex','text')))) { $needsFormat = $true }
                }
            }
            'fill_cells' {
                # fit_max_lines/min_font_pt and cell max_lines/maxLines can shrink
                # fonts, so they are excluded from content-only argument keys.
                if (-not (Test-OnlyDocumentKeys $step.args @('cells'))) { $needsFormat = $true }
                foreach ($cell in @($step.args.cells)) {
                    if (-not (Test-TextDocumentRecord $cell $cellKeys -Cell)) { $needsFormat = $true }
                }
            }
            'apply_body_ops' {
                if (-not (Test-OnlyDocumentKeys $step.args @('ops'))) { $needsFormat = $true }
                foreach ($op in @($step.args.ops)) {
                    $allowedKeys = switch -CaseSensitive ($op.op) {
                        'replace_text' { $sectionKeys + @('op','find','replace','count') }
                        'set_paragraph_text' { $sectionKeys + @('op','index','text') }
                        default { @() }
                    }
                    if (-not $allowedKeys -or -not (Test-TextDocumentRecord $op $allowedKeys)) { $needsFormat = $true }
                }
            }
            'apply_table_ops' {
                if (-not (Test-OnlyDocumentKeys $step.args @('ops'))) { $needsFormat = $true }
                foreach ($op in @($step.args.ops)) {
                    if ($op.op -cne 'fill_cell' -or -not (Test-TextDocumentRecord $op ($cellKeys + @('op')) -Cell)) { $needsFormat = $true }
                }
            }
            default { $needsFormat = $true }
        }
    }
    if ($needsFormat) { Assert-DocumentCapability $JobPath 'format_edit' | Out-Null }
    # Read only: prevent the upstream filler from silently discarding lines
    # beyond the template cell's existing paragraph slots. Anchors are resolved
    # by upstream and require its output checks; this guard checks coordinates.
    if (-not ($activeScope -and $activeScope.formatEditAllowed) -and $plan.source -and (Test-Path -LiteralPath $plan.source -PathType Leaf)) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath([string]$plan.source))
        $capacity.sourceChecked = $true
        $sections = @{}
        try {
            $fills = @(foreach ($step in @($plan.steps)) {
                if ($step.op -ceq 'fill_cells') { $step.args.cells }
                elseif ($step.op -ceq 'apply_table_ops') { @($step.args.ops | Where-Object op -CEQ 'fill_cell') }
            })
            foreach ($cell in $fills) {
                $ti = if ($null -ne $cell.table_index) { $cell.table_index } else { $cell.tableIndex }
                if ($null -eq $ti -or $null -eq $cell.row -or $null -eq $cell.col -or $cell.table_anchor -or $cell.tableAnchor -or $cell.cell_anchor -or $cell.cellAnchor) { $capacity.skippedCells++; continue }
                $section = if ($cell.section_path) { [string]$cell.section_path } elseif ($cell.sectionPath) { [string]$cell.sectionPath } else { 'Contents/section0.xml' }
                if (-not $sections.ContainsKey($section)) {
                    $entry = $archive.GetEntry($section)
                    if (-not $entry) { throw "Template capacity target section not found: $section" }
                    $settings = New-Object Xml.XmlReaderSettings
                    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
                    $settings.XmlResolver = $null
                    $stream = $entry.Open(); $reader = [Xml.XmlReader]::Create($stream,$settings)
                    try { $xml = New-Object Xml.XmlDocument; $xml.XmlResolver=$null; $xml.Load($reader) } finally { $reader.Dispose(); $stream.Dispose() }
                    $sections[$section] = $xml
                }
                $xml = $sections[$section]
                $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
                $ns.AddNamespace('hp','http://www.hancom.co.kr/hwpml/2011/paragraph')
                $tables = $xml.SelectNodes('//hp:tbl',$ns)
                if ([int]$ti -lt 0 -or [int]$ti -ge $tables.Count) { throw 'Template capacity target table not found.' }
                $target = @($tables[[int]$ti].SelectNodes('hp:tr/hp:tc',$ns) | Where-Object {
                    $addr=$_.SelectSingleNode('hp:cellAddr',$ns); $span=$_.SelectSingleNode('hp:cellSpan',$ns)
                    $rs=1; $cs=1; if($span){$rs=[Math]::Max(1,[int]$span.GetAttribute('rowSpan'));$cs=[Math]::Max(1,[int]$span.GetAttribute('colSpan'))}
                    $addr -and [int]$cell.row -ge [int]$addr.GetAttribute('rowAddr') -and [int]$cell.row -lt ([int]$addr.GetAttribute('rowAddr')+$rs) -and [int]$cell.col -ge [int]$addr.GetAttribute('colAddr') -and [int]$cell.col -lt ([int]$addr.GetAttribute('colAddr')+$cs)
                })
                if ($target.Count -ne 1) { throw 'Template capacity cell coordinates are missing or ambiguous.' }
                $slots = $target[0].SelectNodes('hp:subList/hp:p',$ns).Count
                $lines = ([string]$cell.text).Split([char]10).Count
                if ($lines -gt $slots) { throw "Template cell capacity exceeded: $section table $ti cell ($($cell.row),$($cell.col)) accepts $slots paragraph lines, received $lines. Keep all content; revise the text or request a template change. No auto truncate." }
                $capacity.checkedCells++
            }
        } finally { $archive.Dispose() }
    }
}
[ordered]@{ok=$true;capability=$Capability;templateCapacity=$capacity} | ConvertTo-Json -Compress
