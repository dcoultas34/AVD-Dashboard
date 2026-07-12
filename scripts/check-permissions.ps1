<#
.SYNOPSIS
    Standalone Azure RBAC permissions checker for the AVD Live Dashboard deployment.

.DESCRIPTION
    Connects to Azure using the same authentication options as avd-live-dashboard.ps1,
    then checks what Azure RBAC roles the signed-in account holds against the full set
    required by the dashboard and its supporting scripts.

    Roles are checked at subscription scope first (covers MG-inherited grants), then
    per resource group using the RG lists from config.psd1. No NTFS permissions checked.

.PARAMETER UseDeviceAuthentication
    Use device code flow instead of interactive browser.

.PARAMETER UseExistingContext
    Skip authentication and use the current Az PowerShell context.

.PARAMETER UseServicePrincipal
    Authenticate with a service principal. Reuses the DPAPI-encrypted credential
    saved by avd-live-dashboard.ps1 at %APPDATA%\AVDDashboard\sp-credential.xml.

.PARAMETER ConfigFile
    Path to an alternative config.psd1 file. Defaults to config\config.psd1
    relative to the repository root.

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-04-15
    Requires      : PowerShell 5.1 or PowerShell 7 (Windows)

    DISCLAIMER:
    This script is provided as-is with no warranty, guarantee, or support of any kind.
    Use at your own risk. The author accepts no responsibility for any issues,
    data loss, or damages arising from the use of this script in any environment.
    Always test in a non-production environment before deploying.

    Version History:
    2026-02-27 - Initial release. Checks all RBAC roles required by the dashboard against subscription and per-RG scope. WPF results grid with colour-coded pass/fail rows. Supports interactive, device code, existing context and service principal authentication.
    2026-02-28 - Custom window icon (data\avd-dashboard.ico) applied to splash and main windows. Separate taskbar entry via SetCurrentProcessExplicitAppUserModelID. Wildcard support for LogAnalyticsRGs in config.psd1 - patterns expanded via Get-AzResourceGroup (lazy, one call shared across all roles).
    2026-04-15 - Results grid Granted At column now auto-expands row height to fit long values (e.g. multiple storage accounts). Removed fixed RowHeight=34; rows use MinHeight=34 so single-line rows are unchanged but multi-line content is no longer clipped.
#>

param(
    [switch]$UseDeviceAuthentication,
    [switch]$UseExistingContext,
    [switch]$UseServicePrincipal,
    [string]$ConfigFile
)

