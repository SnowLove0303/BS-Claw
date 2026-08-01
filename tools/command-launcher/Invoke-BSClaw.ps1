[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$localRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$entryScript = Join-Path $localRoot 'start-bsclaw.ps1'

if ([IO.Path]::GetPathRoot($localRoot) -notlike 'F:\') {
    [Console]::Error.WriteLine('BS Claw 必须从 F 盘运行。')
    exit 1
}
if (-not (Test-Path -LiteralPath $entryScript -PathType Leaf)) {
    [Console]::Error.WriteLine('BS Claw 本地调度入口不存在，请检查 BSClaw-Local 文件是否完整。')
    exit 1
}

& $entryScript @Arguments
exit $LASTEXITCODE
