[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$localRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path $localRoot -Parent))
$entryScript = Join-Path $localRoot 'bsclaw.py'
$candidates = @(
    [Environment]::GetEnvironmentVariable('BSCLAW_PYTHON_PATH', 'Process'),
    (Join-Path $localRoot 'tools\python\python.exe'),
    (Join-Path $repositoryRoot 'PortManager-Phase1\tools\python\python.exe')
)

function Test-FDrivePython {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    try {
        $resolved = [IO.Path]::GetFullPath($Path)
        return (
            [IO.Path]::GetPathRoot($resolved) -like 'F:\' -and
            (Test-Path -LiteralPath $resolved -PathType Leaf)
        )
    }
    catch {
        return $false
    }
}

if ([IO.Path]::GetPathRoot($localRoot) -notlike 'F:\') {
    [Console]::Error.WriteLine('BS Claw 本地层必须从 F 盘运行。')
    exit 2
}
if (-not (Test-Path -LiteralPath $entryScript -PathType Leaf)) {
    [Console]::Error.WriteLine('BS Claw 本地层入口不完整，请检查 BSClaw-Local 目录。')
    exit 2
}

$pythonPath = $null
foreach ($candidate in $candidates) {
    if (Test-FDrivePython -Path $candidate) {
        $pythonPath = [IO.Path]::GetFullPath($candidate)
        break
    }
}
if ($null -eq $pythonPath) {
    $prepareScript = Join-Path $localRoot 'prepare-python.ps1'
    [Console]::Error.WriteLine(
        '未找到 F 盘 Python。请执行：powershell -NoP -EP Bypass -File "' +
        $prepareScript + '"；完成后重新运行 BS Claw。已有 F 盘 Python 也可在当前会话设置：' +
        '$env:BSCLAW_PYTHON_PATH=''F:\你的Python目录\python.exe'''
    )
    exit 2
}

$env:BSCLAW_PYTHON_PATH = $pythonPath
$env:PYTHONDONTWRITEBYTECODE = '1'
& $pythonPath -B $entryScript @Arguments
exit $LASTEXITCODE
