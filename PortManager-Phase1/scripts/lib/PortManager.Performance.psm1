Set-StrictMode -Version Latest

function New-PMTimingTrace {
    param([Parameter(Mandatory = $true)][string]$Operation)
    return [pscustomobject]@{
        operation = $Operation
        stopwatch = [Diagnostics.Stopwatch]::StartNew()
        lastElapsedMs = 0L
        stages = [Collections.Generic.List[object]]::new()
    }
}

function Add-PMTimingStage {
    param(
        [Parameter(Mandatory = $true)]$Trace,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$Status = 'completed',
        [hashtable]$Details
    )
    $elapsed = [int64]$Trace.stopwatch.ElapsedMilliseconds
    $duration = $elapsed - [int64]$Trace.lastElapsedMs
    $Trace.stages.Add([pscustomobject][ordered]@{
        stage = $Stage
        durationMs = $duration
        elapsedMs = $elapsed
        status = $Status
        details = if ($null -eq $Details) { [pscustomobject]@{} } else { [pscustomobject]$Details }
    })
    $Trace.lastElapsedMs = $elapsed
}

function Complete-PMTimingTrace {
    param([Parameter(Mandatory = $true)]$Trace)
    $Trace.stopwatch.Stop()
    return [pscustomobject][ordered]@{
        operation = [string]$Trace.operation
        totalMs = [int64]$Trace.stopwatch.ElapsedMilliseconds
        stages = @($Trace.stages)
        measuredAt = [DateTimeOffset]::Now.ToString('o')
    }
}

Export-ModuleMember -Function New-PMTimingTrace,Add-PMTimingStage,Complete-PMTimingTrace
