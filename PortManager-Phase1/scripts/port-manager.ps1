[CmdletBinding()]
param(
    [ValidateSet('Menu', 'ServiceCheck', 'StoragePlan', 'List', 'Detail', 'Register', 'Edit', 'Delete', 'Enable', 'Disable', 'Check', 'CheckAll', 'Open', 'CachePlan', 'CleanCache', 'CreateLoginTestProfile', 'DeploymentCleanPlan', 'StorageAudit', 'ResetLoginPlan', 'HuiceList', 'HuiceCheck', 'HuiceLogin', 'AcquireLease', 'ReleaseLease', 'Occupancy', 'LoginCheck', 'CancelLoginCheck')]
    [string]$Action = 'Menu',
    [string]$ResourceId,
    [string]$ResourceName,
    [string]$PlatformName = '慧策通',
    [string]$HostName,
    [int]$Port,
    [ValidateSet('ConnectOnly', 'Launch')]
    [string]$ConnectionMode,
    [string]$BrowserExecutable,
    [string]$BrowserProfileDirectory,
    [string]$StartUrl,
    [string]$PlatformUrlPatterns,
    [string]$LoginPagePatterns,
    [switch]$Disabled,
    [string]$Notes,
    [string]$ConfirmationText,
    [int]$TestPort,
    [string]$LeaseId,
    [string]$TaskRef,
    [switch]$RequireLogin,
    [ValidateRange(5, 3600)]
    [int]$LeaseDurationSeconds = 60,
    [ValidateRange(3, 120)]
    [int]$TimeoutSeconds = 20,
    [switch]$SkipLoginMonitoring,
    [switch]$NonInteractive,
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:InvocationParameters = @{} + $PSBoundParameters
$script:EntryStopwatch = [Diagnostics.Stopwatch]::StartNew()
$script:StorageInitializationMs = $null

$modulePath = Join-Path $PSScriptRoot 'lib\PortManager.Core.psm1'
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$huiceModulePath = Join-Path $PSScriptRoot 'lib\PortManager.Huice.psm1'
Import-Module $huiceModulePath -Force
$registrationModulePath = Join-Path $PSScriptRoot 'lib\PortManager.Registration.psm1'
Import-Module $registrationModulePath -Force
$outputModulePath = Join-Path $PSScriptRoot 'lib\PortManager.Output.psm1'
Import-Module $outputModulePath -Force
$profileModulePath = Join-Path $PSScriptRoot 'lib\PortManager.Profile.psm1'
Import-Module $profileModulePath -Force
$maintenanceModulePath = Join-Path $PSScriptRoot 'lib\PortManager.EnvironmentMaintenance.psm1'
Import-Module $maintenanceModulePath -Force
$storageAuditModulePath = Join-Path $PSScriptRoot 'lib\PortManager.StorageAudit.psm1'
Import-Module $storageAuditModulePath -Force
$serviceAdapterModulePath = Join-Path $PSScriptRoot 'lib\PortManager.ServiceAdapter.psm1'
Import-Module $serviceAdapterModulePath -Force
$huiceLoginAdapterModulePath = Join-Path $PSScriptRoot 'lib\PortManager.HuiceLoginAdapter.psm1'
Import-Module $huiceLoginAdapterModulePath -Force
function Write-PMJsonResult {
    param(
        [bool]$Success,
        [string]$Message,
        [object]$Data,
        [string]$NextAction,
        [object]$ErrorRecord
    )
    $resourceId = $null; $leaseId = $null; $auditId = $null; $taskId = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$script:InvocationParameters['ResourceId'])) { $resourceId = [string]$script:InvocationParameters['ResourceId'] }
    if ($null -ne $Data) {
        if ($Data.PSObject.Properties.Name -contains 'resourceId') { $resourceId = [string]$Data.resourceId }
        elseif ($Data.PSObject.Properties.Name -contains 'Resource' -and $null -ne $Data.Resource) { $resourceId = [string]$Data.Resource.resourceId }
        if ($Data.PSObject.Properties.Name -contains 'leaseId') { $leaseId = [string]$Data.leaseId }
        if ($Data.PSObject.Properties.Name -contains 'auditId') { $auditId = [string]$Data.auditId }
        if ($Data.PSObject.Properties.Name -contains 'attemptId') { $taskId = [string]$Data.attemptId }
        elseif ($Data.PSObject.Properties.Name -contains 'record' -and $null -ne $Data.record) { $taskId = [string]$Data.record.attemptId }
    }
    if ([string]::IsNullOrWhiteSpace($auditId)) {
        try { $auditId = [string](Get-PMLastAuditId) } catch { }
    }
    Write-PMJsonEnvelope -Success $Success -Message $Message -Data $Data -NextAction $NextAction `
        -ErrorCode (Get-PMErrorCodeOutput -ErrorRecord $ErrorRecord) -ResourceId $resourceId -LeaseId $leaseId -AuditId $auditId -TaskId $taskId
}

try {
    Initialize-PMStorage
    $script:StorageInitializationMs = [int64]$script:EntryStopwatch.ElapsedMilliseconds
}
catch {
    if ($OutputFormat -eq 'Json') {
        $message = $_.Exception.Message
        $schemaError = if ($message -match 'checksum') {
            New-PMStructuredException -ErrorCode 'PM_SCHEMA_CHECKSUM_MISMATCH' -Message $message -NextAction '检查 data\migrations 中的备份并修复数据库后重试。'
        }
        elseif ($message -match 'Python.*F 盘|F 盘.*Python') {
            New-PMStructuredException -ErrorCode 'PM_PYTHON_F_DRIVE_REQUIRED' -Message $message -NextAction '设置 BSCLAW_PYTHON_PATH 为 F 盘 python.exe 后重试。'
        }
        else { $_.Exception }
        $schemaRecord = [Management.Automation.ErrorRecord]::new($schemaError, 'PM_STORAGE_INIT_FAILED', [Management.Automation.ErrorCategory]::InvalidData, $null)
        Write-PMJsonResult -Success $false -Message $message -Data $null -NextAction (Get-PMErrorNextActionOutput -Message $message -ErrorRecord $schemaRecord) -ErrorRecord $schemaRecord
        exit 1
    }
    throw
}

function Read-PMUserInput {
    param([string]$Prompt)

    if (-not [Console]::IsInputRedirected) {
        return Read-Host $Prompt
    }

    $value = [Console]::In.ReadLine()
    if ($null -eq $value) {
        return $null
    }

    return ([string]$value).TrimStart([char]0xFEFF)
}

function Resolve-PMResourceId {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        if ($OutputFormat -eq 'Json' -or $NonInteractive) {
            throw '资源编号不能为空；机器调用必须提供 -ResourceId。'
        }
        $resources = @(Get-PMResources | Where-Object { $_ -is [object] })
        if ($resources.Count -eq 0) {
            throw '当前没有已登记的端口资源；请先进入端口管理注册资源。'
        }
        Write-Host '请选择端口资源（输入序号，不需要输入资源编号）：'
        for ($index = 0; $index -lt $resources.Count; $index++) {
            $item = $resources[$index]
            $name = if ([string]::IsNullOrWhiteSpace([string]$item.resourceName)) { '未命名资源' } else { [string]$item.resourceName }
            $enabled = if ([bool]$item.enabled) { '启用' } else { '停用' }
            $status = if ($null -ne $item.lastStatus -and $item.lastStatus.loginStatus) { [string]$item.lastStatus.loginStatus } else { '未检查' }
            Write-Host ("{0}. {1} / 端口 {2} / {3} / {4}" -f ($index + 1), $name, $item.port, $enabled, $status)
        }
        $selection = Read-PMUserInput -Prompt '请输入资源序号'
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection -notmatch '^\d+$') {
            throw '资源选择无效；请返回资源列表后重新选择。'
        }
        $position = [int]$selection - 1
        if ($position -lt 0 -or $position -ge $resources.Count) {
            throw '资源选择无效；请返回资源列表后重新选择。'
        }
        $Value = [string]$resources[$position].resourceId
    }
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw '资源编号不能为空。'
    }
    return $Value.Trim().ToUpperInvariant()
}

function ConvertFrom-PMYesNo {
    param(
        [string]$Text,
        [bool]$DefaultValue
    )
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $DefaultValue
    }
    if ($Text.Trim().ToUpperInvariant() -in @('Y', 'YES', '是', '启用', '1')) {
        return $true
    }
    if ($Text.Trim().ToUpperInvariant() -in @('N', 'NO', '否', '停用', '0')) {
        return $false
    }
    throw '请输入 Y/是 或 N/否。'
}

function Find-PMBrowserExecutable {
    return Get-PMChromeExecutable
}

function Read-PMAdvancedRegistrationParameters {
    param([object]$AdapterDefaults)

    $values = @{}
    $allowPrompt = -not $NonInteractive -and $OutputFormat -eq 'Text'
    $values.PlatformName = if ([string]::IsNullOrWhiteSpace($PlatformName)) { '慧策通' } else { $PlatformName }
    $values.HostName = if ([string]::IsNullOrWhiteSpace($HostName) -and $allowPrompt) {
        $inputHost = Read-PMUserInput -Prompt '高级设置：主机地址，直接回车使用本机'
        if ([string]::IsNullOrWhiteSpace($inputHost)) { '127.0.0.1' } else { $inputHost }
    }
    elseif ([string]::IsNullOrWhiteSpace($HostName)) { '127.0.0.1' }
    else { $HostName }
    $values.Port = if ($Port -eq 0 -and $allowPrompt) {
        [int](Read-PMUserInput -Prompt '高级设置：请输入端口号（1-65535）')
    }
    else { $Port }
    $values.ConnectionMode = if ([string]::IsNullOrWhiteSpace($ConnectionMode) -and $allowPrompt) {
        $mode = Read-PMUserInput -Prompt '高级设置：1=使用已打开的 Chrome，2=需要时自动启动 Chrome'
        if ($mode -eq '2') { 'Launch' } else { 'ConnectOnly' }
    }
    elseif ([string]::IsNullOrWhiteSpace($ConnectionMode)) { 'ConnectOnly' }
    else { $ConnectionMode }

    $values.BrowserExecutable = $BrowserExecutable
    $values.BrowserProfileDirectory = $BrowserProfileDirectory
    if ($values.ConnectionMode -eq 'Launch') {
        if ([string]::IsNullOrWhiteSpace($values.BrowserExecutable) -and $allowPrompt) {
            $detected = Find-PMBrowserExecutable
            $prompt = if ($null -eq $detected) {
                '未自动找到 Google Chrome，请输入 chrome.exe 完整路径'
            }
            else {
                "已找到 Google Chrome，直接回车使用：$detected"
            }
            $browserInput = Read-PMUserInput -Prompt $prompt
            $values.BrowserExecutable = if ([string]::IsNullOrWhiteSpace($browserInput)) { $detected } else { $browserInput }
        }
        if ([string]::IsNullOrWhiteSpace($values.BrowserProfileDirectory) -and $allowPrompt) {
            $defaultProfile = Join-Path (Get-PMRuntimeRoot) ("browser-profiles\huice-{0}" -f $values.Port)
            $profileInput = Read-PMUserInput -Prompt "高级设置：Chrome 配置目录，直接回车由程序使用：$defaultProfile"
            $values.BrowserProfileDirectory = if ([string]::IsNullOrWhiteSpace($profileInput)) { $defaultProfile } else { $profileInput }
        }
    }

    $values.StartUrl = if ($script:InvocationParameters.ContainsKey('StartUrl')) {
        $StartUrl
    }
    elseif ($allowPrompt) {
        $pageInput = Read-PMUserInput -Prompt "高级设置：慧策通页面地址，直接回车使用：$($AdapterDefaults.StartUrl)"
        if ([string]::IsNullOrWhiteSpace($pageInput)) { $AdapterDefaults.StartUrl } else { $pageInput }
    }
    else { $AdapterDefaults.StartUrl }
    $values.PlatformUrlPatterns = if ($script:InvocationParameters.ContainsKey('PlatformUrlPatterns')) {
        $PlatformUrlPatterns
    }
    elseif ($allowPrompt) {
        $patternInput = Read-PMUserInput -Prompt '高级设置：平台识别规则，直接回车使用慧策通默认规则'
        if ([string]::IsNullOrWhiteSpace($patternInput)) { @($AdapterDefaults.PlatformUrlPatterns) } else { $patternInput }
    }
    else { @($AdapterDefaults.PlatformUrlPatterns) }
    $values.LoginPagePatterns = if ($script:InvocationParameters.ContainsKey('LoginPagePatterns')) {
        $LoginPagePatterns
    }
    elseif ($allowPrompt) {
        $loginInput = Read-PMUserInput -Prompt '高级设置：登录页识别规则，直接回车使用慧策通默认规则'
        if ([string]::IsNullOrWhiteSpace($loginInput)) { @($AdapterDefaults.LoginPagePatterns) } else { $loginInput }
    }
    else { @($AdapterDefaults.LoginPagePatterns) }

    $defaultName = if ($values.Port -gt 0) { "慧策通端口-$($values.Port)" } else { '慧策通端口' }
    $values.ResourceName = if ([string]::IsNullOrWhiteSpace($ResourceName) -and $allowPrompt) {
        $nameInput = Read-PMUserInput -Prompt "资源名称（可选），直接回车使用：$defaultName"
        if ([string]::IsNullOrWhiteSpace($nameInput)) { $defaultName } else { $nameInput }
    }
    elseif ([string]::IsNullOrWhiteSpace($ResourceName)) { $defaultName }
    else { $ResourceName }
    $values.Enabled = -not $Disabled
    $values.Notes = if ($script:InvocationParameters.ContainsKey('Notes')) {
        $Notes
    }
    else { $null }
    return $values
}

function Read-PMRegistrationParameters {
    $context = [pscustomobject]@{
        NonInteractive = [bool]$NonInteractive
        OutputFormat = $OutputFormat
        InvocationParameters = $script:InvocationParameters
        ResourceName = $ResourceName
        PlatformName = $PlatformName
        HostName = $HostName
        Port = $Port
        ConnectionMode = $ConnectionMode
        BrowserExecutable = $BrowserExecutable
        BrowserProfileDirectory = $BrowserProfileDirectory
        StartUrl = $StartUrl
        PlatformUrlPatterns = $PlatformUrlPatterns
        LoginPagePatterns = $LoginPagePatterns
        Disabled = [bool]$Disabled
        Notes = $Notes
        ProjectRoot = Get-PMProjectRoot
        RuntimeRoot = Get-PMRuntimeRoot
    }
    $inputReader = {
        param([string]$Prompt)
        Read-PMUserInput -Prompt $Prompt
    }
    return Get-PMRegistrationPlan -Context $context -ReadInput $inputReader
}

function Write-PMResourceList {
    param([object[]]$Resources)
    Write-PMResourceListOutput -Resources $Resources
}

function Write-PMResourceDetail {
    param([object]$Resource)
    Write-PMResourceDetailOutput -Resource $Resource
}

function Write-PMCheckResult {
    param([object]$Result)
    Write-PMCheckOutput -Result $Result
}

function Write-PMOpenResult {
    param([object]$Result)
    Write-PMOpenOutput -Result $Result
}

function Invoke-PMPostRegistrationFlow {
    param([object]$CheckResult)

    $resource = $CheckResult.Resource
    Write-Host ''
    Write-Host '自动检查结果：'
    Write-PMCheckResult -Result $CheckResult | Out-Host
    Write-Host ''
    Write-Host '1. 立即打开慧策通'
    Write-Host '2. 再次检查'
    Write-Host '0. 返回菜单'
    $nextChoice = Read-PMUserInput -Prompt '请选择下一步，直接回车返回菜单'
    if ([string]::IsNullOrWhiteSpace($nextChoice) -or $nextChoice -eq '0') {
        return
    }

    try {
        if ($nextChoice -eq '1') {
            Write-Host '正在打开慧策通…'
            $openResult = Open-PMResource -ResourceId $resource.resourceId -TimeoutSeconds $TimeoutSeconds
            Write-Host '打开操作已完成，真实状态如下：'
            Write-PMOpenResult -Result $openResult | Out-Host
        }
        elseif ($nextChoice -eq '2') {
            Write-Host '正在重新检查…'
            Write-PMCheckResult -Result (Test-PMResource -ResourceId $resource.resourceId) | Out-Host
        }
        else {
            Write-Host '没有执行后续操作，已返回菜单。'
        }
    }
    catch {
        $message = $_.Exception.Message
        Write-Host "操作失败：$message"
        Write-Host "下一步：$(Get-PMErrorNextActionOutput -Message $message -ErrorRecord $_)"
    }
}

function Invoke-PMRegisterAction {
    if ($OutputFormat -eq 'Text') {
        Write-Host '当前操作：注册慧策通端口。'
    }
    $parameters = Read-PMRegistrationParameters
    $autoOpenAfterRegistration = (
        $parameters.ContainsKey('__AutoOpenAfterRegistration') -and
        [bool]$parameters['__AutoOpenAfterRegistration']
    )
    if ($parameters.ContainsKey('__AutoOpenAfterRegistration')) {
        $parameters.Remove('__AutoOpenAfterRegistration')
    }
    $resource = Register-PMResource @parameters
    if ($autoOpenAfterRegistration) {
        if ($OutputFormat -eq 'Text') {
            Write-Host '正在自动启动 Chrome 并打开慧策通…'
        }
        try {
            $checkResult = Open-PMResource -ResourceId $resource.resourceId -TimeoutSeconds $TimeoutSeconds
        }
        catch {
            $resource = Get-PMResourceById -ResourceId $resource.resourceId
            $checkResult = [pscustomobject]@{
                Resource = $resource
                Status = $resource.lastStatus
            }
            if ($OutputFormat -eq 'Text') {
                Write-Host "自动启动未完成：$($_.Exception.Message)"
                Write-Host "下一步：$(Get-PMErrorNextActionOutput -Message $_.Exception.Message -ErrorRecord $_)"
            }
        }
    }
    else {
        $checkResult = Test-PMResource -ResourceId $resource.resourceId
    }
    $resource = $checkResult.Resource
    if ($OutputFormat -eq 'Text') {
        Write-Host '执行结果：注册成功。'
        Write-Host "资源：$($resource.resourceName)"
        Write-Host "编号：$($resource.resourceId)"
        Write-Host "使用方式：$(if ($resource.connectionMode -eq 'Launch') { '自动启动 Chrome' } else { '使用已打开的慧策通' })"
        Invoke-PMPostRegistrationFlow -CheckResult $checkResult
    }
    return $resource
}

function Invoke-PMEditAction {
    param([string]$Id)
    $Id = Resolve-PMResourceId -Value $Id
    $resource = Get-PMResourceById -ResourceId $Id
    $changes = @{}

    if ($OutputFormat -eq 'Json' -or $NonInteractive) {
        $parameterMap = [ordered]@{
            ResourceName = 'resourceName'
            HostName = 'hostName'
            Port = 'port'
            ConnectionMode = 'connectionMode'
            BrowserExecutable = 'browserExecutable'
            BrowserProfileDirectory = 'browserProfileDirectory'
            StartUrl = 'startUrl'
            PlatformUrlPatterns = 'platformUrlPatterns'
            LoginPagePatterns = 'loginPagePatterns'
            Notes = 'notes'
        }
        foreach ($parameterName in $parameterMap.Keys) {
            if ($script:InvocationParameters.ContainsKey($parameterName)) {
                $changes[$parameterMap[$parameterName]] = $script:InvocationParameters[$parameterName]
            }
        }
        if ($script:InvocationParameters.ContainsKey('Disabled')) {
            $changes.enabled = -not [bool]$script:InvocationParameters.Disabled
        }
    }
    else {
        Write-Host '当前操作：编辑端口。直接回车保留原值。'
        Write-PMResourceDetail -Resource $resource

        $value = Read-PMUserInput -Prompt "资源名称 [$($resource.resourceName)]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.resourceName = $value }
        $value = Read-PMUserInput -Prompt "主机地址 [$($resource.hostName)]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.hostName = $value }
        $value = Read-PMUserInput -Prompt "端口号 [$($resource.port)]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.port = [int]$value }
        $value = Read-PMUserInput -Prompt "连接方式 ConnectOnly/Launch [$($resource.connectionMode)]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.connectionMode = $value }
        $value = Read-PMUserInput -Prompt "浏览器程序 [$($resource.browserExecutable)]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.browserExecutable = $value }
        $value = Read-PMUserInput -Prompt "F 盘浏览器配置目录 [$($resource.browserProfileDirectory)]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.browserProfileDirectory = $value }
        $value = Read-PMUserInput -Prompt "慧策页面地址 [$($resource.startUrl)]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.startUrl = $value }
        $value = Read-PMUserInput -Prompt "平台匹配规则 [$(@($resource.platformUrlPatterns) -join ',')]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.platformUrlPatterns = $value }
        $value = Read-PMUserInput -Prompt "登录页规则 [$(@($resource.loginPagePatterns) -join ',')]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.loginPagePatterns = $value }
        $value = Read-PMUserInput -Prompt "启用状态 Y/N [$(if ($resource.enabled) { 'Y' } else { 'N' })]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.enabled = ConvertFrom-PMYesNo -Text $value -DefaultValue ([bool]$resource.enabled) }
        $value = Read-PMUserInput -Prompt "备注 [$($resource.notes)]"
        if (-not [string]::IsNullOrWhiteSpace($value)) { $changes.notes = $value }
    }

    if ($changes.Count -eq 0) {
        if ($OutputFormat -eq 'Json' -or $NonInteractive) {
            throw '机器编辑必须至少提供一个可编辑参数。'
        }
        Write-Host '执行结果：没有修改任何字段。'
        return $resource
    }
    $updated = Update-PMResource -ResourceId $Id -Changes $changes
    if ($OutputFormat -eq 'Text') {
        Write-Host '执行结果：编辑成功。'
        Write-PMResourceDetail -Resource $updated
    }
    return $updated
}

function Invoke-PMDeleteAction {
    param(
        [string]$Id,
        [string]$ProvidedConfirmation
    )
    $Id = Resolve-PMResourceId -Value $Id
    $resource = Get-PMResourceById -ResourceId $Id
    if ([string]::IsNullOrWhiteSpace($ProvidedConfirmation)) {
        if ($OutputFormat -eq 'Json' -or $NonInteractive) {
            throw '机器删除必须提供 -ConfirmationText "confirm-delete-selected-resource"；ResourceId 由调用方从资源列表内部绑定。'
        }
        Write-Host '当前操作：删除端口。正在使用、存在运行任务或活动监听进程时会拒绝删除。'
        Write-PMResourceDetail -Resource $resource
    }
    elseif ($OutputFormat -eq 'Text') {
        Write-Host '当前操作：删除端口。正在使用、存在运行任务或活动监听进程时会拒绝删除。'
        Write-PMResourceDetail -Resource $resource
    }
    $displayName = if ([string]::IsNullOrWhiteSpace([string]$resource.resourceName)) { '未命名资源' } else { [string]$resource.resourceName }
    $displayLabel = "{0}（端口 {1}）" -f $displayName, $resource.port
    if ([string]::IsNullOrWhiteSpace($ProvidedConfirmation) -and -not $NonInteractive -and $OutputFormat -eq 'Text') {
        $ProvidedConfirmation = Read-PMUserInput -Prompt "确认删除“$displayLabel”？请输入“确认”继续"
        if ($ProvidedConfirmation -ne '确认') {
            throw '已取消删除；资源没有改变。'
        }
        $ProvidedConfirmation = 'confirm-delete-selected-resource'
    }
    $deleted = Remove-PMResource -ResourceId $Id -ConfirmationText $ProvidedConfirmation
    if ($OutputFormat -eq 'Text') {
        Write-Host "执行结果：所选资源已删除；审计记录已保留。"
    }
    return $deleted
}

function Invoke-PMAcquireLeaseAction {
    $id = Resolve-PMResourceId -Value $ResourceId
    $operation = if ([string]::IsNullOrWhiteSpace($TaskRef)) { '外部资源调用' } else { $TaskRef }
    return Set-PMLease -ResourceId $id -Operation $operation `
        -DurationSeconds $LeaseDurationSeconds -TaskRef $TaskRef -RequireLogin:$RequireLogin
}

