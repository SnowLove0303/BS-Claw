Set-StrictMode -Version Latest

$stateModule = Join-Path $PSScriptRoot 'PortManager.State.psm1'
Import-Module $stateModule -Force

function Test-PMLoginPatternMatch {
    param(
        [string]$Value,
        [object[]]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    foreach ($pattern in @($Patterns)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pattern) -and $Value -like [string]$pattern) {
            return $true
        }
    }
    return $false
}

function ConvertTo-PMSafePageUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }
    try {
        $uri = [Uri]$Url
        if ($uri.Scheme -notin @('http', 'https')) {
            return $null
        }
        $builder = [UriBuilder]::new($uri.Scheme, $uri.Host, $uri.Port, $uri.AbsolutePath)
        $builder.Query = ''
        $builder.Fragment = ''
        return $builder.Uri.AbsoluteUri
    }
    catch {
        return $null
    }
}

function ConvertTo-PMSafePageTitle {
    param([string]$Title)
    if ([string]::IsNullOrWhiteSpace($Title)) {
        return $null
    }
    $clean = [regex]::Replace($Title, '[\x00-\x1F\x7F]', ' ').Trim()
    if ($clean.Length -gt 160) {
        return $clean.Substring(0, 160)
    }
    return $clean
}

function Get-PMPreviousLoginStatus {
    param([object]$Resource)
    if ($null -eq $Resource -or $null -eq $Resource.lastStatus) {
        return '未检测'
    }
    $value = [string]$Resource.lastStatus.loginStatus
    if ($value -notin (Get-PMLoginStates)) {
        return '未检测'
    }
    return $value
}

function Resolve-PMLoginStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource,
        [bool]$BrowserConnected,
        [string]$PageStatus,
        [object[]]$PageTargets,
        [object[]]$AuthenticatedEvidenceRules,
        [string]$DetectionError,
        [string]$CheckedAt
    )

    if ([string]::IsNullOrWhiteSpace($CheckedAt)) {
        $CheckedAt = [DateTimeOffset]::Now.ToString('o')
    }
    $previous = Get-PMPreviousLoginStatus -Resource $Resource
    $pages = @($PageTargets)
    $primaryPage = @($pages | Where-Object {
        (Test-PMLoginPatternMatch -Value ([string]$_.url) -Patterns @($Resource.platformUrlPatterns)) -or
        (Test-PMLoginPatternMatch -Value ([string]$_.title) -Patterns @($Resource.platformUrlPatterns))
    } | Select-Object -First 1)
    if ($primaryPage.Count -eq 0) {
        $primaryPage = @($pages | Select-Object -First 1)
    }
    $page = if ($primaryPage.Count -gt 0) { $primaryPage[0] } else { $null }
    $safeUrl = if ($null -eq $page) { $null } else { ConvertTo-PMSafePageUrl -Url ([string]$page.url) }
    $safeTitle = if ($null -eq $page) { $null } else { ConvertTo-PMSafePageTitle -Title ([string]$page.title) }

    if (-not [string]::IsNullOrWhiteSpace($DetectionError)) {
        return [pscustomobject]@{
            loginStatus = '检测失败'
            loginEvidence = New-PMLoginEvidence -State '检测失败' -EvidenceType 'detector-error' `
                -EvidenceSummary '登录检测过程异常，未形成登录结论。' -PageUrl $safeUrl -PageTitle $safeTitle `
                -CheckedAt $CheckedAt -Confidence 'unknown'
            loginCheckedAt = $CheckedAt
        }
    }

    if (-not $BrowserConnected -or $PageStatus -ne '平台页面正确') {
        return [pscustomobject]@{
            loginStatus = '登录状态未知'
            loginEvidence = New-PMLoginEvidence -State '登录状态未知' -EvidenceType 'none' `
                -EvidenceSummary 'Chrome 或慧策页面尚未满足登录证据检查条件。' -PageUrl $safeUrl -PageTitle $safeTitle `
                -CheckedAt $CheckedAt -Confidence 'unknown'
            loginCheckedAt = $CheckedAt
        }
    }

    $loginPage = @($pages | Where-Object {
        (Test-PMLoginPatternMatch -Value ([string]$_.url) -Patterns @($Resource.loginPagePatterns)) -or
        (Test-PMLoginPatternMatch -Value ([string]$_.title) -Patterns @($Resource.loginPagePatterns))
    } | Select-Object -First 1)
    if ($loginPage.Count -gt 0) {
        $state = if ($previous -eq '已登录') { '登录已失效' } else { '未登录' }
        $type = if ($state -eq '登录已失效') { 'session-invalidated' } else { 'login-page-rule' }
        $summary = if ($state -eq '登录已失效') {
            '历史状态为已登录，本次页面匹配明确登录页规则。'
        }
        else {
            '当前页面匹配明确登录页规则。'
        }
        return [pscustomobject]@{
            loginStatus = $state
            loginEvidence = New-PMLoginEvidence -State $state -EvidenceType $type -EvidenceSummary $summary `
                -PageUrl (ConvertTo-PMSafePageUrl -Url ([string]$loginPage[0].url)) `
                -PageTitle (ConvertTo-PMSafePageTitle -Title ([string]$loginPage[0].title) `
                ) -CheckedAt $CheckedAt -Confidence 'confirmed'
            loginCheckedAt = $CheckedAt
        }
    }

    $enabledRules = @($AuthenticatedEvidenceRules | Where-Object { [bool]$_.enabled })
    if ($enabledRules.Count -eq 0) {
        return [pscustomobject]@{
            loginStatus = '登录状态未知'
            loginEvidence = New-PMLoginEvidence -State '登录状态未知' -EvidenceType 'none' `
                -EvidenceSummary '页面属于慧策，但适配器没有已启用且经确认的鉴权证据规则。' `
                -PageUrl $safeUrl -PageTitle $safeTitle -CheckedAt $CheckedAt -Confidence 'unknown'
            loginCheckedAt = $CheckedAt
        }
    }

    return [pscustomobject]@{
        loginStatus = '登录状态未知'
        loginEvidence = New-PMLoginEvidence -State '登录状态未知' -EvidenceType 'none' `
            -EvidenceSummary '鉴权证据提供器尚未返回可复核结论。' `
            -PageUrl $safeUrl -PageTitle $safeTitle -CheckedAt $CheckedAt -Confidence 'unknown'
        loginCheckedAt = $CheckedAt
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-PMSafePageUrl',
    'ConvertTo-PMSafePageTitle',
    'Resolve-PMLoginStatus'
)
