<#
.SYNOPSIS
    Azure REST API helper functions for the AVD Live Dashboard.

.DESCRIPTION
    Provides Invoke-ArmRestMethod (core REST wrapper with pagination, retry, and
    bearer-token auth) plus resource-specific wrapper functions. Token acquisition
    uses MSAL.NET directly (no Az.Accounts required).

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
    MSAL.NET (Microsoft.Identity.Client.dll, bundled in lib/) is used for token
    acquisition. Get-ArmToken / Get-LawToken call AcquireTokenSilent on the
    $script:msalApp instance created by Connect-AzureDashboard. MSAL handles
    caching, expiry detection, and silent refresh internally. The main dashboard
    timer calls Get-ArmToken before each refresh cycle and passes the resulting
    bearer token into runspaces. Runspace threads never call MSAL themselves.

    LOGGING
    -------
    When the dashboard is launched with -EnableLogging, $script:LogFile is set to a
    path in %TEMP%. Invoke-ArmRestMethod checks $script:LogFile; the compact
    Invoke-Arm checks a $LogFile variable passed into the runspace. Both use
    [IO.File]::AppendAllText for thread-safe writes. When logging is not enabled,
    these variables are $null and all logging code is skipped (zero overhead).

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-07-08
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
    Snapshots             = '2025-01-02'  # Snapshots use a different version range to VMs; 2024-07-01 returns InvalidResourceType
    Gallery               = '2022-03-03'
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
# Get-ArmToken / Get-LawToken acquire bearer tokens via MSAL.NET (no Az.Accounts).
# $script:msalApp and $script:msalAccount are set by Connect-AzureDashboard in
# connect-azure.ps1 before these functions are called.
#
# MSAL handles token caching, expiry detection, and silent refresh internally -
# no manual cache hash table is needed. AcquireTokenSilent uses the in-memory
# (and disk-persisted) MSAL cache; it only contacts the network when the cached
# token has expired or is missing.
# ─────────────────────────────────────────────────────────────────────────────

function Get-ArmToken {
    param(
        [string]$ResourceUrl = 'https://management.azure.com/'
    )
    # Convert resource URL to a v2 scope (e.g. https://management.azure.com/.default)
    $scope = $ResourceUrl.TrimEnd('/') + '/.default'
    # NOTE: use an intermediate variable rather than backtick line-continuation
    # chaining - PowerShell parses a leading '.ExecuteAsync' on a continued line
    # as a syntax error.
    $req = $script:msalApp.AcquireTokenSilent([string[]]@($scope), $script:msalAccount)
    $result = $req.ExecuteAsync().GetAwaiter().GetResult()
    return $result.AccessToken
}

