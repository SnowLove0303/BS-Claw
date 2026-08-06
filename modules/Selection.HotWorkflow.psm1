Set-StrictMode -Version 2.0

function Get-SelectionValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-SelectionNumber {
    param([object]$Object, [string[]]$Names)
    foreach ($name in $Names) {
        $value = Get-SelectionValue -Object $Object -Name $name
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $number = 0L
        if ([long]::TryParse([string]$value, [ref]$number)) { return $number }
    }
    return $null
}

function Get-SelectionNumberArray {
    param([object]$Value)
    $items = @()
    foreach ($item in @($Value)) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item)) { continue }
        $number = 0L
        if ([long]::TryParse([string]$item, [ref]$number)) { $items += ,$number }
    }
    return [object[]]($items | Select-Object -Unique)
}

function New-HotGoodsReadbackRequest {
    param([object]$Candidate, [int]$PageSize = 50)
    $supplierShopId = Get-SelectionNumber -Object $Candidate -Names @("supplierShopId", "supplierSysShopId", "shopId")
    $goodsName = [string](Get-SelectionValue -Object $Candidate -Name "goodsName")
    [pscustomobject]@{
        invokeMode = "cdp-fetch"
        method = "POST"
        path = "/scmapi/api/admin/distributor/goods/list"
        pageSize = $PageSize
        maxPages = 5
        body = [pscustomobject]@{
            prdDesc = ""
            goodsName = $goodsName
            authShopIdList = @()
            supplierSysShopId = $supplierShopId
            outerGoodsSn = ""
            categoryId = $null
            platformId = ""
            notPerfectPlatformId = ""
            specId = ""
            deletedStatus = $null
            pageRows = $PageSize
            currentPage = 1
            shopType = $null
            selectionTimeStart = ""
            selectionTimeEnd = ""
            tail = $null
            canSalePlatform = ""
            fuzzyForSn = $true
            fuzzyForSpecId = $true
            brandList = @()
            distributorGoodsId = $null
        }
    }
}

function New-HotGoodsJoinRequest {
    param([object]$Candidate)
    $supplierGoodsId = Get-SelectionNumber -Object $Candidate -Names @("supplierGoodsId", "goodsId", "sourceGoodsId")
    $supplierShopId = Get-SelectionNumber -Object $Candidate -Names @("supplierShopId", "supplierSysShopId", "shopId")
    $itemList = Get-SelectionNumberArray (Get-SelectionValue -Object $Candidate -Name "itemList")
    [pscustomobject]@{
        invokeMode = "cdp-fetch"
        method = "POST"
        path = "/scmapi/api/admin/distributor/selection"
        pageSize = 1
        maxPages = 1
        body = [pscustomobject]@{
            paramList = @([pscustomobject]@{
                supplierGoodsId = $supplierGoodsId
                itemList = $itemList
            })
            supplierShopId = $supplierShopId
        }
    }
}

function Test-HotGoodsCandidateIdentity {
    param([object]$Candidate)
    $supplierGoodsId = Get-SelectionNumber -Object $Candidate -Names @("supplierGoodsId", "goodsId", "sourceGoodsId")
    $supplierShopId = Get-SelectionNumber -Object $Candidate -Names @("supplierShopId", "supplierSysShopId", "shopId")
    $itemList = Get-SelectionNumberArray (Get-SelectionValue -Object $Candidate -Name "itemList")
    if ($null -eq $supplierGoodsId) { return "missing_supplier_goods_id" }
    if ($null -eq $supplierShopId) { return "missing_supplier_shop_id" }
    if (@($itemList).Count -lt 1) { return "missing_item_list" }
    return $null
}

