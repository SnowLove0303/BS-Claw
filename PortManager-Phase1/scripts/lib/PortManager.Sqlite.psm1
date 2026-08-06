Set-StrictMode -Version Latest

$script:PythonPath = $null
$script:ServicePath = Join-Path $PSScriptRoot '..\sqlite_service.py'
$script:DbPath = $null
$script:IpcRoot = $null

function Initialize-PMSqlite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DataRoot,
        [Parameter(Mandatory = $true)][string]$JsonPath
    )
    if ([string]::IsNullOrWhiteSpace($script:PythonPath)) {
        $configured = [Environment]::GetEnvironmentVariable('BSCLAW_PYTHON_PATH', 'Process')
        $candidates = @(
            $configured,
            (Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))) 'tools\python\python.exe'),
            'F:\AIAPP\Codex\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
            (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        $existing = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        $script:PythonPath = @($existing | Where-Object { [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$_)) -like 'F:\' }) | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($script:PythonPath) -and $existing.Count -gt 0) {
            $roots = ($existing | ForEach-Object { [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$_)) } | Select-Object -Unique) -join ', '
            throw "SQLite Python 解释器必须位于 F 盘；当前候选路径位于：$roots。请设置 BSCLAW_PYTHON_PATH 为 F 盘 python.exe。"
        }
    }
    if ([string]::IsNullOrWhiteSpace($script:PythonPath)) { throw 'SQLite 运行依赖不存在。请设置 F 盘路径 BSCLAW_PYTHON_PATH，或放置 F 盘 tools\python\python.exe；不会自动创建空库覆盖旧数据。' }
    $fullData = [IO.Path]::GetFullPath($DataRoot)
    if ([IO.Path]::GetPathRoot($fullData) -notlike "F:\") { throw "SQLite 数据目录必须位于 F 盘：$fullData" }
    $script:DbPath = Join-Path $fullData 'port-manager.sqlite3'
    $script:IpcRoot = Join-Path $fullData 'sqlite-ipc'
    $backupDir = Join-Path $fullData 'migrations'
    $null = New-Item -ItemType Directory -Path $script:IpcRoot -Force
    $null = New-Item -ItemType Directory -Path $backupDir -Force
    $baselinePath = Join-Path $backupDir 'pre-sqlite-baseline.json'
    if (-not (Test-Path -LiteralPath $baselinePath -PathType Leaf)) {
        $baselineFiles = @()
        foreach ($candidate in @('ports.json','leases.json','login-detections.json')) {
            $source = Join-Path $fullData $candidate
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $copyDir = Join-Path $backupDir 'legacy'
                $null = New-Item -ItemType Directory -Path $copyDir -Force
                Copy-Item -LiteralPath $source -Destination (Join-Path $copyDir $candidate) -Force
                $hash = Get-FileHash -LiteralPath $source -Algorithm SHA256
                $baselineFiles += [ordered]@{ path = $source; backup = (Join-Path $copyDir $candidate); sha256 = $hash.Hash; bytes = (Get-Item -LiteralPath $source).Length }
            }
        }
        $baseline = [ordered]@{ createdAt = [DateTimeOffset]::Now.ToString('o'); dataRoot = $fullData; files = $baselineFiles }
        [IO.File]::WriteAllText($baselinePath, ($baseline | ConvertTo-Json -Depth 8) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
    $payload = [ordered]@{ jsonPath = $JsonPath; backupDir = $backupDir }
    Invoke-PMSqliteService -Action 'migrate' -Payload $payload | Out-Null
}

function Invoke-PMSqliteService {
    param([Parameter(Mandatory = $true)][string]$Action, [object]$Payload, [switch]$AllowFailure)
    if ([string]::IsNullOrWhiteSpace($script:DbPath)) { throw 'SQLite 数据访问层尚未初始化。' }
    $requestPath = Join-Path $script:IpcRoot ("request-$([Guid]::NewGuid().ToString('N')).json")
    $responsePath = Join-Path $script:IpcRoot ("response-$([Guid]::NewGuid().ToString('N')).json")
    $errorPath = Join-Path $script:IpcRoot ("error-$([Guid]::NewGuid().ToString('N')).txt")
    try {
        if ($null -ne $Payload) {
            [IO.File]::WriteAllText($requestPath, ($Payload | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        }
        $env:PYTHONPYCACHEPREFIX = Join-Path (Split-Path -Parent $script:DbPath) 'python-cache'
        $args = @($script:ServicePath, '--action', $Action, '--db', $script:DbPath)
        if ($null -ne $Payload) { $args += @('--payload', $requestPath) }
        $argText = (@($args | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
        $process = Start-Process -FilePath $script:PythonPath -ArgumentList $argText -WindowStyle Hidden `
            -RedirectStandardOutput $responsePath -RedirectStandardError $errorPath -PassThru
        if (-not $process.WaitForExit(30000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw "SQLite 操作超时（30 秒）：$Action"
        }
        $text = if (Test-Path -LiteralPath $responsePath) { [IO.File]::ReadAllText($responsePath, [Text.Encoding]::UTF8).Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($text)) { throw "SQLite 服务无输出：$Action" }
        $result = $text | ConvertFrom-Json
        $resultError = if ($result.PSObject.Properties.Name -contains 'error') { [string]$result.error } else { '无错误详情' }
        if (($result.PSObject.Properties.Name -contains 'ok') -and $result.ok -eq $false -and -not $AllowFailure) { throw "SQLite 操作失败($Action)：$resultError" }
        return $result
    }
    finally {
        if (Test-Path -LiteralPath $requestPath -PathType Leaf) { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $responsePath -PathType Leaf) { Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $errorPath -PathType Leaf) { Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue }
    }
}

function Test-PMSqliteWatcherProcessInstance {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$ExpectedProcessStartTime
    )
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return [pscustomobject]@{ healthy = $false; errorCode = 'WATCHER_PROCESS_NOT_FOUND' }
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedProcessStartTime)) {
        return [pscustomobject]@{ healthy = $false; errorCode = 'WATCHER_PROCESS_START_TIME_MISSING' }
    }
    try {
        $expectedStart = [DateTimeOffset]::Parse(
            $ExpectedProcessStartTime,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).UtcDateTime
        $actualStart = $process.StartTime.ToUniversalTime()
    }
    catch {
        return [pscustomobject]@{ healthy = $false; errorCode = 'WATCHER_PROCESS_START_TIME_INVALID' }
    }
    if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
        return [pscustomobject]@{ healthy = $false; errorCode = 'WATCHER_PROCESS_START_MISMATCH' }
    }
    $instance = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    $commandLine = if ($null -eq $instance) { '' } else { [string]$instance.CommandLine }
    $watcherCommand = $commandLine -match '(?i)(login-state-watcher\.ps1|login-agent\.ps1.+-Action\s+Watch)'
    $resourceCommand = $commandLine -match [regex]::Escape($ResourceId)
    if (-not $watcherCommand -or -not $resourceCommand) {
        return [pscustomobject]@{ healthy = $false; errorCode = 'WATCHER_PROCESS_IDENTITY_MISMATCH' }
    }
    return [pscustomobject]@{ healthy = $true; errorCode = $null }
}

function Read-PMSqliteStore {
    $store = Invoke-PMSqliteService -Action 'read_store'
    foreach ($resource in @($store.resources)) {
        $status = $resource.lastStatus
        if ($null -eq $status -or $null -eq $status.watcherPid) { continue }
        $watcherPid = [int]$status.watcherPid
        if ($watcherPid -le 0) { continue }
        $watcherStart = [string]$status.watcherProcessStartTime
        $health = Test-PMSqliteWatcherProcessInstance -ResourceId ([string]$resource.resourceId) `
            -ProcessId $watcherPid -ExpectedProcessStartTime $watcherStart
        if ([bool]$health.healthy) { continue }
        $repair = Invoke-PMSqliteService -Action 'mark_watcher_invalid' -Payload @{
            resourceId = [string]$resource.resourceId
            expectedPid = $watcherPid
            expectedProcessStartTime = if ([string]::IsNullOrWhiteSpace($watcherStart)) { $null } else { $watcherStart }
            errorCode = [string]$health.errorCode
            checkedAt = [DateTimeOffset]::Now.ToString('o')
            checkerProcessId = $PID
        }
        if ([bool]$repair.updated) {
            $status.watcherPid = $null
            $status.watcherProcessStartTime = $null
            $status.watcherHeartbeatAt = $null
            $status.watcherNextCheckAt = $null
            $status.watcherFailureCount = [int]$status.watcherFailureCount + 1
            $status.watcherErrorCode = [string]$health.errorCode
        }
    }
    return $store
}
function Test-PMSqliteIntegrity { return (Invoke-PMSqliteService -Action 'integrity_check') }
function Backup-PMSqliteDatabase { param([Parameter(Mandatory = $true)][string]$Destination); if ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destination)) -notlike 'F:\') { throw 'SQLite 备份目标必须位于 F 盘。' }; return (Invoke-PMSqliteService -Action 'backup_database' -Payload @{ destination = [IO.Path]::GetFullPath($Destination) }) }
function Save-PMSqliteStore { param([Parameter(Mandatory = $true)][object]$Store); Invoke-PMSqliteService -Action 'save_store' -Payload @{ resources = @($Store.resources) } | Out-Null }
function Remove-PMSqliteResource { param([Parameter(Mandatory = $true)][string]$ResourceId); Invoke-PMSqliteService -Action 'delete_resource' -Payload @{ resourceId = $ResourceId } | Out-Null }
function Get-PMSqliteRawLeases {
    return (Invoke-PMSqliteService -Action 'read_leases')
}

function Test-PMSqliteLeaseOwnerInstance {
    param([Parameter(Mandatory = $true)][object]$Lease)

    $ownerProcessId = 0
    if ($Lease.PSObject.Properties.Name -contains 'processId') {
        [void][int]::TryParse([string]$Lease.processId, [ref]$ownerProcessId)
    }
    if ($ownerProcessId -le 0) {
        return [pscustomobject]@{
            healthy = $false
            reclaimable = $true
            errorCode = 'LEASE_OWNER_PROCESS_ID_MISSING'
        }
    }

    $process = Get-Process -Id $ownerProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return [pscustomobject]@{
            healthy = $false
            reclaimable = $true
            errorCode = 'LEASE_OWNER_PROCESS_NOT_FOUND'
        }
    }

    try {
        $leaseStartedAt = [DateTimeOffset]::Parse(
            [string]$Lease.startedAt,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).UtcDateTime
        $actualProcessStart = $process.StartTime.ToUniversalTime()
    }
    catch {
        # A live PID with unverifiable identity must remain protected. It can
        # still expire normally, but must never be reclaimed on an assumption.
        return [pscustomobject]@{
            healthy = $false
            reclaimable = $false
            errorCode = 'LEASE_OWNER_INSTANCE_UNVERIFIABLE'
        }
    }

    # The owner process must have existed before it created the lease. A
    # process with the same PID but a later start time is a reused PID and not
    # the original owner instance.
    if ($actualProcessStart -gt $leaseStartedAt) {
        return [pscustomobject]@{
            healthy = $false
            reclaimable = $true
            errorCode = 'LEASE_OWNER_PROCESS_INSTANCE_MISMATCH'
        }
    }

    return [pscustomobject]@{
        healthy = $true
        reclaimable = $false
        errorCode = $null
    }
}

function Invoke-PMSqliteStaleLeaseReap {
    param([string]$ResourceId)

    $snapshot = Get-PMSqliteRawLeases
    $reclaimed = @()
    foreach ($lease in @($snapshot.leases)) {
        if (-not [string]::IsNullOrWhiteSpace($ResourceId) -and
            [string]$lease.resourceId -ne $ResourceId) { continue }
        $health = Test-PMSqliteLeaseOwnerInstance -Lease $lease
        if (-not [bool]$health.reclaimable) { continue }

        $result = Invoke-PMSqliteService -Action 'reclaim_stale_lease' -Payload @{
            leaseId = [string]$lease.leaseId
            resourceId = [string]$lease.resourceId
            expectedProcessId = [int]$lease.processId
            expectedStartedAt = [string]$lease.startedAt
            expectedTaskRef = if ($null -eq $lease.taskRef) { $null } else { [string]$lease.taskRef }
            errorCode = [string]$health.errorCode
            checkerProcessId = $PID
            checkedAt = [DateTimeOffset]::Now.ToString('o')
        }
        if ([bool]$result.reclaimed) {
            $reclaimed += [pscustomobject]@{
                leaseId = [string]$lease.leaseId
                resourceId = [string]$lease.resourceId
                errorCode = [string]$health.errorCode
                auditId = $result.auditId
            }
        }
    }
    $current = Get-PMSqliteRawLeases
    if ($reclaimed.Count -gt 0) {
        $current | Add-Member -MemberType NoteProperty -Name reclaimedLeases -Value @($reclaimed) -Force
    }
    return $current
}

function Get-PMSqliteLeases {
    param([string]$ResourceId, [switch]$SkipStaleReap)
    if ($SkipStaleReap) { return (Get-PMSqliteRawLeases) }
    return (Invoke-PMSqliteStaleLeaseReap -ResourceId $ResourceId)
}

function Add-PMSqliteLease {
    param([Parameter(Mandatory = $true)][object]$Lease)

    # HuiceLoginAgent and PortManager share this entry point. Reap only leases
    # whose original owner process is proven gone or replaced, then let SQLite
    # arbitrate the new lease atomically.
    $null = Invoke-PMSqliteStaleLeaseReap -ResourceId ([string]$Lease.resourceId)
    $result = Invoke-PMSqliteService -Action 'add_lease' -Payload $Lease -AllowFailure
    if (-not [bool]$result.ok -and
        $result.PSObject.Properties.Name -contains 'activeLease' -and
        $null -ne $result.activeLease) {
        # Close the small race where the prior owner exits between the initial
        # reap and SQLite's add_lease transaction. Retry at most once.
        $health = Test-PMSqliteLeaseOwnerInstance -Lease $result.activeLease
        if ([bool]$health.reclaimable) {
            $reclaim = Invoke-PMSqliteService -Action 'reclaim_stale_lease' -Payload @{
                leaseId = [string]$result.activeLease.leaseId
                resourceId = [string]$result.activeLease.resourceId
                expectedProcessId = [int]$result.activeLease.processId
                expectedStartedAt = [string]$result.activeLease.startedAt
                expectedTaskRef = if ($null -eq $result.activeLease.taskRef) { $null } else { [string]$result.activeLease.taskRef }
                errorCode = [string]$health.errorCode
                checkerProcessId = $PID
                checkedAt = [DateTimeOffset]::Now.ToString('o')
            }
            if ([bool]$reclaim.reclaimed) {
                $result = Invoke-PMSqliteService -Action 'add_lease' -Payload $Lease -AllowFailure
            }
        }
    }
    if (-not [bool]$result.ok) {
        $busy = [InvalidOperationException]::new('RESOURCE_BUSY')
        $busy.Data['errorCode'] = 'RESOURCE_BUSY'
        if ($result.PSObject.Properties.Name -contains 'activeLease') { $busy.Data['activeLease'] = $result.activeLease }
        throw $busy
    }
    return $Lease
}
function Release-PMSqliteLease { param([Parameter(Mandatory = $true)][string]$LeaseId); Invoke-PMSqliteService -Action 'release_lease' -Payload @{ leaseId = $LeaseId } | Out-Null }
function Get-PMSqliteDetectionTask { param([Parameter(Mandatory = $true)][string]$ResourceId); return (Invoke-PMSqliteService -Action 'read_detection_task' -Payload @{ resourceId = $ResourceId }).task }
function Start-PMSqliteDetectionTask { param([Parameter(Mandatory = $true)][hashtable]$Task); return (Invoke-PMSqliteService -Action 'start_detection_task' -Payload $Task -AllowFailure) }
function Complete-PMSqliteDetectionTask { param([Parameter(Mandatory = $true)][hashtable]$Task); return (Invoke-PMSqliteService -Action 'complete_detection_task' -Payload $Task -AllowFailure) }
function Set-PMSqliteDetectionProcess { param([Parameter(Mandatory = $true)][string]$AttemptId,[Parameter(Mandatory = $true)][int]$ProcessId); Invoke-PMSqliteService -Action 'set_detection_process' -Payload @{ attemptId = $AttemptId; processId = $ProcessId } | Out-Null }
function Cancel-PMSqliteDetectionTask { param([Parameter(Mandatory = $true)][string]$ResourceId); return (Invoke-PMSqliteService -Action 'cancel_detection_task' -Payload @{ resourceId = $ResourceId }).task }
function Get-PMSqliteExpiredDetectionTasks { return (Invoke-PMSqliteService -Action 'read_expired_detection_tasks').tasks }
function Mark-PMSqliteDetectionReapFailed { param([Parameter(Mandatory = $true)][string]$ResourceId,[Parameter(Mandatory = $true)][string]$AttemptId); return (Invoke-PMSqliteService -Action 'mark_detection_reap_failed' -Payload @{ resourceId = $ResourceId; attemptId = $AttemptId } -AllowFailure) }
function Add-PMSqliteLoginCheck {
    param([Parameter(Mandatory = $true)][hashtable]$Check)
    Invoke-PMSqliteService -Action 'add_login_check' -Payload $Check | Out-Null
}
function Add-PMSqliteAudit {
    param([Parameter(Mandatory = $true)][hashtable]$Audit)
    return (Invoke-PMSqliteService -Action 'add_audit' -Payload $Audit)
}
function Set-PMSqliteLoginRuntime {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    return (Invoke-PMSqliteService -Action 'record_login_runtime' -Payload $State)
}
function Get-PMSqlitePath { return $script:DbPath }

Export-ModuleMember -Function @('Initialize-PMSqlite','Read-PMSqliteStore','Test-PMSqliteIntegrity','Backup-PMSqliteDatabase','Save-PMSqliteStore','Remove-PMSqliteResource','Get-PMSqliteLeases','Add-PMSqliteLease','Release-PMSqliteLease','Get-PMSqliteDetectionTask','Get-PMSqliteExpiredDetectionTasks','Mark-PMSqliteDetectionReapFailed','Start-PMSqliteDetectionTask','Set-PMSqliteDetectionProcess','Complete-PMSqliteDetectionTask','Cancel-PMSqliteDetectionTask','Add-PMSqliteLoginCheck','Add-PMSqliteAudit','Set-PMSqliteLoginRuntime','Get-PMSqlitePath')
