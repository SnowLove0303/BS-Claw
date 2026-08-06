Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HuiceLogin.Configuration.psm1') -Force -DisableNameChecking
$portManager=Resolve-HuicePortManagerContext
Import-Module $portManager.sqliteModule -Force -DisableNameChecking
function Get-HuiceRegisteredResources {
  Initialize-PMSqlite -DataRoot $portManager.dataRoot -JsonPath $portManager.jsonPath
  @((Read-PMSqliteStore).resources|Where-Object {$_.platformId -eq 'huice'})
}
function Resolve-HuiceResource { param([Parameter(Mandatory=$true)][string]$ResourceId)
  $r=@(Get-HuiceRegisteredResources|Where-Object {$_.resourceId -eq $ResourceId})|Select-Object -First 1
  if($null -eq $r){throw "Resource not registered: $ResourceId"}
  if([string]$r.hostName -notin @('127.0.0.1','localhost','::1')){throw 'Only loopback resources are allowed'}
  $proc=@(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue|Where-Object {[string]$_.CommandLine -match "--remote-debugging-port=$([int]$r.port)" -and [string]$_.CommandLine -notmatch '--type='})|Select-Object -First 1
  if($null -eq $proc){throw "Chrome/CDP unavailable on port $($r.port)"}
  $m=[regex]::Match([string]$proc.CommandLine,'(?i)--user-data-dir="([^"]+)"|--user-data-dir=([^\s]+)'); $actual=if($m.Groups[1].Success){$m.Groups[1].Value}else{$m.Groups[2].Value}
  if([IO.Path]::GetFullPath($actual) -ne [IO.Path]::GetFullPath([string]$r.browserProfileDirectory)){throw 'Chrome profile does not match registered resource'}
  $r|Add-Member NoteProperty browserPid ([int]$proc.ProcessId) -Force
  $r|Add-Member NoteProperty processStartTime ((Get-Process -Id $proc.ProcessId).StartTime.ToUniversalTime().ToString('o')) -Force
  $r|Add-Member NoteProperty resolvedProfile $actual -Force; $r
}
function Ensure-HuiceResourceReady { param([Parameter(Mandatory=$true)][string]$ResourceId)
  try{return Resolve-HuiceResource $ResourceId}catch{
    $r=@(Get-HuiceRegisteredResources|Where-Object {$_.resourceId -eq $ResourceId})|Select-Object -First 1
    if($null -eq $r){throw};if([string]$r.connectionMode -ne 'Launch'){throw}
    $p=$portManager.entry
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName='powershell.exe'
    $start.Arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$p`" -Action Open -ResourceId `"$ResourceId`" -OutputFormat Json -NonInteractive -TimeoutSeconds 20 -SkipLoginMonitoring"
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8
    $start.StandardErrorEncoding=[Text.Encoding]::UTF8
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$start
    try {
      if(-not $process.Start()){throw 'PortManager Open process failed to start'}
      $stdoutTask=$process.StandardOutput.ReadToEndAsync()
      $stderrTask=$process.StandardError.ReadToEndAsync()
      if(-not $process.WaitForExit(45000)){
        try{$process.Kill()}catch{}
        try{$process.WaitForExit(5000)|Out-Null}catch{}
        $ex=[TimeoutException]::new('PortManager Open timed out after 45 seconds')
        $ex.Data['errorCode']='PORT_MANAGER_OPEN_TIMEOUT'
        throw $ex
      }
      $stdout=$stdoutTask.GetAwaiter().GetResult().Trim()
      $stderr=$stderrTask.GetAwaiter().GetResult().Trim()
      if($process.ExitCode -ne 0){
        $safe=if(-not [string]::IsNullOrWhiteSpace($stdout)){$stdout}elseif(-not [string]::IsNullOrWhiteSpace($stderr)){$stderr}else{"PortManager Open failed with exit code $($process.ExitCode)"}
        $ex=[InvalidOperationException]::new($safe)
        $ex.Data['errorCode']='PORT_MANAGER_OPEN_FAILED'
        throw $ex
      }
    }
    finally{$process.Dispose()}
    Start-Sleep -Milliseconds 800
    Resolve-HuiceResource $ResourceId
  }
}
Export-ModuleMember -Function Get-HuiceRegisteredResources,Resolve-HuiceResource,Ensure-HuiceResourceReady
