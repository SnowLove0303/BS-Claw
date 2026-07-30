Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Net.Http

function New-PMResourceId {
    return 'HCP-' + ([Guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant())
}

function Assert-PMPort {
    param([int]$Port)
    if ($Port -lt 1 -or $Port -gt 65535) {
        throw '端口号必须是 1 到 65535 之间的整数。'
    }
}

function Assert-PMHost {
    param([string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) {
        throw '主机地址不能为空。'
    }
    $hostKind = [Uri]::CheckHostName($HostName)
    if ($hostKind -eq [UriHostNameType]::Unknown -and $HostName -ne 'localhost') {
        throw "主机地址格式无效：$HostName"
    }
}

function Assert-PMUrl {
    param([string]$Url, [string]$FieldName)
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
        throw "$FieldName 必须是完整的 HTTP 或 HTTPS 地址。"
    }
}

function Test-PMLoopbackHost {
    param([string]$HostName)
    return $HostName -in @('127.0.0.1', 'localhost', '::1')
}

function Test-PMPrivateIpAddress {
    param([Parameter(Mandatory = $true)][Net.IPAddress]$Address)
    if ([Net.IPAddress]::IsLoopback($Address)) { return $true }
    if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
        $bytes = $Address.GetAddressBytes()
        return (
            $bytes[0] -eq 10 -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
            ($bytes[0] -eq 169 -and $bytes[1] -eq 254)
        )
    }
    $ipv6Bytes = $Address.GetAddressBytes()
    return $Address.IsIPv6LinkLocal -or (($ipv6Bytes[0] -band 0xFE) -eq 0xFC)
}

function Assert-PMControlHost {
    param([string]$HostName)
    if ($HostName -eq 'localhost') { return }
    $address = $null
    if (-not [Net.IPAddress]::TryParse($HostName, [ref]$address)) {
        throw '主机地址只允许 localhost 或明确的 IP 地址，禁止使用可发生 DNS 重绑定的远程主机名。'
    }
    if (-not (Test-PMPrivateIpAddress -Address $address)) {
        throw '远程主机只允许回环、RFC1918 私网、链路本地或 IPv6 ULA 地址；禁止访问公网 CDP 地址。'
    }
}

function ConvertTo-PMPatternArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        return @($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    return @($Value | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

function Test-PMPatternMatch {
    param([string]$Value, [object]$Patterns)
    foreach ($pattern in (ConvertTo-PMPatternArray -Value $Patterns)) {
        if ($Value -like $pattern) { return $true }
    }
    return $false
}

function Get-PMUriHost {
    param([string]$HostName)
    if ($HostName.Contains(':') -and -not $HostName.StartsWith('[')) { return "[$HostName]" }
    return $HostName
}

function Get-PMBaseUri {
    param([string]$HostName, [int]$Port)
    return 'http://{0}:{1}' -f (Get-PMUriHost -HostName $HostName), $Port
}

function Test-PMTcpConnection {
    param([string]$HostName, [int]$Port, [int]$TimeoutMilliseconds = 1500)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return [pscustomobject]@{ Connected = $false; Error = '连接超时' }
        }
        $client.EndConnect($asyncResult)
        return [pscustomobject]@{ Connected = $true; Error = $null }
    }
    catch {
        return [pscustomobject]@{ Connected = $false; Error = $_.Exception.Message }
    }
    finally { $client.Dispose() }
}

function Get-PMPortOwners {
    param([int]$Port)
    $owners = @()
    $command = Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        try {
            $connections = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { [int]$_.LocalPort -eq $Port })
            foreach ($connection in $connections) {
                $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
                $owners += [pscustomobject]@{
                    ProcessId = [int]$connection.OwningProcess
                    ProcessName = if ($null -eq $process) { '未知进程' } else { $process.ProcessName }
                    ExecutablePath = if ($null -eq $process) { $null } else { $process.Path }
                    LocalAddress = [string]$connection.LocalAddress
                }
            }
            return @($owners)
        }
        catch {
            # netstat is the deterministic Windows PowerShell 5 fallback.
        }
    }
    $lines = @(& netstat.exe -ano -p tcp 2>$null)
    foreach ($line in $lines) {
        if ($line -match '^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$' -and [int]$Matches[2] -eq $Port) {
            $ownerPid = [int]$Matches[3]
            $process = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
            $owners += [pscustomobject]@{
                ProcessId = $ownerPid
                ProcessName = if ($null -eq $process) { '未知进程' } else { $process.ProcessName }
                ExecutablePath = if ($null -eq $process) { $null } else { $process.Path }
                LocalAddress = $Matches[1]
            }
        }
    }
    return @($owners)
}

function Invoke-PMHttpRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [ValidateSet('GET', 'PUT')][string]$Method = 'GET',
        [int]$TimeoutSeconds = 3
    )
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{
            Responded = $true
            StatusCode = [int]$response.StatusCode
            IsSuccess = $response.IsSuccessStatusCode
            Body = $body
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Responded = $false
            StatusCode = $null
            IsSuccess = $false
            Body = $null
            Error = $_.Exception.Message
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-PMJsonRequest {
    param(
        [string]$Uri,
        [ValidateSet('GET', 'PUT')][string]$Method = 'GET',
        [int]$TimeoutSeconds = 3
    )
    $response = Invoke-PMHttpRequest -Uri $Uri -Method $Method -TimeoutSeconds $TimeoutSeconds
    $json = $null
    if ($response.Responded -and -not [string]::IsNullOrWhiteSpace($response.Body)) {
        try { $json = $response.Body | ConvertFrom-Json }
        catch { $response.Error = '响应不是有效 JSON：' + $_.Exception.Message }
    }
    return [pscustomobject]@{ Response = $response; Json = $json }
}

Export-ModuleMember -Function @(
    'New-PMResourceId', 'Assert-PMPort', 'Assert-PMHost', 'Assert-PMUrl',
    'Test-PMLoopbackHost', 'Test-PMPrivateIpAddress', 'Assert-PMControlHost',
    'ConvertTo-PMPatternArray', 'Test-PMPatternMatch', 'Get-PMUriHost',
    'Get-PMBaseUri', 'Test-PMTcpConnection', 'Get-PMPortOwners',
    'Invoke-PMHttpRequest', 'Invoke-PMJsonRequest'
)
