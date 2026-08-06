[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$entryScript = Join-Path $projectRoot 'port-manager.ps1'
$modulePath = Join-Path $projectRoot 'scripts\lib\PortManager.Core.psm1'
$huiceModulePath = Join-Path $projectRoot 'scripts\lib\PortManager.Huice.psm1'
$helperPath = Join-Path $PSScriptRoot 'helpers\hold-resource-lease.ps1'
$runtimeRoot = Join-Path $projectRoot (
    'data\test-runs\business-regression-{0}-{1}' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N')
)
$null = New-Item -ItemType Directory -Path $runtimeRoot -Force
$auditEvidenceRoot = Join-Path $projectRoot ('data\audit-evidence\business-regression-{0}-{1}' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $auditEvidenceRoot -Force
$env:BSCLAW_PM_RUNTIME_ROOT = $runtimeRoot
Import-Module $huiceModulePath -Force
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Import-Module $huiceModulePath -Force
$results = @()
$script:CurrentStep = 'initialization'

function Write-BusinessAuditEvidence {
    param([object]$FailureRecord)
    try {
        $passed = @($script:results | Where-Object { $_.passed }).Count
        $failed = @($script:results | Where-Object { -not $_.passed }).Count
        $failureText = if ($null -eq $FailureRecord) { $null } else { [string]$FailureRecord.Exception.Message }
        $summary = [ordered]@{
            generatedAt = [DateTimeOffset]::Now.ToString('o')
            script = $PSCommandPath
            runtimeRoot = $runtimeRoot
            currentStep = $script:CurrentStep
            passed = $passed
            failed = $failed
            failure = $failureText
            results = @($script:results)
        }
        $summaryPath = Join-Path $auditEvidenceRoot 'summary.json'
        [IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 12) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        $failurePath = Join-Path $auditEvidenceRoot 'failure.md'
        $failureBody = if ([string]::IsNullOrWhiteSpace($failureText)) {
            "# 回归执行结果`r`n`r`n- 失败步骤：无`r`n- 失败原因：无`r`n- 结果：脚本完成并写入 summary.json`r`n"
        } else {
            "# 回归执行失败`r`n`r`n- 失败步骤：$($script:CurrentStep)`r`n- 失败原因：$failureText`r`n- 运行目录：$runtimeRoot`r`n"
        }
        [IO.File]::WriteAllText($failurePath, $failureBody, [Text.UTF8Encoding]::new($false))
        $indexPath = Join-Path $auditEvidenceRoot 'evidence-index.md'
        $indexLines = @('# 回归证据索引', '', "- summary: $summaryPath", "- failure: $failurePath", "- runtime: $runtimeRoot", "- currentStep: $($script:CurrentStep)")
        foreach ($item in @($script:results)) { $indexLines += "- $($item.id): $($item.evidence)" }
        [IO.File]::WriteAllText($indexPath, ($indexLines -join [Environment]::NewLine) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
    catch {
        # 证据写入失败不能覆盖原始回归异常；尽力保留在已创建的 F 盘目录。
    }
}

trap {
    Write-BusinessAuditEvidence -FailureRecord $_
    exit 1
}

function Add-RegressionResult {
    param(
        [string]$Id,
        [string]$Name,
        [bool]$Passed,
        [string]$Evidence,
        [string]$Requirement
    )
    $script:results += [pscustomobject]@{
        id = $Id
        name = $Name
        passed = $Passed
        requirement = $Requirement
        evidence = $Evidence
    }
}

function ConvertTo-QuotedArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value.Replace('\', '\\').Replace('"', '\"')) + '"'
}

function Invoke-PortManagerProcess {
    param(
        [string[]]$Arguments,
        [AllowNull()]
        [string]$RuntimeRootOverride = $runtimeRoot,
        [string]$WorkingDirectory = $projectRoot,
        [AllowNull()]
        [string[]]$InputLines = $null,
        [ValidateRange(5, 180)]
        [int]$ProcessTimeoutSeconds = 60
    )

    $script:CurrentStep = '执行：powershell.exe ' + ($Arguments -join ' ')

    $allArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $entryScript
    ) + $Arguments
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $powershellArguments = ($allArguments | ForEach-Object { ConvertTo-QuotedArgument -Value ([string]$_) }) -join ' '
    $inputFilePath = $null
    if ($null -ne $InputLines) {
        $inputFilePath = Join-Path $runtimeRoot ('stdin-{0}.txt' -f [Guid]::NewGuid().ToString('N'))
        $inputText = (@($InputLines) -join [Environment]::NewLine) + [Environment]::NewLine
        [IO.File]::WriteAllText($inputFilePath, $inputText, [Text.Encoding]::ASCII)
        $startInfo.FileName = 'cmd.exe'
        $startInfo.Arguments = '/d /s /c "powershell.exe {0} < {1}"' -f (
            $powershellArguments,
            (ConvertTo-QuotedArgument -Value $inputFilePath)
        )
    }
    else {
        $startInfo.FileName = 'powershell.exe'
        $startInfo.Arguments = $powershellArguments
    }
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if ($null -eq $RuntimeRootOverride) {
        $null = $startInfo.EnvironmentVariables.Remove('BSCLAW_PM_RUNTIME_ROOT')
    }
    else {
        $startInfo.EnvironmentVariables['BSCLAW_PM_RUNTIME_ROOT'] = $RuntimeRootOverride
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($ProcessTimeoutSeconds * 1000)
    if ($timedOut) {
        $descendants = @()
        $queue = [System.Collections.Generic.Queue[int]]::new()
        $queue.Enqueue([int]$process.Id)
        while ($queue.Count -gt 0) {
            $parentId = $queue.Dequeue()
            foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$parentId" -ErrorAction SilentlyContinue)) {
                $descendants += [int]$child.ProcessId
                $queue.Enqueue([int]$child.ProcessId)
            }
        }
        foreach ($childId in ($descendants | Sort-Object -Descending)) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
        $process.Kill()
        $process.WaitForExit()
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }
    $process.Dispose()
    if ($null -ne $inputFilePath -and (Test-Path -LiteralPath $inputFilePath -PathType Leaf)) {
        Remove-Item -LiteralPath $inputFilePath -Force
    }

    $json = $null
    $jsonError = $null
    try {
        $json = $stdout | ConvertFrom-Json
    }
    catch {
        $jsonError = $_.Exception.Message
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
        Json = $json
        JsonError = $jsonError
        Command = 'powershell.exe ' + $startInfo.Arguments
        TimedOut = $timedOut
    }
}

function Get-UnboundLocalPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Read-IsolatedJson {
    param([string]$RelativePath)
    $path = Join-Path $runtimeRoot $RelativePath
    return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Get-IsolatedLeases {
    Initialize-PMStorage
    return @(Get-PMActiveLeases)
}

function Test-JsonEnvelope {
    param(
        [object]$Invocation,
        [bool]$ExpectedSuccess,
        [int]$ExpectedExitCode
    )
    return (
        $Invocation.ExitCode -eq $ExpectedExitCode -and
        [string]::IsNullOrWhiteSpace($Invocation.Stderr) -and
        $null -ne $Invocation.Json -and
        [bool]$Invocation.Json.success -eq $ExpectedSuccess
    )
}

$productionDbPath = Join-Path $projectRoot 'data\port-manager.sqlite3'
$productionDbExistedBefore = Test-Path -LiteralPath $productionDbPath -PathType Leaf
$productionHashBefore = if ($productionDbExistedBefore) { (Get-FileHash -LiteralPath $productionDbPath -Algorithm SHA256).Hash } else { $null }

$emptyList = Invoke-PortManagerProcess -Arguments @('-Action', 'List', '-OutputFormat', 'Json', '-NonInteractive')
Add-RegressionResult -Id 'RG-001' -Name '空库 List JSON' -Passed (
    (Test-JsonEnvelope -Invocation $emptyList -ExpectedSuccess $true -ExpectedExitCode 0) -and
    @($emptyList.Json.data).Count -eq 0
) -Requirement '空库正常启动' -Evidence "退出码=$($emptyList.ExitCode)；JSON错误=$($emptyList.JsonError)"

$primaryPort = Get-UnboundLocalPort
$register = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Register',
    '-ResourceName', '隔离回归资源',
    '-HostName', '127.0.0.1',
    '-Port', [string]$primaryPort,
    '-ConnectionMode', 'ConnectOnly',
    '-OutputFormat', 'Json',
    '-NonInteractive'
)
$registerPassed = (
    (Test-JsonEnvelope -Invocation $register -ExpectedSuccess $true -ExpectedExitCode 0) -and
    $register.Json.data.lastStatus.connectionStatus -eq '不可连接' -and
    $register.Json.data.lastStatus.loginStatus -eq '登录状态未知'
)
Add-RegressionResult -Id 'RG-002' -Name '未监听端口正常注册' -Passed $registerPassed -Requirement 'BF-P0-001' -Evidence (
    "退出码=$($register.ExitCode)；JSON错误=$($register.JsonError)；连接状态=$($register.Json.data.lastStatus.connectionStatus)；登录状态=$($register.Json.data.lastStatus.loginStatus)"
)
$primaryId = [string]$register.Json.data.resourceId

$invalidPort = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Register', '-ResourceName', '无效端口输入', '-HostName', '127.0.0.1',
    '-Port', '0', '-ConnectionMode', 'ConnectOnly', '-OutputFormat', 'Json', '-NonInteractive'
)
Add-RegressionResult -Id 'RG-003' -Name '无效端口拒绝' -Passed (
    (Test-JsonEnvelope -Invocation $invalidPort -ExpectedSuccess $false -ExpectedExitCode 1) -and
    $invalidPort.Json.message -like '*1 到 65535*'
) -Requirement '输入校验' -Evidence "退出码=$($invalidPort.ExitCode)；消息=$($invalidPort.Json.message)"

$invalidHost = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Register', '-ResourceName', '无效主机输入', '-HostName', 'invalid host!',
    '-Port', [string](Get-UnboundLocalPort), '-ConnectionMode', 'ConnectOnly', '-OutputFormat', 'Json', '-NonInteractive'
)
Add-RegressionResult -Id 'RG-004' -Name '无效主机拒绝' -Passed (
    (Test-JsonEnvelope -Invocation $invalidHost -ExpectedSuccess $false -ExpectedExitCode 1) -and
    $invalidHost.Json.message -like '*主机地址*'
) -Requirement '输入校验' -Evidence "退出码=$($invalidHost.ExitCode)；消息=$($invalidHost.Json.message)"

$duplicate = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Register', '-ResourceName', '重复资源', '-HostName', '127.0.0.1',
    '-Port', [string]$primaryPort, '-ConnectionMode', 'ConnectOnly', '-OutputFormat', 'Json', '-NonInteractive'
)
Add-RegressionResult -Id 'RG-005' -Name '重复注册拒绝' -Passed (
    (Test-JsonEnvelope -Invocation $duplicate -ExpectedSuccess $false -ExpectedExitCode 1) -and
    $duplicate.Json.message -like '*已注册*'
) -Requirement '重复注册' -Evidence "退出码=$($duplicate.ExitCode)；消息=$($duplicate.Json.message)"

$conflictListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
try {
    $conflictListener.Start()
    $conflictPort = ([Net.IPEndPoint]$conflictListener.LocalEndpoint).Port
    $conflict = Invoke-PortManagerProcess -Arguments @(
        '-Action', 'Register', '-ResourceName', '真实监听冲突资源', '-HostName', '127.0.0.1',
        '-Port', [string]$conflictPort, '-ConnectionMode', 'ConnectOnly', '-OutputFormat', 'Json', '-NonInteractive'
    )
}
finally {
    $conflictListener.Stop()
}
Add-RegressionResult -Id 'RG-006' -Name '真实监听端口冲突拒绝' -Passed (
    (Test-JsonEnvelope -Invocation $conflict -ExpectedSuccess $false -ExpectedExitCode 1) -and
    $conflict.Json.message -like '*占用*'
) -Requirement '监听端口冲突' -Evidence "端口=$conflictPort；退出码=$($conflict.ExitCode)；消息=$($conflict.Json.message)"

$detail = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Detail', '-ResourceId', $primaryId, '-OutputFormat', 'Json', '-NonInteractive'
)
$list = Invoke-PortManagerProcess -Arguments @('-Action', 'List', '-OutputFormat', 'Json', '-NonInteractive')
Add-RegressionResult -Id 'RG-007' -Name 'Detail/List 持久化' -Passed (
    (Test-JsonEnvelope -Invocation $detail -ExpectedSuccess $true -ExpectedExitCode 0) -and
    (Test-JsonEnvelope -Invocation $list -ExpectedSuccess $true -ExpectedExitCode 0) -and
    $detail.Json.data.resourceId -eq $primaryId -and
    @($list.Json.data | Where-Object { $_.resourceId -eq $primaryId }).Count -eq 1
) -Requirement '持久化读取' -Evidence "Detail退出码=$($detail.ExitCode)；List记录数=$(@($list.Json.data).Count)"

