# Top Processes by CPU/RAM
# Shows the top 15 processes sorted by CPU %, then top 15 by RAM usage.
# CPU % comes from performance counters; RAM table comes directly from
# Get-Process so every process is included (even those at 0% CPU).

$cores = (Get-CimInstance Win32_Processor |
    Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

$counters = (Get-Counter "\Process(*)\% Processor Time",
    "\Process(*)\ID Process" -ErrorAction SilentlyContinue).CounterSamples

# Build PID lookup and CPU % map from counter samples
$pidMap = @{}
$cpuMap = @{}
$counters | ForEach-Object {
    if ($_.Path -like "*\id process") {
        $pidMap[$_.InstanceName] = [int]$_.CookedValue
    } elseif ($_.Path -like "*\% processor time" -and
              $_.InstanceName -notin @("_total", "idle")) {
        $cpuMap[$_.InstanceName] = $_.CookedValue
    }
}

# Get all processes with owner info
$allProcs = Get-Process -IncludeUserName -ErrorAction SilentlyContinue

# --- Top 15 by CPU % (from perf counters, deduplicated by PID) ---
$procLookup = @{}
$allProcs | ForEach-Object { $procLookup[$_.Id] = $_ }

$seen = @{}
$cpuResults = foreach ($inst in $cpuMap.Keys) {
    $procId = $pidMap[$inst]
    if (-not $procId -or $seen.ContainsKey($procId) -or -not $procLookup.ContainsKey($procId)) { continue }
    $seen[$procId] = $true
    $p = $procLookup[$procId]
    [PSCustomObject]@{
        Name       = $p.ProcessName
        User       = $p.UserName
        PID        = $procId
        "CPU %"    = [math]::Round($cpuMap[$inst] / $cores, 1)
        "RAM (MB)" = [math]::Round($p.WorkingSet64 / 1MB, 0)
    }
}

"--- Top 15 by CPU % ---"
$cpuResults | Sort-Object "CPU %" -Descending | Select-Object -First 15 | Format-Table -AutoSize

# --- Top 15 by RAM (directly from Get-Process, includes all processes) ---
# Build a PID-to-service lookup so svchost entries show which service they host.
# Uses tasklist /svc which reliably shows services per PID in all contexts.
$svcByPid = @{}
try {
    $tasklistOutput = & tasklist /svc /fo csv /nh 2>$null
    foreach ($line in $tasklistOutput) {
        $parts = $line -replace '"','' -split ','
        if ($parts.Count -ge 3 -and $parts[2] -ne 'N/A') {
            $tPid = [int]$parts[1]
            $svcByPid[$tPid] = $parts[2]
        }
    }
} catch {}

$ramResults = $allProcs |
    Where-Object { $_.ProcessName -notin @('Idle', 'System') -and $_.WorkingSet64 -gt 0 } |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First 15 |
    ForEach-Object {
        # For svchost, append the hosted service name(s) so the Name column is self-descriptive
        $name = $_.ProcessName
        if ($name -eq 'svchost' -and $svcByPid.ContainsKey($_.Id)) {
            $name = "svchost ($($svcByPid[$_.Id]))"
        }
        [PSCustomObject]@{
            Name       = $name
            User       = $_.UserName
            PID        = $_.Id
            "RAM (MB)" = [math]::Round($_.WorkingSet64 / 1MB, 0)
        }
    }

""
"--- Top 15 by RAM (MB) ---"
$ramResults | Format-Table -AutoSize
