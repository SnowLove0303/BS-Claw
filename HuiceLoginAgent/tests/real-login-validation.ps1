[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidatePattern('^HCP-[A-F0-9]{8}$')][string]$ResourceId)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$portManagerRoot = [IO.Path]::GetFullPath((Join-Path $root '..\PortManager-Phase1'))
$pythonPrerequisitePath = Join-Path $portManagerRoot 'tests\helpers\Require-FDrivePython.ps1'
. $pythonPrerequisitePath
try {
    $env:BSCLAW_PYTHON_PATH = Resolve-BSClawTestPython -ProjectRoot $portManagerRoot
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
$entry = Join-Path $root 'login-agent.ps1'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action List -OutputFormat Json -NonInteractive
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $entry -Action Check -ResourceId $ResourceId -OutputFormat Json -NonInteractive
exit $LASTEXITCODE
