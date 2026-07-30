[CmdletBinding()]
param(
    [ValidateSet('Menu','List','Check','Login','Watch')][string]$Action = 'Menu',
    [string]$ResourceId,
    [ValidateSet('Text','Json')][string]$OutputFormat = 'Text',
    [switch]$NonInteractive,
    [switch]$ConfirmServiceAgreement,
    [int]$IntervalSeconds = 600
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:AgentProcessStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
$root = $PSScriptRoot
Import-Module "$root\lib\HuiceLogin.ResourceResolver.psm1" -Force -DisableNameChecking
Import-Module "$root\lib\HuiceLogin.Cdp.psm1" -Force -DisableNameChecking
Import-Module "$root\lib\HuiceLogin.Credential.psm1" -Force -DisableNameChecking
Import-Module "$root\lib\HuiceLogin.HttpLogin.psm1" -Force -DisableNameChecking
Import-Module "$root\lib\HuiceLogin.Persistence.psm1" -Force -DisableNameChecking
Import-Module "$root\lib\HuiceLogin.Watcher.psm1" -Force -DisableNameChecking

function Out-Result {
    param([bool]$Ok,$Data,[string]$Message,[string]$ErrorCode)
    $result = [pscustomobject]@{
        success = $Ok
        message = $Message
        data = $Data
        nextAction = if ($Ok) { '可继续使用当前资源' } elseif ($ErrorCode -eq 'SERVICE_AGREEMENT_CONFIRMATION_REQUIRED') { '确认同意慧策页面显示的服务协议后，使用 -ConfirmServiceAgreement 重新执行登录' } elseif ($ErrorCode -eq 'IMAGE_VERIFICATION_REQUIRED') { '慧策要求图形验证码；当前版本尚未接入验证码续接，不能继续自动登录' } elseif ($ErrorCode -match 'VERIFICATION_REQUIRED') { '当前账号触发慧策安全验证，请按错误码处理后重新执行登录' } elseif ($ErrorCode -eq 'INVALID_CREDENTIALS') { '请检查企业账号、用户账号和密码后重试' } else { '根据错误码处理后重试' }
        errorCode = if ($Ok) { $null } else { $ErrorCode }
        resourceId = $ResourceId
    }
    if ($OutputFormat -eq 'Json') { $result | ConvertTo-Json -Depth 12 } else { $result }
}

function New-HuiceFailureEvidence {
    param([string]$Status,[string]$ErrorCode,[string]$Summary)
    $e = [pscustomobject]@{
        status = $Status
        evidenceType = 'live-cdp-api'
        summary = $Summary
        checkedAt = [DateTimeOffset]::Now.ToString('o')
    }
    $e | Add-Member NoteProperty authResult ([pscustomobject]@{ status=$Status; errorCode=$ErrorCode }) -Force
    return $e
}

function Invoke-HuiceCheckOnce {
    param($Resource,[switch]$NoSave)
    $evidence = Get-HuiceLiveEvidence $Resource
    if ($evidence.status -eq 'platform-page') {
        $page = Get-HuicePageTarget $Resource
        $auth = Invoke-HuiceAuthRefreshAndProbe $page
        $evidence | Add-Member NoteProperty authResult $auth -Force
        $evidence.status = [string]$auth.status
    }
    if ($Action -eq 'Watch') {
        $heartbeat = [DateTimeOffset]::Now
        $evidence | Add-Member NoteProperty watcherPid ([int]$PID) -Force
        $evidence | Add-Member NoteProperty watcherProcessStartTime $script:AgentProcessStart -Force
        $evidence | Add-Member NoteProperty watcherHeartbeatAt $heartbeat.ToString('o') -Force
        $evidence | Add-Member NoteProperty watcherLastCheckAt $heartbeat.ToString('o') -Force
        $evidence | Add-Member NoteProperty watcherNextCheckAt $heartbeat.AddSeconds([Math]::Max(10,$IntervalSeconds)).ToString('o') -Force
    }
    if (-not $NoSave) { Save-HuiceSession $Resource $evidence $null | Out-Null }
    return $evidence
}

function Enter-HuiceErpProduct {
    param($Resource,[int]$TimeoutSeconds = 20)
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $lastStatus = 'erp-product-not-ready'
    do {
        $live = Get-HuiceLiveEvidence $Resource
        if ($live.status -eq 'platform-page' -and $live.pageUrl -eq 'https://erp.huice.com/') {
            return [pscustomobject]@{ clicked = $true; status = 'erp-page-ready' }
        }
        if ($live.status -eq 'product-selection') {
            try {
                $attempt = Open-HuiceErpProduct $Resource
                $lastStatus = [string]$attempt.status
            }
            catch {
                $lastStatus = 'erp-product-click-failed'
            }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTimeOffset]::Now -lt $deadline)
    return [pscustomobject]@{ clicked = $false; status = $lastStatus }
}

Initialize-HuicePersistence | Out-Null

if ($Action -eq 'List') {
    $resources = [object[]]@(Get-HuiceRegisteredResources)
    Out-Result -Ok $true -Data $resources -Message 'resource-list' -ErrorCode $null
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ResourceId) -and $Action -ne 'Menu') {
    $ResourceId = (Get-HuiceRegisteredResources | Select-Object -First 1).resourceId
}

