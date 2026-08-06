Set-StrictMode -Version 2.0

function Get-SelectionDiscovery {
    param([string]$ModuleRoot)
    $manifestPath = Join-Path $ModuleRoot "selection-module.manifest.json"
    $adapterPath = Join-Path $ModuleRoot "adapter\bsclaw-selection-adapter.json"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json
    [pscustomobject]@{
        ok = $true
        status = "DISCOVERED"
        module = $manifest
        adapter = $adapter
        paths = [pscustomobject]@{
            moduleRoot = $ModuleRoot
            manifest = $manifestPath
            adapter = $adapterPath
            entry = Join-Path $ModuleRoot "selection-module.ps1"
        }
        source = "selection-module.discover"
        checkedAt = Get-SelectionUtcNow
        nextAction = "BSClaw-Local scheduler should read capabilities and inject resource context."
    }
}

function Get-SelectionCapability {
    param([string]$ModuleRoot, [string]$ActionId)
    $manifest = Get-Content -LiteralPath (Join-Path $ModuleRoot "selection-module.manifest.json") -Raw | ConvertFrom-Json
    foreach ($capability in $manifest.capabilities) {
        if ($capability.id -eq $ActionId) { return $capability }
    }
    return $null
}

function Test-SelectionCapabilityPolicy {
    param([object]$Capability)
    if ($null -eq $Capability) {
        return New-SelectionError -Code "CAPABILITY_NOT_FOUND" -Message "Selection capability was not found." -Stage "CAPABILITY_MATCHED" -TechnicalSummary "The requested SelectionAction is not declared in the module manifest." -NextAction "Check the capability name passed by scheduler."
    }
    if ([string]::IsNullOrWhiteSpace($Capability.resourceExecutionPolicy) -or $Capability.resourceExecutionPolicy -eq "policy-pending") {
        return New-SelectionError -Code "POLICY_PENDING" -Message "The capability has no executable resource policy and is blocked." -Stage "CAPABILITY_MATCHED" -TechnicalSummary "resourceExecutionPolicy is missing or policy-pending." -NextAction "Declare capability policy before execution."
    }
    if ([string]::IsNullOrWhiteSpace($Capability.resourceSelectionMode)) {
        return New-SelectionError -Code "RESOURCE_SELECTION_MODE_MISSING" -Message "The capability has no resource selection mode and is blocked." -Stage "CAPABILITY_MATCHED" -TechnicalSummary "resourceSelectionMode is missing." -NextAction "Declare selection mode before execution."
    }
    return New-SelectionOk -Status "CAPABILITY_MATCHED" -Stage "CAPABILITY_MATCHED" -Data $Capability -Message "Capability contract matched."
}

Export-ModuleMember -Function *
