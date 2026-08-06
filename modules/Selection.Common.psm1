Set-StrictMode -Version 2.0

function Get-SelectionUtcNow {
    (Get-Date).ToUniversalTime().ToString("o")
}

function New-SelectionId {
    param([string]$Prefix = "sel")
    "{0}-{1}" -f $Prefix, ([guid]::NewGuid().ToString("N"))
}

function ConvertFrom-SelectionJson {
    param(
        [string]$Json,
        [string]$Name,
        [switch]$Required
    )
    if ([string]::IsNullOrWhiteSpace($Json)) {
        if ($Required) { throw "$Name is required." }
        return $null
    }
    try {
        return $Json | ConvertFrom-Json
    } catch {
        throw "$Name is not valid JSON: $($_.Exception.Message)"
    }
}

function ConvertTo-SelectionJsonText {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function ConvertTo-SelectionHashtable {
    param([object]$Value)
    if ($null -eq $Value) { return @{} }
    if ($Value -is [hashtable]) { return $Value }
    $json = $Value | ConvertTo-Json -Depth 30 -Compress
    return $json | ConvertFrom-Json | ConvertTo-Json -Depth 30 -Compress | ConvertFrom-Json
}

function Protect-SelectionObject {
    param([object]$Value)
    $sensitivePattern = "(?i)(password|passwd|pwd|token|cookie|authorization|credential|secret|profile|x-hc-token)"
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Value -match "(?i)^bearer\s+|token=|cookie=|x-hc-token\s*[:=]|authorization\s*[:=]") { return "[REDACTED]" }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        foreach ($key in $Value.Keys) {
            if ([string]$key -match $sensitivePattern) {
                $copy[$key] = "[REDACTED]"
            } else {
                $copy[$key] = Protect-SelectionObject $Value[$key]
            }
        }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) { $items += ,(Protect-SelectionObject $item) }
        return [object[]]$items
    }
    $props = @($Value.PSObject.Properties)
    if ($props.Count -gt 0) {
        $copy = [ordered]@{}
        foreach ($prop in $props) {
            if ($prop.Name -match $sensitivePattern) {
                $copy[$prop.Name] = "[REDACTED]"
            } else {
                $copy[$prop.Name] = Protect-SelectionObject $prop.Value
            }
        }
        return [pscustomobject]$copy
    }
    return $Value
}

function New-SelectionError {
    param(
        [string]$Code,
        [string]$Message,
        [string]$Stage,
        [string]$TechnicalSummary,
        [bool]$Retryable = $false,
        [bool]$RecoveryRequired = $false,
        [string]$NextAction = "Review the error and retry or ask scheduler to recover."
    )
    [pscustomobject]@{
        ok = $false
        code = $Code
        status = if ($RecoveryRequired) { "RECOVERY_REQUIRED" } else { "BLOCKED" }
        stage = $Stage
        userMessage = $Message
        technicalSummary = $TechnicalSummary
        retryable = $Retryable
        recoveryRequired = $RecoveryRequired
        occurredAt = Get-SelectionUtcNow
        nextAction = $NextAction
    }
}

function New-SelectionOk {
    param(
        [string]$Status,
        [string]$Stage,
        [object]$Data,
        [string]$Message = "Operation completed."
    )
    [pscustomobject]@{
        ok = $true
        status = $Status
        stage = $Stage
        userMessage = $Message
        data = Protect-SelectionObject $Data
        checkedAt = Get-SelectionUtcNow
        nextAction = "Review result details."
    }
}

Export-ModuleMember -Function *
