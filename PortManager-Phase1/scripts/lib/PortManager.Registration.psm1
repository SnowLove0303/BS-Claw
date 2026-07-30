Set-StrictMode -Version Latest

$huiceModule = Join-Path $PSScriptRoot 'PortManager.Huice.psm1'
Import-Module $huiceModule -Force

function Read-PMRegistrationInput {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ReadInput,
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )
    return & $ReadInput $Prompt
}

function Get-PMAdvancedRegistrationPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,
        [Parameter(Mandatory = $true)]
        [object]$AdapterDefaults,
        [Parameter(Mandatory = $true)]
        [scriptblock]$ReadInput
    )

    $values = @{}
    $allowPrompt = -not [bool]$Context.NonInteractive -and [string]$Context.OutputFormat -eq 'Text'
    $values.PlatformName = if ([string]::IsNullOrWhiteSpace([string]$Context.PlatformName)) { '慧策通' } else { [string]$Context.PlatformName }
    $values.HostName = if ([string]::IsNullOrWhiteSpace([string]$Context.HostName) -and $allowPrompt) {
        $inputHost = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt '高级设置：主机地址，直接回车使用本机'
        if ([string]::IsNullOrWhiteSpace($inputHost)) { '127.0.0.1' } else { $inputHost }
    }
    elseif ([string]::IsNullOrWhiteSpace([string]$Context.HostName)) { '127.0.0.1' }
    else { [string]$Context.HostName }
    $values.Port = if ([int]$Context.Port -eq 0 -and $allowPrompt) {
        [int](Read-PMRegistrationInput -ReadInput $ReadInput -Prompt '高级设置：请输入端口号（1-65535）')
    }
    else { [int]$Context.Port }
    $values.ConnectionMode = if ([string]::IsNullOrWhiteSpace([string]$Context.ConnectionMode) -and $allowPrompt) {
        $mode = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt '高级设置：1=使用已打开的 Chrome，2=需要时自动启动 Chrome'
        if ($mode -eq '2') { 'Launch' } else { 'ConnectOnly' }
    }
    elseif ([string]::IsNullOrWhiteSpace([string]$Context.ConnectionMode)) { 'ConnectOnly' }
    else { [string]$Context.ConnectionMode }
    $values.BrowserExecutable = [string]$Context.BrowserExecutable
    $values.BrowserProfileDirectory = [string]$Context.BrowserProfileDirectory
    if ($values.ConnectionMode -eq 'Launch') {
        if ([string]::IsNullOrWhiteSpace($values.BrowserExecutable) -and $allowPrompt) {
            $detected = Get-PMChromeExecutable
            $prompt = if ([string]::IsNullOrWhiteSpace($detected)) {
                '未自动找到 Google Chrome，请输入 chrome.exe 完整路径'
            }
            else {
                "已找到 Google Chrome，直接回车使用：$detected"
            }
            $browserInput = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt $prompt
            $values.BrowserExecutable = if ([string]::IsNullOrWhiteSpace($browserInput)) { $detected } else { $browserInput }
        }
        if ([string]::IsNullOrWhiteSpace($values.BrowserProfileDirectory) -and $allowPrompt) {
            $profileRoot = Join-Path (Split-Path -Parent ([string]$Context.ProjectRoot)) '_portmanager-profiles'
            $defaultProfile = Join-Path $profileRoot ("huice-{0}" -f $values.Port)
            $profileInput = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt "高级设置：Chrome 配置目录，直接回车由程序使用：$defaultProfile"
            $values.BrowserProfileDirectory = if ([string]::IsNullOrWhiteSpace($profileInput)) { $defaultProfile } else { $profileInput }
        }
    }

    $values.StartUrl = if (-not [string]::IsNullOrWhiteSpace([string]$Context.StartUrl)) {
        [string]$Context.StartUrl
    }
    elseif ($allowPrompt) {
        $pageInput = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt "高级设置：慧策通页面地址，直接回车使用：$($AdapterDefaults.StartUrl)"
        if ([string]::IsNullOrWhiteSpace($pageInput)) { $AdapterDefaults.StartUrl } else { $pageInput }
    }
    else { $AdapterDefaults.StartUrl }
    $values.PlatformUrlPatterns = if (-not [string]::IsNullOrWhiteSpace([string]$Context.PlatformUrlPatterns)) {
        [string]$Context.PlatformUrlPatterns
    }
    elseif ($allowPrompt) {
        $patternInput = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt '高级设置：平台识别规则，直接回车使用慧策通默认规则'
        if ([string]::IsNullOrWhiteSpace($patternInput)) { @($AdapterDefaults.PlatformUrlPatterns) } else { $patternInput }
    }
    else { @($AdapterDefaults.PlatformUrlPatterns) }
    $values.LoginPagePatterns = if (-not [string]::IsNullOrWhiteSpace([string]$Context.LoginPagePatterns)) {
        [string]$Context.LoginPagePatterns
    }
    elseif ($allowPrompt) {
        $loginInput = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt '高级设置：登录页识别规则，直接回车使用慧策通默认规则'
        if ([string]::IsNullOrWhiteSpace($loginInput)) { @($AdapterDefaults.LoginPagePatterns) } else { $loginInput }
    }
    else { @($AdapterDefaults.LoginPagePatterns) }

    $defaultName = if ($values.Port -gt 0) { "慧策通端口-$($values.Port)" } else { '慧策通端口' }
    $values.ResourceName = if ([string]::IsNullOrWhiteSpace([string]$Context.ResourceName) -and $allowPrompt) {
        $nameInput = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt "资源名称（可选），直接回车使用：$defaultName"
        if ([string]::IsNullOrWhiteSpace($nameInput)) { $defaultName } else { $nameInput }
    }
    elseif ([string]::IsNullOrWhiteSpace([string]$Context.ResourceName)) { $defaultName }
    else { [string]$Context.ResourceName }
    $values.Enabled = -not [bool]$Context.Disabled
    $values.Notes = if ($Context.InvocationParameters.ContainsKey('Notes')) { [string]$Context.Notes } else { $null }
    return $values
}