# =============================================================================
# WPF assemblies
# =============================================================================

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Set a unique AppUserModelID so the window appears as its own taskbar entry
# (separate from the PowerShell group) and shows the custom window icon.
try {
    $null = Add-Type -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@ -Name 'Shell32CP' -Namespace 'Win32' -PassThru -ErrorAction Stop
    [Win32.Shell32CP]::SetCurrentProcessExplicitAppUserModelID('AVDPermissionsChecker') | Out-Null
} catch { <# non-critical - continue without custom taskbar grouping #> }

# =============================================================================
# Window icon helper (defined locally so script works standalone)
# =============================================================================
if (-not (Get-Command Set-WindowIcon -ErrorAction SilentlyContinue)) {
    function Set-WindowIcon {
        param([System.Windows.Window]$Window, [string]$IconPath)
        if (-not (Test-Path $IconPath)) { return }
        try {
            $stream = [System.IO.File]::OpenRead((Resolve-Path $IconPath).ProviderPath)
            $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                $stream,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $stream.Close()
        } catch {}
    }
}

# =============================================================================
# Theme setup (reads registry; applies at window load)
# =============================================================================
$script:CpRegPath = 'HKCU:\Software\AVDDashboard'
$_cpDark = $false
try {
    $_kv = Get-ItemProperty -Path $script:CpRegPath -Name 'DarkTheme' -ErrorAction Stop
    $_cpDark = [bool][int]$_kv.DarkTheme
} catch {}

# =============================================================================
# Styled message dialog (Show-DashboardMessageDialog) - shared with the apps.
# update-check.ps1 only defines functions at dot-source time; no update check runs.
# =============================================================================
. "$PSScriptRoot\update-check.ps1"

# =============================================================================
# Configuration  (script lives in scripts\, config.psd1 is in ..\config\)
# =============================================================================

$_configFile = if ($ConfigFile) { $ConfigFile } else { Join-Path $PSScriptRoot '..\config\config.psd1' }
if (-not (Test-Path $_configFile)) {
    # No config yet (fresh install): open the Config Editor to create one instead of
    # dead-ending with an error. The checker exits; relaunch it after saving.
    $_editorScript = Join-Path $PSScriptRoot 'edit-config.ps1'
    if (Test-Path $_editorScript) {
        Show-DashboardMessageDialog -Title 'No Configuration Found' -Heading 'No configuration found' -Icon Information `
            -Message 'The Config Editor will now open so you can create one. Fill in your environment details, click Save, then run the permissions checker again.'
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $_editorScript + '"'))
        exit 0
    }
    Show-DashboardMessageDialog -Title 'Missing Configuration File' -Heading 'Configuration file not found' -Icon Error `
        -Message 'Ensure config.psd1 is in the config folder.' -Detail $_configFile
    exit 1
}
try {
    $_cfg = & ([scriptblock]::Create([System.IO.File]::ReadAllText($_configFile)))
} catch {
    Show-DashboardMessageDialog -Title 'Invalid Configuration File' -Heading 'config.psd1 could not be parsed' -Icon Error `
        -Message 'Check the file for syntax errors.' -Detail "$_"
    exit 1
}

$DefaultTenantId       = [string]$_cfg.Azure.TenantId
$DefaultSubscriptionId = [string]$_cfg.Azure.SubscriptionId
$AvdIncludeRGs         = @($_cfg.AVDHostPools.IncludeRGs             | Where-Object { $_ })
$FilesRGs              = @($_cfg.AzureFiles.FilesRGs                  | Where-Object { $_ })
$InfraRGs              = @($_cfg.InfrastructureServers.ResourceGroups   | Where-Object { $_ })
$LogAnalyticsRGs       = @($_cfg.PermissionsChecker.LogAnalyticsRGs      | Where-Object { $_ })
# Storage account names from ProfileTools config - used for per-account data-plane role checks
# Storage account names from ProfileTools config - used for per-account data-plane role checks.
# These are the accounts that need 'Storage File Data Privileged Contributor' for OAuth access.
$ProfileToolsAccounts  = @(
    if ($_cfg.ProfileTools -and $_cfg.ProfileTools.StorageAccountShareMap) {
        $_cfg.ProfileTools.StorageAccountShareMap.Keys | Where-Object { $_ }
    }
)
$VmInfraRGs            = @(($AvdIncludeRGs + $InfraRGs) | Select-Object -Unique | Where-Object { $_ })

# =============================================================================
# Required roles table
# Each entry: RoleName, Feature, ScopeGroup, ScopeRGs (empty = subscription-wide)
# =============================================================================

$RequiredRoles = @(
    [PSCustomObject]@{
        RoleName   = 'Desktop Virtualization Reader'
        Feature    = 'Read host pools, session hosts and workspaces'
        ScopeGroup = 'Host pool RGs'
        ScopeRGs   = $AvdIncludeRGs
    }
    [PSCustomObject]@{
        RoleName   = 'Desktop Virtualization User Session Operator'
        Feature    = 'Log off sessions; send messages to users'
        ScopeGroup = 'Host pool RGs'
        ScopeRGs   = $AvdIncludeRGs
    }
    [PSCustomObject]@{
        RoleName   = 'Desktop Virtualization Session Host Operator'
        Feature    = 'Enable / disable drain mode on session hosts'
        ScopeGroup = 'Host pool RGs'
        ScopeRGs   = $AvdIncludeRGs
    }
    [PSCustomObject]@{
        RoleName   = 'Virtual Machine Contributor'
        Feature    = 'Start / deallocate / restart VMs; Run Command on session hosts'
        ScopeGroup = 'VM / Infra RGs'
        ScopeRGs   = $VmInfraRGs
    }
    [PSCustomObject]@{
        RoleName   = 'Reader'
        Feature    = 'IP resolution, Image Version, VM SKU, Query Details'
        ScopeGroup = 'VM / Infra RGs'
        ScopeRGs   = $VmInfraRGs
    }
    [PSCustomObject]@{
        RoleName   = 'Storage Account Contributor'
        Feature    = 'Enumerate Azure Files storage accounts'
        ScopeGroup = 'Storage RGs'
        ScopeRGs   = $FilesRGs
    }
    [PSCustomObject]@{
        RoleName         = 'Storage File Data Privileged Contributor'
        Feature          = 'Profile Tools - lock detection, handle closure, lock file removal (OAuth data plane access)'
        ScopeGroup       = 'Storage Accounts'
        ScopeRGs         = $FilesRGs
        # Per-account check: enumerate each storage account from ProfileTools config
        # and verify the role is assigned at the resource level (not just RG).
        StorageAccounts  = $ProfileToolsAccounts
    }
    [PSCustomObject]@{
        RoleName   = 'Monitoring Reader'
        Feature    = 'Azure Files share usage metrics'
        ScopeGroup = 'Storage RGs'
        ScopeRGs   = $FilesRGs
    }
    [PSCustomObject]@{
        RoleName   = 'Log Analytics Reader'
        Feature    = 'AVD Insights (Monitoring tab); CPU %, Mem %, Disk % metrics (Session Hosts tab)'
        ScopeGroup = 'LA Workspace RGs'
        ScopeRGs   = $LogAnalyticsRGs   # set PermissionsChecker.LogAnalyticsRGs in config.psd1; empty = check all sub RGs
    }
    [PSCustomObject]@{
        RoleName   = 'Cost Management Reader'
        Feature    = 'Load Costs - actual 30-day disk transaction charges (Session Hosts and Infrastructure tabs)'
        ScopeGroup = 'Subscription'
        ScopeRGs   = @()   # subscription-wide scope - Cost Management query runs at subscription level
    }
)

# =============================================================================
# Early authentication for interactive browser flow
# =============================================================================
# In PS7 MSAL's async browser callback deadlocks against WPF's Dispatcher.
# Authenticate BEFORE any WPF elements exist to avoid this. The other auth
# methods (device code, existing context, service principal) are not affected
# because they either skip the browser callback or run under PS 5.1.

$_earlyAuthContext = $null
if (-not $UseExistingContext -and -not $UseDeviceAuthentication -and -not $UseServicePrincipal) {
    try {
        $_connectParams = @{ ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($DefaultTenantId))       { $_connectParams['TenantId']      = $DefaultTenantId }
        if (-not [string]::IsNullOrWhiteSpace($DefaultSubscriptionId)) { $_connectParams['SubscriptionId'] = $DefaultSubscriptionId }
        $_earlyAuthContext = (Connect-AzAccount @_connectParams).Context
        if (-not $_earlyAuthContext -or -not $_earlyAuthContext.Account) {
            Show-DashboardMessageDialog -Title 'Sign-In Failed' -Heading 'Sign-in did not complete' -Icon Error `
                -Message 'Please try again.'
            exit 1
        }
    } catch {
        Show-DashboardMessageDialog -Title 'Sign-In Failed' -Heading 'Sign-in did not complete' -Icon Error `
            -Message 'The Azure sign-in could not be completed.' -Detail "$_"
        exit 1
    }
}

# =============================================================================
# Splash window
# =============================================================================

[xml]$splashXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="AVD Live Dashboard Permissions Checker" Height="140" Width="400"
    ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
    Background="Transparent" FontFamily="Segoe UI"
    WindowStyle="None" AllowsTransparency="True" Topmost="True">
    <Border CornerRadius="8" Background="White" BorderBrush="#DDE1E7" BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect BlurRadius="20" ShadowDepth="2" Opacity="0.15" Color="#000000"/>
        </Border.Effect>
        <StackPanel VerticalAlignment="Center" Margin="30,24">
            <TextBlock Text="AVD Live Dashboard Permissions Checker"
                       FontSize="16" FontWeight="Bold" Foreground="#0078D4"
                       HorizontalAlignment="Center" Margin="0,0,0,8"/>
            <TextBlock x:Name="SplashStatus" Text="Connecting to Azure..."
                       FontSize="12" Foreground="#666"
                       HorizontalAlignment="Center"/>
        </StackPanel>
    </Border>
</Window>
'@

$splashReader = New-Object System.Xml.XmlNodeReader $splashXaml
$splashWin    = [Windows.Markup.XamlReader]::Load($splashReader)
$splashStatus = $splashWin.FindName("SplashStatus")

if ($_cpDark) {
    $splashWin.Content.Background  = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0x2D, 0x2D, 0x30))
    $splashWin.Content.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0x3F, 0x3F, 0x46))
    $splashStatus.Foreground       = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0xCC, 0xCC, 0xCC))
}

$script:_iconPath = Join-Path $PSScriptRoot '..\data\avd-dashboard.ico'
Set-WindowIcon -Window $splashWin -IconPath $script:_iconPath

$splashWin.Show()
$splashWin.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)

function Set-SplashStatus {
    param([string]$Text)
    $splashWin.Dispatcher.Invoke([Action]{
        $splashStatus.Text = $Text
    }, [System.Windows.Threading.DispatcherPriority]::Render)
}

# =============================================================================
# Authentication  (verbatim blocks from avd-live-dashboard.ps1)
# =============================================================================

if ($UseExistingContext) {

    try   { $azContext = Get-AzContext -ErrorAction Stop }
    catch { $azContext = $null }

    if (-not $azContext -or -not $azContext.Account) {
        $splashWin.Close()
        Show-DashboardMessageDialog -Title 'No Azure Context' -Heading 'No active Azure session found' -Icon Warning `
            -Message 'Please authenticate first by running Connect-AzAccount in a PowerShell window, then relaunch.'
        exit 1
    }
    if (-not [string]::IsNullOrWhiteSpace($DefaultSubscriptionId)) {
        try { Set-AzContext -SubscriptionId $DefaultSubscriptionId -ErrorAction Stop | Out-Null; $azContext = Get-AzContext } catch {}
    }

} elseif ($UseDeviceAuthentication) {

    try {
        $_connectParams = @{ UseDeviceAuthentication = $true; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($DefaultTenantId))       { $_connectParams['TenantId']      = $DefaultTenantId }
        if (-not [string]::IsNullOrWhiteSpace($DefaultSubscriptionId)) { $_connectParams['SubscriptionId'] = $DefaultSubscriptionId }
        $azContext = (Connect-AzAccount @_connectParams).Context
        if (-not $azContext -or -not $azContext.Account) {
            $splashWin.Close()
            Show-DashboardMessageDialog -Title 'Sign-In Failed' -Heading 'Sign-in did not complete' -Icon Error `
                -Message 'Please try again.'
            exit 1
        }
    } catch {
        $splashWin.Close()
        Show-DashboardMessageDialog -Title 'Sign-In Failed' -Heading 'Sign-in did not complete' -Icon Error `
            -Message 'The device-code sign-in could not be completed.' -Detail "$_"
        exit 1
    }

} elseif ($UseServicePrincipal) {

    if ([string]::IsNullOrWhiteSpace($DefaultTenantId)) {
        $splashWin.Close()
        Show-DashboardMessageDialog -Title 'Service Principal - Missing Tenant ID' -Heading 'Tenant ID is not configured' -Icon Error `
            -Message 'Azure.TenantId is not set in config.psd1. Service Principal authentication requires a Tenant ID.'
        exit 1
    }

    # Derive credential filename from the config file name so each config gets
    # its own SP credential. Default config.psd1 maps to sp-credential.xml
    # (backward compatible); prod.psd1 maps to sp-credential-prod.xml, etc.
    $_cfgBase = [System.IO.Path]::GetFileNameWithoutExtension($_configFile)
    $_spCredFile = if ($_cfgBase -eq 'config') { 'sp-credential.xml' } else { "sp-credential-$_cfgBase.xml" }
    $_spCredPath = Join-Path $env:APPDATA "AVDDashboard\$_spCredFile"

    function Show-SPCredentialPrompt {
        $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Service Principal Credentials" Width="430" Height="260"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize" ShowInTaskbar="False">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="Enter the App (Client) ID and Client Secret for the service principal. The credential is encrypted with your Windows account (DPAPI) and saved to AppData."/>
        <Label Grid.Row="1" Content="App (Client) ID:" FontWeight="SemiBold" Padding="0,0,0,2"/>
        <TextBox Grid.Row="2" Name="AppIdBox" Margin="0,0,0,8" Padding="4,3" FontFamily="Consolas"/>
        <Label Grid.Row="3" Content="Client Secret:" FontWeight="SemiBold" Padding="0,0,0,2"/>
        <PasswordBox Grid.Row="4" Name="SecretBox" Margin="0,0,0,4" Padding="4,3"/>
        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="OkBtn" Content="Save and Connect" Width="120" Height="28" Margin="0,0,8,0" IsDefault="True"/>
            <Button Name="CancelBtn" Content="Cancel" Width="70" Height="28" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $script:_spDialogWin = [System.Windows.Markup.XamlReader]::Load($reader)
        $script:_spDialogWin.FindName('OkBtn').Add_Click({
            $appId  = $script:_spDialogWin.FindName('AppIdBox').Text.Trim()
            $secret = $script:_spDialogWin.FindName('SecretBox').Password
            if ([string]::IsNullOrWhiteSpace($appId) -or [string]::IsNullOrWhiteSpace($secret)) {
                Show-DashboardMessageDialog -Title 'Missing Fields' -Icon Warning `
                    -Message 'Both App ID and Client Secret are required.'
                return
            }
            $script:_spDialogAppId  = $appId
            $script:_spDialogSecret = $secret
            $script:_spDialogWin.DialogResult = $true
            $script:_spDialogWin.Close()
        })
        if ($script:_spDialogWin.ShowDialog()) {
            return [pscustomobject]@{ AppId = $script:_spDialogAppId; Secret = $script:_spDialogSecret }
        }
        return $null
    }

    $_spCred = $null
    if (Test-Path $_spCredPath) {
        try { $_spCred = Import-Clixml $_spCredPath -ErrorAction Stop }
        catch {
            Show-DashboardMessageDialog -Title 'Credential Load Failed' -Heading 'Saved credential could not be loaded' -Icon Warning `
                -Message 'You will be prompted to re-enter it.' -Detail "$_"
            $_spCred = $null
        }
    }

    if (-not $_spCred) {
        $_spInput = Show-SPCredentialPrompt
        if (-not $_spInput) { $splashWin.Close(); exit 0 }
        $_spCred = [System.Management.Automation.PSCredential]::new(
            $_spInput.AppId,
            (ConvertTo-SecureString $_spInput.Secret -AsPlainText -Force)
        )
        $_spCredDir = Split-Path $_spCredPath -Parent
        if (-not (Test-Path $_spCredDir)) { New-Item -ItemType Directory -Path $_spCredDir -Force | Out-Null }
        try { $_spCred | Export-Clixml $_spCredPath -Force -ErrorAction Stop }
        catch {
            Show-DashboardMessageDialog -Title 'Credential Save Warning' -Heading 'Credential could not be saved' -Icon Warning `
                -Message 'You will be prompted again on next launch.' -Detail "$_"
        }
    }

    try {
        $_connectParams = @{ ServicePrincipal=$true; TenantId=$DefaultTenantId; Credential=$_spCred; ErrorAction='Stop' }
        if (-not [string]::IsNullOrWhiteSpace($DefaultSubscriptionId)) { $_connectParams['SubscriptionId'] = $DefaultSubscriptionId }
        $azContext = (Connect-AzAccount @_connectParams).Context
        if (-not $azContext -or -not $azContext.Account) {
            $splashWin.Close()
            Show-DashboardMessageDialog -Title 'Sign-In Failed' -Heading 'Sign-in did not complete' -Icon Error `
                -Message 'Service principal sign-in did not complete.'
            exit 1
        }
    } catch {
        $splashWin.Close()
        $_retry = Show-DashboardMessageDialog -Title 'Sign-In Failed' -Heading 'Service principal sign-in failed' -Icon Error `
            -Message 'Would you like to clear the saved credential so you can re-enter it on next launch?' `
            -Detail "$_" -Buttons YesNo
        if ($_retry -and (Test-Path $_spCredPath)) {
            Remove-Item $_spCredPath -Force
            Show-DashboardMessageDialog -Title 'Credential Cleared' -Icon Information `
                -Message 'Saved credential cleared. Relaunch to enter new credentials.'
        }
        exit 1
    }

} else {

    # Interactive browser auth was completed before WPF initialisation
    # (see "Early authentication" block above) to avoid MSAL/Dispatcher deadlock in PS7.
    $azContext = $_earlyAuthContext
}

