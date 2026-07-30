Set-StrictMode -Version Latest
$script:HuiceStates=@('not-logged-in','logging-in','manual-verification','login-failed','success-pending-review','logged-in','session-expired','unknown','detection-failed')
function Set-HuiceState { param([string]$State,[string]$Reason='');if($State -notin $script:HuiceStates){throw "Unsupported state: $State"};[pscustomobject]@{status=$State;reason=$Reason;changedAt=[DateTimeOffset]::Now.ToString('o')} }
Export-ModuleMember -Function Set-HuiceState
