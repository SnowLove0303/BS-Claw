[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ModulePath,
    [Parameter(Mandatory = $true)]
    [string]$ResourceId,
    [Parameter(Mandatory = $true)]
    [string]$SignalPath,
    [ValidateRange(3, 60)]
    [int]$HoldSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module $ModulePath -Force
$module = Get-Module PortManager.Core
$lease = & $module {
    param($TargetResourceId, $Duration)
    Set-PMLease -ResourceId $TargetResourceId -Operation '自动回归并发占用' -DurationSeconds $Duration
} $ResourceId ($HoldSeconds + 10)

[IO.File]::WriteAllText(
    $SignalPath,
    ($lease | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
)

try {
    Start-Sleep -Seconds $HoldSeconds
}
finally {
    & $module {
        param($LeaseId)
        Remove-PMLease -LeaseId $LeaseId
    } $lease.leaseId
}
