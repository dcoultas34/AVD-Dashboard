# AppLocker Blocked Events
# Checks the AppLocker event logs for blocked EXEs, DLLs, and Scripts.
# Event ID 8004 = EXE or DLL was prevented from running.
# Event ID 8007 = Script or MSI was prevented from running.
# Reports the most recent 100 blocked events across both logs, including the
# full event message so you can see exactly what was blocked and by which rule.

$results = [System.Collections.ArrayList]::new()

[void]$results.Add("=== AppLocker Blocked Events ===")
[void]$results.Add("  Machine: $env:COMPUTERNAME")
[void]$results.Add("  Time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$results.Add("")

$logs = @(
    @{ Name = 'Microsoft-Windows-AppLocker/EXE and DLL';   BlockedId = 8004; Label = 'EXE/DLL' }
    @{ Name = 'Microsoft-Windows-AppLocker/MSI and Script'; BlockedId = 8007; Label = 'Script/MSI' }
)

$allEvents = [System.Collections.ArrayList]::new()

foreach ($log in $logs) {
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = $log.Name
            Id      = $log.BlockedId
        } -MaxEvents 100 -ErrorAction Stop

        foreach ($ev in $events) {
            [void]$allEvents.Add([PSCustomObject]@{
                Time    = $ev.TimeCreated
                Type    = $log.Label
                Message = $ev.Message
            })
        }
    } catch {
        if ($_.Exception.Message -notmatch 'No events') {
            [void]$results.Add("  WARNING: Could not read '$($log.Name)': $_")
            [void]$results.Add("")
        }
    }
}

if ($allEvents.Count -eq 0) {
    [void]$results.Add("  No AppLocker blocked events found.")
    [void]$results.Add("")
} else {
    $exeCount    = @($allEvents | Where-Object Type -eq 'EXE/DLL').Count
    $scriptCount = @($allEvents | Where-Object Type -eq 'Script/MSI').Count

    [void]$results.Add("  EXE/DLL blocked    : $exeCount event(s)")
    [void]$results.Add("  Script/MSI blocked : $scriptCount event(s)")
    [void]$results.Add("  (Most recent first, up to 100 events per log)")
    [void]$results.Add("")

    foreach ($ev in ($allEvents | Sort-Object Time -Descending)) {
        [void]$results.Add("[$($ev.Time.ToString('yyyy-MM-dd HH:mm:ss'))] [$($ev.Type)]")

        # Show the full message, cleaning up whitespace. AppLocker messages describe
        # exactly which file was blocked and which policy rule caused it.
        $msg = ($ev.Message -replace "`r`n|`n", ' ' -replace '\s+', ' ').Trim()
        [void]$results.Add("  $msg")
        [void]$results.Add("")
    }
}

[void]$results.Add("=== Summary ===")
if ($allEvents.Count -eq 0) {
    [void]$results.Add("  No blocked events found.")
} else {
    [void]$results.Add("  Total blocked: $($allEvents.Count) event(s)")
}

$results -join "`n"
