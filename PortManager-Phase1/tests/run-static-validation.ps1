[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = Join-Path $projectRoot (
    'data\test-runs\static-validation-{0}-{1}' -f [DateTime]::Now.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N')
)
$null = New-Item -ItemType Directory -Path $runtimeRoot -Force
$env:BSCLAW_PM_RUNTIME_ROOT = $runtimeRoot
$results = @()

function Add-ValidationResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Evidence
    )
    $script:results += [pscustomobject]@{
        name = $Name
        passed = $Passed
        evidence = $Evidence
    }
}

$scriptFiles = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
$parseErrors = @()
foreach ($file in $scriptFiles) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    $parseErrors += @($errors | ForEach-Object { "$($file.FullName):$($_.Extent.StartLineNumber):$($_.Message)" })
}
$parseEvidence = if ($parseErrors.Count -eq 0) {
    "$($scriptFiles.Count) 个脚本解析无错误。"
}
else {
    $parseErrors -join [Environment]::NewLine
}
Add-ValidationResult -Name 'PowerShell 语法解析' -Passed ($parseErrors.Count -eq 0) -Evidence $parseEvidence

$jsonFiles = @(
    (Join-Path $projectRoot 'adapter\bsclaw-port-adapter.json'),
    (Join-Path $projectRoot 'data\ports.json')
)
$jsonErrors = @()
foreach ($file in $jsonFiles) {
    try {
        [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json | Out-Null
    }
    catch {
        $jsonErrors += "$file：$($_.Exception.Message)"
    }
}
$jsonEvidence = if ($jsonErrors.Count -eq 0) {
    '适配清单和端口数据文件均为有效 JSON。'
}
else {
    $jsonErrors -join [Environment]::NewLine
}
Add-ValidationResult -Name 'JSON 文件解析' -Passed ($jsonErrors.Count -eq 0) -Evidence $jsonEvidence

$pythonPath = [Environment]::GetEnvironmentVariable('BSCLAW_PYTHON_PATH', 'Process')
if ([string]::IsNullOrWhiteSpace($pythonPath)) {
    $pythonPath = Join-Path $projectRoot 'tools\python\python.exe'
}
$pythonCandidates = @(
    $pythonPath,
    'F:\AIAPP\Codex\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
    (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }
$pythonPath = @($pythonCandidates | Where-Object { [IO.Path]::GetPathRoot([IO.Path]::GetFullPath([string]$_)) -like 'F:\' }) | Select-Object -First 1
$pythonCompilePassed = $false
$pythonCompileEvidence = '未找到 F 盘 Python 解释器；未执行 Python 编译检查。'
if ((Test-Path -LiteralPath $pythonPath -PathType Leaf) -and ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($pythonPath)) -like 'F:\')) {
    & $pythonPath -c "import ast,pathlib; ast.parse(pathlib.Path(r'$projectRoot\scripts\sqlite_service.py').read_text(encoding='utf-8'))"
    $pythonCompilePassed = $LASTEXITCODE -eq 0
    $pythonCompileEvidence = "解释器=$pythonPath；退出码=$LASTEXITCODE"
}
Add-ValidationResult -Name 'SQLite Python 服务编译' -Passed $pythonCompilePassed -Evidence $pythonCompileEvidence

$listOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'port-manager.ps1') -Action List -OutputFormat Json -NonInteractive 2>&1
$listExitCode = $LASTEXITCODE
$listJsonValid = $false
if ($listExitCode -eq 0) {
    try {
        $parsedList = ($listOutput -join [Environment]::NewLine) | ConvertFrom-Json
        $listJsonValid = $parsedList.success -eq $true
    }
    catch {
        $listJsonValid = $false
    }
}
Add-ValidationResult -Name '空数据启动与 List JSON' -Passed ($listExitCode -eq 0 -and $listJsonValid) -Evidence (
    "退出码=$listExitCode；输出=$($listOutput -join ' ')"
)

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'powershell.exe'
$startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$projectRoot\port-manager.ps1`""
$startInfo.WorkingDirectory = $projectRoot
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
$startInfo.CreateNoWindow = $true
$startInfo.EnvironmentVariables['BSCLAW_PM_RUNTIME_ROOT'] = $runtimeRoot
$menuProcess = [Diagnostics.Process]::new()
$menuProcess.StartInfo = $startInfo
$null = $menuProcess.Start()
$menuProcess.StandardInput.WriteLine('0')
$menuProcess.StandardInput.Close()
$menuExited = $menuProcess.WaitForExit(15000)
if (-not $menuExited) {
    Stop-Process -Id $menuProcess.Id -Force -ErrorAction SilentlyContinue
    $menuProcess.WaitForExit(5000) | Out-Null
}
$menuOutput = $menuProcess.StandardOutput.ReadToEnd()
$menuError = $menuProcess.StandardError.ReadToEnd()
$hasRegisterMenu = $menuOutput.Contains('1. 注册慧策通端口')
$hasCheckAllMenu = $menuOutput.Contains('8. 检查全部端口')
$hasMaintenanceMenu = $menuOutput.Contains('9. 清理端口环境')
$hasExitMessage = (
    $menuOutput.Contains('已退出程序。') -or
    $menuOutput.Contains('标准输入已结束，程序安全退出。')
)
$menuPassed = $menuExited -and $menuProcess.ExitCode -eq 0 -and $hasRegisterMenu -and $hasCheckAllMenu -and $hasMaintenanceMenu -and $hasExitMessage
Add-ValidationResult -Name '中文菜单启动与安全退出' -Passed $menuPassed -Evidence (
    "退出码=$($menuProcess.ExitCode)；超时=$(-not $menuExited)；标准错误=$menuError；注册菜单=$hasRegisterMenu；全检菜单=$hasCheckAllMenu；环境清理菜单=$hasMaintenanceMenu；退出提示=$hasExitMessage"
)
$menuProcess.Dispose()

$rootEntryText = [IO.File]::ReadAllText((Join-Path $projectRoot 'port-manager.ps1'), [Text.Encoding]::UTF8)
$internalEntryText = [IO.File]::ReadAllText((Join-Path $projectRoot 'scripts\port-manager.ps1'), [Text.Encoding]::UTF8)
$actionPattern = '\[ValidateSet\(([^\)]*)\)\]\s*\r?\n\s*\[string\]\$Action'
$rootActionMatch = [regex]::Match($rootEntryText, $actionPattern)
$internalActionMatch = [regex]::Match($internalEntryText, $actionPattern)
$rootActions = @()
$internalActions = @()
if ($rootActionMatch.Success) {
    $rootActions = @([regex]::Matches($rootActionMatch.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
}
if ($internalActionMatch.Success) {
    $internalActions = @([regex]::Matches($internalActionMatch.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
}
$missingRootActions = @($internalActions | Where-Object { $_ -notin $rootActions })
$extraRootActions = @($rootActions | Where-Object { $_ -notin $internalActions })
$actionParityPassed = $rootActionMatch.Success -and $internalActionMatch.Success -and
    $missingRootActions.Count -eq 0 -and $extraRootActions.Count -eq 0
Add-ValidationResult -Name '统一根入口 Action 完整性' -Passed $actionParityPassed -Evidence (
    "根入口=$($rootActions.Count)；内部入口=$($internalActions.Count)；缺失=$($missingRootActions -join ',')；多余=$($extraRootActions -join ',')"
)

$requiredPaths = @(
    'port-manager.ps1',
    'scripts\port-manager.ps1',
    'scripts\register-port.ps1',
    'scripts\list-ports.ps1',
    'scripts\edit-port.ps1',
    'scripts\delete-port.ps1',
    'scripts\check-port.ps1',
    'scripts\open-huice-port.ps1',
    'scripts\lib\PortManager.Core.psm1',
    'scripts\lib\PortManager.Huice.psm1',
    'scripts\lib\PortManager.State.psm1',
    'scripts\lib\PortManager.Persistence.psm1',
    'scripts\lib\PortManager.Registration.psm1',
    'scripts\lib\PortManager.Login.psm1',
    'scripts\lib\PortManager.Chrome.psm1',
    'scripts\lib\PortManager.Output.psm1',
    'scripts\lib\PortManager.Sqlite.psm1',
    'scripts\lib\PortManager.LoginStateDetector.psm1',
    'scripts\lib\PortManager.Profile.psm1',
    'scripts\lib\PortManager.EnvironmentMaintenance.psm1',
    'scripts\lib\PortManager.Network.psm1',
    'scripts\lib\PortManager.Performance.psm1',
    'scripts\lib\PortManager.StorageAudit.psm1',
    'scripts\lib\PortManager.HuiceLoginAdapter.psm1',
    'scripts\login-state-worker.ps1',
    'scripts\login-state-watcher.ps1',
    'scripts\sqlite_service.py',
    'adapter\bsclaw-port-adapter.json',
    'docs\README.md',
    'docs\execution.md',
    'docs\sqlite-schema-current.md',
    'docs\manual-test-promotion.md',
    'docs\promotion-closure-report-20260729.md',
    'skill\SKILL.md',
    'data\ports.json',
    'logs\README.md',
    'tests\real-validation-record.md',
    'tests\run-login-state-regression.ps1',
    'tests\login-state-regression-summary.md'
)
$missingPaths = @($requiredPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $projectRoot $_)) })
$pathEvidence = if ($missingPaths.Count -eq 0) {
    "$($requiredPaths.Count) 个必需路径均存在。"
}
else {
    "缺失：$($missingPaths -join '、')"
}
Add-ValidationResult -Name '交付目录与入口完整性' -Passed ($missingPaths.Count -eq 0) -Evidence $pathEvidence

$adapterPath = Join-Path $projectRoot 'adapter\bsclaw-port-adapter.json'
$huiceLoginRoot = Join-Path (Split-Path -Parent $projectRoot) 'HuiceLoginAgent'
$httpLoginModule = Join-Path $huiceLoginRoot 'lib\HuiceLogin.HttpLogin.psm1'
$secureLoginBridge = Join-Path $huiceLoginRoot 'lib\secure_login_bridge.js'
$sqliteService = Join-Path $projectRoot 'scripts\sqlite_service.py'
$loginContractPassed = $false
$loginContractEvidence = '登录适配器或 HuiceLoginAgent 交付路径不存在。'
if (
    (Test-Path -LiteralPath $adapterPath -PathType Leaf) -and
    (Test-Path -LiteralPath $httpLoginModule -PathType Leaf) -and
    (Test-Path -LiteralPath $secureLoginBridge -PathType Leaf)
) {
    $adapter = [IO.File]::ReadAllText($adapterPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $httpLoginText = [IO.File]::ReadAllText($httpLoginModule, [Text.Encoding]::UTF8)
    $secureLoginText = [IO.File]::ReadAllText($secureLoginBridge, [Text.Encoding]::UTF8)
    $sqliteServiceText = [IO.File]::ReadAllText($sqliteService, [Text.Encoding]::UTF8)
    $authenticatedRules = @($adapter.huiceAdapter.loginDetection.authenticatedEvidenceRules)
    $enabledRuleCount = @($authenticatedRules | Where-Object { [bool]$_.enabled }).Count
    $hasDomLogin = (
        $httpLoginText.Contains('Invoke-HuiceWebFormLogin') -or
        $secureLoginText.Contains('Input.dispatchKeyEvent') -or
        $secureLoginText.Contains('Input.dispatchMouseEvent')
    )
    $loginContractPassed = (
        [bool]$adapter.resourceDataModel.autoLoginImplemented -and
        $enabledRuleCount -gt 0 -and
        $httpLoginText.Contains('Invoke-HuiceSameOriginHttpLogin') -and
        $secureLoginText.Contains("loginTransport: 'same-origin-http'") -and
        -not $hasDomLogin -and
        -not $sqliteServiceText.Contains('resource-web-form-login')
    )
    $loginContractEvidence = "自动登录=$($adapter.resourceDataModel.autoLoginImplemented)；启用鉴权规则=$enabledRuleCount；同源HTTP=$($httpLoginText.Contains('Invoke-HuiceSameOriginHttpLogin'))；DOM竞争实现=$hasDomLogin；旧状态名=$($sqliteServiceText.Contains('resource-web-form-login'))"
}
Add-ValidationResult -Name '慧策唯一同源 HTTP 登录契约' -Passed $loginContractPassed -Evidence $loginContractEvidence

$summary = [ordered]@{
    executedAt = [DateTimeOffset]::Now.ToString('o')
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    projectRoot = $projectRoot
    results = $results
    passed = @($results | Where-Object { $_.passed }).Count
    failed = @($results | Where-Object { -not $_.passed }).Count
    realHuiceScenariosExecuted = $false
}

$outputPath = Join-Path $runtimeRoot 'static-validation.json'
[IO.File]::WriteAllText(
    $outputPath,
    ($summary | ConvertTo-Json -Depth 8) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
)
$summary | ConvertTo-Json -Depth 8
if ($summary.failed -gt 0) {
    exit 1
}
exit 0
