[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Path)

# Read-only package reopen; this is not a Hancom application/render receipt.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($Path)
try {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $xmlMembers = @{}
    foreach ($entry in $archive.Entries) {
        if (-not $names.Add($entry.FullName)) { throw 'Duplicate package member.' }
        if ($entry.FullName -match '(^/|\\|(?:^|/)\.\.(?:/|$))') { throw 'Unsafe package member path.' }
        if ($entry.FullName -notmatch '\.(xml|hpf)$') { continue }
        if ($entry.Length -gt 64MB) { throw 'XML member exceeds bounded validation limit.' }
        $stream = $entry.Open()
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.MaxCharactersInDocument = 64MB
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        try {
            $doc = [Xml.XmlDocument]::new()
            $doc.XmlResolver = $null
            $doc.Load($reader)
            $xmlMembers[$entry.FullName] = $doc
        } finally { $reader.Dispose(); $stream.Dispose() }
    }
    foreach ($name in @('mimetype','META-INF/manifest.xml','Contents/content.hpf','Contents/header.xml','settings.xml','Contents/section0.xml')) {
        if (-not $names.Contains($name)) { throw "Missing required package member: $name" }
    }
    $mimeReader = [IO.StreamReader]::new($archive.GetEntry('mimetype').Open())
    try { if ($mimeReader.ReadToEnd().Trim() -ne 'application/hwp+zip') { throw 'Unexpected HWPX mimetype.' } } finally { $mimeReader.Dispose() }
    $content = $xmlMembers['Contents/content.hpf']
    $itemMap = @{}
    $references = [Collections.Generic.List[string]]::new()
    foreach ($item in $content.SelectNodes('//*[local-name()="manifest"]/*[local-name()="item"]')) {
        $id = $item.GetAttribute('id'); $href = $item.GetAttribute('href')
        if (-not $id -or -not $href -or $itemMap.ContainsKey($id)) { throw 'Invalid content manifest item.' }
        # HWPX manifests use package-root paths; accept content-relative paths too.
        $target = [Uri]::UnescapeDataString(($href -split '#')[0])
        if ($target -match '^[a-z]+:|^/|\\|(?:^|/)\.\.(?:/|$)') { throw 'Unsafe content manifest reference.' }
        if (-not $names.Contains($target)) { $target = 'Contents/' + $target }
        if (-not $names.Contains($target)) { throw 'Missing content manifest resource.' }
        $itemMap[$id] = $target
        $references.Add($id + '|' + $target + '|' + $item.GetAttribute('media-type'))
    }
    $spine = @($content.SelectNodes('//*[local-name()="spine"]/*[local-name()="itemref"]') | ForEach-Object {
        $id = $_.GetAttribute('idref')
        if (-not $itemMap.ContainsKey($id)) { throw 'Broken spine reference.' }
        $itemMap[$id]
    })
    $sections = @($archive.Entries.FullName | Where-Object { $_ -match '^Contents/section\d+\.xml$' } | Sort-Object)
    $sectionSpine = @($spine | Where-Object { $_ -match '^Contents/section\d+\.xml$' })
    if ($sectionSpine.Count -eq 0 -or (@($sectionSpine | Sort-Object -Unique) -join '|') -ne ($sections -join '|')) { throw 'Section spine does not cover the document sections exactly.' }
    if ($sectionSpine.Count -ne $sections.Count) { throw 'Duplicate section spine entry.' }
    [pscustomobject]@{ok=$true;verificationLevel='package_xml_reopen';realHancomVerified=$false;spine=$spine;references=@($references | Sort-Object)}
} finally { $archive.Dispose() }
