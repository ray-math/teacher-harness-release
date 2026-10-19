# A document request fills an existing selected draft/form. Workflow planning
# may have no basis, but can never use that intake to publish a document.
function New-WorkDocumentBasis {
    param([string]$Purpose, [object[]]$Sources, [object[]]$Preserved)
    $records = @(foreach ($source in $Sources) {
        if ($source.role -notin @('form','human_revision')) { continue }
        $saved = @($Preserved | Where-Object { $_.path -ieq $source.path -and $_.sha256 -ieq $source.sha256 }) | Select-Object -First 1
        if (-not $saved.copyRelativePath) { throw 'Selected draft/form was not preserved before authoring.' }
        [ordered]@{sourcePath=$source.path;role=$source.role;sha256=$source.sha256;preservedRelativePath=$saved.copyRelativePath}
    })
    if ($Purpose -eq 'Document' -and $records.Count -eq 0) {
        throw 'needs_input: Existing draft or form required. Stop authoring and ask the user to provide or select one.'
    }
    [ordered]@{schemaVersion='existing-document-basis/v1';purpose=$Purpose;records=$records}
}

function Assert-WorkDocumentBasis {
    param($Inputs, [string]$WorkRoot)
    $basis = $Inputs.documentBasis
    if (-not $basis -or $basis.schemaVersion -ne 'existing-document-basis/v1' -or $basis.purpose -ne 'Document' -or @($basis.records).Count -eq 0) {
        throw 'needs_input: Document completion requires an existing selected draft/form. Planning-only intake cannot publish documents.'
    }
    $root = (Assert-WorkStoragePath $WorkRoot).TrimEnd('\')
    foreach ($record in @($basis.records)) {
        $relative = ([string]$record.preservedRelativePath).Replace('/','\')
        if ($record.role -notin @('form','human_revision') -or [IO.Path]::IsPathRooted($relative) -or $relative -notmatch '^\.ai\\originals\\' -or @($relative -split '\\' | Where-Object { $_ -in @('','..','.') }).Count) {
            throw 'Draft/form preservation record is invalid.'
        }
        $path = Assert-WorkStoragePath (Join-Path $root $relative)
        if (-not $path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $record.sha256) {
            throw 'Selected draft/form snapshot is missing or changed. Re-intake the actual baseline before authoring.'
        }
    }
    $basis
}
