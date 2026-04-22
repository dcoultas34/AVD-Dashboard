<#
.SYNOPSIS
    Azure REST API helper functions for the AVD Live Dashboard.

.DESCRIPTION
    Provides Invoke-ArmRestMethod (core REST wrapper with pagination, retry, and
    bearer-token auth) plus resource-specific wrapper functions that replace
    Az PowerShell module cmdlets. Only Az.Accounts is required (for token acquisition).

    Dot-source this file from the main dashboard script before tab modules:
        . "$PSScriptRoot\scripts\rest-api-helpers.ps1"

    ARCHITECTURE OVERVIEW
    ---------------------
    The dashboard makes all Azure data queries via direct REST API calls to the
    Azure Resource Manager (ARM) endpoint (https://management.azure.com). This
    eliminates the need for Az PowerShell modules (Az.DesktopVirtualization,
    Az.Compute, Az.Resources, Az.Storage, Az.Monitor, Az.Network) which would
    otherwise need to be imported into every background runspace - a slow and
    memory-intensive process.

    There are two versions of the REST wrapper in this file:

    1. Invoke-ArmRestMethod (full function)
       Used by the MAIN THREAD and PERSISTENT RUNSPACES (bgRunspace, filesRunspace,
       vmRefreshRunspace, infraRefreshRunspace). These runspaces dot-source this file
       or have the function available via the parent scope.

    2. $script:restHelperDef (compact string - "Invoke-Arm")
       Used by RUNSPACEPOOL THREADS. RunspacePool threads run in isolated execution
       contexts and cannot access parent-scope functions. This string contains a
       compact version of the same logic and is injected into pool thread scriptblocks
       via [scriptblock]::Create($restHelperDef + '...the thread code...'). The
       function definition becomes the first statement in the scriptblock.

       IMPORTANT: Because the function definition is prepended, the appended code
       MUST NOT use param() - it won't be recognised as parameter declarations.
       Instead, extract arguments via $args[0], $args[1], etc.

    Both versions handle:
      - Bearer token authentication (Authorization header)
      - Automatic nextLink / @odata.nextLink pagination for list queries
      - Retry with exponential backoff on 429 (throttled) and 5xx errors
      - Respect for Retry-After response headers
      - Optional logging to file when -EnableLogging is active

    TOKEN FLOW
    ----------
    Az.Accounts (Get-AzAccessToken) is used ONCE to obtain a bearer token. The token
    is cached by Get-ArmToken with a 5-minute expiry buffer. The main dashboard timer
    calls Get-ArmToken before each refresh cycle, and the fresh token is passed into
    runspaces via SessionStateProxy.SetVariable (persistent runspaces) or AddArgument
    (pool threads). Runspace threads never call Get-AzAccessToken themselves.

    LOGGING
    -------
    When the dashboard is launched with -EnableLogging, $script:LogFile is set to a
    path in %TEMP%. Invoke-ArmRestMethod checks $script:LogFile; the compact
    Invoke-Arm checks a $LogFile variable passed into the runspace. Both use
    [IO.File]::AppendAllText for thread-safe writes. When logging is not enabled,
    these variables are $null and all logging code is skipped (zero overhead).

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-03-02
    Requires      : PowerShell 5.1 or PowerShell 7 (Windows)

    DISCLAIMER:
    This script is provided as-is with no warranty, guarantee, or support of any kind.
    Use at your own risk. The author accepts no responsibility for any issues,
    data loss, or damages arising from the use of this script in any environment.
    Always test in a non-production environment before deploying.
#>

# ─────────────────────────────────────────────────────────────────────────────
# Centralised API versions
# Every ARM REST call requires an api-version query parameter. These are
# pinned here so all callers use consistent versions and upgrades happen in
# one place. The resource-specific wrapper functions reference these via
# $script:ApiVersions.<Provider>.
# ─────────────────────────────────────────────────────────────────────────────
$script:ApiVersions = @{
    DesktopVirtualization = '2024-04-03'
    Compute               = '2024-07-01'
    Network               = '2024-01-01'
    Resources             = '2024-03-01'
    Storage               = '2023-05-01'
    Monitor               = '2024-02-01'
    ResourceGraph         = '2021-03-01'
    Subscriptions         = '2022-12-01'
    AzureDevOps           = '7.1'           # Azure DevOps REST API version (tab-azuredevops.ps1)
}

# ─────────────────────────────────────────────────────────────────────────────
# Token management
# Get-ArmToken is the ONLY function that calls Az.Accounts. It caches the
# bearer token and only requests a new one when the cached token is within
# 5 minutes of expiry. The main dashboard timer calls this before every
# refresh cycle and passes the token into all runspaces - runspace threads
# never call Get-AzAccessToken themselves.
#
# PS 5.1 vs PS 7 difference: Get-AzAccessToken -AsSecureString returns a
# SecureString on PS 7 but a plain string on some PS 5.1 builds. The
# conditional below handles both cases.
# ─────────────────────────────────────────────────────────────────────────────
$script:_armTokenCache = @{}

function Get-ArmToken {
    param(
        [string]$ResourceUrl = 'https://management.azure.com/'
    )
    $cached = $script:_armTokenCache[$ResourceUrl]
    if ($cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        return $cached.Token
    }

    $_tok = Get-AzAccessToken -ResourceUrl $ResourceUrl -AsSecureString -ErrorAction Stop
    $plainToken = if ($_tok.Token -is [securestring]) {
        [System.Net.NetworkCredential]::new('', $_tok.Token).Password
    } else { [string]$_tok.Token }

    $script:_armTokenCache[$ResourceUrl] = @{
        Token     = $plainToken
        ExpiresOn = $_tok.ExpiresOn
    }
    return $plainToken
}

# ─────────────────────────────────────────────────────────────────────────────
# REST API logging
# Write-Log is used by Invoke-ArmRestMethod (main thread / persistent
# runspaces) and by the tab-level error catch blocks. It is a no-op when
# $script:LogFile is not set (i.e. -EnableLogging was not passed).
# The compact Invoke-Arm in RunspacePool threads uses [IO.File]::AppendAllText
# directly instead, since Write-Log is not available in pool thread scope.
# ─────────────────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message)
    if (-not $script:LogFile) { return }
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    try { [System.IO.File]::AppendAllText($script:LogFile, "$line`r`n") } catch {}
}

