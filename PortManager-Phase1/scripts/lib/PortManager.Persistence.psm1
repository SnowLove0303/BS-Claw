Set-StrictMode -Version Latest

function Assert-PMPersistencePathOnFDrive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$FieldName = '路径'
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetPathRoot($fullPath) -notlike 'F:\') {
        throw "$FieldName 必须位于 F 盘：$fullPath"
    }
    return $fullPath
}

function Invoke-PMPersistenceWriteLock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MutexName,
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $mutex = [Threading.Mutex]::new($false, $MutexName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
        if (-not $acquired) {
            throw '等待数据写入锁超时，请稍后重试。'
        }
        return & $ScriptBlock
    }
    finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Write-PMPersistedJsonAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Value,
        [string]$BackupPath,
        [switch]$CreateBackup
    )

    $fullPath = Assert-PMPersistencePathOnFDrive -Path $Path -FieldName '数据文件'
    $directory = Split-Path -Parent $fullPath
    $null = New-Item -ItemType Directory -Path $directory -Force
    $temporaryPath = Join-Path $directory (
        ([IO.Path]::GetFileName($fullPath)) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    try {
        $null = Assert-PMPersistedDataSafety -Value $Value -Context 'JSON 持久化数据'
        $json = $Value | ConvertTo-Json -Depth 24
        [IO.File]::WriteAllText(
            $temporaryPath,
            $json + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
        if ($CreateBackup -and (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            if ([string]::IsNullOrWhiteSpace($BackupPath)) {
                throw '原子写入要求备份时必须提供 F 盘备份路径。'
            }
            $safeBackupPath = Assert-PMPersistencePathOnFDrive -Path $BackupPath -FieldName '备份文件'
            Copy-Item -LiteralPath $fullPath -Destination $safeBackupPath -Force
        }
        Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Read-PMPersistedJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = Assert-PMPersistencePathOnFDrive -Path $Path -FieldName '数据文件'
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return $null
    }
    $text = [IO.File]::ReadAllText($fullPath, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return $text | ConvertFrom-Json
}

function Assert-PMPersistedDataSafety {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,
        [string]$Context = '持久化数据'
    )

    $json = $Value | ConvertTo-Json -Compress -Depth 24
    $forbiddenProperty = '"(?:password|passwd|cookie|cookies|token|accessToken|refreshToken|authorization|authorizationHeader|authHeader|secret|credentialValue)"\s*:'
    if ($json -match $forbiddenProperty) {
        throw "$Context 包含禁止持久化的敏感字段。"
    }
    return $true
}

function Get-PMSensitiveFinding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $patterns = [ordered]@{
        passwordField = '"(?:password|passwd)"\s*:'
        cookieField = '"cookies?"\s*:'
        tokenField = '"(?:token|accessToken|refreshToken)"\s*:'
        authorizationField = '"(?:authorization|authorizationHeader|authHeader)"\s*:'
        bearerValue = 'Bearer\s+[A-Za-z0-9._~+/\-=]{12,}'
    }
    $findings = @()
    foreach ($name in $patterns.Keys) {
        if ($Text -match $patterns[$name]) {
            $findings += $name
        }
    }
    return @($findings)
}

Export-ModuleMember -Function @(
    'Assert-PMPersistencePathOnFDrive',
    'Invoke-PMPersistenceWriteLock',
    'Write-PMPersistedJsonAtomic',
    'Read-PMPersistedJson',
    'Assert-PMPersistedDataSafety',
    'Get-PMSensitiveFinding'
)
