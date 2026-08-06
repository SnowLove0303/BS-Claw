Set-StrictMode -Version Latest

$persistenceModule = Join-Path $PSScriptRoot 'PortManager.Persistence.psm1'
Import-Module $persistenceModule -Force
$sqliteModule = Join-Path $PSScriptRoot 'PortManager.Sqlite.psm1'
Import-Module $sqliteModule -Force -WarningAction SilentlyContinue

function Initialize-PMDetectorSqlite {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
    $data = Join-Path (Assert-PMPersistencePathOnFDrive -Path $RuntimeRoot -FieldName 'login detector runtime') 'data'
    $null = New-Item -ItemType Directory -Path $data -Force
    Initialize-PMSqlite -DataRoot $data -JsonPath (Join-Path $data 'ports.json')
}

function Get-PMDetectorPaths {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
    $root = Assert-PMPersistencePathOnFDrive -Path $RuntimeRoot -FieldName 'login detector runtime'
    $logs = Join-Path $root 'logs'
    $null = New-Item -ItemType Directory -Path $logs -Force
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToUpperInvariant())) } finally { $sha.Dispose() }
    $hashText = (($hashBytes[0..7] | ForEach-Object { $_.ToString('X2') }) -join '')
    return [pscustomobject]@{ Logs = $logs; Mutex = 'Local\BSClaw.LoginDetector.' + $hashText }
}

function Test-PMDetectorProcessAlive {
    param([object]$Record)
    if ($null -eq $Record -or [int]$Record.processId -le 0) { return $false }
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$Record.processId)" -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return $false }
    $commandLine = [string]$proc.CommandLine
    if ($commandLine -notmatch '(?i)login-state-worker\.ps1' -or $commandLine.IndexOf([string]$Record.attemptId, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    try {
        $started = (Get-Process -Id ([int]$Record.processId) -ErrorAction Stop).StartTime
        $recordStarted = [DateTimeOffset]::Parse([string]$Record.startedAt).LocalDateTime
        if ($started -lt $recordStarted.AddSeconds(-5)) { return $false }
    } catch { return $false }
    return $true
}

function Get-PMLoginDetectionRecord {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot, [Parameter(Mandatory = $true)][string]$ResourceId)
    Initialize-PMDetectorSqlite -RuntimeRoot $RuntimeRoot
    return Get-PMSqliteDetectionTask -ResourceId $ResourceId
}

function Start-PMLoginDetectorProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [int]$TimeoutSeconds = 30,
        [string]$DetectorVersion = '1'
    )
    $paths = Get-PMDetectorPaths -RuntimeRoot $RuntimeRoot
    Initialize-PMDetectorSqlite -RuntimeRoot $RuntimeRoot
    $attemptId = 'LDA-' + [Guid]::NewGuid().ToString('N').Substring(0, 12).ToUpperInvariant()
    $outPath = Join-Path $paths.Logs "login-detector-$attemptId.out.log"
    $errPath = Join-Path $paths.Logs "login-detector-$attemptId.err.log"
    $existing = Get-PMSqliteDetectionTask -ResourceId $ResourceId
    if ($null -ne $existing -and [string]$existing.state -eq 'running') {
        $expired = $false
        try { $expired = [DateTimeOffset]::Parse([string]$existing.timeoutAt) -le [DateTimeOffset]::Now } catch { $expired = $true }
        if ($expired) {
            $recovered = Stop-PMLoginDetectorProcess -RuntimeRoot $RuntimeRoot -ResourceId $ResourceId
            if (-not $recovered.cancelled) {
                return [pscustomobject]@{ started = $false; errorCode = 'LOGIN_DETECTION_REAP_FAILED'; message = 'Old login detection process is still alive; resource remains occupied.'; record = Get-PMSqliteDetectionTask -ResourceId $ResourceId }
            }
        }
    }
    $now = [DateTimeOffset]::Now
    $task = @{ attemptId = $attemptId; resourceId = $ResourceId; processId = 0; startedAt = $now.ToString('o'); timeoutAt = $now.AddSeconds($TimeoutSeconds).ToString('o'); retryCount = 0; detectorVersion = $DetectorVersion; stdoutPath = $outPath; stderrPath = $errPath }
    $reservation = Start-PMSqliteDetectionTask -Task $task
    if (-not [bool]$reservation.ok) {
        $code = if ([string]$reservation.error -eq 'LOGIN_DETECTION_EXPIRED_REQUIRES_REAP') { 'LOGIN_DETECTION_REAP_REQUIRED' } else { 'LOGIN_DETECTION_IN_FLIGHT' }
        return [pscustomobject]@{ started = $false; errorCode = $code; message = 'login detection is already running or requires safe reaping'; record = Get-PMSqliteDetectionTask -ResourceId $ResourceId }
    }
    try {
        $worker = Join-Path $ProjectRoot 'scripts\login-state-worker.ps1'
        $psExe = Join-Path $PSHOME 'powershell.exe'
        $args = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"{0}"' -f $worker),'-ResourceId',('"{0}"' -f $ResourceId),'-RuntimeRoot',('"{0}"' -f $RuntimeRoot),'-AttemptId',('"{0}"' -f $attemptId),'-TimeoutSeconds',[string]$TimeoutSeconds,'-DetectorVersion',('"{0}"' -f $DetectorVersion))
        # This is an asynchronous worker. Redirected standard handles keep some
        # parent PowerShell pipelines alive until the worker exits, making
        # LoginCheck appear synchronous. The worker persists outcome/error data
        # to SQLite, so launch it as an independent hidden process.
        $process = Start-Process -FilePath $psExe -ArgumentList ($args -join ' ') -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru
        Set-PMSqliteDetectionProcess -AttemptId $attemptId -ProcessId ([int]$process.Id)
        $record = Get-PMSqliteDetectionTask -ResourceId $ResourceId
        if ($null -eq $record -or [int]$record.processId -ne [int]$process.Id) {
            Stop-Process -Id ([int]$process.Id) -Force -ErrorAction SilentlyContinue
            throw 'Login detector worker PID was not persisted to SQLite.'
        }
        return [pscustomobject]@{ started = $true; errorCode = $null; message = 'login detection started'; record = $record }
    }
    catch {
        Complete-PMSqliteDetectionTask -Task @{ resourceId = $ResourceId; attemptId = $attemptId; state = 'failed'; errorCode = 'LOGIN_DETECTION_START_FAILED'; redactedError = $_.Exception.Message; finishedAt = [DateTimeOffset]::Now.ToString('o') }
        throw
    }
}

