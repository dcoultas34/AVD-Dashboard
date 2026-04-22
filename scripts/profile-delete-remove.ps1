<#
.SYNOPSIS
    Profile Delete - Phase 3: removes FSLogix profile folders from UNC paths.

.DESCRIPTION
    Deletes each supplied UNC path using Remove-Item. Designed to run after
    profile-delete-check.ps1 (Phase 1) and profile-delete-unlock.ps1 (Phase 2)
    have confirmed no active locks remain.

    Designed to be loaded as a scriptblock and executed in a background runspace by
    profile-tools.ps1 via Start-BgJob. Running in a runspace (rather than Start-Job)
    ensures Windows credentials are inherited for UNC path access without needing
    to re-authenticate.

.PARAMETER Paths
    Array of full UNC paths to delete (e.g. \\server\share\fslogix\jsmith_S-1-5-21-...).

.OUTPUTS
    [PSCustomObject] with properties:
        Messages - list of {Text, Colour} log entries

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

#>

param(
    [string[]] $Paths
)

$messages = [System.Collections.Generic.List[PSCustomObject]]::new()

function Msg { param($t,$c="#D1D5DB") $messages.Add([PSCustomObject]@{Text=$t;Colour=$c}) }

Msg ""
Msg "  PHASE 3 - Deleting Profile Folders" "#3B8ED4"
Msg ("  " + ("-" * 48)) "#3B5A7A"
Msg ""

foreach ($path in $Paths) {
    if (Test-Path -Path $path) {
        try {
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            Msg "  OK DELETED: $path" "#34D399"
        } catch {
            Msg "  X FAILED: $path" "#EF4444"
            Msg "    Error: $_" "#EF4444"
        }
    } else {
        Msg "  [INFO] Not found (skipped): $path" "#F59E0B"
    }
}

Msg ""
Msg "  -- Operation complete --" "#60B0F0"
Msg ""

return [PSCustomObject]@{ Messages = $messages }
