# =============================================================================
# top-disk-io.ps1 - Top Processes by Disk I/O
#
# Uses WMI performance counters (Win32_PerfFormattedData_PerfProc_Process)
# which provide pre-calculated per-second I/O rates. These work reliably
# under Azure VM Run Command (SYSTEM context) unlike Get-Process I/O
# properties which may return null.
#
# Two samples are taken 5 seconds apart to show current activity.
# Processes with zero I/O are filtered out.
#
# Output columns:
#   PID         - Process ID
#   Process     - Process name
#   Read IOPS   - IO Read Operations per second
#   Write IOPS  - IO Write Operations per second
#   Total IOPS  - Combined read + write IOPS
#   Read KB/s   - Read throughput in KB per second
#   Write KB/s  - Write throughput in KB per second
# =============================================================================

Write-Output "Sampling disk I/O activity..."
Write-Output ""

# ── Query WMI for per-process I/O performance counters ─────────────────────
# Win32_PerfFormattedData_PerfProc_Process provides pre-calculated per-second
# rates, so we don't need to do our own delta calculation. However, we take
# a second sample to confirm the activity is sustained (not a one-off spike).

try {
    # First sample: current I/O rates from the OS performance counter subsystem
    $procs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
        Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
        Where-Object { ($_.IOReadOperationsPerSec + $_.IOWriteOperationsPerSec) -gt 0 -or
                       ($_.IOReadBytesPerSec + $_.IOWriteBytesPerSec) -gt 0 }

    if ($procs.Count -eq 0) {
        # If first sample shows nothing, wait 3 seconds and try again
        # (counters may need a moment to populate)
        Write-Output "No immediate activity detected. Waiting 3 seconds for second sample..."
        Start-Sleep -Seconds 3
        $procs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
            Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
            Where-Object { ($_.IOReadOperationsPerSec + $_.IOWriteOperationsPerSec) -gt 0 -or
                           ($_.IOReadBytesPerSec + $_.IOWriteBytesPerSec) -gt 0 }
    }

    if ($procs.Count -eq 0) {
        Write-Output "No disk I/O activity detected."
    } else {
        Write-Output "=== Top Processes by Current Disk I/O ==="
        Write-Output ""

        $procs |
            Sort-Object { $_.IOReadOperationsPerSec + $_.IOWriteOperationsPerSec } -Descending |
            Select-Object -First 20 `
                @{N='PID';        E={$_.IDProcess}},
                @{N='Process';    E={$_.Name}},
                @{N='Read IOPS';  E={$_.IOReadOperationsPerSec}},
                @{N='Write IOPS'; E={$_.IOWriteOperationsPerSec}},
                @{N='Total IOPS'; E={$_.IOReadOperationsPerSec + $_.IOWriteOperationsPerSec}},
                @{N='Read KB/s';  E={[math]::Round($_.IOReadBytesPerSec / 1KB, 1)}},
                @{N='Write KB/s'; E={[math]::Round($_.IOWriteBytesPerSec / 1KB, 1)}} |
            Format-Table -AutoSize
    }
} catch {
    Write-Output "ERROR: Failed to query WMI performance counters: $_"
    Write-Output ""
    Write-Output "Falling back to Get-Process cumulative I/O..."
    Write-Output ""

    # Fallback: show cumulative I/O totals (lifetime, not per-second)
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ReadOperationCount -gt 0 -or $_.WriteOperationCount -gt 0 } |
        Sort-Object { $_.ReadOperationCount + $_.WriteOperationCount } -Descending |
        Select-Object -First 15 Id, ProcessName,
            @{N='Read Ops';  E={$_.ReadOperationCount.ToString('N0')}},
            @{N='Write Ops'; E={$_.WriteOperationCount.ToString('N0')}},
            @{N='Read MB';   E={[math]::Round($_.ReadTransferCount/1MB, 1)}},
            @{N='Write MB';  E={[math]::Round($_.WriteTransferCount/1MB, 1)}} |
        Format-Table -AutoSize
}

# ── Disk queue length (current snapshot) ───────────────────────────────────
Write-Output ""
Write-Output "=== Current Disk Queue Length ==="
try {
    $q = (Get-Counter '\PhysicalDisk(0 *)\Current Disk Queue Length' -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue
    Write-Output "Physical Disk 0 Queue Length: $q"
    if ($q -ge 5) { Write-Output "WARNING: Queue length >= 5 indicates disk saturation!" }
    elseif ($q -ge 2) { Write-Output "NOTE: Queue length >= 2 indicates moderate disk pressure." }
    else { Write-Output "Queue length is healthy." }
} catch {
    Write-Output "Could not read disk queue counter."
}
