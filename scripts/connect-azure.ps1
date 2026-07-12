#
# Azure authentication helper - dot-sourced by avd-live-dashboard.ps1 and profile-tools.ps1.
# Provides Connect-AzureDashboard: a single function that handles all auth modes via MSAL.NET.
#
# Requires: lib/Microsoft.Identity.Client.dll (bundled in repo - no module install needed)
#
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
#

# Load MSAL.NET at dot-source time. The DLLs are bundled in lib/ relative to the repo root.
# $PSScriptRoot is scripts/, so go up one level. Microsoft.Identity.Client depends on
# Microsoft.IdentityModel.Abstractions - load it first so the MSAL builder resolves it.
$_libDir  = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib'
$_absDll  = Join-Path $_libDir 'Microsoft.IdentityModel.Abstractions.dll'
$_msalDll = Join-Path $_libDir 'Microsoft.Identity.Client.dll'
foreach ($_d in @($_absDll, $_msalDll)) {
    if (-not (Test-Path $_d)) {
        throw "Required library not found at '$_d'. See misc/az-accounts-reference.md for download instructions."
    }
    # Windows tags files that arrived via git/OneDrive/a browser download with a
    # Zone.Identifier "Mark of the Web" alternate data stream. The .NET loader can
    # silently no-op Add-Type against a blocked file (no exception, but the type
    # never actually becomes available) instead of throwing - unblock defensively
    # on every load so this is never the cause of a failure.
    try { Unblock-File -Path $_d -ErrorAction SilentlyContinue } catch {}
}

# Guard against double dot-sourcing within the same process (e.g. a config reload
# that re-dot-sources this file) - Add-Type throws if the same simple assembly
# name is loaded twice, even from an identical path.
if (-not ('Microsoft.Identity.Client.PublicClientApplicationBuilder' -as [type])) {
    Add-Type -Path $_absDll  -ErrorAction Stop
    Add-Type -Path $_msalDll -ErrorAction Stop
    if (-not ('Microsoft.Identity.Client.PublicClientApplicationBuilder' -as [type])) {
        throw "Add-Type completed without error, but Microsoft.Identity.Client.PublicClientApplicationBuilder " +
              "still cannot be resolved. The DLL at '$_msalDll' may be corrupt, blocked, or an incompatible " +
              "build - try deleting lib\*.dll and re-downloading them (see misc/az-accounts-reference.md)."
    }
}

# MSAL token-cache persistence helper (compiled C#, not a PowerShell scriptblock).
# MSAL invokes the BeforeAccess/AfterAccess callbacks on background threads that
# have no PowerShell runspace - a scriptblock callback throws "There is no Runspace
# available to run scripts in this thread". A compiled static method is pure .NET
# and runs on any thread. The cache bytes are DPAPI-encrypted (CurrentUser) since
# they contain refresh tokens.
if (-not ('AvdMsalCache' -as [type])) {
    $_cacheCs = @"
using System;
using System.IO;
using System.Security.Cryptography;
using Microsoft.Identity.Client;

public static class AvdMsalCache {
    public static string CacheFile;
    public static void Before(TokenCacheNotificationArgs args) {
        if (File.Exists(CacheFile)) {
            try {
                byte[] prot = File.ReadAllBytes(CacheFile);
                byte[] data = ProtectedData.Unprotect(prot, null, DataProtectionScope.CurrentUser);
                args.TokenCache.DeserializeMsalV3(data, false);
            } catch { }
        }
    }
    public static void After(TokenCacheNotificationArgs args) {
        if (args.HasStateChanged) {
            try {
                string dir = Path.GetDirectoryName(CacheFile);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                byte[] data = args.TokenCache.SerializeMsalV3();
                byte[] prot = ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser);
                File.WriteAllBytes(CacheFile, prot);
            } catch { }
        }
    }
}
"@
    Add-Type -TypeDefinition $_cacheCs -ReferencedAssemblies @($_msalDll, 'System.Security') -ErrorAction Stop
}

