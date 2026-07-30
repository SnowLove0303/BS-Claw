[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidatePattern('^HCP-[A-F0-9]{8}$')][string]$ResourceId)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$entry = Join-Path $root 'login-agent.ps1'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action List -OutputFormat Json -NonInteractive
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Check -ResourceId $ResourceId -OutputFormat Json -NonInteractive
exit $LASTEXITCODE
