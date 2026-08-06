Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'HuiceLogin.Configuration.psm1') -Force -DisableNameChecking
$script:PortManager = Resolve-HuicePortManagerContext
Import-Module $script:PortManager.sqliteModule -Force -DisableNameChecking

function Initialize-HuicePersistence {
    Initialize-PMSqlite -DataRoot $script:PortManager.dataRoot -JsonPath $script:PortManager.jsonPath
    return [pscustomobject]@{ database = Get-PMSqlitePath; authority = 'port_runtime_states'; schema = (Read-PMSqliteStore).schemaVersion }
}

function ConvertTo-HuiceRuntimeState {
    param($Resource, $Evidence, $Credential)
    $auth = if ($Evidence.PSObject.Properties.Name -contains 'authResult') { $Evidence.authResult } else { $null }
    $rawStatus = [string]$Evidence.status
    $loginStatus = switch ($rawStatus) {
        'logged-in-api-ready' { '已登录' }
        'login-required' { '未登录' }
        'product-selection' { '未登录' }
        'manual-verification' { '未登录' }
        'session-expired' { '登录已失效' }
        'permission-denied' { '检测失败' }
        'resource-busy' { '检测失败' }
        default { '检测失败' }
    }
    $apiStatus = if ($null -ne $auth) { [string]$auth.status } else { 'not-run' }
    $errorCode = if ($null -ne $auth -and $auth.PSObject.Properties.Name -contains 'errorCode') { [string]$auth.errorCode } else { $null }
    if ([string]::IsNullOrWhiteSpace($errorCode) -and $rawStatus -in @('port-unavailable','wrong-host','token-missing','refresh-failed','probe-failed')) {
        $errorCode = $rawStatus.ToUpperInvariant().Replace('-','_')
    }
    $checkedAt = if ($Evidence.PSObject.Properties.Name -contains 'checkedAt') { [string]$Evidence.checkedAt } else { [DateTimeOffset]::Now.ToString('o') }
    $authenticatedAt = if ($rawStatus -eq 'logged-in-api-ready') { $checkedAt } else { $null }
    $nextRetryAt = if ($null -ne $errorCode) { [DateTimeOffset]::Now.AddSeconds(30).ToString('o') } else { $null }
    $safeEvidence = [ordered]@{
        evidenceType = [string]$Evidence.evidenceType
        summary = [string]$Evidence.summary
        pageUrl = if ($Evidence.PSObject.Properties.Name -contains 'pageUrl') { [string]$Evidence.pageUrl } else { $null }
        pageTitle = if ($Evidence.PSObject.Properties.Name -contains 'pageTitle') { [string]$Evidence.pageTitle } else { $null }
        authMaterialPresent = if ($null -ne $auth -and $auth.PSObject.Properties.Name -contains 'authMaterialPresent') { [bool]$auth.authMaterialPresent } else { $false }
        grayTagPresent = if ($null -ne $auth -and $auth.PSObject.Properties.Name -contains 'grayTagPresent') { [bool]$auth.grayTagPresent } else { $false }
        refreshHttpStatus = if ($null -ne $auth -and $auth.PSObject.Properties.Name -contains 'refreshHttpStatus') { $auth.refreshHttpStatus } else { $null }
        probeHttpStatus = if ($null -ne $auth -and $auth.PSObject.Properties.Name -contains 'probeHttpStatus') { $auth.probeHttpStatus } else { $null }
        requiredProbeFieldsPresent = if ($null -ne $auth -and $auth.PSObject.Properties.Name -contains 'requiredProbeFieldsPresent') { [bool]$auth.requiredProbeFieldsPresent } else { $false }
        source = 'huice-login-agent'
    }
    return @{
        resourceId = [string]$Resource.resourceId
        loginStatus = $loginStatus
        evidence = $safeEvidence
        checkedAt = $checkedAt
        apiProbeStatus = $apiStatus
        confidence = if ($rawStatus -eq 'logged-in-api-ready') { 'high' } elseif ($rawStatus -in @('login-required','session-expired','permission-denied')) { 'high' } else { 'unknown' }
        errorCode = $errorCode
        lastError = if ($null -ne $errorCode) { $errorCode } else { $null }
        lastAuthenticatedAt = $authenticatedAt
        authMaterialPresent = [bool]$safeEvidence.authMaterialPresent
        browserPid = if ($Resource.PSObject.Properties.Name -contains 'browserPid') { [int]$Resource.browserPid } else { $null }
        processStartTime = if ($Resource.PSObject.Properties.Name -contains 'processStartTime') { [string]$Resource.processStartTime } else { $null }
        sessionState = '同一资源执行环境'
        nextRetryAt = $nextRetryAt
        auditAction = 'HuiceLoginState'
        auditMessage = "慧策登录状态：$loginStatus"
        processId = $PID
        credentialRef = if ($null -ne $Credential) { [string]$Credential.credentialRef } else { $null }
        credentialType = if ($null -ne $Credential) { 'terminal-secure-input' } else { $null }
        maskedAccountSummary = if ($null -ne $Credential) { [string]$Credential.maskedAccountSummary } else { $null }
        profileFingerprint = if ($Resource.PSObject.Properties.Name -contains 'lastStatus' -and $null -ne $Resource.lastStatus -and $Resource.lastStatus.PSObject.Properties.Name -contains 'profileFingerprint') { [string]$Resource.lastStatus.profileFingerprint } else { $null }
        watcherPid = if ($Evidence.PSObject.Properties.Name -contains 'watcherPid') { [int]$Evidence.watcherPid } else { $null }
        watcherProcessStartTime = if ($Evidence.PSObject.Properties.Name -contains 'watcherProcessStartTime') { [string]$Evidence.watcherProcessStartTime } else { $null }
        watcherHeartbeatAt = if ($Evidence.PSObject.Properties.Name -contains 'watcherHeartbeatAt') { [string]$Evidence.watcherHeartbeatAt } else { $null }
        watcherLastCheckAt = if ($Evidence.PSObject.Properties.Name -contains 'watcherLastCheckAt') { [string]$Evidence.watcherLastCheckAt } else { $null }
        watcherNextCheckAt = if ($Evidence.PSObject.Properties.Name -contains 'watcherNextCheckAt') { [string]$Evidence.watcherNextCheckAt } else { $null }
        watcherErrorCode = if ($Evidence.PSObject.Properties.Name -contains 'watcherErrorCode') { [string]$Evidence.watcherErrorCode } else { $null }
    }
}

