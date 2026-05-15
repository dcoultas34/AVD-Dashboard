# =============================================================================
# audit-log.ps1  -  CSV-based audit logging for destructive/task actions
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Records who did what and when to a weekly CSV file in the logs/ subfolder.
# Covers: Run Commands, logoff, send message, power actions, drain mode,
#         shadow/RDP, profile delete/unlock, cleanup delete.
#
# USAGE
# -----
# Dot-sourced by avd-live-dashboard.ps1 and profile-tools.ps1 at startup.
# Requires $script:azAccountId to be set by caller.
# The $script:AuditLogDir variable must be set by the caller to the project
# root path (where avd-live-dashboard.ps1 lives) so logs/ lands there.
#
# LOG FORMAT
# ----------
# File:    logs/audit-YYYY-MM-DD.csv  (one per week, named by Monday's date)
# Columns: Timestamp, User, Action, Target, Details, Result
# =============================================================================

function Write-AuditLog {
    param(
        [string]$Action,             # Action type (e.g. RunCommand, Logoff, VMStart)
        [string]$Target,             # Target resource (VM name, session host, UNC path)
        [string]$Details = '',       # Extra context (username, command name, message text)
        [string]$Result  = 'Success' # Outcome - 'Success' or error description
    )

    $logDir = Join-Path $script:AuditLogDir 'logs'
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Weekly CSV file - one per week, named by the Monday date (e.g. audit-2026-04-27.csv)
    $now      = Get-Date
    $dow      = [int]$now.DayOfWeek
    $monday   = $now.AddDays(-$(if ($dow -eq 0) { 6 } else { $dow - 1 })).ToString('yyyy-MM-dd')
    $logFile  = Join-Path $logDir "audit-$monday.csv"

    # Write CSV header on first entry of the week
    $needsHeader = -not (Test-Path $logFile)

    # Build the CSV line with proper quoting (double-quote escaping for embedded quotes)
    $line = '"{0}","{1}","{2}","{3}","{4}","{5}"' -f
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
        $script:azAccountId,
        $Action,
        ($Target -replace '"','""'),
        ($Details -replace '"','""'),
        ($Result -replace '"','""')

    if ($needsHeader) {
        [System.IO.File]::WriteAllText($logFile, "Timestamp,User,Action,Target,Details,Result`r`n$line`r`n")
    } else {
        [System.IO.File]::AppendAllText($logFile, "$line`r`n")
    }
}
