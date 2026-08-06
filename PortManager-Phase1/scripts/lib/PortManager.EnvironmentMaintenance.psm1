Set-StrictMode -Version Latest

$script:AllowedProfileRoot = [IO.Path]::GetFullPath('F:\XIANGMU\BS Claw\_portmanager-profiles').TrimEnd('\')
$script:ExcludedLoginData = @(
    'Cookies', 'Local Storage', 'Session Storage', 'Preferences', 'IndexedDB',
    'Profile SQLite databases', 'resource definitions', 'CredentialRef',
    'masked account summary', 'audit records', 'login session events'
)

function New-PMMaintenanceError {
    param(
        [Parameter(Mandatory = $true)][string]$ErrorCode,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$NextAction
    )
    return New-PMStructuredException -ErrorCode $ErrorCode -Message $Message -NextAction $NextAction
}

function Test-PMProfileRunning {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)
    $fullPath = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    try {
        $escaped = [regex]::Escape($fullPath)
        $processes = @(
            Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction Stop |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
                    [string]$_.CommandLine -match $escaped
                }
        )
        return [pscustomobject]@{
            running = $processes.Count -gt 0
            processIds = @($processes | ForEach-Object { [int]$_.ProcessId })
        }
    }
    catch {
        throw (New-PMMaintenanceError -ErrorCode 'PM_PROFILE_RUNNING_CHECK_FAILED' `
            -Message ('无法确认浏览器配置是否正在使用：' + $_.Exception.Message) `
            -NextAction '确认 Windows 进程查询权限正常后重试。')
    }
}