# ─────────────────────────────────────────────────────────────────────────────
# Window icon helper
#
# Loads avd-dashboard.ico via a memory stream so the .ico file is not locked
# for the lifetime of the window. BitmapCacheOption.OnLoad reads the full
# image into memory at creation time, allowing the stream to close immediately.
# Shared across all scripts that dot-source rest-api-helpers.ps1.
# ─────────────────────────────────────────────────────────────────────────────

function Set-WindowIcon {
    param(
        [System.Windows.Window]$Window,
        [string]$IconPath
    )
    if (-not (Test-Path $IconPath)) { return }
    try {
        # Use .ProviderPath instead of .Path - on UNC paths, .Path returns
        # 'Microsoft.PowerShell.Core\FileSystem::\\server\...' which
        # File::OpenRead cannot parse. .ProviderPath gives the clean path.
        $stream = [System.IO.File]::OpenRead((Resolve-Path $IconPath).ProviderPath)
        $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
            $stream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $stream.Close()
    } catch {}
}

# ─────────────────────────────────────────────────────────────────────────────
# Core REST wrapper (full version - main thread and persistent runspaces)
#
# Invoke-ArmRestMethod handles all Azure ARM REST API calls:
#   - Builds the full URI from a relative ARM path (e.g. /subscriptions/...)
#   - Appends the api-version query parameter
#   - Sets Authorization: Bearer header
#   - For GET list queries: auto-follows nextLink/@odata.nextLink pagination,
#     collecting all items into a single array result
#   - For non-GET or -FullResponse: returns the raw response object directly
#   - Retries on 429 (throttled) and 5xx with exponential backoff, respecting
#     the Retry-After response header when present
#   - Returns native object[] (via .ToArray()) so PS 5.1's @() can enumerate
#     the result correctly - List[object] would be treated as a single element
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-ArmRestMethod {
    param(
        [string]$Method      = 'GET',
        [string]$Path,
        [string]$Token,
        [object]$Body,
        [string]$ApiVersion,
        [switch]$FullResponse,
        [switch]$NoPagination,
        [int]$MaxRetries     = 3,
        [string]$BaseUri     = 'https://management.azure.com'
    )

    $uri = if ($Path.StartsWith('https://')) { $Path } else { "$BaseUri$Path" }

    if ($ApiVersion -and $uri -notmatch 'api-version=') {
        $separator = if ($uri.Contains('?')) { '&' } else { '?' }
        $uri = "$uri${separator}api-version=$ApiVersion"
    }

    $headers = @{
        Authorization  = "Bearer $Token"
        'Content-Type' = 'application/json'
    }

    $allItems  = [System.Collections.Generic.List[object]]::new()
    $currentUri = $uri
    $logging    = [bool]$script:LogFile
    $retryCount = 0

    do {
        $response = $null
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                $irm = @{
                    Method      = $Method
                    Uri         = $currentUri
                    Headers     = $headers
                    ErrorAction = 'Stop'
                }
                if ($Body) {
                    $irm['Body'] = if ($Body -is [string]) { $Body }
                                   else { ConvertTo-Json $Body -Depth 10 -Compress }
                }
                $sw = $null
                if ($logging) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }
                $response = Invoke-RestMethod @irm
                if ($logging) {
                    $sw.Stop()
                    $retryNote = if ($retryCount -gt 0) { ", retried ${retryCount}x" } else { '' }
                    Write-Log "$Method $currentUri -> 200 ($($sw.ElapsedMilliseconds)ms$retryNote)"
                }
                break
            }
            catch {
                $statusCode = $null
                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
                if ($statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600)) {
                    $waitSec = [Math]::Pow(2, $attempt)
                    if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers['Retry-After']) {
                        $ra = $_.Exception.Response.Headers['Retry-After']
                        if ([int]::TryParse($ra, [ref]$null)) { $waitSec = [Math]::Max([int]$ra, $waitSec) }
                    }
                    if ($attempt -lt $MaxRetries) {
                        $retryCount++
                        if ($logging) { Write-Log "$Method $currentUri -> $statusCode retry $attempt/$MaxRetries (wait ${waitSec}s)" }
                        Start-Sleep -Seconds $waitSec
                        continue
                    }
                }
                if ($logging) { Write-Log "$Method $currentUri -> $statusCode FAILED: $_" }
                throw
            }
        }

        if ($FullResponse -or $Method -ne 'GET') {
            return $response
        }

        if ($null -ne $response.value) {
            foreach ($item in $response.value) { $allItems.Add($item) }
        }
        elseif ($null -ne $response -and $null -eq $response.nextLink -and $null -eq $response.'@odata.nextLink') {
            return $response
        }

        $currentUri = if (-not $NoPagination -and $response.nextLink) { $response.nextLink }
                      elseif (-not $NoPagination -and $response.'@odata.nextLink') { $response.'@odata.nextLink' }
                      else { $null }
    } while ($currentUri)

    $allItems.ToArray()
}