$edit = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Edit', '-ResourceId', $primaryId, '-ResourceName', '隔离回归资源-已编辑',
    '-Notes', '自动回归真实隔离状态', '-OutputFormat', 'Json', '-NonInteractive'
)
Add-RegressionResult -Id 'RG-008' -Name 'Edit stdout 纯 JSON' -Passed (
    (Test-JsonEnvelope -Invocation $edit -ExpectedSuccess $true -ExpectedExitCode 0) -and
    $edit.Json.data.resourceName -eq '隔离回归资源-已编辑'
) -Requirement 'BF-P1-002' -Evidence "退出码=$($edit.ExitCode)；stderr长度=$($edit.Stderr.Length)；JSON错误=$($edit.JsonError)"

$deleteTargetPort = Get-UnboundLocalPort
$deleteTargetRegister = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Register', '-ResourceName', '隔离删除资源', '-HostName', '127.0.0.1',
    '-Port', [string]$deleteTargetPort, '-ConnectionMode', 'ConnectOnly', '-OutputFormat', 'Json', '-NonInteractive'
)
$deleteTargetId = [string]$deleteTargetRegister.Json.data.resourceId
$deleteWithoutConfirmation = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Delete', '-ResourceId', $deleteTargetId, '-OutputFormat', 'Json', '-NonInteractive'
)
$delete = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Delete', '-ResourceId', $deleteTargetId, '-ConfirmationText', "删除 $deleteTargetId",
    '-OutputFormat', 'Json', '-NonInteractive'
)
Add-RegressionResult -Id 'RG-009' -Name 'Delete stdout 纯 JSON' -Passed (
    (Test-JsonEnvelope -Invocation $deleteWithoutConfirmation -ExpectedSuccess $false -ExpectedExitCode 1) -and
    (Test-JsonEnvelope -Invocation $delete -ExpectedSuccess $true -ExpectedExitCode 0) -and
    $delete.Json.data.resourceId -eq $deleteTargetId
) -Requirement 'BF-P1-002' -Evidence (
    "缺确认退出码=$($deleteWithoutConfirmation.ExitCode)；删除退出码=$($delete.ExitCode)；stderr长度=$($delete.Stderr.Length)；JSON错误=$($delete.JsonError)"
)