function Complete-PMLoginDetectorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [Parameter(Mandatory = $true)][ValidateSet('completed','failed','cancelled')][string]$State,
        [string]$ErrorCode,
        [string]$RedactedError,
        [string]$NextRetryAt,
        [int]$ProcessId = 0
    )
    Initialize-PMDetectorSqlite -RuntimeRoot $RuntimeRoot
    Complete-PMSqliteDetectionTask -Task @{ resourceId = $ResourceId; attemptId = $AttemptId; state = $State; errorCode = $ErrorCode; redactedError = $RedactedError; nextRetryAt = $NextRetryAt; processId = $ProcessId; finishedAt = [DateTimeOffset]::Now.ToString('o') }
}

function Stop-PMLoginDetectorProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot, [Parameter(Mandatory = $true)][string]$ResourceId)
    Initialize-PMDetectorSqlite -RuntimeRoot $RuntimeRoot
    $record = Get-PMSqliteDetectionTask -ResourceId $ResourceId
    if ($null -eq $record -or [string]$record.state -ne 'running') { return [pscustomobject]@{ cancelled = $false; message = 'no running login detection'; record = $record } }
    if (Test-PMDetectorProcessAlive -Record $record) {
        Stop-Process -Id ([int]$record.processId) -Force -ErrorAction SilentlyContinue
        $deadline = [DateTimeOffset]::Now.AddSeconds(5)
        do { Start-Sleep -Milliseconds 100 } while ((Test-PMDetectorProcessAlive -Record $record) -and [DateTimeOffset]::Now -lt $deadline)
        if (Test-PMDetectorProcessAlive -Record $record) {
            return [pscustomobject]@{ cancelled = $false; message = 'login detection process did not exit'; errorCode = 'LOGIN_DETECTION_PROCESS_STILL_RUNNING'; record = $record }
        }
    }
    $task = Cancel-PMSqliteDetectionTask -ResourceId $ResourceId
    return [pscustomobject]@{ cancelled = $true; message = 'login detection cancelled'; record = $task }
}

function Invoke-PMLoginDetectionReaperWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
    Initialize-PMDetectorSqlite -RuntimeRoot $RuntimeRoot
    $expired = @(Get-PMSqliteExpiredDetectionTasks)
    $closed = @()
    foreach ($task in $expired) {
        $record = [pscustomobject]@{ processId = $task.process_id; attemptId = $task.attempt_id; startedAt = $task.started_at }
        $workerAlive = Test-PMDetectorProcessAlive -Record $record
        if ($workerAlive) {
            Stop-Process -Id ([int]$task.process_id) -Force -ErrorAction SilentlyContinue
            $deadline = [DateTimeOffset]::Now.AddSeconds(5)
            do { Start-Sleep -Milliseconds 100 } while ((Test-PMDetectorProcessAlive -Record $record) -and [DateTimeOffset]::Now -lt $deadline)
            $workerAlive = Test-PMDetectorProcessAlive -Record $record
        }
        if ($workerAlive) {
            $null = Mark-PMSqliteDetectionReapFailed -ResourceId $task.resource_id -AttemptId $task.attempt_id
            continue
        }
        Complete-PMSqliteDetectionTask -Task @{ resourceId = $task.resource_id; attemptId = $task.attempt_id; state = 'failed'; errorCode = 'LOGIN_DETECTION_TIMEOUT'; redactedError = 'login detection timeout; task reaped'; nextRetryAt = [DateTimeOffset]::Now.AddSeconds(60).ToString('o'); finishedAt = [DateTimeOffset]::Now.ToString('o') }
        $closed += [pscustomobject]@{ attemptId = $task.attempt_id; resourceId = $task.resource_id; processId = $task.process_id }
    }
    return @($closed)
}

function Start-PMLoginStateWatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot,
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [int]$IntervalSeconds = 600
    )
    $existing = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        [int]$_.ProcessId -ne $PID -and [string]$_.Name -ieq 'powershell.exe' -and
        (([string]$_.CommandLine -match '(?i)-File\s+["'']?.*login-state-watcher\.ps1') -or
         (([string]$_.CommandLine -match '(?i)login-agent\.ps1') -and ([string]$_.CommandLine -match '(?i)-Action\s+Watch'))) -and
        ([string]$_.CommandLine -match [regex]::Escape($ResourceId))
    }) | Select-Object -First 1
    if ($null -ne $existing) {
        $existingStart = $null
        try { $existingStart = (Get-Process -Id ([int]$existing.ProcessId) -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { }
        return [pscustomobject]@{ started = $false; reused = $true; processId = [int]$existing.ProcessId; processStartTime = $existingStart }
    }
    $agentPath = 'F:\XIANGMU\BS Claw\HuiceLoginAgent\login-agent.ps1'
    $scriptPath = if (Test-Path -LiteralPath $agentPath -PathType Leaf) { $agentPath } else { Join-Path $ProjectRoot 'scripts\login-state-watcher.ps1' }
    $null = Assert-PMPersistencePathOnFDrive -Path $RuntimeRoot -FieldName 'login watcher runtime'
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $args = if ([IO.Path]::GetFullPath($scriptPath) -eq [IO.Path]::GetFullPath($agentPath)) {
        @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"{0}"' -f $scriptPath),'-Action','Watch','-ResourceId',('"{0}"' -f $ResourceId),'-IntervalSeconds',[string]$IntervalSeconds)
    } else {
        @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"{0}"' -f $scriptPath),'-ResourceId',('"{0}"' -f $ResourceId),'-RuntimeRoot',('"{0}"' -f $RuntimeRoot),'-ProjectRoot',('"{0}"' -f $ProjectRoot),'-IntervalSeconds',[string]$IntervalSeconds)
    }
    # The watcher is long-lived. Redirecting its standard handles from an Open
    # command keeps the parent PowerShell pipeline alive until the watcher exits.
    # Start it as an independent hidden process; health and failures are persisted
    # through SQLite runtime state and audit records.
    $process = Start-Process -FilePath $psExe -ArgumentList ($args -join ' ') -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru
    $startTime = $null
    try { $startTime = (Get-Process -Id ([int]$process.Id) -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { }
    return [pscustomobject]@{ started = $true; reused = $false; processId = [int]$process.Id; processStartTime = $startTime; outputPath = $null; errorPath = $null }
}

function Stop-PMLoginStateWatcher {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ResourceId)
    $found = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        [int]$_.ProcessId -ne $PID -and [string]$_.Name -ieq 'powershell.exe' -and
        (([string]$_.CommandLine -match '(?i)-File\s+["'']?.*login-state-watcher\.ps1') -or
         (([string]$_.CommandLine -match '(?i)login-agent\.ps1') -and ([string]$_.CommandLine -match '(?i)-Action\s+Watch'))) -and
        ([string]$_.CommandLine -match [regex]::Escape($ResourceId))
    })
    foreach ($proc in $found) { Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ stoppedProcessIds = @($found | ForEach-Object { [int]$_.ProcessId }) }
}

Export-ModuleMember -Function @('Start-PMLoginDetectorProcess','Get-PMLoginDetectionRecord','Complete-PMLoginDetectorRecord','Stop-PMLoginDetectorProcess','Invoke-PMLoginDetectionReaperWorker','Start-PMLoginStateWatcher','Stop-PMLoginStateWatcher')
