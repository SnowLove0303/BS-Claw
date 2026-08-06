Set-StrictMode -Version Latest

function Get-PMDirectoryInventory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{ path = $Path; exists = $false; bytes = 0L; files = 0; directories = 0 }
    }
    $bytes = 0L
    $files = 0
    $directories = 0
    foreach ($item in (Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue)) {
        if ($item.PSIsContainer) { $directories++ }
        else {
            $files++
            $bytes += [int64]$item.Length
        }
    }
    return [pscustomobject]@{
        path = [IO.Path]::GetFullPath($Path)
        exists = $true
        bytes = $bytes
        files = $files
        directories = $directories
    }
}

function Get-PMFileSetInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths
    )
    $bytes = 0L
    $files = 0
    $directories = 0
    $resolved = @()
    foreach ($relativePath in $RelativePaths) {
        $path = Join-Path $Root $relativePath
        if (Test-Path -LiteralPath $path -PathType Container) {
            $item = Get-PMDirectoryInventory -Path $path
            $bytes += [int64]$item.bytes
            $files += [int]$item.files
            $directories += [int]$item.directories + 1
            $resolved += $item
        }
        elseif (Test-Path -LiteralPath $path -PathType Leaf) {
            $file = Get-Item -LiteralPath $path -Force
            $bytes += [int64]$file.Length
            $files++
            $resolved += [pscustomobject]@{
                path = $file.FullName
                exists = $true
                bytes = [int64]$file.Length
                files = 1
                directories = 0
            }
        }
    }
    return [pscustomobject]@{
        bytes = $bytes
        files = $files
        directories = $directories
        items = @($resolved)
    }
}

function Get-PMProfileProcessState {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)
    $fullPath = [IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    $processes = @()
    try {
        $escaped = [regex]::Escape($fullPath)
        $processes = @(
            Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction Stop |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
                    [string]$_.CommandLine -match $escaped
                }
        )
    }
    catch {
        return [pscustomobject]@{
            running = $null
            processIds = @()
            errorCode = 'PM_PROFILE_PROCESS_QUERY_FAILED'
        }
    }
    return [pscustomobject]@{
        running = $processes.Count -gt 0
        processIds = @($processes | ForEach-Object { [int]$_.ProcessId })
        errorCode = $null
    }
}

function Get-PMTopDirectoryInventory {
    param(
        [Parameter(Mandatory = $true)][string[]]$Roots,
        [int]$Limit = 12
    )
    $items = @()
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($directory in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            $metric = Get-PMDirectoryInventory -Path $directory.FullName
            $items += [pscustomobject]@{
                path = $directory.FullName
                bytes = [int64]$metric.bytes
                files = [int]$metric.files
            }
        }
    }
    return @($items | Sort-Object bytes -Descending | Select-Object -First $Limit)
}

