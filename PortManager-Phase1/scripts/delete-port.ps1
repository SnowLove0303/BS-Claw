[CmdletBinding()]
param(
    [string]$ResourceId,
    [string]$ConfirmationText
)
& (Join-Path $PSScriptRoot 'port-manager.ps1') -Action Delete -ResourceId $ResourceId -ConfirmationText $ConfirmationText
exit $LASTEXITCODE
