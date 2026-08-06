Set-StrictMode -Version Latest
function Start-HuiceWatcher { param([string]$ResourceId,[int]$IntervalSeconds=600)
  $existing=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object {
    [int]$_.ProcessId -ne $PID -and [string]$_.Name -ieq 'powershell.exe' -and
    [string]$_.CommandLine -match '(?i)login-agent\.ps1' -and
    [string]$_.CommandLine -match '(?i)-Action\s+Watch' -and
    [string]$_.CommandLine -match [regex]::Escape($ResourceId)
  }|Select-Object -First 1)
  if($existing.Count -gt 0){return [pscustomobject]@{pid=[int]$existing[0].ProcessId;resourceId=$ResourceId;reused=$true}}
  $script=Join-Path (Split-Path $PSScriptRoot -Parent) 'login-agent.ps1'
  $argText='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Watch -ResourceId "{1}" -IntervalSeconds {2}' -f $script,$ResourceId,$IntervalSeconds
  $p=Start-Process powershell.exe -ArgumentList $argText -WindowStyle Hidden -PassThru
  [pscustomobject]@{pid=$p.Id;resourceId=$ResourceId;startedAt=$p.StartTime.ToUniversalTime().ToString('o');script=$script;reused=$false}
}
function Stop-HuiceWatcher { param([int]$ProcessId,[string]$ResourceId)
  $p=Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if($null -eq $p -or ([string]$p.CommandLine -notmatch [regex]::Escape($ResourceId))){return [pscustomobject]@{stopped=$false;reason='instance-validation-failed'}}
  Stop-Process -Id $ProcessId -Force -ErrorAction Stop; [pscustomobject]@{stopped=$true;processId=$ProcessId}
}
Export-ModuleMember -Function Start-HuiceWatcher,Stop-HuiceWatcher
