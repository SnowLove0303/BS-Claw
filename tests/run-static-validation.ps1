[CmdletBinding()]
param(
    [string]$ModuleRoot = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
)

$ErrorActionPreference = "Stop"

$scriptFiles = Get-ChildItem -LiteralPath $ModuleRoot -Recurse -File | Where-Object { $_.Extension -in ".ps1", ".psm1" }
$scriptErrors = @()
foreach ($file in $scriptFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $scriptErrors += [pscustomobject]@{
            file = $file.FullName
            errors = @($errors | ForEach-Object { $_.Message })
        }
    }
}

$jsonFiles = @(
    "manifest.json",
    "module.manifest.json",
    "selection-module.manifest.json",
    "adapter\bsclaw-selection-adapter.json"
)
$jsonResults = @()
foreach ($relative in $jsonFiles) {
    $path = Join-Path $ModuleRoot $relative
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $jsonResults += [pscustomobject]@{
        file = $path
        schemaVersion = $doc.schemaVersion
        moduleId = $doc.moduleId
        adapterId = $doc.adapterId
    }
}

$discover = & (Join-Path $ModuleRoot "selection-module.ps1") -Action Discover | ConvertFrom-Json
$preflight = & (Join-Path $ModuleRoot "selection-module.ps1") -Action Preflight -ResourceContextJson "{}" | ConvertFrom-Json

[pscustomobject]@{
    ok = ($scriptErrors.Count -eq 0 -and $discover.ok -eq $true -and $preflight.ok -eq $false)
    scriptErrors = $scriptErrors
    jsonResults = $jsonResults
    discoverStatus = $discover.status
    emptyResourcePreflightStatus = $preflight.status
    emptyResourcePreflightIssues = $preflight.issues
    checkedAt = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json -Depth 20
