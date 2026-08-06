Set-StrictMode -Version Latest

function Resolve-PMHuiceLoginAgent {
    $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $candidate = if (-not [string]::IsNullOrWhiteSpace($env:BSCLAW_HUICE_LOGIN_AGENT_ROOT)) {
        $env:BSCLAW_HUICE_LOGIN_AGENT_ROOT
    }
    else {
        Join-Path (Split-Path $projectRoot -Parent) 'HuiceLoginAgent'
    }
    $root = [IO.Path]::GetFullPath($candidate)
    if (-not $root.StartsWith('F:\', [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-PMStructuredException -ErrorCode 'PM_HUICE_AGENT_F_DRIVE_REQUIRED' `
            -Message '慧策登录适配器必须位于 F 盘。' `
            -NextAction '将 BSCLAW_HUICE_LOGIN_AGENT_ROOT 指向 F 盘 HuiceLoginAgent 目录。')
    }
    $entry = Join-Path $root 'login-agent.ps1'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
        throw (New-PMStructuredException -ErrorCode 'PM_HUICE_AGENT_NOT_FOUND' `
            -Message "未找到慧策登录适配器：$entry" `
            -NextAction '安装 HuiceLoginAgent，或设置 BSCLAW_HUICE_LOGIN_AGENT_ROOT 后重试。')
    }
    return [pscustomobject]@{ root = $root; entry = $entry }
}

function Invoke-PMHuiceLoginAgent {
    [CmdletBinding()]
    param(
        [ValidateSet('List', 'Check', 'Login')][string]$Action,
        [string]$ResourceId,
        [switch]$Interactive,
        [ValidateRange(20, 300)][int]$TimeoutSeconds = 210
    )
    $agent = Resolve-PMHuiceLoginAgent
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($agent.entry)`"", '-Action', $Action)
    if (-not [string]::IsNullOrWhiteSpace($ResourceId)) {
        $arguments += @('-ResourceId', $ResourceId)
    }
    if (-not $Interactive) {
        $arguments += @('-OutputFormat', 'Json', '-NonInteractive')
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'powershell.exe'
    $start.Arguments = $arguments -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = -not $Interactive
    if ($Interactive) {
        $process = [Diagnostics.Process]::Start($start)
        if ($null -eq $process) {
            throw (New-PMStructuredException -ErrorCode 'PM_HUICE_AGENT_START_FAILED' `
                -Message '无法启动慧策登录适配器。' -NextAction '检查 PowerShell 与适配器路径后重试。')
        }
        try {
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                throw (New-PMStructuredException -ErrorCode 'PM_HUICE_AGENT_FAILED' `
                    -Message "慧策登录适配器执行失败，退出码 $($process.ExitCode)。" `
                    -NextAction '按适配器中文提示修正后重试。')
            }
            return [pscustomobject]@{ action = $Action; resourceId = $ResourceId; exitCode = 0 }
        }
        finally { $process.Dispose() }
    }

    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) {
            throw (New-PMStructuredException -ErrorCode 'PM_HUICE_AGENT_START_FAILED' `
                -Message '无法启动慧策登录适配器。' -NextAction '检查 PowerShell 与适配器路径后重试。')
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw (New-PMStructuredException -ErrorCode 'PM_HUICE_AGENT_TIMEOUT' `
                -Message "慧策登录适配器在 $TimeoutSeconds 秒内未完成。" `
                -NextAction '确认 Chrome/端口状态后执行 HuiceCheck；需要输入凭据时改用交互式 HuiceLogin。')
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        $result = $null
        try { $result = $stdout | ConvertFrom-Json }
        catch {
            throw (New-PMStructuredException -ErrorCode 'PM_HUICE_AGENT_BAD_JSON' `
                -Message '慧策登录适配器未返回有效 JSON。' `
                -NextAction '检查适配器版本与输出编码后重试。')
        }
        if ($process.ExitCode -ne 0 -or -not [bool]$result.success) {
            $code = if ([string]::IsNullOrWhiteSpace([string]$result.errorCode)) { 'PM_HUICE_AGENT_FAILED' } else { [string]$result.errorCode }
            $next = if ([string]::IsNullOrWhiteSpace([string]$result.nextAction)) { '按慧策登录适配器返回的错误修正后重试。' } else { [string]$result.nextAction }
            throw (New-PMStructuredException -ErrorCode $code -Message ([string]$result.message) -NextAction $next)
        }
        return $result
    }
    finally { $process.Dispose() }
}

Export-ModuleMember -Function Resolve-PMHuiceLoginAgent, Invoke-PMHuiceLoginAgent