$script:azAccountId = $azContext.Account.Id

# Use the configured subscription ID when set - this is the authoritative value for RBAC
# scope paths. Script-scoped so Show-SwitchSubscription can update it.
$script:subscriptionId = if (-not [string]::IsNullOrWhiteSpace($DefaultSubscriptionId)) {
    $DefaultSubscriptionId
} else {
    $azContext.Subscription.Id
}

# Best-effort: switch to the configured subscription so Get-AzAccessToken
# returns a token scoped to the right tenant. For group-based accounts
# Set-AzContext may fail (subscription not in the accessible list).
if ($azContext.Subscription.Id -ne $script:subscriptionId) {
    try { Set-AzContext -SubscriptionId $script:subscriptionId -ErrorAction SilentlyContinue | Out-Null; $azContext = Get-AzContext } catch {}
}

# Helper: extract plain-text access token.
# Az.Accounts 3.0+ returns .Token as [SecureString]; older versions return [string].
# PS 5.1 silently coerces SecureString to the literal "System.Security.SecureString"
# when cast to [string], which breaks JWT decoding. This function handles both.
function Get-PlainArmToken {
    $tok = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
    $raw = $tok.Token
    if ($raw -is [securestring]) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($raw)
        try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    return [string]$raw
}

# Best-effort display name lookup via REST - not critical if it fails.
# Script-scoped so Show-SwitchSubscription can update it.
$script:subscriptionName = $azContext.Subscription.Name
if ([string]::IsNullOrWhiteSpace($script:subscriptionName) -or $script:subscriptionName -eq $script:subscriptionId) {
    try {
        $_armTok = Get-PlainArmToken
        $_subResp = Invoke-RestMethod -Method GET `
            -Uri "https://management.azure.com/subscriptions/$($script:subscriptionId)?api-version=2022-12-01" `
            -Headers @{ Authorization = "Bearer $_armTok"; 'Content-Type' = 'application/json' } `
            -ErrorAction SilentlyContinue
        if ($_subResp.displayName) { $script:subscriptionName = $_subResp.displayName }
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($script:subscriptionName)) { $script:subscriptionName = $script:subscriptionId }

# Obtain ARM token for the background runspace (no module loading needed there).
Set-SplashStatus "Preparing token..."
$armToken = Get-PlainArmToken

# =============================================================================
# RBAC check script (runs in background runspace)
# =============================================================================

$rbacScript = {
    param(
        [string]  $ArmToken,
        [string]  $SubId,
        [object[]]$RoleList
    )

    # ── REST helper ──────────────────────────────────────────────────────────
    # Lightweight wrapper for ARM REST calls with pagination support.
    $authHeaders = @{ Authorization = "Bearer $ArmToken"; 'Content-Type' = 'application/json' }
    function Invoke-Arm {
        param([string]$Uri)
        $all = [System.Collections.Generic.List[object]]::new()
        $currentUri = $Uri
        while ($currentUri) {
            $resp = Invoke-RestMethod -Method GET -Uri $currentUri -Headers $authHeaders -ErrorAction Stop
            if ($resp.value) { foreach ($item in $resp.value) { $all.Add($item) } }
            $currentUri = $resp.nextLink
        }
        return $all.ToArray()
    }

    $subScope = "/subscriptions/$SubId"

    # ── Extract ObjectId from the ARM token's JWT claims ─────────────────────
    # The 'oid' claim contains the signed-in principal's ObjectId (user or SP).
    # This avoids any Graph API dependency (Get-AzADUser, Get-AzADServicePrincipal).
    $principalId = $null
    $_jwtErr     = $null
    try {
        $payload = $ArmToken.Split('.')[1]
        $payload = $payload.Replace('-','+').Replace('_','/')
        switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
        $claims = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)) | ConvertFrom-Json
        $principalId = $claims.oid
    } catch { $_jwtErr = $_ }

    if (-not $principalId) {
        $detail = if ($_jwtErr) { "JWT decode error: $_jwtErr" }
                  elseif (-not $ArmToken) { 'Token was null or empty' }
                  else { "Token type: $($ArmToken.GetType().Name), length: $($ArmToken.Length), oid claim missing" }
        return @([PSCustomObject]@{
            Status    = '?'
            StatusKey = 'Error'
            Role      = 'Could not resolve account identity'
            Feature   = 'Unable to extract ObjectId from ARM token'
            Scope     = 'Subscription'
            GrantedAt = $detail
        })
    }

    # ── Pre-fetch role definitions (id -> name lookup) ───────────────────────
    # Role assignments only return roleDefinitionId, not the role name.
    # Fetch all definitions at subscription scope and build a hashtable.
    $roleDefMap = @{}
    try {
        $roleDefs = Invoke-Arm -Uri "https://management.azure.com${subScope}/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01"
        foreach ($rd in $roleDefs) {
            $roleDefMap[$rd.id] = $rd.properties.roleName
            # Also store by the GUID suffix for flexible matching
            $guidPart = $rd.name  # the 'name' field is the GUID
            $roleDefMap[$guidPart] = $rd.properties.roleName
        }
    } catch { }

    # ── Fetch ALL role assignments for the signed-in principal ────────────────
    # The assignedTo() filter returns direct AND group-inherited assignments at
    # every scope (subscription, RG, resource, management group). This is the
    # REST equivalent of Get-AzRoleAssignment -ExpandPrincipalGroups.
    $subAssignErr = $null
    $allAssignments = @()
    try {
        $raw = Invoke-Arm -Uri "https://management.azure.com${subScope}/providers/Microsoft.Authorization/roleAssignments?`$filter=assignedTo('${principalId}')&api-version=2022-04-01"
        # Map to a simple shape with RoleName and Scope
        $allAssignments = @($raw | ForEach-Object {
            $rdId   = $_.properties.roleDefinitionId
            $rdName = $roleDefMap[$rdId]
            if (-not $rdName) {
                # Try by GUID suffix
                $guidPart = $rdId.Split('/')[-1]
                $rdName = $roleDefMap[$guidPart]
            }
            [PSCustomObject]@{
                RoleDefinitionName = $rdName
                Scope              = $_.properties.scope
            }
        })
    } catch {
        $subAssignErr = $_
    }

    # Filter to subscription scope and above (MG-inherited) for the subscription-level check.
    $subAssignments = @($allAssignments |
        Where-Object { $_.Scope -eq $subScope -or $_.Scope -notlike '/subscriptions/*' })
    if ($subAssignments.Count -eq 0 -and $subAssignErr) {
        return @([PSCustomObject]@{
            Status    = '?'
            StatusKey = 'Error'
            Role      = 'Unable to read role assignments'
            Feature   = 'Reader role may be required on the subscription to enumerate IAM'
            Scope     = 'Subscription'
            GrantedAt = "Error: $subAssignErr"
        })
    }

    $subRoleNames = @($subAssignments | ForEach-Object { $_.RoleDefinitionName })

    # Owner / Contributor at subscription (or MG) scope covers most management-plane
    # permissions the dashboard requires. However, data-plane roles like
    # "Storage File Data Privileged Contributor" are NOT covered by Contributor/Owner.
    # These must still be checked individually. Short-circuit only for management-plane roles.
    #
    # Data-plane roles that require explicit assignment (not covered by Owner/Contributor):
    $dataPlaneRoles = @('Storage File Data Privileged Contributor')

    $broadRole = $subRoleNames | Where-Object { $_ -in @('Owner', 'Contributor') } | Select-Object -First 1
    if ($broadRole) {
        # Split the role list: management-plane roles auto-pass, data-plane roles still need checking
        $mgmtRoles = @($RoleList | Where-Object { $_.RoleName -notin $dataPlaneRoles })
        $dataRoles = @($RoleList | Where-Object { $_.RoleName -in $dataPlaneRoles })

        $shortCircuitResults = @($mgmtRoles | ForEach-Object {
            [PSCustomObject]@{
                Status    = [char]0x2713
                StatusKey = 'Granted'
                Role      = [string]$_.RoleName
                Feature   = [string]$_.Feature
                Scope     = [string]$_.ScopeGroup
                GrantedAt = "Subscription ($broadRole)"
            }
        })

        # If no data-plane roles to check, return the short-circuit results
        if ($dataRoles.Count -eq 0) { return $shortCircuitResults }

        # Otherwise, fall through to check data-plane roles individually
        # and prepend the short-circuit results at the end
        $RoleList = $dataRoles
    }

    # ── Lazy wildcard expander ────────────────────────────────────────────────
    # Only enumerates subscription RGs if a pattern contains * or ?.
    # Uses ARM REST instead of Get-AzResourceGroup.
    $script:_allSubRGs = $null
    function Expand-RgWildcards {
        param([string[]]$Patterns)
        if (-not $Patterns -or $Patterns.Count -eq 0) { return @() }
        if (-not ($Patterns | Where-Object { $_ -match '\*|\?' })) { return $Patterns }
        if (-not $script:_allSubRGs) {
            $rgs = Invoke-Arm -Uri "https://management.azure.com${subScope}/resourcegroups?api-version=2024-03-01"
            $script:_allSubRGs = @($rgs | ForEach-Object { $_.name })
        }
        @($Patterns | ForEach-Object {
            $p = $_
            if ($p -match '\*|\?') { $script:_allSubRGs | Where-Object { $_ -like $p } } else { $p }
        } | Select-Object -Unique)
    }

    # Cache for storage account enumeration (populated on first use in per-account checks)
    $script:_allStorageAccounts = $null

    $results = foreach ($req in $RoleList) {

        $roleName   = [string]$req.RoleName
        $feature    = [string]$req.Feature
        $scopeGroup = [string]$req.ScopeGroup
        $scopeRGs   = Expand-RgWildcards @($req.ScopeRGs | Where-Object { $_ })

        # 1. Already granted at subscription (or MG) scope?
        if ($subRoleNames -contains $roleName) {
            [PSCustomObject]@{
                Status    = [char]0x2713    # checkmark
                StatusKey = 'Granted'
                Role      = $roleName
                Feature   = $feature
                Scope     = $scopeGroup
                GrantedAt = 'Subscription'
            }
            continue
        }

        # 2. Per-storage-account check (data-plane roles like Storage File Data Privileged Contributor).
        #    Instead of just checking RG-level assignments, enumerate each storage account from
        #    the ProfileTools config and verify the role is assigned directly on the resource.
        #    This catches cases where Contributor at subscription (management-plane) does NOT
        #    grant data-plane access - the user needs an explicit data-plane role assignment.
        if ($req.StorageAccounts -and $req.StorageAccounts.Count -gt 0) {
            $grantedAccts = [System.Collections.Generic.List[string]]::new()
            $missingAccts = [System.Collections.Generic.List[string]]::new()

            # Enumerate all storage accounts in the subscription once (cached).
            # This avoids repeated API calls when checking multiple accounts.
            if (-not $script:_allStorageAccounts) {
                try {
                    $script:_allStorageAccounts = @(Invoke-Arm -Uri "https://management.azure.com${subScope}/providers/Microsoft.Storage/storageAccounts?api-version=2023-05-01")
                } catch {
                    $script:_allStorageAccounts = @()
                }
            }

            foreach ($acctName in $req.StorageAccounts) {
                # Find the storage account's resource ID from the cached list.
                # This discovers the RG automatically so the user doesn't need to configure it.
                $saMatch = $script:_allStorageAccounts | Where-Object { $_.name -eq $acctName } | Select-Object -First 1

                if (-not $saMatch) {
                    # Storage account not found in this subscription - skip
                    $missingAccts.Add("$acctName (not found)")
                    continue
                }

                # Check if the role is assigned at any scope that covers this resource:
                # subscription, resource group, or directly on the storage account.
                $saScope = $saMatch.id
                $saRgScope = $saScope -replace '/providers/Microsoft\.Storage/storageAccounts/.*$', ''
                $hasRole = $allAssignments | Where-Object {
                    $_.RoleDefinitionName -eq $roleName -and (
                        # Assigned directly on the storage account
                        $_.Scope -eq $saScope -or
                        # Assigned on the resource group containing the storage account
                        $_.Scope -eq $saRgScope -or
                        # Assigned at subscription level (already checked in step 1, but include for completeness)
                        $_.Scope -eq $subScope -or
                        # Assigned at management group level
                        $_.Scope -notlike '/subscriptions/*'
                    )
                } | Select-Object -First 1

                if ($hasRole) {
                    $grantedAccts.Add($acctName)
                } else {
                    $missingAccts.Add($acctName)
                }
            }

            # Build the result based on which accounts have the role.
            # Each account is shown on its own line with a tick or cross prefix
            # so the user can see at a glance which accounts need attention.
            $lines = [System.Collections.Generic.List[string]]::new()
            foreach ($a in $grantedAccts) { $lines.Add("$([char]0x2713) $a") }
            foreach ($a in $missingAccts) { $lines.Add("$([char]0x2717) $a") }
            $detail = $lines -join "`n"

            if ($missingAccts.Count -eq 0) {
                # All storage accounts have the role
                [PSCustomObject]@{
                    Status    = [char]0x2713    # checkmark
                    StatusKey = 'Granted'
                    Role      = $roleName
                    Feature   = $feature
                    Scope     = $scopeGroup
                    GrantedAt = $detail
                }
            } elseif ($grantedAccts.Count -eq 0) {
                # No storage accounts have the role
                [PSCustomObject]@{
                    Status    = [char]0x2717    # cross
                    StatusKey = 'Missing'
                    Role      = $roleName
                    Feature   = $feature
                    Scope     = $scopeGroup
                    GrantedAt = $detail
                }
            } else {
                # Some accounts have the role, some don't
                [PSCustomObject]@{
                    Status    = [char]0x2013    # en dash
                    StatusKey = 'Partial'
                    Role      = $roleName
                    Feature   = $feature
                    Scope     = $scopeGroup
                    GrantedAt = $detail
                }
            }
            continue
        }

        # 3. Subscription-wide role not found at subscription scope
        if ($scopeGroup -eq 'Subscription') {
            [PSCustomObject]@{
                Status    = [char]0x2717    # cross
                StatusKey = 'Missing'
                Role      = $roleName
                Feature   = $feature
                Scope     = $scopeGroup
                GrantedAt = 'Not granted'
            }
            continue
        }

        # 3. No RGs configured in config.psd1 - enumerate all subscription RGs
        $checkedAllSubRGs = $false
        if ($scopeRGs.Count -eq 0) {
            try {
                $rgs = Invoke-Arm -Uri "https://management.azure.com${subScope}/resourcegroups?api-version=2024-03-01"
                $scopeRGs = @($rgs | ForEach-Object { $_.name })
                $checkedAllSubRGs = $true
            } catch {
                [PSCustomObject]@{
                    Status    = [char]0x2013    # en dash
                    StatusKey = 'NotConfigured'
                    Role      = $roleName
                    Feature   = $feature
                    Scope     = $scopeGroup
                    GrantedAt = "Could not enumerate subscription RGs: $_"
                }
                continue
            }
        }

        # 4. Check each resource group
        $grantedRGs = [System.Collections.Generic.List[string]]::new()
        $missingRGs = [System.Collections.Generic.List[string]]::new()

        foreach ($rg in $scopeRGs) {
            $rgScope = "$subScope/resourceGroups/$rg"
            # Filter from the cached assignment set - covers direct and group-inherited roles
            # at this specific RG scope (subscription-level grants are already caught in step 1).
            $rgRoles = @($allAssignments |
                Where-Object { $_.Scope -eq $rgScope } |
                ForEach-Object { $_.RoleDefinitionName })
            if ($rgRoles -contains $roleName) { $grantedRGs.Add($rg) }
            else                              { $missingRGs.Add($rg) }
        }

        $totalRGCount = $scopeRGs.Count
        if ($missingRGs.Count -eq 0) {
            $grantedAtText = if ($checkedAllSubRGs) {
                "All subscription RGs ($totalRGCount)"
            } else {
                ($grantedRGs -join ', ')
            }
            [PSCustomObject]@{
                Status    = [char]0x2713
                StatusKey = 'Granted'
                Role      = $roleName
                Feature   = $feature
                Scope     = $scopeGroup
                GrantedAt = $grantedAtText
            }
        } elseif ($grantedRGs.Count -eq 0) {
            $notGrantedText = if ($checkedAllSubRGs) {
                "Not granted (checked all $totalRGCount subscription RGs)"
            } else {
                'Not granted'
            }
            [PSCustomObject]@{
                Status    = [char]0x2717
                StatusKey = 'Missing'
                Role      = $roleName
                Feature   = $feature
                Scope     = $scopeGroup
                GrantedAt = $notGrantedText
            }
        } else {
            [PSCustomObject]@{
                Status    = [char]0x2013
                StatusKey = 'Partial'
                Role      = $roleName
                Feature   = $feature
                Scope     = $scopeGroup
                GrantedAt = "Partial: $($grantedRGs -join ', ')"
            }
        }
    }

    # If we short-circuited management-plane roles above, prepend those results
    if ($broadRole -and $shortCircuitResults) {
        return @($shortCircuitResults) + @($results)
    }
    return $results
}

