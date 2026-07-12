# Az.Accounts Reference — How It Was Used

This document records exactly how `Az.Accounts` was used in the dashboard before the MSAL.NET migration, so it can be restored if needed.

## What it replaced

`Az.Accounts` was the **only** Az module dependency. All data queries already used direct ARM REST calls. The module was needed for five things:

---

## 1. Interactive browser auth

**File:** `scripts/connect-azure.ps1`

```powershell
$ctx = (Connect-AzAccount -ErrorAction Stop).Context
# With optional TenantId / SubscriptionId params
```

Returns an Az context object with `.Account.Id`, `.Tenant.Id`, `.Subscription.Id`, `.Subscription.Name`.

---

## 2. Device code auth

**File:** `scripts/connect-azure.ps1`

```powershell
$ctx = (Connect-AzAccount -UseDeviceAuthentication -ErrorAction Stop).Context
```

---

## 3. Existing session reuse

**File:** `scripts/connect-azure.ps1`

```powershell
$ctx = Get-AzContext -ErrorAction Stop
# If $ctx.Account is set, session is active
```

For subscription switch within an existing session:
```powershell
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
$ctx = Get-AzContext
```

---

## 4. Token acquisition (ARM, Log Analytics, Graph, Storage)

**File:** `scripts/rest-api-helpers.ps1`, functions `Get-ArmToken` and `Get-LawToken`

```powershell
# ARM
$tok = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -AsSecureString -ErrorAction Stop
$plainToken = [System.Net.NetworkCredential]::new('', $tok.Token).Password
# Cache: $script:_armTokenCache[$ResourceUrl] = @{ Token = $plainToken; ExpiresOn = $tok.ExpiresOn }

# Log Analytics — named type first, fall back to URL
$tok = Get-AzAccessToken -ResourceTypeName 'OperationalInsights' -AsSecureString -ErrorAction Stop
# fallback: Get-AzAccessToken -ResourceUrl 'https://api.loganalytics.azure.com/' -AsSecureString
```

Both functions cached the token with a 5-minute buffer before expiry (`$cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)`).

---

## 5. Subscription switch (runspace)

**File:** `avd-live-dashboard.ps1`, ~lines 4758–4780 (pre-migration)

The subscription switch spawned a dedicated runspace because `Import-AzContext` was slow:

```powershell
$swRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$swRS.Open()
$swPS = [System.Management.Automation.PowerShell]::Create()
$swPS.Runspace = $swRS
[void]$swPS.AddScript({
    param($cf, $subId)
    Import-Module Az.Accounts -ErrorAction Stop -WarningAction SilentlyContinue
    Import-AzContext -Path $cf | Out-Null
    $newCtx = Set-AzContext -SubscriptionId $subId -ErrorAction Stop
    Save-AzContext -Path $cf -Force | Out-Null
    [PSCustomObject]@{
        AccountId        = $newCtx.Account.Id
        SubscriptionName = $newCtx.Subscription.Name
        SubscriptionId   = $newCtx.Subscription.Id
    }
}).AddArgument($contextFile).AddArgument($selected.Id)
$result = $swPS.Invoke() | Select-Object -Last 1
```

`$contextFile` was a temp JSON file created at startup via `Save-AzContext -Path $contextFile -Force`.

---

## 6. Context persistence

**File:** `avd-live-dashboard.ps1`

```powershell
# At startup, after Connect-AzureDashboard:
$contextFile = [System.IO.Path]::GetTempFileName() + ".json"
Save-AzContext -Path $contextFile -Force | Out-Null

# At window close:
if (Test-Path $contextFile) { Remove-Item $contextFile -Force -ErrorAction SilentlyContinue }
```

---

## 7. MFA / Claims Challenge

**File:** `scripts/rest-api-helpers.ps1`, function `Resolve-MfaChallenge`

The original implementation spawned a child `powershell.exe` process:
- Imported `Az.Accounts`
- Called `Connect-AzAccount -ClaimsChallenge $claims` (opens browser for step-up MFA)
- Used `Invoke-AzRestMethod` for the ARM operations (its HTTP pipeline auto-handles claims)
- Wrote result to a temp file (`SUCCESS` / `ERRORS:...` / `AUTH_ERROR:...`)
- Parent polled via `DispatcherTimer` + `DispatcherFrame.PushFrame`
- Silent mode (subsequent MFA): skipped Connect-AzAccount, relied on MSAL cache on disk

The child script was written to `%TEMP%\avd-dashboard-mfa-<guid>.ps1`, result at `avd-dashboard-mfa-<guid>.result`.

---

## Re-enabling Az.Accounts

To revert to Az.Accounts:

1. Restore `scripts/connect-azure.ps1` from git history
2. Restore `Get-ArmToken` / `Get-LawToken` / `Resolve-MfaChallenge` in `scripts/rest-api-helpers.ps1` from git history
3. Restore the module check block in `avd-live-dashboard.ps1` (lines ~690–737 pre-migration)
4. Restore `Save-AzContext` line after runspace creation (pre-migration line ~931)
5. Restore the subscription switch runspace (pre-migration lines ~4758-4780)
6. Remove `lib/Microsoft.Identity.Client.dll` and `lib/Microsoft.IdentityModel.Abstractions.dll` from the repo (optional)

## MSAL bundled DLLs

The migration bundles two DLLs in `lib/` (both net462 builds):

- `Microsoft.Identity.Client.dll` (~1.6 MB) - MSAL.NET 4.66.2
- `Microsoft.IdentityModel.Abstractions.dll` (~19 KB) - required dependency of MSAL

Download source: NuGet packages `Microsoft.Identity.Client` (4.66.2) and
`Microsoft.IdentityModel.Abstractions` (6.35.0). Extract the `lib\net462\*.dll`
from each `.nupkg` (a zip archive).

**PowerShell 5.1 gotchas:**

- Load `Microsoft.IdentityModel.Abstractions.dll` BEFORE `Microsoft.Identity.Client.dll`,
  otherwise the MSAL builder throws "Could not load file or assembly
  'Microsoft.IdentityModel.Abstractions'".

- Do NOT use PowerShell scriptblocks for the MSAL token-cache
  `SetBeforeAccess` / `SetAfterAccess` callbacks. MSAL fires them on background
  threads that have no PowerShell runspace, causing "There is no Runspace available
  to run scripts in this thread". The cache callbacks are implemented as a compiled
  C# helper class (`AvdMsalCache`, defined via Add-Type in connect-azure.ps1) whose
  static methods are pure .NET and DPAPI-encrypt the cache file.

- Do NOT use backtick line-continuation to chain MSAL fluent-builder calls
  (`.WithAuthority(...)` on a continued line is a parse error). Use intermediate
  variable assignments instead.

**Known limitation:** The device-code auth path (`-UseDeviceAuthentication`) still
uses a PowerShell scriptblock for its message callback and may hit the same runspace
issue on background-thread invocation. The default interactive browser path is
unaffected. If device code is needed, convert that callback to a C# helper too.

All changes are in a single commit — `git revert <commit>` will undo the entire migration atomically.