# ─────────────────────────────────────────────────────────────────────────────
# Compact REST helper for RunspacePool threads (string form)
#
# RunspacePool threads run in isolated contexts with no access to parent-scope
# functions. This here-string contains a compact version of Invoke-ArmRestMethod
# named "Invoke-Arm". It is injected into pool thread scriptblocks by prepending
# it to the code:
#
#   $script = [scriptblock]::Create($RestHelperDef + @'
#       $tok = $args[0]; $subId = $args[1]   # extract arguments (no param()!)
#       Invoke-Arm -Path "/subscriptions/$subId/..." -Token $tok -ApiVersion '...'
#   '@)
#   $ps.AddScript($script).AddArgument($token).AddArgument($subId)
#
# CRITICAL: The appended code MUST NOT use param() because the function
# definition is the first statement - PowerShell would not recognise param()
# as parameter declarations. Use $args[N] extraction instead.
#
# For persistent runspaces (bgRunspace, filesRunspace etc.), the function is
# dot-sourced into scope instead:
#   . ([scriptblock]::Create($RestHelperDef))
# These CAN use param() in their own scriptblock since it's a separate statement.
#
# Logging: reads $LogFile variable from the runspace scope. For pool threads
# this is passed via AddArgument and extracted as $LogFile = $args[N]. For
# persistent runspaces it is set via SessionStateProxy.SetVariable('LogFile',...).
# ─────────────────────────────────────────────────────────────────────────────
$script:restHelperDef = @'
function Invoke-Arm {
    param([string]$Method='GET',[string]$Path,[string]$Token,[object]$Body,
          [string]$ApiVersion,[switch]$FullResponse,[int]$MaxRetries=3)
    $uri = if ($Path.StartsWith('https://')) { $Path } else { "https://management.azure.com$Path" }
    if ($ApiVersion -and $uri -notmatch 'api-version=') {
        $sep = if ($uri.Contains('?')) { '&' } else { '?' }
        $uri = "$uri${sep}api-version=$ApiVersion"
    }
    $hdr = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json'; Accept = 'application/json' }
    $all = [System.Collections.Generic.List[object]]::new()
    $cur = $uri; $rc = 0
    do {
        $resp = $null
        for ($a = 1; $a -le $MaxRetries; $a++) {
            try {
                $p = @{ Method=$Method; Uri=$cur; Headers=$hdr; ErrorAction='Stop' }
                if ($Body) { $p['Body'] = if ($Body -is [string]) { $Body } else { ConvertTo-Json $Body -Depth 10 -Compress } }
                $sw = $null; if ($LogFile) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }
                $resp = Invoke-RestMethod @p
                if ($LogFile) { $sw.Stop(); $rn = if ($rc -gt 0) { ", retried ${rc}x" } else { '' }; try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] $Method $cur -> 200 ($($sw.ElapsedMilliseconds)ms$rn)`r`n") } catch {} }
                break
            } catch {
                $sc = $null; if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode }
                if (($sc -eq 429 -or ($sc -ge 500 -and $sc -lt 600)) -and $a -lt $MaxRetries) {
                    $rc++; $ws = [Math]::Pow(2,$a)
                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] $Method $cur -> $sc retry $a/$MaxRetries (wait ${ws}s)`r`n") } catch {} }
                    Start-Sleep -Seconds $ws; continue
                }
                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] $Method $cur -> $sc FAILED: $_`r`n") } catch {} }
                throw
            }
        }
        if ($FullResponse -or $Method -ne 'GET') { return $resp }
        if ($null -ne $resp.value) { foreach ($i in $resp.value) { $all.Add($i) } }
        elseif ($null -ne $resp -and $null -eq $resp.nextLink -and $null -eq $resp.'@odata.nextLink') { return $resp }
        $cur = if ($resp.nextLink) { $resp.nextLink } elseif ($resp.'@odata.nextLink') { $resp.'@odata.nextLink' } else { $null }
    } while ($cur)
    $all.ToArray()
}

'@

# ─────────────────────────────────────────────────────────────────────────────
# Resource-specific wrappers
#
# These functions provide clean call sites that match the brevity of the
# original Az PowerShell cmdlets they replaced (e.g. Get-ArmHostPools replaces
# Get-AzWvdHostPool). Each wrapper builds the ARM path and delegates to
# Invoke-ArmRestMethod. Errors are not caught here - they bubble up to the
# caller (usually a timer tick handler or runspace EndInvoke).
#
# NOTE: These wrappers are only available in the MAIN THREAD and in persistent
# runspaces that dot-source this file. RunspacePool threads use the compact
# Invoke-Arm function and build their ARM paths inline.
# ─────────────────────────────────────────────────────────────────────────────

# -- Azure Virtual Desktop ────────────────────────────────────────────────────