# =============================================================================
# Start background RBAC check
# =============================================================================

Set-SplashStatus "Checking role assignments..."

$script:rbacRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$script:rbacRunspace.ApartmentState = "MTA"
$script:rbacRunspace.Open()

$script:rbacPS = [System.Management.Automation.PowerShell]::Create()
$script:rbacPS.Runspace = $script:rbacRunspace
[void]$script:rbacPS.AddScript($rbacScript).AddArgument($armToken).AddArgument($script:subscriptionId).AddArgument($RequiredRoles)
$script:rbacHandle = $script:rbacPS.BeginInvoke()

# =============================================================================
# Main WPF window
# =============================================================================

$_mainXamlRaw = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="AVD Live Dashboard Permissions Checker"
    Height="760" Width="1280"
    MinHeight="560" MinWidth="960"
    WindowStartupLocation="CenterScreen"
    Background="{DynamicResource Avd.Window.Bg}"
    Foreground="{DynamicResource Avd.Window.Fg}"
    FontFamily="Segoe UI"
    UseLayoutRounding="True"
    TextOptions.TextFormattingMode="Display"
    TextOptions.TextRenderingMode="ClearType">

    <Window.Resources>
        <!-- THEME_SLOT -->

        <!-- Dark mode toggle switch -->
        <Style x:Key="ToggleSwitch" TargetType="ToggleButton">
            <Setter Property="Width"  Value="40"/>
            <Setter Property="Height" Value="22"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border x:Name="Track" CornerRadius="11" Background="#AAAAAA">
                            <Ellipse x:Name="Thumb" Width="16" Height="16" Fill="White"
                                     HorizontalAlignment="Left" Margin="3,0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Track" Property="Background" Value="#0078D4"/>
                                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="DataGrid">
            <Setter Property="Background"                    Value="{DynamicResource Avd.Grid.Bg}"/>
            <Setter Property="BorderBrush"                   Value="{DynamicResource Avd.Border.Std}"/>
            <Setter Property="BorderThickness"               Value="1"/>
            <Setter Property="RowBackground"                 Value="{DynamicResource Avd.Grid.Bg}"/>
            <Setter Property="AlternatingRowBackground"      Value="{DynamicResource Avd.AltRow.Bg}"/>
            <Setter Property="GridLinesVisibility"           Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush"      Value="{DynamicResource Avd.Border.Grid}"/>
            <Setter Property="ColumnHeaderHeight"            Value="38"/>
            <Setter Property="FontSize"                      Value="13"/>
            <Setter Property="IsReadOnly"                    Value="True"/>
            <Setter Property="AutoGenerateColumns"           Value="False"/>
            <Setter Property="SelectionMode"                 Value="Single"/>
            <Setter Property="CanUserResizeRows"             Value="False"/>
            <Setter Property="CanUserAddRows"                Value="False"/>
            <Setter Property="VerticalScrollBarVisibility"   Value="Auto"/>
            <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
        </Style>

        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background"                 Value="{DynamicResource Avd.ColHeader.Bg}"/>
            <Setter Property="Foreground"                 Value="{DynamicResource Avd.ColHeader.Fg}"/>
            <Setter Property="FontWeight"                 Value="SemiBold"/>
            <Setter Property="FontSize"                   Value="12"/>
            <Setter Property="Padding"                    Value="12,0"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="BorderBrush"                Value="{DynamicResource Avd.ColHeader.Border}"/>
            <Setter Property="BorderThickness"            Value="0,0,1,0"/>
        </Style>

        <Style TargetType="DataGridCell">
            <Setter Property="Foreground" Value="{DynamicResource Avd.Window.Fg}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="BorderBrush" Value="Transparent"/>
                    <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Selected}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!--
            DataGridRow style: colour by StatusKey first, then overlay hover/select.
            DataTriggers must come BEFORE the interaction triggers so that
            IsMouseOver and IsSelected (defined last) win when active.
        -->
        <Style TargetType="DataGridRow">
            <Setter Property="MinHeight" Value="34"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding [StatusKey]}" Value="Granted">
                    <Setter Property="Background" Value="{DynamicResource Avd.Status.Granted.Bg}"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding [StatusKey]}" Value="Missing">
                    <Setter Property="Background" Value="{DynamicResource Avd.Status.Missing.Bg}"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding [StatusKey]}" Value="Partial">
                    <Setter Property="Background" Value="{DynamicResource Avd.Status.Partial.Bg}"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding [StatusKey]}" Value="NotConfigured">
                    <Setter Property="Background" Value="{DynamicResource Avd.Status.NotConfig.Bg}"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding [StatusKey]}" Value="Error">
                    <Setter Property="Background" Value="{DynamicResource Avd.Status.Missing.Bg}"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding [StatusKey]}" Value="Info">
                    <Setter Property="Background" Value="{DynamicResource Avd.Status.Info.Bg}"/>
                </DataTrigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{DynamicResource Avd.Hover.Bg}"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{DynamicResource Avd.Selected.Bg}"/>
                    <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Selected}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="CardBorder" TargetType="Border">
            <Setter Property="Background"      Value="{DynamicResource Avd.Card.Bg}"/>
            <Setter Property="CornerRadius"    Value="8"/>
            <Setter Property="Padding"         Value="20,14"/>
            <Setter Property="Margin"          Value="6,0,6,0"/>
            <Setter Property="MinWidth"        Value="120"/>
            <Setter Property="BorderBrush"     Value="{DynamicResource Avd.Border.Std}"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>

        <Style x:Key="StatusBtn" TargetType="Button">
            <Setter Property="Background"      Value="Transparent"/>
            <Setter Property="Foreground"      Value="White"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush"     Value="White"/>
            <Setter Property="Padding"         Value="12,4"/>
            <Setter Property="FontSize"        Value="12"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#1A5FA8"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground"   Value="#88B8D8"/>
                                <Setter Property="BorderBrush"  Value="#88B8D8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

    </Window.Resources>

    <DockPanel>

        <!-- Status Bar -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.StatusBar.Bg}" Height="32">
            <Grid Margin="12,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusText"
                           Grid.Column="0"
                           Text="Checking role assignments..."
                           Foreground="White" FontSize="12"
                           VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="SwitchSubButton" Content="Switch Subscription"
                            Style="{StaticResource StatusBtn}"
                            Margin="0,0,8,0"/>
                    <Button x:Name="RecheckButton" Content="Re-check"
                            Style="{StaticResource StatusBtn}"
                            IsEnabled="False"
                            Margin="0,0,8,0"/>
                    <Button x:Name="CloseButton" Content="Close"
                            Style="{StaticResource StatusBtn}"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Header -->
        <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.Header.Bg}" Padding="20,14,20,14">
            <Border.Effect>
                <DropShadowEffect BlurRadius="6" ShadowDepth="1" Opacity="0.10" Color="#000000"/>
            </Border.Effect>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                    <TextBlock Text="AVD Live Dashboard Permissions Checker"
                               FontSize="20" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"/>
                    <TextBlock x:Name="SubtitleText"
                               FontSize="12" Foreground="{DynamicResource Avd.Fg.Muted}" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="Dark" FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}"
                               VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <ToggleButton x:Name="DarkToggle" Style="{StaticResource ToggleSwitch}"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Main content -->
        <Grid Margin="20,16,20,16">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="16"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- Summary cards -->
            <UniformGrid Grid.Row="0" Rows="1">
                <Border Style="{StaticResource CardBorder}">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardRequired" Text="-"
                                   FontSize="30" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"
                                   HorizontalAlignment="Center"/>
                        <TextBlock Text="Required" FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource CardBorder}">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardGranted" Text="-"
                                   FontSize="30" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Available}"
                                   HorizontalAlignment="Center"/>
                        <TextBlock Text="Granted" FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>
                <Border Style="{StaticResource CardBorder}">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardMissing" Text="-"
                                   FontSize="30" FontWeight="Bold" Foreground="#C42B1C"
                                   HorizontalAlignment="Center"/>
                        <TextBlock Text="Missing / Partial" FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>
            </UniformGrid>

            <!-- Results DataGrid -->
            <DataGrid x:Name="ResultsGrid" Grid.Row="2">
                <DataGrid.Columns>
                    <DataGridTextColumn Header="Status"       Binding="{Binding Status}"    Width="Auto" MinWidth="65"/>
                    <DataGridTextColumn Header="Role"         Binding="{Binding Role}"       Width="Auto" MinWidth="120"/>
                    <DataGridTextColumn Header="Required For" Binding="{Binding Feature}"    Width="Auto" MinWidth="120"/>
                    <DataGridTextColumn Header="Scope"        Binding="{Binding Scope}"      Width="Auto" MinWidth="80"/>
                    <DataGridTemplateColumn Header="Granted At" Width="*" MinWidth="150">
                        <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                                <TextBlock Text="{Binding GrantedAt}" TextWrapping="Wrap" Margin="4,2" VerticalAlignment="Center"/>
                            </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                </DataGrid.Columns>
            </DataGrid>

        </Grid>
    </DockPanel>