if ($Action -eq 'Menu') {
    Write-Host '慧策登录适配器'
    Write-Host '1. 查看慧策资源'
    Write-Host '2. 检查登录与接口状态'
    Write-Host '3. 登录或复用现有会话'
    Write-Host '4. 持续监测登录状态'
    Write-Host '0. 退出'
    $selection = Read-Host '请选择操作'
    if ($selection -eq '1') { $Action = 'List' }
    elseif ($selection -eq '2') { $Action = 'Check' }
    elseif ($selection -eq '3') { $Action = 'Login' }
    elseif ($selection -eq '4') { $Action = 'Watch' }
    else { exit 0 }
    if (-not $ResourceId -and $Action -ne 'List') { $ResourceId = Read-Host '请输入资源编号' }
}

if ($Action -eq 'Watch') {
    while ($true) {
        $lease = $null
        $resource = $null
        $nextDelay = [Math]::Max(10,$IntervalSeconds)
        try {
            $resource = Resolve-HuiceResource $ResourceId
            $lease = Acquire-HuiceLease -ResourceId $ResourceId -Operation 'Watch' -DurationSeconds 30
            Invoke-HuiceCheckOnce $resource | Out-Null
        }
        catch {
            $code = if ($_.Exception.Data.Contains('errorCode')) { [string]$_.Exception.Data['errorCode'] } elseif ($_.Exception.Message -eq 'RESOURCE_BUSY') { 'RESOURCE_BUSY' } else { 'WATCHER_CHECK_FAILED' }
            if ($code -eq 'RESOURCE_BUSY') { $nextDelay = 10 }
            $safeMessage = ([string]$_.Exception.Message) -replace '(?i)(password|passwd|cookie|token|authorization|bearer)\s*[:=]\s*\S+','$1=[已脱敏]'
            try { Write-HuiceAudit -Action 'HuiceLoginWatcher' -ResourceId $ResourceId -Outcome 'Failed' -ErrorCode $code -Message ($code+': '+$safeMessage) | Out-Null } catch { }
            if ($null -ne $resource -and $code -ne 'RESOURCE_BUSY') {
                try {
                    $failure = New-HuiceFailureEvidence -Status 'detection-failed' -ErrorCode $code -Summary 'Watcher real check failed'
                    $heartbeat = [DateTimeOffset]::Now
                    $failure | Add-Member NoteProperty watcherPid ([int]$PID) -Force
                    $failure | Add-Member NoteProperty watcherProcessStartTime $script:AgentProcessStart -Force
                    $failure | Add-Member NoteProperty watcherHeartbeatAt $heartbeat.ToString('o') -Force
                    $failure | Add-Member NoteProperty watcherNextCheckAt $heartbeat.AddSeconds(30).ToString('o') -Force
                    $failure | Add-Member NoteProperty watcherErrorCode $code -Force
                    Save-HuiceSession $resource $failure $null | Out-Null
                } catch { }
            }
        }
        finally {
            if ($null -ne $lease) { Release-HuiceLease $lease }
        }
        Start-Sleep -Seconds $nextDelay
    }
}

