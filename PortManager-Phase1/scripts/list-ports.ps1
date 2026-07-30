[CmdletBinding()]
param(
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text'
)
& (Join-Path $PSScriptRoot 'port-manager.ps1') -Action List -OutputFormat $OutputFormat
exit $LASTEXITCODE