</Window>
'@

$_mainXamlRaw = $_mainXamlRaw -replace '<!-- THEME_SLOT -->', ''
[xml]$mainXaml = $_mainXamlRaw
$mainReader    = New-Object System.Xml.XmlNodeReader $mainXaml
$mainWin       = [Windows.Markup.XamlReader]::Load($mainReader)

function Switch-PermsTheme {
    param([bool]$Dark)
    $_tf = if ($Dark) { 'dark' } else { 'light' }
    $_tc = Get-Content -Raw -Path (Join-Path $PSScriptRoot "..\data\$_tf-theme.xaml") -ErrorAction Stop
    $_rdXaml = "<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$_tc</ResourceDictionary>"
    $_rd = [Windows.Markup.XamlReader]::Parse($_rdXaml)
    $mainWin.Resources.MergedDictionaries.Clear()
    $mainWin.Resources.MergedDictionaries.Add($_rd)
}

Switch-PermsTheme $_cpDark

$subtitleText  = $mainWin.FindName("SubtitleText")
$cardRequired  = $mainWin.FindName("CardRequired")
$cardGranted   = $mainWin.FindName("CardGranted")
$cardMissing   = $mainWin.FindName("CardMissing")
$resultsGrid   = $mainWin.FindName("ResultsGrid")
$statusText    = $mainWin.FindName("StatusText")
$switchSubButton = $mainWin.FindName("SwitchSubButton")
$recheckButton   = $mainWin.FindName("RecheckButton")
$darkToggle      = $mainWin.FindName("DarkToggle")
$closeButton     = $mainWin.FindName("CloseButton")