function Save-HuiceSession {
    param($Resource, $Evidence, $Credential)
    # port_runtime_states is authoritative and login_session_events is append-only
    # evidence. If an old login_sessions table exists, the shared SQLite service
    # updates it only as a compatibility projection from the authoritative state.
    return Set-PMSqliteLoginRuntime -State (ConvertTo-HuiceRuntimeState -Resource $Resource -Evidence $Evidence -Credential $Credential)
}

function Get-HuiceSessions {
    $store = Read-PMSqliteStore
    return @($store.resources | Where-Object { $_.platformId -eq 'huice' })
}

function Acquire-HuiceLease {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [string]$Owner = "huice-login-agent:$PID",
        [string]$Operation = 'Login',
        [ValidateRange(10, 600)][int]$DurationSeconds = 210
    )
    $started = [DateTimeOffset]::Now
    $lease = [pscustomobject]@{
        leaseId = [Guid]::NewGuid().ToString('N')
        resourceId = $ResourceId
        operation = $Operation
        processId = $PID
        taskRef = $Owner
        startedAt = $started.ToString('o')
        expiresAt = $started.AddSeconds($DurationSeconds).ToString('o')
    }
    Add-PMSqliteLease -Lease $lease | Out-Null
    return $lease
}

function Release-HuiceLease {
    param([Parameter(Mandatory = $true)]$Lease)
    $id = if ($Lease -is [string]) { $Lease } else { [string]$Lease.leaseId }
    if (-not [string]::IsNullOrWhiteSpace($id)) { Release-PMSqliteLease -LeaseId $id }
}

function Write-HuiceAudit {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [string]$ErrorCode,
        [string]$Message
    )
    return Add-PMSqliteAudit -Audit @{
        action = $Action
        resourceId = $ResourceId
        outcome = $Outcome
        message = $Message
        errorCode = $ErrorCode
        processId = $PID
        createdAt = [DateTimeOffset]::Now.ToString('o')
        details = @{ errorCode = $ErrorCode }
    }
}

Export-ModuleMember -Function Initialize-HuicePersistence,Save-HuiceSession,Get-HuiceSessions,Acquire-HuiceLease,Release-HuiceLease,Write-HuiceAudit
