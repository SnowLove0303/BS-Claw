[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Uninstall,
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$commandDirectory = [IO.Path]::GetFullPath((Join-Path $projectRoot 'tools\command-launcher'))
$backupRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'data\command-backups'))
$requiredFiles = @(
    (Join-Path $commandDirectory 'BS.cmd'),
    (Join-Path $commandDirectory 'bsclaw.cmd'),
    (Join-Path $commandDirectory 'Invoke-BSClaw.ps1')
)

function Get-NormalizedPathEntry {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    return $Value.Trim().Trim('"').TrimEnd([char[]]@('\', '/'))
}

function Write-InstallerResult {
    param(
        [bool]$Success,
        [string]$Message,
        [object]$Data
    )
    if ($OutputFormat -eq 'Json') {
        [ordered]@{
            success = $Success
            message = $Message
            data = $Data
        } | ConvertTo-Json -Depth 6
    }
    else {
        Write-Host $Message
        if ($null -ne $Data -and $Success -and -not $Uninstall) {
            Write-Host 'Open a new PowerShell window, then run:'
            Write-Host '  BS Claw'
            Write-Host '  bsclaw'
        }
    }
}

try {
    if ([IO.Path]::GetPathRoot($projectRoot) -notlike 'F:\') {
        throw 'BS Claw 快捷命令只能安装在 F 盘项目目录中。'
    }
    $missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missingFiles.Count -gt 0) {
        throw "BS Claw 快捷启动文件不完整：缺少 $($missingFiles.Count) 个文件。"
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    $pathEntries = @(
        @($userPath -split ';') |
            ForEach-Object { Get-NormalizedPathEntry -Value $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $normalizedCommandDirectory = Get-NormalizedPathEntry -Value $commandDirectory
    $existingEntries = @($pathEntries | Where-Object { $_ -ieq $normalizedCommandDirectory })
    $timestamp = '{0}-{1}' -f [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $backupDirectory = Join-Path $backupRoot $timestamp
    $actionName = if ($Uninstall) { 'remove the BS Claw command directory from the user PATH' } else { 'add the BS Claw command directory to the user PATH' }

    if (-not $PSCmdlet.ShouldProcess($commandDirectory, $actionName)) {
        return
    }

    $null = New-Item -ItemType Directory -Path $backupDirectory -Force
    [IO.File]::WriteAllText(
        (Join-Path $backupDirectory 'user-path-before.txt'),
        [string]$userPath,
        [Text.UTF8Encoding]::new($false)
    )

    if ($Uninstall) {
        $updatedEntries = @($pathEntries | Where-Object { $_ -ine $normalizedCommandDirectory })
        $changed = $updatedEntries.Count -ne $pathEntries.Count
    }
    else {
        $updatedEntries = @($pathEntries)
        $changed = $existingEntries.Count -eq 0
        if ($changed) {
            $updatedEntries += $normalizedCommandDirectory
        }
    }

    if ($changed) {
        [Environment]::SetEnvironmentVariable(
            'Path',
            ($updatedEntries -join ';'),
            [EnvironmentVariableTarget]::User
        )
    }

    $result = [ordered]@{
        commandDirectory = $commandDirectory
        pathChanged = $changed
        installed = -not $Uninstall
        backupDirectory = $backupDirectory
        commands = @('BS Claw', 'bsclaw')
        restartPowerShellRequired = $true
    }
    $message = if ($Uninstall) {
        if ($changed) { '已从用户 PATH 移除 BS Claw 快捷命令。' } else { '用户 PATH 中没有 BS Claw 快捷命令，无需移除。' }
    }
    else {
        if ($changed) { 'BS Claw 快捷命令已安装。' } else { 'BS Claw 快捷命令已经安装，未重复添加 PATH。' }
    }
    Write-InstallerResult -Success $true -Message $message -Data $result
    exit 0
}
catch {
    Write-InstallerResult -Success $false -Message $_.Exception.Message -Data $null
    exit 1
}
