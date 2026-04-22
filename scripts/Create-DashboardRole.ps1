<#
.SYNOPSIS
    Creates a custom Azure RBAC role with all permissions required by the AVD Live Dashboard.

.DESCRIPTION
    Creates a custom Azure role definition named "AVD Dashboard Operator" scoped to the
    specified subscription. The role consolidates all data-plane and management permissions
    needed to run the dashboard without assigning broad built-in roles such as Reader or
    Contributor across the entire subscription.

    Permissions included cover:
      - AVD host pool, session host, and user session queries
      - Session host power and drain actions (Start, Deallocate, Restart)
      - User session logoff
      - VM tag management (scaling exclude tag on drain)
      - Resource Graph queries (VM/disk enrichment)
      - Azure Monitor Metrics (OS Disk IOPS/Queue via batch and single-resource APIs)
      - Log Analytics workspace queries (CPU, Mem, Disk, Input Delay, Session History)
      - Azure Files storage account metrics
      - Cost Management read access (Load Costs button)
      - Infrastructure VM and NIC read access

    After creation, assign the role to users or groups at the appropriate scope
    (subscription, resource group, or individual resource) using the Azure portal,
    PowerShell, or Azure CLI.

    NOTE: Profile Tools requires additional Storage Account Contributor permissions
    on target storage accounts for FSLogix lock detection and profile deletion.
    These are not included here as they are scoped to specific storage accounts and
    should be assigned separately.

.PARAMETER SubscriptionId
    The subscription ID to scope the role definition to. Defaults to the current
    Az PowerShell context subscription if not specified.

.PARAMETER RoleName
    Name of the custom role to create. Defaults to "AVD Dashboard Operator".

.PARAMETER Update
    If the role already exists, update its permissions to match this script rather
    than exiting with an error.

.EXAMPLE
    .\Create-DashboardRole.ps1

    Creates the "AVD Dashboard Operator" role in the current subscription.

.EXAMPLE
    .\Create-DashboardRole.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

    Creates the role scoped to the specified subscription.

.EXAMPLE
    .\Create-DashboardRole.ps1 -Update

    Updates an existing "AVD Dashboard Operator" role if it already exists.

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-04-02
    Requires      : PowerShell 5.1 or PowerShell 7 (Windows), Az.Accounts, Az.Resources

    DISCLAIMER:
    This script is provided as-is with no warranty, guarantee, or support of any kind.
    Use at your own risk. The author accepts no responsibility for any issues,
    data loss, or damages arising from the use of this script in any environment.
    Always test in a non-production environment before deploying.

    Version History:
    2026-04-02 - Initial release. Creates custom RBAC role with all permissions required by AVD Live Dashboard.

#>

