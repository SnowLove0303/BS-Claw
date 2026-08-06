param(
    [Parameter(Mandatory = $true)][string]$ResourceId,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [ValidateRange(30, 3600)][int]$IntervalSeconds = 600
)

$ErrorActionPreference = 'Stop'
$env:BSCLAW_PM_RUNTIME_ROOT = $RuntimeRoot
$core = Join-Path $ProjectRoot 'scripts\lib\PortManager.Core.psm1'
Import-Module $core -Force -WarningAction SilentlyContinue
$watcherStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')

function Save-WatcherState {
    param([object]$Resource,[string]$ErrorCode)
    $status = $Resource.lastStatus
    $status.watcherPid = [int]$PID
    $status.watcherProcessStartTime = $watcherStart
    $status.watcherHeartbeatAt = (Get-Date).ToUniversalTime().ToString('o')
    $status.watcherNextCheckAt = ([DateTimeOffset]::Now.AddSeconds($IntervalSeconds)).ToString('o')
    if ([string]::IsNullOrWhiteSpace($ErrorCode)) {
        $status.watcherLastCheckAt = (Get-Date).ToUniversalTime().ToString('o')
        $status.watcherFailureCount = 0
        $status.watcherErrorCode = $null
    } else {
        $status.watcherFailureCount = [int]$status.watcherFailureCount + 1
        $status.watcherErrorCode = $ErrorCode
    }
    Save-PMResourceStatus -ResourceId $ResourceId -Status $status
}

while ($true) {
    try {
        $resource = Get-PMResourceById -ResourceId $ResourceId
    } catch { break }
    try {
        Save-WatcherState -Resource $resource -ErrorCode $null
        $null = Test-PMResource -ResourceId $ResourceId
    } catch {
        $code = if ($_.Exception.Data.Contains('errorCode')) { [string]$_.Exception.Data['errorCode'] } else { [string]$_.Exception.Message }
        if ($code -notin @('RESOURCE_BUSY','PM_RESOURCE_LEASED')) {
            try { Save-WatcherState -Resource $resource -ErrorCode 'LOGIN_WATCHER_CHECK_FAILED' } catch { }
        }
    }
    Start-Sleep -Seconds $IntervalSeconds
}
