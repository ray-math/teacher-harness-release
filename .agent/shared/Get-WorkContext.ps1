[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$WorkFolder)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'WorkStorage.ps1')
. (Join-Path $PSScriptRoot 'WorkReferenceScope.ps1')
. (Join-Path $PSScriptRoot 'WorkGroup.ps1')
$work=Assert-WorkStoragePath $WorkFolder
if (-not (Test-WorkFolderName -Name ([IO.Path]::GetFileName($work))) -or -not (Test-Path -LiteralPath $work -PathType Container)) { throw 'Select an existing human work folder.' }
$group=Get-WorkGroupRecord -WorkFolder $work
$scope=Get-WorkReferenceScope -WorkFolder $work
$workflow=$null;$missingWorkflow=$false
if ($group.status -eq 'ready' -and $group.record.workflowPath) {
    $workflow=Resolve-WorkGroupReferencePath -Cabinet $group.cabinet -Path ([string]$group.record.workflowPath)
    $missingWorkflow=-not (Test-Path -LiteralPath $workflow -PathType Leaf)
    if (-not $missingWorkflow -and -not (Test-ReferenceVisiblePath $workflow)) { throw 'The selected workflow path is internal or hidden.' }
}
$status=if ($group.status -eq 'needs_input' -or $scope.status -eq 'needs_input' -or $missingWorkflow) {'needs_input'}else{'ready'}
@{schemaVersion='hwpx-work-context/v1';status=$status;workFolder=$work;group=@{status=$group.status;reason=$group.reason;id=$group.groupId;categoryCode=$group.categoryCode;path=$group.path;sha256=$group.sha256;title=$group.record.title;year=$group.record.year;categories=@($group.record.categories)};workflowPath=$workflow;workflowMissing=$missingWorkflow;referenceScope=$scope;decisions=@(Get-EffectiveWorkDecisions -Group $group);note='Apply resolved decisions to this requested work. Group updates do not rewrite existing documents or infer new-year membership.'} | ConvertTo-Json -Depth 15