$lease = $null
$resource = $null
$credential = $null
try {
    $resource = Ensure-HuiceResourceReady $ResourceId
    $duration = if ($Action -eq 'Login') { 600 } else { 45 }
    $lease = Acquire-HuiceLease -ResourceId $ResourceId -Operation $Action -DurationSeconds $duration

    if ($Action -eq 'Check') {
        $evidence = Invoke-HuiceCheckOnce $resource
        $ok = $evidence.status -eq 'logged-in-api-ready'
        $code = if ($ok) { $null } elseif ($evidence.PSObject.Properties.Name -contains 'authResult' -and $evidence.authResult.PSObject.Properties.Name -contains 'errorCode') { [string]$evidence.authResult.errorCode } else { [string]$evidence.status }
        Out-Result $ok $evidence ("status: $($evidence.status)") $code
        exit $(if ($ok) { 0 } else { 2 })
    }

    $loginResult = $null
    $needsCredential = $false
    $initialEvidence = Invoke-HuiceCheckOnce $resource -NoSave
    if ($initialEvidence.status -eq 'logged-in-api-ready') {
        Save-HuiceSession $resource $initialEvidence $null | Out-Null
        Out-Result $true $initialEvidence 'logged-in-api-ready（已复用现有会话）' $null
        exit 0
    }
    elseif ($initialEvidence.status -eq 'product-selection') {
        $selection = Enter-HuiceErpProduct $resource
        if (-not [bool]$selection.clicked) {
            $failure = New-HuiceFailureEvidence -Status 'detection-failed' -ErrorCode 'ERP_PRODUCT_SELECTION_FAILED' -Summary '已登录，但旺店通 ERP 入口未能打开'
            Save-HuiceSession $resource $failure $null | Out-Null
            Out-Result $false $failure '无法进入旺店通 ERP' 'ERP_PRODUCT_SELECTION_FAILED'
            exit 2
        }
        if ($OutputFormat -eq 'Text') { Write-Host '已检测到慧策登录会话，正在自动进入旺店通 ERP3.0' }
    }
    else {
        if ($initialEvidence.status -eq 'login-required') {
            $needsCredential = $true
        }
        else {
            $failure = New-HuiceFailureEvidence -Status 'detection-failed' -ErrorCode 'LOGIN_STATE_UNRESOLVED' -Summary '无法确认慧策登录页面状态'
            Save-HuiceSession $resource $failure $null | Out-Null
            Out-Result $false $failure '无法确认登录状态' 'LOGIN_STATE_UNRESOLVED'
            exit 2
        }
    }

    if ($needsCredential) {
        if ($NonInteractive) {
            $failure = New-HuiceFailureEvidence -Status 'login-required' -ErrorCode 'CREDENTIAL_INPUT_REQUIRED' -Summary '当前会话不可用，需要交互式安全输入'
            Save-HuiceSession $resource $failure $null | Out-Null
            Out-Result $false $failure '需要重新登录' 'CREDENTIAL_INPUT_REQUIRED'
            exit 2
        }
        $credential = Read-HuiceCredentialInput -ResourceId $ResourceId -ExistingCredentialRef ([string]$resource.credentialRef) -ConfirmServiceAgreement:$ConfirmServiceAgreement
        Open-HuiceLoginPage $resource
        $loginPageDeadline = [DateTimeOffset]::Now.AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            $loginPage = Get-HuicePageTarget $resource
            if (([Uri]$loginPage.url).Host -eq 'login.huice.com') { break }
        } while ([DateTimeOffset]::Now -lt $loginPageDeadline)
        Start-Sleep -Milliseconds 500
        $postInputGate = Invoke-HuiceCheckOnce $resource -NoSave
        if ($postInputGate.status -eq 'product-selection') {
            $selection = Enter-HuiceErpProduct $resource
            if (-not [bool]$selection.clicked) {
                $failure = New-HuiceFailureEvidence -Status 'detection-failed' -ErrorCode 'ERP_PRODUCT_SELECTION_FAILED' -Summary '输入完成后检测到已有会话，但旺店通 ERP 入口未能打开'
                Save-HuiceSession $resource $failure $null | Out-Null
                Out-Result $false $failure '无法进入旺店通 ERP' 'ERP_PRODUCT_SELECTION_FAILED'
                exit 2
            }
            if ($OutputFormat -eq 'Text') { Write-Host '输入完成后检测到已有慧策会话，正在自动进入旺店通 ERP3.0' }
        }
        elseif ($postInputGate.status -eq 'logged-in-api-ready') {
            Save-HuiceSession $resource $postInputGate $null | Out-Null
            Out-Result $true $postInputGate 'logged-in-api-ready（输入期间会话已就绪）' $null
            exit 0
        }
        elseif ($postInputGate.status -ne 'login-required') {
            $failure = New-HuiceFailureEvidence -Status 'detection-failed' -ErrorCode 'LOGIN_STATE_UNRESOLVED_AFTER_INPUT' -Summary '输入完成后无法确认慧策登录页面状态'
            Save-HuiceSession $resource $failure $null | Out-Null
            Out-Result $false $failure '输入完成后无法确认登录状态' 'LOGIN_STATE_UNRESOLVED_AFTER_INPUT'
            exit 2
        }
        if ($postInputGate.status -eq 'login-required') {
        $loginResult = Invoke-HuiceHttpLogin -Resource $resource -Credential $credential
        if ($loginResult.status -ne 'http-login-succeeded' -and $loginResult.status -ne 'session-already-ready') {
            $verificationRequired = $loginResult.PSObject.Properties.Name -contains 'verificationRequired' -and [bool]$loginResult.verificationRequired
            $failureStatus = if ($verificationRequired) { 'security-verification-required' } else { 'login-required' }
            $failure = New-HuiceFailureEvidence -Status $failureStatus -ErrorCode ([string]$loginResult.errorCode) -Summary '慧策 HTTP 登录未建立可用会话'
            $failure | Add-Member NoteProperty authResult $loginResult -Force
            Save-HuiceSession $resource $failure $credential | Out-Null
            Out-Result $false $failure '登录失败' ([string]$loginResult.errorCode)
            exit 2
        }
        if ($OutputFormat -eq 'Text') { Write-Host '慧策账号登录请求已成功，正在确认端口会话与接口状态' }
        }
    }

    $deadline = [DateTimeOffset]::Now.AddSeconds(90)
    do {
        $evidence = Invoke-HuiceCheckOnce $resource -NoSave
        if ($evidence.status -eq 'product-selection') {
            $selection = Enter-HuiceErpProduct $resource
            if (-not [bool]$selection.clicked) {
                $failure = New-HuiceFailureEvidence -Status 'detection-failed' -ErrorCode 'ERP_PRODUCT_SELECTION_FAILED' -Summary '登录已通过，但旺店通 ERP 入口未能打开'
                Save-HuiceSession $resource $failure $null | Out-Null
                Out-Result $false $failure '无法进入旺店通 ERP' 'ERP_PRODUCT_SELECTION_FAILED'
                exit 2
            }
            if ($OutputFormat -eq 'Text') { Write-Host '已检测到登录完成，正在进入旺店通 ERP' }
        }
        elseif ($evidence.status -eq 'login-required') {
            $pageOutcome = Get-HuiceLoginPageOutcome $resource
            if ($pageOutcome.status -in @('security-verification-required','login-failed')) {
                $failure = New-HuiceFailureEvidence -Status ([string]$pageOutcome.status) -ErrorCode ([string]$pageOutcome.errorCode) -Summary '慧策登录页返回了需要处理的状态'
                $failure | Add-Member NoteProperty pageOutcome $pageOutcome -Force
                Save-HuiceSession $resource $failure $credential | Out-Null
                Out-Result $false $failure '自动登录未完成' ([string]$pageOutcome.errorCode)
                exit 2
            }
        }
        elseif ($evidence.status -eq 'logged-in-api-ready') {
            if ($null -ne $loginResult) { $evidence | Add-Member NoteProperty loginHttpResult $loginResult -Force }
            Save-HuiceSession $resource $evidence $credential | Out-Null
            Out-Result $true $evidence 'logged-in-api-ready' $null
            exit 0
        }
        elseif ($evidence.status -eq 'session-expired') {
            Save-HuiceSession $resource $evidence $credential | Out-Null
            Out-Result $false $evidence '登录会话未能建立或已失效' 'SESSION_EXPIRED'
            exit 2
        }
        elseif ($evidence.status -in @('permission-denied','refresh-failed','probe-failed','wrong-host')) {
            Save-HuiceSession $resource $evidence $null | Out-Null
            $code = if ($evidence.authResult.PSObject.Properties.Name -contains 'errorCode') { [string]$evidence.authResult.errorCode } else { [string]$evidence.status }
            Out-Result $false $evidence ("status: $($evidence.status)") $code
            exit 2
        }
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::Now -lt $deadline)

    $timeoutEvidence = New-HuiceFailureEvidence -Status 'login-timeout' -ErrorCode 'HTTP_LOGIN_SESSION_BIND_TIMEOUT' -Summary '慧策账号登录已返回成功，但端口会话未在限定时间内进入 ERP'
    Save-HuiceSession $resource $timeoutEvidence $credential | Out-Null
    Out-Result $false $timeoutEvidence '登录会话绑定超时' 'HTTP_LOGIN_SESSION_BIND_TIMEOUT'
    exit 2
}
catch {
    $safeMessage = ([string]$_.Exception.Message) -replace '(?i)(password|passwd|cookie|token|authorization|bearer)\s*[:=]\s*\S+','$1=[已脱敏]'
    $code = if ($_.Exception.Data.Contains('errorCode')) {
        [string]$_.Exception.Data['errorCode']
    }
    elseif ($safeMessage -eq 'RESOURCE_BUSY') { 'RESOURCE_BUSY' }
    elseif ($safeMessage -match '^Resource not registered:') { 'RESOURCE_NOT_FOUND' }
    elseif ($safeMessage -match 'profile does not match') { 'PROFILE_MISMATCH' }
    elseif ($safeMessage -match 'Chrome/CDP unavailable') { 'CDP_UNAVAILABLE' }
    elseif ($safeMessage -match 'Huice page not found') { 'HUICE_PAGE_NOT_FOUND' }
    elseif ($safeMessage -match 'SQLite|database|schema|checksum') { 'PERSISTENCE_FAILED' }
    elseif ($safeMessage -match 'timeout|超时') { 'OPERATION_TIMEOUT' }
    else { 'HUICE_AGENT_ERROR' }
    Out-Result $false $null $safeMessage $code
    exit 1
}
finally {
    if ($null -ne $credential) { Remove-HuiceCredentialInput $credential }
    if ($null -ne $lease) { Release-HuiceLease $lease }
}