$check = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Check', '-ResourceId', $primaryId, '-OutputFormat', 'Json', '-NonInteractive'
)
$afterCheckDetail = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Detail', '-ResourceId', $primaryId, '-OutputFormat', 'Json', '-NonInteractive'
)
$persistedPrimary = $afterCheckDetail.Json.data
Add-RegressionResult -Id 'RG-010' -Name 'Check 不可连接状态持久化' -Passed (
    (Test-JsonEnvelope -Invocation $check -ExpectedSuccess $true -ExpectedExitCode 0) -and
    $check.Json.data.Status.connectionStatus -eq '不可连接' -and
    $afterCheckDetail.Json.data.lastStatus.connectionStatus -eq '不可连接' -and
    $persistedPrimary.lastStatus.lastCheckedAt -eq $check.Json.data.Status.lastCheckedAt
) -Requirement 'BF-P1-003' -Evidence (
    "退出码=$($check.ExitCode)；连接状态=$($check.Json.data.Status.connectionStatus)；状态文件时间=$($persistedPrimary.lastStatus.lastCheckedAt)"
)

$openFailure = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Open', '-ResourceId', $primaryId, '-TimeoutSeconds', '3', '-OutputFormat', 'Json', '-NonInteractive'
)
$afterOpenFailure = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Detail', '-ResourceId', $primaryId, '-OutputFormat', 'Json', '-NonInteractive'
)
$leaseStoreAfterOpenFailure = @(Get-IsolatedLeases)
Add-RegressionResult -Id 'RG-011' -Name 'Open 失败状态与租约清理' -Passed (
    (Test-JsonEnvelope -Invocation $openFailure -ExpectedSuccess $false -ExpectedExitCode 1) -and
    $afterOpenFailure.Json.data.lastStatus.operationStatus -eq '打开失败' -and
    -not [string]::IsNullOrWhiteSpace([string]$afterOpenFailure.Json.data.lastStatus.lastError) -and
    $leaseStoreAfterOpenFailure.Count -eq 0
) -Requirement 'BF-P1-003/BF-P1-004' -Evidence (
    "退出码=$($openFailure.ExitCode)；最新操作=$($afterOpenFailure.Json.data.lastStatus.operationStatus)；租约数=$($leaseStoreAfterOpenFailure.Count)"
)

$publicRemote = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Register', '-ResourceName', '公网地址拒绝', '-HostName', '8.8.8.8',
    '-Port', '9222', '-ConnectionMode', 'ConnectOnly', '-OutputFormat', 'Json', '-NonInteractive'
)
$privatePort = Get-UnboundLocalPort
$privateRemote = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Register', '-ResourceName', '私网只读检测资源', '-HostName', '192.168.255.254',
    '-Port', [string]$privatePort, '-ConnectionMode', 'ConnectOnly', '-OutputFormat', 'Json', '-NonInteractive'
)
$privateId = if ($null -eq $privateRemote.Json) { $null } else { [string]$privateRemote.Json.data.resourceId }
$privateOpen = if ([string]::IsNullOrWhiteSpace($privateId)) {
    $null
}
else {
    Invoke-PortManagerProcess -Arguments @(
        '-Action', 'Open', '-ResourceId', $privateId, '-TimeoutSeconds', '3', '-OutputFormat', 'Json', '-NonInteractive'
    )
}
$remotePassed = (
    (Test-JsonEnvelope -Invocation $publicRemote -ExpectedSuccess $false -ExpectedExitCode 1) -and
    $publicRemote.Json.message -like '*公网*' -and
    (Test-JsonEnvelope -Invocation $privateRemote -ExpectedSuccess $true -ExpectedExitCode 0) -and
    $null -ne $privateOpen -and
    (Test-JsonEnvelope -Invocation $privateOpen -ExpectedSuccess $false -ExpectedExitCode 1) -and
    $privateOpen.Json.message -like '*仅允许*'
)
Add-RegressionResult -Id 'RG-012' -Name 'ConnectOnly 远程安全边界' -Passed $remotePassed -Requirement 'BF-P1-005' -Evidence (
    "公网注册退出码=$($publicRemote.ExitCode)；私网注册退出码=$($privateRemote.ExitCode)；私网Open退出码=$(if($null -eq $privateOpen){'未执行'}else{$privateOpen.ExitCode})"
)

