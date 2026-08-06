[CmdletBinding()]
param(
    [ValidateSet('Menu', 'ServiceCheck', 'StoragePlan', 'List', 'Detail', 'Register', 'Edit', 'Delete', 'Enable', 'Disable', 'Check', 'CheckAll', 'Open', 'CachePlan', 'CleanCache', 'CreateLoginTestProfile', 'DeploymentCleanPlan', 'StorageAudit', 'ResetLoginPlan', 'HuiceList', 'HuiceCheck', 'HuiceLogin', 'AcquireLease', 'ReleaseLease', 'Occupancy', 'LoginCheck', 'CancelLoginCheck')]
    [string]$Action = 'Menu',
    [string]$ResourceId,
    [string]$ResourceName,
    [string]$PlatformName = '慧策通',
    [string]$HostName,
    [int]$Port,
    [ValidateSet('ConnectOnly', 'Launch')]
    [string]$ConnectionMode,
    [string]$BrowserExecutable,
    [string]$BrowserProfileDirectory,
    [string]$StartUrl,
    [string]$PlatformUrlPatterns,
    [string]$LoginPagePatterns,
    [switch]$Disabled,
    [string]$Notes,
    [string]$ConfirmationText,
    [int]$TestPort,
    [string]$LeaseId,
    [string]$TaskRef,
    [switch]$RequireLogin,
    [ValidateRange(5, 3600)]
    [int]$LeaseDurationSeconds = 60,
    [ValidateRange(3, 120)]
    [int]$TimeoutSeconds = 20,
    [switch]$SkipLoginMonitoring,
    [switch]$NonInteractive,
    [ValidateSet('Text', 'Json')]
    [string]$OutputFormat = 'Text'
)

$entry = Join-Path $PSScriptRoot 'scripts\port-manager.ps1'
& $entry @PSBoundParameters
exit $LASTEXITCODE
