[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DocumentScope.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$name='template-capacity-test-'+[guid]::NewGuid().ToString('N')
$root=[IO.Path]::GetFullPath((Join-Path $parent $name))
$job=Join-Path $root '.ai\jobs\synthetic'
$source=Join-Path $job 'template.hwpx'
$planPath=Join-Path $job 'plan.json'
$gate=Join-Path $PSScriptRoot 'Assert-DocumentOperationScope.ps1'
$checks=0
function Write-CapacityJson([string]$Path,$Value){$Value|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $Path -Encoding utf8}
function Set-CapacityScope([bool]$Format){
    $scope=New-DocumentScope -JobPath $job -FinalPolishAuthorized:$Format -FormattingRequestText $(if($Format){'format change'}else{''})
    Write-CapacityJson (Join-Path $job 'inputs.json') @{delivery=@{workRoot=$root};documentScope=$scope}
    Write-CapacityJson (Join-Path $root '.ai\work.json') @{editing=@{documentScope=$scope}}
}
try {
    New-Item -ItemType Directory -Path $job -Force|Out-Null
    $zip=[IO.Compression.ZipFile]::Open($source,[IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry=$zip.CreateEntry('Contents/section0.xml');$writer=New-Object IO.StreamWriter($entry.Open())
        try {$writer.Write('<hs:sec xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section" xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph"><hp:p><hp:run><hp:tbl><hp:tr><hp:tc><hp:subList><hp:p/><hp:p/></hp:subList><hp:cellAddr rowAddr="0" colAddr="0"/><hp:cellSpan rowSpan="1" colSpan="1"/></hp:tc></hp:tr></hp:tbl></hp:run></hp:p></hs:sec>')} finally{$writer.Dispose()}
    } finally {$zip.Dispose()}
    $original=(Get-FileHash -LiteralPath $source).Hash
    foreach($case in @(@{lines=2;format=$false;allowed=$true},@{lines=3;format=$false;allowed=$false},@{lines=3;format=$true;allowed=$true})){
        Set-CapacityScope $case.format
        $text=(1..$case.lines | ForEach-Object {"line $_"}) -join "`n"
        Write-CapacityJson $planPath @{source=$source;steps=@(@{op='fill_cells';args=@{cells=@(@{section_path='Contents/section0.xml';table_index=0;row=0;col=0;text=$text})}})}
        $allowed=$true;$failure=''
        try{& $gate -JobPath $job -PlanPath $planPath | Out-Null}catch{$allowed=$false;$failure=$_.Exception.Message}
        if($allowed -ne $case.allowed -or (-not $allowed -and $failure -notlike '*Template cell capacity exceeded*')){throw "Unexpected capacity result: $failure"}
        $checks++
    }
    if((Get-FileHash -LiteralPath $source).Hash -cne $original){throw 'Capacity inspection changed template bytes.'}
    $checks++
} finally {
    if(-not $root.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($root) -cne $name){throw 'Unsafe capacity fixture cleanup.'}
    if(Test-Path -LiteralPath $root){
        $items=@(Get-Item -LiteralPath $root -Force)+@(Get-ChildItem -LiteralPath $root -Recurse -Force)
        if(@($items|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Capacity cleanup refuses reparse points.'}
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
[ordered]@{ok=$true;checks=$checks;powershell=$PSVersionTable.PSVersion.ToString();fixtureRemoved=(-not(Test-Path -LiteralPath $root))}|ConvertTo-Json -Compress
