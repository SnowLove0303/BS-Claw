[CmdletBinding()]
param(
    [string]$ResourceId
)
& (Join-Path $PSScriptRoot 'port-manager.ps1') -Action Edit -ResourceId $ResourceId
exit $LASTEXITCODE
