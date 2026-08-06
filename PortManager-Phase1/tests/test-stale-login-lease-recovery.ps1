[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$entryPath = Join-Path $projectRoot 'port-manager.ps1'
$agentPath = [IO.Path]::GetFullPath((Join-Path $projectRoot '..\HuiceLoginAgent\login-agent.ps1'))
foreach ($requiredPath in @($entryPath, $agentPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "验收入口不存在：$requiredPath"
    }
}

function Invoke-JsonCommand {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $raw = & powershell.exe @Arguments 2>&1
    $text = ($raw -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { throw '验收命令没有返回 JSON。' }
    return $text | ConvertFrom-Json
}

$baseArguments = @('-NoP', '-EP', 'Bypass', '-File')
$beforeCheck = Invoke-JsonCommand -Arguments (
    $baseArguments + @($agentPath, '-Action', 'Check', '-ResourceId', $ResourceId,
        '-OutputFormat', 'Json', '-NonInteractive'))
if ([string]$beforeCheck.data.status -ne 'login-required') {
    throw '本验收只允许从隔离资源 login-required 状态开始。'
}

$beforeOccupancy = Invoke-JsonCommand -Arguments (
    $baseArguments + @($entryPath, '-Action', 'Occupancy', '-ResourceId', $ResourceId,
        '-OutputFormat', 'Json', '-NonInteractive'))
$beforeDetail = Invoke-JsonCommand -Arguments (
    $baseArguments + @($entryPath, '-Action', 'Detail', '-ResourceId', $ResourceId,
        '-OutputFormat', 'Json', '-NonInteractive'))
$chromeBefore = @($beforeOccupancy.data.ownerProcessIds)
$watcherPid = $beforeDetail.data.lastStatus.watcherPid
$watcherAliveBefore = $null -ne $watcherPid -and
    $null -ne (Get-Process -Id ([int]$watcherPid) -ErrorAction SilentlyContinue)

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'powershell.exe'
$startInfo.Arguments = "-NoP -EP Bypass -File `"$agentPath`" -Action Login -ResourceId $ResourceId -OutputFormat Json"
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.CreateNoWindow = $true

$loginProcess = [Diagnostics.Process]::new()
$loginProcess.StartInfo = $startInfo
$loginLease = $null
try {
    if (-not $loginProcess.Start()) { throw '受控 Login 进程启动失败。' }
    $deadline = [DateTimeOffset]::Now.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 300
        $during = Invoke-JsonCommand -Arguments (
            $baseArguments + @($entryPath, '-Action', 'Occupancy', '-ResourceId', $ResourceId,
                '-OutputFormat', 'Json', '-NonInteractive'))
        $loginLease = @($during.data.activeLeases | Where-Object {
                [int]$_.processId -eq $loginProcess.Id -and [string]$_.operation -eq 'Login'
            }) | Select-Object -First 1
    } while ($null -eq $loginLease -and -not $loginProcess.HasExited -and
        [DateTimeOffset]::Now -lt $deadline)

    if ($null -eq $loginLease) { throw '未观察到受控 Login 租约。' }
    $killedProcessId = [int]$loginProcess.Id
    $loginProcess.Kill()
    $loginProcess.WaitForExit()
}
finally {
    if ($null -ne $loginProcess -and -not $loginProcess.HasExited) {
        $loginProcess.Kill()
        $loginProcess.WaitForExit()
    }
}

$ownerAliveAfterKill = $null -ne (
    Get-Process -Id $killedProcessId -ErrorAction SilentlyContinue)
$afterOccupancy = Invoke-JsonCommand -Arguments (
    $baseArguments + @($entryPath, '-Action', 'Occupancy', '-ResourceId', $ResourceId,
        '-OutputFormat', 'Json', '-NonInteractive'))
$afterCheck = Invoke-JsonCommand -Arguments (
    $baseArguments + @($agentPath, '-Action', 'Check', '-ResourceId', $ResourceId,
        '-OutputFormat', 'Json', '-NonInteractive'))
$chromeAfter = @($afterOccupancy.data.ownerProcessIds)
$watcherAliveAfter = $null -ne $watcherPid -and
    $null -ne (Get-Process -Id ([int]$watcherPid) -ErrorAction SilentlyContinue)

$passed = (
    -not $ownerAliveAfterKill -and
    @($afterOccupancy.data.activeLeases).Count -eq 0 -and
    [string]$afterCheck.errorCode -ne 'RESOURCE_BUSY' -and
    [string]$afterCheck.data.status -eq 'login-required' -and
    (@($chromeBefore) -join ',') -eq (@($chromeAfter) -join ',') -and
    (-not $watcherAliveBefore -or $watcherAliveAfter)
)

[ordered]@{
    success = $passed
    resourceId = $ResourceId
    startStatus = [string]$beforeCheck.data.status
    killedLoginProcessId = $killedProcessId
    observedLeaseId = [string]$loginLease.leaseId
    ownerAliveAfterKill = $ownerAliveAfterKill
    activeLeasesAfterRecovery = @($afterOccupancy.data.activeLeases).Count
    checkStatusAfterRecovery = [string]$afterCheck.data.status
    checkErrorCodeAfterRecovery = $afterCheck.errorCode
    chromeProcessIdsBefore = $chromeBefore
    chromeProcessIdsAfter = $chromeAfter
    watcherPid = $watcherPid
    watcherAliveBefore = $watcherAliveBefore
    watcherAliveAfter = $watcherAliveAfter
} | ConvertTo-Json -Depth 6

if (-not $passed) { exit 2 }
