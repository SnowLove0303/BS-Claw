[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceId,
    [ValidateRange(3, 120)]
    [int]$TimeoutSeconds = 20,
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text'
)
& (Join-Path $PSScriptRoot 'port-manager.ps1') -Action Open -ResourceId $ResourceId -TimeoutSeconds $TimeoutSeconds -OutputFormat $OutputFormat
exit $LASTEXITCODE