function Get-ArmHostPools {
    param([string]$SubscriptionId, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization/hostPools" `
        -Token $Token -ApiVersion $script:ApiVersions.DesktopVirtualization
}

function Get-ArmSessionHosts {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$HostPool, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPool/sessionHosts" `
        -Token $Token -ApiVersion $script:ApiVersions.DesktopVirtualization
}

function Get-ArmUserSessions {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$HostPool, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPool/userSessions" `
        -Token $Token -ApiVersion $script:ApiVersions.DesktopVirtualization
}

function Get-ArmApplicationGroups {
    param([string]$SubscriptionId, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization/applicationGroups" `
        -Token $Token -ApiVersion $script:ApiVersions.DesktopVirtualization
}

function Get-ArmWorkspaces {
    param([string]$SubscriptionId, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization/workspaces" `
        -Token $Token -ApiVersion $script:ApiVersions.DesktopVirtualization
}

function Get-ArmScalingPlans {
    param([string]$SubscriptionId, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization/scalingPlans" `
        -Token $Token -ApiVersion $script:ApiVersions.DesktopVirtualization
}

function Remove-ArmUserSession {
    param(
        [string]$SubscriptionId, [string]$ResourceGroup, [string]$HostPool,
        [string]$SessionHost, [string]$SessionId, [string]$Token, [switch]$Force
    )
    $forceParam = if ($Force) { '&force=true' } else { '' }
    Invoke-ArmRestMethod -Method DELETE `
        -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPool/sessionHosts/$SessionHost/userSessions/$SessionId" `
        -Token $Token -ApiVersion "$($script:ApiVersions.DesktopVirtualization)$forceParam" `
        -FullResponse
}

function Update-ArmSessionHost {
    param(
        [string]$SubscriptionId, [string]$ResourceGroup, [string]$HostPool,
        [string]$SessionHostName, [bool]$AllowNewSession, [string]$Token
    )
    $body = @{ properties = @{ allowNewSession = $AllowNewSession } }
    Invoke-ArmRestMethod -Method PATCH `
        -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPool/sessionHosts/$SessionHostName" `
        -Token $Token -ApiVersion $script:ApiVersions.DesktopVirtualization `
        -Body $body -FullResponse
}

function Send-ArmUserSessionMessage {
    param(
        [string]$SubscriptionId, [string]$ResourceGroup, [string]$HostPool,
        [string]$SessionHost, [string]$SessionId,
        [string]$MessageTitle, [string]$MessageBody, [string]$Token
    )
    $body = @{ messageTitle = $MessageTitle; messageBody = $MessageBody }
    Invoke-ArmRestMethod -Method POST `
        -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$HostPool/sessionHosts/$SessionHost/userSessions/$SessionId/sendMessage" `
        -Token $Token -ApiVersion $script:ApiVersions.DesktopVirtualization `
        -Body $body -FullResponse
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource-specific wrappers - Resource Groups
# ─────────────────────────────────────────────────────────────────────────────

function Get-ArmResourceGroups {
    param([string]$SubscriptionId, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/resourcegroups" `
        -Token $Token -ApiVersion $script:ApiVersions.Resources
}

function Get-ArmResourceGroup {
    param([string]$SubscriptionId, [string]$ResourceGroupName, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroupName" `
        -Token $Token -ApiVersion $script:ApiVersions.Resources -FullResponse
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource-specific wrappers - Compute
# ─────────────────────────────────────────────────────────────────────────────

function Get-ArmVirtualMachines {
    param(
        [string]$SubscriptionId, [string]$ResourceGroup, [string]$Token,
        [switch]$InstanceView
    )
    $expand = if ($InstanceView) { '&$expand=instanceView' } else { '' }
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines" `
        -Token $Token -ApiVersion "$($script:ApiVersions.Compute)$expand"
}

function Get-ArmVirtualMachine {
    param(
        [string]$SubscriptionId, [string]$ResourceGroup, [string]$VmName,
        [string]$Token, [switch]$InstanceView
    )
    $expand = if ($InstanceView) { '?$expand=instanceView' } else { '' }
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$VmName$expand"
    Invoke-ArmRestMethod -Path $path `
        -Token $Token -ApiVersion $script:ApiVersions.Compute -FullResponse
}

function Invoke-ArmVmAction {
    param(
        [string]$SubscriptionId, [string]$ResourceGroup, [string]$VmName,
        [ValidateSet('start','deallocate','restart')][string]$Action, [string]$Token
    )
    Invoke-ArmRestMethod -Method POST `
        -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$VmName/$Action" `
        -Token $Token -ApiVersion $script:ApiVersions.Compute -FullResponse
}

function Get-ArmDisk {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$DiskName, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/disks/$DiskName" `
        -Token $Token -ApiVersion $script:ApiVersions.Compute -FullResponse
}

function Invoke-ArmVmRunCommand {
    param(
        [string]$SubscriptionId, [string]$ResourceGroup, [string]$VmName,
        [string[]]$Script, [string]$Token
    )
    $body = @{
        commandId = 'RunPowerShellScript'
        script    = $Script
    }
    Invoke-ArmRestMethod -Method POST `
        -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$VmName/runCommand" `
        -Token $Token -ApiVersion $script:ApiVersions.Compute `
        -Body $body -FullResponse
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource-specific wrappers - Network
# ─────────────────────────────────────────────────────────────────────────────

function Get-ArmNetworkInterface {
    param([string]$ResourceId, [string]$Token)
    Invoke-ArmRestMethod -Path $ResourceId `
        -Token $Token -ApiVersion $script:ApiVersions.Network -FullResponse
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource-specific wrappers - Storage (ARM management plane)
# ─────────────────────────────────────────────────────────────────────────────

function Get-ArmStorageAccounts {
    param([string]$SubscriptionId, [string]$Token, [string]$ResourceGroup)
    $path = if ($ResourceGroup) {
        "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts"
    } else {
        "/subscriptions/$SubscriptionId/providers/Microsoft.Storage/storageAccounts"
    }
    Invoke-ArmRestMethod -Path $path -Token $Token -ApiVersion $script:ApiVersions.Storage
}

function Get-ArmFileShares {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$AccountName, [string]$Token)
    Invoke-ArmRestMethod `
        -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$AccountName/fileServices/default/shares" `
        -Token $Token -ApiVersion $script:ApiVersions.Storage
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource-specific wrappers - Monitor (Metrics)
# ─────────────────────────────────────────────────────────────────────────────

function Get-ArmMetric {
    param(
        [string]$ResourceId, [string]$MetricName, [string]$Token,
        [datetime]$StartTime, [datetime]$EndTime,
        [string]$Interval    = 'PT1H',
        [string]$Aggregation = 'Average'
    )
    $ts = "$($StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    $qs = "metricnames=$MetricName&timespan=$ts&interval=$Interval&aggregation=$Aggregation"
    Invoke-ArmRestMethod `
        -Path "$ResourceId/providers/microsoft.insights/metrics?$qs" `
        -Token $Token -ApiVersion $script:ApiVersions.Monitor -FullResponse
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource-specific wrappers - Subscriptions
# ─────────────────────────────────────────────────────────────────────────────

function Get-ArmSubscriptions {
    param([string]$Token)
    Invoke-ArmRestMethod -Path '/subscriptions' -Token $Token -ApiVersion $script:ApiVersions.Subscriptions
}

# ─────────────────────────────────────────────────────────────────────────────
# Resource-specific wrappers - Resource Graph
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-ArmResourceGraph {
    param([string]$Query, [string[]]$SubscriptionIds, [string]$Token)
    $body = @{ subscriptions = $SubscriptionIds; query = $Query }
    $result = Invoke-ArmRestMethod -Method POST `
        -Path '/providers/Microsoft.ResourceGraph/resources' `
        -Token $Token -ApiVersion $script:ApiVersions.ResourceGraph `
        -Body $body -FullResponse
    return $result.data
}

# =============================================================================
# Resolve-MfaChallenge  -  MFA re-authentication helper
#
# Called by OnComplete callbacks when an ARM operation returns MFA errors.
# Scans the error array for the MFA_CHALLENGE:<claims>:::<session> marker
# produced by scriptblock catch blocks.  If found, launches a child
# powershell.exe to authenticate and execute the ARM operations directly.
#
# WHY THIS EXISTS:
#   Invoke-Arm / Invoke-ArmRestMethod are lightweight REST helpers that cannot
#   handle Conditional Access claims challenges - they just throw on 403.
#   Invoke-AzRestMethod (Az.Accounts) has a full HTTP pipeline that auto-retries
#   with claims, but requires the Az module loaded with a valid context.
#   A child powershell.exe is needed because background runspaces lack an
#   interactive host for browser-based MFA, and running Connect-AzAccount on the
#   WPF UI thread would block the dispatcher.
#
# MODES:
#   Interactive (first MFA): shows dialog, launches child with
#     Connect-AzAccount -ClaimsChallenge (opens browser for MFA step-up),
#     then executes ARM operations via Invoke-AzRestMethod.
#   Silent (subsequent): skips dialog, launches child that only does
#     Import-Module Az.Accounts (loads saved context + MSAL cache from
#     disk) then Invoke-AzRestMethod.  The Az HTTP pipeline handles
#     claims challenges using cached MFA tokens - no browser needed.
#     If silent mode fails, resets flag so next attempt shows full dialog.
#
# PARAMETERS:
#   -Errors        Error array to scan for MFA_CHALLENGE markers
#   -ArmOperations Hashtable[] with Method, Path, Body (optional) keys
#   -StatusText    WPF TextBlock for status updates (default: $script:sdStatus)
#   -PauseTimer    DispatcherTimer to pause during MFA (default: $script:sdCountdownTimer)
#
# CALLERS:
#   session-detail.ps1  - logoff OnComplete callbacks (4 sites: global/per-pool x selected/disconnected)
#   tab-sessionhosts.ps1 - drain mode result handler in Invoke-SessionHostsTabTimer section (c)
#
# RETURN VALUES:
#   Sets $script:_mfaRetryReady = $true  if MFA + operations succeeded
#   Sets $script:_mfaRetryReady = $false if MFA failed or user declined
#   Returns $true  if MFA error was detected (regardless of outcome)
#   Returns $false if no MFA error found (caller handles errors normally)
# =============================================================================

function script:Resolve-MfaChallenge {
    param(
        [array]$Errors,
        [hashtable[]]$ArmOperations,     # @{Method='DELETE'; Path='...'; Body='...' (optional)}
        [System.Windows.Controls.TextBlock]$StatusText,
        [System.Windows.Threading.DispatcherTimer]$PauseTimer
    )
    # Default to session-detail controls if not specified
    if (-not $StatusText) { $StatusText = $script:sdStatus }
    if (-not $PSBoundParameters.ContainsKey('PauseTimer')) { $PauseTimer = $script:sdCountdownTimer }

    $script:_mfaRetryReady  = $false
    $script:_mfaInProgress  = $false
    # ── MFA Debug Logging ────────────────────────────────────────────────
    # Two log files are written to %TEMP% during MFA to aid troubleshooting:
    #
    # 1. PARENT LOG: avd-dashboard-mfa-debug.txt
    #    Written by this function (the WPF UI thread) using $script:_mfaDbg.
    #    Each line is appended immediately (not batched) so the log is
    #    useful even if the parent gets stuck waiting in PushFrame.
    #    Tracks: MFA marker detection, claims extraction, mode selection,
    #    child process launch/exit, result file parsing, final outcome.
    #
    # 2. CHILD LOG: avd-dashboard-mfa-child.log
    #    Written by the child powershell.exe process that runs the actual
    #    Connect-AzAccount + ARM operations. This is critical because if
    #    the parent is stuck "waiting for browser", only the child log
    #    reveals what happened (module load, auth success/fail, ARM calls).
    #
    # Both files are overwritten on each MFA attempt (not appended across
    # attempts) so they always reflect the most recent run.
    # ───────────────────────────────────────────────────────────────────────
    if ($script:LogFile) {
        $script:_mfaDebugLog = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "avd-dashboard-mfa-debug.txt")
        try { [IO.File]::WriteAllText($script:_mfaDebugLog, "") } catch {}
        $script:_mfaDbg = { param($msg) try { [IO.File]::AppendAllText($script:_mfaDebugLog, "[$(Get-Date -f 'HH:mm:ss')] $msg`r`n") } catch {} }
    } else {
        $script:_mfaDbg = { }   # no-op when logging is disabled
    }
    & $script:_mfaDbg "=== Resolve-MfaChallenge ==="

    # Look for MFA_CHALLENGE marker returned by scriptblocks
    $mfaErr = $null
    foreach ($e in $Errors) {
        if ($e -match '^MFA_CHALLENGE:') { $mfaErr = $e; break }
    }
    if (-not $mfaErr) { & $script:_mfaDbg ("No MFA marker found"); return $false }

    # Extract base64 claims challenge from the marker prefix
    $claims = $null
    $parts  = $mfaErr -split ':::', 2
    $prefix = $parts[0] -replace '^MFA_CHALLENGE:', ''
    if ($prefix) { $claims = $prefix }
    & $script:_mfaDbg ("Claims extracted: $(if ($claims) { $claims.Substring(0, [Math]::Min(60, $claims.Length)) + '...' } else { '(none)' })")
    & $script:_mfaDbg ("ArmOperations count: $($ArmOperations.Count)")
    & $script:_mfaDbg ("_mfaEverDone: $($script:_mfaEverDone)")

    # Pause refresh timer so it doesn't fire during MFA (the PushFrame
    # dispatcher loop would allow it to tick and overwrite status text).
    $wasTimerRunning = $false
    if ($PauseTimer -and $PauseTimer.IsEnabled) {
        $PauseTimer.Stop()
        $wasTimerRunning = $true
    }

    # ── Decide: first MFA (show dialog + browser) vs subsequent (silent) ──
    $silentMode = $script:_mfaEverDone -eq $true

    if (-not $silentMode) {
        $msg = "Azure Conditional Access requires elevated authentication for this action.`n`n" +
               "Click Yes to authenticate - this may open a browser if needed,`n" +
               "or use cached credentials if a recent MFA session exists.`n`n" +
               "Click No to cancel."
        $ans = [System.Windows.MessageBox]::Show($msg, "Elevated Authentication Required", "YesNo", "Information")
        if ($ans -ne 'Yes') {
            $StatusText.Text = "Operation cancelled - elevated authentication required."
            if ($wasTimerRunning -and $PauseTimer) { $PauseTimer.Start() }
            return $true
        }
    }

    $StatusText.Text = if ($silentMode) { "Retrying with cached credentials..." } `
                       else { "Authenticating for elevated access..." }
    $script:_mfaInProgress = $true
    & $script:_mfaDbg ("Mode: $(if ($silentMode) {'silent'} else {'interactive'}) - launching child process")

    # Build child powershell.exe script:
    # - Interactive mode: Connect-AzAccount -ClaimsChallenge (browser MFA) then ARM ops
    # - Silent mode: just ARM ops using saved Az context + MSAL cache (no browser)
    $guid     = [guid]::NewGuid().ToString('N').Substring(0,8)
    $tempDir  = [System.IO.Path]::GetTempPath()
    $script:_mfaTempScript = [System.IO.Path]::Combine($tempDir, "avd-dashboard-mfa-$guid.ps1")
    $script:_mfaTempResult = [System.IO.Path]::Combine($tempDir, "avd-dashboard-mfa-$guid.result")

    # ── Child Process Log (see "MFA Debug Logging" block above) ──────────
    # The child .ps1 writes step-by-step progress to this file so we can
    # see exactly where it got to, even when the parent is stuck in
    # PushFrame polling. Each step appends: module load, Connect-AzAccount
    # result, each ARM operation result, and final completion.
    # Only included when -EnableLogging is active ($script:LogFile is set).
    $script:_mfaChildLogging = [bool]$script:LogFile
    if ($script:_mfaChildLogging) {
        $script:_mfaChildLog = [System.IO.Path]::Combine($tempDir, "avd-dashboard-mfa-child.log")
        $cmdLines = @(
            "`$_log = '$($script:_mfaChildLog)'"
            "[IO.File]::WriteAllText(`$_log, `"=== MFA child started `$(Get-Date -f 'HH:mm:ss') ===`r`n`")"
            'try { Import-Module Az.Accounts -ErrorAction Stop } catch { [IO.File]::AppendAllText($_log, "Import-Module FAILED: $_`r`n"); exit 1 }'
            "[IO.File]::AppendAllText(`$_log, `"Az.Accounts loaded`r`n`")"
        )
    } else {
        $cmdLines = @(
            'Import-Module Az.Accounts -ErrorAction Stop'
        )
    }

    if (-not $silentMode) {
        # First MFA: Connect-AzAccount with claims challenge opens browser
        $ctx = Get-AzContext
        $cmdLines += '$p = @{ ErrorAction = "Stop" }'
        if ($ctx.Tenant.Id)       { $cmdLines += "`$p['TenantId']       = '$($ctx.Tenant.Id)'" }
        if ($ctx.Account.Id)      { $cmdLines += "`$p['AccountId']      = '$($ctx.Account.Id)'" }
        if ($ctx.Subscription.Id) { $cmdLines += "`$p['SubscriptionId'] = '$($ctx.Subscription.Id)'" }
        if ($claims)              { $cmdLines += "`$p['ClaimsChallenge'] = '$claims'" }
        if ($script:_mfaChildLogging) {
            $cmdLines += @(
                "[IO.File]::AppendAllText(`$_log, `"Calling Connect-AzAccount...`r`n`")"
                'try {'
                '    Connect-AzAccount @p | Out-Null'
                "    [IO.File]::AppendAllText(`$_log, `"Connect-AzAccount succeeded`r`n`")"
                '} catch {'
                "    [IO.File]::AppendAllText(`$_log, `"Connect-AzAccount FAILED: `$_`r`n`")"
                "    [IO.File]::WriteAllText('$($script:_mfaTempResult)', `"AUTH_ERROR:`$_`")"
                '    exit 1'
                '}'
            )
        } else {
            $cmdLines += @(
                'try {'
                '    Connect-AzAccount @p | Out-Null'
                '} catch {'
                "    [IO.File]::WriteAllText('$($script:_mfaTempResult)', `"AUTH_ERROR:`$_`")"
                '    exit 1'
                '}'
            )
        }
    }
    # Silent mode: Az context auto-loaded from disk; Invoke-AzRestMethod's HTTP
    # pipeline handles claims challenges using cached MFA tokens from MSAL

    # Add ARM operation calls (DELETE, PATCH, etc.)
    $cmdLines += '$errs = @()'
    foreach ($op in $ArmOperations) {
        $method      = $op.Method
        $escapedPath = $op.Path.Replace("'", "''")
        if ($script:_mfaChildLogging) {
            $cmdLines += "[IO.File]::AppendAllText(`$_log, `"Calling $method $($op.Path.Split('/')[-1])...`r`n`")"
        }
        if ($op.Body) {
            $escapedBody = $op.Body.Replace("'", "''")
            if ($script:_mfaChildLogging) {
                $cmdLines += "try { Invoke-AzRestMethod -Method $method -Path '$escapedPath' -Payload '$escapedBody' -ErrorAction Stop | Out-Null; [IO.File]::AppendAllText(`$_log, `"  OK`r`n`") } catch { `$errs += `"$($escapedPath.Split('/')[-1]): `$_`"; [IO.File]::AppendAllText(`$_log, `"  FAILED: `$_`r`n`") }"
            } else {
                $cmdLines += "try { Invoke-AzRestMethod -Method $method -Path '$escapedPath' -Payload '$escapedBody' -ErrorAction Stop | Out-Null } catch { `$errs += `"$($escapedPath.Split('/')[-1]): `$_`" }"
            }
        } else {
            if ($script:_mfaChildLogging) {
                $cmdLines += "try { Invoke-AzRestMethod -Method $method -Path '$escapedPath' -ErrorAction Stop | Out-Null; [IO.File]::AppendAllText(`$_log, `"  OK`r`n`") } catch { `$errs += `"$($escapedPath.Split('/')[-1]): `$_`"; [IO.File]::AppendAllText(`$_log, `"  FAILED: `$_`r`n`") }"
            } else {
                $cmdLines += "try { Invoke-AzRestMethod -Method $method -Path '$escapedPath' -ErrorAction Stop | Out-Null } catch { `$errs += `"$($escapedPath.Split('/')[-1]): `$_`" }"
            }
        }
    }
    $cmdLines += @(
        "if (`$errs.Count -eq 0) { [IO.File]::WriteAllText('$($script:_mfaTempResult)', 'SUCCESS') }"
        "else { [IO.File]::WriteAllText('$($script:_mfaTempResult)', `"ERRORS:`$(`$errs -join '|||')`") }"
    )
    if ($script:_mfaChildLogging) {
        $cmdLines += "[IO.File]::AppendAllText(`$_log, `"Child complete - errs=`$(`$errs.Count) result written`r`n`")"
    }
    [System.IO.File]::WriteAllText($script:_mfaTempScript, ($cmdLines -join "`r`n"))
    & $script:_mfaDbg ("Child script written: $($script:_mfaTempScript)")

    # Launch powershell.exe with the temp script (hidden window - only the browser is visible)
    $script:_mfaProc = Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($script:_mfaTempScript)`"" `
        -PassThru -WindowStyle Hidden

    # Nested dispatcher frame keeps WPF responsive while we poll the child process.
    # Timeout after 5 minutes to prevent the UI hanging indefinitely if the user
    # closes the browser or abandons the MFA prompt without completing auth.
    $script:_mfaFrame = [System.Windows.Threading.DispatcherFrame]::new()
    $script:_mfaStartTime = [DateTime]::UtcNow
    $script:_mfaTimeoutMinutes = 5
    $script:_mfaTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:_mfaTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:_mfaTimer.Add_Tick({
        if ($script:_mfaProc.HasExited) {
            $script:_mfaTimer.Stop()
            $script:_mfaTimer = $null
            $script:_mfaFrame.Continue = $false
        } elseif (([DateTime]::UtcNow - $script:_mfaStartTime).TotalMinutes -ge $script:_mfaTimeoutMinutes) {
            # MFA timed out - kill the child process and exit the frame
            & $script:_mfaDbg "MFA timed out after $($script:_mfaTimeoutMinutes) minutes - killing child process"
            try { $script:_mfaProc.Kill() } catch {}
            $script:_mfaTimer.Stop()
            $script:_mfaTimer = $null
            $script:_mfaFrame.Continue = $false
        }
    })
    $script:_mfaTimer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($script:_mfaFrame)
    & $script:_mfaDbg ("PushFrame exited - child ExitCode: $($script:_mfaProc.ExitCode)")

    # Safety: kill child process if it's still running after PushFrame exits
    try { if (-not $script:_mfaProc.HasExited) { $script:_mfaProc.Kill(); & $script:_mfaDbg "Killed orphaned child process" } } catch {}

    # Clean up temp script
    try { Remove-Item $script:_mfaTempScript -Force -ErrorAction SilentlyContinue } catch {}

    # Read result file from child process (SUCCESS or ERRORS:<err1>|||<err2>)
    & $script:_mfaDbg ("Result file exists: $([System.IO.File]::Exists($script:_mfaTempResult))  Path: $($script:_mfaTempResult)")
    if ([System.IO.File]::Exists($script:_mfaTempResult)) {
        $content = [System.IO.File]::ReadAllText($script:_mfaTempResult)
        try { Remove-Item $script:_mfaTempResult -Force -ErrorAction SilentlyContinue } catch {}

        & $script:_mfaDbg ("Result: $($content.Substring(0, [Math]::Min(200, $content.Length)))")

        if ($content -eq 'SUCCESS') {
            $script:_mfaRetryReady = $true
            $script:_mfaEverDone   = $true
            $StatusText.Text = "MFA complete - operation succeeded."
        } elseif ($content.StartsWith('AUTH_ERROR:')) {
            $errMsg = $content.Substring(11)
            $StatusText.Text = "MFA authentication failed."
            [System.Windows.MessageBox]::Show(
                "MFA re-authentication failed:`n$errMsg",
                "Auth Error", "OK", "Error") | Out-Null
        } elseif ($content.StartsWith('ERRORS:')) {
            $errList = $content.Substring(7) -split '\|\|\|'
            # Check if error is still MFA-related (silent mode cache may have expired)
            $stillMfa = @($errList | Where-Object { $_ -match 'RequestDisallowedByAzure' })
            if ($silentMode -and $stillMfa.Count -gt 0) {
                # Silent mode failed - cached MFA expired; reset flag so next attempt shows dialog
                $script:_mfaEverDone = $false
                $StatusText.Text = "Cached MFA expired - please retry to re-authenticate."
                & $script:_mfaDbg ("Silent mode failed with MFA error - reset _mfaEverDone")
            } else {
                $script:_mfaRetryReady = $true
                $script:_mfaEverDone   = $true
                $StatusText.Text = "MFA complete - some errors occurred."
                [System.Windows.MessageBox]::Show(
                    "Operation completed with errors after MFA:`n$($errList -join "`n")",
                    "Operation Error", "OK", "Error") | Out-Null
            }
        } else {
            $StatusText.Text = "Unexpected MFA result."
            [System.Windows.MessageBox]::Show(
                "Unexpected result from MFA process:`n$($content.Substring(0, [Math]::Min(200, $content.Length)))",
                "Auth Error", "OK", "Error") | Out-Null
        }
    } else {
        $exitCode = $script:_mfaProc.ExitCode
        if ($silentMode) {
            # Silent mode child crashed - reset flag so next attempt shows full dialog
            $script:_mfaEverDone = $false
            $StatusText.Text = "Cached MFA failed - please retry to re-authenticate."
            & $script:_mfaDbg ("Silent mode no result file - reset _mfaEverDone")
        } else {
            $StatusText.Text = "MFA authentication failed."
            [System.Windows.MessageBox]::Show(
                "MFA re-authentication process exited with code $exitCode.`nNo result file was created - check if authentication completed.",
                "Auth Error", "OK", "Error") | Out-Null
        }
    }

    # Resume refresh timer and clean up
    $script:_mfaInProgress = $false
    if ($wasTimerRunning -and $PauseTimer) { $PauseTimer.Start() }
    & $script:_mfaDbg ("Returning true - _mfaRetryReady=$($script:_mfaRetryReady)")
    return $true
}
