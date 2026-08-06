Set-StrictMode -Version 2.0

function Invoke-SelectionCandidateAcquire {
    param([object]$Task, [object]$Request, [object]$ResourceContext)
    $parameters = if ($Request.PSObject.Properties["parameters"] -and $null -ne $Request.parameters) { $Request.parameters } else { $Request }
    if (-not $parameters.PSObject.Properties["httpRequest"] -or $null -eq $parameters.httpRequest) {
        $parameters = [pscustomobject]@{
            apiContractVerified = $true
            httpRequest = [pscustomobject]@{
                invokeMode = "cdp-fetch"
                method = "POST"
                path = "/openapi/api/admin/distributor/hotGoods/recommend"
                pageSize = 20
                maxPages = 1
                body = [pscustomobject]@{
                    categoryIdList = @()
                    currentPage = 1
                    pageRows = 20
                    dataPlatformList = @("39")
                    bannedPlatform = "39"
                    maxDisPrice = ""
                    minDisPrice = ""
                    activeSort = 0
                    searchWord = ""
                    storageType = $null
                    type = ""
                    goodsTag = ""
                    choiceComplatedPlatformIds = @("39")
                    completePlatformIds = @("39")
                    improvePlatformId = "39"
                    canSalePlatform = "39"
                    salePlatformIdList = @("39")
                    bannedPlatformIdList = @("39")
                    joinList = 0
                    goodsTags = @()
                    keyword = ""
                    sortFieldRules = @([pscustomobject]@{ field = "sales_volume_fifteen"; order = 1 })
                }
            }
        }
    }
    $httpResult = Invoke-SelectionHttpRequest -Request $parameters -ResourceContext $ResourceContext -TimeoutSeconds 180
    if (-not $httpResult.ok) { return $httpResult }
    $snapshotId = New-SelectionId -Prefix "candidate-snapshot"
    Save-SelectionCandidateRecord -ModuleRoot $global:SelectionModuleRootForState -Record ([pscustomobject]@{
        snapshotId = $snapshotId
        taskId = $Task.taskId
        source = $httpResult.sourcePath
        sourceAt = $httpResult.sourceAt
        itemCount = [int]$httpResult.itemCount
        summary = [pscustomobject]@{
            pageCount = $httpResult.pageCount
            itemCount = $httpResult.itemCount
            pages = $httpResult.pages
            responseSummary = $httpResult.redactedResponseSummary
        }
        createdAt = Get-SelectionUtcNow
    }) | Out-Null
    return [pscustomobject]@{
        ok = $true
        status = "CANDIDATES_READY"
        phase = "CANDIDATE_ACQUIRE"
        code = $null
        userMessage = "Huice hot-goods candidate snapshot acquired through HTTP API."
        businessSummary = "Hot-goods candidate snapshot generated."
        successCount = [int]$httpResult.itemCount
        failureCount = 0
        externalTaskRef = $null
        readbackAt = $httpResult.sourceAt
        candidateSnapshot = [pscustomobject]@{
            snapshotId = $snapshotId
            sourcePath = $httpResult.sourcePath
            sourceAt = $httpResult.sourceAt
            pageCount = $httpResult.pageCount
            itemCount = $httpResult.itemCount
            items = $httpResult.items
            pages = $httpResult.pages
            responseSummary = $httpResult.redactedResponseSummary
        }
        recoveryAdvice = "Use a versioned rule to select one target from this hot-goods snapshot."
    }
}

Export-ModuleMember -Function *
