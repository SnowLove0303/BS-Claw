Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HuiceLogin.Cdp.psm1') -Force -DisableNameChecking
function Invoke-HuiceReadOnlyProbe { param($Resource)
  $page=Get-HuicePageTarget $Resource
  return Invoke-HuiceAuthRefreshAndProbe $page
}
Export-ModuleMember -Function Invoke-HuiceReadOnlyProbe
