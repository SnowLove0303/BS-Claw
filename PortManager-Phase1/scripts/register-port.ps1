[CmdletBinding()]
param()
& (Join-Path $PSScriptRoot 'port-manager.ps1') -Action Register
exit $LASTEXITCODE