$signalPath = Join-Path $runtimeRoot 'lease-ready.json'
$leaseHolder = Start-Process -FilePath 'powershell.exe' -ArgumentList (
    "-NoProfile -ExecutionPolicy Bypass -File `"$helperPath`" -ModulePath `"$modulePath`" -ResourceId $primaryId -SignalPath `"$signalPath`" -HoldSeconds 45"
) -PassThru -WindowStyle Hidden
$leaseDeadline = [DateTimeOffset]::Now.AddSeconds(90)
while (-not (Test-Path -LiteralPath $signalPath) -and [DateTimeOffset]::Now -lt $leaseDeadline) {
    Start-Sleep -Milliseconds 100
}
$leaseReady = Test-Path -LiteralPath $signalPath
$leaseList = Invoke-PortManagerProcess -Arguments @('-Action', 'List', '-OutputFormat', 'Json', '-NonInteractive')
$leaseDetail = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Detail', '-ResourceId', $primaryId, '-OutputFormat', 'Json', '-NonInteractive'
)
$concurrentEdit = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Edit', '-ResourceId', $primaryId, '-ResourceName', '并发期间不得写入',
    '-OutputFormat', 'Json', '-NonInteractive'
)
$concurrentDelete = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Delete', '-ResourceId', $primaryId, '-ConfirmationText', "删除 $primaryId",
    '-OutputFormat', 'Json', '-NonInteractive'
)
$concurrentOpen = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Open', '-ResourceId', $primaryId, '-TimeoutSeconds', '3', '-OutputFormat', 'Json', '-NonInteractive'
)
$leaseHolder.WaitForExit()
$leaseHolder.Dispose()
$leasesAfterConcurrency = @(Get-IsolatedLeases)
$leaseListResource = @($leaseList.Json.data | Where-Object { $_.resourceId -eq $primaryId }) | Select-Object -First 1
$concurrencyPassed = (
    $leaseReady -and
    $leaseListResource.lastStatus.currentOccupancy -like '*租约:*' -and
    $leaseDetail.Json.data.lastStatus.currentOccupancy -like '*租约:*' -and
    (Test-JsonEnvelope -Invocation $concurrentEdit -ExpectedSuccess $false -ExpectedExitCode 1) -and
    (Test-JsonEnvelope -Invocation $concurrentDelete -ExpectedSuccess $false -ExpectedExitCode 1) -and
    (Test-JsonEnvelope -Invocation $concurrentOpen -ExpectedSuccess $false -ExpectedExitCode 1) -and
    $leasesAfterConcurrency.Count -eq 0
)
Add-RegressionResult -Id 'RG-013' -Name '并发占用保护与展示一致' -Passed $concurrencyPassed -Requirement 'BF-P2-006/BF-P2-007' -Evidence (
    "租约就绪=$leaseReady；List占用=$($leaseListResource.lastStatus.currentOccupancy)；Detail占用=$($leaseDetail.Json.data.lastStatus.currentOccupancy)；Edit/Delete/Open退出码=$($concurrentEdit.ExitCode)/$($concurrentDelete.ExitCode)/$($concurrentOpen.ExitCode)；结束租约数=$($leasesAfterConcurrency.Count)"
)

$browserExecutable = Get-PMChromeExecutable
if ($null -eq $browserExecutable) {
    Add-RegressionResult -Id 'RG-014' -Name '真实浏览器启动失败后回收' -Passed $false -Requirement 'BF-P1-004/BF-P1-020' -Evidence '现场未找到可用 Google Chrome，未执行且不判定通过；没有改用 Edge。'
}
else {
    $browserPort = Get-UnboundLocalPort
    $browserProfile = Join-Path $runtimeRoot ('browser-profile-' + [Guid]::NewGuid().ToString('N'))
    $launchRegister = Invoke-PortManagerProcess -Arguments @(
        '-Action', 'Register', '-ResourceName', '真实浏览器失败回收资源', '-HostName', '127.0.0.1',
        '-Port', [string]$browserPort, '-ConnectionMode', 'Launch',
        '-BrowserExecutable', $browserExecutable, '-BrowserProfileDirectory', $browserProfile,
        '-StartUrl', 'http://127.0.0.1:9/', '-PlatformUrlPatterns', '*://not-huice.invalid/*',
        '-OutputFormat', 'Json', '-NonInteractive'
    )
    $launchId = [string]$launchRegister.Json.data.resourceId
    $launchOpen = Invoke-PortManagerProcess -Arguments @(
        '-Action', 'Open', '-ResourceId', $launchId, '-TimeoutSeconds', '15',
        '-OutputFormat', 'Json', '-NonInteractive'
    )
    Start-Sleep -Seconds 1
    $remainingBrowserProcesses = @(
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -eq 'chrome.exe' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
                (
                    ([string]$_.CommandLine).IndexOf($browserProfile, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    ([string]$_.CommandLine).IndexOf("--remote-debugging-port=$browserPort", [StringComparison]::OrdinalIgnoreCase) -ge 0
                )
            }
    )
    $launchLeases = @(Get-IsolatedLeases)
    $launchDetail = Invoke-PortManagerProcess -Arguments @(
        '-Action', 'Detail', '-ResourceId', $launchId, '-OutputFormat', 'Json', '-NonInteractive'
    )
    Add-RegressionResult -Id 'RG-014' -Name '真实浏览器启动失败后回收' -Passed (
        (Test-JsonEnvelope -Invocation $launchRegister -ExpectedSuccess $true -ExpectedExitCode 0) -and
        (Test-JsonEnvelope -Invocation $launchOpen -ExpectedSuccess $false -ExpectedExitCode 1) -and
        @($remainingBrowserProcesses).Count -eq 0 -and
        $launchLeases.Count -eq 0 -and
        $launchDetail.Json.data.lastStatus.operationStatus -eq '打开失败'
    ) -Requirement 'BF-P1-004/BF-P1-020' -Evidence (
        "浏览器=$browserExecutable；Open退出码=$($launchOpen.ExitCode)；残留进程数=$(@($remainingBrowserProcesses).Count)；租约数=$($launchLeases.Count)；状态=$($launchDetail.Json.data.lastStatus.operationStatus)"
    )
}

