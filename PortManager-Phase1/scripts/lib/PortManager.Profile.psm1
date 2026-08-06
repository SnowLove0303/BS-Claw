Set-StrictMode -Version Latest

$script:CacheDirectoryNames = @(
    'Cache', 'Code Cache', 'GPUCache', 'GrShaderCache', 'ShaderCache',
    'DawnCache', 'GraphiteDawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache',
    'Safe Browsing', 'component_crx_cache', 'Component Crx Cache',
    'extensions_crx_cache', 'BrowserMetrics',
    'optimization_guide_model_store', 'OptGuideOnDeviceModel',
    'WidevineCdm', 'WasmTtsEngine', 'Crashpad', 'CrashpadMetrics-active.pma',
    'Download Service', 'ActorSafetyLists', 'AmountExtractionHeuristicRegexes',
    'CaptchaProviders', 'CertificateRevocation', 'Crowd Deny', 'FileTypePolicies',
    'FirstPartySetsPreloaded', 'hyphen-data', 'MEIPreload',
    'OnDeviceHeadSuggestModel', 'OptimizationHints', 'OriginTrials', 'PKIMetadata',
    'PrivacySandboxAttestationsPreloaded', 'RecoveryImproved', 'SafetyTips',
    'segmentation_platform', 'SSLErrorAssistant', 'Subresource Filter',
    'TrustTokenKeyCommitments', 'ZxcvbnData'
)
$script:CacheDirectorySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($cacheName in $script:CacheDirectoryNames) {
    $null = $script:CacheDirectorySet.Add($cacheName)
}

