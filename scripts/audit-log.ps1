# =============================================================================
# audit-log.ps1  -  CSV-based audit logging for destructive/task actions
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Records who did what and when to a daily CSV file in the logs/ subfolder.
# Covers: Run Commands, logoff, send message, power actions, drain mode,
#         shadow/RDP, profile delete/unlock, cleanup delete.
#
# USAGE
# -----
# Dot-sourced by avd-live-dashboard.ps1 and profile-tools.ps1 at startup.
# Requires $script:EnableAuditLog and $script:azAccountId to be set by caller.
# The $script:AuditLogDir variable must be set by the caller to the project
# root path (where avd-live-dashboard.ps1 lives) so logs/ lands there.
#
# LOG FORMAT
# ----------
# File:    logs/audit-YYYY-MM-DD.csv  (one per day, auto-created)
# Columns: Timestamp, User, Action, Target, Details, Result
# =============================================================================

function Write-AuditLog {
    param(
        [string]$Action,             # Action type (e.g. RunCommand, Logoff, VMStart)
        [string]$Target,             # Target resource (VM name, session host, UNC path)
        [string]$Details = '',       # Extra context (username, command name, message text)
        [string]$Result  = 'Success' # Outcome - 'Success' or error description
    )

    # Skip if audit logging is disabled in config
    if (-not $script:EnableAuditLog) { return }

    try {
        # Resolve the logs/ subfolder relative to the project root.
        # $script:AuditLogDir is set by the main script (avd-live-dashboard.ps1
        # or profile-tools.ps1) to $PSScriptRoot so logs/ sits next to the script.
        $logDir = Join-Path $script:AuditLogDir 'logs'
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # Daily CSV file - automatically rotates at midnight
        $logFile = Join-Path $logDir "audit-$(Get-Date -Format 'yyyy-MM-dd').csv"

        # Write CSV header on first entry of the day
        $needsHeader = -not (Test-Path $logFile)

        # Build the CSV line with proper quoting (double-quote escaping for embedded quotes)
        $line = '"{0}","{1}","{2}","{3}","{4}","{5}"' -f
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            $script:azAccountId,
            $Action,
            ($Target -replace '"','""'),
            ($Details -replace '"','""'),
            ($Result -replace '"','""')

        # Thread-safe append via .NET (same pattern as Write-Log)
        if ($needsHeader) {
            [System.IO.File]::WriteAllText($logFile, "Timestamp,User,Action,Target,Details,Result`r`n$line`r`n")
        } else {
            [System.IO.File]::AppendAllText($logFile, "$line`r`n")
        }
    } catch {
        # Fire-and-forget - audit logging must never block the UI or the action.
        # Log the failure to the debug log (Write-Log) so issues are visible
        # when -EnableLogging is active, but never surface to the user.
        Write-Log "WARN [Audit] Failed to write audit entry ($Action / $Target): $_"
    }
}
