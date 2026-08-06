[CmdletBinding()]
param(
    [string]$ModuleRoot = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $ModuleRoot "modules\Selection.Common.psm1") -Force
Import-Module (Join-Path $ModuleRoot "modules\Selection.Database.psm1") -Force
Initialize-SelectionDatabase -ModuleRoot $ModuleRoot | Out-Null
Get-SelectionDatabaseDiagnostics -ModuleRoot $ModuleRoot | ConvertTo-Json -Depth 10
