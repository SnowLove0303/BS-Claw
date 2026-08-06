Set-StrictMode -Version 2.0

function Get-SelectionRuntimeRoot {
    param([string]$ModuleRoot)
    $configured = [Environment]::GetEnvironmentVariable("BSCLAW_SELECTION_RUNTIME_ROOT")
    if (-not [string]::IsNullOrWhiteSpace($configured)) { return $configured }
    return Join-Path $ModuleRoot "data\runtime"
}

function Get-SelectionPython {
    param([string]$ModuleRoot)
    $configured = [Environment]::GetEnvironmentVariable("BSCLAW_SELECTION_PYTHON")
    if (-not [string]::IsNullOrWhiteSpace($configured) -and (Test-Path -LiteralPath $configured)) { return $configured }
    $local = Join-Path $ModuleRoot "tools\python\python.exe"
    if (Test-Path -LiteralPath $local) { return $local }
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Python runtime not found. Set BSCLAW_SELECTION_PYTHON or provide tools\python\python.exe under the selection module."
}

function Invoke-SelectionSqlite {
    param(
        [string]$ModuleRoot,
        [object]$Command
    )
    $runtime = Get-SelectionRuntimeRoot -ModuleRoot $ModuleRoot
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $db = Join-Path $runtime "selection-module.sqlite3"
    $python = Get-SelectionPython -ModuleRoot $ModuleRoot
    $service = Join-Path $ModuleRoot "scripts\sqlite_service.py"
    $payload = $Command | ConvertTo-Json -Depth 30 -Compress
    $output = $payload | & $python $service --db $db
    if ($LASTEXITCODE -ne 0) { throw "SQLite service failed with exit code ${LASTEXITCODE}: $output" }
    if ([string]::IsNullOrWhiteSpace($output)) { return $null }
    return $output | ConvertFrom-Json
}

function Initialize-SelectionDatabase {
    param([string]$ModuleRoot)
    Invoke-SelectionSqlite -ModuleRoot $ModuleRoot -Command @{ action = "init" }
}

function Save-SelectionTaskRecord {
    param([string]$ModuleRoot, [object]$Record)
    Invoke-SelectionSqlite -ModuleRoot $ModuleRoot -Command @{ action = "save_task"; record = Protect-SelectionObject $Record }
}

function Add-SelectionEventRecord {
    param([string]$ModuleRoot, [object]$Record)
    Invoke-SelectionSqlite -ModuleRoot $ModuleRoot -Command @{ action = "add_event"; record = Protect-SelectionObject $Record }
}

function Get-SelectionTaskRecord {
    param([string]$ModuleRoot, [string]$TaskId)
    Invoke-SelectionSqlite -ModuleRoot $ModuleRoot -Command @{ action = "get_task"; taskId = $TaskId }
}

function Set-SelectionTaskTerminalRecord {
    param([string]$ModuleRoot, [string]$TaskId, [string]$Status, [string]$Reason)
    Invoke-SelectionSqlite -ModuleRoot $ModuleRoot -Command @{ action = "set_terminal"; taskId = $TaskId; status = $Status; reason = $Reason; at = Get-SelectionUtcNow }
}

function Get-SelectionRecoverableRecords {
    param([string]$ModuleRoot, [string]$TaskId)
    Invoke-SelectionSqlite -ModuleRoot $ModuleRoot -Command @{ action = "list_recoverable"; taskId = $TaskId }
}

function Get-SelectionDatabaseDiagnostics {
    param([string]$ModuleRoot)
    Invoke-SelectionSqlite -ModuleRoot $ModuleRoot -Command @{ action = "diagnostics" }
}

function Save-SelectionCandidateRecord {
    param([string]$ModuleRoot, [object]$Record)
    Invoke-SelectionSqlite -ModuleRoot $ModuleRoot -Command @{ action = "save_candidate"; record = Protect-SelectionObject $Record }
}

function Save-SelectionActionRecord {
    param([string]$ModuleRoot, [object]$Record)
    Invoke-SelectionSqlite -ModuleRoot $ModuleRoot -Command @{ action = "save_action"; record = Protect-SelectionObject $Record }
}

Export-ModuleMember -Function *
