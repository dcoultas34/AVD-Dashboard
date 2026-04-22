# FSLogix Event Log Diagnostics
# Queries the FSLogix event logs for errors, warnings, and key profile events
# to help diagnose issues like "Please Wait for the FSLogix Apps Service" hangs.

$results = [System.Collections.ArrayList]::new()

# --- Service status ---
$svc = Get-Service frxsvc -ErrorAction SilentlyContinue
if ($svc) {
    [void]$results.Add("=== FSLogix Service ===")
    [void]$results.Add("  Status: $($svc.Status)")
    [void]$results.Add("  StartType: $($svc.StartType)")
    [void]$results.Add("")
} else {
    [void]$results.Add("FSLogix service (frxsvc) NOT FOUND")
    [void]$results.Add("")
}

# --- FSLogix Profile configuration ---
$regPath = 'HKLM:\SOFTWARE\FSLogix\Profiles'
if (Test-Path $regPath) {
    [void]$results.Add("=== Profile Configuration ===")
    $enabled = (Get-ItemProperty $regPath -Name Enabled -ErrorAction SilentlyContinue).Enabled
    $vhdLocations = (Get-ItemProperty $regPath -Name VHDLocations -ErrorAction SilentlyContinue).VHDLocations
    $sizeInMBs = (Get-ItemProperty $regPath -Name SizeInMBs -ErrorAction SilentlyContinue).SizeInMBs
    [void]$results.Add("  Enabled: $enabled")
    [void]$results.Add("  VHDLocations: $vhdLocations")
    [void]$results.Add("  SizeInMBs: $sizeInMBs")
    [void]$results.Add("")
}

# --- Recent errors and warnings from FSLogix event logs (last 24 hours) ---
$cutoff = (Get-Date).AddHours(-1)
$logNames = @(
    'Microsoft-FSLogix-Apps/Operational'
    'Microsoft-FSLogix-Apps/Admin'
)

foreach ($logName in $logNames) {
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = $logName
            StartTime = $cutoff
            Level     = @(1, 2, 3)  # Critical, Error, Warning
        } -MaxEvents 30 -ErrorAction Stop

        [void]$results.Add("=== $logName (Errors/Warnings - last 1h) ===")
        foreach ($evt in $events) {
            $lvl = switch ($evt.Level) { 1 { 'CRITICAL' }; 2 { 'ERROR' }; 3 { 'WARNING' }; default { $evt.Level } }
            [void]$results.Add("  [$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] [$lvl] ID:$($evt.Id) $($evt.Message -replace "`r`n|`n", ' ' -replace '\s+', ' ')")
        }
        [void]$results.Add("")
    } catch {
        if ($_.Exception.Message -notmatch 'No events were found') {
            [void]$results.Add("=== $logName === Could not query: $_")
            [void]$results.Add("")
        } else {
            [void]$results.Add("=== $logName === No errors/warnings in last 1h")
            [void]$results.Add("")
        }
    }
}

# --- Key profile attach/detach events (informational) ---
try {
    $profileEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-FSLogix-Apps/Operational'
        StartTime = $cutoff
        Id        = @(25, 26, 57, 58, 72, 73)  # Profile attached/detached, VHD attach/detach, container attach failures
    } -MaxEvents 20 -ErrorAction Stop

    [void]$results.Add("=== Recent Profile Events (last 1h) ===")
    foreach ($evt in $profileEvents) {
        [void]$results.Add("  [$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] ID:$($evt.Id) $($evt.Message -replace "`r`n|`n", ' ' -replace '\s+', ' ')")
    }
    [void]$results.Add("")
} catch {
    if ($_.Exception.Message -notmatch 'No events were found') {
        [void]$results.Add("=== Recent Profile Events === Could not query: $_")
    } else {
        [void]$results.Add("=== Recent Profile Events === None in last 1h")
    }
    [void]$results.Add("")
}

# --- Check for VHD/VHDX mount issues ---
try {
    $mountErrors = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-FSLogix-Apps/Operational'
        StartTime = $cutoff
        Id        = @(33, 34, 52, 53)  # VHD compact/shrink errors, disk full
    } -MaxEvents 10 -ErrorAction Stop

    [void]$results.Add("=== VHD Mount/Disk Issues (last 1h) ===")
    foreach ($evt in $mountErrors) {
        [void]$results.Add("  [$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] ID:$($evt.Id) $($evt.Message -replace "`r`n|`n", ' ' -replace '\s+', ' ')")
    }
    [void]$results.Add("")
} catch {
    if ($_.Exception.Message -notmatch 'No events were found') {
        [void]$results.Add("=== VHD Mount/Disk Issues === Could not query: $_")
    }
}

$results -join "`n"
