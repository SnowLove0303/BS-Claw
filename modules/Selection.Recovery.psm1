Set-StrictMode -Version 2.0

function New-SelectionRecoveryReadbackSummary {
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

function Invoke-SelectionRecovery {
    param([string]$ModuleRoot, [string]$TaskId, [string]$Reason)
    if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = "Scheduler requested recovery."; }
    $task = $null
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $task = Get-SelectionTaskRecord -ModuleRoot $ModuleRoot -TaskId $TaskId
    }
    if ($task -and [bool]$task.ok -and $task.selectionAction -eq "selection.execute") {
        $request = $task.request
        $resource = $task.resourceSnapshot
        if ($request -and $request.PSObject.Properties["readbackRequest"] -and $null -ne $request.readbackRequest) {
            $readbackWrapper = [pscustomobject]@{
                apiContractVerified = $true
                httpRequest = $request.readbackRequest
            }
            $readback = Invoke-SelectionHttpRequest -Request $readbackWrapper -ResourceContext $resource -TimeoutSeconds 240
            $readbackMatch = $null
            if ([bool]$readback.ok -and $request.PSObject.Properties["readbackExpect"] -and $null -ne $request.readbackExpect) {
                $expectedSupplierGoodsId = if ($request.readbackExpect.PSObject.Properties["supplierGoodsId"]) { [string]$request.readbackExpect.supplierGoodsId } else { "" }
                $expectedSupplierShopId = if ($request.readbackExpect.PSObject.Properties["supplierShopId"]) { [string]$request.readbackExpect.supplierShopId } else { "" }
                foreach ($item in @($readback.items)) {
                    $supplierGoodsId = if ($item.PSObject.Properties["supplierGoodsId"]) { [string]$item.supplierGoodsId } else { "" }
                    $supplierShopId = if ($item.PSObject.Properties["supplierShopId"]) { [string]$item.supplierShopId } else { "" }
                    if ($supplierGoodsId -eq $expectedSupplierGoodsId -and ([string]::IsNullOrWhiteSpace($expectedSupplierShopId) -or $supplierShopId -eq $expectedSupplierShopId)) {
                        $readbackMatch = Protect-SelectionObject $item
                        break
                    }
                }
            }
            $ok = $null -ne $readbackMatch
            $readbackSummary = New-SelectionRecoveryReadbackSummary -Result $readback
            $result = [pscustomobject]@{
                ok = $ok
                status = if ($ok) { "SUCCEEDED" } else { "RECOVERY_REQUIRED" }
                phase = "RECOVER"
                code = if ($ok) { $null } else { "READBACK_FAILED" }
                userMessage = if ($ok) { "Recovery readback found the expected joined distribution product." } else { "Recovery readback did not find the expected joined distribution product." }
                readbackAt = Get-SelectionUtcNow
                readbackItemCount = if ($readback.PSObject.Properties["itemCount"]) { $readback.itemCount } else { $null }
                readbackSummary = $readbackSummary
                readbackMatch = $readbackMatch
            }
            $task.status = $result.status
            $task.phase = "RECOVER"
            $task.updatedAt = Get-SelectionUtcNow
            $task.result = Protect-SelectionObject $result
            $task.recoveryRequired = -not $ok
            Save-SelectionTaskRecord -ModuleRoot $ModuleRoot -Record $task | Out-Null
            Add-SelectionEventRecord -ModuleRoot $ModuleRoot -Record ([pscustomobject]@{
                taskId = $TaskId
                status = $result.status
                phase = "RECOVER"
                message = $result.userMessage
                source = "selection-module.recover"
                evidence = $result
                nextAction = if ($ok) { "Archive result and keep resource reusable." } else { "Do not retry write; inspect readback and external platform state." }
                at = Get-SelectionUtcNow
            }) | Out-Null
            return [pscustomobject]@{
                ok = $ok
                status = $result.status
                phase = "RECOVER"
                taskId = $TaskId
                result = Protect-SelectionObject $result
                recoveredAt = Get-SelectionUtcNow
                nextAction = if ($ok) { "Archive result and release scheduler resource lock." } else { "Keep recovery open and inspect external state before any retry." }
            }
        }
    }
    $records = Get-SelectionRecoverableRecords -ModuleRoot $ModuleRoot -TaskId $TaskId
    [pscustomobject]@{
        ok = $true
        status = "RECOVERY_LISTED"
        phase = "RECOVER"
        reason = $Reason
        records = Protect-SelectionObject $records
        recoveredAt = Get-SelectionUtcNow
        nextAction = "Scheduler should decide whether to preflight again, read back again, or terminate."
    }
}

Export-ModuleMember -Function *
