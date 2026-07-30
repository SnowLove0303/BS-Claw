[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pythonPrerequisitePath = Join-Path $PSScriptRoot 'helpers\Require-FDrivePython.ps1'
. $pythonPrerequisitePath
try {
    $env:BSCLAW_PYTHON_PATH = Resolve-BSClawTestPython -ProjectRoot $projectRoot
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
$entryScript = Join-Path $projectRoot 'port-manager.ps1'
$runtimeRoot = Join-Path $projectRoot (
    'data\test-runs\login-state-regression-{0}-{1}' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N')
)
$null = New-Item -ItemType Directory -Path $runtimeRoot -Force
$env:BSCLAW_PM_RUNTIME_ROOT = $runtimeRoot
Import-Module (Join-Path $projectRoot 'scripts\lib\PortManager.Core.psm1') -Force -WarningAction SilentlyContinue

Import-Module (Join-Path $projectRoot 'scripts\lib\PortManager.Huice.psm1') -Force
Import-Module (Join-Path $projectRoot 'scripts\lib\PortManager.Login.psm1') -Force
Import-Module (Join-Path $projectRoot 'scripts\lib\PortManager.Chrome.psm1') -Force
Import-Module (Join-Path $projectRoot 'scripts\lib\PortManager.Persistence.psm1') -Force

$results = @()
$ownedBrowserProcessId = $null
$ownedBrowserStartedAt = $null
$registeredResource = $null
$profileDirectory = $null

function Add-LoginRegressionResult {
    param(
        [string]$Id,
        [string]$Name,
        [bool]$Passed,
        [bool]$Executed,
        [string]$Evidence
    )
    $script:results += [pscustomobject]@{
        id = $Id
        name = $Name
        passed = $Passed
        executed = $Executed
        evidence = $Evidence
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

function Invoke-PortManagerJson {
    param([string[]]$Arguments)
    $output = @(
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entryScript @Arguments
    )
    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine
    $json = $null
    $parseError = $null
    try {
        $json = $text | ConvertFrom-Json
    }
    catch {
        $parseError = $_.Exception.Message
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $text
        Json = $json
        ParseError = $parseError
    }
}

try {
    $chromeExecutable = Get-PMChromeExecutable
    $chromeFound = (
        -not [string]::IsNullOrWhiteSpace([string]$chromeExecutable) -and
        [IO.Path]::GetFileName([string]$chromeExecutable) -ieq 'chrome.exe' -and
        (Test-Path -LiteralPath $chromeExecutable -PathType Leaf)
    )
    Add-LoginRegressionResult -Id 'LS-001' -Name '仅发现 Google Chrome' -Passed $chromeFound -Executed $true -Evidence (
        "Chrome=$chromeExecutable；Edge回退未使用=True"
    )
    if (-not $chromeFound) {
        throw '未找到 Google Chrome，无法执行真实登录页回归。'
    }

    $port = Get-UnboundLocalPort
    $profileDirectory = Join-Path $runtimeRoot "browser-profiles\huice-$port"
    $register = Invoke-PortManagerJson -Arguments @(
        '-Action', 'Register',
        '-ResourceName', '真实慧策登录页回归',
        '-HostName', '127.0.0.1',
        '-Port', [string]$port,
        '-ConnectionMode', 'Launch',
        '-BrowserExecutable', $chromeExecutable,
        '-BrowserProfileDirectory', $profileDirectory,
        '-StartUrl', 'https://login.huice.com/',
        '-OutputFormat', 'Json',
        '-NonInteractive'
    )
    $registeredResource = $register.Json.data
    $registerPassed = (
        $register.ExitCode -eq 0 -and
        $null -ne $register.Json -and
        [bool]$register.Json.success -and
        [string]$registeredResource.platformId -eq 'huice' -and
        $null -eq $registeredResource.credentialRef -and
        [string]$registeredResource.loginAutomationState -eq '未配置凭据' -and
        [bool]$registeredResource.sessionPolicy.autoLoginEnabled -eq $false -and
        [bool]$registeredResource.sessionPolicy.credentialRefRequired -and
        [bool]$registeredResource.sessionPolicy.requireHumanConfirmation -and
        [bool]$registeredResource.sessionPolicy.recheckBeforeUse -and
        [string]$registeredResource.lastStatus.loginStatus -eq '登录状态未知'
    )
    Add-LoginRegressionResult -Id 'LS-002' -Name 'schema v2 注册与自动登录预留字段' -Passed $registerPassed -Executed $true -Evidence (
        "退出码=$($register.ExitCode)；JSON错误=$($register.ParseError)；资源=$($registeredResource.resourceId)；platformId=$($registeredResource.platformId)；credentialRef为空=$($null -eq $registeredResource.credentialRef)；自动登录=$($registeredResource.sessionPolicy.autoLoginEnabled)"
    )

    $ownedBrowserStartedAt = [DateTimeOffset]::Now
    $open = Invoke-PortManagerJson -Arguments @(
        '-Action', 'Open',
        '-ResourceId', [string]$registeredResource.resourceId,
        '-TimeoutSeconds', '30',
        '-OutputFormat', 'Json',
        '-NonInteractive'
    )
    if ($null -ne $open.Json -and $null -ne $open.Json.data) {
        $ownedBrowserProcessId = $open.Json.data.BrowserProcessId
    }
    $openStatus = if ($null -eq $open.Json -or $null -eq $open.Json.data) { $null } else { $open.Json.data.Status }
    $openPassed = (
        $open.ExitCode -eq 0 -and
        $null -ne $openStatus -and
        [string]$openStatus.connectionStatus -eq '浏览器可连接' -and
        [string]$openStatus.browserStatus -eq '浏览器可连接' -and
        [string]$openStatus.pageStatus -eq '平台页面正确' -and
        [string]$openStatus.loginStatus -eq '未登录' -and
        [string]$openStatus.loginEvidence.evidenceType -eq 'login-page-rule' -and
        [string]$openStatus.loginEvidence.confidence -eq 'confirmed' -and
        -not [string]::IsNullOrWhiteSpace([string]$openStatus.loginCheckedAt)
    )
    Add-LoginRegressionResult -Id 'LS-003' -Name '真实慧策登录页判定为未登录' -Passed $openPassed -Executed $true -Evidence (
        "退出码=$($open.ExitCode)；浏览器=$($openStatus.browserStatus)；页面=$($openStatus.pageStatus)；登录=$($openStatus.loginStatus)；证据=$($openStatus.loginEvidence.evidenceType)；时间=$($openStatus.loginCheckedAt)"
    )

    $check = Invoke-PortManagerJson -Arguments @(
        '-Action', 'Check',
        '-ResourceId', [string]$registeredResource.resourceId,
        '-OutputFormat', 'Json',
        '-NonInteractive'
    )
    $checkStatus = if ($null -eq $check.Json -or $null -eq $check.Json.data) { $null } else { $check.Json.data.Status }
    $detail = Invoke-PortManagerJson -Arguments @(
        '-Action', 'Detail',
        '-ResourceId', [string]$registeredResource.resourceId,
        '-OutputFormat', 'Json',
        '-NonInteractive'
    )
    $persistPassed = (
        $check.ExitCode -eq 0 -and
        $detail.ExitCode -eq 0 -and
        [string]$checkStatus.loginStatus -eq '未登录' -and
        [string]$detail.Json.data.lastStatus.loginStatus -eq '未登录' -and
        [string]$detail.Json.data.lastStatus.loginEvidence.evidenceType -eq 'login-page-rule' -and
        [string]$detail.Json.data.lastStatus.loginCheckedAt -eq [string]$checkStatus.loginCheckedAt
    )
    Add-LoginRegressionResult -Id 'LS-004' -Name '重复检测与登录证据持久化回读' -Passed $persistPassed -Executed $true -Evidence (
        "Check退出码=$($check.ExitCode)；Detail退出码=$($detail.ExitCode)；登录=$($detail.Json.data.lastStatus.loginStatus)；证据=$($detail.Json.data.lastStatus.loginEvidence.evidenceType)；时间一致=$([string]$detail.Json.data.lastStatus.loginCheckedAt -eq [string]$checkStatus.loginCheckedAt)"
    )

    $adapter = [IO.File]::ReadAllText(
        (Join-Path $projectRoot 'adapter\bsclaw-port-adapter.json'),
        [Text.Encoding]::UTF8
    ) | ConvertFrom-Json
    $loginAgentRoot = Join-Path (Split-Path -Parent $projectRoot) 'HuiceLoginAgent'
    $httpLoginModuleText = [IO.File]::ReadAllText(
        (Join-Path $loginAgentRoot 'lib\HuiceLogin.HttpLogin.psm1'),
        [Text.Encoding]::UTF8
    )
    $secureBridgeText = [IO.File]::ReadAllText(
        (Join-Path $loginAgentRoot 'lib\secure_login_bridge.js'),
        [Text.Encoding]::UTF8
    )
    $authBoundaryPassed = (
        @($adapter.huiceAdapter.loginDetection.authenticatedEvidenceRules).Count -gt 0 -and
        [bool]$adapter.huiceAdapter.loginDetection.authenticatedEvidenceAvailable -and
        [bool]$adapter.resourceDataModel.autoLoginImplemented -and
        [string]$adapter.resourceDataModel.loginAdapter -eq 'HuiceLoginAgent' -and
        [string]$adapter.resourceDataModel.loginAutomationState -eq 'huice-same-origin-http-login' -and
        [string]$adapter.resourceDataModel.credentialPolicy -like '*credentialRef only*' -and
        $httpLoginModuleText.Contains('function Invoke-HuiceSameOriginHttpLogin') -and
        -not $httpLoginModuleText.Contains('Invoke-HuiceWebFormLogin') -and
        $secureBridgeText.Contains("loginTransport: 'same-origin-http'") -and
        -not $secureBridgeText.Contains('runLegacyFormLogin') -and
        -not $secureBridgeText.Contains('Input.dispatchKeyEvent') -and
        -not $secureBridgeText.Contains('Input.dispatchMouseEvent')
    )
    Add-LoginRegressionResult -Id 'LS-005' -Name '鉴权规则与自动登录适配器契约' -Passed $authBoundaryPassed -Executed $true -Evidence (
        "鉴权规则数=$(@($adapter.huiceAdapter.loginDetection.authenticatedEvidenceRules).Count)；鉴权证据可用=$($adapter.huiceAdapter.loginDetection.authenticatedEvidenceAvailable)；自动登录=$($adapter.resourceDataModel.autoLoginImplemented)；适配器=$($adapter.resourceDataModel.loginAdapter)；loginAutomationState=$($adapter.resourceDataModel.loginAutomationState)；唯一主链=同源HTTP"
    )

    $liveEndpoints = @(Get-PMChromeDebugEndpoints -PlatformUrlPatterns @($adapter.huiceAdapter.platformUrlPatterns))
    $liveHuiceEndpoint = @(
        $liveEndpoints |
            Where-Object { [bool]$_.HasHuicePage -and [int]$_.Port -ne $port } |
            Select-Object -First 1
    )
    if ($liveHuiceEndpoint.Count -eq 0) {
        Add-LoginRegressionResult -Id 'LS-006' -Name '现有慧策 Chrome 实时证据边界' -Passed $true -Executed $false -Evidence (
            '本次没有发现用户已打开的慧策 Chrome；场景保持未验证，不伪造页面。'
        )
    }
    else {
        $liveResource = [pscustomobject]@{
            platformUrlPatterns = @($adapter.huiceAdapter.platformUrlPatterns)
            loginPagePatterns = @($adapter.huiceAdapter.loginPagePatterns)
            lastStatus = [pscustomobject]@{ loginStatus = '未检测' }
        }
        $livePages = @($liveHuiceEndpoint[0].HuicePages)
        $liveResult = Resolve-PMLoginStatus -Resource $liveResource -BrowserConnected $true `
            -PageStatus '平台页面正确' -PageTargets $livePages `
            -AuthenticatedEvidenceRules @($adapter.huiceAdapter.loginDetection.authenticatedEvidenceRules) `
            -CheckedAt ([DateTimeOffset]::Now.ToString('o'))
        $livePassed = (
            [string]$liveResult.loginStatus -in @('未登录', '登录状态未知') -and
            [string]$liveResult.loginStatus -ne '已登录'
        )
        Add-LoginRegressionResult -Id 'LS-006' -Name '现有慧策 Chrome 实时证据边界' -Passed $livePassed -Executed $true -Evidence (
            "真实端口=$($liveHuiceEndpoint[0].Port)；真实页面数=$($livePages.Count)；登录状态=$($liveResult.loginStatus)；证据=$($liveResult.loginEvidence.evidenceType)；未读取Cookie/Token=True"
        )
    }

    $managedFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'data') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.json','.jsonl','.txt') }
        Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'logs') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.json','.jsonl','.log','.txt') }
    )
    $sensitiveFindings = @()
    foreach ($file in $managedFiles) {
        $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            foreach ($finding in @(Get-PMSensitiveFinding -Text $text)) {
                $sensitiveFindings += "$($file.Name):$finding"
            }
        }
    }
    Import-Module (Join-Path $projectRoot 'scripts\lib\PortManager.Sqlite.psm1') -Force -WarningAction SilentlyContinue
    Initialize-PMSqlite -DataRoot (Join-Path $runtimeRoot 'data') -JsonPath (Join-Path $runtimeRoot 'data\ports.json')
    $store = Read-PMSqliteStore
    $sensitivePassed = (
        [int]$store.schemaVersion -ge 18 -and
        $sensitiveFindings.Count -eq 0 -and
        @($store.resources | Where-Object { $null -ne $_.credentialRef }).Count -eq 0
    )
    Add-LoginRegressionResult -Id 'LS-007' -Name '状态、审计和日志敏感信息扫描' -Passed $sensitivePassed -Executed $true -Evidence (
        "schema=$($store.schemaVersion)；扫描文件数=$($managedFiles.Count)；发现=$($sensitiveFindings -join ',')；Chrome原生profile不由程序读取或复制"
    )
}
catch {
    Add-LoginRegressionResult -Id 'LS-999' -Name '登录状态回归执行异常' -Passed $false -Executed $true -Evidence $_.Exception.Message
}
finally {
    $cleanupAttempted = $false
    $cleanupCompleted = $true
    $cleanupProcessIds = @()
    if ($null -ne $ownedBrowserProcessId -and $null -ne $registeredResource -and $null -ne $ownedBrowserStartedAt) {
        $cleanupAttempted = $true
        $process = Get-Process -Id ([int]$ownedBrowserProcessId) -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            $cleanup = Stop-PMChromeOwnedProcesses -Resource $registeredResource -StartedProcess $process -StartedAt $ownedBrowserStartedAt
            $cleanupCompleted = [bool]$cleanup.cleaned
            $cleanupProcessIds = @($cleanup.attemptedProcessIds)
        }
    }

    $remainingProfileProcesses = @(
        if (-not [string]::IsNullOrWhiteSpace([string]$profileDirectory)) {
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                [string]$_.Name -ieq 'chrome.exe' -and
                -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
                ([string]$_.CommandLine).IndexOf($profileDirectory, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
        }
    )
    Initialize-PMStorage
    $leaseCount = @(Get-PMActiveLeases).Count
    $cleanupPassed = $cleanupCompleted -and $remainingProfileProcesses.Count -eq 0 -and $leaseCount -eq 0
    Add-LoginRegressionResult -Id 'LS-008' -Name '真实 Chrome 与租约测试后精确清理' -Passed $cleanupPassed -Executed $true -Evidence (
        "尝试清理=$cleanupAttempted；清理完成=$cleanupCompleted；清理PID=$($cleanupProcessIds -join ',')；配置目录残留进程=$($remainingProfileProcesses.Count)；租约=$leaseCount"
    )

    if ($null -ne $registeredResource) {
        $closedCheck = Invoke-PortManagerJson -Arguments @(
            '-Action', 'Check',
            '-ResourceId', [string]$registeredResource.resourceId,
            '-OutputFormat', 'Json',
            '-NonInteractive'
        )
        $closedDetail = Invoke-PortManagerJson -Arguments @(
            '-Action', 'Detail',
            '-ResourceId', [string]$registeredResource.resourceId,
            '-OutputFormat', 'Json',
            '-NonInteractive'
        )
        $closedStatus = if ($null -eq $closedCheck.Json -or $null -eq $closedCheck.Json.data) { $null } else { $closedCheck.Json.data.Status }
        $closedPassed = (
            $closedCheck.ExitCode -eq 0 -and
            $closedDetail.ExitCode -eq 0 -and
            [string]$closedStatus.browserStatus -eq '浏览器未连接' -and
            [string]$closedStatus.loginStatus -eq '登录状态未知' -and
            [string]$closedDetail.Json.data.lastStatus.loginStatus -eq '登录状态未知' -and
            [string]$closedDetail.Json.data.lastStatus.loginEvidence.evidenceType -eq 'none'
        )
        Add-LoginRegressionResult -Id 'LS-009' -Name 'Chrome 关闭后清除旧登录页状态' -Passed $closedPassed -Executed $true -Evidence (
            "Check退出码=$($closedCheck.ExitCode)；Detail退出码=$($closedDetail.ExitCode)；浏览器=$($closedStatus.browserStatus)；登录=$($closedDetail.Json.data.lastStatus.loginStatus)；证据=$($closedDetail.Json.data.lastStatus.loginEvidence.evidenceType)"
        )
    }

    $finalManagedFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'data') -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'logs') -File -ErrorAction SilentlyContinue
    )
    $finalSensitiveFindings = @()
    foreach ($file in $finalManagedFiles) {
        $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            foreach ($finding in @(Get-PMSensitiveFinding -Text $text)) {
                $finalSensitiveFindings += "$($file.Name):$finding"
            }
        }
    }
    Add-LoginRegressionResult -Id 'LS-010' -Name '失败与关闭收口后的敏感信息复扫' `
        -Passed ($finalSensitiveFindings.Count -eq 0) -Executed $true -Evidence (
            "扫描文件数=$($finalManagedFiles.Count)；发现=$($finalSensitiveFindings -join ',')"
        )
}

$summary = [ordered]@{
    executedAt = [DateTimeOffset]::Now.ToString('o')
    projectRoot = $projectRoot
    runtimeRoot = $runtimeRoot
    results = $results
    passed = @($results | Where-Object { $_.passed }).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
    realLoginPageExecuted = @($results | Where-Object { $_.id -eq 'LS-003' -and $_.passed }).Count -eq 1
    realExistingHuicePageExecuted = @($results | Where-Object { $_.id -eq 'LS-006' -and $_.executed }).Count -eq 1
    realAuthenticatedEvidenceExecuted = $false
    autoLoginExecuted = $false
}
$summaryPath = Join-Path $runtimeRoot 'login-state-regression-summary.json'
[IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 12) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
)
$summary | ConvertTo-Json -Depth 12
if ($summary.failed -gt 0) {
    exit 1
}
exit 0
