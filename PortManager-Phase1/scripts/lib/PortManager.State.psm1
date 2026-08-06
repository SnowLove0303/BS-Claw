Set-StrictMode -Version Latest

$script:LoginStates = @(
    '未检测',
    '未登录',
    '已登录',
    '登录状态未知',
    '检测失败',
    '登录已失效'
)

function Set-PMObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [AllowNull()]
        [object]$Value,
        [switch]$OnlyWhenMissing
    )

    if ($OnlyWhenMissing -and $Object.PSObject.Properties.Name -contains $Name) {
        return
    }
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function New-PMSessionPolicy {
    return [pscustomobject][ordered]@{
        autoLoginEnabled = $false
        credentialRefRequired = $true
        requireHumanConfirmation = $true
        profilePersistence = 'resource-owned-f-drive-profile'
        maxSessionAgeSeconds = 0
        recheckBeforeUse = $true
    }
}

function New-PMLoginDetectionPolicy {
    return [pscustomobject][ordered]@{
        intervalSeconds = 600
        timeoutSeconds = 30
        maxRetries = 2
        retryDelaySeconds = 30
        recheckBeforeUse = $true
        enabled = $true
    }
}

function New-PMLoginEvidence {
    param(
        [ValidateSet('未检测', '未登录', '已登录', '登录状态未知', '检测失败', '登录已失效')]
        [string]$State = '未检测',
        [ValidateSet('none', 'login-page-rule', 'authenticated-rule', 'detector-error', 'session-invalidated')]
        [string]$EvidenceType = 'none',
        [string]$EvidenceSummary = '尚未执行登录状态检测。',
        [string]$PageUrl,
        [string]$PageTitle,
        [string]$CheckedAt,
        [ValidateSet('none', 'unknown', 'confirmed')]
        [string]$Confidence = 'none',
        [string]$Source = 'bsclaw.huice.login-detector',
        [string]$EvidenceVersion = '1'
    )

    return [pscustomobject][ordered]@{
        state = $State
        evidenceType = $EvidenceType
        evidenceSummary = $EvidenceSummary
        pageUrl = if ([string]::IsNullOrWhiteSpace($PageUrl)) { $null } else { $PageUrl }
        pageTitle = if ([string]::IsNullOrWhiteSpace($PageTitle)) { $null } else { $PageTitle }
        checkedAt = if ([string]::IsNullOrWhiteSpace($CheckedAt)) { $null } else { $CheckedAt }
        confidence = $Confidence
        source = $Source
        evidenceVersion = $EvidenceVersion
    }
}

function New-PMCurrentOccupancyDetails {
    param(
        [object[]]$ActiveLeases,
        [int[]]$OwnerProcessIds,
        [string]$Operation,
        [string]$CheckedAt
    )

    return [pscustomobject][ordered]@{
        activeLeases = @($ActiveLeases)
        ownerProcessIds = @($OwnerProcessIds)
        operation = if ([string]::IsNullOrWhiteSpace($Operation)) { $null } else { $Operation }
        checkedAt = if ([string]::IsNullOrWhiteSpace($CheckedAt)) { $null } else { $CheckedAt }
    }
}

