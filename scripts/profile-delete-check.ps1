<#
.SYNOPSIS
    Profile Delete - Phase 1: checks for active FSLogix locks and open file handles.

.DESCRIPTION
    Scans one or more Azure storage accounts for .lock files and open file handles on the
    specified profile folder. Returns a structured result for profile-tools.ps1 to act on.

    Uses the Azure Files REST API with SharedKey authentication (via storage-api-helpers.ps1
    functions injected at runtime) instead of the Az.Storage PowerShell module.

.PARAMETER StorageHelperCode
    String containing the content of storage-api-helpers.ps1. Dot-sourced at runtime
    to make storage REST helper functions available in the runspace.

.PARAMETER StorageKeys
    Hashtable mapping storage account names to their primary access keys.

.PARAMETER FolderName
    The profile folder name to check (e.g. jsmith_S-1-5-21-...).

.PARAMETER SelectedAccounts
    Array of storage account short names to check.

.PARAMETER FileShareName
    The Azure File Share name (e.g. 'profiles').

.PARAMETER FileShareSubPath
    The sub-path within the share where profile folders reside (e.g. 'fslogix').

.OUTPUTS
    [PSCustomObject] with properties:
        LockedAccounts       - list of accounts with active locks
        Messages             - list of {Text, Colour} log entries
        RequiresLockConfirm  - $true if locks were found and user must confirm force-close
        RequireDeleteConfirm - always $true

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
    2026-02-24 - Initial release.
    2026-03-02 - Initial REST API release. Replaced Az.Storage cmdlets with Azure Files REST API calls.

#>

param(
    [string]   $StorageHelperCode,
    [hashtable]$StorageKeys    = @{},     # SharedKey auth (legacy) - keys per storage account
    [string]   $StorageToken   = "",      # OAuth bearer token auth (preferred) - single token for all accounts
    [string]   $FolderName,
    [string[]] $SelectedAccounts,
    [string]   $FileShareName,
    [string]   $FileShareSubPath,
    [string]   $LogFile = ""
)

# Load storage REST helper functions into this runspace.
# $LogFile (if set) is visible to storage-api-helpers.ps1 for REST call logging.
. ([scriptblock]::Create($StorageHelperCode))

$BasePath = if ($FileShareSubPath) { "$FileShareSubPath/$FolderName" } else { $FolderName }
$result   = [PSCustomObject]@{
    LockedAccounts      = [System.Collections.Generic.List[PSCustomObject]]::new()
    Messages            = [System.Collections.Generic.List[PSCustomObject]]::new()
    RequiresLockConfirm = $false
    RequireDeleteConfirm= $true
    # Set to $true if any storage account returns an AuthorizationPermissionMismatch
    # error, so the UI can show a helpful popup about the required RBAC role.
    PermissionError     = $false
}

function Msg { param($t,$c="#D1D5DB") $result.Messages.Add([PSCustomObject]@{Text=$t;Colour=$c}) }

Msg ""
Msg "  FSLogix Profile Lock Check: $FolderName" "#00BFFF"
Msg ("  " + ("=" * 70)) "#00BFFF"

