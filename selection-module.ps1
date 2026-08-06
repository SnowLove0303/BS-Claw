[CmdletBinding()]
param(
    [ValidateSet("Discover", "Preflight", "Execute", "Status", "Cancel", "Recover")]
    [string]$Action,

    [string]$SelectionAction,
    [string]$RequestJson,
    [string]$ResourceContextJson,
    [string]$TaskId,
    [string]$Reason,
    [int]$TimeoutSeconds = 180,
    [switch]$NonInteractive,
    [switch]$OutputPretty
)

$ErrorActionPreference = "Stop"
$script:ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Import-Module (Join-Path $script:ModuleRoot "modules\Selection.Common.psm1") -Force
Import-Module (Join-Path $script:ModuleRoot "modules\Selection.Contracts.psm1") -Force
Import-Module (Join-Path $script:ModuleRoot "modules\Selection.Database.psm1") -Force
Import-Module (Join-Path $script:ModuleRoot "modules\Selection.State.psm1") -Force
Import-Module (Join-Path $script:ModuleRoot "modules\Selection.ResourcePreflight.psm1") -Force
Import-Module (Join-Path $script:ModuleRoot "modules\Selection.HttpConnector.psm1") -Force
Import-Module (Join-Path $script:ModuleRoot "modules\Selection.Candidates.psm1") -Force
Import-Module (Join-Path $script:ModuleRoot "modules\Selection.Rules.psm1") -Force
Import-Module (Join-Path $script:ModuleRoot "modules\Selection.Actions.psm1") -Force
Import-Module (Join-Path $script:ModuleRoot "modules\Selection.HotWorkflow.psm1") -Force
Import-Module (Join-Path $script:ModuleRoot "modules\Selection.Recovery.psm1") -Force

Initialize-SelectionDatabase -ModuleRoot $script:ModuleRoot | Out-Null
Set-SelectionStateModuleRoot -ModuleRoot $script:ModuleRoot
$global:SelectionModuleRootForState = $script:ModuleRoot

$stdinText = $null
if ([Console]::IsInputRedirected) {
    $stdinText = [Console]::In.ReadToEnd()
}
$schedulerPayload = $null
if ([string]::IsNullOrWhiteSpace($Action) -and -not [string]::IsNullOrWhiteSpace($stdinText)) {
    $schedulerPayload = ConvertFrom-SelectionJson -Json $stdinText -Name "stdin" -Required
    $Action = "Execute"
    $SelectionAction = [string]$schedulerPayload.action
    $RequestJson = ConvertTo-SelectionJsonText ([pscustomobject]@{
        taskId = $schedulerPayload.taskId
        parameters = $schedulerPayload.parameters
        executionContext = $schedulerPayload.executionContext
        writeLevel = $schedulerPayload.writeLevel
        readOnly = $schedulerPayload.readOnly
        businessWrite = $schedulerPayload.businessWrite
        timeoutSeconds = $schedulerPayload.timeoutSeconds
    })
    $ResourceContextJson = ConvertTo-SelectionJsonText $schedulerPayload.resource
    if ([string]::IsNullOrWhiteSpace($ResourceContextJson)) { $ResourceContextJson = "null" }
    $TaskId = [string]$schedulerPayload.taskId
    $TimeoutSeconds = [int]$schedulerPayload.timeoutSeconds
}
if ([string]::IsNullOrWhiteSpace($Action)) {
    throw "Action is required unless a scheduler payload is provided on stdin."
}

function Write-SelectionOutput {
    param([object]$Value)
    if ($OutputPretty) {
        $Value | ConvertTo-Json -Depth 20
    } else {
        $Value | ConvertTo-Json -Depth 20 -Compress
    }
}

