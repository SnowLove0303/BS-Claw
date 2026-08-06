Set-StrictMode -Version 2.0

function New-SelectionHttpResultSummary {
    param([object]$Result)
    if ($null -eq $Result) { return $null }
    [pscustomobject]@{
        ok = if ($Result.PSObject.Properties["ok"]) { [bool]$Result.ok } else { $false }
        status = if ($Result.PSObject.Properties["status"]) { $Result.status } else { $null }
        code = if ($Result.PSObject.Properties["code"]) { $Result.code } else { $null }
        userMessage = if ($Result.PSObject.Properties["userMessage"]) { $Result.userMessage } else { $null }
        technicalSummary = if ($Result.PSObject.Properties["technicalSummary"]) { $Result.technicalSummary } else { $null }
        sourcePath = if ($Result.PSObject.Properties["sourcePath"]) { $Result.sourcePath } else { $null }
        sourceAt = if ($Result.PSObject.Properties["sourceAt"]) { $Result.sourceAt } else { $null }
        itemCount = if ($Result.PSObject.Properties["itemCount"]) { $Result.itemCount } else { $null }
        pageCount = if ($Result.PSObject.Properties["pageCount"]) { $Result.pageCount } else { $null }
        responseSummary = if ($Result.PSObject.Properties["redactedResponseSummary"]) { Protect-SelectionObject $Result.redactedResponseSummary } else { $null }
        pages = if ($Result.PSObject.Properties["pages"]) { Protect-SelectionObject $Result.pages } else { $null }
    }
}

function Find-SelectionReadbackMatch {
    param([object]$Readback, [object]$Expectation)
    if ($null -eq $Readback -or -not [bool]$Readback.ok -or $null -eq $Expectation) { return $null }
    $expectedSupplierGoodsId = if ($Expectation.PSObject.Properties["supplierGoodsId"]) { [string]$Expectation.supplierGoodsId } else { "" }
    $expectedSupplierShopId = if ($Expectation.PSObject.Properties["supplierShopId"]) { [string]$Expectation.supplierShopId } else { "" }
    foreach ($item in @($Readback.items)) {
        $supplierGoodsId = if ($item.PSObject.Properties["supplierGoodsId"]) { [string]$item.supplierGoodsId } else { "" }
        $supplierShopId = if ($item.PSObject.Properties["supplierShopId"]) { [string]$item.supplierShopId } else { "" }
        if ($supplierGoodsId -eq $expectedSupplierGoodsId -and ([string]::IsNullOrWhiteSpace($expectedSupplierShopId) -or $supplierShopId -eq $expectedSupplierShopId)) {
            return (Protect-SelectionObject $item)
        }
    }
    return $null
}

