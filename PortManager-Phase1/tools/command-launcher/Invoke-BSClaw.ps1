[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$entryScript = Join-Path $projectRoot 'port-manager.ps1'

if ([IO.Path]::GetPathRoot($projectRoot) -notlike 'F:\') {
    [Console]::Error.WriteLine('BS Claw must run from drive F:.')
    exit 1
}
if (-not (Test-Path -LiteralPath $entryScript -PathType Leaf)) {
    [Console]::Error.WriteLine("PortManager entry not found: $entryScript")
    exit 1
}

& $entryScript -Action Menu
exit $LASTEXITCODE