function Get-LawToken {
    # Log Analytics uses api.loganalytics.azure.com - different audience from ARM.
    $scope = 'https://api.loganalytics.azure.com/.default'
    $req = $script:msalApp.AcquireTokenSilent([string[]]@($scope), $script:msalAccount)
    $result = $req.ExecuteAsync().GetAwaiter().GetResult()
    return $result.AccessToken
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
# Log Analytics query wrapper
#
# When QueryBaseUrl is set (e.g. https://api.loganalytics.azure.com), queries go
# directly to the Log Analytics API using an api.loganalytics.azure.com-scoped token.
# api.loganalytics.azure.com CNAMEs to api.monitor.azure.com, which the AMPLS
# privatelink.monitor.azure.com private DNS zone overrides to a private endpoint IP.
# When QueryBaseUrl is empty the existing ARM management plane path is used (public).
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-LawQuery {
    param(
        [string]$Kql,
        [string]$Timespan            = 'P1D',
        [string]$WorkspaceResourceId,
        [string]$QueryBaseUrl        = ''
    )
    if ($QueryBaseUrl) {
        $tok  = Get-LawToken
        $uri  = "$QueryBaseUrl/v1$WorkspaceResourceId/query"
        $body = @{ query = $Kql; timespan = $Timespan } | ConvertTo-Json -Compress
        return Invoke-RestMethod -Method POST -Uri $uri -Body $body `
            -Headers @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
    }
    $tok = Get-ArmToken
    return Invoke-ArmRestMethod -Method POST `
        -Path "$WorkspaceResourceId/api/query" `
        -Token $tok -ApiVersion '2020-08-01' `
        -Body @{ query = $Kql; timespan = $Timespan } `
        -FullResponse
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

function Wait-ArmOperation {
    param([string]$OperationUrl,[string]$Token,[int]$TimeoutSeconds=600,[string]$Label='operation')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 10
        $resp  = Invoke-Arm -Path $OperationUrl -Token $Token -FullResponse
        $state = if ($resp.status) { $resp.status } elseif ($resp.properties.provisioningState) { $resp.properties.provisioningState } else { 'Unknown' }
        Write-Host "  [$Label] state: $state ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
        if ($state -eq 'Failed')   { throw "$Label failed: $($resp.error.message)" }
        if ($state -eq 'Canceled') { throw "$Label was canceled" }
    } while ($state -notin @('Succeeded','Completed') -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if ($state -notin @('Succeeded','Completed')) { throw "$Label timed out after ${TimeoutSeconds}s" }
}

function Wait-VMPowerState {
    param([string]$SubscriptionId,[string]$ResourceGroup,[string]$VMName,[string]$Expected,[string]$Token,[string]$ApiVersion='2024-07-01',[int]$TimeoutSeconds=600)
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$VMName/instanceView"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 15
        $iv = Invoke-Arm -Path $path -Token $Token -ApiVersion $ApiVersion -FullResponse
        $ps = ($iv.statuses | Where-Object { $_.code -like 'PowerState/*' }).code
        Write-Host "  VM $VMName power state: $ps ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "Timed out waiting for $VMName to reach $Expected (current: $ps)" }
    } while ($ps -ne $Expected)
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

function Get-ArmSnapshots {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/snapshots" `
        -Token $Token -ApiVersion $script:ApiVersions.Snapshots
}

function Remove-ArmSnapshot {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$SnapshotName, [string]$Token)
    Invoke-ArmRestMethod -Method DELETE `
        -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/snapshots/$SnapshotName" `
        -Token $Token -ApiVersion $script:ApiVersions.Snapshots
}

function Get-ArmGalleries {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/galleries" `
        -Token $Token -ApiVersion $script:ApiVersions.Gallery
}

function Get-ArmGalleryImageDefinitions {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$GalleryName, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/galleries/$GalleryName/images" `
        -Token $Token -ApiVersion $script:ApiVersions.Gallery
}

function Get-ArmGalleryImageVersions {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$GalleryName, [string]$ImageDefinition, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/galleries/$GalleryName/images/$ImageDefinition/versions" `
        -Token $Token -ApiVersion $script:ApiVersions.Gallery
}

function Remove-ArmGalleryImageVersion {
    param([string]$SubscriptionId, [string]$ResourceGroup, [string]$GalleryName, [string]$ImageDefinition, [string]$Version, [string]$Token)
    Invoke-ArmRestMethod -Method DELETE `
        -Path "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/galleries/$GalleryName/images/$ImageDefinition/versions/$Version" `
        -Token $Token -ApiVersion $script:ApiVersions.Gallery
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

function Get-ArmPrivateEndpoints {
    param([string]$SubscriptionId, [string]$Token)
    Invoke-ArmRestMethod -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Network/privateEndpoints" `
        -Token $Token -ApiVersion $script:ApiVersions.Network
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

# ─────────────────────────────────────────────────────────────────────────────
# Async operation polling helpers
# ─────────────────────────────────────────────────────────────────────────────

function Wait-ArmOperation {
    param(
        [string]$OperationUrl,
        [string]$Token,
        [int]   $TimeoutSeconds = 600,
        [string]$Label          = 'operation'
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 10
        $resp  = Invoke-Arm -Path $OperationUrl -Token $Token -FullResponse
        $state = if ($resp.status) { $resp.status } elseif ($resp.properties.provisioningState) { $resp.properties.provisioningState } else { 'Unknown' }
        Write-Host "  [$Label] state: $state ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
        if ($state -eq 'Failed')   { throw "$Label failed: $($resp.error.message)" }
        if ($state -eq 'Canceled') { throw "$Label was canceled" }
    } while ($state -notin @('Succeeded', 'Completed') -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    if ($state -notin @('Succeeded', 'Completed')) { throw "$Label timed out after ${TimeoutSeconds}s" }
}

function Wait-VMPowerState {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$VMName,
        [string]$Expected,
        [string]$Token,
        [string]$ApiVersion     = '2024-07-01',
        [int]   $TimeoutSeconds = 600
    )
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$VMName/instanceView"
    $sw   = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 15
        $iv = Invoke-Arm -Path $path -Token $Token -ApiVersion $ApiVersion -FullResponse
        $ps = ($iv.statuses | Where-Object { $_.code -like 'PowerState/*' }).code
        Write-Host "  VM $VMName power state: $ps ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "Timed out waiting for $VMName to reach $Expected (current: $ps)" }
    } while ($ps -ne $Expected)
}

# =============================================================================
# Resolve-MfaChallenge  -  MFA re-authentication helper
#
# Called by OnComplete callbacks when an ARM operation returns MFA errors.
# Scans the error array for the MFA_CHALLENGE:<claims>:::<session> marker
# produced by scriptblock catch blocks. If found, re-authenticates via MSAL
# with the claims challenge and retries the ARM operations directly.
#
# WHY THIS EXISTS:
#   Invoke-Arm / Invoke-ArmRestMethod are lightweight REST helpers that cannot
#   handle Conditional Access claims challenges - they just throw on 403.
#   When Azure issues a claims challenge, the app must acquire a new token
#   with the claims embedded. MSAL handles this natively via WithClaims().
#
# PARAMETERS:
#   -Errors        Error array to scan for MFA_CHALLENGE markers
#   -ArmOperations Hashtable[] with Method, Path, Body (optional) keys
#   -StatusText    WPF TextBlock for status updates (default: $script:sdStatus)
#   -PauseTimer    DispatcherTimer to pause during MFA (default: $script:sdCountdownTimer)
#
# CALLERS:
#   session-detail.ps1   - logoff OnComplete callbacks
#   tab-sessionhosts.ps1 - drain mode result handler
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
        [hashtable[]]$ArmOperations,
        [System.Windows.Controls.TextBlock]$StatusText,
        [System.Windows.Threading.DispatcherTimer]$PauseTimer
    )
    if (-not $StatusText) { $StatusText = $script:sdStatus }
    if (-not $PSBoundParameters.ContainsKey('PauseTimer')) { $PauseTimer = $script:sdCountdownTimer }

    $script:_mfaRetryReady = $false
    $script:_mfaInProgress = $false

    # Look for MFA_CHALLENGE marker
    $mfaErr = $null
    foreach ($e in $Errors) { if ($e -match '^MFA_CHALLENGE:') { $mfaErr = $e; break } }
    if (-not $mfaErr) { return $false }

    # Extract base64 claims challenge from the marker prefix
    $claims = $null
    $prefix = ($mfaErr -split ':::', 2)[0] -replace '^MFA_CHALLENGE:', ''
    if ($prefix) { $claims = $prefix }

    Write-Log "=== Resolve-MfaChallenge === claims=$(if($claims){'present'}else{'none'}) ops=$($ArmOperations.Count)"

    $wasTimerRunning = $false
    if ($PauseTimer -and $PauseTimer.IsEnabled) { $PauseTimer.Stop(); $wasTimerRunning = $true }

    $msg = "Azure Conditional Access requires elevated authentication for this action.`n`n" +
           "Click Yes to authenticate (browser may open).`n`nClick No to cancel."
    $ans = Show-ThemedDialog -Message $msg -Title 'Elevated Authentication Required' -Buttons YesNo -Icon Question
    if (-not $ans) {
        $StatusText.Text = "Operation cancelled - elevated authentication required."
        if ($wasTimerRunning -and $PauseTimer) { $PauseTimer.Start() }
        return $true
    }

    $StatusText.Text = "Authenticating for elevated access..."
    $script:_mfaInProgress = $true

    $armScopes = [string[]]@('https://management.azure.com/.default')
    $tok = $null
    try {
        # Try silent first with the claims challenge embedded
        $builder = $script:msalApp.AcquireTokenSilent($armScopes, $script:msalAccount)
        if ($claims) { $builder = $builder.WithClaims($claims) }
        $r = $builder.ExecuteAsync().GetAwaiter().GetResult()
        $tok = $r.AccessToken
        $script:msalAccount = $r.Account
        Write-Log "MFA: silent token with claims succeeded"
    } catch {
        Write-Log "MFA: silent failed ($($_.Exception.GetType().Name)) - trying interactive"
        try {
            $builder = $script:msalApp.AcquireTokenInteractive($armScopes).WithAccount($script:msalAccount)
            if ($claims) { $builder = $builder.WithClaims($claims) }
            $r = $builder.ExecuteAsync().GetAwaiter().GetResult()
            $tok = $r.AccessToken
            $script:msalAccount = $r.Account
            Write-Log "MFA: interactive token succeeded"
        } catch {
            Write-Log "MFA: interactive failed: $_"
            $StatusText.Text = "MFA authentication failed."
            Show-ThemedDialog -Message "MFA re-authentication failed:`n$_" -Title 'Auth Error' -Icon Error | Out-Null
            $script:_mfaInProgress = $false
            if ($wasTimerRunning -and $PauseTimer) { $PauseTimer.Start() }
            return $true
        }
    }

    # Execute the ARM operations directly with the fresh token
    $errs = @()
    foreach ($op in $ArmOperations) {
        try {
            Invoke-ArmRestMethod -Method $op.Method -Path $op.Path -Token $tok -Body $op.Body -FullResponse | Out-Null
            Write-Log "MFA op OK: $($op.Method) $($op.Path.Split('/')[-1])"
        } catch {
            $errs += "$($op.Path.Split('/')[-1]): $_"
            Write-Log "MFA op FAILED: $($op.Method) $($op.Path.Split('/')[-1]) - $_"
        }
    }

    if ($errs.Count -eq 0) {
        $script:_mfaRetryReady = $true
        $StatusText.Text = "MFA complete - operation succeeded."
    } else {
        $script:_mfaRetryReady = $true
        $StatusText.Text = "MFA complete - some errors occurred."
        Show-ThemedDialog -Message "Operation completed with errors after MFA:`n$($errs -join `"`n`")" `
            -Title 'Operation Error' -Icon Error | Out-Null
    }

    $script:_mfaInProgress = $false
    if ($wasTimerRunning -and $PauseTimer) { $PauseTimer.Start() }
    Write-Log "Resolve-MfaChallenge returning true - _mfaRetryReady=$($script:_mfaRetryReady)"
    return $true
}