function Invoke-SelectionExecuteAction {
    param([object]$Task, [object]$Request, [object]$ResourceContext)
    $parameters = if ($Request.PSObject.Properties["parameters"] -and $null -ne $Request.parameters) { $Request.parameters } else { $Request }
    $idempotencyKey = $null
    if ($parameters.PSObject.Properties["idempotencyKey"]) { $idempotencyKey = $parameters.idempotencyKey }
    if ([string]::IsNullOrWhiteSpace([string]$idempotencyKey)) {
        $idempotencyKey = New-SelectionId -Prefix "idem"
    }
    $authorized = $false
    if ($parameters.PSObject.Properties["writeAuthorization"] -and $parameters.writeAuthorization) {
        $authorized = ([string]$parameters.writeAuthorization.scope -eq "isolated-resource" -and [string]$parameters.writeAuthorization.status -eq "approved")
    }
    $verified = ($parameters.PSObject.Properties["actionContractVerified"] -and [bool]$parameters.actionContractVerified)
    if (-not $authorized -or -not $verified) {
        return [pscustomobject]@{
        ok = $false
        status = "BLOCKED"
        phase = "EXECUTING"
        code = "WRITE_ACTION_NOT_VERIFIED"
        userMessage = "Write Action is not verified with real API and isolated authorization; execution is blocked and no external write was performed."
        businessSummary = "No write was executed."
        successCount = 0
        failureCount = 1
        idempotencyKey = $idempotencyKey
        externalTaskRef = $null
        readbackAt = $null
        failureReason = "Real response, idempotency semantics and precise readback are not verified."
        recoveryAdvice = "Verify real API responses and isolated authorization before enabling writes. Unknown results must be read back before retry."
        }
    }
    $writeResult = Invoke-SelectionHttpRequest -Request $parameters -ResourceContext $ResourceContext -TimeoutSeconds 300
    if (-not $writeResult.ok) { return $writeResult }
    if (-not $parameters.PSObject.Properties["readbackRequest"] -or $null -eq $parameters.readbackRequest) {
        return [pscustomobject]@{
            ok = $false
            status = "RECOVERY_REQUIRED"
            phase = "VERIFYING"
            code = "READBACK_REQUIRED"
            userMessage = "Write request returned, but readback contract is missing. Unknown result requires recovery."
            businessSummary = "Write result is unknown."
            successCount = 0
            failureCount = 1
            idempotencyKey = $idempotencyKey
            externalTaskRef = $null
            readbackAt = $null
            failureReason = "Precise readback is mandatory after write."
            recoveryAdvice = "Run recover with a verified readback request before retry."
        }
    }
    $readbackWrapper = [pscustomobject]@{
        apiContractVerified = $true
        httpRequest = $parameters.readbackRequest
    }
    $readback = Invoke-SelectionHttpRequest -Request $readbackWrapper -ResourceContext $ResourceContext -TimeoutSeconds 180
    $externalRef = if ($writeResult.PSObject.Properties["externalTaskRef"]) { $writeResult.externalTaskRef } else { $null }
    $readbackMatch = $null
    $readbackOk = [bool]$readback.ok
    if ($readbackOk -and $parameters.PSObject.Properties["readbackExpect"] -and $null -ne $parameters.readbackExpect) {
        $readbackMatch = Find-SelectionReadbackMatch -Readback $readback -Expectation $parameters.readbackExpect
        $readbackOk = $null -ne $readbackMatch
        $pollAttempt = 0
        while (-not $readbackOk -and $pollAttempt -lt 3) {
            Start-Sleep -Seconds 2
            $pollAttempt += 1
            $readback = Invoke-SelectionHttpRequest -Request $readbackWrapper -ResourceContext $ResourceContext -TimeoutSeconds 180
            $readbackMatch = Find-SelectionReadbackMatch -Readback $readback -Expectation $parameters.readbackExpect
            $readbackOk = $null -ne $readbackMatch
        }
    }
    $writeSummary = New-SelectionHttpResultSummary -Result $writeResult
    $readbackSummary = New-SelectionHttpResultSummary -Result $readback
    $actionRecordId = New-SelectionId -Prefix "selection-action"
    Save-SelectionActionRecord -ModuleRoot $global:SelectionModuleRootForState -Record ([pscustomobject]@{
        actionRecordId = $actionRecordId
        taskId = $Task.taskId
        actionId = "selection.execute"
        idempotencyKey = $idempotencyKey
        externalRef = $externalRef
        status = if ($readbackOk) { "SUCCEEDED" } else { "RECOVERY_REQUIRED" }
        readbackAt = Get-SelectionUtcNow
        result = [pscustomobject]@{ writeSummary = $writeSummary; readbackSummary = $readbackSummary; readbackMatch = $readbackMatch }
        createdAt = Get-SelectionUtcNow
    }) | Out-Null
    [pscustomobject]@{
        ok = [bool]$readbackOk
        status = if ($readbackOk) { "SUCCEEDED" } else { "RECOVERY_REQUIRED" }
        phase = "VERIFYING"
        code = if ($readbackOk) { $null } else { "READBACK_FAILED" }
        userMessage = if ($readbackOk) { "Selection action was executed and read back." } else { "Selection action write returned but expected readback object was not found." }
        businessSummary = if ($readbackOk) { "Selection action readback completed." } else { "Selection action result is unknown." }
        successCount = if ($readbackOk) { 1 } else { 0 }
        failureCount = if ($readbackOk) { 0 } else { 1 }
        idempotencyKey = $idempotencyKey
        actionRecordId = $actionRecordId
        externalTaskRef = $externalRef
        readbackAt = Get-SelectionUtcNow
        writeSummary = $writeSummary
        readbackSummary = $readbackSummary
        readbackMatch = $readbackMatch
        recoveryAdvice = if ($readbackOk) { "Archive result and release scheduler resource lock." } else { "Use recover to read back before any retry." }
    }
}