function Select-HotGoodsTarget {
    param([object[]]$Candidates, [object]$ResourceContext, [object]$Task)
    $rejected = @()
    $index = 0
    foreach ($candidate in @($Candidates)) {
        $index += 1
        $identityError = Test-HotGoodsCandidateIdentity -Candidate $candidate
        if ($identityError) {
            $rejected += [pscustomobject]@{ index = $index; reason = $identityError; item = Protect-SelectionObject $candidate }
            continue
        }
        $readbackRequest = New-HotGoodsReadbackRequest -Candidate $candidate
        $readback = Invoke-SelectionHttpRequest -Request ([pscustomobject]@{
            apiContractVerified = $true
            httpRequest = $readbackRequest
        }) -ResourceContext $ResourceContext -TimeoutSeconds 180
        if (-not $readback.ok) {
            $rejected += [pscustomobject]@{ index = $index; reason = "pre_readback_failed"; error = Protect-SelectionObject $readback; item = Protect-SelectionObject $candidate }
            continue
        }
        $expectation = [pscustomobject]@{
            supplierGoodsId = Get-SelectionNumber -Object $candidate -Names @("supplierGoodsId", "goodsId", "sourceGoodsId")
            supplierShopId = Get-SelectionNumber -Object $candidate -Names @("supplierShopId", "supplierSysShopId", "shopId")
        }
        $match = Find-SelectionReadbackMatch -Readback $readback -Expectation $expectation
        if ($null -ne $match) {
            $rejected += [pscustomobject]@{ index = $index; reason = "already_distributed"; readbackMatch = $match; item = Protect-SelectionObject $candidate }
            continue
        }
        return [pscustomobject]@{
            ok = $true
            ruleVersion = "hot-default-v1"
            rule = "Select the first complete item from the current hot-goods response that is not distributed in pre-readback."
            selectedIndex = $index
            selected = Protect-SelectionObject $candidate
            rejected = [object[]]$rejected
            preReadbackSummary = New-SelectionHttpResultSummary -Result $readback
        }
    }
    return [pscustomobject]@{
        ok = $false
        ruleVersion = "hot-default-v1"
        code = if (@($Candidates).Count -eq 0) { "NO_HOT_CANDIDATE" } else { "TARGET_ALREADY_DISTRIBUTED" }
        rejected = [object[]]$rejected
    }
}