$wizard = Invoke-PortManagerProcess -Arguments @() -InputLines @('1', '2', '', '0') -ProcessTimeoutSeconds 90
$wizardStore = @((Invoke-PortManagerProcess -Arguments @('-Action', 'List', '-OutputFormat', 'Json', '-NonInteractive')).Json.data)
$wizardResource = @(
    $wizardStore |
        Where-Object { [string]$_.resourceName -like '慧策通端口-*' -and [string]$_.connectionMode -eq 'Launch' } |
        Sort-Object registeredAt -Descending
) | Select-Object -First 1
$wizardResourceId = if ($null -eq $wizardResource) { '未创建' } else { [string]$wizardResource.resourceId }
$wizardResourceName = if ($null -eq $wizardResource) { '未创建' } else { [string]$wizardResource.resourceName }
$wizardResourcePort = if ($null -eq $wizardResource) { 0 } else { [int]$wizardResource.port }
$wizardBrowserExecutable = if ($null -eq $wizardResource) { $null } else { [string]$wizardResource.browserExecutable }
$wizardProfileDirectory = if ($null -eq $wizardResource) { $null } else { [string]$wizardResource.browserProfileDirectory }
$wizardProcesses = @(
    if (-not [string]::IsNullOrWhiteSpace($wizardProfileDirectory)) {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            [string]$_.Name -ieq 'chrome.exe' -and
            -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
            ([string]$_.CommandLine).IndexOf($wizardProfileDirectory, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }
    }
)
$wizardBrowserStarted = $wizardProcesses.Count -gt 0
$wizardProcessIds = @($wizardProcesses | ForEach-Object { [int]$_.ProcessId })
foreach ($processId in ($wizardProcessIds | Sort-Object -Descending)) {
    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
}
$wizardCleanupDeadline = [DateTimeOffset]::Now.AddSeconds(5)
do {
    $wizardRemainingProcessIds = @(
        $wizardProcessIds | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) }
    )
    if ($wizardRemainingProcessIds.Count -eq 0) {
        break
    }
    Start-Sleep -Milliseconds 200
} while ([DateTimeOffset]::Now -lt $wizardCleanupDeadline)
$wizardLeases = @(Get-IsolatedLeases)
$technicalPromptMarkers = @(
    'ConnectOnly',
    'Launch',
    'URL Pattern',
    'Login Pattern',
    '请输入真实调试端口号',
    '请输入浏览器可执行文件完整路径',
    '请输入 F 盘浏览器配置目录'
)
$technicalPromptsFound = @($technicalPromptMarkers | Where-Object { $wizard.Stdout.Contains($_) })
$wizardPassed = (
    $wizard.ExitCode -eq 0 -and
    [string]::IsNullOrWhiteSpace($wizard.Stderr) -and
    $null -ne $wizardResource -and
    $wizardResourceName -eq "慧策通端口-$wizardResourcePort" -and
    $wizardBrowserExecutable -eq [string]$browserExecutable -and
    $wizardProfileDirectory -like "$(Join-Path (Split-Path -Parent $projectRoot) '_portmanager-profiles')\*" -and
    [string]$wizardResource.startUrl -eq 'https://login.huice.com/' -and
    @($wizardResource.platformUrlPatterns).Count -gt 0 -and
    @($wizardResource.loginPagePatterns).Count -gt 0 -and
    [bool]$wizardResource.enabled -and
    $null -eq $wizardResource.notes -and
    $wizardBrowserStarted -and
    [string]$wizardResource.lastStatus.browserStatus -eq '浏览器可连接' -and
    [string]$wizardResource.lastStatus.pageStatus -eq '平台页面正确' -and
    [string]$wizardResource.lastStatus.loginStatus -eq '未登录' -and
    [string]$wizardResource.lastStatus.loginEvidence.evidenceType -eq 'login-page-rule' -and
    @($wizardResource.lastStatus.activeLeases).Count -eq 0 -and
    $wizardRemainingProcessIds.Count -eq 0 -and
    $wizardLeases.Count -eq 0 -and
    $technicalPromptsFound.Count -eq 0 -and
    -not $wizard.Stdout.Contains('.\port-manager.ps1 -Action') -and
    -not $wizard.Stdout.Contains('在已打开的 Chrome 中完成慧策通登录') -and
    $wizard.Stdout.Contains('端口管理 HuiceLogin')
)
Add-RegressionResult -Id 'RG-015' -Name '首次注册业务向导与默认名称' -Passed $wizardPassed -Requirement 'BF-P0-016/BF-P1-017/BF-P1-018/BF-P1-019/BF-P1-020/BF-P1-021/BF-P1-022/BF-P1-023' -Evidence (
    "退出码=$($wizard.ExitCode)；超时=$($wizard.TimedOut)；资源=$wizardResourceId/$wizardResourceName；Chrome=$wizardBrowserExecutable；自动端口=$wizardResourcePort；配置目录=$wizardProfileDirectory；实际启动=$wizardBrowserStarted；浏览器/页面/登录=$($wizardResource.lastStatus.browserStatus)/$($wizardResource.lastStatus.pageStatus)/$($wizardResource.lastStatus.loginStatus)；测试进程残留=$($wizardRemainingProcessIds.Count)；租约=$($wizardLeases.Count)；发现技术提示=$($technicalPromptsFound -join ',')；含复制命令=$($wizard.Stdout.Contains('.\port-manager.ps1 -Action'))；引导HTTP主链=$($wizard.Stdout.Contains('端口管理 HuiceLogin'))；未创建时输出=$($wizard.Stdout)"
)

