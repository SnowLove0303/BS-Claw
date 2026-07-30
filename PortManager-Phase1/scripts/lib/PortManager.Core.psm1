Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Net.Http

$stateModulePath = Join-Path $PSScriptRoot 'PortManager.State.psm1'
$persistenceModulePath = Join-Path $PSScriptRoot 'PortManager.Persistence.psm1'
$loginModulePath = Join-Path $PSScriptRoot 'PortManager.Login.psm1'
$chromeModulePath = Join-Path $PSScriptRoot 'PortManager.Chrome.psm1'
$huiceModulePath = Join-Path $PSScriptRoot 'PortManager.Huice.psm1'
$loginDetectorModulePath = Join-Path $PSScriptRoot 'PortManager.LoginStateDetector.psm1'
$profileModulePath = Join-Path $PSScriptRoot 'PortManager.Profile.psm1'
$sqliteModulePath = Join-Path $PSScriptRoot 'PortManager.Sqlite.psm1'
$networkModulePath = Join-Path $PSScriptRoot 'PortManager.Network.psm1'
$performanceModulePath = Join-Path $PSScriptRoot 'PortManager.Performance.psm1'
Import-Module $stateModulePath -Force
Import-Module $persistenceModulePath -Force
Import-Module $loginModulePath -Force
Import-Module $chromeModulePath -Force
Import-Module $huiceModulePath -Force
Import-Module $profileModulePath -Force
Import-Module $sqliteModulePath -Force -WarningAction SilentlyContinue
Import-Module $networkModulePath -Force
Import-Module $performanceModulePath -Force
Import-Module $loginDetectorModulePath -Force -WarningAction SilentlyContinue

$script:ModuleRoot = $PSScriptRoot
$script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $script:ModuleRoot '..\..'))
$runtimeRootOverride = [Environment]::GetEnvironmentVariable('BSCLAW_PM_RUNTIME_ROOT', 'Process')
if ([string]::IsNullOrWhiteSpace($runtimeRootOverride)) {
    # 当前阶段按约束统一将 JSON 运行数据写入项目 data；Chrome Profile 另行隔离。
    $script:RuntimeRoot = $script:ProjectRoot
}
else {
    $script:RuntimeRoot = [IO.Path]::GetFullPath($runtimeRootOverride)
}
if ([IO.Path]::GetPathRoot($script:RuntimeRoot) -notlike 'F:\') {
    throw "运行目录必须位于 F 盘：$($script:RuntimeRoot)"
}
$script:RuntimeRoot = [IO.Path]::GetFullPath($script:RuntimeRoot)
$script:DataRoot = Join-Path $script:RuntimeRoot 'data'
$script:LogsRoot = Join-Path $script:RuntimeRoot 'logs'
$script:StorePath = Join-Path $script:DataRoot 'ports.json'
$script:StoreBackupPath = Join-Path $script:DataRoot 'ports.json.bak'
$script:LeasePath = Join-Path $script:DataRoot 'leases.json'
$script:AuditPath = Join-Path $script:DataRoot 'audit.jsonl'
$script:LogPath = Join-Path $script:LogsRoot 'port-manager.log'
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $runtimeHashBytes = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:RuntimeRoot.ToUpperInvariant()))
    $runtimeHash = ([BitConverter]::ToString($runtimeHashBytes, 0, 8)).Replace('-', '')
}
finally {
    $sha256.Dispose()
}
$script:MutexName = "Local\BSClaw.PortManager.Phase1.$runtimeHash"
$script:SqliteReady = $false
$script:LastAuditId = $null

function Get-PMProjectRoot {
    return $script:ProjectRoot
}

function Get-PMRuntimeRoot {
    return $script:RuntimeRoot
}

function Get-PMNow {
    return [DateTimeOffset]::Now.ToString('o')
}

function Get-PMLastAuditId { return $script:LastAuditId }

function New-PMStructuredException {
    param(
        [Parameter(Mandatory = $true)][string]$ErrorCode,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$NextAction
    )
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['errorCode'] = $ErrorCode
    $exception.Data['nextAction'] = $NextAction
    return $exception
}

function Assert-PMPathOnFDrive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$FieldName = '路径'
    )

    return Assert-PMPersistencePathOnFDrive -Path $Path -FieldName $FieldName
}

function Initialize-PMStorage {
    foreach ($path in @($script:DataRoot, $script:LogsRoot)) {
        $null = New-Item -ItemType Directory -Path $path -Force
        $null = Assert-PMPathOnFDrive -Path $path
    }

    # ports.json/leases.json are legacy migration inputs only. New runtime state is never created or written here.
    if (-not $script:SqliteReady) {
        Initialize-PMSqlite -DataRoot $script:DataRoot -JsonPath $script:StorePath
        $script:SqliteReady = $true
    }
}

function Invoke-PMWriteLock {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    return Invoke-PMPersistenceWriteLock -MutexName $script:MutexName -ScriptBlock $ScriptBlock
}