$subtitleText.Text = "Checking as: $($script:azAccountId)  |  Subscription: $($script:subscriptionName)"

# =============================================================================
# Helper: build DataTable from result rows and populate the grid
# =============================================================================

function Update-ResultsGrid {
    param([object[]]$Rows)

    $mainWin.Dispatcher.Invoke([Action]{

        # Build DataTable - DataRowView binding is reliable in WPF
        $dt = New-Object System.Data.DataTable
        foreach ($col in @('Status','StatusKey','Role','Feature','Scope','GrantedAt')) {
            $dt.Columns.Add($col) | Out-Null
        }
        foreach ($r in $Rows) {
            $dr = $dt.NewRow()
            $dr['Status']    = [string]$r.Status
            $dr['StatusKey'] = [string]$r.StatusKey
            $dr['Role']      = [string]$r.Role
            $dr['Feature']   = [string]$r.Feature
            $dr['Scope']     = [string]$r.Scope
            $dr['GrantedAt'] = [string]$r.GrantedAt
            $dt.Rows.Add($dr)
        }
        $resultsGrid.ItemsSource = $dt.DefaultView

        # Summary counts (exclude optional 'Info' rows from the RBAC totals)
        $rbacRows = @($Rows | Where-Object { $_.StatusKey -ne 'Info' })
        $total    = $rbacRows.Count
        $granted  = ($rbacRows | Where-Object { $_.StatusKey -eq 'Granted' }).Count
        $bad      = ($rbacRows | Where-Object { $_.StatusKey -in @('Missing','Partial','Error') }).Count

        $cardRequired.Text = [string]$total
        $cardGranted.Text  = [string]$granted
        $cardMissing.Text  = [string]$bad

        $statusText.Text         = "Last checked: $(Get-Date -Format 'HH:mm:ss')  |  $granted of $total roles granted"
        $recheckButton.IsEnabled = $true

    }, [System.Windows.Threading.DispatcherPriority]::Normal)
}

