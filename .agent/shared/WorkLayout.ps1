# Workflow storage is independent of school year, subject, and input document format.
function Compare-WorkflowNumber([string]$Left,[string]$Right) {
    $a=@($Left -split '-'); $b=@($Right -split '-')
    for($i=0;$i -lt [Math]::Min($a.Count,$b.Count);$i++) {
        if([int]$a[$i] -ne [int]$b[$i]) { return [Math]::Sign([int]$a[$i]-[int]$b[$i]) }
    }
    return [Math]::Sign($a.Count-$b.Count)
}
function Resolve-WorkWorkflowLayout {
    param([string]$WorkRoot,[object[]]$Steps,[object[]]$ExistingSteps=@())
    $old=@{}; $seen=@{}; $numbers=@{}; $paths=@{}; $resolved=@()
    foreach($s in $ExistingSteps){if($s.id){$old[[string]$s.id]=$s}}
    foreach($s in $Steps) {
        if(-not $s.storage){
            if($s.id -and $old.ContainsKey([string]$s.id) -and $old[[string]$s.id].storage){$s['storage']=$old[[string]$s.id].storage}
            else{$resolved+=,$s;continue}
        }
        if(-not $s.id -or $seen.ContainsKey([string]$s.id)){throw 'Storage steps require unique stable ids.'}
        $seen[[string]$s.id]=$true
        $spec=$s.storage
        if($spec.kind -notin @('folder','file','none')){throw 'Storage kind must be folder, file or none.'}
        if($spec.kind -eq 'none'){
            if($old.ContainsKey([string]$s.id) -and $old[[string]$s.id].storage.relativePath){throw 'Changing existing storage requires an explicit relocation plan.'}
            $s['storage']=@{kind='none'};$resolved+=,$s;continue
        }
        $name=[string]$spec.name
        if([string]::IsNullOrWhiteSpace($name) -or $name -match '[\\/]' -or $name -match '^\d{2}[_-]'){throw 'Storage name must be one descriptive component without its numeric prefix.'}
        Get-WorkCurrentTarget -WorkRoot $WorkRoot -RelativePath $name -ReservedNames @('.ai','previous_versions','업무현황.html')|Out-Null
        if($spec.kind -eq 'file' -and [IO.Path]::GetExtension($name).ToLowerInvariant() -notin @('.hwpx','.hwp','.odt','.docx','.xlsx','.xls','.xlsm','.pptx','.pdf','.csv','.txt')){throw 'Singleton storage needs a supported document filename.'}
        $number=[string]$spec.number
        $prior=if($old.ContainsKey([string]$s.id)){$old[[string]$s.id].storage}else{$null}
        if($prior -and $prior.kind -ne 'none') {
            if($prior.kind -ne $spec.kind -or $prior.name -cne $name -or ($number -and $number -ne $prior.number)){throw 'Changing existing storage requires an explicit relocation plan.'}
            $number=[string]$prior.number
        }
        if($number -and ($number -notmatch '^\d{2,3}(-\d{2,3})*$' -or $numbers.ContainsKey($number))){throw 'Storage numbers must be unique two-or-more digit components.'}
        if($number){$numbers[$number]=$true}
        $s['storage']=@{kind=[string]$spec.kind;name=$name;number=$number}
        $resolved+=,$s
    }
    $left=''
    for($i=0;$i -lt $resolved.Count;$i++) {
        $spec=$resolved[$i].storage
        if(-not $spec -or $spec.kind -eq 'none'){continue}
        $number=[string]$spec.number
        if(-not $number){
            $right=''
            for($j=$i+1;$j -lt $resolved.Count;$j++){if($resolved[$j].storage.number){$right=[string]$resolved[$j].storage.number;break}}
            if(-not $left -and -not $right){$number='01'}
            elseif(-not $left){$number='00-01'}
            elseif(-not $right){$number=('{0:D2}' -f ([int]($left -split '-')[0]+1))}
            else{$number=$left+'-01'}
            if($right -and (Compare-WorkflowNumber $number $right) -ge 0){
                $number=if($left){$left+'-00-01'}else{'00-00-01'}
                if((Compare-WorkflowNumber $number $right) -ge 0){throw 'No insertion number fits. Specify a number or a reviewed renumbering plan.'}
            }
            if($numbers.ContainsKey($number)){throw 'Inserted storage number collides with an existing step.'}
            $numbers[$number]=$true;$spec.number=$number
        }
        if($left -and (Compare-WorkflowNumber $left $number) -ge 0){throw 'Step order conflicts with existing storage numbers; supply a relocation plan to reorder.'}
        $left=$number
        $relative=$number+'_'+$spec.name
        $target=Get-WorkCurrentTarget -WorkRoot $WorkRoot -RelativePath $relative -ReservedNames @('.ai','previous_versions','업무현황.html')
        if($paths.ContainsKey($relative)){throw 'Duplicate workflow storage path.'};$paths[$relative]=$true
        if(Test-Path -LiteralPath $target){
            $item=Get-Item -LiteralPath $target -Force
            if($item.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System)){throw 'Workflow storage target is hidden or system.'}
            if(($spec.kind -eq 'folder') -ne $item.PSIsContainer){throw 'Workflow storage collides with an existing file or directory.'}
        }
        $spec['relativePath']=$relative
    }
    [pscustomobject]@{steps=@($resolved);foldersToCreate=@($resolved|Where-Object {$_.storage.kind -eq 'folder' -and -not(Test-Path -LiteralPath (Join-Path $WorkRoot $_.storage.relativePath))}|ForEach-Object {$_.storage.relativePath});supportFolders=@($resolved|Where-Object {$_.storage.kind -eq 'folder'}|ForEach-Object {$_.storage.relativePath})}
}