function Connect-AzureDashboard {
    <#
    .SYNOPSIS
        Authenticates to Azure via MSAL.NET and returns a context object.

    .DESCRIPTION
        Replaces the Az.Accounts dependency with direct MSAL.NET calls. Supports:
          - Interactive browser (default)
          - Device code flow       (-UseDeviceAuthentication)
          - Silent re-use          (-UseExistingContext, uses cached token from previous run)

        Token cache is persisted to %APPDATA%\AVDDashboard\token-cache.bin.

        On success returns a PSCustomObject with .Subscription, .Account, .Tenant matching
        the shape previously returned by Get-AzContext so all callers are unchanged.
        On failure shows an error dialog and calls exit 1.

    .PARAMETER TenantId
        Azure AD tenant ID to authenticate against. Pass '' to use 'organizations' (multi-tenant).

    .PARAMETER SubscriptionId
        Subscription to activate after sign-in.

    .PARAMETER UseDeviceAuthentication
        Use device code flow instead of interactive browser.

    .PARAMETER UseExistingContext
        Try silent token acquisition from cache first; falls back to interactive if no cached token.

    .PARAMETER UseServicePrincipal
        Not supported in this version (user accounts only). Shows an error if passed.

    .PARAMETER CredentialTag
        Ignored - retained for backward-compatibility with existing config files.

    .PARAMETER LogCallback
        Optional scriptblock called with a single string for log/trace output.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialTag',
        Justification = 'CredentialTag is a config file basename, not a secret value.')]
    param(
        [string]  $TenantId                 = '',
        [string]  $SubscriptionId           = '',
        [switch]  $UseDeviceAuthentication,
        [switch]  $UseExistingContext,
        [switch]  $UseServicePrincipal,
        [string]  $CredentialTag            = 'config',
        [scriptblock] $LogCallback          = $null
    )

    function _Log { param([string]$m); if ($LogCallback) { & $LogCallback $m } }

    # Styled WPF dialog matching the update prompt (Show-DashboardMessageDialog lives in
    # update-check.ps1, which both apps dot-source before this file). Native MessageBox
    # fallback keeps this file usable standalone.
    function _AuthDialog {
        param(
            [string]$Heading,
            [string]$Message,
            [string]$Detail = '',
            [ValidateSet('Information', 'Warning', 'Error')][string]$Icon = 'Error',
            [string]$Title = 'Sign-In Failed'
        )
        if (Get-Command Show-DashboardMessageDialog -ErrorAction SilentlyContinue) {
            Show-DashboardMessageDialog -Title $Title -Heading $Heading -Message $Message -Detail $Detail -Icon $Icon
        } else {
            $img = switch ($Icon) {
                'Error'   { [System.Windows.MessageBoxImage]::Error }
                'Warning' { [System.Windows.MessageBoxImage]::Warning }
                default   { [System.Windows.MessageBoxImage]::Information }
            }
            $full = if ("$Detail".Trim()) { "$Message`n`n$Detail" } else { $Message }
            [System.Windows.MessageBox]::Show($full, $Title, [System.Windows.MessageBoxButton]::OK, $img) | Out-Null
        }
    }

    # Innermost exception message - the part worth showing, without PowerShell's
    # 'Exception calling "GetResult" with "0" argument(s)' method-invocation wrapper.
    function _AuthErrorDetail {
        param($ErrorRecord)
        $ex = $ErrorRecord.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        return "$($ex.Message)".Trim()
    }

    # True when the user cancelled the sign-in themselves (closed the browser window /
    # pressed Cancel). MSAL surfaces that as MsalClientException 'authentication_canceled';
    # the message match is a belt-and-braces fallback for wrapped/rethrown variants.
    function _IsAuthCancelled {
        param($ErrorRecord)
        $ex = $ErrorRecord.Exception
        while ($ex) {
            if ($ex -is [Microsoft.Identity.Client.MsalClientException] -and $ex.ErrorCode -eq 'authentication_canceled') { return $true }
            $ex = $ex.InnerException
        }
        return ("$ErrorRecord" -match 'canceled authentication')
    }

    if ($UseServicePrincipal) {
        _AuthDialog -Title 'Not Supported' -Heading 'Service principal sign-in is not supported' `
            -Message 'This version supports user account authentication only (interactive browser or device code). Launch again without the service principal option.'
        exit 1
    }

    # ─── Build MSAL public client app ────────────────────────────────────────
    # Client ID: Azure PowerShell well-known app (pre-trusted in every Entra tenant).
    # Authority: use explicit tenant if provided, otherwise 'organizations' for multi-tenant.
    $authority = if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        "https://login.microsoftonline.com/$TenantId"
    } else {
        "https://login.microsoftonline.com/organizations"
    }
    _Log "[Auth] Building MSAL app | Authority: $authority"

    # NOTE: Build the app with intermediate variable assignments, NOT backtick
    # line-continuation chaining. PowerShell treats a leading '.Method' on a
    # continued line as a parse error ('Unexpected token .WithAuthority').
    #
    # The whole setup block is wrapped so a failure here shows the same
    # detailed "Sign-In Failed" dialog (with line number) as the auth-mode
    # blocks below, instead of crashing with an unhandled/invisible error.
    try {
        $_builder = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create('1950a258-227b-4e31-a9cf-717495945fc2')
        if (-not $_builder) { throw "PublicClientApplicationBuilder.Create() returned null." }

        $_builder = $_builder.WithAuthority($authority)
        $_builder = $_builder.WithRedirectUri('http://localhost')
        $script:msalApp = $_builder.Build()
        if (-not $script:msalApp) { throw "PublicClientApplicationBuilder.Build() returned null." }

        # ─── Token cache persistence ──────────────────────────────────────────
        # Serialise/deserialise the MSAL token cache to disk (DPAPI-encrypted) so
        # silent re-auth works across dashboard restarts. Replaces Save-AzContext /
        # Import-AzContext. Uses the compiled AvdMsalCache helper (see top of file)
        # because MSAL fires these callbacks on runspace-less background threads.
        $cacheFile = "$env:APPDATA\AVDDashboard\token-cache.bin"
        [AvdMsalCache]::CacheFile = $cacheFile

        if (-not $script:msalApp.UserTokenCache) {
            throw "`$script:msalApp.UserTokenCache is null - cannot wire token-cache persistence."
        }
        $_beforeCb = [Delegate]::CreateDelegate([Microsoft.Identity.Client.TokenCacheCallback], [AvdMsalCache], 'Before')
        $_afterCb  = [Delegate]::CreateDelegate([Microsoft.Identity.Client.TokenCacheCallback], [AvdMsalCache], 'After')
        $script:msalApp.UserTokenCache.SetBeforeAccess($_beforeCb)
        $script:msalApp.UserTokenCache.SetAfterAccess($_afterCb)
    } catch {
        _Log "[Auth] ERROR - MSAL setup failed: $_"
        _AuthDialog -Heading 'Could not start sign-in' `
            -Message 'The Microsoft sign-in components (MSAL) could not be initialised.' `
            -Detail "$(_AuthErrorDetail $_)`n(line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim()))"
        exit 1
    }

    # ─── Authenticate ─────────────────────────────────────────────────────────
    $armScopes   = [string[]]@('https://management.azure.com/.default')
    $authResult  = $null

    # Mode: UseExistingContext - try silent auth from cache first
    if ($UseExistingContext) {
        _Log "[Auth] Mode: UseExistingContext - trying silent token acquisition"
        try {
            $accounts = $script:msalApp.GetAccountsAsync().GetAwaiter().GetResult()
            if ($accounts -and @($accounts).Count -gt 0) {
                $_req = $script:msalApp.AcquireTokenSilent($armScopes, @($accounts)[0])
                $authResult = $_req.ExecuteAsync().GetAwaiter().GetResult()
                _Log "[Auth] Silent token OK: $($authResult.Account.Username)"
            } else {
                _Log "[Auth] No cached accounts - falling back to interactive"
            }
        } catch {
            _Log "[Auth] Silent token failed: $_ - falling back to interactive"
            $authResult = $null
        }
    }

    # Mode: Device code
    if (-not $authResult -and $UseDeviceAuthentication) {
        _Log "[Auth] Mode: DeviceAuthentication"
        try {
            $authResult = $script:msalApp.AcquireTokenByDeviceCode($armScopes, [System.Action[Microsoft.Identity.Client.DeviceCodeResult]]{
                param($dc)
                _Log "[Auth] Device code: $($dc.Message)"
                # Surface the message to the user - write to console (visible in the
                # PowerShell window that launched the dashboard)
                Write-Host "`n$($dc.Message)`n"
            }).ExecuteAsync().GetAwaiter().GetResult()
            _Log "[Auth] Device code sign-in OK: $($authResult.Account.Username)"
        } catch {
            if (_IsAuthCancelled $_) {
                _Log "[Auth] Sign-in cancelled by user"
                _AuthDialog -Title 'Sign-In Cancelled' -Heading 'Sign-in was cancelled' -Icon Warning `
                    -Message 'The dashboard needs an Azure sign-in to start, so it will close now. Launch it again when you are ready to sign in.'
                exit 0
            }
            _Log "[Auth] ERROR - device sign-in failed: $_"
            _AuthDialog -Heading 'Sign-in did not complete' `
                -Message 'The device-code sign-in could not be completed.' `
                -Detail (_AuthErrorDetail $_)
            exit 1
        }
    }

    # Mode: Interactive browser (default, or fallback from UseExistingContext)
    if (-not $authResult) {
        _Log "[Auth] Mode: Interactive browser"
        try {
            $_req = $script:msalApp.AcquireTokenInteractive($armScopes)
            $authResult = $_req.ExecuteAsync().GetAwaiter().GetResult()
            _Log "[Auth] Interactive sign-in OK: $($authResult.Account.Username)"
        } catch {
            if (_IsAuthCancelled $_) {
                _Log "[Auth] Sign-in cancelled by user"
                _AuthDialog -Title 'Sign-In Cancelled' -Heading 'Sign-in was cancelled' -Icon Warning `
                    -Message 'The dashboard needs an Azure sign-in to start, so it will close now. Launch it again when you are ready to sign in.'
                exit 0
            }
            _Log "[Auth] ERROR - interactive sign-in failed: $_"
            _AuthDialog -Heading 'Sign-in did not complete' `
                -Message 'The Azure sign-in could not be completed.' `
                -Detail (_AuthErrorDetail $_)
            exit 1
        }
    }

    # Expose the authenticated account for token functions in rest-api-helpers.ps1
    $script:msalAccount  = $authResult.Account
    $script:msalTenantId = $authResult.TenantId

    _Log "[Auth] Signed in as: $($authResult.Account.Username) | Tenant: $($authResult.TenantId)"

    # ─── Resolve subscription ─────────────────────────────────────────────────
    # Get subscription details from ARM REST (replaces Get-AzContext subscription info).
    # If no SubscriptionId was provided, list available subscriptions and pick the first.
    $armToken = $authResult.AccessToken
    $armHdr   = @{ Authorization = "Bearer $armToken"; 'Content-Type' = 'application/json' }

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        _Log "[Auth] No SubscriptionId configured - fetching available subscriptions"
        try {
            $subs = (Invoke-RestMethod 'https://management.azure.com/subscriptions?api-version=2022-12-01' -Headers $armHdr).value
            if (-not $subs -or @($subs).Count -eq 0) {
                _AuthDialog -Title 'No Subscriptions' -Heading 'No Azure subscriptions found' `
                    -Message "Account '$($authResult.Account.Username)' does not have access to any Azure subscriptions in this tenant."
                exit 1
            }
            $subInfo = @($subs)[0]
            _Log "[Auth] Using first available subscription: $($subInfo.displayName) ($($subInfo.subscriptionId))"
        } catch {
            _Log "[Auth] ERROR fetching subscriptions: $_"
            _AuthDialog -Title 'Subscription Error' -Heading 'Could not list subscriptions' `
                -Message 'You are signed in, but the list of Azure subscriptions could not be retrieved.' `
                -Detail (_AuthErrorDetail $_)
            exit 1
        }
    } else {
        _Log "[Auth] Fetching subscription: $SubscriptionId"
        try {
            $subInfo = Invoke-RestMethod "https://management.azure.com/subscriptions/$SubscriptionId`?api-version=2022-12-01" -Headers $armHdr
        } catch {
            _Log "[Auth] ERROR fetching subscription '$SubscriptionId': $_"
            _AuthDialog -Title 'Subscription Error' -Heading 'Could not open the subscription' `
                -Message "Subscription '$SubscriptionId' (from your config) could not be retrieved. Check the ID and that your account has access to it." `
                -Detail (_AuthErrorDetail $_)
            exit 1
        }
    }

    _Log "[Auth] Subscription: $($subInfo.displayName) ($($subInfo.subscriptionId))"

    # Return a context object matching the shape previously provided by Get-AzContext.
    # All callers read .Subscription.Id, .Subscription.Name, .Account.Id, .Tenant.Id.
    return [PSCustomObject]@{
        Subscription = [PSCustomObject]@{
            Id   = $subInfo.subscriptionId
            Name = $subInfo.displayName
        }
        Account = [PSCustomObject]@{ Id = $authResult.Account.Username }
        Tenant  = [PSCustomObject]@{ Id = $authResult.TenantId }
    }
}
