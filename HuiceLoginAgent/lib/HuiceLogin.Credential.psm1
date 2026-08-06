Set-StrictMode -Version Latest

function ConvertTo-HuiceMaskedValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($Value.Length -le 2) { return $Value.Substring(0, 1) + '***' }
    return $Value.Substring(0, 2) + '***' + $Value.Substring($Value.Length - 1, 1)
}

function New-HuiceCredentialInput {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$Account,
        [Parameter(Mandatory = $true)][Security.SecureString]$SecurePassword,
        [string]$ExistingCredentialRef,
        [switch]$ConfirmServiceAgreement
    )
    # A redirected UTF-8 stdin stream can expose its BOM as the first
    # character returned by ReadLine(). Never let that transport marker become
    # part of the merchant identity sent to the real login page.
    $tenantIdValue = $TenantId.Trim().TrimStart([char]0xFEFF)
    $accountValue = $Account.Trim().TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($tenantIdValue) -or [string]::IsNullOrWhiteSpace($accountValue) -or $SecurePassword.Length -eq 0) {
        throw '企业/卖家账号、操作员/用户账号和密码均不能为空'
    }
    $credentialRef = if ([string]::IsNullOrWhiteSpace($ExistingCredentialRef)) {
        "huice:${ResourceId}:$([Guid]::NewGuid().ToString('N'))"
    }
    else {
        $ExistingCredentialRef
    }
    return [pscustomobject]@{
        tenantId = $tenantIdValue
        account = $accountValue
        securePassword = $SecurePassword
        serviceAgreementConfirmed = [bool]$ConfirmServiceAgreement
        credentialRef = $credentialRef
        maskedAccountSummary = ('卖家账号 {0}；用户账号 {1}' -f (ConvertTo-HuiceMaskedValue $tenantIdValue),(ConvertTo-HuiceMaskedValue $accountValue))
    }
}

function Read-HuiceCredentialInput {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [string]$ExistingCredentialRef,
        [switch]$ConfirmServiceAgreement
    )
    $securePassword = $null
    if ([Console]::IsInputRedirected) {
        $tenantId = ([Console]::In.ReadLine()).Trim().TrimStart([char]0xFEFF)
        $account = ([Console]::In.ReadLine()).Trim().TrimStart([char]0xFEFF)
        $plainPassword = [Console]::In.ReadLine()
        $securePassword = [Security.SecureString]::new()
        try {
            if ($null -ne $plainPassword) {
                foreach ($character in $plainPassword.ToCharArray()) { $securePassword.AppendChar($character) }
            }
            $securePassword.MakeReadOnly()
        }
        finally {
            $plainPassword = $null
        }
    }
    else {
        $tenantId = (Read-Host '企业/卖家账号').Trim()
        $account = (Read-Host '操作员/用户账号').Trim()
        $securePassword = Read-Host '密码（输入内容不会回显）' -AsSecureString
        if (-not $ConfirmServiceAgreement) {
            $agreementInput = (Read-Host '如同意慧策页面显示的服务协议，请输入“同意”').Trim()
            $ConfirmServiceAgreement = $agreementInput -eq '同意'
        }
    }
    try {
        return New-HuiceCredentialInput -ResourceId $ResourceId -TenantId $tenantId -Account $account -SecurePassword $securePassword -ExistingCredentialRef $ExistingCredentialRef -ConfirmServiceAgreement:$ConfirmServiceAgreement
    }
    catch {
        if ($null -ne $securePassword) { $securePassword.Dispose() }
        throw
    }
}

function Remove-HuiceCredentialInput {
    param($Credential)
    if ($null -ne $Credential -and $Credential.PSObject.Properties.Name -contains 'securePassword' -and $null -ne $Credential.securePassword) {
        $Credential.securePassword.Dispose()
        $Credential.securePassword = $null
    }
    if ($null -ne $Credential) {
        $Credential.tenantId = ''
        $Credential.account = ''
    }
}

Export-ModuleMember -Function New-HuiceCredentialInput,Read-HuiceCredentialInput,Remove-HuiceCredentialInput,ConvertTo-HuiceMaskedValue