param(
    [string]$SubscriptionId,
    [string]$RoleName = 'AVD Dashboard Operator',
    [switch]$Update
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# Module check — only Az.Accounts required (REST API used for role management)
# =============================================================================

if (-not (Get-Module -ListAvailable -Name 'Az.Accounts')) {
    Write-Error "Required module 'Az.Accounts' is not installed. Run: Install-Module Az.Accounts -Scope CurrentUser"
}

# =============================================================================
# Authentication / subscription
# =============================================================================

$ctx = Get-AzContext
if (-not $ctx) {
    Write-Host 'No Azure context found. Connecting...'
    Connect-AzAccount
    $ctx = Get-AzContext
}

if ($SubscriptionId) {
    if ($ctx.Subscription.Id -ne $SubscriptionId) {
        Write-Host "Switching to subscription: $SubscriptionId"
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        $ctx = Get-AzContext
    }
} else {
    $SubscriptionId = $ctx.Subscription.Id
}

Write-Host ''
Write-Host "Subscription : $($ctx.Subscription.Name) ($SubscriptionId)"
Write-Host "Signed in as : $($ctx.Account.Id)"
Write-Host "Role name    : $RoleName"
Write-Host ''

# =============================================================================
# Role definition
# =============================================================================

# All actions are read-only data queries and the minimum set of write actions
# needed for the dashboard's interactive features. Grouped by feature area
# with a comment explaining which dashboard feature requires each permission.

$actions = @(

    # ── AVD / Desktop Virtualisation ──────────────────────────────────────────
    # Read host pools, session hosts, workspaces, user sessions, host pool agents.
    # Required by: Per Host Pool tab, Session Hosts tab, all AVD data.
    'Microsoft.DesktopVirtualization/hostpools/read'
    'Microsoft.DesktopVirtualization/hostpools/sessionhosts/read'
    'Microsoft.DesktopVirtualization/hostpools/sessionhosts/usersessions/read'
    'Microsoft.DesktopVirtualization/hostpools/sessionhosts/usersessions/delete'    # Session logoff
    'Microsoft.DesktopVirtualization/workspaces/read'
    'Microsoft.DesktopVirtualization/applicationgroups/read'
    'Microsoft.DesktopVirtualization/scalingplans/read'

    # ── Virtual Machines — read and power actions ─────────────────────────────
    # Read: VM properties, sizes, extensions, managed disks.
    # Write: Start/deallocate/restart from Session Hosts and Infrastructure tabs.
    # Required by: Session Hosts tab (power buttons), Infrastructure tab.
    'Microsoft.Compute/virtualMachines/read'
    'Microsoft.Compute/virtualMachines/start/action'                               # Start Selected button
    'Microsoft.Compute/virtualMachines/deallocate/action'                          # Deallocate Selected button
    'Microsoft.Compute/virtualMachines/restart/action'                             # Restart Selected button
    'Microsoft.Compute/virtualMachines/runCommand/action'                          # Run Command feature
    'Microsoft.Compute/virtualMachines/runCommands/read'
    'Microsoft.Compute/virtualMachines/runCommands/write'
    'Microsoft.Compute/virtualMachines/runCommands/delete'
    'Microsoft.Compute/disks/read'                                                 # Disk SKU / tier lookup
    'Microsoft.Compute/locations/vmSizes/read'                                     # VM size lookup for costs

    # ── VM Tags (scaling exclude tag on drain) ────────────────────────────────
    # Required by: Session Hosts tab "Enable/Disable Drain" when the
    # "Set scaling tag on drain" setting is enabled (on by default).
    # Uses the Microsoft.Resources Tags API (Merge/Delete semantics).
    'Microsoft.Resources/tags/write'
    'Microsoft.Resources/tags/delete'
    'Microsoft.Resources/tags/read'

    # ── Network interfaces ────────────────────────────────────────────────────
    # Required by: Infrastructure tab (IP address column), Shadow/RDP IP resolution.
    'Microsoft.Network/networkInterfaces/read'

    # ── Resource Graph ────────────────────────────────────────────────────────
    # Required by: Phase 3 of Session Hosts refresh — batch VM property lookup
    # (Power State, resource ID, disk info) via a single Resource Graph query
    # instead of N per-VM ARM calls.
    'Microsoft.ResourceGraph/resources/read'

    # ── Azure Monitor Metrics ─────────────────────────────────────────────────
    # Required by: Session Hosts tab OS Disk IOPS/IOPS%/Queue columns.
    # Uses the regional batch metrics API and single-resource metrics API.
    # Also required for Azure Files storage account metrics (Used %, Quota).
    'Microsoft.Insights/metrics/read'
    'Microsoft.Insights/metricDefinitions/read'

    # ── Log Analytics Workspace queries ──────────────────────────────────────
    # Required by: Session Hosts tab CPU%/Mem%/Disk%/Input Delay columns,
    # Performance History right-click chart, Session History tab,
    # Monitoring tab (Winlogon Stages, RTT by Gateway).
    'Microsoft.OperationalInsights/workspaces/read'
    'Microsoft.OperationalInsights/workspaces/query/read'

    # ── Storage accounts (Azure Files tab) ───────────────────────────────────
    # Required by: Azure Files tab (share quota, used capacity).
    # Read-only — no write access to storage accounts or file shares.
    'Microsoft.Storage/storageAccounts/read'
    'Microsoft.Storage/storageAccounts/listKeys/action'                            # Required for Azure Files data plane (SharedKey auth for metrics)
    'Microsoft.Storage/storageAccounts/fileServices/read'
    'Microsoft.Storage/storageAccounts/fileServices/shares/read'

    # ── Cost Management ───────────────────────────────────────────────────────
    # Required by: "Load Costs" button — queries actual 30-day disk transaction
    # charges via the Azure Cost Management Query API.
    'Microsoft.CostManagement/query/action'
    'Microsoft.CostManagement/exports/read'

    # ── Resource groups and subscriptions (general read) ─────────────────────
    # Required by: all tabs — resource group location cache used for region
    # resolution, subscription listing for Switch Subscription button.
    'Microsoft.Resources/subscriptions/read'
    'Microsoft.Resources/subscriptions/resourceGroups/read'
    'Microsoft.Resources/deployments/read'
)

# No data actions required — all access is via ARM REST API with bearer token.
$dataActions = @()

# No deny actions.
$notActions     = @()
$notDataActions = @()

# =============================================================================
# ARM token helper — uses Az.Accounts only, same pattern as rest-api-helpers.ps1
# =============================================================================

function Get-ArmToken {
    $tokenObj = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
    # Az.Accounts >= 2.x returns a SecureString token; earlier versions return a plain string
    if ($tokenObj.Token -is [System.Security.SecureString]) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenObj.Token)
        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    return [string]$tokenObj.Token
}

