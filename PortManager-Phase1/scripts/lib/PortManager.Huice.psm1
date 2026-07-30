Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Net.Http

function Get-PMHuiceAdapterDefaults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $adapterPath = Join-Path $ProjectRoot 'adapter\bsclaw-port-adapter.json'
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
        throw "慧策通适配清单不存在：$adapterPath"
    }

    $adapter = [IO.File]::ReadAllText($adapterPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($null -eq $adapter.huiceAdapter) {
        throw '慧策通适配清单缺少 huiceAdapter 默认配置。'
    }

    $defaults = $adapter.huiceAdapter
    if (
        [string]::IsNullOrWhiteSpace([string]$defaults.defaultStartUrl) -or
        @($defaults.platformUrlPatterns).Count -eq 0 -or
        @($defaults.loginPagePatterns).Count -eq 0
    ) {
        throw '慧策通适配清单的页面地址或识别规则不完整。'
    }

    return [pscustomobject]@{
        PlatformName = if ([string]::IsNullOrWhiteSpace([string]$defaults.displayName)) { '慧策通' } else { [string]$defaults.displayName }
        StartUrl = [string]$defaults.defaultStartUrl
        PlatformUrlPatterns = @($defaults.platformUrlPatterns | ForEach-Object { [string]$_ })
        LoginPagePatterns = @($defaults.loginPagePatterns | ForEach-Object { [string]$_ })
        LoginStates = @(
            if ($null -ne $defaults.loginDetection) {
                $defaults.loginDetection.states | ForEach-Object { [string]$_ }
            }
        )
        AuthenticatedEvidenceRules = @(
            if ($null -ne $defaults.loginDetection) {
                $defaults.loginDetection.authenticatedEvidenceRules
            }
        )
        LoginDetection = if ($null -ne $defaults.loginDetection) { $defaults.loginDetection } else { $null }
        LoginEvidenceVersion = if ($null -ne $defaults.loginDetection) {
            [string]$defaults.loginDetection.evidenceVersion
        }
        else { '1' }
    }
}

function Get-PMChromeExecutable {
    [CmdletBinding()]
    param()

    $candidates = [Collections.Generic.List[string]]::new()
    $runningChrome = @(
        Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) }
    )
    foreach ($process in $runningChrome) {
        $candidates.Add([string]$process.ExecutablePath)
    }

    $registryKeys = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )
    foreach ($registryKey in $registryKeys) {
        try {
            $registryPath = [string](Get-Item -LiteralPath $registryKey -ErrorAction Stop).GetValue('')
            if (-not [string]::IsNullOrWhiteSpace($registryPath)) {
                $candidates.Add($registryPath)
            }
        }
        catch {
            # Chrome 未通过该注册表入口安装时继续检查其他真实入口。
        }
    }

    $chromeCommand = Get-Command chrome.exe -ErrorAction SilentlyContinue
    if ($null -ne $chromeCommand -and -not [string]::IsNullOrWhiteSpace([string]$chromeCommand.Source)) {
        $candidates.Add([string]$chromeCommand.Source)
    }
    foreach ($knownPath in @(
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
    )) {
        $candidates.Add($knownPath)
    }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $fullPath = try { [IO.Path]::GetFullPath($candidate.Trim('"')) } catch { $null }
        if (
            -not [string]::IsNullOrWhiteSpace($fullPath) -and
            [IO.Path]::GetFileName($fullPath) -ieq 'chrome.exe' -and
            $seen.Add($fullPath) -and
            (Test-Path -LiteralPath $fullPath -PathType Leaf)
        ) {
            return $fullPath
        }
    }
    return $null
}

