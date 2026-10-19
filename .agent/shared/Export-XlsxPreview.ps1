[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceFile,
    [Parameter(Mandatory = $true)][string]$OutputPdf,
    [string]$SheetName,
    [string]$RangeAddress
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Use a separate automation instance, never the user's active Excel instance.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class XlsxPreviewWindow {
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
}
'@

$excel = $null
$books = $null
$book = $null
$sheets = $null
$sheet = $null
$range = $null
$ownedProcess = $null
$ownsExcel = $false
$failure = $null
$cleanupErrors = New-Object 'System.Collections.Generic.List[string]'
$receipt = [ordered]@{ status = 'failed'; sourceFile = $SourceFile; outputPdf = $OutputPdf }

function Release-PreviewComObject($Object) {
    if ($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Object)
    }
}

try {
    $source = (Get-Item -LiteralPath $SourceFile -ErrorAction Stop).FullName
    if ([IO.Path]::GetExtension($source) -ine '.xlsx') { throw 'Only .xlsx inputs are supported.' }
    $target = [IO.Path]::GetFullPath($OutputPdf)
    if ([IO.Path]::GetExtension($target) -ine '.pdf') { throw 'OutputPdf must end in .pdf.' }
    if (Test-Path -LiteralPath $target) { throw 'OutputPdf already exists. Choose an unused preview path.' }
    if ($RangeAddress -and -not $SheetName) { throw 'RangeAddress requires SheetName.' }
    $receipt.sourceFile = $source
    $receipt.outputPdf = $target
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $receipt.sourceSha256 = $sourceHash
    $existingIds = @(Get-Process -Name EXCEL -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $excel = New-Object -ComObject Excel.Application
    [uint32]$excelProcessId = 0
    [void][XlsxPreviewWindow]::GetWindowThreadProcessId([IntPtr]$excel.Hwnd, [ref]$excelProcessId)
    if (-not $excelProcessId -or $existingIds -contains [int]$excelProcessId) {
        throw 'Excel did not create a separate process; the existing instance was left untouched.'
    }
    $ownedProcess = Get-Process -Id $excelProcessId -ErrorAction Stop
    $ownsExcel = $true
    $receipt.excelProcessId = $excelProcessId
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.EnableEvents = $false
    $excel.AskToUpdateLinks = $false
    $excel.AutomationSecurity = 3
    $books = $excel.Workbooks
    $missing = [Type]::Missing
    # Pass only required choices: UpdateLinks=0 and ReadOnly=true. On this Excel
    # COM binding, forwarding all optional parameters makes valid files fail Open.
    $book = $books.Open($source, 0, $true)
    if (-not $book.ReadOnly) { throw 'Excel did not open the source read-only.' }
    $receipt.readOnly = $true
    $parent = [IO.Path]::GetDirectoryName($target)
    [void][IO.Directory]::CreateDirectory($parent)
    if ($SheetName) {
        $sheets = $book.Worksheets
        $sheet = $sheets.Item($SheetName)
        $receipt.sheetName = $SheetName
        if ($RangeAddress) {
            $range = $sheet.Range($RangeAddress)
            $receipt.rangeAddress = $RangeAddress
            $range.ExportAsFixedFormat(0, $target, 0, $true, $false, $missing, $missing, $false)
        } else {
            $sheet.ExportAsFixedFormat(0, $target, 0, $true, $false, $missing, $missing, $false)
        }
    } else {
        $book.ExportAsFixedFormat(0, $target, 0, $true, $false, $missing, $missing, $false)
    }
    $pdf = Get-Item -LiteralPath $target -ErrorAction Stop
    if ($pdf.Length -eq 0) { throw 'Excel created an empty PDF.' }
    $receipt.pdfBytes = $pdf.Length
} catch {
    $failure = $_.Exception.Message
} finally {
    if ($null -ne $book) {
        try { $book.Close($false) } catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    foreach ($comObject in @($range, $sheet, $sheets, $book, $books)) {
        try { Release-PreviewComObject $comObject } catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    if ($ownsExcel -and $null -ne $excel) {
        try { $excel.Quit() } catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    try { Release-PreviewComObject $excel } catch { $cleanupErrors.Add($_.Exception.Message) }
    $range = $sheet = $sheets = $book = $books = $excel = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if ($ownsExcel -and $null -ne $ownedProcess) {
        if (-not $ownedProcess.WaitForExit(10000)) {
            $cleanupErrors.Add('The owned Excel process did not exit after Quit.')
        }
        $receipt.excelExited = $ownedProcess.HasExited
        $ownedProcess.Dispose()
    }
    if ($receipt.Contains('sourceSha256')) {
        try {
            $receipt.sourceUnchanged = ((Get-FileHash -LiteralPath $receipt.sourceFile -Algorithm SHA256).Hash -eq $receipt.sourceSha256)
            if (-not $receipt.sourceUnchanged) { $cleanupErrors.Add('Source workbook hash changed.') }
        } catch { $cleanupErrors.Add($_.Exception.Message) }
    }
}

if ($failure -or $cleanupErrors.Count) {
    $receipt.error = $failure
    $receipt.cleanupErrors = @($cleanupErrors.ToArray())
    $receipt | ConvertTo-Json -Depth 5 -Compress
    exit 1
}
$receipt.status = 'passed'
$receipt | ConvertTo-Json -Depth 5 -Compress