function Get-PMRegistrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,
        [Parameter(Mandatory = $true)]
        [scriptblock]$ReadInput
    )

    $allowPrompt = -not [bool]$Context.NonInteractive -and [string]$Context.OutputFormat -eq 'Text'
    $adapterDefaults = Get-PMHuiceAdapterDefaults -ProjectRoot ([string]$Context.ProjectRoot)
    $advancedParametersProvided = @(
        @(
            'HostName', 'Port', 'ConnectionMode', 'BrowserExecutable', 'BrowserProfileDirectory',
            'StartUrl', 'PlatformUrlPatterns', 'LoginPagePatterns'
        ) | Where-Object { $Context.InvocationParameters.ContainsKey($_) }
    )
    if (-not $allowPrompt -or $advancedParametersProvided.Count -gt 0) {
        return Get-PMAdvancedRegistrationPlan -Context $Context -AdapterDefaults $adapterDefaults -ReadInput $ReadInput
    }

    Write-Host '注册向导：只需选择 Chrome 使用方式，其他配置由程序自动完成。'
    Write-Host '正在查找已经打开的慧策通…'
    $endpoints = @(Get-PMChromeDebugEndpoints -PlatformUrlPatterns $adapterDefaults.PlatformUrlPatterns)
    $huiceEndpoints = @($endpoints | Where-Object { $_.HasHuicePage })
    if ($huiceEndpoints.Count -gt 0) {
        Write-Host "已发现 $($huiceEndpoints.Count) 个打开慧策通页面的 Chrome 窗口。"
        Write-Host '1. 使用已打开的慧策通（推荐）'
        Write-Host '2. 自动启动新的 Chrome'
        Write-Host '3. 高级设置'
        $choice = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt '请选择，直接回车使用 1'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '1' }
    }
    else {
        Write-Host '没有发现可直接连接的慧策通，程序可以自动创建 Chrome 运行环境。'
        Write-Host '1. 使用已打开的慧策通'
        Write-Host '2. 自动启动新的 Chrome（推荐）'
        Write-Host '3. 高级设置'
        $choice = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt '请选择，直接回车使用 2'
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '2' }
    }
    if ($choice -eq '3') {
        return Get-PMAdvancedRegistrationPlan -Context $Context -AdapterDefaults $adapterDefaults -ReadInput $ReadInput
    }
    if ($choice -eq '1' -and $huiceEndpoints.Count -eq 0) {
        Write-Host '当前没有可连接的慧策通窗口，将改用自动启动 Chrome。'
        $choice = '2'
    }

    $values = @{
        PlatformName = $adapterDefaults.PlatformName
        HostName = '127.0.0.1'
        StartUrl = $adapterDefaults.StartUrl
        PlatformUrlPatterns = @($adapterDefaults.PlatformUrlPatterns)
        LoginPagePatterns = @($adapterDefaults.LoginPagePatterns)
        Enabled = $true
        Notes = $null
    }
    if ($choice -eq '1') {
        $selected = $huiceEndpoints[0]
        if ($huiceEndpoints.Count -gt 1) {
            for ($index = 0; $index -lt $huiceEndpoints.Count; $index++) {
                $pageTitle = [string](@($huiceEndpoints[$index].HuicePages | Select-Object -First 1).title)
                Write-Host "$($index + 1). $pageTitle"
            }
            $selectedIndex = [int](Read-PMRegistrationInput -ReadInput $ReadInput -Prompt '请选择要使用的慧策通窗口') - 1
            if ($selectedIndex -lt 0 -or $selectedIndex -ge $huiceEndpoints.Count) {
                throw '没有选择有效的慧策通窗口。'
            }
            $selected = $huiceEndpoints[$selectedIndex]
        }
        $values.Port = [int]$selected.Port
        $values.ConnectionMode = 'ConnectOnly'
        $values.BrowserExecutable = if ([string]::IsNullOrWhiteSpace([string]$selected.ExecutablePath)) { $null } else { [string]$selected.ExecutablePath }
        $values.BrowserProfileDirectory = $null
    }
    elseif ($choice -eq '2') {
        $chromeExecutable = Get-PMChromeExecutable
        if ([string]::IsNullOrWhiteSpace($chromeExecutable)) {
            $chromeExecutable = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt '未自动找到 Google Chrome，请输入真实 chrome.exe 完整路径'
        }
        if (
            [string]::IsNullOrWhiteSpace($chromeExecutable) -or
            [IO.Path]::GetFileName($chromeExecutable) -ine 'chrome.exe' -or
            -not (Test-Path -LiteralPath $chromeExecutable -PathType Leaf)
        ) {
            throw '未找到可用的 Google Chrome。'
        }
        $values.Port = Get-PMAvailableLocalPort
        $values.ConnectionMode = 'Launch'
        $values.BrowserExecutable = [IO.Path]::GetFullPath($chromeExecutable)
        $profileRoot = Join-Path (Split-Path -Parent ([string]$Context.ProjectRoot)) '_portmanager-profiles'
        $values.BrowserProfileDirectory = Join-Path $profileRoot ("huice-{0}" -f $values.Port)
    }
    else {
        throw '请选择 1、2 或 3。'
    }

    $defaultName = "慧策通端口-$($values.Port)"
    $nameInput = Read-PMRegistrationInput -ReadInput $ReadInput -Prompt "资源名称（可选），直接回车使用：$defaultName"
    $values.ResourceName = if ([string]::IsNullOrWhiteSpace($nameInput)) { $defaultName } else { $nameInput }
    $values.__AutoOpenAfterRegistration = ($choice -eq '2')
    return $values
}

Export-ModuleMember -Function @(
    'Get-PMRegistrationPlan'
)
