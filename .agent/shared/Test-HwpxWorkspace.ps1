[CmdletBinding()]
param([switch]$StructureOnly)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$errors = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$required = @(
    '.agent\shared\inspect_harness_connection.py',
    '.agent\shared\check_hwpx_mcp.py',
    '.agent\shared\test_hwpx_mcp_install.py',
    '.agent\shared\benchmark_hwpx_transport.py',
    'AGENTS.md', 'README.md', 'INSTALL.md', 'Install.ps1', 'Setup.ps1',
    '.agent\shared\DocumentBasis.ps1',
    '.agent\shared\Receive-TeacherHarnessInputs.ps1',
    '.agent\shared\Test-ExistingDocumentBasis.ps1',
    '.agent\shared\Test-TeacherHarnessInputs.ps1',
    '.agent\shared\Resolve-TeacherHarnessConfig.ps1',
    '.agent\shared\Test-DocumentWorkReadiness.ps1',
    '.agent\shared\Test-TeacherHarnessDistribution.ps1',
    '.agent\shared\Test-PortableInstallSafety.ps1',
    '.agents\skills\hwpx-workspace-delivery\SKILL.md',
    '.agents\skills\work-planning\SKILL.md',
    '.agents\skills\workspace-maintenance\SKILL.md',
    '.agent\index\delivery-system.json', '.agent\index\hwpx-runtime.json',
    '.agent\shared\Start-HwpxWork.ps1', '.agent\shared\Publish-HumanResult.ps1',
    '.agent\shared\DocumentScope.ps1', '.agent\shared\Assert-DocumentOperationScope.ps1',
    '.agent\shared\Complete-HumanDraft.ps1', '.agent\shared\HumanDeliveryContract.ps1',
    '.agent\shared\Assert-ContentValidation.ps1', '.agent\shared\validate_content_contract.py',
    '.agent\shared\paragraph_target_preflight.py', '.agent\shared\test_paragraph_target_preflight.py',
    '.agent\shared\Test-ContentValidation.ps1', '.agent\shared\test_content_contract.py',
    '.agent\shared\official-odt-draft\scripts\edit_existing_odt.py',
    '.agent\shared\HumanRevisionStorage.ps1', '.agent\shared\Test-HumanDeliveryFlow.ps1',
    '.agent\shared\document_scope.py', '.agent\shared\Test-DocumentScope.ps1',
    '.agent\shared\Test-TemplateFillCapacity.ps1',
    '.agent\shared\measure_workflow_usage.py', '.agent\shared\test_measure_workflow_usage.py',
    '.agent\shared\WorkRegistry.ps1', '.agent\shared\WorkStorage.ps1',
    '.agent\shared\WorkGroup.ps1', '.agent\shared\Get-WorkContext.ps1',
    '.agent\shared\Set-WorkGroup.ps1', '.agent\shared\Set-WorkDecision.ps1',
    '.agent\shared\Set-HumanCabinetRoot.ps1', '.agent\shared\Rename-WorkTools.ps1',
    '.agent\shared\WorkReferenceScope.ps1', '.agent\shared\Set-WorkReferenceScope.ps1',
    '.agent\shared\Find-HwpxContext.ps1', '.agent\shared\Prepare-WorkWorkflow.ps1',
    '.agent\shared\New-HwpxFormContract.ps1', '.agent\shared\Assert-HwpxPublishGate.ps1'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $workspace $relative) -PathType Leaf)) { $errors.Add("Missing required file: $relative") }
}
foreach ($entry in Get-ChildItem -LiteralPath $workspace -Force) {
    if ($entry.Name -notin @('.agent', '.agents', 'AGENTS.md', 'README.md', 'INSTALL.md', 'Install.ps1', 'Setup.ps1',
    'docs', '.gitignore')) { $warnings.Add("Additional workspace entry: $($entry.Name)") }
}
foreach ($relative in @('source', 'manuals', 'templates', '.agent\jobs', '.agent\archive', '.agent\index\human-current.json')) {
    if (Test-Path -LiteralPath (Join-Path $workspace $relative)) { $warnings.Add("Legacy workspace data remains: $relative") }
}
foreach ($relative in @(
    '.agent\cache\console-browser-check-20260907',
    '.agent\cache\hwpx-skill-policy-20260904',
    '.agent\cache\human-open-launcher',
    '.agent\index\hancom-automation',
    '.agent\index\human-open-targets.json',
    '.agent\index\human-open-launcher.json'
)) {
    if (Test-Path -LiteralPath (Join-Path $workspace $relative)) {
        $errors.Add("Retired diagnostic state must not be recreated: $relative")
    }
}
if (-not $StructureOnly) {
    foreach ($relative in @('.agent\index\delivery-system.json', '.agent\index\hwpx-runtime.json')) {
        try { Get-Content -LiteralPath (Join-Path $workspace $relative) -Raw -Encoding utf8 | ConvertFrom-Json | Out-Null }
        catch { $errors.Add("Invalid configuration: $relative") }
    }
    foreach ($script in Get-ChildItem -LiteralPath (Join-Path $workspace '.agent\shared') -Filter '*.ps1' -Recurse -File) {
        $tokens=$null; $parseErrors=$null
        [Management.Automation.Language.Parser]::ParseFile($script.FullName,[ref]$tokens,[ref]$parseErrors) | Out-Null
        foreach ($problem in $parseErrors) { $errors.Add("$($script.Name): $($problem.Message)") }
    }
}
[ordered]@{
    schemaVersion='hwpx-workspace.check/v2'
    scope=$(if($StructureOnly){'structure-only'}else{'structure-config-powershell'})
    ok=($errors.Count -eq 0)
    checkedRequiredFiles=$required.Count
    errors=@($errors)
    warnings=@($warnings)
    schoolFilesRead=$false
} | ConvertTo-Json -Depth 5
if ($errors.Count -gt 0) { exit 1 }