function ConvertTo-SchedulerPluginOutput {
    param([object]$Value)
    $success = $false
    if ($Value.PSObject.Properties["ok"]) { $success = [bool]$Value.ok }
    $status = if ($Value.PSObject.Properties["status"]) { [string]$Value.status } else { "UNKNOWN" }
    $errorCode = $null
    if ($Value.PSObject.Properties["code"]) { $errorCode = $Value.code }
    elseif ($Value.PSObject.Properties["errorCode"]) { $errorCode = $Value.errorCode }
    elseif ($Value.PSObject.Properties["result"] -and $null -ne $Value.result -and $Value.result.PSObject.Properties["code"]) { $errorCode = $Value.result.code }
    $message = if ($Value.PSObject.Properties["userMessage"]) { [string]$Value.userMessage } else { "" }
    if ([string]::IsNullOrWhiteSpace($message) -and $Value.PSObject.Properties["message"]) { $message = [string]$Value.message }
    if ([string]::IsNullOrWhiteSpace($message) -and $Value.PSObject.Properties["result"] -and $null -ne $Value.result -and $Value.result.PSObject.Properties["userMessage"]) { $message = [string]$Value.result.userMessage }
    [pscustomobject]@{
        success = $success
        status = $status
        result = Protect-SelectionObject $Value
        errorCode = $errorCode
        message = $message
        needsManualAction = $status -in @("AUTH_REQUIRED", "WAITING_LOGIN", "WAITING_EXTERNAL_VERIFICATION")
        evidence = [pscustomobject]@{
            source = "SelectionModule-Phase1"
            taskId = if ($Value.PSObject.Properties["taskId"]) { $Value.taskId } else { $TaskId }
            checkedAt = Get-SelectionUtcNow
        }
        businessWritesExecuted = ($SelectionAction -in @("selection.execute", "hot.add-distribution") -and $success)
        serviceStateWritesExecuted = $false
    }
}

try {
    switch ($Action) {
        "Discover" {
            Write-SelectionOutput (Get-SelectionDiscovery -ModuleRoot $script:ModuleRoot)
        }
        "Preflight" {
            $resourceContext = ConvertFrom-SelectionJson -Json $ResourceContextJson -Name "ResourceContextJson" -Required
            $request = ConvertFrom-SelectionJson -Json $RequestJson -Name "RequestJson"
            Write-SelectionOutput (Invoke-SelectionPreflight -ResourceContext $resourceContext -Request $request -Source "selection-module.preflight")
        }
        "Execute" {
            if ([string]::IsNullOrWhiteSpace($SelectionAction)) {
                throw "SelectionAction is required for Execute."
            }
            $request = ConvertFrom-SelectionJson -Json $RequestJson -Name "RequestJson" -Required
            $resourceContext = ConvertFrom-SelectionJson -Json $ResourceContextJson -Name "ResourceContextJson" -Required
            $result = Invoke-SelectionTask -ModuleRoot $script:ModuleRoot -SelectionAction $SelectionAction -Request $request -ResourceContext $resourceContext -TimeoutSeconds $TimeoutSeconds
            if ($null -ne $schedulerPayload) {
                Write-SelectionOutput (ConvertTo-SchedulerPluginOutput -Value $result)
            } else {
                Write-SelectionOutput $result
            }
        }
        "Status" {
            if ([string]::IsNullOrWhiteSpace($TaskId)) { throw "TaskId is required for Status." }
            Write-SelectionOutput (Get-SelectionTaskStatus -TaskId $TaskId)
        }
        "Cancel" {
            if ([string]::IsNullOrWhiteSpace($TaskId)) { throw "TaskId is required for Cancel." }
            Write-SelectionOutput (Stop-SelectionTask -TaskId $TaskId -Reason $Reason)
        }
        "Recover" {
            Write-SelectionOutput (Invoke-SelectionRecovery -ModuleRoot $script:ModuleRoot -TaskId $TaskId -Reason $Reason)
        }
    }
} catch {
    $errorResult = New-SelectionError -Code "SELECTION_ENTRY_FAILED" -Message "Selection module entry failed." -Stage $Action -TechnicalSummary $_.Exception.Message -Retryable:$false -RecoveryRequired:$true -NextAction "Check input contract, module files and runtime dependencies."
    Write-SelectionOutput $errorResult
    exit 1
}