function Invoke-SelectionHotAddDistribution {
    param([object]$Task, [object]$Request, [object]$ResourceContext)
    $parameters = if ($Request.PSObject.Properties["parameters"] -and $null -ne $Request.parameters) { $Request.parameters } else { $Request }

    Add-SelectionStateTransition -Task $Task -Status "INTENT_MATCHED" -Phase "INTENT_MATCHED" -Message "Hot add-distribution fixed path matched." -Source "selection.hot.workflow" -Evidence @{ action = "hot.add-distribution" } -NextAction "Read Huice hot-goods candidates." | Out-Null

    $candidateRequest = [pscustomobject]@{ parameters = [pscustomobject]@{} }
    if ($parameters.PSObject.Properties["hotRequest"] -and $null -ne $parameters.hotRequest) {
        $candidateRequest.parameters = $parameters.hotRequest
    }
    $candidateResult = Invoke-SelectionCandidateAcquire -Task $Task -Request $candidateRequest -ResourceContext $ResourceContext
    if (-not $candidateResult.ok) { return $candidateResult }
    if ([int]$candidateResult.successCount -lt 1) {
        return [pscustomobject]@{
            ok = $false
            status = "NO_HOT_CANDIDATE"
            phase = "HOT_CANDIDATES_READY"
            code = "NO_HOT_CANDIDATE"
            userMessage = "Huice hot-goods API returned no usable candidate."
            businessSummary = "Add-distribution was not executed."
            successCount = 0
            failureCount = 1
            candidateSnapshot = $candidateResult.candidateSnapshot
            readbackAt = Get-SelectionUtcNow
            recoveryAdvice = "Adjust hot-goods conditions or retry candidate acquisition later."
        }
    }
    Add-SelectionStateTransition -Task $Task -Status "HOT_CANDIDATES_READY" -Phase "CANDIDATE_ACQUIRE" -Message "Huice hot-goods candidates were acquired." -Source "hotGoods/recommend" -Evidence @{ itemCount = $candidateResult.successCount; source = $candidateResult.candidateSnapshot.sourcePath; sourceAt = $candidateResult.candidateSnapshot.sourceAt } -NextAction "Select one target with hot-default-v1." | Out-Null

    $selection = Select-HotGoodsTarget -Candidates @($candidateResult.candidateSnapshot.items) -ResourceContext $ResourceContext -Task $Task
    if (-not $selection.ok) {
        return [pscustomobject]@{
            ok = $false
            status = $selection.code
            phase = "TARGET_SELECTED"
            code = $selection.code
            userMessage = if ($selection.code -eq "NO_HOT_CANDIDATE") { "No hot-goods candidate can be selected." } else { "All hot-goods candidates are already distributed or missing required fields." }
            businessSummary = "Duplicate add-distribution was not executed."
            successCount = 0
            failureCount = 1
            candidateSnapshot = $candidateResult.candidateSnapshot
            ruleVersion = $selection.ruleVersion
            rejected = $selection.rejected
            readbackAt = Get-SelectionUtcNow
            recoveryAdvice = "Acquire a new hot-goods snapshot or confirm a usable target through business rules."
        }
    }
    Add-SelectionStateTransition -Task $Task -Status "TARGET_SELECTED" -Phase "TARGET_SELECTED" -Message "One item was selected from the current hot-goods snapshot." -Source "hot-default-v1" -Evidence $selection -NextAction "Submit add-distribution and run post-readback." | Out-Null

    $selected = $selection.selected
    $executeParameters = [pscustomobject]@{
        actionContractVerified = $true
        writeAuthorization = if ($parameters.PSObject.Properties["writeAuthorization"]) { $parameters.writeAuthorization } else { $null }
        idempotencyKey = if ($parameters.PSObject.Properties["idempotencyKey"] -and $parameters.idempotencyKey) { $parameters.idempotencyKey } else { New-SelectionId -Prefix "hot-add-dist" }
        httpRequest = New-HotGoodsJoinRequest -Candidate $selected
        readbackRequest = New-HotGoodsReadbackRequest -Candidate $selected
        readbackExpect = [pscustomobject]@{
            supplierGoodsId = Get-SelectionNumber -Object $selected -Names @("supplierGoodsId", "goodsId", "sourceGoodsId")
            supplierShopId = Get-SelectionNumber -Object $selected -Names @("supplierShopId", "supplierSysShopId", "shopId")
        }
    }
    Add-SelectionStateTransition -Task $Task -Status "JOIN_SUBMITTED" -Phase "EXECUTING" -Message "Submitting Huice add-distribution HTTP request." -Source "distributor/selection" -Evidence @{ idempotencyKey = $executeParameters.idempotencyKey; selected = $selected } -NextAction "Wait for write response and distribution-list readback." | Out-Null
    $actionResult = Invoke-SelectionExecuteAction -Task $Task -Request ([pscustomobject]@{ parameters = $executeParameters }) -ResourceContext $ResourceContext
    $result = [pscustomobject]@{
        ok = $actionResult.ok
        status = if ($actionResult.ok) { "SUCCEEDED" } else { $actionResult.status }
        phase = if ($actionResult.ok) { "READBACK_VERIFIED" } else { $actionResult.phase }
        code = if ($actionResult.ok) { $null } else { $actionResult.code }
        userMessage = if ($actionResult.ok) { "A hot-goods item was added to distribution and verified by post-readback." } else { $actionResult.userMessage }
        businessSummary = if ($actionResult.ok) { "Hot-goods item added to distribution." } else { $actionResult.businessSummary }
        successCount = $actionResult.successCount
        failureCount = $actionResult.failureCount
        candidateSnapshot = $candidateResult.candidateSnapshot
        ruleVersion = $selection.ruleVersion
        selectionRule = $selection.rule
        selected = $selected
        rejected = $selection.rejected
        idempotencyKey = $actionResult.idempotencyKey
        actionRecordId = $actionResult.actionRecordId
        writeSummary = $actionResult.writeSummary
        readbackSummary = $actionResult.readbackSummary
        readbackMatch = $actionResult.readbackMatch
        readbackAt = $actionResult.readbackAt
        recoveryAdvice = $actionResult.recoveryAdvice
    }
    if ($actionResult.ok) {
        Add-SelectionStateTransition -Task $Task -Status "READBACK_VERIFIED" -Phase "VERIFYING" -Message "Post-write distribution-list readback matched the target item." -Source "distributor/goods/list" -Evidence $result -NextAction "Return user-readable result and release scheduler resource lease." | Out-Null
    }
    return $result
}

Export-ModuleMember -Function *