function Assert-PMMaintenanceProfile {
    param([Parameter(Mandatory = $true)][object]$Resource)
    if ([string]$Resource.connectionMode -ne 'Launch' -or
        [string]::IsNullOrWhiteSpace([string]$Resource.browserProfileDirectory)) {
        throw (New-PMMaintenanceError -ErrorCode 'PM_PROFILE_NOT_MANAGED' `
            -Message "资源 $($Resource.resourceId) 没有可管理的独立浏览器配置。" `
            -NextAction '请选择以自动启动 Chrome 方式登记、且具有 F 盘独立配置目录的资源。')
    }
    $fullPath = [IO.Path]::GetFullPath([string]$Resource.browserProfileDirectory)
    if (-not $fullPath.StartsWith(($script:AllowedProfileRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-PMMaintenanceError -ErrorCode 'PM_PROFILE_PATH_NOT_ALLOWED' `
            -Message "资源配置目录不在允许的受控范围内：$fullPath" `
            -NextAction "仅允许管理 $($script:AllowedProfileRoot) 下的资源配置。")
    }
    return $fullPath
}

function Get-PMDeploymentGuidance {
    return [pscustomobject][ordered]@{
        preserve = @(
            '代码、脚本、适配器和正式文档',
            'SQLite schema、迁移记录、资源定义',
            'CredentialRef 引用和脱敏账号摘要',
            '正式审计记录与登录会话事件',
            '需要复用登录态时的非缓存 Profile 数据'
        )
        reproducible = @(
            'Chrome 可再生缓存', '临时日志', 'IPC 临时文件', 'Python 缓存',
            '测试运行目录', '过期租约', 'Watcher PID/心跳', '临时探针结果'
        )
        rediscoverAfterMigration = @(
            'Chrome 可执行文件路径', '端口占用', 'Watcher 与进程 PID',
            '登录状态新鲜度', '真实页面状态', 'API 只读探针状态'
        )
        loginReuse = '需要复用登录态时保留非缓存 Profile；不复用时在新设备打开该资源后执行 Login。'
    }
}

function Get-PMCachePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ResourceId)
    $resource = Get-PMResourceById -ResourceId $ResourceId
    $profilePath = Assert-PMMaintenanceProfile -Resource $resource
    $before = Get-PMProfileMetrics -ProfilePath $profilePath
    $cleanupPlan = Invoke-PMProfileCacheCleanup -ProfilePath $profilePath
    $usage = Test-PMProfileRunning -ProfilePath $profilePath
    $result = [pscustomobject][ordered]@{
        action = 'CachePlan'
        executeMode = 'dry-run'
        resourceId = [string]$resource.resourceId
        port = [int]$resource.port
        profilePath = $profilePath
        profileRunning = [bool]$usage.running
        runningProcessIds = @($usage.processIds)
        canExecute = (-not [bool]$usage.running -and @($cleanupPlan.errors).Count -eq 0)
        totalBytes = [int64]$before.sizeBytes
        cacheBytes = [int64]$before.cacheBytes
        nonCacheBytes = [int64]($before.sizeBytes - $before.cacheBytes)
        totalFiles = [int]$before.fileCount
        plannedBytes = [int64]$cleanupPlan.plannedBytes
        plannedFiles = [int]$cleanupPlan.plannedFiles
        plannedDirectoryCount = @($cleanupPlan.plannedDirectories).Count
        plannedDirectories = @($cleanupPlan.plannedDirectories)
        excludedData = @($script:ExcludedLoginData)
        errors = @($cleanupPlan.errors)
        nextAction = if ([bool]$usage.running) {
            '先正常关闭该端口对应的 Chrome，再执行 CleanCache。'
        } else {
            "执行 CleanCache，并提供精确确认文本：确认清理可再生缓存 $ResourceId"
        }
        deploymentGuidance = Get-PMDeploymentGuidance
    }
    Write-PMAudit -Action 'CachePlan' -ResourceId $ResourceId -Outcome 'Planned' `
        -Message '已生成可再生缓存清理预览，未删除任何数据。' -Details @{
            profilePath = $profilePath
            plannedBytes = [int64]$result.plannedBytes
            plannedDirectories = [int]$result.plannedDirectoryCount
            excludedData = @($result.excludedData)
            beforeMetrics = $before
            executeMode = 'dry-run'
            confirmationUsed = $false
            profileRunning = [bool]$result.profileRunning
        }
    $result | Add-Member -MemberType NoteProperty -Name auditId -Value (Get-PMLastAuditId) -Force
    return $result
}

function Get-PMDeploymentCleanPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ResourceId)
    $cache = Get-PMCachePlan -ResourceId $ResourceId
    $storage = Get-PMStorageAudit -ResourceId $ResourceId
    $result = [pscustomobject][ordered]@{
        action = 'DeploymentCleanPlan'
        executeMode = 'dry-run'
        resourceId = $ResourceId
        cachePlan = $cache
        storageAudit = $storage
        guidance = Get-PMDeploymentGuidance
        warning = '本计划不删除数据。迁移登录态时必须保留非缓存 Profile 数据。'
    }
    Write-PMAudit -Action 'DeploymentCleanPlan' -ResourceId $ResourceId -Outcome 'Planned' `
        -Message '已生成跨机器部署清理建议，未删除任何数据。' -Details @{
            profilePath = [string]$cache.profilePath
            plannedBytes = [int64]$cache.plannedBytes
            plannedDirectories = [int]$cache.plannedDirectoryCount
            excludedData = @($cache.excludedData)
            executeMode = 'dry-run'
            confirmationUsed = $false
        }
    $result | Add-Member -MemberType NoteProperty -Name auditId -Value (Get-PMLastAuditId) -Force
    return $result
}