function Write-PMJsonAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Value,
        [switch]$CreateBackup
    )

    Write-PMPersistedJsonAtomic -Path $Path -Value $Value `
        -BackupPath $script:StoreBackupPath -CreateBackup:$CreateBackup
}

function Read-PMJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return Read-PMPersistedJson -Path $Path
}

function Initialize-PMStatusShape {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Status
    )

    $null = Initialize-PMStatusModel -Status $Status
}

function Read-PMStore {
    Initialize-PMStorage
    $store = Read-PMSqliteStore
    if ($null -eq $store.resources) { $store | Add-Member -MemberType NoteProperty -Name resources -Value @() -Force }
    foreach ($resource in @($store.resources)) {
        $null = Initialize-PMResourceModel -Resource $resource
    }
    return $store
}

function Save-PMStore {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Store
    )

    # SQLite migration max(version) is the single externally visible schemaVersion.
    foreach ($resource in @($Store.resources)) {
        $null = Initialize-PMResourceModel -Resource $resource
    }
    $null = Assert-PMPersistedDataSafety -Value $Store -Context '端口资源数据'
    $Store.updatedAt = Get-PMNow
    Save-PMSqliteStore -Store $Store
}

function Write-PMAudit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string]$ResourceId,
        [Parameter(Mandatory = $true)]
        [string]$Outcome,
        [string]$Message,
        [hashtable]$Details
    )

    Initialize-PMStorage
    $record = [ordered]@{
        timestamp = Get-PMNow
        action = $Action
        resourceId = $ResourceId
        outcome = $Outcome
        message = $Message
        processId = $PID
        details = if ($null -eq $Details) { @{} } else { $Details }
    }
    $null = Assert-PMPersistedDataSafety -Value $record -Context '审计记录'
    $auditId = $null
    try {
        $auditResult = Add-PMSqliteAudit -Audit @{
            action = $Action; resourceId = $ResourceId; outcome = $Outcome; message = $Message
            errorCode = $null; processId = $PID; createdAt = [string]$record.timestamp; details = $record.details
        }
        if ($null -ne $auditResult -and $auditResult.PSObject.Properties.Name -contains 'auditId') { $auditId = [int]$auditResult.auditId }
    }
    catch {
        throw (New-PMStructuredException -ErrorCode 'PM_AUDIT_PERSISTENCE_FAILED' -Message ('审计数据库写入失败：' + $_.Exception.Message) -NextAction '检查 SQLite 数据库、F 盘空间和迁移状态后重试。')
    }
    try {
        $line = $record | ConvertTo-Json -Compress -Depth 8
        [IO.File]::AppendAllText($script:AuditPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
    catch {
        # SQLite is authoritative; JSONL is a best-effort compatibility export.
        Write-PMLog -Level 'WARN' -ResourceId $ResourceId -Message ('审计 JSONL 导出失败（SQLite 已保存）：' + $_.Exception.Message)
    }
    $script:LastAuditId = $auditId
}

function Write-PMLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Level,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$ResourceId
    )

    Initialize-PMStorage
    $safeMessage = ($Message -replace '(?i)(cookie|token|authorization|password|passwd)\s*[:=]\s*\S+', '$1=[已脱敏]') -replace '(?i)Bearer\s+[A-Za-z0-9._~+/=-]{8,}', 'Bearer [已脱敏]'
    $line = '{0} [{1}] ResourceId={2} {3}{4}' -f (Get-PMNow), $Level, $ResourceId, $safeMessage, [Environment]::NewLine
    [IO.File]::AppendAllText($script:LogPath, $line, [Text.UTF8Encoding]::new($false))
}

function Get-PMResourceById {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )
    $store = Read-PMStore
    $resource = @($store.resources | Where-Object { $_.resourceId -eq $ResourceId }) | Select-Object -First 1
    if ($null -eq $resource) {
        throw (New-PMStructuredException -ErrorCode 'PM_RESOURCE_NOT_FOUND' -Message "未找到资源编号：$ResourceId" -NextAction '先查看端口列表，再选择其中的资源重试。')
    }
    Update-PMResourceOccupancyView -Resource $resource
    return $resource
}

function Get-PMResources {
    $store = Read-PMStore
    $resources = @($store.resources | Sort-Object registeredAt)
    foreach ($resource in $resources) {
        Update-PMResourceOccupancyView -Resource $resource
    }
    return @($resources)
}

function Get-PMActiveLeases {
    param([string]$ResourceId, [switch]$SkipStaleReap)
    Initialize-PMStorage
    return @((Get-PMSqliteLeases -ResourceId $ResourceId -SkipStaleReap:$SkipStaleReap).leases)
}

function Set-PMLease {
    param(
        [string]$ResourceId,
        [string]$Operation,
        [int]$DurationSeconds = 60,
        [string]$TaskRef,
        [switch]$RequireLogin
    )

    return Invoke-PMWriteLock {
        $active = @(Get-PMActiveLeases -ResourceId $ResourceId)
        $existing = @($active | Where-Object { $_.resourceId -eq $ResourceId })
        if ($existing.Count -gt 0) {
            throw (New-PMStructuredException -ErrorCode 'RESOURCE_BUSY' -Message 'RESOURCE_BUSY' -NextAction "资源 $ResourceId 正由操作「$($existing[0].operation)」占用；等待其释放后重试。")
        }
        $store = Read-PMStore
        $resource = @($store.resources | Where-Object { $_.resourceId -eq $ResourceId }) | Select-Object -First 1
        if ($null -eq $resource) {
            throw (New-PMStructuredException -ErrorCode 'PM_RESOURCE_NOT_FOUND' -Message "建立租约时未找到资源：$ResourceId" -NextAction '先查看端口列表，再选择已有资源。')
        }
        if (-not [bool]$resource.enabled) {
            throw (New-PMStructuredException -ErrorCode 'PM_RESOURCE_DISABLED' -Message "资源 $ResourceId 已停用，不能申请租约。" -NextAction '启用资源后重试。')
        }
        if ($RequireLogin -and [string]$resource.lastStatus.loginStatus -ne '已登录') {
            throw (New-PMStructuredException -ErrorCode 'PM_LOGIN_REQUIRED' -Message "资源 $ResourceId 当前登录状态不是已登录。" -NextAction '先完成真实登录并重新检测，再申请需要登录的租约。')
        }
        $lease = [pscustomobject]@{
            leaseId = [Guid]::NewGuid().ToString('N')
            resourceId = $ResourceId
            operation = $Operation
            processId = $PID
            startedAt = Get-PMNow
            expiresAt = [DateTimeOffset]::Now.AddSeconds($DurationSeconds).ToString('o')
            taskRef = $TaskRef
        }
        Add-PMSqliteLease -Lease $lease | Out-Null

        $owners = @(
            if (Test-PMLoopbackHost -HostName $resource.hostName) {
                Get-PMPortOwners -Port ([int]$resource.port)
            }
        )
        Set-PMStatusOccupancy -Status $resource.lastStatus -Leases (@($existing) + $lease) -Owners $owners
        Save-PMStore -Store $store
        return $lease
    }
}

function Get-PMResourceOccupancy {
    param([Parameter(Mandatory = $true)][string]$ResourceId)
    $resource = Get-PMResourceById -ResourceId $ResourceId
    $usage = Get-PMUsage -Resource $resource
    return [pscustomobject]@{
        resourceId = $ResourceId
        currentOccupancy = Format-PMUsageOccupancy -Leases @($usage.Leases) -Owners @($usage.Owners)
        activeLeases = @($usage.Leases)
        ownerProcessIds = @($usage.Owners | ForEach-Object { $_.ProcessId })
        loginDetectionTask = $usage.DetectionTask
        checkedAt = Get-PMNow
    }
}

function Remove-PMLease {
    param([string]$LeaseId)
    if ([string]::IsNullOrWhiteSpace($LeaseId)) {
        return
    }
    Invoke-PMWriteLock {
        $removedLease = @(Get-PMActiveLeases -SkipStaleReap | Where-Object { $_.leaseId -eq $LeaseId }) | Select-Object -First 1
        Release-PMSqliteLease -LeaseId $LeaseId

        if ($null -ne $removedLease) {
            $store = Read-PMStore
            $resource = @($store.resources | Where-Object { $_.resourceId -eq $removedLease.resourceId }) | Select-Object -First 1
            if ($null -ne $resource) {
                $remainingLeases = @(Get-PMActiveLeases -SkipStaleReap | Where-Object { $_.resourceId -eq $resource.resourceId })
                $owners = @(
                    if (Test-PMLoopbackHost -HostName $resource.hostName) {
                        Get-PMPortOwners -Port ([int]$resource.port)
                    }
                )
                Set-PMStatusOccupancy -Status $resource.lastStatus -Leases $remainingLeases -Owners $owners
                Save-PMStore -Store $store
            }
        }
    } | Out-Null
}

function Format-PMUsageOccupancy {
    param(
        [object[]]$Leases,
        [object[]]$Owners
    )

    $parts = @()
    $parts += @($Leases | ForEach-Object { "租约:$($_.operation)(PID $($_.processId))" })
    $parts += @($Owners | ForEach-Object { "$($_.ProcessName)(PID $($_.ProcessId))" })
    if ($parts.Count -eq 0) {
        return '无'
    }
    return $parts -join '、'
}

function Set-PMStatusOccupancy {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Status,
        [object[]]$Leases,
        [object[]]$Owners
    )

    $Status | Add-Member -MemberType NoteProperty -Name currentOccupancy -Value (
        Format-PMUsageOccupancy -Leases @($Leases) -Owners @($Owners)
    ) -Force
    $Status | Add-Member -MemberType NoteProperty -Name ownerProcessIds -Value @(
        $Owners | ForEach-Object { $_.ProcessId }
    ) -Force
    $Status | Add-Member -MemberType NoteProperty -Name activeLeases -Value @(
        $Leases | ForEach-Object {
            [pscustomobject]@{
                leaseId = $_.leaseId
                operation = $_.operation
                processId = $_.processId
                startedAt = $_.startedAt
                expiresAt = $_.expiresAt
            }
        }
    ) -Force
    $null = Set-PMStatusOccupancyModel -Status $Status `
        -ActiveLeases @($Status.activeLeases) `
        -OwnerProcessIds @($Status.ownerProcessIds) `
        -Operation ([string]$Status.operationStatus) `
        -CheckedAt ([string]$Status.lastCheckedAt)
}

function Update-PMResourceOccupancyView {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource
    )

    $usage = Get-PMUsage -Resource $Resource
    Set-PMStatusOccupancy -Status $Resource.lastStatus -Leases @($usage.Leases) -Owners @($usage.Owners)
}

function Get-PMUsage {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource
    )
    $leases = @(Get-PMActiveLeases -ResourceId ([string]$Resource.resourceId) | Where-Object { $_.resourceId -eq $Resource.resourceId })
    $owners = @(
        if (Test-PMLoopbackHost -HostName $Resource.hostName) {
            Get-PMPortOwners -Port ([int]$Resource.port)
        }
    )
    $detection = Get-PMSqliteDetectionTask -ResourceId $Resource.resourceId
    # A timed-out task remains occupied until a reaper confirms process exit and
    # the SQLite CAS transition reaches a terminal state.
    $detectionActive = $null -ne $detection -and [string]$detection.state -eq 'running'
    return [pscustomobject]@{
        Leases = $leases
        Owners = $owners
        DetectionTask = if ($detectionActive) { $detection } else { $null }
        InUse = ($leases.Count -gt 0 -or $owners.Count -gt 0 -or $detectionActive)
    }
}

function Throw-PMResourceUsageError {
    param(
        [Parameter(Mandatory = $true)][object]$Usage,
        [Parameter(Mandatory = $true)][string]$OperationName
    )
    if ($Usage.Leases.Count -gt 0) {
        $lease = $Usage.Leases[0]
        throw (New-PMStructuredException -ErrorCode 'PM_RESOURCE_LEASED' `
            -Message "资源正在执行「$($lease.operation)」，不能$OperationName。" `
            -NextAction '等待当前操作完成并释放资源租约后重试。')
    }
    if ($Usage.Owners.Count -gt 0) {
        $ownerSummary = ($Usage.Owners | ForEach-Object { "$($_.ProcessName)(PID $($_.ProcessId))" }) -join '、'
        throw (New-PMStructuredException -ErrorCode 'PM_PORT_OCCUPIED' `
            -Message "端口当前存在活动监听进程，不能$OperationName：$ownerSummary" `
            -NextAction '关闭占用端口的进程或释放资源后重试；也可以改用其他端口。')
    }
    if ($null -ne $Usage.DetectionTask) {
        throw (New-PMStructuredException -ErrorCode 'PM_LOGIN_DETECTION_ACTIVE' `
            -Message "资源正在进行登录状态检测（任务 $($Usage.DetectionTask.attemptId)），不能$OperationName。" `
            -NextAction '等待登录状态检测结束、超时收口或先执行取消检测，再重试。')
    }
}

function Get-PMDerivedPlatformPatterns {
    param(
        [string]$StartUrl,
        [object]$Patterns
    )
    $normalized = @(ConvertTo-PMPatternArray -Value $Patterns)
    if ($normalized.Count -gt 0 -or [string]::IsNullOrWhiteSpace($StartUrl)) {
        return @($normalized)
    }
    $uri = [Uri]$StartUrl
    return @("*://$($uri.Host)/*")
}

function Register-PMResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceName,
        [string]$PlatformName = '慧策通',
        [Parameter(Mandatory = $true)]
        [string]$HostName,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [ValidateSet('ConnectOnly', 'Launch')]
        [string]$ConnectionMode = 'ConnectOnly',
        [string]$BrowserExecutable,
        [string]$BrowserProfileDirectory,
        [string]$StartUrl,
        [object]$PlatformUrlPatterns,
        [object]$LoginPagePatterns,
        [bool]$Enabled = $true,
        [string]$Notes,
        [string]$CredentialRef,
        [string]$MaskedAccountSummary
    )

    Assert-PMHost -HostName $HostName
    Assert-PMControlHost -HostName $HostName
    Assert-PMPort -Port $Port
    Assert-PMUrl -Url $StartUrl -FieldName '慧策页面地址'
    if ([string]::IsNullOrWhiteSpace($ResourceName)) {
        throw '资源名称不能为空。'
    }
    if ([string]::IsNullOrWhiteSpace($PlatformName)) {
        throw '平台名称不能为空。'
    }

    if ($ConnectionMode -eq 'Launch') {
        if (-not (Test-PMLoopbackHost -HostName $HostName)) {
            throw '启动本机浏览器时，主机地址只能是 127.0.0.1、localhost 或 ::1。'
        }
        if ([string]::IsNullOrWhiteSpace($BrowserExecutable) -or -not (Test-Path -LiteralPath $BrowserExecutable -PathType Leaf)) {
            throw '启动方式必须提供真实存在的浏览器可执行文件。'
        }
        if ([IO.Path]::GetFileName($BrowserExecutable) -ine 'chrome.exe') {
            throw '默认浏览器只允许 Google Chrome，不允许使用其他浏览器。'
        }
        if ([string]::IsNullOrWhiteSpace($BrowserProfileDirectory)) {
            throw '启动方式必须提供 F 盘浏览器配置目录。'
        }
        $BrowserProfileDirectory = Assert-PMPathOnFDrive -Path $BrowserProfileDirectory -FieldName '浏览器配置目录'
    }

    $tcp = Test-PMTcpConnection -HostName $HostName -Port $Port
    $owners = @(
        if (Test-PMLoopbackHost -HostName $HostName) {
            Get-PMPortOwners -Port $Port
        }
    )
    $baseUri = Get-PMBaseUri -HostName $HostName -Port $Port
    $versionProbe = if ($tcp.Connected) { Invoke-PMJsonRequest -Uri "$baseUri/json/version" } else { $null }
    $isCdp = $null -ne $versionProbe -and $null -ne $versionProbe.Json -and -not [string]::IsNullOrWhiteSpace([string]$versionProbe.Json.Browser)

    if ($owners.Count -gt 0 -and -not $isCdp) {
        $ownerSummary = ($owners | ForEach-Object { "$($_.ProcessName)(PID $($_.ProcessId))" }) -join '、'
        throw (New-PMStructuredException -ErrorCode 'PM_REGISTER_PORT_OCCUPIED' `
            -Message "端口 $Port 已被非浏览器调试服务占用：$ownerSummary" `
            -NextAction '关闭占用端口的进程或重新注册并让程序自动选择端口。')
    }

    $platformPatterns = Get-PMDerivedPlatformPatterns -StartUrl $StartUrl -Patterns $PlatformUrlPatterns
    $loginPatterns = ConvertTo-PMPatternArray -Value $LoginPagePatterns

    return Invoke-PMWriteLock {
        $store = Read-PMStore
        $lockedTcp = Test-PMTcpConnection -HostName $HostName -Port $Port
        $lockedOwners = @(
            if (Test-PMLoopbackHost -HostName $HostName) {
                Get-PMPortOwners -Port $Port
            }
        )
        $lockedBaseUri = Get-PMBaseUri -HostName $HostName -Port $Port
        $lockedVersionProbe = if ($lockedTcp.Connected) {
            Invoke-PMJsonRequest -Uri "$lockedBaseUri/json/version"
        }
        else { $null }
        $lockedIsCdp = $null -ne $lockedVersionProbe -and
            $null -ne $lockedVersionProbe.Json -and
            -not [string]::IsNullOrWhiteSpace([string]$lockedVersionProbe.Json.Browser)
        $lockedBinding = if ($lockedIsCdp -and (Test-PMLoopbackHost -HostName $HostName)) {
            Get-PMChromeResourceBinding -Port $Port -ProfileDirectory $BrowserProfileDirectory
        } else { $null }
        if ($ConnectionMode -eq 'ConnectOnly' -and $lockedIsCdp -and $null -ne $lockedBinding) {
            if ([string]::IsNullOrWhiteSpace($BrowserExecutable)) { $BrowserExecutable = [string]$lockedBinding.ExecutablePath }
            if ([string]::IsNullOrWhiteSpace($BrowserProfileDirectory) -and -not [string]::IsNullOrWhiteSpace([string]$lockedBinding.ProfileDirectory)) {
                $BrowserProfileDirectory = [string]$lockedBinding.ProfileDirectory
            }
            if (-not $lockedBinding.MatchesProfile) {
                throw (New-PMStructuredException -ErrorCode 'PM_RUNTIME_BINDING_MISMATCH' -Message '已有 Chrome 调试会话的 Profile 与当前登记信息不一致；不会创建新的未登录环境。' -NextAction '使用现有 Profile 重新登记，或关闭当前会话后再注册。')
            }
        }
        if ($ConnectionMode -eq 'Launch' -and $lockedOwners.Count -gt 0) {
            $ownerSummary = ($lockedOwners | ForEach-Object { "$($_.ProcessName)(PID $($_.ProcessId))" }) -join '、'
            throw (New-PMStructuredException -ErrorCode 'PM_REGISTER_PORT_OCCUPIED' `
                -Message "端口 $Port 在最终写入复核时已被占用：$ownerSummary" `
                -NextAction '关闭占用端口的进程或重新注册并让程序自动选择端口。')
        }
        if ($lockedOwners.Count -gt 0 -and -not $lockedIsCdp) {
            $ownerSummary = ($lockedOwners | ForEach-Object { "$($_.ProcessName)(PID $($_.ProcessId))" }) -join '、'
            throw (New-PMStructuredException -ErrorCode 'PM_REGISTER_PORT_OCCUPIED' `
                -Message "端口 $Port 在最终写入复核时被非浏览器调试服务占用：$ownerSummary" `
                -NextAction '关闭占用端口的进程或重新注册并让程序自动选择端口。')
        }
        $duplicate = @($store.resources | Where-Object {
            $_.hostName -eq $HostName -and [int]$_.port -eq $Port
        })
        if ($duplicate.Count -gt 0) {
            throw (New-PMStructuredException -ErrorCode 'PM_RESOURCE_DUPLICATE' `
                -Message "地址 $HostName`:$Port 已注册，资源编号：$($duplicate[0].resourceId)" `
                -NextAction '使用列表中的已有资源，或更换端口后重新注册。')
        }
        if ($ConnectionMode -eq 'Launch' -and -not [string]::IsNullOrWhiteSpace($BrowserProfileDirectory)) {
            $profileConflict = @($store.resources | Where-Object {
                [string]$_.browserProfileDirectory -eq [string]$BrowserProfileDirectory
            })
            if ($profileConflict.Count -gt 0) {
                throw (New-PMStructuredException -ErrorCode 'PM_RUNTIME_PROFILE_CONFLICT' `
                    -Message "F 盘浏览器配置目录已被资源 $($profileConflict[0].resourceId) 使用。" `
                    -NextAction '重新注册并让程序自动创建新的 F 盘配置目录。')
            }
        }

        $now = Get-PMNow
        $resourceId = $null
        do {
            $resourceId = New-PMResourceId
        } while (@($store.resources | Where-Object { $_.resourceId -eq $resourceId }).Count -gt 0)
        $resource = [pscustomobject]@{
            resourceId = $resourceId
            platformId = 'huice'
            resourceName = $ResourceName.Trim()
            platformName = $PlatformName.Trim()
            hostName = $HostName.Trim()
            port = $Port
            connectionMode = $ConnectionMode
            browserExecutable = if ([string]::IsNullOrWhiteSpace($BrowserExecutable)) { $null } else { [IO.Path]::GetFullPath($BrowserExecutable) }
            browserProfileDirectory = if ([string]::IsNullOrWhiteSpace($BrowserProfileDirectory)) { $null } else { $BrowserProfileDirectory }
            startUrl = if ([string]::IsNullOrWhiteSpace($StartUrl)) { $null } else { $StartUrl }
            platformUrlPatterns = @($platformPatterns)
            loginPagePatterns = @($loginPatterns)
            enabled = $Enabled
            notes = if ([string]::IsNullOrWhiteSpace($Notes)) { $null } else { $Notes.Trim() }
            credentialRef = if ([string]::IsNullOrWhiteSpace($CredentialRef)) { $null } else { $CredentialRef.Trim() }
            maskedAccountSummary = if ([string]::IsNullOrWhiteSpace($MaskedAccountSummary)) { $null } else { $MaskedAccountSummary.Trim() }
            loginAutomationState = if ([string]::IsNullOrWhiteSpace($CredentialRef)) { '未配置凭据' } else { '待登录验证' }
            sessionPolicy = New-PMSessionPolicy
            registeredAt = $now
            updatedAt = $now
            lastStatus = [pscustomobject]@{
                connectionStatus = if ($lockedTcp.Connected) { if ($lockedIsCdp) { '浏览器可连接' } else { '端口已监听' } } else { '不可连接' }
                portStatus = if ($lockedTcp.Connected) { '端口已监听' } else { '不可连接' }
                httpStatus = if ($null -ne $lockedVersionProbe -and $lockedVersionProbe.Response.Responded) { 'HTTP 已响应' } else { 'HTTP 未响应' }
                browserStatus = if ($lockedIsCdp) { '浏览器可连接' } else { '浏览器未连接' }
                pageStatus = '页面状态未知'
                loginStatus = '未检测'
                loginEvidence = New-PMLoginEvidence
                loginCheckedAt = $null
                currentOccupancy = if ($lockedOwners.Count -eq 0) { '无' } else { ($lockedOwners | ForEach-Object { "$($_.ProcessName)(PID $($_.ProcessId))" }) -join '、' }
                ownerProcessIds = @($lockedOwners | ForEach-Object { $_.ProcessId })
                activeLeases = @()
                currentOccupancyDetails = [pscustomobject]@{
                    activeLeases = @()
                    ownerProcessIds = @($lockedOwners | ForEach-Object { $_.ProcessId })
                    operation = '已注册'
                    checkedAt = $now
                }
                operationStatus = '已注册'
                lastCheckedAt = $now
                lastSuccessAt = if ($lockedIsCdp) { $now } else { $null }
                lastError = if ($lockedTcp.Connected) { $null } else { $lockedTcp.Error }
                loginDetectionState = '未检测'
                browserPid = if ($null -eq $lockedBinding) { $null } else { [int]$lockedBinding.ProcessId }
                processStartTime = if ($null -eq $lockedBinding) { $null } else { [string]$lockedBinding.ProcessStartTime }
                profileFingerprint = if ($null -eq $lockedBinding) { $null } else { [string]$lockedBinding.ProfileFingerprint }
                sessionState = if ($null -eq $lockedBinding) { '未连接' } else { '同一资源执行环境' }
                loginDetectionStartedAt = $null
                nextLoginDetectionAt = $now
                loginDetectionSource = $null
                loginDetectionErrorCode = $null
                loginCookieEvidencePresent = $null
                loginApiProbeStatus = '未配置可靠探针'
                loginConfidence = 'none'
                detectorVersion = '1'
                profileMetrics = $null
            }
        }
        $store.resources = @($store.resources) + $resource
        Save-PMStore -Store $store
        Write-PMAudit -Action 'Register' -ResourceId $resource.resourceId -Outcome 'Success' -Message '端口资源已注册。' -Details @{
            hostName = $HostName
            port = $Port
            connectionMode = $ConnectionMode
            initialConnectionStatus = $resource.lastStatus.connectionStatus
        }
        Write-PMLog -Level 'INFO' -ResourceId $resource.resourceId -Message '端口资源注册成功。'
        return $resource
    }
}

function Get-PMResourceStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource,
        [switch]$SkipProfileMetrics
    )

    $timing = New-PMTimingTrace -Operation 'ResourceStatusProbe'
    $now = Get-PMNow
    $tcp = Test-PMTcpConnection -HostName $Resource.hostName -Port ([int]$Resource.port)
    $owners = @(
        if (Test-PMLoopbackHost -HostName $Resource.hostName) {
            Get-PMPortOwners -Port ([int]$Resource.port)
        }
    )
    $leases = @(Get-PMActiveLeases | Where-Object { $_.resourceId -eq $Resource.resourceId })
    Add-PMTimingStage -Trace $timing -Stage 'tcp-and-port-ownership' -Details @{
        connected = [bool]$tcp.Connected
        ownerCount = @($owners).Count
        activeLeaseCount = @($leases).Count
    }
    $baseUri = Get-PMBaseUri -HostName $Resource.hostName -Port ([int]$Resource.port
    )

    $httpProbe = $null
    $versionProbe = $null
    $targetsProbe = $null
    $browserConnected = $false
    if ($tcp.Connected) {
        $httpProbe = Invoke-PMHttpRequest -Uri $baseUri
        $versionProbe = Invoke-PMJsonRequest -Uri "$baseUri/json/version"
        $browserConnected = $null -ne $versionProbe.Json -and -not [string]::IsNullOrWhiteSpace([string]$versionProbe.Json.Browser)
        if ($browserConnected) {
            $targetsProbe = Invoke-PMJsonRequest -Uri "$baseUri/json/list"
        }
    }
    Add-PMTimingStage -Trace $timing -Stage 'http-cdp-targets' -Details @{
        browserConnected = [bool]$browserConnected
        targetCount = if ($null -eq $targetsProbe -or $null -eq $targetsProbe.Json) { 0 } else { @($targetsProbe.Json).Count }
    }
    $binding = if ($browserConnected -and (Test-PMLoopbackHost -HostName $Resource.hostName)) {
        Get-PMChromeResourceBinding -Port ([int]$Resource.port) -ProfileDirectory ([string]$Resource.browserProfileDirectory)
    } else { $null }
    Add-PMTimingStage -Trace $timing -Stage 'browser-profile-binding' -Details @{
        matched = ($null -ne $binding -and [bool]$binding.MatchesProfile)
    }

    $pageTargets = @()
    if ($null -ne $targetsProbe -and $null -ne $targetsProbe.Json) {
        $pageTargets = @($targetsProbe.Json | Where-Object { $_.type -eq 'page' })
    }
    $matchingPages = @($pageTargets | Where-Object {
        (Test-PMPatternMatch -Value ([string]$_.url) -Patterns $Resource.platformUrlPatterns) -or
        (Test-PMPatternMatch -Value ([string]$_.title) -Patterns $Resource.platformUrlPatterns)
    })
    $connectionStatus = '不可连接'
    $portStatus = '不可连接'
    $browserStatus = '浏览器未连接'
    $pageStatus = '页面状态未知'
    $lastError = $null

    if (-not $tcp.Connected) {
        $lastError = if ([string]::IsNullOrWhiteSpace($tcp.Error)) { '端口不可连接。' } else { $tcp.Error }
    }
    elseif (-not $browserConnected) {
        $connectionStatus = if ($owners.Count -gt 0) { '端口冲突' } else { '端口已监听' }
        $portStatus = '端口已监听'
        $lastError = if ($owners.Count -gt 0) { '端口存在监听进程，但不是可识别的浏览器调试接口。' } else { '端口已响应，但未识别为浏览器调试接口。' }
    }
    else {
        $connectionStatus = '浏览器可连接'
        $portStatus = '端口已监听'
        $browserStatus = '浏览器可连接'
        if (@($Resource.platformUrlPatterns).Count -eq 0) {
            $pageStatus = '页面状态未知'
        }
        elseif ($matchingPages.Count -gt 0) {
            $pageStatus = '平台页面正确'
        }
        elseif ($pageTargets.Count -gt 0) {
            $pageStatus = '平台页面错误'
            $lastError = '浏览器已连接，但没有页面匹配已登记的平台规则。'
        }
        else {
            $pageStatus = '未发现页面'
            $lastError = '浏览器调试接口可用，但未发现页面目标。'
        }
    }

    $occupancy = Format-PMUsageOccupancy -Leases $leases -Owners $owners
    $authenticatedEvidenceRules = @()
    $loginDetectionError = $null
    try {
        $adapterDefaults = Get-PMHuiceAdapterDefaults -ProjectRoot $script:ProjectRoot
        $authenticatedEvidenceRules = @($adapterDefaults.AuthenticatedEvidenceRules)
    }
    catch {
        $loginDetectionError = $_.Exception.Message
    }
    $loginResult = Resolve-PMLoginStatus `
        -Resource $Resource `
        -BrowserConnected $browserConnected `
        -PageStatus $pageStatus `
        -PageTargets $pageTargets `
        -AuthenticatedEvidenceRules $authenticatedEvidenceRules `
        -DetectionError $loginDetectionError `
        -CheckedAt $now
    $preserveAgentLogin = $browserConnected -and $null -ne $binding -and [bool]$binding.MatchesProfile -and
        [string]$Resource.lastStatus.loginDetectionSource -eq 'huice-login-agent' -and
        -not [string]::IsNullOrWhiteSpace([string]$Resource.lastStatus.loginCheckedAt
        )
    $effectiveLoginStatus = if ($preserveAgentLogin) { [string]$Resource.lastStatus.loginStatus } else { [string]$loginResult.loginStatus }
    $effectiveLoginEvidence = if ($preserveAgentLogin) { $Resource.lastStatus.loginEvidence } else { $loginResult.loginEvidence }
    $effectiveLoginCheckedAt = if ($preserveAgentLogin) { [string]$Resource.lastStatus.loginCheckedAt } else { [string]$loginResult.loginCheckedAt }
    Add-PMTimingStage -Trace $timing -Stage 'page-and-login-resolution' -Details @{
        pageStatus = $pageStatus
        preservedAgentEvidence = [bool]$preserveAgentLogin
        loginProbeMode = if ($preserveAgentLogin) { 'preserved-huice-agent-evidence' } else { 'page-evidence-only' }
    }

    $profileMetrics = if ($SkipProfileMetrics) {
        $Resource.lastStatus.profileMetrics
    }
    elseif ($Resource.connectionMode -eq 'Launch' -and -not [string]::IsNullOrWhiteSpace([string]$Resource.browserProfileDirectory)) {
        Get-PMProfileMetrics -ProfilePath ([string]$Resource.browserProfileDirectory)
    }
    else { $null }
    Add-PMTimingStage -Trace $timing -Stage 'profile-metrics' -Status $(if ($SkipProfileMetrics) { 'reused' } else { 'refreshed' }) -Details @{
        skipped = [bool]$SkipProfileMetrics
    }

    $status = [pscustomobject]@{
        connectionStatus = $connectionStatus
        portStatus = $portStatus
        httpStatus = if ($null -ne $httpProbe -and $httpProbe.Responded) { "HTTP 已响应($($httpProbe.StatusCode))" } else { 'HTTP 未响应' }
        browserStatus = $browserStatus
        pageStatus = $pageStatus
        loginStatus = $effectiveLoginStatus
        loginEvidence = $effectiveLoginEvidence
        loginCheckedAt = $effectiveLoginCheckedAt
        currentOccupancy = $occupancy
        ownerProcessIds = @($owners | ForEach-Object { $_.ProcessId })
        activeLeases = @($leases)
        operationStatus = '检测完成'
        browserVersion = if ($browserConnected) { [string]$versionProbe.Json.Browser } else { $null }
        protocolVersion = if ($browserConnected) { [string]$versionProbe.Json.'Protocol-Version' } else { $null }
        debugEndpoint = if ($browserConnected) { "$baseUri/json" } else { $null }
        matchedPages = @($matchingPages | ForEach-Object {
            [pscustomobject]@{
                title = ConvertTo-PMSafePageTitle -Title ([string]$_.title)
                url = ConvertTo-PMSafePageUrl -Url ([string]$_.url)
                id = [string]$_.id
            }
        })
        lastCheckedAt = $now
        lastSuccessAt = if ($browserConnected) { $now } else { $Resource.lastStatus.lastSuccessAt }
        lastError = if ($preserveAgentLogin -and -not [string]::IsNullOrWhiteSpace([string]$Resource.lastStatus.lastError)) { [string]$Resource.lastStatus.lastError } else { $lastError }
        loginDetectionState = if ($preserveAgentLogin) { [string]$Resource.lastStatus.loginDetectionState } else { '已完成' }
        loginDetectionStartedAt = $Resource.lastStatus.loginDetectionStartedAt
        nextLoginDetectionAt = if ($preserveAgentLogin) { $Resource.lastStatus.nextLoginDetectionAt } else { ([DateTimeOffset]::Now.AddSeconds(600)).ToString('o') }
        loginDetectionSource = if ($preserveAgentLogin) { 'huice-login-agent' } else { 'bsclaw.huice.login-detector' }
        loginDetectionErrorCode = if ($preserveAgentLogin) { $Resource.lastStatus.loginDetectionErrorCode } else { $null }
        loginCookieEvidencePresent = if ($preserveAgentLogin) { $Resource.lastStatus.loginCookieEvidencePresent } else { $null }
        loginApiProbeStatus = if ($preserveAgentLogin) { $Resource.lastStatus.loginApiProbeStatus } else { '未配置可靠探针' }
        loginConfidence = if ($preserveAgentLogin) { $Resource.lastStatus.loginConfidence } else { [string]$loginResult.loginEvidence.confidence }
        detectorVersion = if ($preserveAgentLogin) { $Resource.lastStatus.detectorVersion } else { '1' }
        lastAuthenticatedAt = $Resource.lastStatus.lastAuthenticatedAt
        browserPid = if ($null -eq $binding) { $null } else { [int]$binding.ProcessId }
        processStartTime = if ($null -eq $binding) { $null } else { [string]$binding.ProcessStartTime }
        profileFingerprint = if ($null -eq $binding) { $null } else { [string]$binding.ProfileFingerprint }
        sessionState = if ($null -ne $binding -and $binding.MatchesProfile) { '同一资源执行环境' } elseif ($browserConnected) { '已有会话未登记或资源占用' } else { '未连接' }
        lastOpenAt = $Resource.lastStatus.lastOpenAt
        lastOpenResult = $Resource.lastStatus.lastOpenResult
        watcherPid = $Resource.lastStatus.watcherPid
        watcherProcessStartTime = $Resource.lastStatus.watcherProcessStartTime
        watcherHeartbeatAt = $Resource.lastStatus.watcherHeartbeatAt
        watcherLastCheckAt = $Resource.lastStatus.watcherLastCheckAt
        watcherNextCheckAt = $Resource.lastStatus.watcherNextCheckAt
        watcherFailureCount = $Resource.lastStatus.watcherFailureCount
        watcherErrorCode = $Resource.lastStatus.watcherErrorCode
        profileMetrics = $profileMetrics
    }
    $null = Set-PMStatusOccupancyModel -Status $status -ActiveLeases @($leases) `
        -OwnerProcessIds @($owners | ForEach-Object { [int]$_.ProcessId }) `
        -Operation '检测完成' -CheckedAt $now
    Add-PMTimingStage -Trace $timing -Stage 'status-compose'
    $status | Add-Member -MemberType NoteProperty -Name timingSummary -Value (Complete-PMTimingTrace -Trace $timing) -Force
    return $status
}

