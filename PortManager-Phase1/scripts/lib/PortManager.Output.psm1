Set-StrictMode -Version Latest

$huiceModule = Join-Path $PSScriptRoot 'PortManager.Huice.psm1'
Import-Module $huiceModule -Force

function Write-PMJsonEnvelope {
    param(
        [bool]$Success,
        [string]$Message,
        [object]$Data,
        [string]$NextAction,
        [string]$ErrorCode,
        [string]$ResourceId,
        [string]$LeaseId,
        [string]$AuditId,
        [string]$TaskId
    )
    [ordered]@{
        success = $Success
        message = $Message
        data = $Data
        nextAction = if ([string]::IsNullOrWhiteSpace($NextAction)) { $null } else { $NextAction }
        errorCode = if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { $ErrorCode }
        resourceId = if ([string]::IsNullOrWhiteSpace($ResourceId)) { $null } else { $ResourceId }
        leaseId = if ([string]::IsNullOrWhiteSpace($LeaseId)) { $null } else { $LeaseId }
        auditId = if ([string]::IsNullOrWhiteSpace($AuditId)) { $null } else { $AuditId }
        taskId = if ([string]::IsNullOrWhiteSpace($TaskId)) { $null } else { $TaskId }
    } | ConvertTo-Json -Depth 24
}

function Get-PMErrorNextActionOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$ErrorRecord
    )
    if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.Exception -and
        $ErrorRecord.Exception.Data.Contains('nextAction')) {
        return [string]$ErrorRecord.Exception.Data['nextAction']
    }
    return Get-PMErrorNextAction -Message $Message
}

function Get-PMErrorCodeOutput {
    param([object]$ErrorRecord)
    if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.Exception -and
        $ErrorRecord.Exception.Data.Contains('errorCode')) {
        return [string]$ErrorRecord.Exception.Data['errorCode']
    }
    return $null
}

function Write-PMResourceListOutput {
    param([object[]]$Resources)
    if ($Resources.Count -eq 0) {
        Write-Host '当前没有已注册端口。'
        Write-Host '下一步：选择菜单 1 注册慧策通。'
        return
    }
    $Resources | Select-Object `
        @{Name = '资源编号'; Expression = { $_.resourceId } },
        @{Name = '资源名称'; Expression = { $_.resourceName } },
        @{Name = '平台'; Expression = { $_.platformName } },
        @{Name = '地址'; Expression = { $_.hostName } },
        @{Name = '端口'; Expression = { $_.port } },
        @{Name = '启用'; Expression = { if ($_.enabled) { '是' } else { '否' } } },
        @{Name = '最近操作'; Expression = { $_.lastStatus.operationStatus } },
        @{Name = '连接状态'; Expression = { $_.lastStatus.connectionStatus } },
        @{Name = '登录状态'; Expression = { $_.lastStatus.loginStatus } },
        @{Name = '当前占用'; Expression = { $_.lastStatus.currentOccupancy } },
        @{Name = '最后检测时间'; Expression = { $_.lastStatus.lastCheckedAt } },
        @{Name = '最后错误'; Expression = { $_.lastStatus.lastError } } |
        Format-Table -AutoSize -Wrap
}

function Write-PMResourceDetailOutput {
    param([object]$Resource)
    [pscustomobject]@{
        资源编号 = $Resource.resourceId
        资源名称 = $Resource.resourceName
        平台名称 = $Resource.platformName
        主机地址 = $Resource.hostName
        端口号 = $Resource.port
        连接方式 = $Resource.connectionMode
        浏览器程序 = $Resource.browserExecutable
        浏览器配置目录 = $Resource.browserProfileDirectory
        慧策页面地址 = $Resource.startUrl
        启用状态 = if ($Resource.enabled) { '启用' } else { '停用' }
        最近操作 = $Resource.lastStatus.operationStatus
        连接状态 = $Resource.lastStatus.connectionStatus
        浏览器状态 = $Resource.lastStatus.browserStatus
        页面状态 = $Resource.lastStatus.pageStatus
        登录状态 = $Resource.lastStatus.loginStatus
        登录证据 = $Resource.lastStatus.loginEvidence.evidenceSummary
        登录检测时间 = $Resource.lastStatus.loginCheckedAt
        当前占用 = $Resource.lastStatus.currentOccupancy
        最后检测时间 = $Resource.lastStatus.lastCheckedAt
        最后错误 = $Resource.lastStatus.lastError
        注册时间 = $Resource.registeredAt
        更新时间 = $Resource.updatedAt
    } | Format-List
}

function Write-PMCheckOutput {
    param([object]$Result)
    $resource = $Result.Resource
    $status = $Result.Status
    [pscustomobject]@{
        资源编号 = $resource.resourceId
        地址端口 = "$($resource.hostName):$($resource.port)"
        连接状态 = $status.connectionStatus
        浏览器状态 = $status.browserStatus
        页面状态 = $status.pageStatus
        登录状态 = $status.loginStatus
        登录证据 = $status.loginEvidence.evidenceSummary
        登录检测时间 = $status.loginCheckedAt
        当前占用 = $status.currentOccupancy
        检测时间 = $status.lastCheckedAt
        失败原因 = $status.lastError
        最近操作 = $status.operationStatus
    } | Format-List
    Write-Host "下一步：$(Get-PMStatusNextAction -Status $status -Resource $resource)"
}

function Write-PMOpenOutput {
    param([object]$Result)
    $resource = $Result.Resource
    $status = $Result.Status
    [pscustomobject]@{
        资源编号 = $resource.resourceId
        端口 = $resource.port
        浏览器状态 = $status.browserStatus
        调试接口状态 = if ($status.debugEndpoint) { '可访问' } else { '不可访问' }
        页面状态 = $status.pageStatus
        登录状态 = $status.loginStatus
        登录证据 = $status.loginEvidence.evidenceSummary
        登录检测时间 = $status.loginCheckedAt
        新启动进程 = $Result.BrowserProcessId
        最后错误 = $status.lastError
    } | Format-List
    Write-Host "下一步：$(Get-PMStatusNextAction -Status $status -Resource $resource)"
}

Export-ModuleMember -Function @(
    'Write-PMJsonEnvelope',
    'Get-PMErrorNextActionOutput',
    'Get-PMErrorCodeOutput',
    'Write-PMResourceListOutput',
    'Write-PMResourceDetailOutput',
    'Write-PMCheckOutput',
    'Write-PMOpenOutput'
)