function Get-PMProfileMetrics {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProfilePath)
    $fullPath = [IO.Path]::GetFullPath($ProfilePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        return [pscustomobject]@{ exists = $false; sizeBytes = 0L; fileCount = 0; cacheBytes = 0L; cacheFileCount = 0 }
    }
    $size = [int64]0
    $count = 0
    $cacheSize = [int64]0
    $cacheCount = 0
    try {
        foreach ($file in [IO.Directory]::EnumerateFiles($fullPath, '*', [IO.SearchOption]::AllDirectories)) {
            try {
                $length = ([IO.FileInfo]$file).Length
                $size += [int64]$length
                $count++
                $relative = $file.Substring($fullPath.Length).TrimStart('\')
                $isCache = $false
                foreach ($segment in $relative.Split('\')) {
                    if ($script:CacheDirectorySet.Contains($segment)) {
                        $isCache = $true
                        break
                    }
                }
                if ($isCache) {
                    $cacheSize += [int64]$length
                    $cacheCount++
                }
            }
            catch { }
        }
    }
    catch { }
    return [pscustomobject]@{ exists = $true; sizeBytes = $size; fileCount = $count; cacheBytes = $cacheSize; cacheFileCount = $cacheCount }
}

function Invoke-PMProfileCacheCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [switch]$Execute,
        [string]$ConfirmationText,
        [string]$AuditRecordPath
    )

    $allowedRoot = [IO.Path]::GetFullPath('F:\XIANGMU\BS Claw\_portmanager-profiles').TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($ProfilePath)
    $allowedPrefix = $allowedRoot + '\'
    if (-not $fullPath.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "PROFILE_PATH_NOT_ALLOWED: ProfilePath must be below $allowedRoot"
    }

    $planned = @()
    $plannedBytes = [int64]0
    $plannedFiles = 0
    $removed = @()
    $removedBytes = [int64]0
    $removedFiles = 0
    $errors = @()
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        return [pscustomobject]@{
            mode = if ($Execute) { 'execute' } else { 'dry-run' }
            profilePath = $fullPath
            exists = $false
            executed = $false
            plannedDirectories = @()
            plannedBytes = 0L
            plannedFiles = 0
            removedDirectories = @()
            removedBytes = 0L
            removedFiles = 0
            errors = @()
            impact = 'Profile does not exist; nothing was or will be deleted.'
        }
    }

    $allCandidates = @()
    try {
        $allCandidates = @(
            [IO.Directory]::EnumerateDirectories($fullPath, '*', [IO.SearchOption]::AllDirectories) |
                Where-Object { $script:CacheDirectorySet.Contains(([IO.DirectoryInfo]$_).Name) } |
                Sort-Object { $_.Length }
        )
    }
    catch {
        $errors += "PROFILE_ENUMERATION_FAILED: $($_.Exception.Message)"
    }

    # Keep only top-level matching candidates so nested cache directories are
    # neither counted nor deleted twice.
    $selectedCandidates = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $allCandidates) {
        $nested = $false
        foreach ($selected in $selectedCandidates) {
            if ($candidate.StartsWith(($selected.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
                $nested = $true
                break
            }
        }
        if (-not $nested) {
            $selectedCandidates.Add($candidate)
        }
    }

    foreach ($candidate in $selectedCandidates) {
        $candidateBytes = [int64]0
        $candidateFiles = 0
        try {
            foreach ($file in [IO.Directory]::EnumerateFiles($candidate, '*', [IO.SearchOption]::AllDirectories)) {
                try {
                    $candidateBytes += ([IO.FileInfo]$file).Length
                    $candidateFiles++
                }
                catch { }
            }
        }
        catch {
            $errors += "CACHE_ENUMERATION_FAILED: $($_.Exception.Message)"
        }
        $relativePath = $candidate.Substring($fullPath.TrimEnd('\').Length).TrimStart('\')
        $planned += [pscustomobject]@{
            relativePath = $relativePath
            bytes = $candidateBytes
            files = $candidateFiles
        }
        $plannedBytes += $candidateBytes
        $plannedFiles += $candidateFiles
    }

    if (-not $Execute) {
        return [pscustomobject]@{
            mode = 'dry-run'
            profilePath = $fullPath
            exists = $true
            executed = $false
            plannedDirectories = @($planned)
            plannedBytes = $plannedBytes
            plannedFiles = $plannedFiles
            removedDirectories = @()
            removedBytes = 0L
            removedFiles = 0
            errors = @($errors)
            impact = 'Only reproducible Chrome cache directories are listed. Browser session, Cookies, Local Storage, Session Storage, Preferences, SQLite, resources, CredentialRef, and audit evidence are not deletion targets.'
        }
    }

    if ($ConfirmationText -cne '确认清理可再生缓存') {
        throw 'CACHE_CLEANUP_CONFIRMATION_REQUIRED: ConfirmationText must exactly match the required Chinese confirmation text.'
    }
    if ([string]::IsNullOrWhiteSpace($AuditRecordPath)) {
        throw 'CACHE_CLEANUP_AUDIT_REQUIRED: AuditRecordPath on drive F: is required.'
    }
    $fullAuditPath = [IO.Path]::GetFullPath($AuditRecordPath)
    if (-not $fullAuditPath.StartsWith('F:\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'CACHE_CLEANUP_AUDIT_PATH_NOT_ALLOWED: AuditRecordPath must be on drive F:.'
    }

    $profileInUse = $false
    try {
        $escapedProfile = [regex]::Escape($fullPath.TrimEnd('\'))
        $profileInUse = @(
            Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction Stop |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and [string]$_.CommandLine -match $escapedProfile }
        ).Count -gt 0
    }
    catch {
        throw "PROFILE_RUNNING_CHECK_FAILED: $($_.Exception.Message)"
    }
    if ($profileInUse) {
        throw 'PROFILE_IN_USE: Real cache deletion is forbidden while the registered Chrome profile is running.'
    }

    if (Test-Path -LiteralPath $fullAuditPath) {
        throw 'CACHE_CLEANUP_AUDIT_EXISTS: AuditRecordPath must identify a new file.'
    }
    $auditParent = Split-Path -Parent $fullAuditPath
    if (-not [string]::IsNullOrWhiteSpace($auditParent)) {
        [IO.Directory]::CreateDirectory($auditParent) | Out-Null
    }
    $preAuditRecord = [ordered]@{
        occurredAt = [DateTimeOffset]::Now.ToString('o')
        action = 'ProfileCacheCleanup'
        phase = 'approved-before-delete'
        profilePath = $fullPath
        plannedDirectories = @($planned | ForEach-Object { $_.relativePath })
        plannedBytes = $plannedBytes
        plannedFiles = $plannedFiles
        excludedData = @('Cookies','Local Storage','Session Storage','Preferences','SQLite','resources','CredentialRef','audit evidence')
    }
    [IO.File]::WriteAllText(
        $fullAuditPath,
        ($preAuditRecord | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($true)
    )

    foreach ($candidate in $selectedCandidates) {
        $planItem = @($planned | Where-Object { $_.relativePath -eq $candidate.Substring($fullPath.TrimEnd('\').Length).TrimStart('\') }) | Select-Object -First 1
        try {
            Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction Stop
            $removed += [string]$planItem.relativePath
            $removedBytes += [int64]$planItem.bytes
            $removedFiles += [int]$planItem.files
        }
        catch {
            $errors += "$([string]$planItem.relativePath): $($_.Exception.Message)"
        }
    }

    $auditRecord = [ordered]@{
        occurredAt = [DateTimeOffset]::Now.ToString('o')
        action = 'ProfileCacheCleanup'
        phase = 'completed'
        profilePath = $fullPath
        plannedBytes = $plannedBytes
        plannedFiles = $plannedFiles
        removedDirectories = @($removed)
        removedBytes = $removedBytes
        removedFiles = $removedFiles
        errors = @($errors)
        excludedData = @('Cookies','Local Storage','Session Storage','Preferences','SQLite','resources','CredentialRef','audit evidence')
    }
    [IO.File]::WriteAllText(
        $fullAuditPath,
        ($auditRecord | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($true)
    )

    return [pscustomobject]@{
        mode = 'execute'
        profilePath = $fullPath
        exists = $true
        executed = $true
        plannedDirectories = @($planned)
        plannedBytes = $plannedBytes
        plannedFiles = $plannedFiles
        removedDirectories = @($removed)
        removedBytes = $removedBytes
        removedFiles = $removedFiles
        errors = @($errors)
        auditRecordPath = $fullAuditPath
        impact = 'Only explicitly classified reproducible Chrome cache directories were targeted.'
    }
}

Export-ModuleMember -Function @('Get-PMProfileMetrics', 'Invoke-PMProfileCacheCleanup')
