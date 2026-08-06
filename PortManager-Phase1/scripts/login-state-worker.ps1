[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceId,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$AttemptId,
    [int]$TimeoutSeconds = 30,
    [string]$DetectorVersion = '1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:BSCLAW_PM_RUNTIME_ROOT = $RuntimeRoot
$modulePath = Join-Path $PSScriptRoot 'lib\PortManager.Core.psm1'
$detectorPath = Join-Path $PSScriptRoot 'lib\PortManager.LoginStateDetector.psm1'
$huiceAdapterPath = Join-Path $PSScriptRoot 'lib\PortManager.HuiceLoginAdapter.psm1'
Import-Module $modulePath -Force
Import-Module $detectorPath -Force -WarningAction SilentlyContinue
Import-Module $huiceAdapterPath -Force -WarningAction SilentlyContinue
# Give the launcher time to persist this worker PID before the worker opens the
# same SQLite database. This avoids startup lock contention while preserving
# asynchronous execution.
Start-Sleep -Milliseconds 2500
Initialize-PMStorage

function Get-PMRedactedDetectorMessage {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return '登录状态检测失败。' }
    $safe = [string]$Message
    $safe = $safe -replace '(?i)(cookie|token|authorization|password|passwd)\s*[:=]\s*\S+', '$1=[已脱敏]'
    $safe = $safe -replace '(?i)Bearer\s+[A-Za-z0-9._~+/=-]{8,}', 'Bearer [已脱敏]'
    return ($safe -replace '\r?\n', ' ')
}

$finishedState = 'failed'
$status = $null
$errorCode = $null
$errorMessage = $null
try {
    $resource = Get-PMResourceById -ResourceId $ResourceId
    if ([string]$resource.platformId -eq 'huice') {
        $agentResult = Invoke-PMHuiceLoginAgent -Action Check -ResourceId $ResourceId -TimeoutSeconds $TimeoutSeconds
        $resource = Get-PMResourceById -ResourceId $ResourceId
        $status = $resource.lastStatus
        $status.loginDetectionState = '已完成'
        $status.loginDetectionStartedAt = $resource.lastStatus.loginDetectionStartedAt
        $status.nextLoginDetectionAt = ([DateTimeOffset]::Now.AddSeconds(600)).ToString('o')
        $status.loginDetectionErrorCode = $null
        Save-PMResourceStatus -ResourceId $ResourceId -Status $status
    }
    else {
        $result = Test-PMResource -ResourceId $ResourceId
        $resource = Get-PMResourceById -ResourceId $ResourceId
        $status = $result.Status
        $status.loginDetectionState = '已完成'
        $status.loginDetectionStartedAt = $resource.lastStatus.loginDetectionStartedAt
        $status.nextLoginDetectionAt = ([DateTimeOffset]::Now.AddSeconds(600)).ToString('o')
        $status.loginDetectionSource = 'bsclaw.huice.login-detector'
        $status.loginDetectionErrorCode = $null
        $status.loginCookieEvidencePresent = $null
        $status.loginApiProbeStatus = '未配置可靠探针'
        $status.loginConfidence = [string]$status.loginEvidence.confidence
        $status.detectorVersion = $DetectorVersion
        Save-PMResourceStatus -ResourceId $ResourceId -Status $status
    }
    $finishedState = 'completed'
}
catch {
    $errorMessage = Get-PMRedactedDetectorMessage -Message $_.Exception.Message
    $errorCode = 'LOGIN_DETECTION_FAILED'
    try {
        $resource = Get-PMResourceById -ResourceId $ResourceId
        $status = $resource.lastStatus
        $status.loginDetectionState = '检测失败'
        $status.loginDetectionErrorCode = $errorCode
        $status.loginDetectionSource = 'bsclaw.huice.login-detector'
        $status.loginApiProbeStatus = '检测异常'
        $status.loginCookieEvidencePresent = $null
        $status.loginConfidence = 'unknown'
        $status.detectorVersion = $DetectorVersion
        $status.nextLoginDetectionAt = ([DateTimeOffset]::Now.AddSeconds(60)).ToString('o')
        $status.lastError = $errorMessage
        Save-PMResourceStatus -ResourceId $ResourceId -Status $status
    }
    catch {
        $errorMessage = Get-PMRedactedDetectorMessage -Message ($errorMessage + '；失败状态保存异常：' + $_.Exception.Message)
    }
}
finally {
    try {
        $evidence = if ($null -ne $status -and $null -ne $status.loginEvidence) { [string]$status.loginEvidence.evidenceSummary } else { $errorMessage }
        $evidenceType = if ($null -ne $status -and $null -ne $status.loginEvidence) { [string]$status.loginEvidence.evidenceType } else { '检测异常' }
        Add-PMSqliteLoginCheck -Check @{
            resourceId = $ResourceId; attemptId = $AttemptId; state = $finishedState
            evidenceType = $evidenceType; evidenceSummary = $evidence
            checkedAt = (Get-PMNow); errorCode = $errorCode; detectorVersion = $DetectorVersion
            confidence = if ($null -ne $status) { [string]$status.loginConfidence } else { 'unknown' }
            apiProbeStatus = if ($null -ne $status) { [string]$status.loginApiProbeStatus } else { '检测异常' }
        }
    } catch { }
    $nextRetry = if ($finishedState -eq 'failed') { ([DateTimeOffset]::Now.AddSeconds(60)).ToString('o') } else { $null }
    Complete-PMLoginDetectorRecord -RuntimeRoot $RuntimeRoot -ResourceId $ResourceId -AttemptId $AttemptId `
        -State $finishedState -ErrorCode $errorCode -RedactedError $errorMessage -NextRetryAt $nextRetry -ProcessId $PID
}