function Save-PMResourceStatus {
    param(
        [string]$ResourceId,
        [object]$Status
    )
    Invoke-PMWriteLock {
        $store = Read-PMStore
        $resource = @($store.resources | Where-Object { $_.resourceId -eq $ResourceId }) | Select-Object -First 1
        if ($null -eq $resource) {
            throw "保存状态时未找到资源：$ResourceId"
        }
        $resource.lastStatus = $Status
        $resource.updatedAt = Get-PMNow
        Save-PMStore -Store $store
    } | Out-Null
}

function Start-PMLoginStateDetectionAsync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [int]$TimeoutSeconds = 30,
        [string]$DetectorVersion = '1'
    )
    $resource = Get-PMResourceById -ResourceId $ResourceId
    $now = Get-PMNow
    $status = $resource.lastStatus
    $status.loginDetectionState = '检测中'
    $status.loginDetectionStartedAt = $now
    $status.nextLoginDetectionAt = $null
    $status.loginDetectionSource = 'bsclaw.login-state-detector'
    $status.loginDetectionErrorCode = $null
    $status.detectorVersion = $DetectorVersion
    Save-PMResourceStatus -ResourceId $ResourceId -Status $status
    try {
        return Start-PMLoginDetectorProcess -ResourceId $ResourceId -RuntimeRoot $script:RuntimeRoot `
            -ProjectRoot $script:ProjectRoot -TimeoutSeconds $TimeoutSeconds -DetectorVersion $DetectorVersion
    }
    catch {
        $status.loginDetectionState = '检测失败'
        $status.loginDetectionErrorCode = 'LOGIN_DETECTION_START_FAILED'
        $status.lastError = '登录状态检测启动失败：' + $_.Exception.Message
        $status.nextLoginDetectionAt = ([DateTimeOffset]::Now.AddSeconds(60)).ToString('o')
        Save-PMResourceStatus -ResourceId $ResourceId -Status $status
        throw
    }
}

function Invoke-PMLoginDetectionReaper {
    [CmdletBinding()]
    param()
    $closed = @(Invoke-PMLoginDetectionReaperWorker -RuntimeRoot $script:RuntimeRoot)
    foreach ($task in $closed) {
        try {
            $resource = Get-PMResourceById -ResourceId ([string]$task.resourceId)
            $status = $resource.lastStatus
            $status.loginDetectionState = '检测失败'
            $status.loginDetectionErrorCode = 'LOGIN_DETECTION_TIMEOUT'
            $status.loginDetectionSource = 'bsclaw.login-state-detector.reaper'
            $status.loginDetectionStartedAt = $status.loginDetectionStartedAt
            $status.nextLoginDetectionAt = ([DateTimeOffset]::Now.AddSeconds(60)).ToString('o')
            $status.lastError = '登录状态检测超时，工作进程已回收。'
            Save-PMResourceStatus -ResourceId ([string]$task.resourceId) -Status $status
            Write-PMAudit -Action 'LoginDetectionReap' -ResourceId ([string]$task.resourceId) -Outcome 'Failed' -Message '登录状态检测超时并已回收工作进程。' -Details @{ attemptId = [string]$task.attemptId; processId = [int]$task.processId }
        }
        catch {
            Write-PMLog -Level 'ERROR' -ResourceId ([string]$task.resourceId) -Message ('登录检测超时收口失败：' + $_.Exception.Message)
        }
    }
    return @($closed)
}

function Invoke-PMLoginDetectionScheduler {
    [CmdletBinding()]
    param([int]$MaxStarts = 1)
    $now = [DateTimeOffset]::Now
    $started = @()
    foreach ($resource in @(Get-PMResources | Where-Object { [bool]$_.enabled })) {
        if ($started.Count -ge $MaxStarts) { break }
        $agentEvidence = $null -ne $resource.lastStatus.loginEvidence -and
            [string]$resource.lastStatus.loginEvidence.source -eq 'huice-login-agent'
        if ([string]$resource.lastStatus.loginDetectionSource -eq 'huice-login-agent' -or $agentEvidence) { continue }
        $state = [string]$resource.lastStatus.loginDetectionState
        if ($state -eq '检测中') {
            $record = Get-PMLoginDetectionRecord -RuntimeRoot $script:RuntimeRoot -ResourceId $resource.resourceId
            if ($null -ne $record -and [string]$record.state -eq 'running') { continue }
        }
        $due = $true
        if (-not [string]::IsNullOrWhiteSpace([string]$resource.lastStatus.nextLoginDetectionAt)) {
            $due = try { ([DateTimeOffset]$resource.lastStatus.nextLoginDetectionAt) -le $now } catch { $true }
        }
        if (-not $due) { continue }
        try {
            $result = Start-PMLoginStateDetectionAsync -ResourceId $resource.resourceId
            if ($result.started) { $started += $resource.resourceId }
        }
        catch {
            Write-PMLog -Level 'WARN' -ResourceId $resource.resourceId -Message ('登录检测调度失败：' + $_.Exception.Message)
        }
    }
    return @($started)
}

function New-PMFailureStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('检测失败', '打开失败')]
        [string]$OperationStatus
    )

    $usage = Get-PMUsage -Resource $Resource
    return [pscustomobject]@{
        connectionStatus = $OperationStatus
        portStatus = $OperationStatus
        httpStatus = $OperationStatus
        browserStatus = '浏览器状态未知'
        pageStatus = '页面状态未知'
        loginStatus = '检测失败'
        loginEvidence = New-PMLoginEvidence -State '检测失败' -EvidenceType 'detector-error' `
            -EvidenceSummary '登录检测过程异常，未形成登录结论。' `
            -CheckedAt (Get-PMNow) -Confidence 'unknown'
        loginCheckedAt = Get-PMNow
        currentOccupancy = Format-PMUsageOccupancy -Leases @($usage.Leases) -Owners @($usage.Owners)
        ownerProcessIds = @($usage.Owners | ForEach-Object { $_.ProcessId })
        activeLeases = @($usage.Leases)
        currentOccupancyDetails = [pscustomobject]@{
            activeLeases = @($usage.Leases)
            ownerProcessIds = @($usage.Owners | ForEach-Object { $_.ProcessId })
            operation = $OperationStatus
            checkedAt = Get-PMNow
        }
        operationStatus = $OperationStatus
        browserVersion = $null
        protocolVersion = $null
        debugEndpoint = $null
        matchedPages = @()
        lastCheckedAt = Get-PMNow
        lastSuccessAt = $Resource.lastStatus.lastSuccessAt
        lastError = $Message
        loginDetectionState = '检测失败'
        loginDetectionStartedAt = $null
        nextLoginDetectionAt = ([DateTimeOffset]::Now.AddSeconds(60)).ToString('o')
        loginDetectionSource = 'bsclaw.login-state-detector'
        loginDetectionErrorCode = 'LOGIN_DETECTION_FAILED'
        loginCookieEvidencePresent = $null
        loginApiProbeStatus = '未配置可靠探针'
        loginConfidence = 'unknown'
        detectorVersion = '1'
        profileMetrics = $null
        watcherPid = $Resource.lastStatus.watcherPid
        watcherProcessStartTime = $Resource.lastStatus.watcherProcessStartTime
        watcherHeartbeatAt = $Resource.lastStatus.watcherHeartbeatAt
        watcherLastCheckAt = $Resource.lastStatus.watcherLastCheckAt
        watcherNextCheckAt = $Resource.lastStatus.watcherNextCheckAt
        watcherFailureCount = $Resource.lastStatus.watcherFailureCount
        watcherErrorCode = $Resource.lastStatus.watcherErrorCode
    }
}

function Test-PMResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId
    )

    $timing = New-PMTimingTrace -Operation 'Check'
    $resource = Get-PMResourceById -ResourceId $ResourceId
    Add-PMTimingStage -Trace $timing -Stage 'resource-read'
    $lease = $null
    try {
        $lease = Set-PMLease -ResourceId $ResourceId -Operation '检查端口状态' -DurationSeconds 60 -TaskRef "Check:$PID"
        Add-PMTimingStage -Trace $timing -Stage 'lease-acquire'
    }
    catch {
        $code = if ($_.Exception.Data.Contains('errorCode')) { [string]$_.Exception.Data['errorCode'] } else { [string]$_.Exception.Message }
        if ($code -in @('RESOURCE_BUSY','PM_RESOURCE_LEASED')) {
            Write-PMAudit -Action 'Check' -ResourceId $ResourceId -Outcome 'Rejected' -Message 'RESOURCE_BUSY' -Details @{ errorCode = 'RESOURCE_BUSY'; processId = $PID }
            throw (New-PMStructuredException -ErrorCode 'RESOURCE_BUSY' -Message 'RESOURCE_BUSY' -NextAction '等待当前操作释放资源租约后重试。')
        }
        throw
    }
    try {
        # An explicit Check is the refresh boundary for persisted profile metrics.
        # List remains fast by reading the last successfully refreshed status.
        $status = Get-PMResourceStatus -Resource $resource
        Add-PMTimingStage -Trace $timing -Stage 'tcp-cdp-page-login-and-profile' -Details @{
            probeTotalMs = [int64]$status.timingSummary.totalMs
        }
        foreach ($field in @('watcherPid','watcherProcessStartTime','watcherHeartbeatAt','watcherLastCheckAt','watcherNextCheckAt','watcherFailureCount','watcherErrorCode')) {
            $status.$field = $resource.lastStatus.$field
        }
        Save-PMResourceStatus -ResourceId $ResourceId -Status $status
        Add-PMTimingStage -Trace $timing -Stage 'state-save'
        Write-PMAudit -Action 'Check' -ResourceId $ResourceId -Outcome 'Success' -Message '端口状态检测完成。' -Details @{
            connectionStatus = $status.connectionStatus
            browserStatus = $status.browserStatus
            pageStatus = $status.pageStatus
            loginStatus = $status.loginStatus
            probeTiming = $status.timingSummary
        }
        Add-PMTimingStage -Trace $timing -Stage 'audit-write'
        if ($null -ne $lease) {
            Remove-PMLease -LeaseId $lease.leaseId
            $lease = $null
        }
        Add-PMTimingStage -Trace $timing -Stage 'lease-release'
        return [pscustomobject]@{
            Resource = (Get-PMResourceById -ResourceId $ResourceId)
            Status = $status
            TimingSummary = (Complete-PMTimingTrace -Trace $timing)
        }
    }
    catch {
        $failureException = $_.Exception
        $failureMessage = $failureException.Message
        $failureStatus = New-PMFailureStatus -Resource $resource -Message $failureMessage -OperationStatus '检测失败'
        try {
            Save-PMResourceStatus -ResourceId $ResourceId -Status $failureStatus
        }
        catch {
            Write-PMLog -Level 'ERROR' -ResourceId $ResourceId -Message ('检测失败状态保存失败：' + $_.Exception.Message)
        }
        Write-PMAudit -Action 'Check' -ResourceId $ResourceId -Outcome 'Failed' -Message $failureMessage -Details @{
            elapsedMs = [int64]$timing.stopwatch.ElapsedMilliseconds
            completedStages = @($timing.stages)
        }
        Write-PMLog -Level 'ERROR' -ResourceId $ResourceId -Message $failureMessage
        throw $failureException
    }
    finally {
        if ($null -ne $lease) { Remove-PMLease -LeaseId $lease.leaseId }
    }
}

function Test-PMAllResources {
    $results = @()
    foreach ($resource in Get-PMResources) {
        try {
            $results += Test-PMResource -ResourceId $resource.resourceId
        }
        catch {
            $latestResource = Get-PMResourceById -ResourceId $resource.resourceId
            $results += [pscustomobject]@{
                Resource = $latestResource
                Status = $latestResource.lastStatus
            }
        }
    }
    return $results
}

function Assert-PMResourceNotInUse {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource,
        [string]$OperationName
    )
    Throw-PMResourceUsageError -Usage (Get-PMUsage -Resource $Resource) -OperationName $OperationName
}

function Update-PMResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,
        [hashtable]$Changes
    )

    if ($null -eq $Changes -or $Changes.Count -eq 0) {
        throw '没有提供需要修改的字段。'
    }
    $allowedFields = @(
        'resourceName', 'hostName', 'port', 'connectionMode', 'browserExecutable',
        'browserProfileDirectory', 'startUrl', 'platformUrlPatterns',
        'loginPagePatterns', 'enabled', 'notes'
    )
    foreach ($field in $Changes.Keys) {
        if ($field -notin $allowedFields) {
            throw "不支持编辑字段：$field"
        }
    }

    return Invoke-PMWriteLock {
        $store = Read-PMStore
        $resource = @($store.resources | Where-Object { $_.resourceId -eq $ResourceId }) | Select-Object -First 1
        if ($null -eq $resource) {
            throw (New-PMStructuredException -ErrorCode 'PM_RESOURCE_NOT_FOUND' -Message "未找到资源编号：$ResourceId" -NextAction '先查看端口列表，再选择其中的资源重试。')
        }
        Assert-PMResourceNotInUse -Resource $resource -OperationName '编辑'

        $candidate = [ordered]@{
            resourceName = [string]$resource.resourceName
            hostName = [string]$resource.hostName
            port = [int]$resource.port
            connectionMode = [string]$resource.connectionMode
            browserExecutable = $resource.browserExecutable
            browserProfileDirectory = $resource.browserProfileDirectory
            startUrl = $resource.startUrl
            platformUrlPatterns = @($resource.platformUrlPatterns)
            loginPagePatterns = @($resource.loginPagePatterns)
            enabled = [bool]$resource.enabled
            notes = $resource.notes
        }
        foreach ($field in $Changes.Keys) {
            $candidate[$field] = $Changes[$field]
        }

        Assert-PMHost -HostName $candidate.hostName
        Assert-PMControlHost -HostName $candidate.hostName
        Assert-PMPort -Port ([int]$candidate.port)
        Assert-PMUrl -Url $candidate.startUrl -FieldName '慧策页面地址'
        if ([string]::IsNullOrWhiteSpace($candidate.resourceName)) {
            throw '资源名称不能为空。'
        }
        if ($candidate.connectionMode -notin @('ConnectOnly', 'Launch')) {
            throw '连接方式只能是 ConnectOnly 或 Launch。'
        }
        if ($candidate.connectionMode -eq 'Launch') {
            if (-not (Test-PMLoopbackHost -HostName $candidate.hostName)) {
                throw '启动本机浏览器时只能使用回环地址。'
            }
            if ([string]::IsNullOrWhiteSpace($candidate.browserExecutable) -or -not (Test-Path -LiteralPath $candidate.browserExecutable -PathType Leaf)) {
                throw '浏览器可执行文件不存在。'
            }
            if ([IO.Path]::GetFileName([string]$candidate.browserExecutable) -ine 'chrome.exe') {
                throw '默认浏览器只允许 Google Chrome，不允许使用其他浏览器。'
            }
            $candidate.browserProfileDirectory = Assert-PMPathOnFDrive -Path $candidate.browserProfileDirectory -FieldName '浏览器配置目录'
        }
        $candidate.platformUrlPatterns = Get-PMDerivedPlatformPatterns -StartUrl $candidate.startUrl -Patterns $candidate.platformUrlPatterns
        $candidate.loginPagePatterns = ConvertTo-PMPatternArray -Value $candidate.loginPagePatterns

        $tcp = Test-PMTcpConnection -HostName $candidate.hostName -Port ([int]$candidate.port)
        $owners = @(
            if (Test-PMLoopbackHost -HostName $candidate.hostName) {
                Get-PMPortOwners -Port ([int]$candidate.port)
            }
        )
        if ($owners.Count -gt 0) {
            throw '目标端口当前存在活动监听进程，不能完成编辑。'
        }

        $duplicate = @($store.resources | Where-Object {
            $_.resourceId -ne $ResourceId -and $_.hostName -eq $candidate.hostName -and [int]$_.port -eq [int]$candidate.port
        })
        if ($duplicate.Count -gt 0) {
            throw "修改后的地址与资源 $($duplicate[0].resourceId) 重复。"
        }

        foreach ($field in $candidate.Keys) {
            if ($field -in @('platformUrlPatterns', 'loginPagePatterns')) {
                $resource.$field = @($candidate[$field])
            }
            else {
                $resource.$field = $candidate[$field]
            }
        }
        $resource.updatedAt = Get-PMNow
        $resource.lastStatus = [pscustomobject]@{
            connectionStatus = if ($tcp.Connected) { '端口已监听' } else { '不可连接' }
            portStatus = if ($tcp.Connected) { '端口已监听' } else { '不可连接' }
            httpStatus = '尚未检测'
            browserStatus = '浏览器状态未知'
            pageStatus = '页面状态未知'
            loginStatus = '未检测'
            loginEvidence = New-PMLoginEvidence -EvidenceSummary '资源已编辑，需要重新执行登录检测。'
            loginCheckedAt = $null
            currentOccupancy = '无'
            ownerProcessIds = @()
            activeLeases = @()
            currentOccupancyDetails = [pscustomobject]@{
                activeLeases = @()
                ownerProcessIds = @()
                operation = '已编辑'
                checkedAt = $null
            }
            operationStatus = '已编辑'
            lastCheckedAt = $null
            lastSuccessAt = $resource.lastStatus.lastSuccessAt
            lastError = if ($tcp.Connected) { $null } else { $tcp.Error }
        }
        Save-PMStore -Store $store
        Write-PMAudit -Action 'Edit' -ResourceId $ResourceId -Outcome 'Success' -Message '端口资源已编辑。' -Details @{ changedFields = @($Changes.Keys) }
        Write-PMLog -Level 'INFO' -ResourceId $ResourceId -Message '端口资源编辑成功。'
        return $resource
    }
}

function Set-PMResourceEnabled {
    param(
        [string]$ResourceId,
        [bool]$Enabled
    )
    return Update-PMResource -ResourceId $ResourceId -Changes @{ enabled = $Enabled }
}

function Remove-PMResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,
        [Parameter(Mandatory = $true)]
        [string]$ConfirmationText
    )

    if ($ConfirmationText -cne "删除 $ResourceId") {
        Write-PMAudit -Action 'Delete' -ResourceId $ResourceId -Outcome 'Rejected' -Message '删除确认文字不匹配。'
        throw (New-PMStructuredException -ErrorCode 'PM_DELETE_CONFIRMATION_INVALID' `
            -Message "确认失败。当前资源为 $ResourceId；必须准确输入：删除 $ResourceId" `
            -NextAction "重新执行删除，并输入：删除 $ResourceId")
    }

    $deleteLease = $null
    try {
        $deleteLease = Set-PMLease -ResourceId $ResourceId -Operation '删除端口资源' -DurationSeconds 60 -TaskRef "Delete:$PID"
        return Invoke-PMWriteLock {
        $store = Read-PMStore
        $resource = @($store.resources | Where-Object { $_.resourceId -eq $ResourceId }) | Select-Object -First 1
        if ($null -eq $resource) {
            throw (New-PMStructuredException -ErrorCode 'PM_RESOURCE_NOT_FOUND' -Message "未找到资源编号：$ResourceId" -NextAction '先查看端口列表，再选择其中的资源重试。')
        }
        $usage = Get-PMUsage -Resource $resource
        $otherLeases = @($usage.Leases | Where-Object { $_.leaseId -ne $deleteLease.leaseId })
        $deleteUsage = [pscustomobject]@{
            Leases = $otherLeases
            Owners = @($usage.Owners)
            DetectionTask = $usage.DetectionTask
            InUse = ($otherLeases.Count -gt 0 -or @($usage.Owners).Count -gt 0 -or $null -ne $usage.DetectionTask)
        }
        Throw-PMResourceUsageError -Usage $deleteUsage -OperationName '删除'
        $watcherStop = Stop-PMLoginStateWatcher -ResourceId $ResourceId
        if (@($watcherStop.stoppedProcessIds).Count -gt 0) {
            Write-PMAudit -Action 'LoginStateWatcher' -ResourceId $ResourceId -Outcome 'Stopped' -Message '删除资源前已停止登录状态后台同步。' -Details @{ processIds = @($watcherStop.stoppedProcessIds) }
        }

        $beforeCount = @($store.resources).Count
        $store.resources = @($store.resources | Where-Object { $_.resourceId -ne $ResourceId })
        if (@($store.resources).Count -eq $beforeCount) {
            throw (New-PMStructuredException -ErrorCode 'PM_RESOURCE_NOT_FOUND' -Message "未找到资源编号：$ResourceId" -NextAction '先查看端口列表，再选择其中的资源重试。')
        }
        Save-PMStore -Store $store
        Remove-PMSqliteResource -ResourceId $ResourceId
        Write-PMAudit -Action 'Delete' -ResourceId $ResourceId -Outcome 'Success' -Message '端口资源已删除。' -Details @{
            resourceName = $resource.resourceName
            hostName = $resource.hostName
            port = $resource.port
        }
        Write-PMLog -Level 'INFO' -ResourceId $ResourceId -Message '端口资源删除成功。'
        return $resource
        }
    }
    finally {
        if ($null -ne $deleteLease) { Remove-PMLease -LeaseId $deleteLease.leaseId }
    }
}

function Start-PMBrowser {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource
    )
    if (-not (Test-PMLoopbackHost -HostName $Resource.hostName)) {
        throw '本机浏览器只能绑定回环地址。'
    }
    return Start-PMChromeResourceBrowser -Resource $Resource
}

function Stop-PMOwnedBrowserProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource,
        [Parameter(Mandatory = $true)]
        [object]$StartedProcess,
        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$StartedAt
    )

    return Stop-PMChromeOwnedProcesses -Resource $Resource -StartedProcess $StartedProcess -StartedAt $StartedAt
}

function Open-PMTargetPage {
    param(
        [object]$Resource,
        [object]$Status
    )
    if (-not (Test-PMLoopbackHost -HostName $Resource.hostName)) {
        throw '阶段一禁止通过远程主机调用 /json/new 或 /json/activate；Open 仅允许回环地址。'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Resource.startUrl)) {
        return $null
    }
    if ($Status.pageStatus -eq '平台页面正确') {
        $target = @($Status.matchedPages) | Select-Object -First 1
        if ($null -ne $target -and -not [string]::IsNullOrWhiteSpace([string]$target.id)) {
            $baseUri = Get-PMBaseUri -HostName $Resource.hostName -Port ([int]$Resource.port)
            $null = Invoke-PMHttpRequest -Uri "$baseUri/json/activate/$($target.id)"
        }
        return $target
    }

    $baseUri = Get-PMBaseUri -HostName $Resource.hostName -Port ([int]$Resource.port)
    $encodedUrl = [Uri]::EscapeDataString([string]$Resource.startUrl)
    $created = Invoke-PMJsonRequest -Uri "$baseUri/json/new?$encodedUrl" -Method 'PUT' -TimeoutSeconds 5
    if (-not $created.Response.IsSuccess -or $null -eq $created.Json) {
        throw "页面打开失败：$($created.Response.Error)"
    }
    return $created.Json
}

function Open-PMResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,
        [ValidateRange(3, 120)]
        [int]$TimeoutSeconds = 20,
        [switch]$SkipLoginMonitoring
    )

    $timing = New-PMTimingTrace -Operation 'Open'
    $lease = $null
    $resource = $null
    $status = $null
    $startedProcess = $null
    $browserStartedAt = $null
    $cleanupResult = $null
    try {
        $resource = Get-PMResourceById -ResourceId $ResourceId
        Add-PMTimingStage -Trace $timing -Stage 'resource-read'
        if (-not [bool]$resource.enabled) {
            throw (New-PMStructuredException -ErrorCode 'PM_RESOURCE_DISABLED' -Message '该资源已停用，请先启用后再打开。' -NextAction '先启用资源，再重试打开操作。')
        }
        if (-not (Test-PMLoopbackHost -HostName $resource.hostName)) {
            throw (New-PMStructuredException -ErrorCode 'PM_REMOTE_CDP_BLOCKED' -Message '阶段一 Open 仅允许 127.0.0.1、localhost 或 ::1，禁止控制远程 CDP 主机。' -NextAction '将资源主机改为本机地址，或使用本机 Chrome 调试端口。')
        }

        $lease = Set-PMLease -ResourceId $ResourceId -Operation '打开慧策通端口' -DurationSeconds ($TimeoutSeconds + 30)
        Add-PMTimingStage -Trace $timing -Stage 'lease-acquire'
        $resource = Get-PMResourceById -ResourceId $ResourceId
        # Open only needs connection/page freshness. Profile size is a maintenance
        # concern and is intentionally reused here to avoid scanning multi-GB caches.
        $status = Get-PMResourceStatus -Resource $resource -SkipProfileMetrics
        Add-PMTimingStage -Trace $timing -Stage 'initial-tcp-cdp-page-check' -Details @{
            probeTotalMs = [int64]$status.timingSummary.totalMs
            browserStatus = [string]$status.browserStatus
        }
        if ($status.connectionStatus -eq '端口冲突') {
            throw (New-PMStructuredException -ErrorCode 'PM_PORT_OCCUPIED' -Message "端口占用：$($status.currentOccupancy)。监听服务不是可识别的浏览器调试接口。" -NextAction '关闭占用进程后重试，或为该资源更换未占用端口。')
        }
        if ($status.browserStatus -eq '浏览器可连接' -and [string]$status.sessionState -eq '已有会话未登记或资源占用') {
            throw (New-PMStructuredException -ErrorCode 'PM_RUNTIME_BINDING_MISMATCH' -Message '已有慧策 Chrome 会话未登记到当前资源，或该端口/Profile 已被其他资源占用；不会新建未登录窗口。' -NextAction '关闭该会话后重新登记，或使用与现有端口和 F 盘 Profile 完全一致的资源。')
        }

        if ($status.browserStatus -ne '浏览器可连接') {
            if ($resource.connectionMode -ne 'Launch') {
                throw (New-PMStructuredException -ErrorCode 'PM_BROWSER_NOT_AVAILABLE' -Message '浏览器未启动或调试接口不可访问；该资源为仅连接方式，程序不会自动启动浏览器。' -NextAction '确认 Google Chrome 正在运行且调试端口可访问后重试；仍失败时改用自动启动 Chrome。')
            }
            $browserStartedAt = [DateTimeOffset]::Now
            $startedProcess = Start-PMBrowser -Resource $resource
            $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
            do {
                Start-Sleep -Milliseconds 500
                $status = Get-PMResourceStatus -Resource $resource -SkipProfileMetrics
                if ($status.browserStatus -eq '浏览器可连接') {
                    break
                }
            } while ([DateTimeOffset]::Now -lt $deadline)
            if ($status.browserStatus -ne '浏览器可连接') {
                throw (New-PMStructuredException -ErrorCode 'PM_CDP_TIMEOUT' -Message "打开超时：浏览器进程已启动，但在 $TimeoutSeconds 秒内无法访问调试接口。" -NextAction '确认 Chrome 路径和配置目录可用后重试；超时进程将被回收。')
            }
            Add-PMTimingStage -Trace $timing -Stage 'browser-start-and-cdp-wait' -Details @{
                reused = $false
                startedProcessId = if ($null -eq $startedProcess) { $null } else { [int]$startedProcess.Id }
            }
        }
        else {
            Add-PMTimingStage -Trace $timing -Stage 'browser-start-and-cdp-wait' -Status 'reused' -Details @{
                reused = $true
                browserPid = $status.browserPid
            }
        }

        $pageAlreadyReady = $status.pageStatus -eq '平台页面正确'
        $null = Open-PMTargetPage -Resource $resource -Status $status
        if (-not $pageAlreadyReady -and -not [string]::IsNullOrWhiteSpace([string]$resource.startUrl)) {
            Start-Sleep -Milliseconds 300
        }
        Add-PMTimingStage -Trace $timing -Stage 'page-activate-or-create' -Status $(if ($pageAlreadyReady) { 'reused' } else { 'opened' })
        $finalStatus = Get-PMResourceStatus -Resource $resource -SkipProfileMetrics
        Add-PMTimingStage -Trace $timing -Stage 'final-tcp-cdp-page-check' -Details @{
            probeTotalMs = [int64]$finalStatus.timingSummary.totalMs
        }

        if ($finalStatus.browserStatus -ne '浏览器可连接') {
            throw (New-PMStructuredException -ErrorCode 'PM_CDP_UNAVAILABLE' -Message '调试接口不可访问。' -NextAction '确认 Google Chrome 调试端口仍在监听后重试。')
        }
        if (@($resource.platformUrlPatterns).Count -gt 0 -and $finalStatus.pageStatus -ne '平台页面正确') {
            throw (New-PMStructuredException -ErrorCode 'PM_PAGE_MISMATCH' -Message "页面错误：$($finalStatus.pageStatus)。$($finalStatus.lastError)" -NextAction '确认 Chrome 已打开慧策通页面后重试。')
        }

        if ($null -ne $lease) {
            Remove-PMLease -LeaseId $lease.leaseId
            $lease = $null
            $ownersAfterRelease = @(Get-PMPortOwners -Port ([int]$resource.port))
            $finalStatus.operationStatus = '打开成功'
            Set-PMStatusOccupancy -Status $finalStatus -Leases @() -Owners $ownersAfterRelease
        }
        Add-PMTimingStage -Trace $timing -Stage 'lease-release'
        $finalStatus | Add-Member -MemberType NoteProperty -Name operationStatus -Value '打开成功' -Force
        $finalStatus.lastOpenAt = Get-PMNow
        $finalStatus.lastOpenResult = 'success'
        Save-PMResourceStatus -ResourceId $ResourceId -Status $finalStatus
        Add-PMTimingStage -Trace $timing -Stage 'state-save'
        if (-not $SkipLoginMonitoring) {
        try {
            $agentEvidence = $null -ne $finalStatus.loginEvidence -and [string]$finalStatus.loginEvidence.source -eq 'huice-login-agent'
            if (-not $agentEvidence -and [string]$finalStatus.loginDetectionSource -ne 'huice-login-agent') {
                $detection = Start-PMLoginStateDetectionAsync -ResourceId $ResourceId
                if ($detection.started) {
                    $finalStatus.loginDetectionState = '检测中'
                    $finalStatus.loginDetectionStartedAt = Get-PMNow
                    $finalStatus.nextLoginDetectionAt = $null
                    $finalStatus.loginDetectionSource = 'bsclaw.huice.login-detector'
                }
            }
            $watcher = Start-PMLoginStateWatcher -ResourceId $ResourceId -RuntimeRoot $script:RuntimeRoot -ProjectRoot $script:ProjectRoot
            $finalStatus.watcherPid = $watcher.processId
            $finalStatus.watcherProcessStartTime = $watcher.processStartTime
            $finalStatus.watcherHeartbeatAt = Get-PMNow
            $finalStatus.watcherLastCheckAt = $null
            $finalStatus.watcherNextCheckAt = ([DateTimeOffset]::Now.AddSeconds(600)).ToString('o')
            $finalStatus.watcherFailureCount = 0
            $finalStatus.watcherErrorCode = $null
            Save-PMResourceStatus -ResourceId $ResourceId -Status $finalStatus
            Write-PMAudit -Action 'LoginStateWatcher' -ResourceId $ResourceId -Outcome 'Started' -Message '登录状态后台同步已启动。' -Details @{ processId = $watcher.processId; reused = [bool]$watcher.reused; intervalSeconds = 600 }
        }
        catch {
            $finalStatus.loginDetectionState = '检测失败'
            $finalStatus.loginDetectionErrorCode = 'LOGIN_DETECTION_START_FAILED'
            $finalStatus.lastError = '打开成功，但登录状态检测未启动：' + $_.Exception.Message
            Save-PMResourceStatus -ResourceId $ResourceId -Status $finalStatus
        }
        }
        Add-PMTimingStage -Trace $timing -Stage 'watcher-start-or-reuse' -Status $(if ($SkipLoginMonitoring) { 'skipped' } else { 'completed' }) -Details @{
            watcherPid = $finalStatus.watcherPid
        }
        Write-PMAudit -Action 'Open' -ResourceId $ResourceId -Outcome 'Success' -Message '慧策通端口已真实连接。' -Details @{
            port = $resource.port
            browserStatus = $finalStatus.browserStatus
            pageStatus = $finalStatus.pageStatus
            loginStatus = $finalStatus.loginStatus
            startedProcessId = if ($null -eq $startedProcess) { $null } else { $startedProcess.Id }
            elapsedMsBeforeAudit = [int64]$timing.stopwatch.ElapsedMilliseconds
            stages = @($timing.stages)
        }
        Add-PMTimingStage -Trace $timing -Stage 'audit-write'
        Write-PMLog -Level 'INFO' -ResourceId $ResourceId -Message '端口打开和回查完成。'
        return [pscustomobject]@{
            Resource = (Get-PMResourceById -ResourceId $ResourceId)
            Status = $finalStatus
            BrowserProcessId = if ($null -eq $startedProcess) { $null } else { $startedProcess.Id }
            TimingSummary = (Complete-PMTimingTrace -Trace $timing)
        }
    }
    catch {
        $failureException = $_.Exception
        $failureMessage = $failureException.Message
        $failureCode = if ($failureException.Data.Contains('errorCode')) { [string]$failureException.Data['errorCode'] } else { $null }
        $failureNextAction = if ($failureException.Data.Contains('nextAction')) { [string]$failureException.Data['nextAction'] } else { $null }

        if ($null -ne $startedProcess -and $null -ne $browserStartedAt -and $null -ne $resource) {
            try {
                $cleanupResult = Stop-PMOwnedBrowserProcesses -Resource $resource -StartedProcess $startedProcess -StartedAt $browserStartedAt
                if (-not $cleanupResult.cleaned) {
                    $failureMessage += "；浏览器清理未完成，残留 PID：$($cleanupResult.remainingProcessIds -join ',')"
                }
            }
            catch {
                $failureMessage += '；浏览器清理失败：' + $_.Exception.Message
            }
        }

        if ($null -ne $resource) {
            try {
                $failureStatus = Get-PMResourceStatus -Resource $resource -SkipProfileMetrics
                $failureStatus | Add-Member -MemberType NoteProperty -Name operationStatus -Value '打开失败' -Force
                $failureStatus.lastError = $failureMessage
            }
            catch {
                $failureStatus = New-PMFailureStatus -Resource $resource -Message $failureMessage -OperationStatus '打开失败'
            }
            $failureStatus.lastOpenAt = Get-PMNow
            $failureStatus.lastOpenResult = 'failed'
            try {
                Save-PMResourceStatus -ResourceId $ResourceId -Status $failureStatus
            }
            catch {
                Write-PMLog -Level 'ERROR' -ResourceId $ResourceId -Message ('打开失败状态保存失败：' + $_.Exception.Message)
            }
        }

        Write-PMAudit -Action 'Open' -ResourceId $ResourceId -Outcome 'Failed' -Message $failureMessage -Details @{
            cleanupAttempted = ($null -ne $startedProcess)
            cleanupCompleted = ($null -ne $cleanupResult -and $cleanupResult.cleaned)
            startedProcessId = if ($null -eq $startedProcess) { $null } else { $startedProcess.Id }
            elapsedMs = [int64]$timing.stopwatch.ElapsedMilliseconds
            completedStages = @($timing.stages)
        }
        Write-PMLog -Level 'ERROR' -ResourceId $ResourceId -Message $failureMessage
        $wrapped = [InvalidOperationException]::new($failureMessage, $failureException)
        if (-not [string]::IsNullOrWhiteSpace($failureCode)) { $wrapped.Data['errorCode'] = $failureCode }
        if (-not [string]::IsNullOrWhiteSpace($failureNextAction)) { $wrapped.Data['nextAction'] = $failureNextAction }
        throw $wrapped
    }
    finally {
        if ($null -ne $lease) {
            Remove-PMLease -LeaseId $lease.leaseId
        }
    }
}

Export-ModuleMember -Function @(
    'Get-PMProjectRoot',
    'Get-PMRuntimeRoot',
    'New-PMStructuredException',
    'Initialize-PMStorage',
    'Get-PMResources',
    'Get-PMResourceById',
    'Get-PMActiveLeases',
    'Set-PMLease',
    'Remove-PMLease',
    'Get-PMResourceOccupancy',
    'Register-PMResource',
    'Update-PMResource',
    'Set-PMResourceEnabled',
    'Remove-PMResource',
    'Test-PMResource',
    'Test-PMAllResources',
    'Open-PMResource',
    'Save-PMResourceStatus',
    'New-PMFailureStatus',
    'Get-PMNow',
    'Get-PMLastAuditId',
    'Write-PMAudit',
    'Start-PMLoginStateDetectionAsync',
    'Stop-PMLoginDetectorProcess',
    'Invoke-PMLoginDetectionReaper',
    'Invoke-PMLoginDetectionScheduler'
)
