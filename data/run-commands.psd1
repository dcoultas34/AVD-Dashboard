#
# run-commands.psd1  -  Predefined Run Commands for the Session Hosts tab
#
# Each entry in the Commands array appears as a selectable item in the
# right-click "Run Command..." picker on the Session Hosts grid.
#
# Fields (all required):
#   Name        - Display label shown in the picker list
#   Description - One-line explanation shown below the list when selected
#   Script      - PowerShell code executed on the target VM via Invoke-AzVMRunCommand
#   ScriptFile  - (optional) .ps1 filename in data\runcommands\ (overrides Script)
#
# Order is preserved - commands appear in the picker exactly as listed here.
# Add, remove, or reorder entries freely; no script changes are needed.
#

@{
    Commands = @(
        @{
            Name        = 'Top Processes by CPU/RAM'
            Description = 'Lists the top 15 processes by current CPU % and RAM usage (uses performance counters).'
            ScriptFile  = 'top-processes.ps1'
        }
        @{
            Name        = 'Top User Processes by CPU/RAM'
            Description = 'Same as above but excludes SYSTEM, LOCAL SERVICE and NETWORK SERVICE accounts.'
            ScriptFile  = 'top-user-processes.ps1'
        }
        @{
            Name        = 'Restart AVD Agent'
            Description = 'Restarts the RDAgentBootLoader service. Use to recover a session host stuck in an unhealthy or unavailable state.'
            Script      = 'Restart-Service RDAgentBootLoader -Force; Start-Sleep 2; Get-Service RDAgentBootLoader | Select-Object Name,Status'
        }
        @{
            Name        = 'Run GPUpdate'
            Description = 'Forces an immediate Group Policy refresh (gpupdate /force).'
            Script      = '& gpupdate.exe /force 2>&1 | Out-String'
        }
        @{
            Name        = 'Check Disk Space'
            Description = 'Reports free and used space on the C: drive in GB.'
            Script      = 'Get-PSDrive C | Select-Object @{N="Used (GB)";E={[math]::Round($_.Used/1GB,2)}},@{N="Free (GB)";E={[math]::Round($_.Free/1GB,2)}}'
        }
        @{
            Name        = 'Check FSLogix Status'
            Description = 'Reports the status of FSLogix services (frxsvc, frxdrv, frxccds).'
            Script      = 'Get-Service frxsvc,frxdrv,frxccds -ErrorAction SilentlyContinue | Select-Object Name,Status'
        }
        @{
            Name        = 'FSLogix Redirections.xml Check'
            Description = 'Checks FSLogix event log for redirections.xml processing events (ID 27=applied, 28=parse error, 29=folder redirection). Also validates the XML file if found on disk.'
            ScriptFile  = 'fslogix-redirections-check.ps1'
        }
        @{
            Name        = 'FSLogix Event Log Diagnostics'
            Description = 'Queries FSLogix event logs for errors, warnings, profile attach/detach events, and VHD issues in the last hour. Helps diagnose "Please Wait for FSLogix Apps Service" hangs.'
            ScriptFile  = 'fslogix-events.ps1'
        }
        @{
            Name        = 'Get Logged-On Users'
            Description = 'Lists all users currently logged on to this session host.'
            Script      = 'query user 2>&1'
        }
        @{
            Name        = 'Recent Errors (All Logs - 15min)'
            Description = 'Scans all Windows event logs for Critical and Error events in the last 15 minutes. Groups by log name for quick triage.'
            ScriptFile  = 'recent-errors.ps1'
        }
        @{
            Name        = 'AppLocker Blocked Events'
            Description = 'Lists AppLocker blocked events for EXEs, DLLs, and Scripts (Event IDs 8004 and 8007). Shows up to 100 events per log, most recent first.'
            ScriptFile  = 'applocker-errors.ps1'
        }
        @{
            Name        = 'Check TCP Port Usage'
            Description = 'Per-process TCP connection breakdown with port exhaustion risk assessment.'
            ScriptFile  = 'check-tcp-ports.ps1'
        }
        @{
            Name        = 'Top Processes by Disk I/O'
            Description = 'Samples disk I/O for 5 seconds then shows the top 15 processes by IOPS and throughput. Identifies what is driving disk activity.'
            ScriptFile  = 'top-disk-io.ps1'
        }
        @{
            Name        = 'Disk I/O Trace (10 seconds)'
            Description = 'Runs a 10-second ETW kernel file trace to identify exactly which files and directories are generating disk I/O. Best used on busy hosts. Traces through kernel drivers (FSLogix VHD, NTFS, AV) to the actual file paths. ~1-3% CPU overhead.'
            ScriptFile  = 'disk-io-trace.ps1'
        }
        @{
            Name        = 'Installed Applications'
            Description = 'Lists installed applications from the registry (64-bit and 32-bit).'
            ScriptFile  = 'installed-apps.ps1'
        }
    )
}