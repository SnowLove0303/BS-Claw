Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'PortManager.Profile.psm1') -Force

function Assert-PMChromeProfileOnFDrive {
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetPathRoot($fullPath) -notlike 'F:\') {
        throw "Chrome 配置目录必须位于 F 盘：$fullPath"
    }
    return $fullPath
}

function Start-PMChromeResourceBrowser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource
    )

    if ([IO.Path]::GetFileName([string]$Resource.browserExecutable) -ine 'chrome.exe') {
        throw '默认浏览器只允许 Google Chrome，不允许使用其他浏览器。'
    }
    if (-not (Test-Path -LiteralPath $Resource.browserExecutable -PathType Leaf)) {
        throw "Chrome 未启动：可执行文件不存在：$($Resource.browserExecutable)"
    }
    $profilePath = Assert-PMChromeProfileOnFDrive -Path ([string]$Resource.browserProfileDirectory)
    $null = New-Item -ItemType Directory -Path $profilePath -Force
    # 正常启动不得隐式清理 Profile。缓存只统计，清理必须由独立、显式且
    # 已确认的维护操作执行，避免用户仅执行 Open/Check 时发生磁盘数据删除。

    $arguments = @(
        "--remote-debugging-port=$($Resource.port)"
        '--remote-debugging-address=127.0.0.1'
        "--user-data-dir=`"$profilePath`""
        '--no-first-run'
        '--no-default-browser-check'
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$Resource.startUrl)) {
        $arguments += "`"$(([string]$Resource.startUrl).Replace('"', '%22'))`""
    }
    else {
        $arguments += 'about:blank'
    }

    try {
        return Start-Process -FilePath $Resource.browserExecutable -ArgumentList $arguments -PassThru
    }
    catch {
        throw 'Chrome 未启动：' + $_.Exception.Message
    }
}

function Get-PMChromeResourceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$ProfileDirectory
    )
    $marker = "--remote-debugging-port=$Port"
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $line = [string]$_.CommandLine
        $line.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $line -notmatch '(?i)--type=(renderer|gpu-process|utility|crashpad-handler)'
    })
    if ($processes.Count -eq 0) { return $null }
    $process = $processes | Sort-Object ProcessId | Select-Object -First 1
    $line = [string]$process.CommandLine
    $profileMatch = [regex]::Match($line, '(?i)--user-data-dir="([^"]+)"|--user-data-dir=([^\s]+)')
    $actualProfile = if ($profileMatch.Success) { if ($profileMatch.Groups[1].Success) { $profileMatch.Groups[1].Value } else { $profileMatch.Groups[2].Value } } else { $null }
    $start = $null
    try { $start = (Get-Process -Id ([int]$process.ProcessId) -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { }
    $fingerprint = $null
    if (-not [string]::IsNullOrWhiteSpace($actualProfile)) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $fingerprint = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($actualProfile)).ToUpperInvariant())) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16) } finally { $sha.Dispose() }
    }
    return [pscustomobject]@{
        ProcessId = [int]$process.ProcessId
        ExecutablePath = [string]$process.ExecutablePath
        ProcessStartTime = $start
        CommandLine = $line
        ProfileDirectory = $actualProfile
        ProfileFingerprint = $fingerprint
        MatchesProfile = [string]::IsNullOrWhiteSpace($ProfileDirectory) -or (-not [string]::IsNullOrWhiteSpace($actualProfile) -and [IO.Path]::GetFullPath($actualProfile) -eq [IO.Path]::GetFullPath($ProfileDirectory))
    }
}

function Stop-PMChromeOwnedProcesses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Resource,
        [Parameter(Mandatory = $true)]
        [object]$StartedProcess,
        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$StartedAt
    )

    $rootProcessId = [int]$StartedProcess.Id
    $profileMarker = [string]$Resource.browserProfileDirectory
    $portMarker = "--remote-debugging-port=$($Resource.port)"
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $ownedIds = [Collections.Generic.HashSet[int]]::new()
    $null = $ownedIds.Add($rootProcessId)
    $createdAfter = $StartedAt.AddSeconds(-2).UtcDateTime

    foreach ($process in $processes) {
        if ([string]$process.Name -ine 'chrome.exe') {
            continue
        }
        $creationTime = try {
            if ($process.CreationDate -is [DateTime]) {
                ([DateTime]$process.CreationDate).ToUniversalTime()
            }
            else {
                [Management.ManagementDateTimeConverter]::ToDateTime([string]$process.CreationDate).ToUniversalTime()
            }
        }
        catch {
            $null
        }
        $commandLine = [string]$process.CommandLine
        $matchesLaunch = (
            -not [string]::IsNullOrWhiteSpace($commandLine) -and
            (
                $commandLine.IndexOf($portMarker, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $commandLine.IndexOf($profileMarker, [StringComparison]::OrdinalIgnoreCase) -ge 0
            )
        )
        if ($matchesLaunch -and ($null -eq $creationTime -or $creationTime -ge $createdAfter)) {
            $null = $ownedIds.Add([int]$process.ProcessId)
        }
    }

    $added = $true
    while ($added) {
        $added = $false
        foreach ($process in $processes) {
            if (
                [string]$process.Name -ieq 'chrome.exe' -and
                $ownedIds.Contains([int]$process.ParentProcessId) -and
                -not $ownedIds.Contains([int]$process.ProcessId)
            ) {
                $null = $ownedIds.Add([int]$process.ProcessId)
                $added = $true
            }
        }
    }

    $attemptedIds = @($ownedIds)
    foreach ($processId in ($attemptedIds | Sort-Object -Descending)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
    $deadline = [DateTimeOffset]::Now.AddSeconds(5)
    do {
        $stillRunning = @($attemptedIds | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
        if ($stillRunning.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTimeOffset]::Now -lt $deadline)

    return [pscustomobject]@{
        attemptedProcessIds = @($attemptedIds)
        remainingProcessIds = @($stillRunning)
        cleaned = ($stillRunning.Count -eq 0)
    }
}

Export-ModuleMember -Function @(
    'Start-PMChromeResourceBrowser',
    'Stop-PMChromeOwnedProcesses',
    'Get-PMChromeResourceBinding'
)
