Set-StrictMode -Version Latest

function Invoke-HuiceSecureLoginBridge {
    param(
        [Parameter(Mandatory = $true)][string]$WebSocketUrl,
        [Parameter(Mandatory = $true)]$Credential,
        [ValidateSet('login')][string]$Mode = 'login'
    )
    $node = 'E:\MorenAnzhuangLujing\Huangjingdajian\Nodejs\node.exe'
    $bridge = Join-Path $PSScriptRoot 'secure_login_bridge.js'
    if (-not (Test-Path -LiteralPath $node -PathType Leaf)) { throw 'F/E drive Node runtime unavailable' }
    $bstr = [IntPtr]::Zero
    $plainPassword = $null
    $json = $null
    $wirePayload = $null
    $process = $null
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.securePassword)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $json = @{
            mode = $Mode
            webSocketUrl = $WebSocketUrl
            tenantId = [string]$Credential.tenantId
            account = [string]$Credential.account
            password = $plainPassword
            serviceAgreementConfirmed = [bool]$Credential.serviceAgreementConfirmed
        } | ConvertTo-Json -Compress
        $wirePayload = 'B64:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $node
        $start.Arguments = '"' + $bridge + '"'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        if (-not $process.Start()) { throw '无法启动安全登录桥' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($wirePayload)
        $process.StandardInput.Close()
        $wirePayload = $null
        $json = $null
        $plainPassword = $null
        if (-not $process.WaitForExit(35000)) {
            try { $process.Kill() } catch {}
            try { $process.WaitForExit(5000) | Out-Null } catch {}
            throw '安全登录桥执行超时'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $null = $stderrTask.GetAwaiter().GetResult()
        if ([string]::IsNullOrWhiteSpace($stdout)) { throw '安全登录桥无输出' }
        $result = $stdout | ConvertFrom-Json
        if ($process.ExitCode -ne 0 -or -not [bool]$result.ok) {
            $code = if ($result.PSObject.Properties.Name -contains 'errorCode') { [string]$result.errorCode } else { 'SECURE_LOGIN_BRIDGE_FAILED' }
            $detail = if ($result.PSObject.Properties.Name -contains 'detail' -and -not [string]::IsNullOrWhiteSpace([string]$result.detail)) {
                ([string]$result.detail) -replace '(?i)(password|passwd|cookie|token|authorization|bearer)\s*[:=]\s*\S+','$1=[已脱敏]'
            } else {
                $null
            }
            $message = if ([string]::IsNullOrWhiteSpace($detail)) { $code } else { "$code`: $detail" }
            $exception = [InvalidOperationException]::new($message)
            $exception.Data['errorCode'] = $code
            if (-not [string]::IsNullOrWhiteSpace($detail)) { $exception.Data['diagnostic'] = $detail }
            throw $exception
        }
        return $result.value
    }
    finally {
        $wirePayload = $null
        $json = $null
        $plainPassword = $null
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Invoke-HuicePasswordLogin {
    param(
        [Parameter(Mandatory = $true)]$Resource,
        [Parameter(Mandatory = $true)]$Credential,
        [ValidateSet('login')][string]$Mode = 'login'
    )
    $page = Get-HuicePageTarget $Resource
    return Invoke-HuiceSecureLoginBridge -WebSocketUrl ([string]$page.webSocketDebuggerUrl) -Credential $Credential -Mode $Mode
}

function Invoke-HuiceHttpLogin {
    param(
        [Parameter(Mandatory = $true)]$Resource,
        [Parameter(Mandatory = $true)]$Credential
    )
    return Invoke-HuicePasswordLogin -Resource $Resource -Credential $Credential
}

function Invoke-HuiceWebFormLogin {
    param(
        [Parameter(Mandatory = $true)]$Resource,
        [Parameter(Mandatory = $true)]$Credential
    )
    return Invoke-HuicePasswordLogin -Resource $Resource -Credential $Credential
}

Export-ModuleMember -Function Invoke-HuiceSecureLoginBridge,Invoke-HuicePasswordLogin,Invoke-HuiceHttpLogin,Invoke-HuiceWebFormLogin