function Invoke-PMReleaseLeaseAction {
    if ([string]::IsNullOrWhiteSpace($LeaseId)) { throw (New-PMStructuredException -ErrorCode 'PM_LEASE_ID_REQUIRED' -Message '释放租约必须提供 -LeaseId。' -NextAction '先通过 Occupancy 查询 leaseId，再执行 ReleaseLease。') }
    $lease = @(Get-PMActiveLeases | Where-Object { $_.leaseId -eq $LeaseId }) | Select-Object -First 1
    Remove-PMLease -LeaseId $LeaseId
    return [pscustomobject]@{ leaseId = $LeaseId; resourceId = if ($null -eq $lease) { $null } else { $lease.resourceId }; released = $true }
}

function Invoke-PMAction {
    param([string]$SelectedAction)
    $actionStopwatch = [Diagnostics.Stopwatch]::StartNew()
    if ($SelectedAction -notin @('ServiceCheck', 'StoragePlan')) {
        $null = Invoke-PMLoginDetectionReaper
    }
    # CLI reads and explicit actions must not silently enqueue unrelated login checks.
    # LoginCheck and Open own their respective async maintenance decisions.
    switch ($SelectedAction) {
        'ServiceCheck' {
            $data = Invoke-PMServiceCheck
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success ($data.sqliteIntegrity -eq 'ok') -Message '端口管理服务只读自检完成。' -Data $data }
            else {
                Write-Host "端口管理服务：可用；资源数：$($data.resourceCount)；SQLite：$($data.sqliteIntegrity)"
            }
        }
        'StoragePlan' {
            $id = if ([string]::IsNullOrWhiteSpace($ResourceId)) { $null } else { Resolve-PMResourceId -Value $ResourceId }
            $plan = Get-PMStorageAudit -ResourceId $id -NoAudit
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '存储体积只读计划已生成，未写审计、未删除数据。' -Data $plan }
            else { Write-PMStorageAuditText -Audit $plan }
        }
        'List' {
            $resources = @(Get-PMResources)
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '端口列表读取成功。' -Data $resources }
            else { Write-Host '当前操作：查看端口列表。'; Write-PMResourceList -Resources $resources }
        }
        'Detail' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $resource = Get-PMResourceById -ResourceId $id
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '端口详情读取成功。' -Data $resource }
            else { Write-PMResourceDetail -Resource $resource }
        }
        'Register' {
            $resource = Invoke-PMRegisterAction
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '端口注册成功。' -Data $resource }
        }
        'Edit' {
            $resource = Invoke-PMEditAction -Id $ResourceId
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '端口编辑完成。' -Data $resource }
        }
        'Delete' {
            $resource = Invoke-PMDeleteAction -Id $ResourceId -ProvidedConfirmation $ConfirmationText
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '端口删除成功。' -Data $resource }
        }
        'Enable' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $resource = Set-PMResourceEnabled -ResourceId $id -Enabled $true
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '端口已启用。' -Data $resource }
            else { Write-Host "执行结果：资源 $($resource.resourceName)（端口 $($resource.port)）已启用。" }
        }
        'Disable' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $resource = Set-PMResourceEnabled -ResourceId $id -Enabled $false
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '端口已停用。' -Data $resource }
            else { Write-Host "执行结果：资源 $($resource.resourceName)（端口 $($resource.port)）已停用。" }
        }
        'Check' {
            $id = Resolve-PMResourceId -Value $ResourceId
            if ($OutputFormat -eq 'Text') { Write-Host "正在检测资源 $id，请稍候……" }
            $result = Test-PMResource -ResourceId $id
            $result | Add-Member -MemberType NoteProperty -Name entryTiming -Value ([pscustomobject]@{
                storageInitializationMs = $script:StorageInitializationMs
                actionDispatchMs = [int64]$actionStopwatch.ElapsedMilliseconds
            }) -Force
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '端口状态检测完成。' -Data $result }
            else { Write-PMCheckResult -Result $result }
        }
        'CheckAll' {
            $results = @(Test-PMAllResources)
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '全部端口检测完成。' -Data $results }
            elseif ($results.Count -eq 0) { Write-Host '当前操作：检查全部端口。'; Write-Host '当前没有已注册端口。' }
            else { Write-Host '当前操作：检查全部端口。'; foreach ($result in $results) { Write-PMCheckResult -Result $result } }
        }
        'Open' {
            $id = Resolve-PMResourceId -Value $ResourceId
            if ($OutputFormat -eq 'Text') {
                $selected = Get-PMResourceById -ResourceId $id
                Write-Host "当前操作：打开指定慧策通端口 $($selected.resourceName)（端口 $($selected.port)）。"
                Write-Host '程序将检查启用状态、端口冲突、浏览器调试接口、平台页面和登录证据。'
            }
            $result = Open-PMResource -ResourceId $id -TimeoutSeconds $TimeoutSeconds -SkipLoginMonitoring:$SkipLoginMonitoring
            $result | Add-Member -MemberType NoteProperty -Name entryTiming -Value ([pscustomobject]@{
                storageInitializationMs = $script:StorageInitializationMs
                actionDispatchMs = [int64]$actionStopwatch.ElapsedMilliseconds
            }) -Force
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '慧策通端口打开并回查完成。' -Data $result }
            else { Write-PMOpenResult -Result $result }
        }
        'CachePlan' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $plan = Get-PMCachePlan -ResourceId $id
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '可再生缓存预览完成，未删除任何数据。' -Data $plan }
            else { Write-PMCachePlanText -Plan $plan }
        }
        'DeploymentCleanPlan' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $plan = Get-PMDeploymentCleanPlan -ResourceId $id
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '部署前清理建议已生成，未删除任何数据。' -Data $plan }
            else { Write-PMDeploymentPlanText -Plan $plan }
        }
        'StorageAudit' {
            $id = if ([string]::IsNullOrWhiteSpace($ResourceId)) { $null } else { Resolve-PMResourceId -Value $ResourceId }
            $audit = Get-PMStorageAudit -ResourceId $id
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '端口管理全模块体积盘点完成，未删除任何数据。' -Data $audit }
            else { Write-PMStorageAuditText -Audit $audit }
        }
        'CleanCache' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $confirmation = $ConfirmationText
            if ([string]::IsNullOrWhiteSpace($confirmation) -and -not $NonInteractive -and $OutputFormat -eq 'Text') {
                Write-Host '此操作只清理可再生浏览器缓存，不会退出登录。'
                Write-Host '浏览器正在使用该端口时会拒绝，不会自动关闭 Chrome。'
                $selected = Get-PMResourceById -ResourceId $id
                $name = if ([string]::IsNullOrWhiteSpace([string]$selected.resourceName)) { '未命名资源' } else { [string]$selected.resourceName }
                $confirmation = Read-PMUserInput -Prompt "确认清理“$name（端口 $($selected.port)）”的可再生缓存？请输入“确认”继续"
                if ($confirmation -eq '确认') { $confirmation = "确认清理可再生缓存 $id" }
            }
            $result = Invoke-PMResourceCacheCleanup -ResourceId $id -ConfirmationText $confirmation
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '可再生缓存清理完成，登录状态未改变。' -Data $result }
            else { Write-PMCleanupResultText -Result $result }
        }
        'CreateLoginTestProfile' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $created = New-PMLoginTestProfile -SourceResourceId $id -PreferredPort $TestPort
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '独立登录测试环境已创建。' -Data $created }
            else { Write-PMLoginTestProfileText -Result $created }
        }
        'ResetLoginPlan' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $plan = Get-PMResetLoginPlan -ResourceId $id
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '登录状态重置风险说明已生成，未执行任何删除或状态修改。' -Data $plan }
            else { Write-PMResetLoginPlanText -Plan $plan }
        }
        'HuiceList' {
            $result = Invoke-PMHuiceLoginAgent -Action List -TimeoutSeconds $TimeoutSeconds
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '慧策登录资源读取成功。' -Data $result.data }
            else { $result.data | Format-Table resourceId,port,loginStatus,loginApiProbeStatus,loginConfidence -AutoSize }
        }
        'HuiceCheck' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $result = Invoke-PMHuiceLoginAgent -Action Check -ResourceId $id -TimeoutSeconds $TimeoutSeconds
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '慧策登录状态检测完成。' -Data $result.data }
            else { Write-Host "登录状态检测结果：$($result.message)" }
        }
        'HuiceLogin' {
            $id = Resolve-PMResourceId -Value $ResourceId
            if ($OutputFormat -eq 'Text' -and -not $NonInteractive) {
                $result = Invoke-PMHuiceLoginAgent -Action Login -ResourceId $id -Interactive -TimeoutSeconds 300
                Write-Host "慧策登录流程已完成。"
            }
            else {
                $result = Invoke-PMHuiceLoginAgent -Action Login -ResourceId $id -TimeoutSeconds 300
                Write-PMJsonResult -Success $true -Message '慧策登录/会话复用完成。' -Data $result.data
            }
        }
        'AcquireLease' {
            $lease = Invoke-PMAcquireLeaseAction
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '资源租约申请成功。' -Data $lease }
            else { Write-Host "租约已申请：$($lease.leaseId)" }
        }
        'ReleaseLease' {
            $released = Invoke-PMReleaseLeaseAction
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '资源租约已释放（幂等）。' -Data $released }
            else { Write-Host "租约已释放：$($released.leaseId)" }
        }
        'Occupancy' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $occupancy = Get-PMResourceOccupancy -ResourceId $id
            if ($OutputFormat -eq 'Json') { Write-PMJsonResult -Success $true -Message '资源占用状态读取成功。' -Data $occupancy }
            else { $occupancy | Format-List }
        }
        'LoginCheck' {
            $id = Resolve-PMResourceId -Value $ResourceId
            if ($OutputFormat -eq 'Text') { Write-Host "正在启动所选资源的异步登录检测……" }
            $queued = Start-PMLoginStateDetectionAsync -ResourceId $id
            if (-not [bool]$queued.started) {
                throw (New-PMStructuredException -ErrorCode 'LOGIN_DETECTION_IN_FLIGHT' `
                    -Message ([string]$queued.message) `
                    -NextAction '等待当前登录状态检测完成后再检查，或执行取消检测后重试。')
            }
            if ($OutputFormat -eq 'Json') {
                $queued | Add-Member -MemberType NoteProperty -Name timingSummary -Value ([pscustomobject]@{
                    totalMs = [int64]$actionStopwatch.ElapsedMilliseconds
                    storageInitializationMs = $script:StorageInitializationMs
                    stages = @([pscustomobject]@{ name = 'login-check-enqueue'; elapsedMs = [int64]$actionStopwatch.ElapsedMilliseconds })
                }) -Force
                Write-PMJsonResult -Success $true -Message '登录状态检测已异步启动。' -Data $queued
            }
            else {
                Write-Host "登录状态检测：$($queued.message)"
            }
        }
        'CancelLoginCheck' {
            $id = Resolve-PMResourceId -Value $ResourceId
            $cancelled = Stop-PMLoginDetectorProcess -RuntimeRoot (Get-PMRuntimeRoot) -ResourceId $id
            if ($cancelled.cancelled) {
                try {
                    $resource = Get-PMResourceById -ResourceId $id
                    $resource.lastStatus.loginDetectionState = '检测失败'
                    $resource.lastStatus.loginDetectionErrorCode = 'LOGIN_DETECTION_CANCELLED'
                    $resource.lastStatus.loginDetectionSource = 'bsclaw.login-state-detector'
                    $resource.lastStatus.lastError = '登录状态检测已取消。'
                    $resource.lastStatus.nextLoginDetectionAt = ([DateTimeOffset]::Now.AddSeconds(60)).ToString('o')
                    Save-PMResourceStatus -ResourceId $id -Status $resource.lastStatus
                    Write-PMAudit -Action 'LoginDetectionCancel' -ResourceId $id -Outcome 'Cancelled' -Message '登录状态检测已取消，工作进程已回收。' -Details @{ attemptId = if ($null -eq $cancelled.record) { $null } else { [string]$cancelled.record.attemptId }; processId = if ($null -eq $cancelled.record) { $null } else { [int]$cancelled.record.processId } }
                }
                catch { }
            }
            if ($OutputFormat -eq 'Json') {
                Write-PMJsonResult -Success $true -Message '登录状态检测已取消。' -Data $cancelled
            }
            else {
                Write-Host "资源 $id：$($cancelled.message)"
            }
        }
        default {
            throw "不支持的操作：$SelectedAction"
        }
    }
}

