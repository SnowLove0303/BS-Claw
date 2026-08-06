Set-StrictMode -Version 2.0

function Get-SelectionResourceField {
    param([object]$ResourceContext, [string[]]$Names)
    foreach ($name in $Names) {
        $prop = $ResourceContext.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            return $prop.Value
        }
    }
    return $null
}

function Test-SelectionTextContains {
    param([object]$Value, [int[]]$CodePoints)
    $needle = -join ($CodePoints | ForEach-Object { [char]$_ })
    return ([string]$Value).Contains($needle)
}

function Invoke-SelectionPreflight {
    param([object]$ResourceContext, [object]$Request, [string]$Source = "selection-module.preflight")
    $issues = @()
    if ($null -eq $ResourceContext) {
        return [pscustomobject]@{
            ok = $false
            status = "AUTH_REQUIRED"
            phase = "PREFLIGHT"
            code = "RESOURCE_CONTEXT_MISSING"
            userMessage = "Resource context is missing; selection task will not continue."
            issues = @("RESOURCE_CONTEXT_MISSING")
            resourceSnapshot = [pscustomobject]@{
                resourceName = $null
                port = $null
                enabled = $null
                connectionStatus = $null
                browserStatus = $null
                pageStatus = $null
                loginStatus = $null
                apiStatus = $null
                confidence = $null
                checkedAt = $null
                snapshotAt = Get-SelectionUtcNow
                freshness = $null
                statusSource = $null
                nextAction = $null
                lease = $null
            }
            source = $Source
            checkedAt = Get-SelectionUtcNow
            nextAction = "Scheduler must inject a PortManager public ResourceContext before retry."
        }
    }

    $enabled = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("enabled", "isEnabled")
    $port = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("port", "debugPort")
    $connectionStatus = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("connectionStatus", "connection")
    $browserStatus = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("browserStatus", "browser")
    $pageStatus = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("pageStatus", "page")
    $loginStatus = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("loginStatus", "login")
    $apiStatus = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("apiStatus", "loginApiProbeStatus")
    $confidence = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("confidence")
    $checkedAt = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("checkedAt", "snapshotAt")
    $lease = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("lease", "occupancy")

    $connectionText = "$connectionStatus".ToLowerInvariant()
    $browserText = "$browserStatus".ToLowerInvariant()
    $pageText = "$pageStatus".ToLowerInvariant()
    $loginText = "$loginStatus".ToLowerInvariant()
    $apiText = "$apiStatus".ToLowerInvariant()
    $leaseBusy = $false
    if ($null -ne $lease) {
        if ($lease.PSObject.Properties["active"]) {
            $leaseBusy = [bool]$lease.active
        } elseif ($lease.PSObject.Properties["count"]) {
            $leaseBusy = ([int]$lease.count) -gt 0
        } elseif ($lease.PSObject.Properties["currentOccupancyDetails"] -and $null -ne $lease.currentOccupancyDetails) {
            $leaseBusy = "$($lease.currentOccupancyDetails)" -match "(?i)busy|occupied|locked"
        } else {
            $leaseBusy = "$lease" -match "(?i)busy|occupied|locked"
        }
    }

    $enabledZh = Test-SelectionTextContains -Value $enabled -CodePoints @(0x542F, 0x7528)
    $connectionReadyZh = Test-SelectionTextContains -Value $connectionStatus -CodePoints @(0x53EF, 0x8FDE, 0x63A5)
    $browserNotReadyZh = (Test-SelectionTextContains -Value $browserStatus -CodePoints @(0x4E0D, 0x53EF, 0x8FDE, 0x63A5)) -or (Test-SelectionTextContains -Value $browserStatus -CodePoints @(0x672A, 0x8FD0, 0x884C))
    $pageReadyZh = (Test-SelectionTextContains -Value $pageStatus -CodePoints @(0x5E73, 0x53F0, 0x9875, 0x9762, 0x6B63, 0x786E)) -or (Test-SelectionTextContains -Value $pageStatus -CodePoints @(0x9875, 0x9762, 0x6B63, 0x786E)) -or (Test-SelectionTextContains -Value $pageStatus -CodePoints @(0x5DF2, 0x5C31, 0x7EEA))
    $loggedInZh = Test-SelectionTextContains -Value $loginStatus -CodePoints @(0x5DF2, 0x767B, 0x5F55)
    $apiReadyZh = Test-SelectionTextContains -Value $apiStatus -CodePoints @(0x5DF2, 0x5C31, 0x7EEA)

    if ($enabled -ne $true -and "$enabled" -notin @("true", "True", "enabled") -and -not $enabledZh) { $issues += "RESOURCE_DISABLED_OR_UNKNOWN" }
    if ($null -eq $port) { $issues += "PORT_MISSING" }
    if ($connectionText -notin @("connected", "ok", "reachable") -and -not $connectionReadyZh) { $issues += "CDP_CONNECTION_NOT_READY" }
    if ($browserText -in @("missing", "not-running", "unavailable") -or $browserNotReadyZh) { $issues += "BROWSER_NOT_READY" }
    if ($pageText -notmatch "erp\.huice\.com|ready|ok|logged" -and -not $pageReadyZh) { $issues += "PAGE_NOT_CONFIRMED" }
    if ($loginText -notin @("logged-in", "logged-in-api-ready", "authenticated") -and -not $loggedInZh) { $issues += "AUTH_REQUIRED" }
    if ($apiText -notin @("logged-in-api-ready", "200", "ok") -and -not "$apiStatus".Contains("logged-in-api-ready") -and -not $apiReadyZh) { $issues += "API_NOT_READY" }
    if ($leaseBusy) { $issues += "RESOURCE_BUSY" }

    $snapshot = [pscustomobject]@{
        resourceName = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("resourceName", "name", "displayName")
        port = $port
        enabled = $enabled
        connectionStatus = $connectionStatus
        browserStatus = $browserStatus
        pageStatus = $pageStatus
        loginStatus = $loginStatus
        apiStatus = $apiStatus
        confidence = $confidence
        checkedAt = $checkedAt
        snapshotAt = Get-SelectionUtcNow
        freshness = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("freshness")
        statusSource = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("statusSource", "source")
        nextAction = Get-SelectionResourceField -ResourceContext $ResourceContext -Names @("nextAction")
        lease = Protect-SelectionObject $lease
    }

    if ($issues.Count -gt 0) {
        $code = if ($issues -contains "RESOURCE_BUSY") { "RESOURCE_BUSY" } elseif ($issues -contains "AUTH_REQUIRED") { "AUTH_REQUIRED" } else { "PREFLIGHT_BLOCKED" }
        return [pscustomobject]@{
            ok = $false
            status = if ($code -eq "RESOURCE_BUSY") { "RESOURCE_BUSY" } elseif ($code -eq "AUTH_REQUIRED") { "AUTH_REQUIRED" } else { "BLOCKED" }
            phase = "PREFLIGHT"
            code = $code
            userMessage = "Resource preflight failed; selection task will not continue."
            issues = $issues
            resourceSnapshot = $snapshot
            source = $Source
            checkedAt = Get-SelectionUtcNow
            nextAction = "Use the formal resource entry to restore connection, login, API-ready state or release occupancy before retry."
        }
    }

    [pscustomobject]@{
        ok = $true
        status = "PREFLIGHT_PASSED"
        phase = "PREFLIGHT"
        userMessage = "Resource preflight passed."
        resourceSnapshot = $snapshot
        source = $Source
        checkedAt = Get-SelectionUtcNow
        nextAction = "Continue selection capability execution."
    }
}

Export-ModuleMember -Function *