foreach ($saName in $SelectedAccounts) {

    Msg ""
    Msg ("  " + ("=" * 70)) "#E5E7EB"
    Msg "  Storage Account: $saName" "#E5E7EB"
    Msg ("  " + ("=" * 70)) "#E5E7EB"

    # Determine auth method: OAuth bearer token (preferred) or SharedKey (legacy)
    $authSplat = @{ AccountName = $saName }
    if ($StorageToken) {
        $authSplat['BearerToken'] = $StorageToken
    } elseif ($StorageKeys -and $StorageKeys[$saName]) {
        $authSplat['AccountKey'] = $StorageKeys[$saName]
    } else {
        Msg "  WARNING: No authentication available for this storage account" "#EF4444"
        continue
    }

    $HasLocks      = $false
    $LockFilesList = @()
    $Handles       = $null
    $VHDXHandle    = $null

    # -- Check for .lock files ------------------------------------------------
    Msg ""
    Msg "  Checking for FSLogix .lock files..." "#F59E0B"
    Msg "    Share: $FileShareName  Path: $BasePath" "#9CA3AF"
    try {
        $Files = Get-StorageDirectoryFiles @authSplat `
                     -ShareName $FileShareName -DirectoryPath $BasePath

        if ($Files -and $Files.Count -gt 0) {
            Msg "    Files in folder:" "#9CA3AF"
            foreach ($file in $Files) {
                $fileName = $file.Name
                Msg "      - $fileName" "#9CA3AF"
                if ($fileName -like "*.lock") {
                    Msg "        *** LOCK FILE DETECTED ***" "#EF4444"
                    $HasLocks = $true
                    $LockFilesList += $fileName
                }
            }

            $lockCount = @($Files | Where-Object { $_.Name -like "*.lock" }).Count
            Msg ""
            if ($lockCount -gt 0) {
                $lockNames = ($Files | Where-Object { $_.Name -like "*.lock" } | ForEach-Object { $_.Name }) -join ', '
                Msg "    STATUS: PROFILE IS LOCKED" "#EF4444"
                Msg "    Lock file(s): $lockNames" "#EF4444"
            } else {
                Msg "    STATUS: No .lock files found" "#34D399"
            }
        }
    } catch {
        $errMsg = "$_"
        if ($errMsg -match 'AuthorizationPermissionMismatch|AuthorizationFailure|not authorized') {
            # OAuth token is valid but the identity lacks the required data-plane
            # RBAC role on this storage account. Flag it so the UI can show a popup.
            Msg "    ERROR: Permission denied on storage account '$saName'" "#EF4444"
            Msg "    Your account needs the 'Storage File Data Privileged Contributor' role" "#EF4444"
            Msg "    assigned on this storage account to use OAuth data-plane access." "#EF4444"
            $result.PermissionError = $true
        } else {
            # Generic error - folder may not exist, network issue, etc.
            Msg "    WARNING: Could not access folder (may not exist in this storage account)" "#F59E0B"
            Msg "    Error: $errMsg" "#F59E0B"
        }
        continue
    }

    Msg ""

    # -- Check for open handles -----------------------------------------------
    Msg "  Checking for open file handles..." "#F59E0B"
    try {
        # Wrap in @() to ensure array even if API returns a single handle object.
        # Without this, Where-Object and .Count behave unexpectedly on scalar values.
        $Handles = @(Get-StorageFileHandles @authSplat `
                       -ShareName $FileShareName -Path $BasePath -Recursive)

        if ($Handles.Count -gt 0) {
            Msg "    Found $($Handles.Count) open handle(s):" "#F59E0B"
            $HasLocks = $true

            $VHDXHandle = $Handles | Where-Object {
                $_.Path -like "*_STD.VHDX" -or $_.Path -like "*_RW.VHDX" -or
                ($_.Path -like "*.VHDX" -and $_.Path -notlike "*.meta")
            } | Select-Object -First 1

            if ($VHDXHandle) {
                Msg ""
                Msg "    ACTIVE SESSION HOST: $($VHDXHandle.ClientIp)" "#FBBF24"
                Msg "    VHDX File: $(Split-Path $VHDXHandle.Path -Leaf)" "#FBBF24"
                Msg ""
            }

            $Handles | Group-Object ClientIp | ForEach-Object {
                Msg "    Client IP: $($_.Name)  ($($_.Count) handle(s))" "#60B0F0"
                $_.Group | ForEach-Object {
                    $leafName = Split-Path $_.Path -Leaf
                    $openDuration = ''
                    try {
                        $opened = [DateTime]::Parse($_.OpenTime)
                        $dur = [DateTime]::UtcNow - $opened
                        if ($dur.TotalHours -ge 1) {
                            $openDuration = " | Open for: $([math]::Floor($dur.TotalHours))h $($dur.Minutes)m"
                        } else {
                            $openDuration = " | Open for: $($dur.Minutes)m $($dur.Seconds)s"
                        }
                    } catch {}
                    $sessId = if ($_.SessionId) { " | Session: $($_.SessionId)" } else { '' }
                    $lastReconn = if ($_.LastReconnectTime) { " | Last Reconnect: $($_.LastReconnectTime)" } else { '' }
                    Msg "      - $leafName" "#E5E7EB"
                    Msg "        Handle: $($_.HandleId) | Opened: $($_.OpenTime)$openDuration$sessId$lastReconn" "#9CA3AF"
                }
                Msg ""
            }
        } else {
            Msg "    No open handles found" "#34D399"
        }
    } catch {
        Msg "    WARNING: Could not check handles: $_" "#F59E0B"
    }

    if ($HasLocks -or $LockFilesList.Count -gt 0) {
        $result.LockedAccounts.Add([PSCustomObject]@{
            Name        = $saName
            HandleCount = if ($Handles) { $Handles.Count } else { 0 }
            SessionHost = if ($VHDXHandle) { $VHDXHandle.ClientIp } else { "Unknown" }
            LockFiles   = $LockFilesList
        })
    }
}

# -- Summary ------------------------------------------------------------------
Msg ""
Msg ("  " + ("=" * 70)) "#60B0F0"
Msg "  Lock Cleanup Summary" "#60B0F0"
Msg ("  " + ("=" * 70)) "#60B0F0"
Msg ""

if ($result.LockedAccounts.Count -gt 0) {
    $result.RequiresLockConfirm = $true
    Msg "  Locks found in the following storage accounts:" "#F59E0B"
    foreach ($la in $result.LockedAccounts) {
        if ($la.HandleCount -gt 0) {
            Msg "    - $($la.Name) - $($la.HandleCount) handle(s) - Session Host: $($la.SessionHost)" "#FBBF24"
        } else {
            Msg "    - $($la.Name) - Lock files only (no active handles)" "#FBBF24"
        }
        if ($la.LockFiles.Count -gt 0) {
            Msg "      Lock files: $($la.LockFiles -join ', ')" "#9CA3AF"
        }
    }
    Msg ""
    Msg "  WARNING: Closing handles will forcefully log off the user!" "#EF4444"
} else {
    Msg "  No locks found to clean up!" "#34D399"
}

$result.RequireDeleteConfirm = $true
return $result
