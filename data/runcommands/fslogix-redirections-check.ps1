# FSLogix Redirections.xml Check
# Scans the FSLogix Profile log files on disk for redirections.xml processing
# entries. FSLogix does NOT log redirections events to the Windows Event Log -
# they only appear in the flat log files at C:\ProgramData\FSLogix\Logs\Profile.
#
# Key log entries this script looks for:
#   - "RedirXMLSourceFolder" - registry config showing where the XML is sourced from
#   - "Attempting to copy" + "Redirections.xml" - FSLogix copying the file locally
#   - "Redirections.xml copy success" - file copied OK
#   - "Reading profile folder redirections" - FSLogix parsing the exclusions
#   - "Creating base folder" - each exclusion path being applied
#   - Any errors or failures related to redirections

$results = [System.Collections.ArrayList]::new()
$logRoot = 'C:\ProgramData\FSLogix\Logs\Profile'

[void]$results.Add("=== FSLogix Redirections.xml Check (Log Files) ===")
[void]$results.Add("  Log path: $logRoot")
[void]$results.Add("")

# --- Check registry config ---
[void]$results.Add("--- Registry Configuration ---")
$regPath = 'HKLM:\SOFTWARE\FSLogix\Profiles'
$redirSource = (Get-ItemProperty $regPath -Name RedirXMLSourceFolder -ErrorAction SilentlyContinue).RedirXMLSourceFolder
if ($redirSource) {
    [void]$results.Add("  RedirXMLSourceFolder: $redirSource")
    $xmlPath = Join-Path $redirSource 'Redirections.xml'
    try {
        if (Test-Path $xmlPath -ErrorAction Stop) {
            $fi = Get-Item $xmlPath -ErrorAction Stop
            [void]$results.Add("  File exists: YES ($($fi.Length) bytes, modified $($fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))")
            # Quick XML validation
            try {
                [xml]$null = Get-Content $xmlPath -Raw -ErrorAction Stop
                [void]$results.Add("  XML validation: OK")
            } catch {
                [void]$results.Add("  XML validation: FAILED - $($_.Exception.Message)")
            }
        } else {
            [void]$results.Add("  File exists: NO - $xmlPath not found!")
        }
    } catch {
        [void]$results.Add("  File access: SKIPPED - Run Command (SYSTEM) cannot access UNC path $xmlPath")
        [void]$results.Add("  This is expected - SYSTEM has no network credentials for file shares.")
        [void]$results.Add("  The log file analysis below will confirm whether FSLogix processed it at user logon.")
    }
} else {
    [void]$results.Add("  RedirXMLSourceFolder: NOT SET - FSLogix won't process redirections.xml")
}
[void]$results.Add("")

# --- Scan FSLogix Profile log files ---
if (-not (Test-Path $logRoot)) {
    [void]$results.Add("  [ERROR] Log folder not found: $logRoot")
    $results -join "`n"
    return
}

# Get log files modified in the last hour, newest first
$cutoff = (Get-Date).AddHours(-1)
$logFiles = @(Get-ChildItem -Path $logRoot -Filter '*.log' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt $cutoff } |
    Sort-Object LastWriteTime -Descending)

if ($logFiles.Count -eq 0) {
    [void]$results.Add("  No Profile log files modified in the last hour.")
    [void]$results.Add("  A user logon is needed to generate redirections log entries.")
    $results -join "`n"
    return
}

[void]$results.Add("--- Log File Analysis ($($logFiles.Count) file(s) from last hour) ---")
[void]$results.Add("")

# Patterns to search for in the log files
$patterns = @(
    'RedirXMLSourceFolder',
    'Redirections\.xml',
    'Redirections.xml',
    'Reading profile folder redirections',
    'Creating base folder',
    'redirect',
    'Redirect'
)
$combinedPattern = ($patterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
# Use a simpler pattern for the match since some have regex already
$matchPattern = 'RedirXMLSourceFolder|[Rr]edirections\.xml|[Rr]edirections.xml|Reading profile folder redirections|Creating base folder|[Rr]edirect'

$foundEntries = $false

foreach ($file in $logFiles) {
    [void]$results.Add("  -- $($file.Name)")
    [void]$results.Add("     Modified: $($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))")

    # FSLogix Profile logs are UTF-16LE
    try {
        $lines = [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::Unicode)
    } catch {
        try { $lines = Get-Content $file.FullName -ErrorAction Stop } catch { $lines = @() }
    }

    $hitCount = 0
    foreach ($line in $lines) {
        if ($line -match $matchPattern) {
            $hitCount++
            $trimmed = $line.Trim()

            # Colour-code: errors in red, success in green, info in default
            if ($trimmed -match 'fail|error|denied|not found|not set') {
                [void]$results.Add("     [ERROR] $trimmed")
            } elseif ($trimmed -match 'success|Creating base folder') {
                [void]$results.Add("     [OK]    $trimmed")
            } else {
                [void]$results.Add("     [INFO]  $trimmed")
            }
        }
    }

    if ($hitCount -eq 0) {
        [void]$results.Add("     No redirections entries found in this log file.")
    } else {
        $foundEntries = $true
    }
    [void]$results.Add("")
}

# --- Summary ---
[void]$results.Add("--- Summary ---")
if ($foundEntries) {
    [void]$results.Add("  Redirections.xml processing found in log files above.")
} else {
    [void]$results.Add("  No redirections.xml processing found in any recent log files.")
    [void]$results.Add("  This may mean no user has logged on recently, or RedirXMLSourceFolder is not configured.")
}

$results -join "`n"