function Get-PMAvailableLocalPort {
    [CmdletBinding()]
    param()

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Invoke-PMLocalJsonRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [int]$TimeoutMilliseconds = 1000
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMilliseconds)
    try {
        $text = $client.GetStringAsync($Uri).GetAwaiter().GetResult()
        return $text | ConvertFrom-Json
    }
    catch {
        return $null
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Test-PMHuiceTarget {
    param(
        [object]$Target,
        [string[]]$PlatformUrlPatterns
    )

    $url = [string]$Target.url
    $title = [string]$Target.title
    foreach ($pattern in @($PlatformUrlPatterns)) {
        if ($url -like $pattern -or $title -like $pattern) {
            return $true
        }
    }
    return $false
}

function Get-PMChromeDebugEndpoints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$PlatformUrlPatterns
    )

    # 优先从真实 Chrome 命令行读取调试端口，避免对整机监听端口做高噪声扫描。
    $candidates = [Collections.Generic.List[object]]::new()
    $chromeProcesses = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue)
    foreach ($process in $chromeProcesses) {
        $commandLine = [string]$process.CommandLine
        $portMatch = [regex]::Match($commandLine, '--remote-debugging-port=(\d+)')
        if ($portMatch.Success) {
            $candidates.Add([pscustomobject]@{
                LocalPort = [int]$portMatch.Groups[1].Value
                OwningProcess = [int]$process.ProcessId
                Process = $process
            })
        }
    }
    if ($candidates.Count -eq 0) {
        try {
            $fallback = @(
                Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.LocalAddress -in @('127.0.0.1', '::1', '0.0.0.0', '::') -and
                        [int]$_.LocalPort -gt 0
                    } | Select-Object -First 32
            )
            foreach ($connection in $fallback) {
                $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$connection.OwningProcess)" -ErrorAction SilentlyContinue
                if ($null -ne $process -and [string]$process.Name -ieq 'chrome.exe') {
                    $candidates.Add([pscustomobject]@{
                        LocalPort = [int]$connection.LocalPort
                        OwningProcess = [int]$connection.OwningProcess
                        Process = $process
                    })
                }
            }
        }
        catch {
            return @()
        }
    }

    $results = @()
    $seenPorts = [Collections.Generic.HashSet[int]]::new()
    foreach ($connection in $candidates) {
        $port = [int]$connection.LocalPort
        if (-not $seenPorts.Add($port)) {
            continue
        }

        $process = $connection.Process
        if ($null -eq $process -or [string]$process.Name -ine 'chrome.exe') {
            continue
        }

        $version = Invoke-PMLocalJsonRequest -Uri "http://127.0.0.1:$port/json/version"
        if (
            $null -eq $version -or
            [string]::IsNullOrWhiteSpace([string]$version.Browser) -or
            [string]$version.Browser -match 'Edg/'
        ) {
            continue
        }

        $targets = Invoke-PMLocalJsonRequest -Uri "http://127.0.0.1:$port/json/list"
        $pages = @(
            if ($null -ne $targets) {
                $targets | Where-Object { [string]$_.type -eq 'page' }
            }
        )
        $huicePages = @($pages | Where-Object { Test-PMHuiceTarget -Target $_ -PlatformUrlPatterns $PlatformUrlPatterns })
        $results += [pscustomobject]@{
            Port = $port
            ProcessId = [int]$connection.OwningProcess
            ExecutablePath = [string]$process.ExecutablePath
            Browser = [string]$version.Browser
            ProtocolVersion = [string]$version.'Protocol-Version'
            Pages = @($pages)
            HuicePages = @($huicePages)
            HasHuicePage = ($huicePages.Count -gt 0)
        }
    }

    return @($results | Sort-Object @{ Expression = 'HasHuicePage'; Descending = $true }, Port)
}

function Get-PMStatusNextAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Status,
        [object]$Resource
    )

    if ([string]$Status.connectionStatus -eq '端口冲突') {
        return '关闭占用该端口的其他程序，或编辑资源改用其他端口后再检查。'
    }
    if ([string]$Status.connectionStatus -eq '不可连接') {
        if ($null -ne $Resource -and [string]$Resource.connectionMode -eq 'Launch') {
            return '选择“打开指定慧策通端口”，由程序启动 Chrome 并再次检查。'
        }
        return '重新注册并选择“自动启动 Chrome”，或先打开带调试入口的慧策通 Chrome。'
    }
    if ([string]$Status.browserStatus -ne '浏览器可连接') {
        return '确认 Google Chrome 已启动；自动启动资源可直接执行“打开指定慧策通端口”。'
    }
    if ([string]$Status.pageStatus -in @('平台页面错误', '未发现页面', '页面状态未知')) {
        return '执行“打开指定慧策通端口”，让程序打开慧策通页面后再检查。'
    }
    if ([string]$Status.loginStatus -eq '未登录') {
        return '在已打开的 Chrome 中完成慧策通登录，然后重新检查。'
    }
    if ([string]$Status.loginStatus -eq '登录已失效') {
        return '慧策会话已经失效，请重新登录后再次检查。'
    }
    if ([string]$Status.loginStatus -eq '检测失败') {
        return '保留当前错误信息，确认 Chrome 页面稳定后重新检查。'
    }
    if ([string]$Status.loginStatus -eq '登录状态未知') {
        return '在 Chrome 中确认账号状态；没有真实鉴权证据前程序不会判定为已登录。'
    }
    return '当前检查已完成，可继续使用该资源。'
}

function Get-PMErrorNextAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Message -match '租约|正在执行|活动监听|占用端口|端口冲突|监听进程|PID\s*\d+') {
        return '关闭占用端口的进程或等待当前操作完成并释放资源；必要时改用其他端口。'
    }
    if ($Message -match '删除确认|必须准确输入|确认失败') {
        return '重新执行删除，并按提示准确输入当前资源编号对应的“删除 HCP-XXXXXXXX”。'
    }
    if ($Message -match 'Chrome|chrome\.exe|浏览器可执行文件') {
        return '确认已安装 Google Chrome；若使用便携版，请在高级设置中选择真实 chrome.exe。'
    }
    if ($Message -match '页面错误|页面打开失败|未发现页面') {
        return '确认网络可用，并在 Chrome 中打开慧策通页面后重新检查。'
    }
    if ($Message -match '登录') {
        return '在 Chrome 中完成慧策通登录，然后重新执行检查。'
    }
    if ($Message -match '超时|不可连接|调试接口') {
        return '确认 Chrome 正在运行后重试；仍失败时重新注册并选择“自动启动 Chrome”。'
    }
    if ($Message -match '资源编号|不存在') {
        return '先查看端口列表，再选择其中的资源重试。'
    }
    return '根据失败原因修正当前配置后重试；如仍失败，请保留错误文字和日志时间。'
}

Export-ModuleMember -Function @(
    'Get-PMHuiceAdapterDefaults',
    'Get-PMChromeExecutable',
    'Get-PMAvailableLocalPort',
    'Get-PMChromeDebugEndpoints',
    'Get-PMStatusNextAction',
    'Get-PMErrorNextAction'
)