function Invoke-PMResourceCacheCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [string]$ConfirmationText
    )
    $expected = "确认清理可再生缓存 $ResourceId"
    if ($ConfirmationText -cne $expected) {
        throw (New-PMMaintenanceError -ErrorCode 'PM_CACHE_CONFIRMATION_REQUIRED' `
            -Message "未执行清理。确认文本必须完全等于：$expected" `
            -NextAction "确认已关闭对应 Chrome 后，重新执行并提供 -ConfirmationText `"$expected`"。")
    }
    $lease = $null
    $profilePath = $null
    $before = $null
    try {
        $lease = Set-PMLease -ResourceId $ResourceId -Operation '清理可再生缓存' -DurationSeconds 300 -TaskRef 'port-maintenance-clean-cache'
        $plan = Get-PMCachePlan -ResourceId $ResourceId
        $profilePath = [string]$plan.profilePath
        if ([bool]$plan.profileRunning) {
            throw (New-PMMaintenanceError -ErrorCode 'PM_PROFILE_IN_USE' `
                -Message '该端口浏览器正在运行，未删除任何缓存。' `
                -NextAction '请先正常关闭该端口对应的 Chrome，再重新执行 CleanCache；程序不会自动关闭浏览器。')
        }
        $before = Get-PMProfileMetrics -ProfilePath $profilePath
        $auditRoot = Join-Path (Get-PMRuntimeRoot) 'data\maintenance-audits'
        $auditPath = Join-Path $auditRoot (
            'cache-clean-{0}-{1}.json' -f $ResourceId, [DateTime]::Now.ToString('yyyyMMdd-HHmmssfff')
        )
        $cleanup = Invoke-PMProfileCacheCleanup -ProfilePath $profilePath -Execute `
            -ConfirmationText '确认清理可再生缓存' -AuditRecordPath $auditPath
        $after = Get-PMProfileMetrics -ProfilePath $profilePath
        $latest = Get-PMResourceById -ResourceId $ResourceId
        $loginBefore = [pscustomobject]@{
            loginStatus = [string]$latest.lastStatus.loginStatus
            loginApiProbeStatus = [string]$latest.lastStatus.loginApiProbeStatus
            loginConfidence = [string]$latest.lastStatus.loginConfidence
        }
        $latest.lastStatus.profileMetrics = $after
        Save-PMResourceStatus -ResourceId $ResourceId -Status $latest.lastStatus
        $outcome = if (@($cleanup.errors).Count -eq 0) { 'Success' } else { 'PartialFailure' }
        Write-PMAudit -Action 'CleanCache' -ResourceId $ResourceId -Outcome $outcome `
            -Message '可再生缓存清理已执行；登录状态未由本操作修改。' -Details @{
                profilePath = $profilePath
                plannedBytes = [int64]$plan.plannedBytes
                plannedDirectories = @($plan.plannedDirectories).Count
                removedBytes = [int64]$cleanup.removedBytes
                removedFiles = [int]$cleanup.removedFiles
                removedDirectories = @($cleanup.removedDirectories).Count
                excludedData = @($script:ExcludedLoginData)
                beforeMetrics = $before
                afterMetrics = $after
                executeMode = 'execute'
                confirmationUsed = $true
                loginStatePreserved = $loginBefore
                fileAuditPath = $auditPath
            }
        if (@($cleanup.errors).Count -gt 0) {
            throw (New-PMMaintenanceError -ErrorCode 'PM_CACHE_CLEANUP_PARTIAL' `
                -Message '部分缓存未能清理，已刷新指标并记录审计。' `
                -NextAction '查看返回的审计路径和错误摘要，确认文件占用后重试。')
        }
        return [pscustomobject][ordered]@{
            action = 'CleanCache'
            executeMode = 'execute'
            resourceId = $ResourceId
            profilePath = $profilePath
            beforeMetrics = $before
            afterMetrics = $after
            plannedBytes = [int64]$plan.plannedBytes
            plannedDirectoryCount = @($plan.plannedDirectories).Count
            removedBytes = [int64]$cleanup.removedBytes
            removedFiles = [int]$cleanup.removedFiles
            removedDirectoryCount = @($cleanup.removedDirectories).Count
            excludedData = @($script:ExcludedLoginData)
            loginStatePreserved = $loginBefore
            auditId = Get-PMLastAuditId
            auditRecordPath = $auditPath
        }
    }
    catch {
        if ($null -ne $profilePath) {
            try {
                Write-PMAudit -Action 'CleanCache' -ResourceId $ResourceId -Outcome 'Failed' `
                    -Message $_.Exception.Message -Details @{
                        profilePath = $profilePath
                        plannedBytes = if ($null -eq $before) { 0L } else { [int64]$before.cacheBytes }
                        plannedDirectories = 0
                        removedBytes = 0L
                        excludedData = @($script:ExcludedLoginData)
                        executeMode = 'execute'
                        confirmationUsed = $true
                    }
            } catch { }
        }
        throw
    }
    finally {
        if ($null -ne $lease) { Remove-PMLease -LeaseId $lease.leaseId }
    }
}

