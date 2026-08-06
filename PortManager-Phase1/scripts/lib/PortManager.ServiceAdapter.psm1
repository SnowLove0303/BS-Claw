Set-StrictMode -Version Latest

function Resolve-PMServicePython {
    $configured = [Environment]::GetEnvironmentVariable('BSCLAW_PYTHON_PATH', 'Process')
    $projectRoot = Get-PMProjectRoot
    $candidates = @(
        $configured,
        (Join-Path $projectRoot 'tools\python\python.exe'),
        'F:\AIAPP\Codex\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    foreach ($candidate in $candidates) {
        $resolved = [IO.Path]::GetFullPath([string]$candidate)
        if (
            [IO.Path]::GetPathRoot($resolved) -like 'F:\' -and
            (Test-Path -LiteralPath $resolved -PathType Leaf)
        ) {
            return $resolved
        }
    }
    throw (New-PMStructuredException -ErrorCode 'PM_PYTHON_F_DRIVE_REQUIRED' `
        -Message '端口管理服务自检需要 F 盘 Python。' `
        -NextAction '在当前 PowerShell 会话设置 BSCLAW_PYTHON_PATH 为 F 盘 python.exe 后重试。')
}

function Invoke-PMServiceCheck {
    [CmdletBinding()]
    param()

    $projectRoot = Get-PMProjectRoot
    $databasePath = Join-Path $projectRoot 'data\port-manager.sqlite3'
    $servicePath = Join-Path $projectRoot 'scripts\sqlite_service.py'
    if (-not (Test-Path -LiteralPath $databasePath -PathType Leaf)) {
        throw (New-PMStructuredException -ErrorCode 'PM_DATABASE_NOT_FOUND' `
            -Message '端口管理 SQLite 事实源不存在。' `
            -NextAction '先通过端口管理正式初始化流程创建空数据事实源。')
    }
    $pythonPath = Resolve-PMServicePython
    $output = & $pythonPath -B $servicePath --action integrity_check --db $databasePath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (New-PMStructuredException -ErrorCode 'PM_SQLITE_INTEGRITY_CHECK_FAILED' `
            -Message 'SQLite 只读完整性检查执行失败。' `
            -NextAction '保留错误时间并检查 F 盘 Python 与数据库文件权限。')
    }
    try {
        $integrity = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        throw (New-PMStructuredException -ErrorCode 'PM_SQLITE_INTEGRITY_OUTPUT_INVALID' `
            -Message 'SQLite 只读完整性检查未返回有效 JSON。' `
            -NextAction '检查 sqlite_service.py 与 Python 版本后重试。')
    }
    $resources = @(Get-PMResources)
    return [pscustomobject][ordered]@{
        serviceId = 'port-manager'
        entryAvailable = $true
        jsonContract = 'single-document'
        resourceCount = $resources.Count
        sqliteIntegrity = [string]$integrity.integrity
        schemaVersion = [int]$integrity.schemaVersion
        checkedAt = [DateTimeOffset]::Now.ToString('o')
        readOnly = $true
    }
}

Export-ModuleMember -Function @('Invoke-PMServiceCheck')
