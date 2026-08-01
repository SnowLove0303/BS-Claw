[CmdletBinding()]
param(
    [string]$ArchivePath,
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$localRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$repositoryRoot = [IO.Path]::GetFullPath((Split-Path $localRoot -Parent))
$targetRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'PortManager-Phase1\tools\python'))
$pythonPath = Join-Path $targetRoot 'python.exe'
$cacheRoot = [IO.Path]::GetFullPath((Join-Path $localRoot 'data\python-bootstrap'))
$downloadPath = Join-Path $cacheRoot 'python-3.13.14-embed-amd64.zip'
$downloadUrl = 'https://www.python.org/ftp/python/3.13.14/python-3.13.14-embed-amd64.zip'
$expectedSha256 = '90B4E5B9898B72D744650524BFF92377C367F44BD5FBD09E3148656C080AD907'

function Write-Result {
    param(
        [bool]$Success,
        [string]$Message,
        [object]$Data
    )
    $result = [ordered]@{
        success = $Success
        message = $Message
        data = $Data
    }
    if ($OutputFormat -eq 'Json') {
        $result | ConvertTo-Json -Depth 5
    }
    else {
        Write-Host $Message
        if ($Success) {
            Write-Host "Python 路径：$pythonPath"
            Write-Host '现在可以重新执行 BS Claw 或 bsclaw。'
        }
    }
}

function Test-Python {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $previousNoByteCode = [Environment]::GetEnvironmentVariable('PYTHONDONTWRITEBYTECODE', 'Process')
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $env:PYTHONDONTWRITEBYTECODE = '1'
        & $Path -c 'import sqlite3' 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -eq $previousNoByteCode) {
            [Environment]::SetEnvironmentVariable('PYTHONDONTWRITEBYTECODE', $null, 'Process')
        }
        else {
            $env:PYTHONDONTWRITEBYTECODE = $previousNoByteCode
        }
    }
}

try {
    if ([IO.Path]::GetPathRoot($localRoot) -notlike 'F:\') {
        throw 'Python 准备脚本和目标目录都必须位于 F 盘。'
    }
    if (Test-Python -Path $pythonPath) {
        Write-Result -Success $true -Message 'F 盘 Python 已准备完成，无需重复安装。' -Data @{
            pythonPath = $pythonPath
            reused = $true
            downloaded = $false
        }
        exit 0
    }
    if (Test-Path -LiteralPath $targetRoot) {
        throw "目标目录已存在但 Python 不可用，请先人工检查后再处理：$targetRoot"
    }

    $archive = $null
    $downloaded = $false
    if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
        $archive = [IO.Path]::GetFullPath($ArchivePath)
        if ([IO.Path]::GetPathRoot($archive) -notlike 'F:\') {
            throw '指定的 Python 压缩包必须位于 F 盘。'
        }
        if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
            throw "未找到指定的 Python 压缩包：$archive"
        }
    }
    else {
        $null = New-Item -ItemType Directory -Path $cacheRoot -Force
        $archive = $downloadPath
        if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
            Write-Host '正在从 Python 官方站点下载 F 盘便携运行时……'
            Invoke-WebRequest -Uri $downloadUrl -OutFile $archive -UseBasicParsing
            $downloaded = $true
        }
    }

    $actualSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        throw 'Python 压缩包校验失败，未安装。请删除该 F 盘压缩包后重试。'
    }

    $targetParent = Split-Path $targetRoot -Parent
    $null = New-Item -ItemType Directory -Path $targetParent -Force
    $stagingRoot = Join-Path $targetParent (
        'python-staging-{0}' -f [Guid]::NewGuid().ToString('N')
    )
    $null = New-Item -ItemType Directory -Path $stagingRoot -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $stagingRoot)
    if (-not (Test-Python -Path (Join-Path $stagingRoot 'python.exe'))) {
        throw "解压后的 Python 缺少 sqlite3，临时目录保留供排查：$stagingRoot"
    }
    Move-Item -LiteralPath $stagingRoot -Destination $targetRoot

    Write-Result -Success $true -Message 'F 盘 Python 已准备完成。' -Data @{
        pythonPath = $pythonPath
        reused = $false
        downloaded = $downloaded
        source = 'python.org CPython 3.13.14 embeddable package'
        sha256Verified = $true
    }
    exit 0
}
catch {
    Write-Result -Success $false -Message $_.Exception.Message -Data @{
        pythonPath = $pythonPath
        cacheRoot = $cacheRoot
        nextAction = "重新执行：powershell -NoP -EP Bypass -File `"$PSCommandPath`""
    }
    exit 2
}