function Test-PMPortAvailable {
    param([Parameter(Mandatory = $true)][int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $connected = $async.AsyncWaitHandle.WaitOne(120)
        if ($connected) {
            try { $client.EndConnect($async) } catch { }
            return $false
        }
        return $true
    }
    catch { return $true }
    finally { $client.Dispose() }
}

function Get-PMLoginTestPort {
    param([object[]]$Resources, [int]$SourcePort, [int]$PreferredPort)
    $registered = @($Resources | ForEach-Object { [int]$_.port })
    if ($PreferredPort -gt 0) {
        if ($PreferredPort -lt 1024 -or $PreferredPort -gt 65535 -or $PreferredPort -in $registered -or
            -not (Test-PMPortAvailable -Port $PreferredPort)) {
            throw (New-PMMaintenanceError -ErrorCode 'PM_LOGIN_TEST_PORT_UNAVAILABLE' `
                -Message "指定测试端口 $PreferredPort 不可用。" `
                -NextAction '不传 -TestPort 让程序自动选择，或选择未登记且未占用的 1024-65535 端口。')
        }
        return $PreferredPort
    }
    foreach ($candidate in (($SourcePort + 1)..([Math]::Min($SourcePort + 1000, 65535)))) {
        if ($candidate -notin $registered -and (Test-PMPortAvailable -Port $candidate)) { return $candidate }
    }
    throw (New-PMMaintenanceError -ErrorCode 'PM_LOGIN_TEST_PORT_NOT_FOUND' `
        -Message '没有找到可用的独立测试端口。' `
        -NextAction '释放一个本机端口，或通过 -TestPort 指定未登记且未占用的端口。')
}

function New-PMLoginTestProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceResourceId,
        [int]$PreferredPort
    )
    $lease = $null
    $profilePath = $null
    $created = $null
    try {
        $lease = Set-PMLease -ResourceId $SourceResourceId -Operation '创建登录测试环境' `
            -DurationSeconds 300 -TaskRef 'port-maintenance-login-test-profile'
        $source = Get-PMResourceById -ResourceId $SourceResourceId
        $null = Assert-PMMaintenanceProfile -Resource $source
        $resources = @(Get-PMResources)
        $port = Get-PMLoginTestPort -Resources $resources -SourcePort ([int]$source.port) -PreferredPort $PreferredPort
        $profileName = 'login-test-{0}-{1}' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
        $profilePath = Join-Path $script:AllowedProfileRoot $profileName
        [IO.Directory]::CreateDirectory($profilePath) | Out-Null
        $created = Register-PMResource -ResourceName ("$($source.resourceName)-登录测试") `
            -PlatformName ([string]$source.platformName) -HostName '127.0.0.1' -Port $port `
            -ConnectionMode 'Launch' -BrowserExecutable ([string]$source.browserExecutable) `
            -BrowserProfileDirectory $profilePath -StartUrl ([string]$source.startUrl) `
            -PlatformUrlPatterns @($source.platformUrlPatterns) -LoginPagePatterns @($source.loginPagePatterns) `
            -Enabled $true -Notes "由 $SourceResourceId 创建的独立登录测试环境；不复制登录会话。" `
            -CredentialRef ([string]$source.credentialRef) -MaskedAccountSummary ([string]$source.maskedAccountSummary)
        $status = $created.lastStatus
        $now = Get-PMNow
        $status.loginStatus = '未登录'
        $status.loginApiProbeStatus = 'login-required'
        $status.loginConfidence = 'none'
        $status.loginDetectionState = '未检测'
        $status.loginCheckedAt = $now
        if ($status.PSObject.Properties.Name -contains 'lastAuthenticatedAt') {
            $status.lastAuthenticatedAt = $null
        }
        else {
            $status | Add-Member -MemberType NoteProperty -Name lastAuthenticatedAt -Value $null
        }
        $status.lastError = $null
        $status.profileMetrics = Get-PMProfileMetrics -ProfilePath $profilePath
        $status.loginEvidence.state = '未登录'
        $status.loginEvidence.evidenceType = 'none'
        $status.loginEvidence.evidenceSummary = '独立登录测试环境尚未登录。'
        $status.loginEvidence.checkedAt = $now
        $status.loginEvidence.confidence = 'none'
        $status.loginEvidence.source = 'port-manager.login-test-profile'
        Save-PMResourceStatus -ResourceId $created.resourceId -Status $status
        Write-PMAudit -Action 'LoginTestProfileCreate' -ResourceId $created.resourceId -Outcome 'Success' `
            -Message '已创建独立登录测试资源；未复制密码、Token、Cookie 或浏览器会话。' -Details @{
                sourceResourceId = $SourceResourceId
                profilePath = $profilePath
                port = $port
                credentialRefCopied = -not [string]::IsNullOrWhiteSpace([string]$source.credentialRef)
                sessionDataCopied = $false
                executeMode = 'execute'
                confirmationUsed = $false
                excludedData = @('password','Token','Cookie','authorization header','browser session data')
            }
        $finalResource = Get-PMResourceById -ResourceId $created.resourceId
        return [pscustomobject][ordered]@{
            action = 'CreateLoginTestProfile'
            sourceResourceId = $SourceResourceId
            resource = $finalResource
            copied = [pscustomobject]@{
                resourceConfiguration = $true
                credentialRef = -not [string]::IsNullOrWhiteSpace([string]$source.credentialRef)
                maskedAccountSummary = -not [string]::IsNullOrWhiteSpace([string]$source.maskedAccountSummary)
                secrets = $false
                browserSession = $false
            }
            nextAction = "执行 HuiceLoginAgent Login，ResourceId 为 $($created.resourceId)。"
            auditId = Get-PMLastAuditId
        }
    }
    catch {
        if ($null -ne $created) {
            try {
                Remove-PMResource -ResourceId ([string]$created.resourceId) `
                    -ConfirmationText ("删除 " + [string]$created.resourceId) | Out-Null
            }
            catch {
                throw (New-PMMaintenanceError -ErrorCode 'PM_LOGIN_TEST_PROFILE_ROLLBACK_FAILED' `
                    -Message "测试资源创建失败，且自动回滚资源 $($created.resourceId) 失败。" `
                    -NextAction '不要使用该半成品资源；查看审计记录并由端口管理员确认后删除。')
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($profilePath) -and
            (Test-Path -LiteralPath $profilePath -PathType Container)) {
            $registeredPath = @(Get-PMResources | Where-Object {
                [string]$_.browserProfileDirectory -eq $profilePath
            }).Count -gt 0
            if (-not $registeredPath -and
                $profilePath.StartsWith(($script:AllowedProfileRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
            }
        }
        throw
    }
    finally {
        if ($null -ne $lease) { Remove-PMLease -LeaseId $lease.leaseId }
    }
}

function Get-PMResetLoginPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ResourceId)
    $resource = Get-PMResourceById -ResourceId $ResourceId
    $profilePath = Assert-PMMaintenanceProfile -Resource $resource
    $usage = Test-PMProfileRunning -ProfilePath $profilePath
    $result = [pscustomobject][ordered]@{
        action = 'ResetLoginPlan'
        executeMode = 'dry-run'
        resourceId = $ResourceId
        profilePath = $profilePath
        profileRunning = [bool]$usage.running
        implemented = $false
        changed = $false
        warning = '本阶段不提供原资源登录态删除。推荐创建独立登录测试环境，避免破坏当前可复用会话。'
        recommendedAction = 'CreateLoginTestProfile'
        nextAction = "执行 -Action CreateLoginTestProfile -ResourceId $ResourceId"
    }
    Write-PMAudit -Action 'ResetLoginStatePlan' -ResourceId $ResourceId -Outcome 'Planned' `
        -Message '已生成登录重测安全方案；未删除会话或修改登录状态。' -Details @{
            profilePath = $profilePath
            executeMode = 'dry-run'
            confirmationUsed = $false
            profileRunning = [bool]$usage.running
            recommendedAction = 'CreateLoginTestProfile'
        }
    $result | Add-Member -MemberType NoteProperty -Name auditId -Value (Get-PMLastAuditId) -Force
    return $result
}

function Write-PMCachePlanText {
    param([object]$Plan)
    Write-Host "资源：$($Plan.resourceId) / 端口 $($Plan.port)"
    Write-Host ("配置总大小：{0:N2} MB" -f ($Plan.totalBytes / 1MB))
    Write-Host ("可再生缓存：{0:N2} MB；非缓存数据：{1:N2} MB" -f ($Plan.cacheBytes / 1MB), ($Plan.nonCacheBytes / 1MB))
    Write-Host "预计清理：$($Plan.plannedDirectoryCount) 个目录、$($Plan.plannedFiles) 个文件"
    Write-Host $(if ($Plan.profileRunning) { '当前浏览器正在使用该资源，不能执行真实清理。' } else { '当前可以执行真实清理。' })
    Write-Host '不会清理登录复用数据、资源定义、凭据引用或审计记录。'
}

function Write-PMDeploymentPlanText {
    param([object]$Plan)
    Write-PMCachePlanText -Plan $Plan.cachePlan
    Write-Host ''
    Write-Host '部署前保留：代码、数据库事实源、凭据引用、正式审计，以及需要复用登录时的非缓存配置。'
    Write-Host '迁移后重建：Chrome 路径、端口占用、进程/Watcher、登录新鲜度和 API 探针。'
}

function Write-PMCleanupResultText {
    param([object]$Result)
    Write-Host '可再生缓存清理完成，登录状态未改变。'
    Write-Host ("清理前：{0:N2} MB；清理后：{1:N2} MB；删除：{2:N2} MB" -f `
        ($Result.beforeMetrics.sizeBytes / 1MB), ($Result.afterMetrics.sizeBytes / 1MB), ($Result.removedBytes / 1MB))
    Write-Host "审计编号：$($Result.auditId)"
}

function Write-PMLoginTestProfileText {
    param([object]$Result)
    Write-Host '独立登录测试环境已创建，不影响当前已登录资源。'
    Write-Host "新资源：$($Result.resource.resourceId) / 端口 $($Result.resource.port)"
    Write-Host '新环境没有复制密码、Token、Cookie 或浏览器登录会话。'
    Write-Host "下一步：$($Result.nextAction)"
}

function Write-PMResetLoginPlanText {
    param([object]$Plan)
    Write-Host '未执行登录状态重置。'
    Write-Host $Plan.warning
    Write-Host "下一步：$($Plan.nextAction)"
}

function Show-PMEnvironmentMaintenanceMenu {
    Write-Host ''
    Write-Host '清理端口环境'
    Write-Host '1. 查看可清理缓存大小（不删除）'
    Write-Host '2. 清理指定端口可再生缓存（不影响登录）'
    Write-Host '3. 创建干净登录测试环境（推荐）'
    Write-Host '4. 查看登录状态重测方案（不执行删除）'
    Write-Host '5. 查看部署前清理建议（不删除）'
    Write-Host '6. 查看全模块体积与推广风险（不删除）'
    Write-Host '0. 返回'
    $choice = Read-Host '请选择操作'
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '0') { return }
    if ($choice -eq '6') {
        Write-PMStorageAuditText -Audit (Get-PMStorageAudit)
        return
    }
    $resourceId = (Read-Host '请输入资源编号').Trim().ToUpperInvariant()
    switch ($choice) {
        '1' { Write-PMCachePlanText -Plan (Get-PMCachePlan -ResourceId $resourceId) }
        '2' {
            Write-Host '此操作不会退出登录；必须先关闭该端口对应的 Chrome。'
            $confirmation = Read-Host "确认执行请输入“确认清理可再生缓存 $resourceId”"
            Write-PMCleanupResultText -Result (Invoke-PMResourceCacheCleanup -ResourceId $resourceId -ConfirmationText $confirmation)
        }
        '3' { Write-PMLoginTestProfileText -Result (New-PMLoginTestProfile -SourceResourceId $resourceId) }
        '4' { Write-PMResetLoginPlanText -Plan (Get-PMResetLoginPlan -ResourceId $resourceId) }
        '5' { Write-PMDeploymentPlanText -Plan (Get-PMDeploymentCleanPlan -ResourceId $resourceId) }
        default { Write-Host '输入无效，请输入 0 到 6。' }
    }
}

Export-ModuleMember -Function @(
    'Get-PMCachePlan',
    'Get-PMDeploymentCleanPlan',
    'Invoke-PMResourceCacheCleanup',
    'New-PMLoginTestProfile',
    'Get-PMResetLoginPlan',
    'Write-PMCachePlanText',
    'Write-PMDeploymentPlanText',
    'Write-PMCleanupResultText',
    'Write-PMLoginTestProfileText',
    'Write-PMResetLoginPlanText',
    'Show-PMEnvironmentMaintenanceMenu'
)
