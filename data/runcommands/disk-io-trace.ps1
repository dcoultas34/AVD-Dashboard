# =============================================================================
# disk-io-trace.ps1 - ETW Disk I/O File Trace (10 seconds)
#
# PURPOSE:
# The "Top Processes by Disk I/O" command shows System (PID 4) as the top
# consumer because kernel-level drivers (FSLogix VHD, NTFS metadata, AV
# filter drivers, page file) attribute I/O to the System process. This
# trace goes deeper: it uses Event Tracing for Windows (ETW) to capture
# actual file paths being accessed, revealing WHAT is causing the I/O.
#
# BEST USED ON: Busy session hosts with high IOPS. On quiet machines the
# trace may only capture its own I/O activity.
#
# HOW IT WORKS:
# 1. Creates a 10-second ETW trace session using the built-in Windows
#    'Microsoft-Windows-Kernel-File' provider (no installs needed)
# 2. This provider logs every file create/read/write/close at the kernel
#    level, including the full file path
# 3. After 10 seconds, stops the trace and parses the .etl file using
#    Get-WinEvent to extract file paths and operation counts
# 4. Filters out the trace's own temp files to avoid self-reporting
# 5. Groups results by directory and file, sorted by busiest first
# 6. Cleans up the temp .etl file (wrapped in try/finally for safety)
#
# OVERHEAD:
# - CPU: ~1-3% (ETW is designed for production use)
# - Memory: 64KB circular buffer
# - Disk: temp .etl file typically 1-10MB, deleted after parsing
# - Duration: ~15 seconds total (10s trace + 5s parsing)
# - Impact on users: none visible
# =============================================================================

$traceName = 'AVD-DiskIO-Trace'
$etlPath   = "$env:TEMP\$traceName.etl"

# ── Cleanup any previous trace that might be lingering ─────────────────────
logman stop $traceName -ets 2>$null | Out-Null
if (Test-Path $etlPath) { Remove-Item $etlPath -Force -ErrorAction SilentlyContinue }

Write-Output "Starting 10-second disk I/O trace..."
Write-Output "(ETW provider: Microsoft-Windows-Kernel-File, ~1-3% CPU overhead)"
Write-Output "(Best results on busy hosts with high IOPS)"
Write-Output ""