function Invoke-ArmJson {
    param([string]$Method, [string]$Uri, [string]$Token, [hashtable]$Body)
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    $params  = @{ Method = $Method; Uri = $Uri; Headers = $headers; UseBasicParsing = $true }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    $resp = Invoke-WebRequest @params -ErrorAction Stop
    return ($resp.Content | ConvertFrom-Json)
}

# =============================================================================
# Check if role already exists, then create or update via REST
# =============================================================================

$scope       = "/subscriptions/$SubscriptionId"
$description = 'Read and operate permissions required by the AVD Live Dashboard. Covers AVD data, VM power actions, OS Disk metrics, Log Analytics queries, Azure Files read, and Cost Management read.'
$token       = Get-ArmToken

# List custom role definitions at subscription scope and find by name
$listUri  = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleDefinitions?`$filter=type eq 'CustomRole'&api-version=2022-04-01"
$existing = $null
try {
    $listResp = Invoke-ArmJson -Method GET -Uri $listUri -Token $token
    $existing = $listResp.value | Where-Object { $_.properties.roleName -eq $RoleName } | Select-Object -First 1
} catch {
    Write-Warning "Could not list existing role definitions: $_"
}

$roleBody = @{
    properties = @{
        roleName         = $RoleName
        description      = $description
        type             = 'CustomRole'
        permissions      = @(@{
            actions        = $actions
            notActions     = @()
            dataActions    = @()
            notDataActions = @()
        })
        assignableScopes = @($scope)
    }
}

if ($existing) {
    if (-not $Update) {
        Write-Host "Role '$RoleName' already exists (Id: $($existing.name))." -ForegroundColor Yellow
        Write-Host "Run with -Update to update its permissions, or choose a different -RoleName." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Updating existing role '$RoleName'..." -ForegroundColor Cyan
    $putUri = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleDefinitions/$($existing.name)?api-version=2022-04-01"
    Invoke-ArmJson -Method PUT -Uri $putUri -Token $token -Body $roleBody | Out-Null
    Write-Host "Role updated successfully." -ForegroundColor Green
    $roleId = $existing.name

} else {
    Write-Host "Creating role '$RoleName'..." -ForegroundColor Cyan
    # Generate a new GUID for the role definition ID
    $roleId = [guid]::NewGuid().ToString()
    $putUri = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleDefinitions/$roleId`?api-version=2022-04-01"
    Invoke-ArmJson -Method PUT -Uri $putUri -Token $token -Body $roleBody | Out-Null
    Write-Host "Role created successfully." -ForegroundColor Green
}

# =============================================================================
# Summary
# =============================================================================

Write-Host ''
Write-Host "Role ID          : $roleId"
Write-Host "Role Name        : $RoleName"
Write-Host "Assignable Scope : $scope"
Write-Host "Permissions      : $($actions.Count) action(s)"
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host "  1. Assign '$RoleName' to users or groups in the Azure portal or via:"
Write-Host "       New-AzRoleAssignment -ObjectId <userId/groupId> -RoleDefinitionName '$RoleName' -Scope '$scope'"
Write-Host "  2. For Profile Tools: also assign 'Storage Account Contributor' on each"
Write-Host "     target storage account (required for FSLogix lock detection and deletion)."
Write-Host "  3. Run Check-AVD-Permissions.cmd to verify access before launching the dashboard."
Write-Host ''
