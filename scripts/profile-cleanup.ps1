<#
.SYNOPSIS
    Profile Cleanup Scanner - identifies and removes stale FSLogix profile folders by age.

.DESCRIPTION
    Scans one or more root UNC paths and returns profile subfolders whose most recent
    file activity is older than the specified threshold. Uses .NET IO enumeration for speed.

    Designed to be called from profile-tools.ps1 via Start-Job, but can also be run
    standalone and will output objects to the pipeline.

.PARAMETER Paths
    One or more root paths to scan (e.g. UNC share paths from config.psd1).

.PARAMETER AccountMap
    Hashtable mapping each path to its storage account name for display purposes.
    e.g. @{ '\\server\share' = 'cukavdukwprod01' }
    If not supplied, the storage account name is derived from the UNC path.

.PARAMETER ThresholdDays
    Number of days of inactivity before a folder is considered stale. Default: 90.
    The most recent file LastWriteTime within the folder is used to determine activity.
    Falls back to the folder's own LastWriteTime if no files are found.

.OUTPUTS
    [PSCustomObject] with properties:
        Folder         - folder name only (no path)
        StorageAccount - storage account name
        FullPath       - full path to the folder
        LastModified   - most recent file modification DateTime
        DaysSince      - whole days since last modification (for sorting)
        AgeHuman       - human-readable age string (e.g. "127 days")
        FileCount      - number of files inside

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-02-22
    Requires      : PowerShell 5.1

    DISCLAIMER:
    This script is provided as-is with no warranty, guarantee, or support of any kind.
    Use at your own risk. The author accepts no responsibility for any issues,
    data loss, or damages arising from the use of this script in any environment.
    Always test in a non-production environment before deploying.

    Version History:
    2026-02-23 - Initial release.
    2026-03-02 - Initial REST API release.

.EXAMPLE
    .\profile-cleanup.ps1 -Paths "\\server\share\profiles" -ThresholdDays 90

.EXAMPLE
    .\profile-cleanup.ps1 -Paths "\\uksprod01\profiles","\\ukwprod01\profiles" -ThresholdDays 180
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Paths,

    [Parameter(Position = 1)]
    [hashtable]$AccountMap = @{},

    [Parameter(Position = 2)]
    [int]$ThresholdDays = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

# ─────────────────────────────────────────────────────────────────────────────
# Cutoff date: folders with no activity since this date are flagged
# ─────────────────────────────────────────────────────────────────────────────
$cutoff  = (Get-Date).AddDays(-$ThresholdDays)
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# ─────────────────────────────────────────────────────────────────────────────
# Scan each root path
# ─────────────────────────────────────────────────────────────────────────────
foreach ($rootPath in $Paths) {

    if (-not [System.IO.Directory]::Exists($rootPath)) {
        Write-Warning "Path not found or inaccessible, skipping: $rootPath"
        continue
    }

    # Resolve display name: use AccountMap if provided, otherwise derive from UNC
    if ($AccountMap.ContainsKey($rootPath)) {
        $accountName = $AccountMap[$rootPath]
    } else {
        # e.g. \\cukavdukwprod01.file.core.windows.net\profiles\fslogix -> cukavdukwprod01
        $accountName = ($rootPath -split '\\' | Where-Object { $_ } | Select-Object -First 1) -replace '\..*'
    }

    try {
        $subDirs = [System.IO.Directory]::GetDirectories($rootPath)
    } catch {
        Write-Warning "Cannot enumerate subfolders of: $rootPath  ($_)"
        continue
    }

    foreach ($dir in $subDirs) {

        $latestWrite = [DateTime]::MinValue
        $count       = [int]0

        try {
            $enumOpts = [System.IO.EnumerationOptions]::new()
            $enumOpts.RecurseSubdirectories = $true
            $enumOpts.IgnoreInaccessible    = $true
            $enumOpts.AttributesToSkip      = [System.IO.FileAttributes]::ReparsePoint

            foreach ($file in [System.IO.Directory]::EnumerateFiles($dir, '*', $enumOpts)) {
                try {
                    $fi = [System.IO.FileInfo]$file
                    if ($fi.LastWriteTime -gt $latestWrite) { $latestWrite = $fi.LastWriteTime }
                    $count++
                } catch {}
            }
        } catch {
            # Fallback for older .NET / access restrictions
            try {
                foreach ($file in [System.IO.Directory]::GetFiles($dir, '*', [System.IO.SearchOption]::AllDirectories)) {
                    try {
                        $fi = [System.IO.FileInfo]$file
                        if ($fi.LastWriteTime -gt $latestWrite) { $latestWrite = $fi.LastWriteTime }
                        $count++
                    } catch {}
                }
            } catch {}
        }

        # Fall back to the folder's own LastWriteTime if no files were accessible
        if ($latestWrite -eq [DateTime]::MinValue) {
            try { $latestWrite = ([System.IO.DirectoryInfo]$dir).LastWriteTime } catch {}
        }

        # Skip folders with unknown age or that are still within the active threshold
        if ($latestWrite -eq [DateTime]::MinValue -or $latestWrite -gt $cutoff) { continue }

        $days = [int][Math]::Floor(([DateTime]::Now - $latestWrite).TotalDays)

        $results.Add([PSCustomObject]@{
            Folder         = [System.IO.Path]::GetFileName($dir)
            StorageAccount = $accountName
            FullPath       = $dir
            LastModified   = $latestWrite
            DaysSince      = $days
            AgeHuman       = "$days days"
            FileCount      = $count
        })
    }
}

# Return results unsorted — sorting and grouping is handled by profile-tools.ps1
$results
