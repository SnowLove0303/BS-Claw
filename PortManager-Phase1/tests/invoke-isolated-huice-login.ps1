[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceId,

    [Parameter(Mandatory = $true)]
    [string]$CredentialFile,

    [switch]$ConfirmServiceAgreement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compatibility harness only. RedirectStandardInput selects a different input
# branch from the user's Read-Host flow, so this result is not the authoritative
# acceptance verdict for interactive Login.

function Get-SafeProperty {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $null
}

function Get-FirstHuiceTestCredential {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetPathRoot($fullPath) -notlike 'F:\') {
        throw '隔离验收凭据文件必须位于 F 盘。'
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw '隔离验收凭据文件不存在。'
    }

    $values = @{}
    foreach ($rawLine in [IO.File]::ReadAllLines($fullPath, [Text.UTF8Encoding]::new($false))) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^测试账号2') { break }

        $match = [regex]::Match($line, '^\s*([^：:=]+?)\s*[：:=]\s*(.*)$')
        if (-not $match.Success) { continue }
        $label = $match.Groups[1].Value.Trim()
        $value = $match.Groups[2].Value.Trim()
        if ($label -in @('企业账号', '用户账户', '密码') -and -not $values.ContainsKey($label)) {
            $values[$label] = $value
        }
    }

    foreach ($required in @('企业账号', '用户账户', '密码')) {
        if (-not $values.ContainsKey($required) -or [string]::IsNullOrWhiteSpace([string]$values[$required])) {
            throw "第一组测试凭据缺少字段：$required"
        }
    }

    return [pscustomobject]@{
        tenantId = [string]$values['企业账号']
        account = [string]$values['用户账户']
        password = [string]$values['密码']
    }
}

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$agentPath = [IO.Path]::GetFullPath((Join-Path $projectRoot '..\HuiceLoginAgent\login-agent.ps1'))
if (-not (Test-Path -LiteralPath $agentPath -PathType Leaf)) {
    throw '慧策登录适配器不存在。'
}

$credential = $null
$process = $null
try {
    # This is an isolated acceptance harness only. Production credentials must
    # come from PortManager CredentialRef and a controlled in-memory provider.
    $credential = Get-FirstHuiceTestCredential -Path $CredentialFile
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $agreementArgument = if ($ConfirmServiceAgreement) { ' -ConfirmServiceAgreement' } else { '' }
    $startInfo.Arguments = "-NoP -EP Bypass -File `"$agentPath`" -Action Login -ResourceId $ResourceId -OutputFormat Json$agreementArgument"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw '慧策 Login 验收进程启动失败。' }

    $process.StandardInput.WriteLine($credential.tenantId)
    $process.StandardInput.WriteLine($credential.account)
    $process.StandardInput.WriteLine($credential.password)
    $process.StandardInput.Close()

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $result = $stdout.Trim() | ConvertFrom-Json
    $data = $result.data
    $auth = if ($null -ne $data -and
        $data.PSObject.Properties.Name -contains 'authResult') { $data.authResult } else { $null }
    $loginResult = if ($null -ne $data -and
        $data.PSObject.Properties.Name -contains 'loginHttpResult') { $data.loginHttpResult } elseif ($null -ne $auth) { $auth } else { $null }

    [ordered]@{
        testScope = 'redirected-stdin-credential-transport-compatibility'
        authoritativeUserAcceptance = $false
        userAcceptanceEntry = 'Use login-agent.ps1 with Read-Host on a new isolated resource.'
        success = [bool]$result.success
        message = [string]$result.message
        errorCode = if ($null -eq $result.errorCode) { $null } else { [string]$result.errorCode }
        resourceId = $ResourceId
        exitCode = [int]$process.ExitCode
        status = if ($null -eq $data) { $null } else { [string]$data.status }
        refreshHttpStatus = Get-SafeProperty $auth 'refreshHttpStatus'
        probeHttpStatus = Get-SafeProperty $auth 'probeHttpStatus'
        requiredProbeFieldsPresent = Get-SafeProperty $auth 'requiredProbeFieldsPresent'
        loginHttp = if ($null -eq $loginResult) {
            $null
        } else {
            [ordered]@{
                status = if ($loginResult.PSObject.Properties.Name -contains 'status') { [string]$loginResult.status } else { $null }
                errorCode = if ($loginResult.PSObject.Properties.Name -contains 'errorCode') { $loginResult.errorCode } else { $null }
                loginTransport = Get-SafeProperty $loginResult 'loginTransport'
                riskHttpStatus = Get-SafeProperty $loginResult 'riskHttpStatus'
                riskResponseCode = Get-SafeProperty $loginResult 'riskResponseCode'
                loginHttpStatus = Get-SafeProperty $loginResult 'loginHttpStatus'
                loginResponseCode = Get-SafeProperty $loginResult 'loginResponseCode'
                verificationRequired = Get-SafeProperty $loginResult 'verificationRequired'
            }
        }
        stderrPresent = -not [string]::IsNullOrWhiteSpace($stderr)
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($null -ne $credential) {
        $credential.tenantId = ''
        $credential.account = ''
        $credential.password = ''
        $credential = $null
    }
}
