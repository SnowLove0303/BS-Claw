Set-StrictMode -Version Latest

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Resolve-BSClawTestPython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $message = 'BS-Claw 测试与诊断需要 F 盘 Python（含 sqlite3）。请在当前 PowerShell 会话执行：$env:BSCLAW_PYTHON_PATH=''F:\你的Python目录\python.exe''；或将解释器放到 PortManager-Phase1\tools\python\python.exe 后重试。'
    $configured = [Environment]::GetEnvironmentVariable('BSCLAW_PYTHON_PATH', 'Process')
    $projectPython = Join-Path ([IO.Path]::GetFullPath($ProjectRoot)) 'tools\python\python.exe'
    $candidates = @($configured, $projectPython) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique

    foreach ($candidate in $candidates) {
        try {
            $fullPath = [IO.Path]::GetFullPath([string]$candidate)
        }
        catch {
            continue
        }
        if ([IO.Path]::GetPathRoot($fullPath) -notlike 'F:\') { continue }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }

        $previousNoByteCode = [Environment]::GetEnvironmentVariable('PYTHONDONTWRITEBYTECODE', 'Process')
        try {
            $env:PYTHONDONTWRITEBYTECODE = '1'
            & $fullPath -c 'import sqlite3' 2>$null
            if ($LASTEXITCODE -eq 0) {
                return $fullPath
            }
        }
        finally {
            if ($null -eq $previousNoByteCode) {
                [Environment]::SetEnvironmentVariable('PYTHONDONTWRITEBYTECODE', $null, 'Process')
            }
            else {
                $env:PYTHONDONTWRITEBYTECODE = $previousNoByteCode
            }
        }
    }

    throw $message
}