# =============================================================================
# Poll timer - checks background job completion every 500ms
# =============================================================================

$pollTimer          = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$pollTimer.Add_Tick({
    if (-not $script:rbacHandle) { $pollTimer.Stop(); return }
    if (-not $script:rbacHandle.IsCompleted) { return }

    $pollTimer.Stop()

    $rows = $null
    try {
        $rows = @($script:rbacPS.EndInvoke($script:rbacHandle))
    } catch {
        $rows = @([PSCustomObject]@{
            Status    = '?'
            StatusKey = 'Error'
            Role      = 'RBAC check failed'
            Feature   = "$_"
            Scope     = '-'
            GrantedAt = '-'
        })
    } finally {
        try { $script:rbacPS.Dispose() }       catch {}
        try { $script:rbacRunspace.Dispose() } catch {}
        $script:rbacHandle   = $null
        $script:rbacPS       = $null
        $script:rbacRunspace = $null
    }

    if ($rows) {
        # Append optional module/permission checks (run on UI thread - fast)
        $optionalRows = @()

        # Check Microsoft.Graph.Users module
        $mgInstalled = $null -ne (Get-Module -ListAvailable -Name Microsoft.Graph.Users -ErrorAction SilentlyContinue)
        $optionalRows += [PSCustomObject]@{
            Status    = if ($mgInstalled) { [string][char]0x2713 } else { [string][char]0x2717 }
            StatusKey = if ($mgInstalled) { 'Info' } else { 'Missing' }
            Role      = 'Microsoft.Graph.Users module'
            Feature   = 'Session History tab: Enrich from Entra ID (User.Read.All)'
            Scope     = 'Optional'
            GrantedAt = if ($mgInstalled) { 'Installed' } else { 'Not installed - Install-Module Microsoft.Graph.Users -Scope CurrentUser' }
        }

        # Check ActiveDirectory (RSAT) module
        $adInstalled = $null -ne (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)
        $optionalRows += [PSCustomObject]@{
            Status    = if ($adInstalled) { [string][char]0x2713 } else { [string][char]0x2717 }
            StatusKey = if ($adInstalled) { 'Info' } else { 'Missing' }
            Role      = 'ActiveDirectory module (RSAT)'
            Feature   = 'Session History tab: Enrich from AD (Get-ADUser)'
            Scope     = 'Optional'
            GrantedAt = if ($adInstalled) { 'Installed' } else { 'Not installed - requires RSAT Active Directory feature' }
        }

        Update-ResultsGrid -Rows ($rows + $optionalRows)
    }
})

# =============================================================================
# Helper: cancel any in-flight RBAC check and start a fresh one
# =============================================================================

function Start-RbacCheck {
    # Cancel any in-flight check
    if ($script:rbacHandle -and -not $script:rbacHandle.IsCompleted) {
        try { $script:rbacPS.Stop() } catch {}
    }
    if ($script:rbacPS)       { try { $script:rbacPS.Dispose() }       catch {} }
    if ($script:rbacRunspace) { try { $script:rbacRunspace.Dispose() } catch {} }

    $recheckButton.IsEnabled = $false
    $statusText.Text         = "Checking role assignments..."
    $cardRequired.Text = '-'; $cardGranted.Text = '-'; $cardMissing.Text = '-'

    $freshToken = $null
    try { $freshToken = Get-PlainArmToken } catch {
        $statusText.Text = "Failed to acquire token: $_"
        $statusText.Foreground = [System.Windows.Media.Brushes]::Orange
        return
    }
    if (-not $freshToken) {
        $statusText.Text = "Token acquisition returned empty - check Azure sign-in."
        $statusText.Foreground = [System.Windows.Media.Brushes]::Orange
        return
    }

    $script:rbacRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:rbacRunspace.ApartmentState = "MTA"
    $script:rbacRunspace.Open()

    $script:rbacPS = [System.Management.Automation.PowerShell]::Create()
    $script:rbacPS.Runspace = $script:rbacRunspace
    [void]$script:rbacPS.AddScript($rbacScript).AddArgument($freshToken).AddArgument($script:subscriptionId).AddArgument($RequiredRoles)
    $script:rbacHandle = $script:rbacPS.BeginInvoke()

    $pollTimer.Start()
}

# =============================================================================
# Switch Subscription
# =============================================================================