function Initialize-PMStatusModel {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Status,
        [switch]$ResetLegacyLogin
    )

    $defaults = [ordered]@{
        connectionStatus = '尚未检测'
        portStatus = '尚未检测'
        httpStatus = '尚未检测'
        browserStatus = '浏览器状态未知'
        pageStatus = '页面状态未知'
        loginStatus = '未检测'
        currentOccupancy = '无'
        ownerProcessIds = @()
        activeLeases = @()
        operationStatus = '状态未知'
        browserVersion = $null
        protocolVersion = $null
        debugEndpoint = $null
        matchedPages = @()
        loginCheckedAt = $null
        lastCheckedAt = $null
        lastSuccessAt = $null
        lastError = $null
        loginDetectionState = '未检测'
        loginDetectionStartedAt = $null
        nextLoginDetectionAt = $null
        loginDetectionSource = $null
        loginDetectionErrorCode = $null
        loginCookieEvidencePresent = $null
        loginApiProbeStatus = '未配置可靠探针'
        loginConfidence = 'none'
        detectorVersion = '1'
        profileMetrics = $null
        browserPid = $null
        processStartTime = $null
        profileFingerprint = $null
        sessionState = '未连接'
        lastOpenAt = $null
        lastOpenResult = $null
        watcherPid = $null
        watcherProcessStartTime = $null
        watcherHeartbeatAt = $null
        watcherLastCheckAt = $null
        watcherNextCheckAt = $null
        watcherFailureCount = 0
        watcherErrorCode = $null
    }
    foreach ($name in $defaults.Keys) {
        Set-PMObjectProperty -Object $Status -Name $name -Value $defaults[$name] -OnlyWhenMissing
    }

    if ($ResetLegacyLogin -or [string]$Status.loginStatus -notin $script:LoginStates) {
        $Status.loginStatus = '未检测'
    }

    if (
        $ResetLegacyLogin -or
        $Status.PSObject.Properties.Name -notcontains 'loginEvidence' -or
        $null -eq $Status.loginEvidence
    ) {
        $evidenceSummary = if ($ResetLegacyLogin) {
            '旧资源尚未按登录证据模型重新检测。'
        }
        else {
            '尚未执行登录状态检测。'
        }
        Set-PMObjectProperty -Object $Status -Name 'loginEvidence' -Value (
            New-PMLoginEvidence -EvidenceSummary $evidenceSummary
        )
        $Status.loginCheckedAt = $null
    }

    Set-PMObjectProperty -Object $Status -Name 'currentOccupancyDetails' -Value (
        New-PMCurrentOccupancyDetails `
            -ActiveLeases @($Status.activeLeases) `
            -OwnerProcessIds @($Status.ownerProcessIds) `
            -Operation ([string]$Status.operationStatus) `
            -CheckedAt ([string]$Status.lastCheckedAt)
    ) -OnlyWhenMissing

    return $Status
}

function Initialize-PMResourceModel {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource,
        [switch]$ResetLegacyLogin
    )

    Set-PMObjectProperty -Object $Resource -Name 'platformId' -Value 'huice' -OnlyWhenMissing
    Set-PMObjectProperty -Object $Resource -Name 'credentialRef' -Value $null -OnlyWhenMissing
    Set-PMObjectProperty -Object $Resource -Name 'maskedAccountSummary' -Value $null -OnlyWhenMissing
    Set-PMObjectProperty -Object $Resource -Name 'loginAutomationState' -Value '未配置凭据' -OnlyWhenMissing
    Set-PMObjectProperty -Object $Resource -Name 'sessionPolicy' -Value (New-PMSessionPolicy) -OnlyWhenMissing
    Set-PMObjectProperty -Object $Resource -Name 'loginDetectionPolicy' -Value (New-PMLoginDetectionPolicy) -OnlyWhenMissing
    if ($null -eq $Resource.lastStatus) {
        Set-PMObjectProperty -Object $Resource -Name 'lastStatus' -Value ([pscustomobject]@{})
    }
    $null = Initialize-PMStatusModel -Status $Resource.lastStatus -ResetLegacyLogin:$ResetLegacyLogin
    return $Resource
}

function Set-PMStatusOccupancyModel {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Status,
        [object[]]$ActiveLeases,
        [int[]]$OwnerProcessIds,
        [string]$Operation,
        [string]$CheckedAt
    )

    Set-PMObjectProperty -Object $Status -Name 'currentOccupancyDetails' -Value (
        New-PMCurrentOccupancyDetails `
            -ActiveLeases @($ActiveLeases) `
            -OwnerProcessIds @($OwnerProcessIds) `
            -Operation $Operation `
            -CheckedAt $CheckedAt
    )
    return $Status
}

function Get-PMLoginStates {
    return @($script:LoginStates)
}

Export-ModuleMember -Function @(
    'New-PMSessionPolicy',
    'New-PMLoginDetectionPolicy',
    'New-PMLoginEvidence',
    'Initialize-PMStatusModel',
    'Initialize-PMResourceModel',
    'Set-PMStatusOccupancyModel',
    'Get-PMLoginStates'
)
