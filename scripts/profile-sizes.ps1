<#
.SYNOPSIS
    Profile Size Scanner - fast folder size enumeration for FSLogix profile shares.

.DESCRIPTION
    Scans one or more root UNC paths and returns the name, full path, storage account,
    size, and file count for every immediate subfolder. Uses .NET IO enumeration for speed.

    Designed to be called from profile-tools.ps1 via Start-Job, but can also be run
    standalone and will output objects to the pipeline.

.PARAMETER Paths
    One or more root paths to scan (e.g. UNC share paths from config.psd1).

.PARAMETER AccountMap
    Hashtable mapping each path to its storage account name for display purposes.
    e.g. @{ '\\server\share' = 'cukavdukwprod01' }
    If not supplied, the storage account name is derived from the UNC path.

.OUTPUTS
    [PSCustomObject] with properties:
        Folder         - folder name only (no path)
        StorageAccount - storage account name
        FullPath       - full path to the folder
        Bytes          - raw size in bytes (for sorting)
        FileCount      - number of files inside
        SizeHuman      - human-readable size string (e.g. "2.31 GB")

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-02-20
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
    .\profile-size.ps1 -Paths "\\server\share\profiles"

.EXAMPLE
    .\profile-size.ps1 -Paths "\\uksprod01\profiles","\\ukwprod01\profiles"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Paths,

    [Parameter(Position = 1)]
    [hashtable]$AccountMap = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

# ─────────────────────────────────────────────────────────────────────────────
# Size formatter
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-HumanSize {
    param([long]$Bytes)
    switch ($Bytes) {
        { $_ -ge 1TB } { return '{0:N2} TB' -f ($_ / 1TB) }
        { $_ -ge 1GB } { return '{0:N2} GB' -f ($_ / 1GB) }
        { $_ -ge 1MB } { return '{0:N2} MB' -f ($_ / 1MB) }
        { $_ -ge 1KB } { return '{0:N2} KB' -f ($_ / 1KB) }
        default        { return '{0} B'     -f $_ }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Scan each root path
# ─────────────────────────────────────────────────────────────────────────────
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($rootPath in $Paths) {

    if (-not [System.IO.Directory]::Exists($rootPath)) {
        Write-Warning "Path not found or inaccessible, skipping: $rootPath"
        continue
    }

    # Resolve display name: use AccountMap if provided, otherwise derive from UNC
    if ($AccountMap.ContainsKey($rootPath)) {
        $accountName = $AccountMap[$rootPath]
    } else {
        $accountName = ($rootPath -split '\\' | Where-Object { $_ } | Select-Object -First 1) -replace '\..*'
    }

    try {
        $subDirs = [System.IO.Directory]::GetDirectories($rootPath)
    } catch {
        Write-Warning "Cannot enumerate subfolders of: $rootPath  ($_)"
        continue
    }

    foreach ($dir in $subDirs) {

        $bytes = [long]0
        $count = [int]0

        try {
            $enumOpts = [System.IO.EnumerationOptions]::new()
            $enumOpts.RecurseSubdirectories = $true
            $enumOpts.IgnoreInaccessible    = $true
            $enumOpts.AttributesToSkip      = [System.IO.FileAttributes]::ReparsePoint

            foreach ($file in [System.IO.Directory]::EnumerateFiles($dir, '*', $enumOpts)) {
                try { $bytes += ([System.IO.FileInfo]$file).Length; $count++ } catch {}
            }
        } catch {
            try {
                foreach ($file in [System.IO.Directory]::GetFiles($dir, '*', [System.IO.SearchOption]::AllDirectories)) {
                    try { $bytes += ([System.IO.FileInfo]$file).Length; $count++ } catch {}
                }
            } catch {}
        }

        $results.Add([PSCustomObject]@{
            Folder         = [System.IO.Path]::GetFileName($dir)
            StorageAccount = $accountName
            FullPath       = $dir
            Bytes          = $bytes
            FileCount      = $count
            SizeHuman      = ConvertTo-HumanSize -Bytes $bytes
        })
    }
}

# Return sorted largest-first
$results | Sort-Object Bytes -Descending