function Invoke-SelectionTask {
    param(
        [string]$ModuleRoot,
        [string]$SelectionAction,
        [object]$Request,
        [object]$ResourceContext,
        [int]$TimeoutSeconds
    )
    Set-SelectionStateModuleRoot -ModuleRoot $ModuleRoot
    $task = New-SelectionTaskRecord -SelectionAction $SelectionAction -Request $Request -ResourceContext $ResourceContext
    Save-SelectionTaskRecord -ModuleRoot $ModuleRoot -Record $task | Out-Null
    Add-SelectionStateTransition -Task $task -Status "RECEIVED" -Phase "RECEIVED" -Message "Selection task received." -Source "selection-module.execute" -Evidence @{ selectionAction = $SelectionAction; timeoutSeconds = $TimeoutSeconds } -NextAction "Match capability contract." | Out-Null

    $capability = Get-SelectionCapability -ModuleRoot $ModuleRoot -ActionId $SelectionAction
    $capabilityResult = Test-SelectionCapabilityPolicy -Capability $capability
    if (-not $capabilityResult.ok) {
        return Complete-SelectionTask -Task $task -Status $capabilityResult.status -Phase "CAPABILITY_MATCHED" -Result $capabilityResult -Message $capabilityResult.userMessage -NextAction $capabilityResult.nextAction
    }
    Add-SelectionStateTransition -Task $task -Status "CAPABILITY_MATCHED" -Phase "CAPABILITY_MATCHED" -Message "Capability contract matched." -Source "selection-module.manifest" -Evidence $capability -NextAction "Bind resource context." | Out-Null

    Add-SelectionStateTransition -Task $task -Status "RESOURCE_BOUND" -Phase "RESOURCE_BOUND" -Message "Resource context was injected by scheduler." -Source "scheduler-injected-context" -Evidence $ResourceContext -NextAction "Run resource preflight." | Out-Null
    $preflight = Invoke-SelectionPreflight -ResourceContext $ResourceContext -Request $Request -Source "selection-module.execute.preflight"
    if (-not $preflight.ok) {
        return Complete-SelectionTask -Task $task -Status $preflight.status -Phase "PREFLIGHT" -Result $preflight -Message $preflight.userMessage -NextAction $preflight.nextAction
    }
    Add-SelectionStateTransition -Task $task -Status "PREFLIGHT_PASSED" -Phase "PREFLIGHT" -Message "Resource preflight passed." -Source "selection-module.preflight" -Evidence $preflight -NextAction "Execute selection capability." | Out-Null

    switch ($SelectionAction) {
        "candidate.acquire" { $actionResult = Invoke-SelectionCandidateAcquire -Task $task -Request $Request -ResourceContext $ResourceContext }
        "candidate.filter" { $actionResult = Invoke-SelectionCandidateFilter -Task $task -Request $Request }
        "selection.execute" { $actionResult = Invoke-SelectionExecuteAction -Task $task -Request $Request -ResourceContext $ResourceContext }
        "hot.add-distribution" { $actionResult = Invoke-SelectionHotAddDistribution -Task $task -Request $Request -ResourceContext $ResourceContext }
        default {
            $actionResult = [pscustomobject]@{
                ok = $false
                status = "BLOCKED"
                phase = "EXECUTING"
                code = "ACTION_NOT_IMPLEMENTED"
                userMessage = "This selection action is not implemented."
                businessSummary = "No action was executed."
                successCount = 0
                failureCount = 1
                externalTaskRef = $null
                readbackAt = $null
                failureReason = "Action is not registered in the module mainline."
                recoveryAdvice = "Check manifest, adapter and implementation."
            }
        }
    }

    $terminalStatus = if ($actionResult.ok) { "SUCCEEDED" } elseif ($actionResult.status -in @("CANCELED", "TIMED_OUT", "RECOVERY_REQUIRED", "AUTH_REQUIRED", "RESOURCE_BUSY")) { $actionResult.status } else { "BLOCKED" }
    $resultPhase = if ($actionResult.PSObject.Properties["phase"]) { [string]$actionResult.phase } elseif ($actionResult.PSObject.Properties["stage"]) { [string]$actionResult.stage } else { "EXECUTING" }
    $resultMessage = if ($actionResult.PSObject.Properties["userMessage"]) { [string]$actionResult.userMessage } elseif ($actionResult.PSObject.Properties["message"]) { [string]$actionResult.message } else { "Selection action finished." }
    $resultNextAction = if ($actionResult.PSObject.Properties["recoveryAdvice"]) { [string]$actionResult.recoveryAdvice } elseif ($actionResult.PSObject.Properties["nextAction"]) { [string]$actionResult.nextAction } else { "Review result." }
    return Complete-SelectionTask -Task $task -Status $terminalStatus -Phase $resultPhase -Result $actionResult -Message $resultMessage -NextAction $resultNextAction
}

Export-ModuleMember -Function *
