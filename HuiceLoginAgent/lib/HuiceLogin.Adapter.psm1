Set-StrictMode -Version Latest
function Get-HuiceLoginPatterns {
  $loginTitlePattern = '*' + [char]0x767B + [char]0x5F55 + '*'
  return @('*://login.huice.com/*','*://*.huice.com/*login*','*://*.wangdian.cn/*login*',$loginTitlePattern)
}
function Test-HuicePage($Page){ foreach($p in @('*://huice.com/*','*://*.huice.com/*','*://wangdian.cn/*','*://*.wangdian.cn/*')){if(([string]$Page.url -like $p)-or([string]$Page.title -like $p)){return $true}};return $false }
function Test-HuiceLoginPage($Page){foreach($p in Get-HuiceLoginPatterns){if(([string]$Page.url -like $p)-or([string]$Page.title -like $p)){return $true}};return $false}
Export-ModuleMember -Function Get-HuiceLoginPatterns,Test-HuicePage,Test-HuiceLoginPage
