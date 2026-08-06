Set-StrictMode -Version 2.0

$script:AllowedHuicePaths = @(
    "/openapi/api/admin/distributor/hotGoods/recommend",
    "/openapi/api/admin/goods/base/detail",
    "/scmapi/api/admin/distributor/supplier/goods/list",
    "/scmapi/api/admin/distributor/selection",
    "/scmapi/api/admin/distributor/goods/list",
    "/scmapi/api/admin/distributor/my/supplier",
    "/scmapi/api/admin/distributor/countSupplier",
    "/scmapi/api/admin/distributor/goods/stockInfo",
    "/scmapi/api/admin/distributor/goods/supplier/useNew",
    "/scmapi/api/admin/task/list",
    "/scmapi/api/admin/task/failed/list",
    "/scmapi/api/admin/task/audit/list"
)

function Get-SelectionPropertyValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-SelectionRawSecretHeader {
    param([object]$Headers)
    if ($null -eq $Headers) { return $false }
    foreach ($property in @($Headers.PSObject.Properties)) {
        $name = [string]$property.Name
        $value = [string]$property.Value
        if ($name -match "(?i)authorization|cookie|token|x-hc-token") { return $true }
        if ($value -match "(?i)^bearer\s+|token=|cookie:|x-hc-token") { return $true }
    }
    return $false
}

function Get-SelectionResponseItems {
    param([object]$Payload)
    if ($null -eq $Payload) { return @() }
    $candidates = @()
    $data = $null
    if ($Payload.PSObject.Properties["data"]) { $data = $Payload.data }
    if ($null -ne $data) {
        foreach ($name in @("items", "list", "records")) {
            $property = $data.PSObject.Properties[$name]
            if ($property) { $candidates += ,$property.Value }
        }
    }
    foreach ($name in @("items", "list", "records")) {
        $property = $Payload.PSObject.Properties[$name]
        if ($property) { $candidates += ,$property.Value }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -is [System.Collections.IEnumerable] -and -not ($candidate -is [string])) {
            return @($candidate)
        }
    }
    return @($Payload)
}

function Get-SelectionNextCursor {
    param([object]$Payload)
    foreach ($name in @("nextCursor", "cursor", "nextPageToken")) {
        $property = $Payload.PSObject.Properties[$name]
        if ($property -and $property.Value) { return $property.Value }
        if ($Payload.PSObject.Properties["data"] -and $null -ne $Payload.data) {
            $dataProperty = $Payload.data.PSObject.Properties[$name]
            if ($dataProperty -and $dataProperty.Value) { return $dataProperty.Value }
        }
    }
    return $null
}

function Invoke-SelectionHttpRequest {
    param(
        [object]$Request,
        [object]$ResourceContext,
        [int]$TimeoutSeconds = 180
    )
    if ($null -eq $Request -or -not $Request.PSObject.Properties["httpRequest"]) {
        return New-SelectionError -Code "HTTP_REQUEST_MISSING" -Message "HTTP request contract is missing." -Stage "HTTP_CONNECTOR" -TechnicalSummary "Request.httpRequest was not provided." -NextAction "Scheduler must inject a verified controlled HTTP request contract."
    }
    if ($Request.PSObject.Properties["apiContractVerified"] -and -not [bool]$Request.apiContractVerified) {
        return New-SelectionError -Code "API_CONTRACT_NOT_VERIFIED" -Message "API contract is not verified." -Stage "HTTP_CONNECTOR" -TechnicalSummary "apiContractVerified=false." -NextAction "Verify Feishu/API fields and real response before retry."
    }
    $http = $Request.httpRequest
    $path = [string](Get-SelectionPropertyValue -Object $http -Name "path")
    if ($script:AllowedHuicePaths -notcontains $path) {
        return New-SelectionError -Code "HTTP_PATH_NOT_ALLOWED" -Message "HTTP path is not in the selection allow-list." -Stage "HTTP_CONNECTOR" -TechnicalSummary $path -NextAction "Register and verify the API path before execution."
    }
    $rawHeaders = Get-SelectionPropertyValue -Object $http -Name "headers"
    if (Test-SelectionRawSecretHeader -Headers $rawHeaders) {
        return New-SelectionError -Code "RAW_SECRET_HEADER_REJECTED" -Message "Raw credential headers are not accepted by the selection module." -Stage "HTTP_CONNECTOR" -TechnicalSummary "headers contained credential-like names or values." -NextAction "Pass only scheduler-controlled non-secret invocation context."
    }
    $method = ([string](Get-SelectionPropertyValue -Object $http -Name "method")).ToUpperInvariant()
    if ($method -notin @("GET", "POST")) {
        return New-SelectionError -Code "HTTP_METHOD_NOT_ALLOWED" -Message "HTTP method is not allowed." -Stage "HTTP_CONNECTOR" -TechnicalSummary $method -NextAction "Use GET or POST for the verified connector contract."
    }
    $invokeMode = [string](Get-SelectionPropertyValue -Object $http -Name "invokeMode")
    if ([string]::IsNullOrWhiteSpace($invokeMode)) { $invokeMode = "direct-http" }
    if ($invokeMode -eq "cdp-fetch") {
        return Invoke-SelectionCdpFetch -Http $http -ResourceContext $ResourceContext -TimeoutSeconds $TimeoutSeconds
    }
    $baseUrl = [string](Get-SelectionPropertyValue -Object $http -Name "baseUrl")
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        return New-SelectionError -Code "HTTP_BASE_URL_MISSING" -Message "HTTP baseUrl is missing." -Stage "HTTP_CONNECTOR" -TechnicalSummary "No controlled baseUrl was injected." -NextAction "Inject a verified Huice baseUrl through scheduler context."
    }
    $uri = ([System.Uri]::new([System.Uri]$baseUrl, $path)).AbsoluteUri
    $headers = @{}
    if ($null -ne $rawHeaders) {
        foreach ($property in @($rawHeaders.PSObject.Properties)) {
            $headers[$property.Name] = [string]$property.Value
        }
    }
    $pageCount = 0
    $maxPagesValue = Get-SelectionPropertyValue -Object $http -Name "maxPages"
    $maxPages = if ($null -eq $maxPagesValue) { 1 } else { [int]$maxPagesValue }
    if ($maxPages -le 0) { $maxPages = 1 }
    $items = @()
    $lastPayload = $null
    $sourceAt = Get-SelectionUtcNow
    do {
        $pageCount += 1
        try {
            $params = @{
                Uri = $uri
                Method = $method
                TimeoutSec = [Math]::Max(1, $TimeoutSeconds)
                Headers = $headers
            }
            if ($method -eq "POST") {
                $params["ContentType"] = "application/json"
                $params["Body"] = ConvertTo-SelectionJsonText (Get-SelectionPropertyValue -Object $http -Name "body")
            }
            $lastPayload = Invoke-RestMethod @params
        } catch {
            return New-SelectionError -Code "HTTP_REQUEST_FAILED" -Message "Huice HTTP request failed." -Stage "HTTP_CONNECTOR" -TechnicalSummary $_.Exception.Message -Retryable:$true -RecoveryRequired:$true -NextAction "Check resource login/API-ready, rate limit and endpoint contract."
        }
        $items += @(Get-SelectionResponseItems -Payload $lastPayload)
        $cursor = Get-SelectionNextCursor -Payload $lastPayload
    } while ($cursor -and $pageCount -lt $maxPages)

    [pscustomobject]@{
        ok = $true
        status = "HTTP_OK"
        phase = "HTTP_CONNECTOR"
        itemCount = @($items).Count
        pageCount = $pageCount
        sourcePath = $path
        sourceAt = $sourceAt
        items = Protect-SelectionObject $items
        redactedResponseSummary = Protect-SelectionObject $lastPayload
        nextAction = "Normalize response and persist candidate snapshot."
    }
}

