Set-StrictMode -Version 2.0

$script:ModuleRootForState = $null

function Set-SelectionStateModuleRoot {
    param([string]$ModuleRoot)
    $script:ModuleRootForState = $ModuleRoot
}

function New-SelectionTaskRecord {
    param([string]$SelectionAction, [object]$Request, [object]$ResourceContext)
    $taskId = New-SelectionId -Prefix "selection-task"
    [pscustomobject]@{
        taskId = $taskId
        selectionAction = $SelectionAction
        status = "RECEIVED"
        phase = "RECEIVED"
        createdAt = Get-SelectionUtcNow
        updatedAt = Get-SelectionUtcNow
        request = Protect-SelectionObject $Request
        resourceSnapshot = Protect-SelectionObject $ResourceContext
        result = $null
        recoveryRequired = $false
    }
}

function Add-SelectionStateTransition {
    param(
        [object]$Task,
        [string]$Status,
        [string]$Phase,
        [string]$Message,
        [string]$Source,
        [object]$Evidence,
        [string]$NextAction
    )
    $Task.status = $Status
    $Task.phase = $Phase
    $Task.updatedAt = Get-SelectionUtcNow
    $event = [pscustomobject]@{
        taskId = $Task.taskId
        status = $Status
        phase = $Phase
        message = $Message
        source = $Source
        evidence = Protect-SelectionObject $Evidence
        nextAction = $NextAction
        at = Get-SelectionUtcNow
    }
    Save-SelectionTaskRecord -ModuleRoot $script:ModuleRootForState -Record $Task | Out-Null
    Add-SelectionEventRecord -ModuleRoot $script:ModuleRootForState -Record $event | Out-Null
    return $event
}

function Complete-SelectionTask {
    param(
        [object]$Task,
        [string]$Status,
        [string]$Phase,
        [object]$Result,
        [string]$Message,
        [string]$NextAction
    )
    $Task.status = $Status
    $Task.phase = $Phase
    $Task.updatedAt = Get-SelectionUtcNow
    $Task.result = Protect-SelectionObject $Result
    $Task.recoveryRequired = ($Status -eq "RECOVERY_REQUIRED")
    Save-SelectionTaskRecord -ModuleRoot $script:ModuleRootForState -Record $Task | Out-Null
    Add-SelectionStateTransition -Task $Task -Status $Status -Phase $Phase -Message $Message -Source "selection-module.closeout" -Evidence $Result -NextAction $NextAction | Out-Null
    return [pscustomobject]@{
        ok = ($Status -eq "SUCCEEDED")
        taskId = $Task.taskId
        selectionAction = $Task.selectionAction
        status = $Status
        phase = $Phase
        result = Protect-SelectionObject $Result
        updatedAt = $Task.updatedAt
        nextAction = $NextAction
    }
}

function Get-SelectionTaskStatus {
    param([string]$TaskId)
    Get-SelectionTaskRecord -ModuleRoot $script:ModuleRootForState -TaskId $TaskId
}

function Stop-SelectionTask {
    param([string]$TaskId, [string]$Reason)
    if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = "Task was canceled by user or scheduler." }
    Set-SelectionTaskTerminalRecord -ModuleRoot $script:ModuleRootForState -TaskId $TaskId -Status "CANCELED" -Reason $Reason
}

Export-ModuleMember -Function *