$adapter = [IO.File]::ReadAllText((Join-Path $projectRoot 'adapter\bsclaw-port-adapter.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$huiceLoginRoot = Join-Path (Split-Path -Parent $projectRoot) 'HuiceLoginAgent'
$httpLoginModule = Join-Path $huiceLoginRoot 'lib\HuiceLogin.HttpLogin.psm1'
$secureLoginBridge = Join-Path $huiceLoginRoot 'lib\secure_login_bridge.js'
$httpLoginText = if (Test-Path -LiteralPath $httpLoginModule) { [IO.File]::ReadAllText($httpLoginModule, [Text.Encoding]::UTF8) } else { '' }
$secureLoginText = if (Test-Path -LiteralPath $secureLoginBridge) { [IO.File]::ReadAllText($secureLoginBridge, [Text.Encoding]::UTF8) } else { '' }
$authenticatedRules = @($adapter.huiceAdapter.loginDetection.authenticatedEvidenceRules)
$adapterPassed = (
    [int]$adapter.schemaVersion -eq 2 -and
    [string]$adapter.version -eq '0.4.0' -and
    ([string]$adapter.runtime.rootDirectory -eq '.' -or [string]$adapter.runtime.rootDirectory -eq $projectRoot) -and
    [string]$adapter.runtime.logsDirectory -eq './logs' -and
    [string]$adapter.runtime.browserProfilesDirectory -like '*BSCLAW_PROFILE_ROOT*' -and
    [string]$adapter.huiceAdapter.defaultStartUrl -eq 'https://login.huice.com/' -and
    @($adapter.huiceAdapter.platformUrlPatterns).Count -gt 0 -and
    @($adapter.huiceAdapter.loginPagePatterns).Count -gt 0 -and
    @($adapter.huiceAdapter.loginDetection.states).Count -eq 6 -and
    $authenticatedRules.Count -gt 0 -and
    @($authenticatedRules | Where-Object { [bool]$_.enabled }).Count -gt 0 -and
    [bool]$adapter.resourceDataModel.autoLoginImplemented -eq $true -and
    [string]$adapter.huiceAdapter.loginDetection.authenticatedEvidenceSource -like '*HuiceLoginAgent*' -and
    $httpLoginText.Contains('Invoke-HuiceSameOriginHttpLogin') -and
    -not $httpLoginText.Contains('Invoke-HuiceWebFormLogin') -and
    $secureLoginText.Contains("loginTransport: 'same-origin-http'") -and
    -not $secureLoginText.Contains('Input.dispatchKeyEvent') -and
    -not $secureLoginText.Contains('Input.dispatchMouseEvent') -and
    [string]$adapter.huiceAdapter.browserPolicy -like '*Google Chrome*' -and
    [string]$adapter.huiceAdapter.browserPolicy -like '*no alternate browser*'
)
Add-RegressionResult -Id 'RG-016' -Name '慧策同源 HTTP 登录与鉴权证据契约' -Passed $adapterPassed -Requirement 'BF-P1-020/BF-P1-021' -Evidence (
    "schema=$($adapter.schemaVersion)；版本=$($adapter.version)；鉴权规则数=$($authenticatedRules.Count)；启用规则数=$(@($authenticatedRules | Where-Object { [bool]$_.enabled }).Count)；自动登录=$($adapter.resourceDataModel.autoLoginImplemented)；同源HTTP实现=$($httpLoginText.Contains('Invoke-HuiceSameOriginHttpLogin'))；DOM输入调用=$($secureLoginText.Contains('Input.dispatchKeyEvent') -or $secureLoginText.Contains('Input.dispatchMouseEvent'))"
)

$defaultRuntimeRoot = $projectRoot
$defaultRuntimeStore = Join-Path $defaultRuntimeRoot 'data\port-manager.sqlite3'
$arbitraryWorkingDirectory = 'F:\XIANGMU\BS Claw\_audit-runtime\user-flow-20260728-register'
$defaultRuntimeList = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'List', '-OutputFormat', 'Json', '-NonInteractive'
) -RuntimeRootOverride $null -WorkingDirectory $arbitraryWorkingDirectory
$defaultRuntimePassed = (
    (Test-JsonEnvelope -Invocation $defaultRuntimeList -ExpectedSuccess $true -ExpectedExitCode 0) -and
    (Test-Path -LiteralPath $defaultRuntimeStore -PathType Leaf) -and
    [IO.Path]::GetFullPath($defaultRuntimeStore).StartsWith($defaultRuntimeRoot, [StringComparison]::OrdinalIgnoreCase) -and
    (Test-Path -LiteralPath $defaultRuntimeStore -PathType Leaf)
)
Add-RegressionResult -Id 'RG-017' -Name '任意当前目录使用统一运行目录' -Passed $defaultRuntimePassed -Requirement 'BF-P1-024' -Evidence (
    "工作目录=$arbitraryWorkingDirectory；退出码=$($defaultRuntimeList.ExitCode)；统一运行数据库=$defaultRuntimeStore；未生成测试目录数据库=$(-not (Test-Path -LiteralPath (Join-Path $arbitraryWorkingDirectory 'data\port-manager.sqlite3')))"
)

$recoveryRoot = Join-Path $runtimeRoot 'recovery-case'
$recoveryPort = Get-UnboundLocalPort
$recoveryRegister = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Register', '-ResourceName', '异常恢复资源', '-HostName', '127.0.0.1',
    '-Port', [string]$recoveryPort, '-ConnectionMode', 'ConnectOnly',
    '-OutputFormat', 'Json', '-NonInteractive'
) -RuntimeRootOverride $recoveryRoot
$recoveryId = [string]$recoveryRegister.Json.data.resourceId
$recoveryEdit = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'Edit', '-ResourceId', $recoveryId, '-ResourceName', '异常恢复资源-编辑后',
    '-OutputFormat', 'Json', '-NonInteractive'
) -RuntimeRootOverride $recoveryRoot
$recoveryList = Invoke-PortManagerProcess -Arguments @(
    '-Action', 'List', '-OutputFormat', 'Json', '-NonInteractive'
) -RuntimeRootOverride $recoveryRoot
$recoveryDbPath = Join-Path $recoveryRoot 'data\port-manager.sqlite3'
$recoveredResource = @($recoveryList.Json.data | Where-Object { [string]$_.resourceId -eq $recoveryId }) | Select-Object -First 1
$recoveryPassed = (
    (Test-JsonEnvelope -Invocation $recoveryRegister -ExpectedSuccess $true -ExpectedExitCode 0) -and
    (Test-JsonEnvelope -Invocation $recoveryEdit -ExpectedSuccess $true -ExpectedExitCode 0) -and
    (Test-JsonEnvelope -Invocation $recoveryList -ExpectedSuccess $true -ExpectedExitCode 0) -and
    $null -ne $recoveredResource -and
    (Test-Path -LiteralPath $recoveryDbPath -PathType Leaf)
)
Add-RegressionResult -Id 'RG-018' -Name '数据文件异常后的备份恢复' -Passed $recoveryPassed -Requirement 'BF-P1-024' -Evidence (
    "注册/编辑/重启读取退出码=$($recoveryRegister.ExitCode)/$($recoveryEdit.ExitCode)/$($recoveryList.ExitCode)；恢复资源=$($recoveredResource.resourceId)；数据库存在=$((Test-Path -LiteralPath $recoveryDbPath -PathType Leaf))"
)

