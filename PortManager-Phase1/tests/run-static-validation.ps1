[CmdletBinding()]
param(
    [switch]$PrerequisiteOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pythonPrerequisitePath = Join-Path $PSScriptRoot 'helpers\Require-FDrivePython.ps1'
. $pythonPrerequisitePath
try {
    $pythonPath = Resolve-BSClawTestPython -ProjectRoot $projectRoot
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
$env:BSCLAW_PYTHON_PATH = $pythonPath
if ($PrerequisiteOnly) {
    [Console]::Out.WriteLine('F 盘 Python 与 sqlite3 前置检查通过。')
    exit 0
}

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

$previousByteCodePrefix = [Environment]::GetEnvironmentVariable('PYTHONPYCACHEPREFIX', 'Process')
$env:PYTHONPYCACHEPREFIX = Join-Path $runtimeRoot 'python-cache'
& $pythonPath -m py_compile (Join-Path $projectRoot 'scripts\sqlite_service.py')
$pythonCompileExitCode = $LASTEXITCODE
if ($null -eq $previousByteCodePrefix) {
    [Environment]::SetEnvironmentVariable('PYTHONPYCACHEPREFIX', $null, 'Process')
}
else {
    $env:PYTHONPYCACHEPREFIX = $previousByteCodePrefix
}
$prerequisiteOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (
    Join-Path $PSScriptRoot 'test-python-prerequisite.ps1'
) 2>&1
$prerequisiteExitCode = $LASTEXITCODE
$pythonCompilePassed = $pythonCompileExitCode -eq 0 -and $prerequisiteExitCode -eq 0
$pythonCompileEvidence = (
    "解释器=$pythonPath；编译退出码=$pythonCompileExitCode；" +
    "无配置前置回归退出码=$prerequisiteExitCode；结果=$($prerequisiteOutput -join ' ')"
)
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
$adapterPath = Join-Path $projectRoot 'adapter\bsclaw-port-adapter.json'
$adapterActions = @()
if (Test-Path -LiteralPath $adapterPath) {
    try {
        $adapterContract = Get-Content -LiteralPath $adapterPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $adapterActions = @($adapterContract.supportedOperations | ForEach-Object { [string]$_.name })
    }
    catch {
        $adapterActions = @()
    }
}
$formalInternalActions = @($internalActions | Where-Object { $_ -ne 'Menu' })
$missingAdapterActions = @($formalInternalActions | Where-Object { $_ -notin $adapterActions })
$extraAdapterActions = @($adapterActions | Where-Object { $_ -notin $formalInternalActions })
$actionParityPassed = $rootActionMatch.Success -and $internalActionMatch.Success -and
    $missingRootActions.Count -eq 0 -and $extraRootActions.Count -eq 0 -and
    $missingAdapterActions.Count -eq 0 -and $extraAdapterActions.Count -eq 0
Add-ValidationResult -Name '统一根入口 Action 完整性' -Passed $actionParityPassed -Evidence (
    "根入口=$($rootActions.Count)；内部入口=$($internalActions.Count)；适配器=$($adapterActions.Count)；" +
    "根入口缺失=$($missingRootActions -join ',')；根入口多余=$($extraRootActions -join ',')；" +
    "适配器缺失=$($missingAdapterActions -join ',')；适配器多余=$($extraAdapterActions -join ',')"
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
    '..\docs\portmanager-login-migration-audit.md',
    'skill\SKILL.md',
    'data\ports.json',
    'logs\README.md',
    'tests\helpers\Require-FDrivePython.ps1',
    'tests\run-business-regression.ps1',
    'tests\run-login-state-regression.ps1',
    'tests\run-static-validation.ps1',
    'tests\test-python-prerequisite.ps1'
)
$missingPaths = @($requiredPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $projectRoot $_)) })
$pathEvidence = if ($missingPaths.Count -eq 0) {
    "$($requiredPaths.Count) 个必需路径均存在。"
}
else {
    "缺失：$($missingPaths -join '、')"
}
Add-ValidationResult -Name '交付目录与入口完整性' -Passed ($missingPaths.Count -eq 0) -Evidence $pathEvidence

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path $projectRoot -Parent))
$loginAgentRoot = Join-Path $repositoryRoot 'HuiceLoginAgent'
$designContractPath = Join-Path $projectRoot 'docs\design\port-resource-login-state-v1.md'
$integrationPaths = @(
    (Join-Path $loginAgentRoot 'login-agent.ps1'),
    (Join-Path $loginAgentRoot 'lib\HuiceLogin.HttpLogin.psm1'),
    (Join-Path $loginAgentRoot 'lib\HuiceLogin.Credential.psm1'),
    (Join-Path $loginAgentRoot 'lib\secure_login_bridge.js')
)
$missingIntegrationPaths = @($integrationPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
$designContractText = if (Test-Path -LiteralPath $designContractPath -PathType Leaf) {
    [IO.File]::ReadAllText($designContractPath, [Text.Encoding]::UTF8)
}
else {
    ''
}
$enabledEvidenceRules = @(
    $adapterContract.huiceAdapter.loginDetection.authenticatedEvidenceRules |
        Where-Object { [bool]$_.enabled }
)
$httpLoginModuleText = if (Test-Path -LiteralPath $integrationPaths[1] -PathType Leaf) {
    [IO.File]::ReadAllText($integrationPaths[1], [Text.Encoding]::UTF8)
}
else {
    ''
}
$loginEntryText = if (Test-Path -LiteralPath $integrationPaths[0] -PathType Leaf) {
    [IO.File]::ReadAllText($integrationPaths[0], [Text.Encoding]::UTF8)
}
else {
    ''
}
$sqliteServiceText = [IO.File]::ReadAllText(
    (Join-Path $projectRoot 'scripts\sqlite_service.py'),
    [Text.Encoding]::UTF8
)
$secureBridgeText = if (Test-Path -LiteralPath $integrationPaths[3] -PathType Leaf) {
    [IO.File]::ReadAllText($integrationPaths[3], [Text.Encoding]::UTF8)
}
else {
    ''
}
$designContractMatches = (
    $designContractText.Contains('authenticatedEvidenceRules：当前为 1 条启用规则') -and
    $designContractText.Contains('autoLoginImplemented：true') -and
    $designContractText.Contains('loginAutomationState：`huice-same-origin-http-login`') -and
    $designContractText.Contains('HuiceLoginAgent') -and
    $designContractText.Contains('同源 HTTP 登录') -and
    -not $designContractText.Contains('"authenticatedEvidenceRules": []') -and
    -not $designContractText.Contains('autoLoginEnabled` 本阶段固定为 `false`')
)
$integrationBoundaryPassed = (
    [IO.Path]::GetPathRoot($repositoryRoot) -like 'F:\' -and
    $missingIntegrationPaths.Count -eq 0 -and
    $enabledEvidenceRules.Count -eq 1 -and
    [bool]$adapterContract.resourceDataModel.autoLoginImplemented -and
    [string]$adapterContract.resourceDataModel.loginAdapter -eq 'HuiceLoginAgent' -and
    [string]$adapterContract.resourceDataModel.loginAutomationState -eq 'huice-same-origin-http-login' -and
    $httpLoginModuleText.Contains('function Invoke-HuiceSameOriginHttpLogin') -and
    $httpLoginModuleText.Contains('function Invoke-HuiceHttpLogin') -and
    -not $httpLoginModuleText.Contains('Invoke-HuiceWebFormLogin') -and
    $loginEntryText.Contains('Invoke-HuiceHttpLogin') -and
    $secureBridgeText.Contains("loginTransport: 'same-origin-http'") -and
    -not $secureBridgeText.Contains('runLegacyFormLogin') -and
    -not $secureBridgeText.Contains('Input.dispatchKeyEvent') -and
    -not $secureBridgeText.Contains('Input.dispatchMouseEvent') -and
    $sqliteServiceText.Contains("login_automation_state='huice-same-origin-http-login'") -and
    -not $sqliteServiceText.Contains("login_automation_state='same-origin-http-login'") -and
    $sqliteServiceText.Contains('resources = source if isinstance(source, list) else (source.get("resources") or [])') -and
    $loginEntryText.Contains('$resources = [object[]]@(Get-HuiceRegisteredResources)') -and
    $designContractMatches
)
Add-ValidationResult -Name '同仓库登录适配器与设计文档契约一致性' -Passed $integrationBoundaryPassed -Evidence (
    "仓库根=$repositoryRoot；缺失=$($missingIntegrationPaths -join ',')；启用鉴权规则=$($enabledEvidenceRules.Count)；" +
    "autoLoginImplemented=$($adapterContract.resourceDataModel.autoLoginImplemented)；" +
    "loginAdapter=$($adapterContract.resourceDataModel.loginAdapter)；loginAutomationState=$($adapterContract.resourceDataModel.loginAutomationState)；" +
    "同源HTTP唯一主链=$($secureBridgeText.Contains(""loginTransport: 'same-origin-http'""))；JSON迁移/List数组兼容=True；实现与文档一致=$designContractMatches"
)

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