try {
    # ── Start the ETW trace session ────────────────────────────────────────
    # -p  = provider GUID/name
    # -ets = Event Trace Session (real-time, no logman data collector needed)
    # -bs  = buffer size in KB
    # -nb  = min/max buffers
    # -o   = output .etl file path
    # Keywords 0x1063 = FileCreate | FileRead | FileWrite | FileDelete
    # Level 0x4 = Informational
    $startResult = logman start $traceName -p 'Microsoft-Windows-Kernel-File' 0x0000000000001063 0x4 -ets -bs 64 -nb 16 64 -o $etlPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output "ERROR: Failed to start ETW trace. logman output:"
        Write-Output $startResult
        Write-Output ""
        Write-Output "This may require Administrator privileges or the trace name may already be in use."
        return
    }

    # ── Wait 10 seconds while the trace captures file I/O events ───────────
    Write-Output "Tracing file I/O activity for 10 seconds..."
    Start-Sleep -Seconds 10

    # ── Stop the trace ─────────────────────────────────────────────────────
    logman stop $traceName -ets 2>$null | Out-Null
    Write-Output "Trace complete. Parsing results..."
    Write-Output ""

    # ── Parse the ETL file ─────────────────────────────────────────────────
    $events = @()
    try {
        $events = Get-WinEvent -Path $etlPath -Oldest -ErrorAction Stop
    } catch {
        Write-Output "WARNING: Could not parse ETL file: $_"
        return
    }

    if ($events.Count -eq 0) {
        Write-Output "No file I/O events captured during the 10-second trace."
        return
    }

    Write-Output "Captured $($events.Count) file I/O events in 10 seconds."
    Write-Output ""

    # ── Extract file paths from events ─────────────────────────────────────
    $filePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($evt in $events) {
        $path = $null
        try {
            if ($evt.Properties -and $evt.Properties.Count -gt 0) {
                foreach ($prop in $evt.Properties) {
                    $val = [string]$prop.Value
                    # Look for values that look like file paths (contain backslash, min length)
                    if ($val -match '\\' -and $val.Length -gt 3 -and $val -notmatch '^\{') {
                        $path = $val
                        break
                    }
                }
            }
            if (-not $path -and $evt.Message) {
                if ($evt.Message -match '(?:FileName|File):\s*(.+)') {
                    $path = $Matches[1].Trim()
                }
            }
        } catch {}

        if ($path) { $filePaths.Add($path) }
    }

    # ── Filter out the trace's own files so it doesn't report itself ───────
    $selfPaths = @($etlPath, "$env:TEMP\$traceName", "$traceName")
    $filePaths = [System.Collections.Generic.List[string]]@(
        $filePaths | Where-Object {
            $p = $_
            -not ($selfPaths | Where-Object { $p -like "*$_*" })
        }
    )

    if ($filePaths.Count -eq 0) {
        Write-Output "Captured $($events.Count) events but no file paths found after filtering."
        Write-Output "The host may have very low disk activity. Try running on a busier host."
        return
    }

    Write-Output "$($filePaths.Count) file path references after filtering out trace self-activity."
    Write-Output ""

    # ── Top 20 files by I/O event count (busiest first) ────────────────────
    # Device paths like \Device\HarddiskVolume4\Windows\... are very long.
    # Strip the \Device\HarddiskVolumeN\ prefix to show cleaner paths.
    Write-Output "=== Top 20 Busiest Files ==="
    Write-Output ""
    $filePaths | Group-Object | Sort-Object Count -Descending | Select-Object -First 20 |
        ForEach-Object {
            $cleanPath = $_.Name -replace '^\\Device\\HarddiskVolume\d+\\', '\'
            "{0,6}  {1}" -f $_.Count, $cleanPath
        }
    Write-Output ""

    # ── Top 10 directories by I/O event count (busiest first) ──────────────
    Write-Output "=== Top 10 Busiest Directories ==="
    Write-Output ""
    $filePaths | ForEach-Object {
        try { Split-Path $_ -Parent -ErrorAction SilentlyContinue } catch { $_ }
    } | Where-Object { $_ } |
        Group-Object | Sort-Object Count -Descending | Select-Object -First 10 |
        ForEach-Object {
            $cleanDir = $_.Name -replace '^\\Device\\HarddiskVolume\d+\\', '\'
            "{0,6}  {1}" -f $_.Count, $cleanDir
        }
    Write-Output ""

    # ── File type breakdown (busiest extensions) ───────────────────────────
    Write-Output "=== Busiest File Types ==="
    Write-Output ""
    $filePaths | ForEach-Object {
        try { [System.IO.Path]::GetExtension($_).ToLower() } catch { '(unknown)' }
    } | Where-Object { $_ } |
        Group-Object | Sort-Object Count -Descending | Select-Object -First 10 |
        Select-Object @{N='Events';E={$_.Count}}, @{N='Extension';E={if ($_.Name) { $_.Name } else { '(no ext)' }}} |
        Format-Table -AutoSize

    # ── FSLogix VHD detection ──────────────────────────────────────────────
    Write-Output ""
    Write-Output "=== FSLogix / VHD Activity ==="
    $vhdPaths = @($filePaths | Where-Object { $_ -match '\.(vhd|vhdx|cim)' } | Sort-Object -Unique)
    if ($vhdPaths.Count -gt 0) {
        Write-Output "VHD/VHDX files detected in I/O trace:"
        foreach ($v in ($vhdPaths | ForEach-Object { $_ -replace '^\\Device\\HarddiskVolume\d+\\', '\' })) { Write-Output "  $v" }
        $vhdEvents = @($filePaths | Where-Object { $_ -match '\.(vhd|vhdx|cim)' }).Count
        $vhdPct = [math]::Round($vhdEvents / $filePaths.Count * 100, 1)
        Write-Output ""
        Write-Output "$vhdEvents of $($filePaths.Count) events ($vhdPct%) involve VHD/VHDX files."
        if ($vhdPct -ge 20) {
            Write-Output "FSLogix profile container I/O is a MAJOR contributor to disk activity."
        } elseif ($vhdPct -ge 5) {
            Write-Output "FSLogix profile container I/O is a moderate contributor."
        } else {
            Write-Output "FSLogix profile container I/O is minimal - disk activity is from other sources."
        }
    } else {
        Write-Output "No VHD/VHDX file activity detected in this trace."
    }

} finally {
    # ── Always clean up: stop trace and delete temp file ───────────────────
    logman stop $traceName -ets 2>$null | Out-Null
    if (Test-Path $etlPath) {
        Remove-Item $etlPath -Force -ErrorAction SilentlyContinue
        Write-Output ""
        Write-Output "(Trace file cleaned up)"
    }
}