function Show-PMMenu {
    while ($true) {
        Clear-Host
        Write-Host 'BSClaw 慧策通端口管理（第一阶段）'
        Write-Host ''
        Write-Host '1. 注册慧策通端口'
        Write-Host '2. 查看端口列表'
        Write-Host '3. 查看端口详情'
        Write-Host '4. 编辑端口'
        Write-Host '5. 删除端口'
        Write-Host '6. 检测端口状态'
        Write-Host '7. 打开指定慧策通端口'
        Write-Host '8. 检查全部端口'
        Write-Host '9. 清理端口环境'
        Write-Host '0. 退出程序'
        Write-Host ''
        $choice = Read-PMUserInput -Prompt '请选择操作'
        if ($null -eq $choice -or ([Console]::IsInputRedirected -and [string]::IsNullOrWhiteSpace([string]$choice))) {
            Write-Host '标准输入已结束，程序安全退出。'
            return
        }
        $choice = ([string]$choice).Trim().TrimStart([char]0xFEFF)
        if ($choice -match '([0-9])\s*$') {
            $choice = $Matches[1]
        }
        if ($choice -eq '0') {
            Write-Host '已退出程序。'
            return
        }
        try {
            switch ($choice) {
                '1' { Invoke-PMAction -SelectedAction 'Register' }
                '2' { Invoke-PMAction -SelectedAction 'List' }
                '3' { Invoke-PMAction -SelectedAction 'Detail' }
                '4' { Invoke-PMAction -SelectedAction 'Edit' }
                '5' { Invoke-PMAction -SelectedAction 'Delete' }
                '6' { Invoke-PMAction -SelectedAction 'Check' }
                '7' { Invoke-PMAction -SelectedAction 'Open' }
                '8' { Invoke-PMAction -SelectedAction 'CheckAll' }
                '9' { Show-PMEnvironmentMaintenanceMenu }
                default { Write-Host '输入无效，请输入 0 到 9。' }
            }
        }
        catch {
            $message = $_.Exception.Message
            Write-Host "操作失败：$message"
            Write-Host "下一步：$(Get-PMErrorNextActionOutput -Message $message -ErrorRecord $_)"
        }
        if ([Console]::IsInputRedirected) {
            Write-Host '标准输入已结束，程序安全退出。'
            return
        }
        $null = Read-PMUserInput -Prompt '按回车键返回菜单'
    }
}

try {
    if ($Action -eq 'Menu') {
        Show-PMMenu
    }
    else {
        Invoke-PMAction -SelectedAction $Action
    }
    exit 0
}
catch {
    if ($OutputFormat -eq 'Json') {
        $message = $_.Exception.Message
        Write-PMJsonResult -Success $false -Message $message -Data $null `
            -NextAction (Get-PMErrorNextActionOutput -Message $message -ErrorRecord $_) -ErrorRecord $_
    }
    else {
        $message = $_.Exception.Message
        Write-Host "操作失败：$message"
        Write-Host "下一步：$(Get-PMErrorNextActionOutput -Message $message -ErrorRecord $_)"
    }
    exit 1
}
