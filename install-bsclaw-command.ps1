[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Uninstall,
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$localRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path $localRoot -Parent))
$commandDirectory = [IO.Path]::GetFullPath((Join-Path $localRoot 'tools\command-launcher'))
$compatibilityCommandDirectory = [IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot 'PortManager-Phase1\tools\command-launcher')
)
$backupRoot = [IO.Path]::GetFullPath((Join-Path $localRoot 'data\command-backups'))
$requiredFiles = @(
    (Join-Path $commandDirectory 'BS.cmd'),
    (Join-Path $commandDirectory 'bsclaw.cmd'),
    (Join-Path $commandDirectory 'Invoke-BSClaw.ps1'),
    (Join-Path $localRoot 'start-bsclaw.ps1')
)

function Normalize-PathEntry([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return $Value.Trim().Trim('"').TrimEnd([char[]]@('\', '/'))
}

function Write-Result([bool]$Success, [string]$Message, [object]$Data) {
    if ($OutputFormat -eq 'Json') {
        [ordered]@{ success = $Success; message = $Message; data = $Data } |
            ConvertTo-Json -Depth 5
    }
    else {
        Write-Host $Message
        if ($Success -and -not $Uninstall) {
            if ($Data.compatibilityEntriesRemoved -gt 0) {
                Write-Host '已从用户 PATH 移除旧兼容入口；兼容文件仍保留。'
            }
            Write-Host '请重新打开 PowerShell，然后输入 BS Claw 或 bsclaw。'
        }
    }
}

try {
    if ([IO.Path]::GetPathRoot($localRoot) -notlike 'F:\') {
        throw 'BS Claw 快捷命令只能安装在 F 盘项目目录中。'
    }
    $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -gt 0) { throw "快捷启动文件不完整：缺少 $($missing.Count) 个文件。" }

    $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    $entries = @(
        @($userPath -split ';') |
            ForEach-Object { Normalize-PathEntry $_ } |
            Where-Object { $_ }
    )
    $normalized = Normalize-PathEntry $commandDirectory
    $normalizedCompatibility = Normalize-PathEntry $compatibilityCommandDirectory
    $withoutCurrent = @($entries | Where-Object { $_ -ine $normalized })
    $compatibilityEntries = @(
        if (-not $Uninstall) {
            $entries | Where-Object { $_ -ieq $normalizedCompatibility }
        }
    )
    $withoutManagedEntries = if ($Uninstall) {
        $withoutCurrent
    }
    else {
        @($withoutCurrent | Where-Object { $_ -ine $normalizedCompatibility })
    }
    $updated = if ($Uninstall) { $withoutManagedEntries } else { @($normalized) + $withoutManagedEntries }
    $changed = ($entries -join ';') -cne ($updated -join ';')

    $action = if ($Uninstall) { 'remove local scheduler launcher from user PATH' } else { 'make local scheduler launcher the first user PATH entry' }
    if (-not $PSCmdlet.ShouldProcess($commandDirectory, $action)) { return }

    $stamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss')
    $backup = Join-Path $backupRoot $stamp
    $null = New-Item -ItemType Directory -Path $backup -Force
    [IO.File]::WriteAllText((Join-Path $backup 'user-path-before.txt'), [string]$userPath, [Text.UTF8Encoding]::new($false))
    if ($changed) {
        [Environment]::SetEnvironmentVariable('Path', ($updated -join ';'), [EnvironmentVariableTarget]::User)
    }
    Write-Result $true $(if ($Uninstall) { '已移除 BS Claw 本地调度入口。' } else { 'BS Claw 本地调度入口已设为首选。' }) ([ordered]@{
        commandDirectory = $commandDirectory
        pathChanged = $changed
        compatibilityEntriesRemoved = $compatibilityEntries.Count
        backupDirectory = $backup
        restartPowerShellRequired = $true
    })
    exit 0
}
catch {
    Write-Result $false $_.Exception.Message $null
    exit 1
}
