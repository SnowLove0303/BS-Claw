Set-StrictMode -Version Latest

function Resolve-HuicePortManagerContext {
    $agentRoot = Split-Path $PSScriptRoot -Parent
    $candidate = if (-not [string]::IsNullOrWhiteSpace($env:BSCLAW_PORT_MANAGER_ROOT)) {
        $env:BSCLAW_PORT_MANAGER_ROOT
    }
    else {
        Join-Path (Split-Path $agentRoot -Parent) 'PortManager-Phase1'
    }
    $root = [IO.Path]::GetFullPath($candidate)
    if (-not $root.StartsWith('F:\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'PortManager 必须位于 F 盘；请设置 BSCLAW_PORT_MANAGER_ROOT。'
    }
    $entry = Join-Path $root 'port-manager.ps1'
    $sqlite = Join-Path $root 'scripts\lib\PortManager.Sqlite.psm1'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf) -or
        -not (Test-Path -LiteralPath $sqlite -PathType Leaf)) {
        throw "未找到可用的 PortManager：$root"
    }
    return [pscustomobject]@{
        root = $root
        entry = $entry
        dataRoot = Join-Path $root 'data'
        jsonPath = Join-Path $root 'data\ports.json'
        sqliteModule = $sqlite
        authority = 'port_runtime_states'
    }
}

Export-ModuleMember -Function Resolve-HuicePortManagerContext