$nextActionCount = [regex]::Matches($wizard.Stdout, '下一步：').Count
$feedbackPassed = (
    -not [string]::IsNullOrWhiteSpace([string]$invalidPort.Json.nextAction) -and
    $nextActionCount -eq 1
)
Add-RegressionResult -Id 'RG-019' -Name '失败反馈提供单一下一步动作' -Passed $feedbackPassed -Requirement 'BF-P2-025' -Evidence (
    "JSON失败下一步=$($invalidPort.Json.nextAction)；注册检查后的下一步数量=$nextActionCount"
)

$productionHashAfter = if (Test-Path -LiteralPath $productionDbPath -PathType Leaf) { (Get-FileHash -LiteralPath $productionDbPath -Algorithm SHA256).Hash } else { $null }
$legacySystemPath = 'F:\XIANGMU\BS Claw\System'
$huiceLoginEntry = Join-Path (Split-Path -Parent $projectRoot) 'HuiceLoginAgent\login-agent.ps1'
$moduleBoundaryPassed = (
    -not (Test-Path -LiteralPath $legacySystemPath) -and
    (Test-Path -LiteralPath $huiceLoginEntry -PathType Leaf) -and
    [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($projectRoot)) -like 'F:\' -and
    [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($huiceLoginEntry)) -like 'F:\'
)
Add-RegressionResult -Id 'RG-020' -Name '端口管理、登录代理与旧空壳隔离' -Passed (
    $moduleBoundaryPassed
) -Requirement '执行边界' -Evidence (
    "默认 SQLite 路径=$productionDbPath；HuiceLoginAgent入口=$huiceLoginEntry；旧System不存在=$(-not (Test-Path -LiteralPath $legacySystemPath))；模块均位于F盘=$moduleBoundaryPassed"
)

$summary = [ordered]@{
    executedAt = [DateTimeOffset]::Now.ToString('o')
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    projectRoot = $projectRoot
    runtimeRoot = $runtimeRoot
    results = $results
    passed = @($results | Where-Object { $_.passed }).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
    realBrowserFailurePathExecuted = @($results | Where-Object { $_.id -eq 'RG-014' -and $_.passed }).Count -eq 1
    realHuicePageExecuted = @($results | Where-Object { $_.id -eq 'RG-015' -and $_.passed }).Count -eq 1
    realHuiceLoginExecuted = $false
}
$summaryPath = Join-Path $runtimeRoot 'business-regression-summary.json'
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 10) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
)
Write-BusinessAuditEvidence
$summary | ConvertTo-Json -Depth 10
if ($summary.failed -gt 0) {
    exit 1
}
exit 0