function Show-SwitchSubscription {

    # ── Fetch available subscriptions via REST ────────────────────────────────
    $statusText.Text = "Loading subscriptions..."
    $subs = $null
    try {
        $tok = Get-PlainArmToken
        $_authHdr = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
        $allSubs = [System.Collections.Generic.List[object]]::new()
        $_uri = 'https://management.azure.com/subscriptions?api-version=2022-12-01'
        while ($_uri) {
            $_resp = Invoke-RestMethod -Method GET -Uri $_uri -Headers $_authHdr -ErrorAction Stop
            if ($_resp.value) { foreach ($_s in $_resp.value) { $allSubs.Add($_s) } }
            $_uri = $_resp.nextLink
        }
        $subs = @($allSubs | ForEach-Object {
            [PSCustomObject]@{ Name = $_.displayName; Id = $_.subscriptionId; TenantId = $_.tenantId }
        } | Sort-Object Name)
    } catch {
        $statusText.Text = "Failed to load subscriptions: $_"
        return
    }

    if ($subs.Count -eq 0) {
        $statusText.Text = "No subscriptions found."
        return
    }

    # ── Build subscription picker dialog ──────────────────────────────────────
    $_subXamlRaw = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Switch Subscription" Height="420" Width="520"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        MinHeight="300" MinWidth="400" ShowInTaskbar="False"
        FontFamily="Segoe UI"
        Background="{DynamicResource Avd.Window.Bg}"
        Foreground="{DynamicResource Avd.Window.Fg}">
    <Window.Resources><!-- THEME_SLOT --></Window.Resources>
    <DockPanel Margin="16">
        <TextBlock DockPanel.Dock="Top" Text="Select a subscription:"
                   FontSize="13" FontWeight="SemiBold"
                   Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,10"/>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal"
                    HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="SubCancelBtn" Content="Cancel" Width="80" Height="30"
                    IsCancel="True" Margin="0,0,8,0"/>
            <Button x:Name="SubConfirmBtn" Content="Switch" Width="80" Height="30"
                    IsEnabled="False" IsDefault="True"/>
        </StackPanel>
        <ListBox x:Name="SubList" Margin="0,0,0,0" FontSize="13"
                 Background="{DynamicResource Avd.Input.Bg}"
                 Foreground="{DynamicResource Avd.Window.Fg}"
                 BorderBrush="{DynamicResource Avd.Border.Input}"/>
    </DockPanel>
</Window>
'@

    $_subXamlRaw = $_subXamlRaw -replace '<!-- THEME_SLOT -->', ''
    [xml]$subXaml  = $_subXamlRaw
    $subReader = New-Object System.Xml.XmlNodeReader $subXaml
    $subWin    = [Windows.Markup.XamlReader]::Load($subReader)
    $subWin.Owner = $mainWin

    # Apply current theme to sub-window
    $_tf = if ($_cpDark) { 'dark' } else { 'light' }
    try {
        $_tc = Get-Content -Raw -Path (Join-Path $PSScriptRoot "..\data\$_tf-theme.xaml") -ErrorAction Stop
        $_rd = [Windows.Markup.XamlReader]::Parse("<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$_tc</ResourceDictionary>")
        $subWin.Resources.MergedDictionaries.Add($_rd)
    } catch {}

    Set-WindowIcon -Window $subWin -IconPath $script:_iconPath
    if ($_cpDark) {
        $subWin.Add_SourceInitialized({
            try {
                $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($subWin)).Handle
                $v = 1; [void][Win32.DwmApiCP]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
            } catch {}
        })
    }

    $subList       = $subWin.FindName("SubList")
    $subConfirmBtn = $subWin.FindName("SubConfirmBtn")

    # Populate ListBox
    foreach ($s in $subs) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = "$($s.Name)  ($($s.Id))"
        $item.Tag     = $s
        if ($s.Id -eq $script:subscriptionId) {
            $item.IsSelected = $true
            $item.FontWeight = [System.Windows.FontWeights]::Bold
        }
        $subList.Items.Add($item) | Out-Null
    }

    $sel = $subList.SelectedItem
    if ($sel) { $subList.ScrollIntoView($sel) }

    # Enable Switch button on selection change
    $subList.Add_SelectionChanged({ $subConfirmBtn.IsEnabled = ($null -ne $subList.SelectedItem) })

    # Double-click to confirm
    $subList.Add_MouseDoubleClick({
        if ($subList.SelectedItem) {
            $subWin.Tag = $subList.SelectedItem.Tag
            $subWin.DialogResult = $true
            $subWin.Close()
        }
    })

    $subConfirmBtn.Add_Click({
        if ($subList.SelectedItem) {
            $subWin.Tag = $subList.SelectedItem.Tag
            $subWin.DialogResult = $true
            $subWin.Close()
        }
    })

    # ── Show dialog ───────────────────────────────────────────────────────────
    $statusText.Text = "Select a subscription..."
    $result = $subWin.ShowDialog()

    if (-not $result -or -not $subWin.Tag) {
        $statusText.Text = "Subscription switch cancelled."
        return
    }

    $selected = $subWin.Tag

    # Skip if same subscription
    if ($selected.Id -eq $script:subscriptionId) {
        $statusText.Text = "Already on '$($selected.Name)'."
        return
    }

    # ── Switch Azure context ──────────────────────────────────────────────────
    $statusText.Text = "Switching to '$($selected.Name)'..."
    try {
        Set-AzContext -SubscriptionId $selected.Id -ErrorAction Stop | Out-Null
    } catch {
        $statusText.Text = "Failed to switch subscription: $_"
        return
    }

    # ── Update script state and trigger re-check ──────────────────────────────
    $script:subscriptionId   = $selected.Id
    $script:subscriptionName = $selected.Name
    $subtitleText.Text       = "Checking as: $($script:azAccountId)  |  Subscription: $($script:subscriptionName)"
    $statusText.Text         = "Switched to '$($script:subscriptionName)' - checking role assignments..."

    Start-RbacCheck
}

# =============================================================================
# Button handlers
# =============================================================================

$switchSubButton.Add_Click({ Show-SwitchSubscription })

$recheckButton.Add_Click({ Start-RbacCheck })

$closeButton.Add_Click({ $mainWin.Close() })

$darkToggle.IsChecked = $_cpDark
$darkToggle.Add_Checked({
    try {
        if (-not (Test-Path $script:CpRegPath)) { New-Item $script:CpRegPath -Force | Out-Null }
        Set-ItemProperty -Path $script:CpRegPath -Name 'DarkTheme' -Value 1
    } catch {}
    Switch-PermsTheme $true
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($mainWin)).Handle
        $v = 1; [void][Win32.DwmApiCP]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
    } catch {}
})
$darkToggle.Add_Unchecked({
    try {
        Set-ItemProperty -Path $script:CpRegPath -Name 'DarkTheme' -Value 0
    } catch {}
    Switch-PermsTheme $false
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($mainWin)).Handle
        $v = 0; [void][Win32.DwmApiCP]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
    } catch {}
})

# =============================================================================
# Cleanup on close + shut down the dispatcher so the script exits
# =============================================================================

$mainWin.Add_Closed({
    $pollTimer.Stop()
    try { if ($script:rbacPS)       { $script:rbacPS.Dispose() }       } catch {}
    try { if ($script:rbacRunspace) { $script:rbacRunspace.Dispose() } } catch {}
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvokeShutdown(
        [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
})

# =============================================================================
# Show main window, close splash, start polling
# =============================================================================

Set-WindowIcon -Window $mainWin -IconPath $script:_iconPath

try {
    Add-Type -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);' -Name 'DwmApiCP' -Namespace 'Win32' -ErrorAction Stop
} catch {}
if ($_cpDark) {
    $mainWin.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($mainWin)).Handle
            $v = 1
            [void][Win32.DwmApiCP]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        } catch {}
    })
}

$mainWin.Show()
$splashWin.Close()
$pollTimer.Start()

[System.Windows.Threading.Dispatcher]::Run()
