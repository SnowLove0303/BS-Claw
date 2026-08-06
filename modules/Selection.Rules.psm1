Set-StrictMode -Version 2.0

function Invoke-SelectionCandidateFilter {
    param([object]$Task, [object]$Request)
    $parameters = if ($Request.PSObject.Properties["parameters"] -and $null -ne $Request.parameters) { $Request.parameters } else { $Request }
    $ruleVersion = $null
    if ($parameters.PSObject.Properties["ruleVersion"]) { $ruleVersion = $parameters.ruleVersion }
    if ([string]::IsNullOrWhiteSpace([string]$ruleVersion)) {
        return [pscustomobject]@{
            ok = $false
            status = "BLOCKED"
            phase = "FILTER"
            code = "RULE_VERSION_REQUIRED"
            userMessage = "Rule version is not bound; execution is blocked."
            businessSummary = "No filtering was executed."
            successCount = 0
            failureCount = 1
            externalTaskRef = $null
            readbackAt = $null
            failureReason = "Filtering conditions, ranking, supplier policy or elimination reason structure is not frozen."
            recoveryAdvice = "Bind a versioned rule contract before execution."
        }
    }
    if (-not $parameters.PSObject.Properties["candidates"] -or $null -eq $parameters.candidates) {
        return [pscustomobject]@{
            ok = $false
            status = "BLOCKED"
            phase = "FILTER"
            code = "CANDIDATES_REQUIRED"
            userMessage = "Candidate list is missing; filtering is blocked."
            businessSummary = "No filtering was executed."
            successCount = 0
            failureCount = 1
            externalTaskRef = $null
            readbackAt = $null
            failureReason = "candidate.filter requires a real candidate snapshot from candidate.acquire."
            recoveryAdvice = "Run candidate.acquire with a verified HTTP connector first."
        }
    }
    if (-not $parameters.PSObject.Properties["rules"] -or $null -eq $parameters.rules) {
        return [pscustomobject]@{
            ok = $false
            status = "BLOCKED"
            phase = "FILTER"
            code = "RULES_REQUIRED"
            userMessage = "Frozen rules are missing; filtering is blocked."
            businessSummary = "No filtering was executed."
            successCount = 0
            failureCount = 1
            externalTaskRef = $null
            readbackAt = $null
            failureReason = "No explicit conditions, sort or dedupe contract was supplied."
            recoveryAdvice = "Provide versioned rules from the approved requirements package."
        }
    }
    $filtered = Invoke-SelectionRuleEngine -Candidates @($parameters.candidates) -Rules $parameters.rules
    [pscustomobject]@{
        ok = $true
        status = "FILTERED"
        phase = "FILTER"
        code = $null
        userMessage = "Candidates were filtered by explicit versioned rules."
        businessSummary = "Filtered candidates generated."
        successCount = @($filtered.selected).Count
        failureCount = @($filtered.rejected).Count
        externalTaskRef = $null
        readbackAt = Get-SelectionUtcNow
        ruleVersion = $ruleVersion
        selected = [object[]]@(Protect-SelectionObject $filtered.selected)
        rejected = [object[]]@(Protect-SelectionObject $filtered.rejected)
        recoveryAdvice = "Continue to selection.execute only if write action and readback are authorized."
    }
}

function Get-SelectionNestedValue {
    param([object]$Item, [string]$Path)
    $value = $Item
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $value) { return $null }
        $property = $value.PSObject.Properties[$part]
        if (-not $property) { return $null }
        $value = $property.Value
    }
    return $value
}

function Test-SelectionRuleCondition {
    param([object]$Item, [object]$Condition)
    $field = [string]$Condition.field
    $operator = ([string]$Condition.operator).ToLowerInvariant()
    $expected = $Condition.value
    $actual = Get-SelectionNestedValue -Item $Item -Path $field
    switch ($operator) {
        "exists" { return $null -ne $actual }
        "eq" { return "$actual" -eq "$expected" }
        "neq" { return "$actual" -ne "$expected" }
        "contains" { return "$actual" -like "*$expected*" }
        "in" { return @($expected) -contains $actual }
        "gt" { return ([double]$actual) -gt ([double]$expected) }
        "gte" { return ([double]$actual) -ge ([double]$expected) }
        "lt" { return ([double]$actual) -lt ([double]$expected) }
        "lte" { return ([double]$actual) -le ([double]$expected) }
        default { throw "Unsupported rule operator: $operator" }
    }
}

function Invoke-SelectionRuleEngine {
    param([object[]]$Candidates, [object]$Rules)
    $selected = @()
    $rejected = @()
    $conditions = @($Rules.conditions)
    foreach ($candidate in $Candidates) {
        $failed = @()
        foreach ($condition in $conditions) {
            try {
                if (-not (Test-SelectionRuleCondition -Item $candidate -Condition $condition)) {
                    $failed += "condition_failed:$($condition.field):$($condition.operator)"
                }
            } catch {
                $failed += "condition_error:$($condition.field):$($_.Exception.Message)"
            }
        }
        $record = [pscustomobject]@{
            item = $candidate
            reasons = if ($failed.Count -eq 0) { @("matched") } else { $failed }
        }
        if ($failed.Count -eq 0) { $selected += $record } else { $rejected += $record }
    }
    if ($Rules.PSObject.Properties["dedupeKey"] -and $Rules.dedupeKey) {
        $seen = @{}
        $deduped = @()
        foreach ($record in $selected) {
            $keyParts = @()
            foreach ($field in @($Rules.dedupeKey)) { $keyParts += [string](Get-SelectionNestedValue -Item $record.item -Path $field) }
            $key = $keyParts -join "|"
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $deduped += $record
            } else {
                $record.reasons = @("deduped")
                $rejected += $record
            }
        }
        $selected = $deduped
    }
    [pscustomobject]@{ selected = $selected; rejected = $rejected }
}

Export-ModuleMember -Function *
