# Recent Errors - All Event Logs (Last 15 Minutes)
# Queries all Windows event logs for Critical and Error events in the last
# 15 minutes. Groups results by log name for easy scanning. Useful for
# quickly identifying what's going wrong on a session host after a reported issue.

$cutoff = (Get-Date).AddMinutes(-15)
$results = [System.Collections.ArrayList]::new()

[void]$results.Add("=== Recent Errors Across All Event Logs ===")
[void]$results.Add("  Window: Last 15 minutes (since $($cutoff.ToString('HH:mm:ss')))")
[void]$results.Add("  Machine: $env:COMPUTERNAME")
[void]$results.Add("")

$totalErrors = 0
$totalCritical = 0

try {
    # Query all logs for Critical (Level 1) and Error (Level 2) events.
    # LogName = '*' is required in PS 5.1 — omitting it throws "You must specify
    # at least one Log, Provider or Path key-value pair."
    $events = Get-WinEvent -FilterHashtable @{
        LogName   = '*'
        Level     = @(1, 2)
        StartTime = $cutoff
    } -MaxEvents 200 -ErrorAction Stop

    # Group by log name for readability
    $grouped = $events | Group-Object LogName | Sort-Object Count -Descending

    foreach ($group in $grouped) {
        [void]$results.Add("--- $($group.Name) ($($group.Count) event(s)) ---")
        [void]$results.Add("")

        foreach ($ev in ($group.Group | Sort-Object TimeCreated -Descending)) {
            $lvl = if ($ev.Level -eq 1) { 'CRITICAL'; $totalCritical++ } else { 'ERROR'; $totalErrors++ }
            $msg = ($ev.Message -replace "`r`n|`n", ' ' -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }

            [void]$results.Add("  [$($ev.TimeCreated.ToString('HH:mm:ss'))] [$lvl] ID:$($ev.Id) $($ev.ProviderName)")
            [void]$results.Add("    $msg")
            [void]$results.Add("")
        }
    }
} catch {
    if ($_.Exception.Message -match 'No events were found') {
        [void]$results.Add("  No errors or critical events in the last 15 minutes.")
    } else {
        [void]$results.Add("  Error querying event logs: $_")
    }
    [void]$results.Add("")
}

# --- Summary ---
[void]$results.Add("=== Summary ===")
$total = $totalErrors + $totalCritical
if ($total -eq 0) {
    [void]$results.Add("  No errors found in the last 15 minutes.")
} else {
    [void]$results.Add("  $totalCritical critical, $totalErrors error(s) across $(@($grouped).Count) log(s)")
}

$results -join "`n"
