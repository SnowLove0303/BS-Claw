[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$entryPath = Join-Path $projectRoot 'tests\run-static-validation.ps1'
$projectPython = Join-Path $projectRoot 'tools\python\python.exe'
$testRunsRoot = Join-Path $projectRoot 'data\test-runs'

if (Test-Path -LiteralPath $projectPython -PathType Leaf) {
    [pscustomobject]@{
        passed = $true
        skipped = $true
        reason = '项目内 F 盘 Python 已存在，不满足“无 Python 配置”前置条件。'
    } | ConvertTo-Json -Compress
    exit 0
}

$before = @()
if (Test-Path -LiteralPath $testRunsRoot -PathType Container) {
    $before = @(Get-ChildItem -LiteralPath $testRunsRoot -Directory -Force | Select-Object -ExpandProperty FullName)
}

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'powershell.exe'
$startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$entryPath`" -PrerequisiteOnly"
$startInfo.WorkingDirectory = $projectRoot
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
$startInfo.CreateNoWindow = $true
$null = $startInfo.EnvironmentVariables.Remove('BSCLAW_PYTHON_PATH')

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$null = $process.Start()
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
$process.WaitForExit()

$after = @()
if (Test-Path -LiteralPath $testRunsRoot -PathType Container) {
    $after = @(Get-ChildItem -LiteralPath $testRunsRoot -Directory -Force | Select-Object -ExpandProperty FullName)
}

$expectedText = 'BS-Claw 测试与诊断需要 F 盘 Python（含 sqlite3）。'
$passed = (
    $process.ExitCode -eq 2 -and
    [string]::IsNullOrWhiteSpace($stdout) -and
    $stderr.Trim().StartsWith($expectedText, [StringComparison]::Ordinal) -and
    @($after | Where-Object { $_ -notin $before }).Count -eq 0
)

[pscustomobject]@{
    passed = $passed
    skipped = $false
    exitCode = $process.ExitCode
    messageMatched = $stderr.Trim().StartsWith($expectedText, [StringComparison]::Ordinal)
    stdoutEmpty = [string]::IsNullOrWhiteSpace($stdout)
    createdRuntimeDirectories = @($after | Where-Object { $_ -notin $before }).Count
} | ConvertTo-Json -Compress

if (-not $passed) { exit 1 }
exit 0