function Get-PMStorageAudit {
    [CmdletBinding()]
    param(
        [string]$ResourceId,
        [switch]$NoAudit
    )

    $projectRoot = Get-PMProjectRoot
    $parentRoot = Split-Path $projectRoot -Parent
    $profileRoot = if (-not [string]::IsNullOrWhiteSpace($env:BSCLAW_PM_PROFILE_ROOT)) {
        [IO.Path]::GetFullPath($env:BSCLAW_PM_PROFILE_ROOT)
    }
    else {
        Join-Path $parentRoot '_portmanager-profiles'
    }
    if (-not $profileRoot.StartsWith('F:\', [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-PMStructuredException -ErrorCode 'PM_STORAGE_AUDIT_F_DRIVE_REQUIRED' `
            -Message '体积盘点只允许读取 F 盘端口管理数据。' `
            -NextAction '将 BSCLAW_PM_PROFILE_ROOT 指向 F 盘受控 Profile 根目录后重试。')
    }

    $resources = @(Get-PMResources)
    if (-not [string]::IsNullOrWhiteSpace($ResourceId)) {
        $null = Get-PMResourceById -ResourceId $ResourceId
    }
    $code = Get-PMFileSetInventory -Root $projectRoot -RelativePaths @(
        'port-manager.ps1', 'AGENTS.md', '.gitignore', 'scripts', 'docs', 'adapters'
    )
    $databaseFacts = Get-PMFileSetInventory -Root $projectRoot -RelativePaths @(
        'data\port-manager.sqlite3', 'data\migrations'
    )
    $logs = Get-PMDirectoryInventory -Path (Join-Path $projectRoot 'logs')
    $tests = Get-PMDirectoryInventory -Path (Join-Path $projectRoot 'tests')
    $dataTestRuns = Get-PMDirectoryInventory -Path (Join-Path $projectRoot 'data\test-runs')
    $runtime = Get-PMDirectoryInventory -Path (Join-Path $projectRoot 'runtime')

    $profiles = @()
    if (Test-Path -LiteralPath $profileRoot -PathType Container) {
        foreach ($directory in (Get-ChildItem -LiteralPath $profileRoot -Directory -Force -ErrorAction SilentlyContinue)) {
            $metrics = Get-PMProfileMetrics -ProfilePath $directory.FullName
            $process = Get-PMProfileProcessState -ProfilePath $directory.FullName
            $references = @(
                $resources | Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_.browserProfileDirectory) -and
                    [IO.Path]::GetFullPath([string]$_.browserProfileDirectory).TrimEnd('\') -eq
                        [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\')
                } | ForEach-Object { [string]$_.resourceId }
            )
            $profiles += [pscustomobject][ordered]@{
                profilePath = $directory.FullName
                profileName = $directory.Name
                totalBytes = [int64]$metrics.sizeBytes
                cacheBytes = [int64]$metrics.cacheBytes
                nonCacheBytes = [int64]($metrics.sizeBytes - $metrics.cacheBytes)
                files = [int]$metrics.fileCount
                referenced = $references.Count -gt 0
                resourceIds = @($references)
                running = $process.running
                processIds = @($process.processIds)
                processCheckErrorCode = $process.errorCode
                cacheCleanupEligible = ($process.running -eq $false)
                profileDeletionAllowed = $false
                suspectedHistoricalTestResidual = ($references.Count -eq 0 -and $directory.Name -match '^(login-test-|cache-clean-|test-|huice-\d+$)')
                classification = if ($references.Count -gt 0) { 'registered-profile' } else { 'unreferenced-review-required' }
            }
        }
    }

    $profileTotal = [int64](($profiles | Measure-Object totalBytes -Sum).Sum)
    $profileCache = [int64](($profiles | Measure-Object cacheBytes -Sum).Sum)
    $testBytes = [int64]$tests.bytes + [int64]$dataTestRuns.bytes
    $runtimeBytes = [int64]$runtime.bytes
    $thresholds = [pscustomobject][ordered]@{
        profileWarningBytes = 1GB
        testArtifactsWarningBytes = 512MB
        runtimeWarningBytes = 512MB
        rawDeploymentWarningBytes = 1GB
    }
    $topRoots = @(
        (Join-Path $projectRoot 'tests'),
        (Join-Path $projectRoot 'data'),
        (Join-Path $projectRoot 'runtime'),
        $profileRoot
    )
    $topRoots += @($profiles | ForEach-Object { [string]$_.profilePath })
    $topBloat = Get-PMTopDirectoryInventory -Roots $topRoots
    $rawTotal = [int64]$code.bytes + [int64]$databaseFacts.bytes + [int64]$logs.bytes +
        $testBytes + $runtimeBytes + $profileTotal
    $blockers = @()
    if ($testBytes -gt $thresholds.testArtifactsWarningBytes) {
        $blockers += '测试产物超过 512 MB；推广时不得纳入源代码包。'
    }
    if ($runtimeBytes -gt $thresholds.runtimeWarningBytes) {
        $blockers += '运行数据超过 512 MB；推广时应由新机器自动重建。'
    }
    if ($profileTotal -gt $thresholds.rawDeploymentWarningBytes) {
        $blockers += '浏览器 Profile 不得整体并入通用分发包；仅在需要迁移登录态时单独受控迁移非缓存数据。'
    }
    $result = [pscustomobject][ordered]@{
        action = 'StorageAudit'
        executeMode = 'dry-run'
        generatedAt = [DateTimeOffset]::Now.ToString('o')
        resourceId = if ([string]::IsNullOrWhiteSpace($ResourceId)) { $null } else { $ResourceId }
        roots = [pscustomobject]@{ project = $projectRoot; profiles = $profileRoot }
        totals = [pscustomobject][ordered]@{
            observedBytes = $rawTotal
            codeBytes = [int64]$code.bytes
            databaseFactBytes = [int64]$databaseFacts.bytes
            logBytes = [int64]$logs.bytes
            testArtifactBytes = $testBytes
            runtimeBytes = $runtimeBytes
            chromeProfileBytes = $profileTotal
            reproducibleChromeCacheBytes = $profileCache
            nonCacheProfileBytes = $profileTotal - $profileCache
        }
        categories = [pscustomobject][ordered]@{
            code = $code
            databaseFacts = $databaseFacts
            logs = $logs
            tests = $tests
            dataTestRuns = $dataTestRuns
            runtime = $runtime
        }
        profiles = @($profiles | Sort-Object totalBytes -Descending)
        topBloatItems = @($topBloat)
        thresholds = $thresholds
        immutableFacts = @(
            'port_resources', 'schema_migrations', 'credential_profiles',
            'audit_records', 'login_session_events', 'resource definitions'
        )
        dryRunCleanupCandidates = @(
            'tests 下的历史测试产物', 'data\test-runs', 'runtime 下可再生运行数据',
            'Profile 中已分类的 Chrome 可再生缓存'
        )
        rawFolderPromotionBlocked = $blockers.Count -gt 0
        promotionBlockers = @($blockers)
        recommendation = '推广只冻结源码、迁移、正式文档和必要事实源；运行数据与缓存由目标机器重建。'
    }
    if (-not $NoAudit) {
        Write-PMAudit -Action 'StorageAudit' -ResourceId $ResourceId -Outcome 'Planned' `
            -Message '已完成端口管理全模块体积盘点，未删除任何数据。' -Details @{
                executeMode = 'dry-run'
                totalBytes = $rawTotal
                profileBytes = $profileTotal
                cacheBytes = $profileCache
                testArtifactBytes = $testBytes
                promotionBlockers = @($blockers)
            }
        $result | Add-Member -MemberType NoteProperty -Name auditId -Value (Get-PMLastAuditId) -Force
    }
    else {
        $result | Add-Member -MemberType NoteProperty -Name auditId -Value $null -Force
        $result | Add-Member -MemberType NoteProperty -Name readOnly -Value $true -Force
    }
    return $result
}

function Write-PMStorageAuditText {
    param([Parameter(Mandatory = $true)][object]$Audit)
    Write-Host ("代码：{0:N2} MB；数据库事实源：{1:N2} MB" -f ($Audit.totals.codeBytes / 1MB), ($Audit.totals.databaseFactBytes / 1MB))
    Write-Host ("测试产物：{0:N2} MB；运行数据：{1:N2} MB" -f ($Audit.totals.testArtifactBytes / 1MB), ($Audit.totals.runtimeBytes / 1MB))
    Write-Host ("浏览器配置：{0:N2} MB（可再生缓存 {1:N2} MB，非缓存 {2:N2} MB）" -f `
        ($Audit.totals.chromeProfileBytes / 1MB), ($Audit.totals.reproducibleChromeCacheBytes / 1MB), ($Audit.totals.nonCacheProfileBytes / 1MB))
    Write-Host '本操作仅盘点，不删除任何文件。'
    foreach ($blocker in @($Audit.promotionBlockers)) { Write-Host "推广提示：$blocker" }
}

Export-ModuleMember -Function @('Get-PMStorageAudit', 'Write-PMStorageAuditText')

