<#
.SYNOPSIS
    Profile Delete - Phase 2: closes open file handles and removes FSLogix lock files.

.DESCRIPTION
    Processes the list of locked storage accounts returned by profile-delete-check.ps1 (Phase 1).
    For each account, closes all open Azure file handles then removes any .lock files.

    Uses the Azure Files REST API with SharedKey authentication (via storage-api-helpers.ps1
    functions injected at runtime) instead of the Az.Storage PowerShell module.

    Designed to be loaded as a scriptblock and executed in a background runspace by
    profile-tools.ps1 via Start-BgJob.

.PARAMETER StorageHelperCode
    String containing the content of storage-api-helpers.ps1. Dot-sourced at runtime
    to make storage REST helper functions available in the runspace.

.PARAMETER StorageKeys
    Hashtable mapping storage account names to their primary access keys.

.PARAMETER FolderName
    The profile folder name being processed (e.g. jsmith_S-1-5-21-...).

.PARAMETER LockedAccounts
    Array of locked account objects returned by profile-delete-check.ps1.
    Each object must have: Name, HandleCount, LockFiles.

.PARAMETER FileShareName
    The Azure File Share name (e.g. 'profiles').

.PARAMETER FileShareSubPath
    The sub-path within the share where profile folders reside (e.g. 'fslogix').

.OUTPUTS
    [PSCustomObject] with properties:
        Messages - list of {Text, Colour} log entries
        Errors   - list of error strings; non-empty means lock cleanup failed

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
    2026-03-02 - Initial REST API release. Replaced Az.Storage cmdlets with Azure Files REST API calls.

#>

param(
    [string]   $StorageHelperCode,
    [hashtable]$StorageKeys    = @{},     # SharedKey auth (legacy) - keys per storage account
    [string]   $StorageToken   = "",      # OAuth bearer token auth (preferred) - single token for all accounts
    [string]   $FolderName,
    [object[]] $LockedAccounts,
    [hashtable]$ShareNameMap    = @{},    # per-account share names derived from the storage map
    [hashtable]$ShareSubPathMap = @{},    # per-account subpaths derived from the storage map
    [string]   $LogFile = ""
)

# Load storage REST helper functions into this runspace.
# $LogFile (if set) is visible to storage-api-helpers.ps1 for REST call logging.
. ([scriptblock]::Create($StorageHelperCode))
$messages = [System.Collections.Generic.List[PSCustomObject]]::new()
$errors   = [System.Collections.Generic.List[string]]::new()

function Msg { param($t,$c="#D1D5DB") $messages.Add([PSCustomObject]@{Text=$t;Colour=$c}) }

Msg ""
Msg "  PHASE 2 - Clearing Locks" "#3B8ED4"
Msg ("  " + ("-" * 48)) "#3B5A7A"

foreach ($la in $LockedAccounts) {
    Msg ""
    Msg "  > Processing: $($la.Name)" "#E5E7EB"

    $acctShareName = [string]$ShareNameMap[$la.Name]
    $acctSubPath   = [string]$ShareSubPathMap[$la.Name]
    $BasePath      = if ($acctSubPath) { "$acctSubPath/$FolderName" } else { $FolderName }

    # Determine auth method: OAuth bearer token (preferred) or SharedKey (legacy)
    $authSplat = @{ AccountName = $la.Name }
    if ($StorageToken) {
        $authSplat['BearerToken'] = $StorageToken
    } elseif ($StorageKeys -and $StorageKeys[$la.Name]) {
        $authSplat['AccountKey'] = $StorageKeys[$la.Name]
    } else {
        $errors.Add("$($la.Name): No authentication available")
        Msg "    [ERROR] No authentication available for this storage account" "#EF4444"
        continue
    }

    try {
        if ($la.HandleCount -gt 0) {
            Msg "    Closing $($la.HandleCount) handle(s)..." "#9CA3AF"
            $closed = Close-StorageFileHandles @authSplat `
                          -ShareName $acctShareName -Path $BasePath -Recursive
            Start-Sleep -Seconds 2
            Msg "    OK All handles closed ($closed closed by server)" "#34D399"
        }
        foreach ($lf in $la.LockFiles) {
            $lp = "$BasePath/$lf"
            $exists = Test-StorageFileExists @authSplat `
                          -ShareName $acctShareName -FilePath $lp
            if ($exists) {
                Remove-StorageFileItem @authSplat `
                    -ShareName $acctShareName -FilePath $lp
                Msg "    OK Removed lock file: $lf" "#34D399"
            } else {
                Msg "    [INFO] Lock file already gone: $lf" "#9CA3AF"
            }
        }
    } catch {
        $errors.Add($la.Name + ": " + $_)
        Msg "    [ERROR] $($_)" "#EF4444"
    }
}

return [PSCustomObject]@{ Messages = $messages; Errors = $errors }