function Invoke-SelectionCdpFetch {
    param(
        [object]$Http,
        [object]$ResourceContext,
        [int]$TimeoutSeconds = 180
    )
    if ($null -eq $ResourceContext -or -not $ResourceContext.PSObject.Properties["port"]) {
        return New-SelectionError -Code "RESOURCE_CDP_PORT_MISSING" -Message "Resource CDP port is missing." -Stage "HTTP_CONNECTOR" -TechnicalSummary "ResourceContext.port is required for cdp-fetch." -NextAction "Scheduler must inject a fresh ResourceContext from PortManager."
    }
    $port = [int]$ResourceContext.port
    $request = [ordered]@{
        path = [string](Get-SelectionPropertyValue -Object $Http -Name "path")
        method = ([string](Get-SelectionPropertyValue -Object $Http -Name "method")).ToUpperInvariant()
        body = Get-SelectionPropertyValue -Object $Http -Name "body"
        maxPages = Get-SelectionPropertyValue -Object $Http -Name "maxPages"
        pageSize = Get-SelectionPropertyValue -Object $Http -Name "pageSize"
    }
    $payload = @{ port = $port; request = $request; timeoutSeconds = $TimeoutSeconds }
    try {
        $python = Get-SelectionPython -ModuleRoot $global:SelectionModuleRootForState
        $script = Join-Path $global:SelectionModuleRootForState "scripts\cdp_fetch.py"
        $json = $payload | ConvertTo-Json -Depth 30 -Compress
        $raw = $json | & $python $script
        $decoded = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
    } catch {
        return New-SelectionError -Code "CDP_FETCH_FAILED" -Message "Controlled Huice CDP fetch failed." -Stage "HTTP_CONNECTOR" -TechnicalSummary $_.Exception.Message -Retryable:$true -RecoveryRequired:$true -NextAction "Check resource browser/CDP, login/API-ready and endpoint contract."
    }
    if (-not [bool]$decoded.ok) {
        return New-SelectionError -Code "CDP_FETCH_FAILED" -Message "Controlled Huice CDP fetch failed." -Stage "HTTP_CONNECTOR" -TechnicalSummary ([string]$decoded.message) -Retryable:$true -RecoveryRequired:$true -NextAction "Check resource browser/CDP, login/API-ready and endpoint contract."
    }
    $value = $decoded.value
    if (-not [bool]$value.ok) {
        $code = if ($value.PSObject.Properties["code"] -and $value.code) { [string]$value.code } else { "HUICE_BUSINESS_RESPONSE_FAILED" }
        return New-SelectionError -Code $code -Message "Huice API returned a non-success business response." -Stage "HTTP_CONNECTOR" -TechnicalSummary (ConvertTo-SelectionJsonText (Protect-SelectionObject $value)) -Retryable:$true -RecoveryRequired:$true -NextAction "Review endpoint parameters, permissions, login state and recovery advice before retry."
    }
    [pscustomobject]@{
        ok = $true
        status = "HTTP_OK"
        phase = "HTTP_CONNECTOR"
        itemCount = [int]$value.itemCount
        pageCount = [int]$value.pageCount
        sourcePath = [string]$value.path
        sourceAt = Get-SelectionUtcNow
        items = Protect-SelectionObject $value.items
        redactedResponseSummary = Protect-SelectionObject $value.responseSummary
        pages = Protect-SelectionObject $value.pages
        nextAction = "Normalize response and persist candidate snapshot."
    }
}

Export-ModuleMember -Function *
