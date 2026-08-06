[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceId,
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text'
)
& (Join-Path $PSScriptRoot 'port-manager.ps1') -Action Check -ResourceId $ResourceId -OutputFormat $OutputFormat
exit $LASTEXITCODE
