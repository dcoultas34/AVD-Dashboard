<#
.SYNOPSIS
    Profile Tools - standalone WPF GUI for FSLogix profile management tasks.

.DESCRIPTION
    A companion tool to the AVD Live Dashboard.
    Provides a polished GUI interface for administrative operations
    that would otherwise require running scripts interactively in a terminal.

    Tools included:
      - Delete FSLogix Profile: checks for active locks and open handles,
        optionally force-closes them, then removes the profile folder from
        all configured Azure File Share storage accounts.
      - Storage Locations: quick-launch links to open each configured
        Azure File Share UNC path directly in Windows Explorer.
      - Profile Sizes: enumerates and displays the size and file count of
        every profile subfolder across one or more Azure File Share locations.
      - Profile Cleanup: scans for stale profile folders by last file activity
        age with a configurable threshold, and supports selective or bulk deletion.

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-05-26
    Requires      : PowerShell 5.1 or PowerShell 7 (Windows)

    DISCLAIMER:
    This script is provided as-is with no warranty, guarantee, or support of any kind.
    Use at your own risk. The author accepts no responsibility for any issues,
    data loss, or damages arising from the use of this script in any environment.
    Always test in a non-production environment before deploying.

    Version History:
    2026-02-23 - Initial release.
    2026-02-24 - PS version in About box. Replaced Import-PowerShellDataFile for PS7 compatibility.
    2026-02-24 - Bug fix: Delete FSLogix Profile Phase 3 not deleting folders. Changed Start-BgJob to
                          support named parameter passing (AddParameter) so arrays are correctly bound in
                          sub-scripts. Fixed lock detection failing when multiple storage accounts selected
                          (array flattening caused wrong args to be passed to profile-delete-check.ps1).
    2026-02-24 - Bug fix: Phase 1 lock detection not finding locks. $FileShareName was never loaded
                          from config (undefined variable passed as $null to Get-AzStorageFile). Added
                          FileShareName to config.psd1 ProfileTools section and loaded it at startup.
    2026-02-25 - About box: Version History title moved inside its bordered box for consistent styling.
    2026-03-02 - Initial REST API release. Replaced Az.Storage module dependency with direct
                          Azure Files REST API calls (SharedKey auth). Only Az.Accounts is now required.
                          Storage account keys retrieved via ARM REST API at startup. Added splash screen
                          with progress bar during startup (matching live dashboard style).
    2026-04-15 - Storage account pairing. Added StorageAccountPairs config key under ProfileTools.
                          Named pairs of storage accounts can be defined in config.psd1. Each pair
                          appears as a radio button above the storage account checkboxes on all action
                          tabs (Delete, Remove Locks, Profile Sizes, Profile Cleanup). Selecting a pair
                          radio ticks only that pair's account checkboxes and deselects the other pairs.
    2026-07-08 - Removed the Az.Accounts module dependency, replaced with bundled MSAL.NET
                          (see avd-live-dashboard.ps1 changelog / CHANGELOG.md for full details).
                          Service principal authentication removed.

    Requirements:
      - lib\Microsoft.Identity.Client.dll and lib\Microsoft.IdentityModel.Abstractions.dll
        (bundled in the repo - no module install needed)

    Customer/environment-specific settings ($StorageAccountShareMap,
    $ExcludeStorage, $FileShareSubPath) are loaded from
    config.psd1, which must be present in the config subfolder alongside this script.

.PARAMETER EnableLogging
    When specified, writes detailed REST API call logs (ARM and Azure Files data
    plane) to a timestamped file in %TEMP%. The log file path is displayed in the
    console at startup.

.PARAMETER ConfigFile
    Path to an alternative config.psd1 file. Defaults to config\config.psd1
    relative to the script root.

.PARAMETER UseDeviceAuthentication
    Use device code flow instead of interactive browser sign-in.

.PARAMETER UseExistingContext
    Try silent token acquisition from the local MSAL token cache first; falls
    back to interactive browser sign-in automatically if no cached token is found.

.PARAMETER UseServicePrincipal
    Not supported. Retained only for backward-compatibility with existing
    shortcuts/configs - shows a "Not Supported" dialog and exits if passed.

.EXAMPLE
    .\Profile-Tools.ps1

.EXAMPLE
    .\Profile-Tools.ps1 -UseDeviceAuthentication

.EXAMPLE
    .\Profile-Tools.ps1 -UseExistingContext

.EXAMPLE
    .\Profile-Tools.ps1 -EnableLogging
#>

param(
    [switch]$EnableLogging,
    [string]$ConfigFile,
    [switch]$UseDeviceAuthentication,
    [switch]$UseExistingContext,
    [switch]$UseServicePrincipal,
    [int]$DashboardTheme = -1,
    [switch]$SkipUpdateCheck
)

# =============================================================================
# Script version - not customer-specific, stays here rather than in config
# =============================================================================

$ScriptVersion = "2026-07-11.2"

# Captured once, at top level, so the update-check flow can relaunch this exact script
# with the same arguments it was originally passed.
$script:_ptScriptPath  = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$script:_ptBoundParams = $PSBoundParameters

# Auto-update support. Dot-sourced this early (before any Add-Type) so that
# Complete-DashboardPendingUpdate can swap in files a previous update couldn't overwrite
# while they were loaded (lib\*.dll) - the swap has to happen before anything locks them.
. (Join-Path $PSScriptRoot 'scripts\update-check.ps1')
Complete-DashboardPendingUpdate -RepoRoot $PSScriptRoot

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

try {
    Add-Type -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);' `
             -Name 'DwmApiPT' -Namespace 'Win32' -ErrorAction Stop
} catch {}

# Read dark theme: from dashboard parameter if launched from dashboard, else from registry
$script:_ptRegPath = 'HKCU:\Software\AVDDashboard'
$_ptLaunchedFromDashboard = ($DashboardTheme -ge 0)
$_ptDark = $false
if ($_ptLaunchedFromDashboard) {
    $_ptDark = [bool]$DashboardTheme
} else {
    try {
        $_kv = Get-ItemProperty -Path $script:_ptRegPath -Name 'DarkTheme' -ErrorAction Stop
        $_ptDark = [bool][int]$_kv.DarkTheme
    } catch {}
}
$script:_ptDark = $_ptDark

# =============================================================================
# Splash / Loading Window - shown after auth completes
# =============================================================================

[xml]$splashXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Profile Tools" Height="160" Width="420"
    ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
    Background="Transparent" FontFamily="Segoe UI"
    WindowStyle="None" AllowsTransparency="True" Topmost="True">
    <Border CornerRadius="8" Background="White" BorderBrush="#DDE1E7" BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect BlurRadius="20" ShadowDepth="2" Opacity="0.15" Color="#000000"/>
        </Border.Effect>
        <StackPanel VerticalAlignment="Center" Margin="30,24">
            <TextBlock Text="Profile Tools"
                       FontSize="16" FontWeight="Bold" Foreground="#0078D4"
                       HorizontalAlignment="Center" Margin="0,0,0,6"/>
            <TextBlock x:Name="SplashStatus" Text="Starting up..."
                       FontSize="12" Foreground="#666"
                       HorizontalAlignment="Center" Margin="0,0,0,16"/>
            <ProgressBar x:Name="SplashProgress" IsIndeterminate="False"
                         Minimum="0" Maximum="100" Value="0"
                         Height="3" Background="#E8EAED" Foreground="#0078D4"
                         BorderThickness="0"/>
        </StackPanel>
    </Border>
</Window>
'@

$splashReader    = New-Object System.Xml.XmlNodeReader $splashXaml
$splashWin       = [Windows.Markup.XamlReader]::Load($splashReader)
$splashStatus    = $splashWin.FindName("SplashStatus")
$splashProgress  = $splashWin.FindName("SplashProgress")
if ($_ptDark) {
    $splashBorder = $splashWin.Content
    $splashBorder.Background  = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0x25,0x25,0x26)
    $splashBorder.BorderBrush = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0x3F,0x3F,0x46)
    $splashStatus.Foreground  = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0x9D,0x9D,0x9D)
    try {
        $splashWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($splashWin)).Handle
            $v = 1
            [void][Win32.DwmApiPT]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    } catch {}
}

function Set-SplashStatus {
    param([string]$Text, [int]$Progress = -1)
    if (-not $splashWin.IsVisible) { return }
    $splashWin.Dispatcher.Invoke([Action]{
        $splashStatus.Text = $Text
        if ($Progress -ge 0) { $splashProgress.Value = $Progress }
    }, [System.Windows.Threading.DispatcherPriority]::Render)
}

# Set a unique AppUserModelID so Profile Tools appears as its own taskbar entry
# (separate from the PowerShell group) and shows the custom window icon.
try {
    $null = Add-Type -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@ -Name 'Shell32' -Namespace 'Win32' -PassThru -ErrorAction Stop
    [Win32.Shell32]::SetCurrentProcessExplicitAppUserModelID('AVDProfileTools') | Out-Null
} catch { <# non-critical - continue without custom taskbar grouping #> }

# =============================================================================
# Constants - adjust these values to change behaviour without editing logic
# =============================================================================

$CLEANUP_THRESHOLD_DEFAULT = 90     # Default stale profile inactivity threshold (days)
$CLEANUP_THRESHOLD_MIN     = 1      # Minimum allowed threshold (days)
$CLEANUP_THRESHOLD_MAX     = 3650   # Maximum allowed threshold (days)
$CLEANUP_CONFIRM_CAP       = 20     # Max folders listed in the confirmation dialog
$CLEANUP_BATCH_WARN        = 50     # Folder count above which a large-batch warning is shown
$CLEANUP_RUNSPACE_MAX      = 6      # Max concurrent runspaces when deleting folders in parallel

$script:_ptActiveJobs = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()

# =============================================================================
# Multi-config support
# Mirrors the same logic in avd-live-dashboard.ps1 so profile-tools respects
# whichever config the dashboard selected (passed via -ConfigFile when launched
# from the dashboard) or lets the user pick when launched standalone.
# =============================================================================

function Get-PtAvailableConfigs {
    @(
        Get-ChildItem -Path (Join-Path $PSScriptRoot 'config') -Filter '*.psd1' -ErrorAction SilentlyContinue |
        Where-Object  { $_.Name -ne 'EXAMPLE-config.psd1' } |
        Sort-Object   Name |
        ForEach-Object {
            $_slug = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            $_disp = $_slug
            try {
                $_d = & ([scriptblock]::Create([System.IO.File]::ReadAllText($_.FullName)))
                if ($_d.Name) { $_disp = [string]$_d.Name }
            } catch {}
            [PSCustomObject]@{ Path = $_.FullName; Slug = $_slug; DisplayName = $_disp }
        }
    )
}

function Show-PtConfigPicker {
    param([object[]]$Configs, [bool]$AllowCancel = $true)
    $_tf  = if ($script:_ptDark) { 'dark' } else { 'light' }
    $_thm = Get-Content -Raw -Path (Join-Path $PSScriptRoot "data\$_tf-theme.xaml") -ErrorAction SilentlyContinue
    $_raw = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Profile Tools - Select Configuration"
        SizeToContent="Height" Width="400"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="{DynamicResource Avd.Window.Bg}"
        FontFamily="Segoe UI" ShowInTaskbar="True">
    <Window.Resources>
        <!-- THEME_SLOT -->
    </Window.Resources>
    <Border Padding="24,20,24,20">
        <StackPanel>
            <TextBlock Text="Select a configuration:" FontSize="13" FontWeight="SemiBold"
                       Foreground="{DynamicResource Avd.Window.Fg}" Margin="0,0,0,10"/>
            <ListBox x:Name="ConfigList" Height="130" Margin="0,0,0,12"
                     BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                     Background="{DynamicResource Avd.Card.Bg}"
                     Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12"/>
            <CheckBox x:Name="SetDefaultCheck" Content="Remember this choice"
                      Foreground="{DynamicResource Avd.Window.Fg}" Margin="0,0,0,4"/>
            <Button x:Name="ClearDefaultBtn" Content="Clear saved default"
                    HorizontalAlignment="Left" FontSize="11" Background="Transparent"
                    BorderThickness="0" Foreground="#2563EB" Cursor="Hand"
                    Visibility="Collapsed" Padding="0" Margin="0,2,0,0"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
                <Button x:Name="CancelBtn" Content="Cancel"
                        Width="90" Height="32" Margin="0,0,8,0"
                        Foreground="{DynamicResource Avd.Fg.Label}"
                        BorderThickness="0" FontSize="13" Cursor="Hand">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="Bd" Background="{DynamicResource Avd.Btn.Cancel.Bg}" CornerRadius="4" Padding="8,0">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Btn.Cancel.Hover}"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Btn.Cancel.Press}"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="OkBtn" Content="Load"
                        Width="90" Height="32"
                        Foreground="White" BorderThickness="0" FontSize="13" FontWeight="SemiBold" Cursor="Hand">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="Bd" Background="{DynamicResource Avd.Btn.Save.Bg}" CornerRadius="4" Padding="8,0">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Btn.Save.Hover}"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Btn.Save.Press}"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </StackPanel>
        </StackPanel>
    </Border>
</Window>
'@
    $_raw = $_raw -replace '<!-- THEME_SLOT -->', $_thm
    [xml]$_cx = $_raw
    $_w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $_cx))
    if ($script:_ptDark) {
        $_w.Add_SourceInitialized({
            param($s, $e)
            try { $_h = (New-Object System.Windows.Interop.WindowInteropHelper($s)).Handle; $_dv = 1; [void][Win32.DwmApiPT]::DwmSetWindowAttribute($_h, 20, [ref]$_dv, 4) } catch {}
        })
    }
    $_list   = $_w.FindName('ConfigList')
    $_okBtn  = $_w.FindName('OkBtn')
    $_cnlBtn = $_w.FindName('CancelBtn')
    $_setDef = $_w.FindName('SetDefaultCheck')
    $_clrBtn = $_w.FindName('ClearDefaultBtn')

    foreach ($_c in $Configs) { [void]$_list.Items.Add($_c.DisplayName) }
    if ($_list.Items.Count -gt 0) { $_list.SelectedIndex = 0 }

    # Show "Clear saved default" link only when a default is already saved and cancel is allowed
    # (i.e. this is an in-app switch, not the mandatory startup prompt)
    $_rootReg = 'HKCU:\Software\AVDDashboard'
    $_hasDef  = $false
    try { $_hasDef = $null -ne (Get-ItemProperty -Path $_rootReg -Name 'DefaultConfig' -ErrorAction Stop).DefaultConfig } catch {}
    if ($_hasDef -and $AllowCancel) { $_clrBtn.Visibility = 'Visible' }

    # At startup (AllowCancel=$false): hide Cancel, button says "Load"
    # From Switch Config button (AllowCancel=$true): show Cancel, button says "Switch"
    if (-not $AllowCancel) { $_cnlBtn.Visibility = 'Collapsed' }
    if ($AllowCancel)      { $_okBtn.Content = 'Switch' }

    $_okBtn.Add_Click({
        if ($_list.SelectedIndex -lt 0) { return }
        $script:_ptCfgPickerResult = @{
            Config       = $Configs[$_list.SelectedIndex]
            SetDefault   = [bool]$_setDef.IsChecked
            ClearDefault = $false
        }
        $_w.DialogResult = $true; $_w.Close()
    })
    $_cnlBtn.Add_Click({ $_w.DialogResult = $false; $_w.Close() })
    $_clrBtn.Add_Click({
        $script:_ptCfgPickerResult = @{ Config = $null; SetDefault = $false; ClearDefault = $true }
        $_w.DialogResult = $true; $_w.Close()
    })

    $null = $_w.ShowDialog()
    if (-not $_w.DialogResult) { return $null }
    return $script:_ptCfgPickerResult
}

function Resolve-PtStartupConfig {
    $_rootReg = 'HKCU:\Software\AVDDashboard'
    $configs  = Get-PtAvailableConfigs
    if ($configs.Count -le 1) {
        if ($configs.Count -eq 1) { return $configs[0].Path }
        return Join-Path $PSScriptRoot 'config\config.psd1'
    }
    # Multiple configs: check for a saved default
    $_savedSlug = try { (Get-ItemProperty -Path $_rootReg -Name 'DefaultConfig' -ErrorAction Stop).DefaultConfig } catch { $null }
    if ($_savedSlug) {
        $_m = $configs | Where-Object { $_.Slug -eq $_savedSlug } | Select-Object -First 1
        if ($_m) {
            $script:_ptRegPath = "$_rootReg\$($_m.Slug)"
            return $_m.Path
        }
    }
    # No usable default: show picker. Cancel exits because we cannot continue without a config.
    $_p = Show-PtConfigPicker -Configs $configs -AllowCancel $false
    if (-not $_p -or -not $_p.Config) { exit }
    if ($_p.SetDefault) {
        if (-not (Test-Path $_rootReg)) { try { New-Item -Path $_rootReg -Force | Out-Null } catch {} }
        try { Set-ItemProperty -Path $_rootReg -Name 'DefaultConfig' -Value $_p.Config.Slug } catch {}
    }
    $script:_ptRegPath = "$_rootReg\$($_p.Config.Slug)"
    return $_p.Config.Path
}

# =============================================================================
# Customer / Environment Configuration
# All environment-specific settings are loaded from config.psd1 which
# must be present in the config subfolder alongside this script. Edit that file
# - not this one - when deploying to a new customer or environment.
# =============================================================================

if ($ConfigFile) {
    # Launched from the dashboard with an explicit config path.
    # Derive the slug from the filename so the per-config registry subkey matches
    # what the dashboard is using, then skip the picker entirely.
    $_configFile = $ConfigFile
    $_cfgSlug    = [System.IO.Path]::GetFileNameWithoutExtension($ConfigFile)
    $_rootReg    = 'HKCU:\Software\AVDDashboard'
    $script:_ptRegPath = if ((Get-PtAvailableConfigs).Count -gt 1) { "$_rootReg\$_cfgSlug" } else { $_rootReg }
} else {
    $_configFile = Resolve-PtStartupConfig
}
$script:_ptConfigFile = $_configFile   # stored for Switch Config button access
$script:profileSizeScript        = Join-Path $PSScriptRoot 'scripts\profile-sizes.ps1'
$script:profileCleanupScript     = Join-Path $PSScriptRoot 'scripts\profile-cleanup.ps1'
$script:profileDeleteScript      = Join-Path $PSScriptRoot 'scripts\profile-delete-check.ps1'
$script:profileDeleteLocksScript = Join-Path $PSScriptRoot 'scripts\profile-delete-unlock.ps1'
$script:profileDeleteRemoveScript= Join-Path $PSScriptRoot 'scripts\profile-delete-remove.ps1'
if (-not (Test-Path $_configFile)) {
    Show-DashboardMessageDialog -Title 'Missing Configuration File' -Heading 'Configuration file not found' -Icon Error `
        -Message 'Ensure config.psd1 is in the config subfolder alongside this script.' -Detail $_configFile
    exit 1
}

try {
    $_cfg = & ([scriptblock]::Create([System.IO.File]::ReadAllText($_configFile)))
} catch {
    Show-DashboardMessageDialog -Title 'Invalid Configuration File' -Heading 'config.psd1 could not be parsed' -Icon Error `
        -Message 'Check the file for syntax errors.' -Detail "$_"
    exit 1
}

# FSLogix / Profile Tools
$StorageAccountShareMap = [ordered]@{}
$_cfg.ProfileTools.StorageAccountShareMap.GetEnumerator() | ForEach-Object {
    $StorageAccountShareMap[$_.Key] = $_.Value
}
$ExcludeStorage = @($_cfg.ProfileTools.ExcludeStorage | Where-Object { $_ })

$StorageAccountPairs = [ordered]@{}
if ($_cfg.ProfileTools.StorageAccountPairs) {
    $_cfg.ProfileTools.StorageAccountPairs.GetEnumerator() | ForEach-Object {
        $StorageAccountPairs[$_.Key] = @($_.Value)
    }
}

# Audit logging - enabled by default unless explicitly set to $false in config
$script:EnableAuditLog = if ($null -ne $_cfg.Dashboard.EnableAuditLog) { [bool]$_cfg.Dashboard.EnableAuditLog } else { $true }

# =============================================================================
# MSAL.NET DLL check. Authentication uses bundled MSAL.NET (no Az.Accounts).
# Both DLLs are required: Microsoft.Identity.Client depends on
# Microsoft.IdentityModel.Abstractions at runtime.
# =============================================================================

$_reqDlls = @(
    "$PSScriptRoot\lib\Microsoft.Identity.Client.dll",
    "$PSScriptRoot\lib\Microsoft.IdentityModel.Abstractions.dll"
)
$_missingDlls = $_reqDlls | Where-Object { -not (Test-Path $_) }
if ($_missingDlls) {
    Show-DashboardMessageDialog -Title 'Missing MSAL Library' -Heading 'Required sign-in library files not found' -Icon Error `
        -Message 'See misc\az-accounts-reference.md for download instructions.' -Detail ($_missingDlls -join "`n")
    exit 1
}

# =============================================================================
# Dot-source REST API helpers (provides Invoke-ArmRestMethod, Get-ArmToken)
# =============================================================================

. (Join-Path $PSScriptRoot 'scripts\rest-api-helpers.ps1')
. (Join-Path $PSScriptRoot 'scripts\audit-log.ps1')
. (Join-Path $PSScriptRoot 'scripts\connect-azure.ps1')

# Set the audit log directory to the project root (logs/ subfolder sits here)
$script:AuditLogDir = $PSScriptRoot

# Initialise REST API logging when -EnableLogging is specified
if ($EnableLogging) {
    $script:LogFile = Join-Path $env:TEMP "profile-tools-$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
    Write-Host "REST API logging enabled: $($script:LogFile)" -ForegroundColor Cyan
    Write-Log "Profile Tools v$ScriptVersion | PS $($PSVersionTable.PSVersion)"
}

# -- Update check (before auth). Skipped when launched as a companion process from the
#    dashboard ($_ptLaunchedFromDashboard) since the dashboard already ran its own check.
#    update-check.ps1 itself is dot-sourced near the top of the script. --------------------
Invoke-DashboardUpdateCheck `
    -RepoRoot        $PSScriptRoot `
    -CurrentVersion  $ScriptVersion `
    -ScriptPath      $script:_ptScriptPath `
    -BoundParameters $script:_ptBoundParams `
    -SkipUpdateCheck:($SkipUpdateCheck -or $_ptLaunchedFromDashboard) `
    -LogCallback     { param($m) if ($script:LogFile) { Write-Log $m } }

# =============================================================================
# Azure authentication
# =============================================================================

$_cfgBase = [System.IO.Path]::GetFileNameWithoutExtension($_configFile)
$_authTenantId = if ($_cfg.Azure.TenantId)      { [string]$_cfg.Azure.TenantId }      else { '' }
$_authSubId    = if ($_cfg.Azure.SubscriptionId) { [string]$_cfg.Azure.SubscriptionId } else { '' }
$azContext = Connect-AzureDashboard `
    -TenantId        $_authTenantId `
    -SubscriptionId  $_authSubId `
    -UseDeviceAuthentication:$UseDeviceAuthentication `
    -UseExistingContext:$UseExistingContext `
    -UseServicePrincipal:$UseServicePrincipal `
    -CredentialTag   $_cfgBase `
    -LogCallback     { param($m); if ($script:LogFile) { Write-Log $m } else { Write-Host $m } }

# Auth complete - show splash now (same pattern as live dashboard: auth first, then UI)
$splashWin.Show()
$splashWin.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
Set-SplashStatus "Connecting to Azure..." -Progress 25

# =============================================================================
# Azure context + storage OAuth setup
# =============================================================================
# Storage authentication uses OAuth bearer tokens via Entra ID instead of
# storage account keys. This requires the signed-in identity to have the
# "Storage File Data Privileged Contributor" RBAC role on each storage account.
# Tokens are acquired fresh at each operation (not cached at startup) to avoid
# expiry issues. No storage account keys are retrieved or stored.
# =============================================================================

$script:AzSubId = $azContext.Subscription.Id

# Set the user identity for audit logging.
# Profile Tools uses Windows credentials (not always an Azure identity),
# so fall back to the Windows username if the Azure account ID is empty.
$script:azAccountId = if ($azContext.Account.Id) { $azContext.Account.Id } else { "$env:USERDOMAIN\$env:USERNAME" }

# Audit: record profile tools launch
Write-AuditLog -Action 'ProfileToolsLaunch' -Target $azContext.Subscription.Name -Details "Subscription: $($azContext.Subscription.Id)"

# Validate that we can acquire a storage token (catches auth issues early)
try {
    Set-SplashStatus "Validating storage access token..." -Progress 40
    $testTok = Get-ArmToken -ResourceUrl 'https://storage.azure.com/'
    if (-not $testTok) { throw "Token was empty" }
} catch {
    Write-Log "ERROR [ProfileTools] Storage OAuth token validation failed: $_"
    Show-DashboardMessageDialog -Title 'Storage Token Error' -Heading 'Could not access storage' -Icon Error `
        -Message "Ensure you are signed in and have the 'Storage File Data Privileged Contributor' role on the storage accounts." -Detail "$_"
    exit 1
}

if ($script:LogFile) {
    Write-Log "Sub: $($script:AzSubId) | Storage OAuth token validated (bearer auth)"
}

# Load storage-api-helpers.ps1 as a string - passed to background runspaces
# so they can dot-source the storage REST functions without needing Az.Storage.
$script:storageHelperCode = Get-Content (Join-Path $PSScriptRoot 'scripts\storage-api-helpers.ps1') -Raw

Set-SplashStatus "Building UI..." -Progress 85

# =============================================================================
# XAML Window
# =============================================================================

$_ptXamlRaw = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Profile Tools"
    Height="680" Width="860"
    MinHeight="500" MinWidth="640"
    WindowStartupLocation="CenterScreen"
    Background="{DynamicResource Avd.Window.Bg}"
    Foreground="{DynamicResource Avd.Window.Fg}"
    FontFamily="Segoe UI"
    UseLayoutRounding="True">

    <Window.Resources>

        <!-- Primary button -->
        <Style x:Key="PrimaryBtn" TargetType="Button">
            <Setter Property="Background"      Value="#0078D4"/>
            <Setter Property="Foreground"      Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="18,8"/>
            <Setter Property="FontSize"        Value="13"/>
            <Setter Property="FontWeight"      Value="SemiBold"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="5"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#005A9E"/>
                            </Trigger>
                            <Trigger Property="IsPressed"   Value="True">
                                <Setter Property="Background" Value="#003D6B"/>
                            </Trigger>
                            <Trigger Property="IsEnabled"   Value="False">
                                <Setter Property="Background" Value="#AAC8E8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Danger button -->
        <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource PrimaryBtn}">
            <Setter Property="Background" Value="{DynamicResource Avd.Btn.Danger.Bg}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{DynamicResource Avd.Btn.Danger.Hover}"/>
                </Trigger>
                <Trigger Property="IsPressed"   Value="True">
                    <Setter Property="Background" Value="{DynamicResource Avd.Btn.Danger.Press}"/>
                </Trigger>
                <Trigger Property="IsEnabled"   Value="False">
                    <Setter Property="Background" Value="{DynamicResource Avd.Btn.Danger.Disabled}"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Secondary / clear button -->
        <Style x:Key="SecondaryBtn" TargetType="Button" BasedOn="{StaticResource PrimaryBtn}">
            <Setter Property="Background" Value="#6B737C"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#4F565D"/>
                </Trigger>
                <Trigger Property="IsEnabled"   Value="False">
                    <Setter Property="Background" Value="#B0B5BA"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Card border -->
        <Style x:Key="CardBorder" TargetType="Border">
            <Setter Property="Background"   Value="{DynamicResource Avd.Card.Bg}"/>
            <Setter Property="CornerRadius" Value="8"/>
            <Setter Property="Padding"      Value="20,16"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect BlurRadius="10" ShadowDepth="1" Opacity="0.12" Color="#000000"/>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Text input style -->
        <Style x:Key="InputBox" TargetType="TextBox">
            <Setter Property="FontSize"         Value="13"/>
            <Setter Property="Padding"          Value="10,8"/>
            <Setter Property="BorderBrush"      Value="{DynamicResource Avd.Border.Input2}"/>
            <Setter Property="BorderThickness"  Value="1"/>
            <Setter Property="Background"       Value="{DynamicResource Avd.Input.Bg}"/>
            <Setter Property="Foreground"       Value="{DynamicResource Avd.Window.Fg}"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Style.Triggers>
                <Trigger Property="IsFocused" Value="True">
                    <Setter Property="BorderBrush" Value="#0078D4"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Phase header label -->
        <Style x:Key="PhaseLabel" TargetType="TextBlock">
            <Setter Property="FontSize"   Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="#0078D4"/>
            <Setter Property="Margin"     Value="0,6,0,2"/>
        </Style>

        <!-- Status bar button - darker blue sits on the #0078D4 bar -->
        <Style x:Key="RefreshBtn" TargetType="Button">
            <Setter Property="Background"      Value="#005A9E"/>
            <Setter Property="Foreground"      Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"         Value="14,5"/>
            <Setter Property="FontSize"        Value="12"/>
            <Setter Property="FontWeight"      Value="SemiBold"/>
            <Setter Property="Cursor"          Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#004F8C"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#003D6B"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- THEME_SLOT -->
        <Style TargetType="TextBox">
            <Setter Property="Foreground" Value="{DynamicResource Avd.Window.Fg}"/>
        </Style>
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

    </Window.Resources>

    <DockPanel>

        <!-- == Status Bar == -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.StatusBar.Bg}" Height="32">
            <Grid Margin="12,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusBar"
                           Grid.Column="0"
                           Foreground="White" FontSize="12"
                           VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="SwitchConfigBtn"
                            Content="Switch Config"
                            Style="{StaticResource RefreshBtn}"
                            Visibility="Collapsed"
                            Margin="0,0,8,0"/>
                    <Button x:Name="SettingsBtn"
                            Content="Settings"
                            Style="{StaticResource RefreshBtn}"
                            Margin="0,0,8,0"/>
                    <Button x:Name="AboutBtn"
                            Content="About"
                            Style="{StaticResource RefreshBtn}"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- == Header == -->
        <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.Header.Bg}" Padding="20,14,20,14">
            <Border.Effect>
                <DropShadowEffect BlurRadius="6" ShadowDepth="1" Opacity="0.10" Color="#000000"/>
            </Border.Effect>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="" FontSize="22" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <StackPanel>
                        <TextBlock Text="Profile Tools"
                                   FontSize="20" FontWeight="Bold" Foreground="#0078D4"/>
                        <TextBlock x:Name="SubText"
                                   FontSize="12" Foreground="{DynamicResource Avd.Fg.Muted}"/>
                    </StackPanel>
                </StackPanel>
                <StackPanel x:Name="DarkTogglePanel" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Visibility="Collapsed">
                    <TextBlock Text="Dark" Foreground="{DynamicResource Avd.Fg.Muted}" FontSize="12"
                               VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <ToggleButton x:Name="DarkToggle" Style="{StaticResource ToggleSwitch}"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- == Tab Control == -->
        <TabControl Background="Transparent" BorderThickness="0" Margin="16,14,16,14">

            <TabControl.Resources>
                <Style TargetType="TabItem">
                    <Setter Property="FontSize"   Value="13"/>
                    <Setter Property="FontWeight" Value="SemiBold"/>
                    <Setter Property="Padding"    Value="16,8"/>
                    <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Secondary}"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="TabItem">
                                <Border x:Name="TabBorder"
                                        Background="Transparent"
                                        BorderThickness="0,0,0,3"
                                        BorderBrush="Transparent"
                                        Padding="{TemplateBinding Padding}"
                                        Margin="0,0,4,0"
                                        Cursor="Hand">
                                    <ContentPresenter ContentSource="Header"
                                                      HorizontalAlignment="Center"
                                                      VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsSelected" Value="True">
                                        <Setter TargetName="TabBorder" Property="BorderBrush" Value="#0078D4"/>
                                        <Setter Property="Foreground" Value="#0078D4"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="TabBorder" Property="Background" Value="{DynamicResource Avd.TabHover.Bg}"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Style>
            </TabControl.Resources>

            <!-- ===============================================================
                 TAB: Delete FSLogix Profile
                 =============================================================== -->
            <TabItem Header="  Delete FSLogix Profile">
                <Grid Margin="0,10,0,0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>  <!-- input card -->
                        <RowDefinition Height="12"/>    <!-- spacer -->
                        <RowDefinition Height="*"/>     <!-- output card -->
                    </Grid.RowDefinitions>

                    <!-- Input card -->
                    <Border Grid.Row="0" Style="{StaticResource CardBorder}">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="10"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="14"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Grid.Row="0">
                                <TextBlock Text="FSLogix Profile Folder Name"
                                           FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource Avd.Window.Fg}"
                                           Margin="0,0,0,4"/>
                                <TextBlock Text="Enter the profile folder name exactly as it appears on the file share (e.g. JSmith_S-1-5-21-1234567890-...)."
                                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}" TextWrapping="Wrap"/>
                                <TextBlock Text="Connection: Azure Files REST API  (Entra ID OAuth token - no SMB or VPN required)"
                                           FontSize="10" FontStyle="Italic"
                                           Foreground="{DynamicResource Avd.Fg.Muted}"
                                           Margin="0,4,0,0"/>
                            </StackPanel>

                            <Grid Grid.Row="2">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="10"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="8"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBox x:Name="FolderInput"
                                         Grid.Column="0"
                                         Style="{StaticResource InputBox}"
                                         ToolTip="Enter the FSLogix profile folder name"/>
                                <Button  x:Name="RunDeleteBtn"
                                         Grid.Column="2"
                                         Content=">  Run Check &amp; Delete"
                                         Style="{StaticResource DangerBtn}"/>
                                <Button  x:Name="ClearLogBtn"
                                         Grid.Column="4"
                                         Content="Clear Log"
                                         Style="{StaticResource SecondaryBtn}"/>
                            </Grid>

                            <!-- Storage account checkboxes -->
                            <StackPanel Grid.Row="4" Orientation="Vertical">
                                <StackPanel x:Name="PairSelectPanel" Orientation="Horizontal" Margin="0,0,0,6" Visibility="Collapsed"/>
                                <TextBlock x:Name="StorageAccountsLabel"
                                           Text="Storage accounts to check:"
                                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}" Margin="0,8,0,4"/>
                                <StackPanel x:Name="StorageAccountPanel" Orientation="Horizontal"/>
                            </StackPanel>

                        </Grid>
                    </Border>

                    <!-- Output log card -->
                    <Border Grid.Row="2" Style="{StaticResource CardBorder}" Padding="0">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <!-- Log header bar -->
                            <Border Grid.Row="0" Background="#1E2A38" CornerRadius="8,8,0,0" Padding="14,8">
                                <TextBlock Text="Operation Log" Foreground="#A8C4DE"
                                           FontSize="11" FontWeight="SemiBold" FontFamily="Consolas"/>
                            </Border>
                            <ScrollViewer Grid.Row="1"
                                          x:Name="LogScroller"
                                          Background="#1E2A38"
                                          VerticalScrollBarVisibility="Auto"
                                          HorizontalScrollBarVisibility="Auto"
                                          Padding="14,10">
                                <ItemsControl x:Name="LogOutput" Background="Transparent">
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <TextBlock Text="{Binding Text}"
                                                       Foreground="{Binding Colour}"
                                                       FontFamily="Consolas"
                                                       FontSize="12"
                                                       TextWrapping="NoWrap"/>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </ScrollViewer>
                        </Grid>
                    </Border>

                </Grid>
            </TabItem>

            <!-- ===============================================================
                 TAB: Remove Profile Locks
                 =============================================================== -->
            <TabItem Header="  Remove Profile Locks">
                <Grid Margin="0,10,0,0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="12"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Input card -->
                    <Border Grid.Row="0" Style="{StaticResource CardBorder}">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="10"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="14"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Grid.Row="0">
                                <TextBlock Text="FSLogix Profile Folder Name"
                                           FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource Avd.Window.Fg}"
                                           Margin="0,0,0,4"/>
                                <TextBlock Text="Check for and remove FSLogix lock files and open file handles without deleting the profile folder. Use this to unlock a stuck profile."
                                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}" TextWrapping="Wrap"/>
                                <TextBlock Text="Connection: Azure Files REST API  (Entra ID OAuth token - no SMB or VPN required)"
                                           FontSize="10" FontStyle="Italic"
                                           Foreground="{DynamicResource Avd.Fg.Muted}"
                                           Margin="0,4,0,0"/>
                            </StackPanel>

                            <Grid Grid.Row="2">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="10"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="8"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBox x:Name="UnlockFolderInput"
                                         Grid.Column="0"
                                         Style="{StaticResource InputBox}"
                                         ToolTip="Enter the FSLogix profile folder name"/>
                                <Button  x:Name="RunUnlockBtn"
                                         Grid.Column="2"
                                         Content=">  Check &amp; Remove Locks"
                                         Style="{StaticResource PrimaryBtn}"/>
                                <Button  x:Name="ClearUnlockLogBtn"
                                         Grid.Column="4"
                                         Content="Clear Log"
                                         Style="{StaticResource SecondaryBtn}"/>
                            </Grid>

                            <StackPanel Grid.Row="4" Orientation="Vertical">
                                <StackPanel x:Name="UnlockPairSelectPanel" Orientation="Horizontal" Margin="0,0,0,6" Visibility="Collapsed"/>
                                <TextBlock Text="Storage accounts to check:"
                                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}" Margin="0,8,0,4"/>
                                <StackPanel x:Name="UnlockStorageAccountPanel" Orientation="Horizontal"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <!-- Output log card -->
                    <Border Grid.Row="2" Style="{StaticResource CardBorder}" Padding="0">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Border Grid.Row="0" Background="#1E2A38" CornerRadius="8,8,0,0" Padding="14,8">
                                <TextBlock Text="Operation Log" Foreground="#A8C4DE"
                                           FontSize="11" FontWeight="SemiBold" FontFamily="Consolas"/>
                            </Border>
                            <ScrollViewer Grid.Row="1"
                                          x:Name="UnlockLogScroller"
                                          Background="#1E2A38"
                                          VerticalScrollBarVisibility="Auto"
                                          HorizontalScrollBarVisibility="Auto"
                                          Padding="14,10">
                                <ItemsControl x:Name="UnlockLogOutput" Background="Transparent">
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <TextBlock Text="{Binding Text}"
                                                       Foreground="{Binding Colour}"
                                                       FontFamily="Consolas"
                                                       FontSize="12"
                                                       TextWrapping="NoWrap"/>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </ScrollViewer>
                        </Grid>
                    </Border>
                </Grid>
            </TabItem>

            <!-- ===============================================================
                 TAB: Storage Locations
                 =============================================================== -->
            <TabItem Header="  Storage Locations">
                <Grid Margin="0,10,0,0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>   <!-- intro card -->
                        <RowDefinition Height="12"/>     <!-- spacer -->
                        <RowDefinition Height="*"/>      <!-- location cards -->
                    </Grid.RowDefinitions>

                    <!-- Intro / description card -->
                    <Border Grid.Row="0" Style="{StaticResource CardBorder}">
                        <StackPanel>
                            <TextBlock Text="Azure File Share Locations"
                                       FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource Avd.Window.Fg}"
                                       Margin="0,0,0,4"/>
                            <TextBlock FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}" TextWrapping="Wrap">
                                Quick links to the FSLogix profile share locations for each configured storage account.
                                Click <Bold>Open in Explorer</Bold> to browse the share directly, or
                                <Bold>Copy Path</Bold> to copy the UNC path to your clipboard.
                                Ensure you are connected to the corporate network or VPN before opening.
                            </TextBlock>
                            <TextBlock Text="Connection: SMB / UNC path  (Windows credentials - corporate network or VPN required)"
                                       FontSize="10" FontStyle="Italic"
                                       Foreground="{DynamicResource Avd.Fg.Muted}"
                                       Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>

                    <!-- Dynamically populated location cards -->
                    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
                        <StackPanel x:Name="StorageLocationsPanel" Margin="0,0,0,8"/>
                    </ScrollViewer>

                </Grid>
            </TabItem>


            <!-- ===============================================================
                 TAB: Profile Sizes
                 =============================================================== -->
            <TabItem Header="  Profile Sizes">
                <Grid Margin="0,10,0,0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="12"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Control card -->
                    <Border Grid.Row="0" Style="{StaticResource CardBorder}">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="10"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="14"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Grid.Row="0">
                                <TextBlock Text="Profile Folder Sizes"
                                           FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource Avd.Window.Fg}"
                                           Margin="0,0,0,4"/>
                                <TextBlock Text="Select the storage accounts to scan then click Scan. Double-click any row to open that folder in Explorer."
                                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}" TextWrapping="Wrap"/>
                                <TextBlock Text="Connection: SMB / UNC path  (Windows credentials - corporate network or VPN required)"
                                           FontSize="10" FontStyle="Italic"
                                           Foreground="{DynamicResource Avd.Fg.Muted}"
                                           Margin="0,4,0,0"/>
                            </StackPanel>

                            <Grid Grid.Row="2">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="10"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <Button x:Name="ScanSizesBtn"
                                        Grid.Column="2"
                                        Content="  Scan Folder Sizes"
                                        Style="{StaticResource PrimaryBtn}"/>
                            </Grid>

                            <StackPanel Grid.Row="4" Orientation="Vertical">
                                <StackPanel x:Name="SizePairSelectPanel" Orientation="Horizontal" Margin="0,0,0,6" Visibility="Collapsed"/>
                                <TextBlock Text="Storage accounts to scan:"
                                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}" Margin="0,8,0,4"/>
                                <StackPanel x:Name="SizeStorageAccountPanel" Orientation="Horizontal"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <!-- Results card -->
                    <Border Grid.Row="2" Style="{StaticResource CardBorder}" Padding="0">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <!-- Dark column header bar -->
                            <Border Grid.Row="0" Background="#1E2A38" CornerRadius="8,8,0,0" Padding="14,10">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="160"/>
                                        <ColumnDefinition Width="130"/>
                                        <ColumnDefinition Width="70"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="Folder"
                                               Foreground="#A8C4DE" FontSize="11"
                                               FontWeight="SemiBold" FontFamily="Consolas"/>
                                    <TextBlock Grid.Column="1" Text="Storage Account"
                                               Foreground="#A8C4DE" FontSize="11"
                                               FontWeight="SemiBold" FontFamily="Consolas"/>
                                    <TextBlock Grid.Column="2" Text="Size"
                                               Foreground="#A8C4DE" FontSize="11"
                                               FontWeight="SemiBold" FontFamily="Consolas"
                                               HorizontalAlignment="Right"/>
                                    <TextBlock Grid.Column="3" Text="Files"
                                               Foreground="#A8C4DE" FontSize="11"
                                               FontWeight="SemiBold" FontFamily="Consolas"
                                               HorizontalAlignment="Right" Margin="0,0,6,0"/>
                                </Grid>
                            </Border>

                            <!-- DataGrid - no built-in headers, driven by the bar above -->
                            <DataGrid x:Name="ProfileSizeGrid"
                                      Grid.Row="1"
                                      AutoGenerateColumns="False"
                                      IsReadOnly="True"
                                      SelectionMode="Single"
                                      GridLinesVisibility="Horizontal"
                                      HorizontalGridLinesBrush="{DynamicResource Avd.Border.Grid}"
                                      Background="{DynamicResource Avd.Grid.Bg}"
                                      RowBackground="{DynamicResource Avd.Grid.Bg}"
                                      AlternatingRowBackground="{DynamicResource Avd.AltRow.Bg}"
                                      BorderThickness="0"
                                      CanUserReorderColumns="False"
                                      CanUserResizeRows="False"
                                      CanUserSortColumns="True"
                                      HeadersVisibility="None"
                                      VerticalScrollBarVisibility="Auto"
                                      FontFamily="Segoe UI"
                                      FontSize="12">
                                <!-- Cell style: colour lives here so WPF selection highlight is fully controlled -->
                                <DataGrid.CellStyle>
                                    <Style TargetType="DataGridCell">
                                        <Setter Property="BorderThickness"  Value="0"/>
                                        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
                                        <Setter Property="Background"       Value="Transparent"/>
                                        <Setter Property="Foreground"       Value="{DynamicResource Avd.Window.Fg}"/>
                                        <Style.Triggers>
                                            <Trigger Property="IsSelected" Value="True">
                                                <Setter Property="Background" Value="{DynamicResource Avd.Selected.Bg}"/>
                                                <Setter Property="Foreground" Value="{DynamicResource Avd.Window.Fg}"/>
                                                <Setter Property="BorderBrush" Value="Transparent"/>
                                            </Trigger>
                                        </Style.Triggers>
                                    </Style>
                                </DataGrid.CellStyle>
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Folder"
                                                        Binding="{Binding Folder}"
                                                        Width="*">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="Padding"           Value="14,0,0,0"/>
                                                <Setter Property="VerticalAlignment" Value="Center"/>
                                                <Setter Property="Foreground"        Value="{DynamicResource Avd.Window.Fg}"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                    <DataGridTextColumn Header="Storage Account"
                                                        Binding="{Binding StorageAccount}"
                                                        Width="160">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="VerticalAlignment" Value="Center"/>
                                                <Setter Property="Padding"           Value="0,0,10,0"/>
                                                <Setter Property="Foreground"        Value="{DynamicResource Avd.Fg.Muted}"/>
                                                <Setter Property="FontFamily"        Value="Consolas"/>
                                                <Setter Property="FontSize"          Value="11"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                    <DataGridTextColumn Header="Size"
                                                        Binding="{Binding SizeHuman}"
                                                        Width="130"
                                                        SortMemberPath="Bytes">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="HorizontalAlignment" Value="Right"/>
                                                <Setter Property="VerticalAlignment"   Value="Center"/>
                                                <Setter Property="Padding"             Value="0,0,10,0"/>
                                                <Setter Property="Foreground"          Value="#0078D4"/>
                                                <Setter Property="FontWeight"          Value="SemiBold"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                    <DataGridTextColumn Header="Files"
                                                        Binding="{Binding FileCount}"
                                                        Width="70">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="HorizontalAlignment" Value="Right"/>
                                                <Setter Property="VerticalAlignment"   Value="Center"/>
                                                <Setter Property="Padding"             Value="0,0,10,0"/>
                                                <Setter Property="Foreground"          Value="{DynamicResource Avd.Fg.Muted}"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                </DataGrid.Columns>
                                <DataGrid.RowStyle>
                                    <Style TargetType="DataGridRow">
                                        <Setter Property="Cursor"     Value="Hand"/>
                                        <Setter Property="Height"     Value="32"/>
                                        <Setter Property="Background" Value="Transparent"/>
                                        <Style.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter Property="Background" Value="#EBF5FB"/>
                                            </Trigger>
                                        </Style.Triggers>
                                    </Style>
                                </DataGrid.RowStyle>
                            </DataGrid>

                            <!-- Summary footer -->
                            <Border Grid.Row="2"
                                    Background="{DynamicResource Avd.NearWhite.Bg}"
                                    CornerRadius="0,0,8,8"
                                    BorderBrush="{DynamicResource Avd.Border.Std}"
                                    BorderThickness="0,1,0,0"
                                    Padding="14,10">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock x:Name="SizeSummaryText"
                                               Grid.Column="0"
                                               FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}"
                                               VerticalAlignment="Center"
                                               Text="No scan run yet.  Select storage accounts and click Scan."/>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal">
                                        <TextBlock x:Name="SizeScanTimeText"
                                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                                   VerticalAlignment="Center"
                                                   Margin="0,0,12,0"/>
                                        <Button x:Name="ExportSizesBtn"
                                                Content="  Export CSV"
                                                Style="{StaticResource RefreshBtn}"
                                                IsEnabled="False"/>
                                    </StackPanel>
                                </Grid>
                            </Border>

                        </Grid>
                    </Border>

                </Grid>
            </TabItem>

            <!-- ===============================================================
                 TAB: Profile Cleanup
                 =============================================================== -->
            <TabItem Header="  Profile Cleanup">
                <Grid Margin="0,10,0,0">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="12"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Control card -->
                    <Border Grid.Row="0" Style="{StaticResource CardBorder}">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="10"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="14"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Grid.Row="0">
                                <TextBlock Text="Stale Profile Detection"
                                           FontSize="13" FontWeight="SemiBold" Foreground="{DynamicResource Avd.Window.Fg}"
                                           Margin="0,0,0,4"/>
                                <TextBlock Text="Scans for profile folders with no file activity within the threshold. Review results carefully before removing any folders."
                                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}" TextWrapping="Wrap"/>
                                <TextBlock Text="Connection: SMB / UNC path  (Windows credentials - corporate network or VPN required)"
                                           FontSize="10" FontStyle="Italic"
                                           Foreground="{DynamicResource Avd.Fg.Muted}"
                                           Margin="0,4,0,0"/>
                            </StackPanel>

                            <Grid Grid.Row="2">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="8"/>
                                    <ColumnDefinition Width="64"/>
                                    <ColumnDefinition Width="8"/>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock Grid.Column="0"
                                           Text="Flag folders inactive for more than"
                                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Label}"
                                           VerticalAlignment="Center"/>
                                <TextBox x:Name="CleanupThresholdBox"
                                         Grid.Column="2"
                                         Style="{StaticResource InputBox}"
                                         Text="90"
                                         TextAlignment="Center"/>
                                <TextBlock Grid.Column="4" Text="days"
                                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Label}"
                                           VerticalAlignment="Center"/>
                                <Button x:Name="ScanCleanupBtn"
                                        Grid.Column="6"
                                        Content="  Scan for Stale Profiles"
                                        Style="{StaticResource PrimaryBtn}"/>
                            </Grid>

                            <StackPanel Grid.Row="4" Orientation="Vertical">
                                <StackPanel x:Name="CleanupPairSelectPanel" Orientation="Horizontal" Margin="0,0,0,6" Visibility="Collapsed"/>
                                <TextBlock Text="Storage accounts to scan:"
                                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}" Margin="0,8,0,4"/>
                                <StackPanel x:Name="CleanupStorageAccountPanel" Orientation="Horizontal"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <!-- Results card -->
                    <Border Grid.Row="2" Style="{StaticResource CardBorder}" Padding="0">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <!-- Filter bar -->
                            <Border Grid.Row="0" Background="{DynamicResource Avd.NearWhite.Bg}" CornerRadius="8,8,0,0"
                                    BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1" Padding="14,8">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="8"/>
                                        <ColumnDefinition Width="140"/>
                                        <ColumnDefinition Width="12"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="Filter:" FontSize="11"
                                               Foreground="{DynamicResource Avd.Fg.Muted}" VerticalAlignment="Center"/>
                                    <TextBox x:Name="CleanupFilterBox" Grid.Column="2"
                                             Style="{StaticResource InputBox}"
                                             Padding="8,4" FontSize="11" VerticalContentAlignment="Center"/>
                                    <Button x:Name="ExportCleanupBtn" Grid.Column="4"
                                            Content="  Export CSV"
                                            Style="{StaticResource RefreshBtn}"
                                            IsEnabled="False"/>
                                </Grid>
                            </Border>

                            <!-- Dark column header bar -->
                            <Border Grid.Row="1" Background="#1E2A38" Padding="14,10">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="160"/>
                                        <ColumnDefinition Width="130"/>
                                        <ColumnDefinition Width="110"/>
                                        <ColumnDefinition Width="70"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock x:Name="CleanupHdrFolder"
                                               Grid.Column="0" Text="Folder"
                                               Foreground="#A8C4DE" FontSize="11"
                                               FontWeight="SemiBold" FontFamily="Consolas"
                                               Cursor="Hand" ToolTip="Click to sort"/>
                                    <TextBlock x:Name="CleanupHdrStorage"
                                               Grid.Column="1" Text="Storage Account"
                                               Foreground="#A8C4DE" FontSize="11"
                                               FontWeight="SemiBold" FontFamily="Consolas"
                                               Cursor="Hand" ToolTip="Click to sort"/>
                                    <TextBlock x:Name="CleanupHdrLastMod"
                                               Grid.Column="2" Text="Last Modified"
                                               Foreground="#A8C4DE" FontSize="11"
                                               FontWeight="SemiBold" FontFamily="Consolas"
                                               Cursor="Hand" ToolTip="Click to sort"/>
                                    <TextBlock x:Name="CleanupHdrDays"
                                               Grid.Column="3" Text="Days Inactive"
                                               Foreground="#A8C4DE" FontSize="11"
                                               FontWeight="SemiBold" FontFamily="Consolas"
                                               HorizontalAlignment="Right"
                                               Cursor="Hand" ToolTip="Click to sort"/>
                                    <TextBlock x:Name="CleanupHdrFiles"
                                               Grid.Column="4" Text="Files"
                                               Foreground="#A8C4DE" FontSize="11"
                                               FontWeight="SemiBold" FontFamily="Consolas"
                                               HorizontalAlignment="Right" Margin="0,0,6,0"
                                               Cursor="Hand" ToolTip="Click to sort"/>
                                </Grid>
                            </Border>

                            <!-- DataGrid - no built-in headers, driven by the bar above -->
                            <DataGrid x:Name="ProfileCleanupGrid"
                                      Grid.Row="2"
                                      AutoGenerateColumns="False"
                                      IsReadOnly="True"
                                      SelectionMode="Extended"
                                      GridLinesVisibility="Horizontal"
                                      HorizontalGridLinesBrush="{DynamicResource Avd.Border.Grid}"
                                      Background="{DynamicResource Avd.Grid.Bg}"
                                      RowBackground="{DynamicResource Avd.Grid.Bg}"
                                      AlternatingRowBackground="{DynamicResource Avd.AltRow.Bg}"
                                      BorderThickness="0"
                                      CanUserReorderColumns="False"
                                      CanUserResizeRows="False"
                                      CanUserSortColumns="False"
                                      HeadersVisibility="None"
                                      VerticalScrollBarVisibility="Auto"
                                      VirtualizingPanel.IsVirtualizing="True"
                                      VirtualizingPanel.VirtualizationMode="Recycling"
                                      FontFamily="Segoe UI"
                                      FontSize="12">
                                <DataGrid.CellStyle>
                                    <Style TargetType="DataGridCell">
                                        <Setter Property="BorderThickness"  Value="0"/>
                                        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
                                        <Setter Property="Background"       Value="Transparent"/>
                                        <Setter Property="Foreground"       Value="{DynamicResource Avd.Window.Fg}"/>
                                        <Style.Triggers>
                                            <Trigger Property="IsSelected" Value="True">
                                                <Setter Property="Background" Value="#FDE8E8"/>
                                                <Setter Property="Foreground" Value="{DynamicResource Avd.Window.Fg}"/>
                                                <Setter Property="BorderBrush" Value="Transparent"/>
                                            </Trigger>
                                        </Style.Triggers>
                                    </Style>
                                </DataGrid.CellStyle>
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Folder"
                                                        Binding="{Binding Folder}"
                                                        Width="*">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="Padding"           Value="14,0,0,0"/>
                                                <Setter Property="VerticalAlignment" Value="Center"/>
                                                <Setter Property="Foreground"        Value="{DynamicResource Avd.Window.Fg}"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                    <DataGridTextColumn Header="Storage Account"
                                                        Binding="{Binding StorageAccount}"
                                                        Width="160">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="VerticalAlignment" Value="Center"/>
                                                <Setter Property="Padding"           Value="0,0,10,0"/>
                                                <Setter Property="Foreground"        Value="{DynamicResource Avd.Fg.Muted}"/>
                                                <Setter Property="FontFamily"        Value="Consolas"/>
                                                <Setter Property="FontSize"          Value="11"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                    <DataGridTextColumn Header="Last Modified"
                                                        Binding="{Binding LastModified, StringFormat='{}{0:dd-MMM-yyyy}'}"
                                                        Width="130">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="VerticalAlignment" Value="Center"/>
                                                <Setter Property="Padding"           Value="0,0,10,0"/>
                                                <Setter Property="Foreground"        Value="{DynamicResource Avd.Fg.Muted}"/>
                                                <Setter Property="FontFamily"        Value="Consolas"/>
                                                <Setter Property="FontSize"          Value="11"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                    <DataGridTextColumn Header="Days Inactive"
                                                        Binding="{Binding DaysSince}"
                                                        Width="110"
                                                        SortMemberPath="DaysSince">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="HorizontalAlignment" Value="Right"/>
                                                <Setter Property="VerticalAlignment"   Value="Center"/>
                                                <Setter Property="Padding"             Value="0,0,10,0"/>
                                                <Setter Property="Foreground"          Value="#D83B01"/>
                                                <Setter Property="FontWeight"          Value="SemiBold"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                    <DataGridTextColumn Header="Files"
                                                        Binding="{Binding FileCount}"
                                                        Width="70">
                                        <DataGridTextColumn.ElementStyle>
                                            <Style TargetType="TextBlock">
                                                <Setter Property="HorizontalAlignment" Value="Right"/>
                                                <Setter Property="VerticalAlignment"   Value="Center"/>
                                                <Setter Property="Padding"             Value="0,0,10,0"/>
                                                <Setter Property="Foreground"          Value="{DynamicResource Avd.Fg.Muted}"/>
                                            </Style>
                                        </DataGridTextColumn.ElementStyle>
                                    </DataGridTextColumn>
                                </DataGrid.Columns>
                                <DataGrid.RowStyle>
                                    <Style TargetType="DataGridRow">
                                        <Setter Property="Cursor"     Value="Hand"/>
                                        <Setter Property="Height"     Value="32"/>
                                        <Setter Property="Background" Value="Transparent"/>
                                        <Style.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter Property="Background" Value="#FEF2F2"/>
                                            </Trigger>
                                        </Style.Triggers>
                                    </Style>
                                </DataGrid.RowStyle>
                            </DataGrid>

                            <!-- Summary footer with Delete button -->
                            <Border Grid.Row="3"
                                    Background="{DynamicResource Avd.NearWhite.Bg}"
                                    CornerRadius="0,0,8,8"
                                    BorderBrush="{DynamicResource Avd.Border.Std}"
                                    BorderThickness="0,1,0,0"
                                    Padding="14,10">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock x:Name="CleanupSummaryText"
                                               Grid.Column="0"
                                               FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}"
                                               VerticalAlignment="Center"
                                               TextTrimming="CharacterEllipsis"
                                               Text="No scan run yet.  Select storage accounts and click Scan."/>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal">
                                        <Button x:Name="DeleteCleanupBtn"
                                                Content="  Delete Selected"
                                                Style="{StaticResource DangerBtn}"
                                                IsEnabled="False"
                                                Margin="0,0,8,0"/>
                                        <Button x:Name="DeleteAllCleanupBtn"
                                                Content="  Delete All"
                                                Style="{StaticResource DangerBtn}"
                                                IsEnabled="False"/>
                                    </StackPanel>
                                </Grid>
                            </Border>

                        </Grid>
                    </Border>

                </Grid>
            </TabItem>

        </TabControl>

    </DockPanel>
</Window>
'@

# =============================================================================
# Parse XAML and wire up controls
# =============================================================================

# Inject initial theme
$_ptThemeFile = if ($script:_ptDark) { 'dark' } else { 'light' }
$_ptThemeContent = Get-Content -Raw -Path (Join-Path $PSScriptRoot "data\$_ptThemeFile-theme.xaml") -ErrorAction Stop
$_ptXamlParsed = $_ptXamlRaw -replace '<!-- THEME_SLOT -->', $_ptThemeContent
[xml]$xaml = $_ptXamlParsed

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$SubText              = $window.FindName("SubText")
$StatusBar            = $window.FindName("StatusBar")
$FolderInput          = $window.FindName("FolderInput")
$RunDeleteBtn         = $window.FindName("RunDeleteBtn")
$ClearLogBtn          = $window.FindName("ClearLogBtn")
$LogOutput            = $window.FindName("LogOutput")
$LogScroller          = $window.FindName("LogScroller")
$StorageAccountPanel  = $window.FindName("StorageAccountPanel")
$PairSelectPanel      = $window.FindName("PairSelectPanel")
$UnlockFolderInput          = $window.FindName("UnlockFolderInput")
$RunUnlockBtn               = $window.FindName("RunUnlockBtn")
$ClearUnlockLogBtn          = $window.FindName("ClearUnlockLogBtn")
$UnlockLogOutput            = $window.FindName("UnlockLogOutput")
$UnlockLogScroller          = $window.FindName("UnlockLogScroller")
$UnlockPairSelectPanel      = $window.FindName("UnlockPairSelectPanel")
$UnlockStorageAccountPanel  = $window.FindName("UnlockStorageAccountPanel")
$StorageLocationsPanel      = $window.FindName("StorageLocationsPanel")
$SizePairSelectPanel        = $window.FindName("SizePairSelectPanel")
$SizeStorageAccountPanel    = $window.FindName("SizeStorageAccountPanel")
$ScanSizesBtn               = $window.FindName("ScanSizesBtn")
$ProfileSizeGrid            = $window.FindName("ProfileSizeGrid")
$SizeSummaryText            = $window.FindName("SizeSummaryText")
$SizeScanTimeText           = $window.FindName("SizeScanTimeText")
$ExportSizesBtn             = $window.FindName("ExportSizesBtn")
$CleanupPairSelectPanel     = $window.FindName("CleanupPairSelectPanel")
$CleanupStorageAccountPanel = $window.FindName("CleanupStorageAccountPanel")
$CleanupThresholdBox        = $window.FindName("CleanupThresholdBox")
$CleanupFilterBox           = $window.FindName("CleanupFilterBox")
$CleanupHdrFolder           = $window.FindName("CleanupHdrFolder")
$CleanupHdrStorage          = $window.FindName("CleanupHdrStorage")
$CleanupHdrLastMod          = $window.FindName("CleanupHdrLastMod")
$CleanupHdrDays             = $window.FindName("CleanupHdrDays")
$CleanupHdrFiles            = $window.FindName("CleanupHdrFiles")
$ScanCleanupBtn             = $window.FindName("ScanCleanupBtn")
$ProfileCleanupGrid         = $window.FindName("ProfileCleanupGrid")
$CleanupSummaryText         = $window.FindName("CleanupSummaryText")
$ExportCleanupBtn           = $window.FindName("ExportCleanupBtn")
$DeleteCleanupBtn           = $window.FindName("DeleteCleanupBtn")
$DeleteAllCleanupBtn        = $window.FindName("DeleteAllCleanupBtn")
$SettingsBtn                = $window.FindName("SettingsBtn")
$AboutBtn                   = $window.FindName("AboutBtn")
$SwitchConfigBtn            = $window.FindName("SwitchConfigBtn")

# =============================================================================
# Theme support
# =============================================================================

function Switch-ProfileTheme {
    param([bool]$Dark)
    $script:_ptDark = $Dark
    $_tf = if ($Dark) { 'dark' } else { 'light' }
    $_tc = Get-Content -Raw -Path (Join-Path $PSScriptRoot "data\$_tf-theme.xaml") -ErrorAction Stop
    $_rdXaml = "<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$_tc</ResourceDictionary>"
    $_rd = [Windows.Markup.XamlReader]::Parse($_rdXaml)
    foreach ($_key in @($_rd.Keys)) { $window.Resources[$_key] = $_rd[$_key] }
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $v = [int]$Dark
        [void][Win32.DwmApiPT]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
    } catch {}
}

# =============================================================================
# Registry Settings
# =============================================================================

$script:RegPath = 'HKCU:\Software\AVDDashboard'

function Read-ProfileToolsSettings {
    $defaults = @{ CleanupThresholdDays = $CLEANUP_THRESHOLD_DEFAULT }
    try {
        if (-not (Test-Path $script:RegPath)) { return $defaults }
        $k = Get-ItemProperty -Path $script:RegPath -ErrorAction Stop
        @{ CleanupThresholdDays = if ($k.CleanupThresholdDays) { [int]$k.CleanupThresholdDays } else { $CLEANUP_THRESHOLD_DEFAULT } }
    } catch { $defaults }
}

function Write-ProfileToolsSettings {
    param([int]$CleanupThresholdDays)
    if (-not (Test-Path $script:RegPath)) { New-Item -Path $script:RegPath -Force | Out-Null }
    Set-ItemProperty -Path $script:RegPath -Name 'CleanupThresholdDays' -Value $CleanupThresholdDays
}

$savedSettings = Read-ProfileToolsSettings
$CleanupThresholdBox.Text = $savedSettings.CleanupThresholdDays

# Subscription context info in header
$SubText.Text = "Connected as: $($azContext.Account.Id)   |   Subscription: $($azContext.Subscription.Name)"
$StatusBar.Text = "Ready."

# =============================================================================
# Shared UI helpers
# =============================================================================

# Populates a dedicated pair-selector row (PairSelectPanel) above the account checkboxes.
# Each pair gets a plain checkbox that when ticked selects only that pair's accounts.
# Does NOT move or duplicate the account checkboxes.
# Builds one coloured box per pair, each containing a radio button + the pair's account checkboxes.
# Selecting a radio ticks only that pair's accounts and unticks all others.
# All radios share a GroupName per panel so WPF enforces mutual exclusivity automatically.
# Call this AFTER New-StorageCheckboxes so $AccountMap is populated.
function Add-PairCheckboxes {
    param(
        [System.Windows.Controls.StackPanel]$PairPanel,
        [System.Windows.Controls.StackPanel]$AccountPanel,
        [hashtable]$AccountMap
    )
    if ($StorageAccountPairs.Count -eq 0) { return }

    # Collect all paired accounts and remove them from the flat panel
    $pairedSet = @{}
    foreach ($pairName in $StorageAccountPairs.Keys) {
        foreach ($acct in $StorageAccountPairs[$pairName]) { $pairedSet[$acct] = $true }
    }
    $toRemove = @($AccountPanel.Children | Where-Object {
        $_ -is [System.Windows.Controls.CheckBox] -and $pairedSet.ContainsKey([string]$_.Content)
    })
    foreach ($r in $toRemove) { [void]$AccountPanel.Children.Remove($r) }

    # Unique group name per panel so tabs don't interfere with each other
    $groupName   = "PairGroup_$($PairPanel.Name)"
    $capturedMap = $AccountMap

    foreach ($pairName in $StorageAccountPairs.Keys) {
        $capturedAccounts = @($StorageAccountPairs[$pairName])

        # Coloured box
        $box                 = New-Object System.Windows.Controls.Border
        if ($script:_ptDark) {
            $box.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Avd.Input.Bg')
            $box.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty,  'Avd.Border.Std')
        } else {
            $box.Background  = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0xEE, 0xF4, 0xFC)
            $box.BorderBrush = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0xB8, 0xD0, 0xEB)
        }
        $box.BorderThickness = [System.Windows.Thickness]::new(1)
        $box.CornerRadius    = [System.Windows.CornerRadius]::new(4)
        $box.Padding         = [System.Windows.Thickness]::new(6, 2, 6, 2)
        $box.Margin          = [System.Windows.Thickness]::new(0, 0, 8, 0)

        $row             = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $row.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        # Radio button (no label - mutual exclusion handled by GroupName)
        $rb               = New-Object System.Windows.Controls.RadioButton
        $rb.GroupName     = $groupName
        $rb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $rb.Margin        = [System.Windows.Thickness]::new(0, 0, 8, 0)

        $rb.Add_Checked({
            foreach ($key in $capturedMap.Keys) { $capturedMap[$key].IsChecked = $false }
            foreach ($key in $capturedAccounts) {
                if ($capturedMap.ContainsKey($key)) { $capturedMap[$key].IsChecked = $true }
            }
        }.GetNewClosure())

        [void]$row.Children.Add($rb)

        # Account checkboxes inside the box
        foreach ($acct in $capturedAccounts) {
            if ($AccountMap.ContainsKey($acct)) {
                $AccountMap[$acct].FontSize          = 11
                if ($script:_ptDark) {
                    $AccountMap[$acct].SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Avd.Fg.Label')
                } else {
                    $AccountMap[$acct].Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0x1E, 0x40, 0x6E)
                }
                $AccountMap[$acct].VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $AccountMap[$acct].Margin            = [System.Windows.Thickness]::new(0, 0, 10, 0)
                [void]$row.Children.Add($AccountMap[$acct])
            }
        }

        $box.Child = $row
        [void]$PairPanel.Children.Add($box)
    }

    $PairPanel.Visibility = [System.Windows.Visibility]::Visible
}

# Builds storage account checkboxes into a StackPanel and returns a name->CheckBox map.
function New-StorageCheckboxes {
    param(
        [System.Windows.Controls.StackPanel]$Panel,
        [bool]$DefaultChecked = $false
    )
    $map = @{}
    foreach ($saName in $StorageAccountShareMap.Keys) {
        if ($ExcludeStorage -contains $saName) { continue }
        $cb            = New-Object System.Windows.Controls.CheckBox
        $cb.Content    = $saName
        $cb.IsChecked  = $DefaultChecked
        $cb.FontSize   = 12
        $cb.Foreground = [System.Windows.Media.Brushes]::DimGray
        $cb.Margin     = [System.Windows.Thickness]::new(0, 0, 16, 0)
        $Panel.Children.Add($cb) | Out-Null
        $map[$saName] = $cb
    }
    return $map
}

# Returns the names of all checked accounts from a name->CheckBox map.
function Get-CheckedAccounts {
    param([hashtable]$Checkboxes)
    return @($Checkboxes.GetEnumerator() | Where-Object { $_.Value.IsChecked } | ForEach-Object { $_.Key })
}

# Shared scriptblock used by both Delete Selected and Delete All on the Cleanup tab.
# Runs via Start-Job; receives plain PSCustomObjects so serialisation is safe.
# Uses a RunspacePool (max 6 concurrent) so multiple folders delete in parallel.
$script:cleanupDeleteScript = {
    param($Items, $MaxRunspaces)

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxRunspaces)
    $pool.Open()

    $jobs = foreach ($item in $Items) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript({
            param($FullPath, $Folder)
            try {
                if (Test-Path -LiteralPath $FullPath) {
                    Remove-Item -LiteralPath $FullPath -Recurse -Force -ErrorAction Stop
                    [PSCustomObject]@{ FullPath = $FullPath; Folder = $Folder; Success = $true;  Error = "" }
                } else {
                    [PSCustomObject]@{ FullPath = $FullPath; Folder = $Folder; Success = $true;  Error = "Not found" }
                }
            } catch {
                [PSCustomObject]@{ FullPath = $FullPath; Folder = $Folder; Success = $false; Error = $_.ToString() }
            }
        })
        [void]$ps.AddArgument($item.FullPath)
        [void]$ps.AddArgument($item.Folder)
        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    $results = foreach ($job in $jobs) {
        try   { $job.PS.EndInvoke($job.Handle) }
        catch { [PSCustomObject]@{ FullPath = ""; Folder = ""; Success = $false; Error = $_.ToString() } }
        $job.PS.Dispose()
    }

    $pool.Close()
    $pool.Dispose()
    return $results
}

# Populate storage account checkboxes dynamically from config
$script:StorageCheckboxes = New-StorageCheckboxes -Panel $StorageAccountPanel -DefaultChecked $true
Add-PairCheckboxes -PairPanel $PairSelectPanel -AccountPanel $StorageAccountPanel -AccountMap $script:StorageCheckboxes
$script:UnlockStorageCheckboxes = New-StorageCheckboxes -Panel $UnlockStorageAccountPanel -DefaultChecked $true
Add-PairCheckboxes -PairPanel $UnlockPairSelectPanel -AccountPanel $UnlockStorageAccountPanel -AccountMap $script:UnlockStorageCheckboxes

# =============================================================================
# Storage Locations tab - dynamically build a card per storage account
# =============================================================================

# Region labels loaded from config.psd1 - extend the RegionLabels key there as needed
$regionLabels = if ($_cfg.ProfileTools.RegionLabels) { $_cfg.ProfileTools.RegionLabels } else { @{} }

function Get-RegionLabel {
    param([string]$AccountName)
    foreach ($key in $regionLabels.Keys) {
        if ($AccountName -match $key) { return $regionLabels[$key] }
    }
    return "Azure"
}

foreach ($saName in $StorageAccountShareMap.Keys) {

    if ($ExcludeStorage -contains $saName) { continue }

    $uncPath    = $StorageAccountShareMap[$saName]
    $regionTag  = Get-RegionLabel -AccountName $saName
    $accent     = "#0078D4"

    # -- Outer card border ----------------------------------------------------
    $cardBorder = New-Object System.Windows.Controls.Border
    $cardBorder.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Avd.Card.Bg')
    $cardBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $cardBorder.Margin       = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $cardBorder.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect
    $cardBorder.Effect.BlurRadius  = 10
    $cardBorder.Effect.ShadowDepth = 1
    $cardBorder.Effect.Opacity     = 0.12
    $cardBorder.Effect.Color       = [System.Windows.Media.Colors]::Black

    # -- Inner grid: accent stripe | content ---------------------------------
    $innerGrid = New-Object System.Windows.Controls.Grid
    $col0 = New-Object System.Windows.Controls.ColumnDefinition
    $col0.Width = [System.Windows.GridLength]::new(6)
    $col1 = New-Object System.Windows.Controls.ColumnDefinition
    $col1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $innerGrid.ColumnDefinitions.Add($col0)
    $innerGrid.ColumnDefinitions.Add($col1)

    # Coloured left accent stripe
    $stripe = New-Object System.Windows.Controls.Border
    $stripe.Background   = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($accent))
    $stripe.CornerRadius = [System.Windows.CornerRadius]::new(8, 0, 0, 8)
    [System.Windows.Controls.Grid]::SetColumn($stripe, 0)
    $innerGrid.Children.Add($stripe) | Out-Null

    # Content panel
    $contentStack = New-Object System.Windows.Controls.StackPanel
    $contentStack.Margin = [System.Windows.Thickness]::new(18, 14, 18, 14)
    [System.Windows.Controls.Grid]::SetColumn($contentStack, 1)

    # -- Row 1: icon + account name + region badge ----------------------------
    $titleRow = New-Object System.Windows.Controls.StackPanel
    $titleRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $titleRow.Margin      = [System.Windows.Thickness]::new(0, 0, 0, 6)

    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.Text       = ""
    $icon.FontSize   = 20
    $icon.Margin     = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $icon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $nameBlock = New-Object System.Windows.Controls.TextBlock
    $nameBlock.Text       = $saName
    $nameBlock.FontSize   = 14
    $nameBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
    $nameBlock.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Avd.Window.Fg')
    $nameBlock.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    # Region badge
    $badge = New-Object System.Windows.Controls.Border
    $badge.Background    = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($accent))
    $badge.CornerRadius  = [System.Windows.CornerRadius]::new(10)
    $badge.Padding       = [System.Windows.Thickness]::new(8, 2, 8, 2)
    $badge.Margin        = [System.Windows.Thickness]::new(10, 0, 0, 0)
    $badge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $badgeText = New-Object System.Windows.Controls.TextBlock
    $badgeText.Text       = $regionTag
    $badgeText.Foreground = [System.Windows.Media.Brushes]::White
    $badgeText.FontSize   = 10
    $badgeText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $badge.Child = $badgeText

    $titleRow.Children.Add($icon)     | Out-Null
    $titleRow.Children.Add($nameBlock)| Out-Null
    $titleRow.Children.Add($badge)    | Out-Null

    # -- Row 2: UNC path display ----------------------------------------------
    $pathBorder = New-Object System.Windows.Controls.Border
    $pathBorder.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Avd.Input.Bg')
    $pathBorder.CornerRadius = [System.Windows.CornerRadius]::new(5)
    $pathBorder.Padding      = [System.Windows.Thickness]::new(10, 7, 10, 7)
    $pathBorder.Margin       = [System.Windows.Thickness]::new(0, 0, 0, 10)

    $pathText = New-Object System.Windows.Controls.TextBlock
    $pathText.Text       = $uncPath
    $pathText.FontFamily = [System.Windows.Media.FontFamily]::new("Consolas")
    $pathText.FontSize   = 12
    $pathText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Avd.Fg.Label')
    $pathText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $pathBorder.Child = $pathText

    # -- Row 3: action buttons ------------------------------------------------
    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal

    # Helper to build a styled button without referencing XAML resources
    function New-ActionButton {
        param([string]$Label, [string]$BgColour, [string]$HoverColour)
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content     = $Label
        $btn.FontSize    = 12
        $btn.FontWeight  = [System.Windows.FontWeights]::SemiBold
        $btn.Foreground  = [System.Windows.Media.Brushes]::White
        $btn.BorderThickness = [System.Windows.Thickness]::new(0)
        $btn.Cursor      = [System.Windows.Input.Cursors]::Hand
        $btn.Padding     = [System.Windows.Thickness]::new(14, 7, 14, 7)
        $btn.Margin      = [System.Windows.Thickness]::new(0, 0, 8, 0)
        $btn.Background  = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($BgColour))

        # Rounded corners via ControlTemplate
        [xml]$btnXaml = "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
                             xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
                             TargetType='Button'>
            <Border Background=`"{TemplateBinding Background}`" CornerRadius='5'
                    Padding=`"{TemplateBinding Padding}`">
                <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
            </Border>
            <ControlTemplate.Triggers>
                <Trigger Property='IsMouseOver' Value='True'>
                    <Setter Property='Background' Value='$HoverColour'/>
                </Trigger>
                <Trigger Property='IsPressed' Value='True'>
                    <Setter Property='Opacity' Value='0.85'/>
                </Trigger>
            </ControlTemplate.Triggers>
        </ControlTemplate>"
        $btn.Template = [System.Windows.Markup.XamlReader]::Load(
            (New-Object System.Xml.XmlNodeReader $btnXaml))
        return $btn
    }

    $openBtn = New-ActionButton -Label "  Open in Explorer" -BgColour $accent -HoverColour "#003D6B"
    $copyBtn = New-ActionButton -Label "  Copy Path"        -BgColour "#6B737C" -HoverColour "#4F565D"

    # Wire up Open button - capture $uncPath in closure
    $openBtnPath = $uncPath
    $openBtn.Add_Click({
        try {
            Start-Process explorer.exe -ArgumentList $openBtnPath
            $StatusBar.Text = "Opened: $openBtnPath"
        } catch {
            Write-Log "ERROR [ProfileTools] Open Explorer failed for '$openBtnPath': $_"
            Show-ThemedDialog -Title "Explorer Error" -Message "Could not open Explorer for:`n$openBtnPath`n`nError: $_" -Icon Error | Out-Null
        }
    }.GetNewClosure())

    # Wire up Copy button
    $copyBtnPath = $uncPath
    $copyBtn.Add_Click({
        try {
            [System.Windows.Clipboard]::SetText($copyBtnPath)
            $StatusBar.Text = "Copied to clipboard: $copyBtnPath"
        } catch {
            Show-ThemedDialog -Title "Clipboard Error" -Message "Could not copy to clipboard.`n`nError: $_" -Icon Error | Out-Null
        }
    }.GetNewClosure())

    $btnRow.Children.Add($openBtn) | Out-Null
    $btnRow.Children.Add($copyBtn) | Out-Null

    # -- Assemble card --------------------------------------------------------
    $contentStack.Children.Add($titleRow)   | Out-Null
    $contentStack.Children.Add($pathBorder) | Out-Null
    $contentStack.Children.Add($btnRow)     | Out-Null

    $innerGrid.Children.Add($contentStack) | Out-Null
    $cardBorder.Child = $innerGrid
    $StorageLocationsPanel.Children.Add($cardBorder) | Out-Null
}


# =============================================================================
# Profile Sizes tab - storage account checkboxes
# =============================================================================

$script:SizeStorageCheckboxes = New-StorageCheckboxes -Panel $SizeStorageAccountPanel
Add-PairCheckboxes -PairPanel $SizePairSelectPanel -AccountPanel $SizeStorageAccountPanel -AccountMap $script:SizeStorageCheckboxes

# =============================================================================
# Profile Sizes tab - DataGrid source
# =============================================================================

$script:sizeItems = New-Object System.Collections.ObjectModel.ObservableCollection[PSCustomObject]
$ProfileSizeGrid.ItemsSource = $script:sizeItems

# =============================================================================
# Profile Sizes tab - Scan button
# Calls profile-sizes.ps1 in a background runspace; renders results in the grid
# =============================================================================

$ScanSizesBtn.Add_Click({

    $selectedAccounts = Get-CheckedAccounts $script:SizeStorageCheckboxes

    if ($selectedAccounts.Count -eq 0) {
        Show-ThemedDialog -Title "No Storage Account Selected" -Message "Please select at least one storage account to scan." -Icon Warning | Out-Null
        return
    }

    # Resolve UNC paths and build a path->account name map to pass to profile-sizes.ps1
    $scanPaths  = @()
    $accountMap = @{}
    foreach ($saName in $selectedAccounts) {
        if ($StorageAccountShareMap.Contains($saName)) {
            $path = $StorageAccountShareMap[$saName]
            $scanPaths  += $path
            $accountMap[$path] = $saName
        }
    }

    $ScanSizesBtn.IsEnabled  = $false
    $ScanSizesBtn.Content    = "  Scanning..."
    $StatusBar.Text          = "Scanning profile folder sizes..."
    $SizeSummaryText.Text    = "Scanning - please wait..."
    $SizeScanTimeText.Text   = ""
    $script:sizeItems.Clear()

    # Use Start-Job so profile-sizes.ps1 runs in a full PowerShell process.
    # This inherits the user's Windows credentials (needed for SMB/UNC access)
    # and avoids the serialisation and policy issues of a bare runspace.
    $scanScriptPath = $script:profileSizeScript

    if (-not (Test-Path $scanScriptPath)) {
        Show-ThemedDialog -Title "Script Not Found" -Message "profile-sizes.ps1 not found:`n$scanScriptPath`n`nPlace it in the scripts subfolder alongside profile-tools.ps1." -Icon Error | Out-Null
        $ScanSizesBtn.IsEnabled = $true
        $ScanSizesBtn.Content   = "  Scan Folder Sizes"
        $StatusBar.Text         = "Ready."
        return
    }

    $sw          = [System.Diagnostics.Stopwatch]::StartNew()
    $capturedJob = Start-Job -FilePath $scanScriptPath -ArgumentList $scanPaths, $accountMap
    [void]$script:_ptActiveJobs.Add($capturedJob)

    # Capture all UI references as locals so GetNewClosure() can bind them correctly.
    # $script: scope does not resolve reliably inside a DispatcherTimer closure.
    $localSizeItems       = $script:sizeItems
    $localScanBtn         = $ScanSizesBtn
    $localSummaryText     = $SizeSummaryText
    $localScanTimeText    = $SizeScanTimeText
    $localStatusBar       = $StatusBar
    $localAccountCount    = $selectedAccounts.Count
    $localExportBtn       = $ExportSizesBtn

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $timer.Add_Tick({
        if ($capturedJob.State -notin 'Running','NotStarted') {
            $timer.Stop()

            $sw.Stop()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

            $results = Receive-Job -Job $capturedJob -ErrorAction SilentlyContinue
            Remove-Job -Job $capturedJob -Force
            [void]$script:_ptActiveJobs.Remove($capturedJob)

            if (-not $results -or @($results).Count -eq 0) {
                $localSummaryText.Text   = "No folders found. Verify the storage account paths are accessible."
                $localScanTimeText.Text  = "Completed in ${elapsed}s"
                $localScanBtn.IsEnabled  = $true
                $localScanBtn.Content    = "  Scan Folder Sizes"
                $localExportBtn.IsEnabled = $false
                $localStatusBar.Text     = "Scan complete - no results."
                return
            }

            $resultList  = @($results)
            $totalBytes  = ($resultList | Measure-Object -Property Bytes     -Sum).Sum
            $totalFiles  = ($resultList | Measure-Object -Property FileCount -Sum).Sum
            $folderCount = $resultList.Count

            $totalHuman = switch ($totalBytes) {
                { $_ -ge 1TB } { '{0:N2} TB' -f ($_ / 1TB); break }
                { $_ -ge 1GB } { '{0:N2} GB' -f ($_ / 1GB); break }
                { $_ -ge 1MB } { '{0:N2} MB' -f ($_ / 1MB); break }
                default        { '{0:N2} KB' -f ($_ / 1KB) }
            }

            $localSizeItems.Clear()
            foreach ($r in $resultList) { $localSizeItems.Add($r) }
            $avgHuman = ""
            if ($localAccountCount -eq 1 -and $folderCount -gt 0) {
                $avgBytes = [long]($totalBytes / $folderCount)
                $avgHuman = switch ($avgBytes) {
                    { $_ -ge 1TB } { '   |   Avg profile size: {0:N2} TB' -f ($avgBytes / 1TB); break }
                    { $_ -ge 1GB } { '   |   Avg profile size: {0:N2} GB' -f ($avgBytes / 1GB); break }
                    { $_ -ge 1MB } { '   |   Avg profile size: {0:N2} MB' -f ($avgBytes / 1MB); break }
                    default        { '   |   Avg profile size: {0:N2} KB' -f ($avgBytes / 1KB) }
                }
            }
            $localSummaryText.Text    = "$folderCount folders   |   Total: $totalHuman   |   Files: $($totalFiles.ToString('N0'))$avgHuman"
            $localScanTimeText.Text   = "Scanned in ${elapsed}s"
            $localScanBtn.IsEnabled   = $true
            $localScanBtn.Content     = "  Scan Folder Sizes"
            $localExportBtn.IsEnabled = $true
            $localStatusBar.Text      = "Scan complete.  $folderCount folders found."
        }
    }.GetNewClosure())
    $timer.Start()
})

# =============================================================================
# Profile Sizes tab - double-click row opens folder in Explorer
# =============================================================================

$ProfileSizeGrid.Add_MouseDoubleClick({
    $row = $ProfileSizeGrid.SelectedItem
    if ($row -and $row.FullPath) {
        try {
            Start-Process explorer.exe -ArgumentList $row.FullPath
            $StatusBar.Text = "Opened: $($row.FullPath)"
        } catch {
            Write-Log "ERROR [ProfileTools] Open Explorer failed for '$($row.FullPath)': $_"
            Show-ThemedDialog -Title "Explorer Error" -Message "Could not open Explorer:`n$($row.FullPath)`n`nError: $_" -Icon Error | Out-Null
        }
    }
})

# =============================================================================
# Profile Sizes tab - Export CSV
# =============================================================================

$ExportSizesBtn.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter   = "CSV files (*.csv)|*.csv"
    $dlg.FileName = "ProfileSizes_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    if ($dlg.ShowDialog() -eq $true) {
        $script:sizeItems |
            Select-Object Folder, StorageAccount, SizeHuman, Bytes, FileCount, FullPath |
            Export-Csv -Path $dlg.FileName -NoTypeInformation -Force
        $StatusBar.Text = "Exported $(($script:sizeItems).Count) rows to $($dlg.FileName)"
    }
})

# =============================================================================
# Profile Cleanup tab - storage account checkboxes
# =============================================================================

$script:CleanupStorageCheckboxes = New-StorageCheckboxes -Panel $CleanupStorageAccountPanel -DefaultChecked $true
Add-PairCheckboxes -PairPanel $CleanupPairSelectPanel -AccountPanel $CleanupStorageAccountPanel -AccountMap $script:CleanupStorageCheckboxes

# =============================================================================
# Profile Cleanup tab - DataGrid source
# =============================================================================

$script:cleanupItems      = New-Object System.Collections.ObjectModel.ObservableCollection[PSCustomObject]
$script:allCleanupResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:cleanupSortCol    = 'DaysSince'
$script:cleanupSortDesc   = $true
$ProfileCleanupGrid.ItemsSource = $script:cleanupItems

# Applies current sort + filter from $script:allCleanupResults into $script:cleanupItems
function Update-CleanupGrid {
    $text   = $CleanupFilterBox.Text.Trim()
    $source = if ([string]::IsNullOrEmpty($text)) {
        @($script:allCleanupResults)
    } else {
        @($script:allCleanupResults | Where-Object { $_.Folder -like "*$text*" })
    }

    $sorted = switch ($script:cleanupSortCol) {
        'Folder' {
            if ($script:cleanupSortDesc) { @($source | Sort-Object Folder -Descending) }
            else                         { @($source | Sort-Object Folder) }
        }
        'StorageAccount' {
            if ($script:cleanupSortDesc) { @($source | Sort-Object StorageAccount -Descending) }
            else                         { @($source | Sort-Object StorageAccount) }
        }
        'LastModified' {
            if ($script:cleanupSortDesc) { @($source | Sort-Object LastModified -Descending) }
            else                         { @($source | Sort-Object LastModified) }
        }
        'FileCount' {
            if ($script:cleanupSortDesc) { @($source | Sort-Object FileCount -Descending) }
            else                         { @($source | Sort-Object FileCount) }
        }
        default { # DaysSince - group by folder, sort groups by max days
            if ($script:cleanupSortDesc) {
                @($source | Group-Object Folder |
                    Sort-Object { ($_.Group | Measure-Object DaysSince -Maximum).Maximum } -Descending |
                    ForEach-Object { $_.Group | Sort-Object DaysSince -Descending })
            } else {
                @($source | Group-Object Folder |
                    Sort-Object { ($_.Group | Measure-Object DaysSince -Minimum).Minimum } |
                    ForEach-Object { $_.Group | Sort-Object DaysSince })
            }
        }
    }

    $script:cleanupItems.Clear()
    foreach ($r in $sorted) { $script:cleanupItems.Add($r) }
}

function Update-CleanupSortIndicators {
    $arrow = if ($script:cleanupSortDesc) { " $([char]0x25BC)" } else { " $([char]0x25B2)" }
    $CleanupHdrFolder.Text  = if ($script:cleanupSortCol -eq 'Folder')         { "Folder$arrow" }          else { 'Folder' }
    $CleanupHdrStorage.Text = if ($script:cleanupSortCol -eq 'StorageAccount') { "Storage Account$arrow" }  else { 'Storage Account' }
    $CleanupHdrLastMod.Text = if ($script:cleanupSortCol -eq 'LastModified')   { "Last Modified$arrow" }    else { 'Last Modified' }
    $CleanupHdrDays.Text    = if ($script:cleanupSortCol -eq 'DaysSince')      { "Days Inactive$arrow" }    else { 'Days Inactive' }
    $CleanupHdrFiles.Text   = if ($script:cleanupSortCol -eq 'FileCount')      { "Files$arrow" }            else { 'Files' }
}

function Set-CleanupSort {
    param([string]$Column)
    if ($script:cleanupSortCol -eq $Column) { $script:cleanupSortDesc = -not $script:cleanupSortDesc }
    else { $script:cleanupSortCol = $Column; $script:cleanupSortDesc = $true }
    Update-CleanupSortIndicators
    Update-CleanupGrid
}

# Enable Delete button only when rows are selected
$ProfileCleanupGrid.Add_SelectionChanged({
    $DeleteCleanupBtn.IsEnabled = ($ProfileCleanupGrid.SelectedItems.Count -gt 0)
})

# Set initial sort indicator (▼ on Days Inactive)
Update-CleanupSortIndicators

# Column header sort clicks
$CleanupHdrFolder.Add_MouseLeftButtonDown({  Set-CleanupSort 'Folder' })
$CleanupHdrStorage.Add_MouseLeftButtonDown({ Set-CleanupSort 'StorageAccount' })
$CleanupHdrLastMod.Add_MouseLeftButtonDown({ Set-CleanupSort 'LastModified' })
$CleanupHdrDays.Add_MouseLeftButtonDown({    Set-CleanupSort 'DaysSince' })
$CleanupHdrFiles.Add_MouseLeftButtonDown({   Set-CleanupSort 'FileCount' })

# Filter box - re-applies grid on every keystroke
$CleanupFilterBox.Add_TextChanged({ Update-CleanupGrid })

# Export CSV
$ExportCleanupBtn.Add_Click({
    if ($script:cleanupItems.Count -eq 0) { return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter   = "CSV Files (*.csv)|*.csv"
    $dlg.FileName = "stale-profiles-$(Get-Date -Format 'yyyy-MM-dd')"
    if ($dlg.ShowDialog()) {
        try {
            $script:cleanupItems |
                Select-Object Folder, StorageAccount, LastModified, DaysSince, FileCount, FullPath |
                Export-Csv -Path $dlg.FileName -NoTypeInformation -Force
            $StatusBar.Text = "Exported $($script:cleanupItems.Count) row(s) to: $($dlg.FileName)"
        } catch {
            Write-Log "ERROR [ProfileTools] CSV export failed to '$($dlg.FileName)': $_"
            Show-ThemedDialog -Title "Export Error" -Message "Export failed:`n$_" -Icon Error | Out-Null
        }
    }
})

# =============================================================================
# Profile Cleanup tab - Scan button
# Launches one Start-Job per storage account in parallel; results stream into
# the grid as each account completes so the UI updates incrementally.
# =============================================================================

$ScanCleanupBtn.Add_Click({

    $selectedAccounts = Get-CheckedAccounts $script:CleanupStorageCheckboxes

    if ($selectedAccounts.Count -eq 0) {
        Show-ThemedDialog -Title "No Storage Account Selected" -Message "Please select at least one storage account to scan." -Icon Warning | Out-Null
        return
    }

    $threshold = 0
    if (-not [int]::TryParse($CleanupThresholdBox.Text.Trim(), [ref]$threshold) -or $threshold -lt $CLEANUP_THRESHOLD_MIN -or $threshold -gt $CLEANUP_THRESHOLD_MAX) {
        Show-ThemedDialog -Title "Invalid Threshold" -Message "Please enter a valid number of days between $CLEANUP_THRESHOLD_MIN and $CLEANUP_THRESHOLD_MAX." -Icon Warning | Out-Null
        return
    }

    $cleanupScriptPath = $script:profileCleanupScript
    if (-not (Test-Path $cleanupScriptPath)) {
        Show-ThemedDialog -Title "Script Not Found" -Message "profile-cleanup.ps1 not found:`n$cleanupScriptPath`n`nPlace it in the scripts subfolder alongside profile-tools.ps1." -Icon Error | Out-Null
        return
    }

    $ScanCleanupBtn.IsEnabled      = $false
    $ScanCleanupBtn.Content        = "  Scanning..."
    $DeleteCleanupBtn.IsEnabled    = $false
    $DeleteAllCleanupBtn.IsEnabled = $false
    $ExportCleanupBtn.IsEnabled    = $false
    $CleanupSummaryText.Text       = "Scanning - please wait..."
    $script:cleanupItems.Clear()
    $script:allCleanupResults.Clear()

    # One job per storage account - all run concurrently
    $sw       = [System.Diagnostics.Stopwatch]::StartNew()
    $scanJobs = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($saName in $selectedAccounts) {
        if (-not $StorageAccountShareMap.Contains($saName)) { continue }
        $path = $StorageAccountShareMap[$saName]
        $am   = @{ $path = $saName }
        $job  = Start-Job -FilePath $cleanupScriptPath -ArgumentList @(,$path), $am, $threshold
        $scanJobs.Add([PSCustomObject]@{ Job = $job; Done = $false; Name = $saName })
        [void]$script:_ptActiveJobs.Add($job)
    }

    $totalJobs         = $scanJobs.Count
    $localScanBtn      = $ScanCleanupBtn
    $localDeleteAllBtn = $DeleteAllCleanupBtn
    $localExportBtn    = $ExportCleanupBtn
    $localSummaryText  = $CleanupSummaryText
    $localStatusBar    = $StatusBar
    $localAllResults   = $script:allCleanupResults
    $localThreshold    = $threshold
    $localUpdateGrid   = ${function:Update-CleanupGrid}

    $localStatusBar.Text = "Scanning $totalJobs storage account(s) in parallel (threshold: $threshold days)..."

    $scanTimer = New-Object System.Windows.Threading.DispatcherTimer
    $scanTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $scanTimer.Add_Tick({
        $doneCount = 0
        foreach ($entry in $scanJobs) {
            if ($entry.Done) { $doneCount++; continue }
            if ($entry.Job.State -notin 'Running','NotStarted') {
                $entry.Done = $true
                $doneCount++
                $results = Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue
                Remove-Job -Job $entry.Job -Force
                [void]$script:_ptActiveJobs.Remove($entry.Job)
                if ($results) {
                    foreach ($r in $results) { $localAllResults.Add($r) }
                    & $localUpdateGrid
                }
                $localStatusBar.Text = "Scanning... ($doneCount of $totalJobs account(s) complete - $($localAllResults.Count) stale folder(s) found so far)"
            }
        }

        if ($doneCount -ge $totalJobs) {
            $scanTimer.Stop()
            $sw.Stop()
            $elapsed     = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            $folderCount = $localAllResults.Count

            if ($folderCount -eq 0) {
                $localSummaryText.Text       = "No stale folders found with a threshold of $localThreshold days."
                $localDeleteAllBtn.IsEnabled = $false
                $localExportBtn.IsEnabled    = $false
            } else {
                $localSummaryText.Text       = "$folderCount stale folder(s) found (inactive > $localThreshold days)   |   Select rows and click Delete Selected, or Delete All."
                $localDeleteAllBtn.IsEnabled = $true
                $localExportBtn.IsEnabled    = $true
            }
            $localScanBtn.IsEnabled = $true
            $localScanBtn.Content   = "  Scan for Stale Profiles"
            $localStatusBar.Text    = "Scan complete.  $folderCount stale folder(s) found across $totalJobs account(s).  Scanned in ${elapsed}s"
        }
    }.GetNewClosure())
    $scanTimer.Start()
})

# =============================================================================
# Profile Cleanup tab - shared delete logic
# Groups items by storage account and runs one parallel Start-Job per account.
# Each job uses a RunspacePool internally for concurrent folder deletion.
# Results stream back per-account so the grid updates incrementally.
# =============================================================================

function Invoke-CleanupDelete {
    param(
        [PSCustomObject[]] $ItemsToDelete,
        [string]           $ActionLabel
    )

    $totalCount = $ItemsToDelete.Count
    if ($totalCount -eq 0) { return }

    # Build confirmation list (cap at $CLEANUP_CONFIRM_CAP lines to keep dialog manageable)
    $cap     = [Math]::Min($totalCount, $CLEANUP_CONFIRM_CAP)
    $lines   = ($ItemsToDelete | Select-Object -First $cap |
                    ForEach-Object { "  $([char]0x2022) $($_.Folder)  [$($_.StorageAccount)]" }) -join "`n"
    if ($totalCount -gt $CLEANUP_CONFIRM_CAP) { $lines += "`n  ... and $($totalCount - $CLEANUP_CONFIRM_CAP) more" }

    $prefix  = if ($totalCount -gt $CLEANUP_BATCH_WARN) { "WARNING: You are deleting a large number of folders!`n`n" } else { "" }
    $confirm = Show-ThemedDialog -Message "${prefix}You are about to PERMANENTLY DELETE $totalCount profile folder(s):`n`n$lines`n`nThis action cannot be undone.`nAre you absolutely sure?" -Title "Confirm $ActionLabel" -Buttons YesNo -Icon Warning
    if (-not $confirm) { return }

    # Audit log - record the cleanup deletion
    foreach ($item in $ItemsToDelete) {
        Write-AuditLog -Action 'CleanupDelete' -Target $item.FullPath -Details "Folder: $($item.Folder)"
    }

    $DeleteCleanupBtn.IsEnabled    = $false
    $DeleteAllCleanupBtn.IsEnabled = $false
    $ScanCleanupBtn.IsEnabled      = $false
    $ExportCleanupBtn.IsEnabled    = $false
    $StatusBar.Text                = "Deleting $totalCount folder(s) in parallel (max $CLEANUP_RUNSPACE_MAX concurrent per account)..."

    # One job per storage account for per-account progress reporting
    $deleteJobs = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($group in ($ItemsToDelete | Group-Object StorageAccount)) {
        $batchData = @($group.Group | ForEach-Object { [PSCustomObject]@{ Folder = $_.Folder; FullPath = $_.FullPath } })
        $job = Start-Job -ScriptBlock $script:cleanupDeleteScript -ArgumentList (, $batchData), $CLEANUP_RUNSPACE_MAX
        $deleteJobs.Add([PSCustomObject]@{ Job = $job; Done = $false; AccountName = $group.Name })
        [void]$script:_ptActiveJobs.Add($job)
    }

    $totalJobs         = $deleteJobs.Count
    $localDeleteBtn    = $DeleteCleanupBtn
    $localDeleteAllBtn = $DeleteAllCleanupBtn
    $localScanBtn      = $ScanCleanupBtn
    $localExportBtn    = $ExportCleanupBtn
    $localSummaryText  = $CleanupSummaryText
    $localStatusBar    = $StatusBar
    $localAllResults   = $script:allCleanupResults
    $localUpdateGrid   = ${function:Update-CleanupGrid}
    $deleteState       = [PSCustomObject]@{
        Succeeded  = 0
        FailedList = [System.Collections.Generic.List[string]]::new()
    }

    $delTimer = New-Object System.Windows.Threading.DispatcherTimer
    $delTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $delTimer.Add_Tick({
        $doneCount = 0
        foreach ($entry in $deleteJobs) {
            if ($entry.Done) { $doneCount++; continue }
            if ($entry.Job.State -notin 'Running','NotStarted') {
                $entry.Done = $true
                $doneCount++
                $delResults = @(Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue)
                Remove-Job -Job $entry.Job -Force
                [void]$script:_ptActiveJobs.Remove($entry.Job)

                foreach ($r in $delResults) {
                    if ($r.Success) {
                        $deleteState.Succeeded++
                        $match = $localAllResults | Where-Object { $_.FullPath -eq $r.FullPath } | Select-Object -First 1
                        if ($match) { [void]$localAllResults.Remove($match) }
                    } else {
                        $deleteState.FailedList.Add("$($r.Folder): $($r.Error)")
                    }
                }
                & $localUpdateGrid
                $localStatusBar.Text = "Deleting... ($doneCount of $totalJobs account(s) complete - $($deleteState.Succeeded) deleted)"
            }
        }

        if ($doneCount -ge $totalJobs) {
            $delTimer.Stop()

            if ($deleteState.FailedList.Count -gt 0) {
                $errList = ($deleteState.FailedList | ForEach-Object { "  $_" }) -join "`n"
                Show-ThemedDialog -Title "Deletion Complete" -Message "$($deleteState.Succeeded) folder(s) deleted successfully.`n$($deleteState.FailedList.Count) failed:`n`n$errList" -Icon Warning | Out-Null
            }

            $remaining = $localAllResults.Count
            $localSummaryText.Text       = if ($remaining -gt 0) {
                "$remaining stale folder(s) remaining.  $($deleteState.Succeeded) deleted."
            } else { "All stale folders removed." }
            $localDeleteBtn.IsEnabled    = $false
            $localDeleteAllBtn.IsEnabled = ($remaining -gt 0)
            $localExportBtn.IsEnabled    = ($remaining -gt 0)
            $localScanBtn.IsEnabled      = $true
            $localStatusBar.Text         = "$($deleteState.Succeeded) folder(s) deleted.  $($deleteState.FailedList.Count) failed."
        }
    }.GetNewClosure())
    $delTimer.Start()
}

# =============================================================================
# Profile Cleanup tab - Delete Selected button
# =============================================================================

$DeleteCleanupBtn.Add_Click({
    $selected = @($ProfileCleanupGrid.SelectedItems)
    Invoke-CleanupDelete -ItemsToDelete $selected -ActionLabel "Delete Selected"
})

# =============================================================================
# Profile Cleanup tab - Delete All button
# =============================================================================

$DeleteAllCleanupBtn.Add_Click({
    $allItems = @($script:cleanupItems)
    Invoke-CleanupDelete -ItemsToDelete $allItems -ActionLabel "Delete All"
})

# =============================================================================
# Profile Cleanup tab - double-click row opens folder in Explorer
# =============================================================================

$ProfileCleanupGrid.Add_MouseDoubleClick({
    $row = $ProfileCleanupGrid.SelectedItem
    if ($row -and $row.FullPath) {
        try {
            Start-Process explorer.exe -ArgumentList $row.FullPath
            $StatusBar.Text = "Opened: $($row.FullPath)"
        } catch {
            Show-ThemedDialog -Title "Explorer Error" -Message "Could not open Explorer:`n$($row.FullPath)`n`nError: $_" -Icon Error | Out-Null
        }
    }
})

# =============================================================================
# Settings dialog
# =============================================================================

function Show-CleanupSettings {
    $_sWinXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Profile Tools Settings"
    Height="280" Width="420"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterOwner"
    Background="{DynamicResource Avd.Window.Bg}"
    FontFamily="Segoe UI">
    <Window.Resources>
        <!-- THEME_SLOT -->
    </Window.Resources>
    <DockPanel Margin="24,20,24,20">

        <!-- Registry path info -->
        <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.Card.Bg}" CornerRadius="6"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1"
                Padding="12,9" Margin="0,0,0,16">
            <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets"
                           FontSize="13" Foreground="{DynamicResource Avd.Fg.Hint}"
                           VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock FontSize="11" Foreground="{DynamicResource Avd.Fg.Muted}" VerticalAlignment="Center">
                    <Run Text="Settings are saved to "/>
                    <Run Text="HKCU\Software\AVDDashboard"
                         FontFamily="Consolas" Foreground="#0078D4"/>
                </TextBlock>
            </StackPanel>
        </Border>

        <!-- Save / Cancel -->
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal"
                    HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="SettingsCancelBtn" Content="Cancel"
                    Width="90" Height="32" Margin="0,0,10,0"
                    Background="{DynamicResource Avd.Btn.Cancel.Bg}" Foreground="{DynamicResource Avd.Window.Fg}"
                    BorderThickness="0" FontSize="13" Cursor="Hand">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="8,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#CDD0D6"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button x:Name="SettingsSaveBtn" Content="Save"
                    Width="90" Height="32"
                    Background="#0078D4" Foreground="White"
                    BorderThickness="0" FontSize="13" FontWeight="SemiBold" Cursor="Hand">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="8,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#005A9E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>

        <!-- Settings content -->
        <StackPanel DockPanel.Dock="Top">

            <TextBlock Text="Profile Cleanup Settings" FontSize="18" FontWeight="Bold"
                       Foreground="#0078D4" Margin="0,0,0,20"/>

            <TextBlock Text="Stale Profile Threshold (days)" FontSize="13" FontWeight="SemiBold"
                       Foreground="{DynamicResource Avd.Window.Fg}" Margin="0,0,0,6"/>
            <TextBox x:Name="ThresholdBox"
                     Height="32" FontSize="13" Padding="8,4"
                     BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                     Background="{DynamicResource Avd.Input.Bg}" Foreground="{DynamicResource Avd.Window.Fg}"
                     VerticalContentAlignment="Center"/>
            <TextBlock Text="Profiles with no file activity for more than this many days are flagged as stale. Minimum 1, maximum 3650."
                       FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,0" TextWrapping="Wrap"/>

            <TextBlock x:Name="SettingsStatus" FontSize="11" Foreground="#C42B1C"
                       Margin="0,8,0,0" TextWrapping="Wrap"/>

        </StackPanel>

    </DockPanel>
</Window>
'@
    $_sXml = $_sWinXaml -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path (Join-Path $PSScriptRoot "data\$(if ($script:_ptDark) { 'dark' } else { 'light' })-theme.xaml") -ErrorAction Stop)
    [xml]$settingsXaml = $_sXml
    $sReader = New-Object System.Xml.XmlNodeReader $settingsXaml
    $sWin    = [System.Windows.Markup.XamlReader]::Load($sReader)
    $sWin.Owner = $window
    try {
        $sWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($sWin)).Handle
            $v = [int]$script:_ptDark
            [void][Win32.DwmApiPT]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    } catch {}

    $sThreshold = $sWin.FindName("ThresholdBox")
    $sStatus    = $sWin.FindName("SettingsStatus")
    $sSave      = $sWin.FindName("SettingsSaveBtn")
    $sCancel    = $sWin.FindName("SettingsCancelBtn")

    $sThreshold.Text = (Read-ProfileToolsSettings).CleanupThresholdDays

    $sCancel.Add_Click({ $sWin.Close() }.GetNewClosure())

    $sSave.Add_Click({
        $iv = 0
        if (-not [int]::TryParse($sThreshold.Text.Trim(), [ref]$iv) -or $iv -lt $CLEANUP_THRESHOLD_MIN -or $iv -gt $CLEANUP_THRESHOLD_MAX) {
            $sStatus.Text = "Threshold must be a whole number between $CLEANUP_THRESHOLD_MIN and $CLEANUP_THRESHOLD_MAX."
            return
        }
        try {
            Write-ProfileToolsSettings -CleanupThresholdDays $iv
        } catch {
            $sStatus.Text = "Failed to save to registry: $_"
            return
        }
        $CleanupThresholdBox.Text = $iv
        $sWin.Close()
    })

    $sWin.ShowDialog() | Out-Null
}

# Show Switch Config button only when multiple configs exist and not launched from the dashboard
# (when launched from the dashboard the config is controlled by the dashboard itself)
$_ptAllConfigs = Get-PtAvailableConfigs
if ($_ptAllConfigs.Count -gt 1 -and -not $_ptLaunchedFromDashboard) { $SwitchConfigBtn.Visibility = 'Visible' }

$SwitchConfigBtn.Add_Click({
    $_ptAllConfigs = Get-PtAvailableConfigs
    if ($_ptAllConfigs.Count -lt 2) { return }
    $_p = Show-PtConfigPicker -Configs $_ptAllConfigs -AllowCancel $true
    if (-not $_p) { return }   # cancelled

    $_rootReg = 'HKCU:\Software\AVDDashboard'

    if ($_p.ClearDefault) {
        # User clicked "Clear saved default" - remove the registry value so the picker
        # appears next time both the dashboard and profile-tools are launched
        try { Remove-ItemProperty -Path $_rootReg -Name 'DefaultConfig' -ErrorAction Stop } catch {}
        return   # stay on the current config, no restart needed
    }

    if (-not $_p.Config) { return }

    # Save or update the default if the user ticked "Remember this choice"
    if ($_p.SetDefault) {
        if (-not (Test-Path $_rootReg)) { try { New-Item -Path $_rootReg -Force | Out-Null } catch {} }
        try { Set-ItemProperty -Path $_rootReg -Name 'DefaultConfig' -Value $_p.Config.Slug } catch {}
    }

    # Restart with the new config, reusing the current Az context and theme
    $_theme  = [int]$script:_ptDark
    $_script = Join-Path $PSScriptRoot 'profile-tools.ps1'
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -File `"$_script`" -UseExistingContext -DashboardTheme $_theme -ConfigFile `"$($_p.Config.Path)`""
    $window.Close()
})

$SettingsBtn.Add_Click({ Show-CleanupSettings })

# =============================================================================
# About dialog
# =============================================================================

function Show-About {
    $_aRaw = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="About Profile Tools"
    SizeToContent="Height" Width="520"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterOwner"
    Background="{DynamicResource Avd.Window.Bg}"
    Foreground="{DynamicResource Avd.Window.Fg}"
    FontFamily="Segoe UI">
    <Window.Resources>
        <!-- THEME_SLOT -->
    </Window.Resources>
    <DockPanel Margin="28,24,28,20">

        <!-- Title + version -->
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <TextBlock Text="Profile Tools" FontSize="18" FontWeight="Bold" Foreground="#0078D4"/>
            <TextBlock x:Name="AboutVersion"   FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,4,0,0"/>
            <TextBlock x:Name="AboutPSVersion" FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,2,0,0"/>
            <TextBlock FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,2,0,0">GitHub: <Hyperlink x:Name="AboutGitHub" Foreground="#0078D4" TextDecorations="None">virtualwebber/AVD-Dashboard</Hyperlink></TextBlock>
        </StackPanel>

        <!-- Close / Check for updates buttons -->
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button x:Name="AboutUpdateBtn"
                Content="Check for Updates" Width="140" Height="32" Margin="0,0,8,0"
                Background="Transparent" Foreground="{DynamicResource Avd.Window.Fg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1"
                FontSize="13" Cursor="Hand"/>
        <Button x:Name="AboutCloseBtn"
                Content="Close" HorizontalAlignment="Right"
                Width="90" Height="32"
                Background="#0078D4" Foreground="White"
                BorderThickness="0" FontSize="13" FontWeight="SemiBold" Cursor="Hand">
            <Button.Template>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="8,0">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="Background" Value="#005A9E"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Button.Template>
        </Button>
        </StackPanel>

        <!-- Disclaimer -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.Card.Bg}" CornerRadius="6" Padding="14,12"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1" Margin="0,12,0,0">
            <StackPanel>
                <TextBlock Text="DISCLAIMER" FontSize="11" FontWeight="Bold" Foreground="#C42B1C" Margin="0,0,0,6"/>
                <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="{DynamicResource Avd.Fg.Secondary}" LineHeight="18">
                    This script is provided as-is with no warranty, guarantee, or support of any kind.
                    Use at your own risk. The author accepts no responsibility for any issues,
                    data loss, or damages arising from the use of this script in any environment.
                    Always test in a non-production environment before deploying.
                </TextBlock>
            </StackPanel>
        </Border>

    </DockPanel>
</Window>
'@
    $_aXml = $_aRaw -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path (Join-Path $PSScriptRoot "data\$(if ($script:_ptDark) { 'dark' } else { 'light' })-theme.xaml") -ErrorAction Stop)
    [xml]$aboutXaml = $_aXml
    $aReader = New-Object System.Xml.XmlNodeReader $aboutXaml
    $aWin    = [System.Windows.Markup.XamlReader]::Load($aReader)
    $aWin.Owner = $window
    Set-WindowIcon -Window $aWin -IconPath (Join-Path $PSScriptRoot 'data\avd-dashboard.ico')
    try {
        $aWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($aWin)).Handle
            $v = [int]$script:_ptDark
            [void][Win32.DwmApiPT]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    } catch {}
    $aWin.FindName("AboutVersion").Text   = "Version $ScriptVersion"
    $aWin.FindName("AboutPSVersion").Text = "PowerShell $($PSVersionTable.PSVersion)"
    $aWin.FindName("AboutCloseBtn").Add_Click({ $aWin.Close() })
    $aWin.FindName("AboutGitHub").Add_Click({ Start-Process "https://github.com/virtualwebber/AVD-Dashboard" })
    $aWin.FindName("AboutUpdateBtn").Add_Click({
        $_updBtn = $aWin.FindName("AboutUpdateBtn")
        $_updBtn.IsEnabled = $false
        $_updBtn.Content   = "Checking..."
        # Force the "Checking..." state to actually paint before the blocking network
        # call below - otherwise the click looks like it did nothing until it returns.
        $_updBtn.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        try {
            Invoke-DashboardUpdateCheck `
                -RepoRoot        $PSScriptRoot `
                -CurrentVersion  $ScriptVersion `
                -ScriptPath      $script:_ptScriptPath `
                -BoundParameters $script:_ptBoundParams `
                -Manual `
                -IconPath        (Join-Path $PSScriptRoot 'data\avd-dashboard.ico') `
                -OwnerWindow     $aWin `
                -LogCallback     { param($m) Write-Log $m }
        } finally {
            $_updBtn.IsEnabled = $true
            $_updBtn.Content   = "Check for Updates"
        }
    })

    $aWin.ShowDialog() | Out-Null
}

$AboutBtn.Add_Click({ Show-About })

# =============================================================================
# Log helper - creates coloured line entries in the ItemsControl
# =============================================================================

$script:logItems = New-Object System.Collections.ObjectModel.ObservableCollection[PSCustomObject]
$LogOutput.ItemsSource = $script:logItems

function Write-Log {
    param(
        [string]$Message,
        [string]$Colour = "#D1D5DB"   # default: light grey
    )
    $entry = [PSCustomObject]@{ Text = $Message; Colour = $Colour }
    $window.Dispatcher.Invoke([Action]{
        $script:logItems.Add($entry)
        $LogScroller.ScrollToEnd()
    })
}

function Write-LogSeparator {
    param([string]$Title = "", [string]$Colour = "#3B8ED4")
    $line = if ($Title) { "  ===  $Title  ===" } else { "  " + ("=" * 64) }
    Write-Log $line $Colour
}

function Clear-Log {
    $window.Dispatcher.Invoke([Action]{ $script:logItems.Clear() })
}

# =============================================================================
# Core deletion logic - loaded from scripts subfolder as scriptblocks
# and executed in background runspaces via Start-BgJob.
# Storage REST helper functions + account keys are passed as parameters.
# =============================================================================

foreach ($s in @($script:profileDeleteScript, $script:profileDeleteLocksScript, $script:profileDeleteRemoveScript)) {
    if (-not (Test-Path $s)) {
        Show-ThemedDialog -Title "Script Not Found" -Message "Required script not found:`n$s`n`nPlace it in the scripts subfolder alongside profile-tools.ps1." -Icon Error | Out-Null
        exit 1
    }
}

$deleteScript      = [scriptblock]::Create((Get-Content $script:profileDeleteScript       -Raw))
$lockCleanupScript = [scriptblock]::Create((Get-Content $script:profileDeleteLocksScript  -Raw))
$removeScript      = [scriptblock]::Create((Get-Content $script:profileDeleteRemoveScript -Raw))

# =============================================================================
# Find-ProfileFolders
# Searches the share paths for all folders whose names contain $SearchName.
# Returns an array of PSCustomObjects: StorageAccount, FolderName, FolderPath.
# =============================================================================
function Find-ProfileFolders {
    param(
        [string]$SearchName,
        [string[]]$SelectedAccounts,
        [hashtable]$ShareMap,
        [string]$SubPath      = '',
        [string]$StorageToken = '',   # OAuth bearer token for Azure Files data plane
        [ref]$SearchErrors    = $null # collects per-account error strings for the caller to display
    )
    $results   = @()
    $errorList = [System.Collections.Generic.List[string]]::new()

    # Dot-source the storage REST helper so Invoke-StorageFileRest is available.
    # This is the same helper used by the background scripts and already handles:
    #   - x-ms-file-request-intent: backup  (required for OAuth calls to Azure Files)
    #   - x-ms-version and x-ms-date headers
    #   - Correct URI construction for Azure Files
    . ([scriptblock]::Create($script:storageHelperCode))

    foreach ($saName in $SelectedAccounts) {
        if (-not $ShareMap.ContainsKey($saName)) { continue }
        $uncPath = $ShareMap[$saName]

        # Parse account name, share name, and optional subpath from the UNC path:
        #   \\stfeavdgenprdsdc.file.core.windows.net\fslogix-general\profiles
        #   -> AccountName = 'stfeavdgenprdsdc'  ShareName = 'fslogix-general'  SubPath = 'profiles'
        $m = [regex]::Match($uncPath, '\\\\(?<acct>[^.\\]+)\.file\.core\.windows\.net\\(?<share>[^\\]+)(?:\\(?<sub>.+))?')
        if (-not $m.Success) {
            $errorList.Add("PARSE [$saName]: cannot extract account/share from '$uncPath'")
            continue
        }
        $acctName  = $m.Groups['acct'].Value   # e.g. stfeavdgenprdsdc
        $shareName = $m.Groups['share'].Value  # e.g. fslogix-general
        $acctSub   = $m.Groups['sub'].Value    # e.g. profiles (empty if profiles are at share root)

        # List the directory via Azure Files REST API.
        # No prefix filter in the request - list all entries and filter client-side.
        # The prefix query parameter was rejected with InvalidResourceName so we
        # avoid it entirely.
        $restOk = $false
        if ($StorageToken) {
            try {
                $marker = ''
                do {
                    $qp = @{ restype = 'directory'; comp = 'list' }
                    if ($marker) { $qp['marker'] = $marker }
                    $resp = Invoke-StorageFileRest `
                        -AccountName $acctName `
                        -BearerToken $StorageToken `
                        -Method 'GET' `
                        -ShareName $shareName `
                        -Path $acctSub `
                        -QueryParams $qp `
                        -ErrorAction Stop

                    # Strip UTF-8 BOM that PS 5.1 may leave on the content string
                    $content  = $resp.Content
                    $xmlStart = $content.IndexOf('<')
                    if ($xmlStart -gt 0) { $content = $content.Substring($xmlStart) }
                    [xml]$xml = $content

                    # Filter directories client-side: names starting with the search term
                    foreach ($dir in @($xml.EnumerationResults.Entries.Directory)) {
                        if (-not $dir) { continue }
                        $name = [string]$dir.Name
                        if (-not $name -or $name -notlike "$SearchName*") { continue }
                        $results += [PSCustomObject]@{ StorageAccount = $saName; FolderName = $name; FolderPath = "$uncPath\$name" }
                    }
                    $marker = [string]$xml.EnumerationResults.NextMarker
                } while ($marker)
                $restOk = $true
            } catch {
                $errorList.Add("REST [$saName]: $_")
            }
        }

        # Fallback: SMB listing (may fail if the share root is permission-restricted)
        if (-not $restOk) {
            $root = $uncPath
            try {
                $dirs = @(Get-ChildItem -Path $root -Directory -ErrorAction Stop |
                          Where-Object { $_.Name -like "$SearchName*" })
                foreach ($d in $dirs) {
                    $results += [PSCustomObject]@{ StorageAccount = $saName; FolderName = $d.Name; FolderPath = $d.FullName }
                }
            } catch {
                $errorList.Add("SMB  [$saName]: $_")
            }
        }
    }

    if ($null -ne $SearchErrors) { $SearchErrors.Value = $errorList }
    return $results
}

# =============================================================================
# Show-FolderPickerDialog
# Displays a list of matching profile folders so the user can select one or more.
# Returns an array of chosen PSCustomObjects (@{StorageAccount;FolderName;FolderPath})
# or $null if the user cancelled.
# =============================================================================
function Show-FolderPickerDialog {
    param(
        [PSCustomObject[]]$FolderMatches,
        [string]$SearchName
    )

    [xml]$fpXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Select Profile Folder"
    Height="340" Width="620" MinWidth="500"
    ResizeMode="CanResize"
    WindowStartupLocation="CenterOwner"
    Background="#F4F6F9" FontFamily="Segoe UI">
    <DockPanel Margin="20">
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <TextBlock x:Name="HeaderText" FontSize="13" FontWeight="SemiBold"
                       Foreground="{DynamicResource Avd.Window.Fg}" TextWrapping="Wrap"/>
            <TextBlock x:Name="HintText"
                       Text="Select one or more folders, then click OK.  (Ctrl+Click or Shift+Click to select multiple)"
                       FontSize="12" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,0"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal"
                    HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button x:Name="CancelBtn" Content="Cancel" Width="90" Height="30"
                    Margin="0,0,8,0" IsCancel="True"
                    Background="#E5E5E5" Foreground="#444" BorderThickness="0"
                    FontSize="12" FontWeight="SemiBold" Cursor="Hand">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#D0D0D0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button x:Name="OkBtn" Content="OK" Width="90" Height="30"
                    IsDefault="True" IsEnabled="False"
                    Background="#0078D4" Foreground="White" BorderThickness="0"
                    FontSize="12" FontWeight="SemiBold" Cursor="Hand">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#005A9E"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>
        <DataGrid x:Name="FolderGrid"
                  AutoGenerateColumns="False" IsReadOnly="True"
                  SelectionMode="Extended" SelectionUnit="FullRow"
                  CanUserSortColumns="True" CanUserResizeRows="False"
                  CanUserAddRows="False" HeadersVisibility="Column"
                  GridLinesVisibility="Horizontal"
                  BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1"
                  Background="{DynamicResource Avd.Grid.Bg}"
                  RowBackground="{DynamicResource Avd.Grid.Bg}"
                  AlternatingRowBackground="{DynamicResource Avd.AltRow.Bg}"
                  Foreground="{DynamicResource Avd.Window.Fg}"
                  HorizontalGridLinesBrush="{DynamicResource Avd.Border.Grid}">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Storage Account" Binding="{Binding StorageAccount}" Width="160"/>
                <DataGridTextColumn Header="Folder Name"     Binding="{Binding FolderName}"     Width="*"/>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
'@
    $fpReader = New-Object System.Xml.XmlNodeReader $fpXaml
    $fpWin    = [System.Windows.Markup.XamlReader]::Load($fpReader)
    $fpWin.Owner = $window

    # Apply current theme resources so the grid and text colours match
    foreach ($_key in @($window.Resources.Keys)) {
        try { $fpWin.Resources[$_key] = $window.Resources[$_key] } catch {}
    }
    if ($script:_ptDark) {
        try {
            $fpWin.Add_SourceInitialized({
                $_h = (New-Object System.Windows.Interop.WindowInteropHelper($fpWin)).Handle
                $_v = 1; [void][Win32.DwmApiPT]::DwmSetWindowAttribute($_h, 20, [ref]$_v, 4)
            })
        } catch {}
    }
    try { Set-WindowIcon -Window $fpWin -IconPath (Join-Path $PSScriptRoot 'data\avd-dashboard.ico') } catch {}

    $headerText = $fpWin.FindName('HeaderText')
    $hintText   = $fpWin.FindName('HintText')
    $grid       = $fpWin.FindName('FolderGrid')
    $okBtn      = $fpWin.FindName('OkBtn')
    $cancelBtn  = $fpWin.FindName('CancelBtn')

    $count = $FolderMatches.Count
    $headerText.Text = "$count folder(s) found matching '$SearchName':"

    $grid.ItemsSource = $FolderMatches

    $resultRef = @{ Value = $null }

    $grid.Add_SelectionChanged({
        $sel = $grid.SelectedItems.Count
        $okBtn.IsEnabled = ($sel -gt 0)
        $hintText.Text = if ($sel -gt 1) { "$sel folders selected" } else { "Select one or more folders, then click OK.  (Ctrl+Click or Shift+Click to select multiple)" }
    }.GetNewClosure())

    # Double-click row = immediate OK with just that row
    $grid.Add_MouseDoubleClick({
        if ($grid.SelectedItem) {
            $resultRef.Value = @($grid.SelectedItem)
            $fpWin.DialogResult = $true
            $fpWin.Close()
        }
    }.GetNewClosure())

    $okBtn.Add_Click({
        $resultRef.Value = @($grid.SelectedItems)
        $fpWin.DialogResult = $true
        $fpWin.Close()
    }.GetNewClosure())

    $cancelBtn.Add_Click({ $fpWin.DialogResult = $false; $fpWin.Close() })

    $fpWin.ShowDialog() | Out-Null
    return $resultRef.Value
}

# =============================================================================
# Custom confirmation dialog - auto-sizes to content width
# =============================================================================

function Show-ThemedDialog {
    param(
        [string]$Message,
        [string]$Title   = 'Profile Tools',
        [ValidateSet('OK','YesNo')]
        [string]$Buttons = 'OK',
        [ValidateSet('Information','Warning','Error','Question')]
        [string]$Icon    = 'Information'
    )

    $_themeFile    = if ($script:_ptDark) { 'dark' } else { 'light' }
    $_themeContent = Get-Content -Raw -Path (Join-Path $PSScriptRoot "data\$_themeFile-theme.xaml") -ErrorAction SilentlyContinue
    $_themeRd      = [Windows.Markup.XamlReader]::Parse("<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$_themeContent</ResourceDictionary>")

    $win = New-Object System.Windows.Window
    $win.Title                 = $Title
    $win.Width                 = 420
    $win.MaxWidth              = 640
    $win.SizeToContent         = 'Height'
    $win.ResizeMode            = 'NoResize'
    $win.WindowStartupLocation = 'CenterOwner'
    $win.Owner                 = $window
    $win.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'Avd.Window.Bg')
    $win.SetResourceReference([System.Windows.Window]::ForegroundProperty,  'Avd.Window.Fg')
    $win.Resources.MergedDictionaries.Add($_themeRd)

    try { Set-WindowIcon -Window $win -IconPath (Join-Path $PSScriptRoot 'data\avd-dashboard.ico') } catch {}
    if ($script:_ptDark) {
        $win.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
            $v = 1; [void][Win32.DwmApiPT]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    }

    $iconText = New-Object System.Windows.Controls.TextBlock
    $iconText.FontSize  = 32
    $iconText.Margin    = '0,2,14,0'
    $iconText.VerticalAlignment = 'Top'
    switch ($Icon) {
        'Information' { $iconText.Text = [char]0x2139; $iconText.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString('#0078D4') }
        'Warning'     { $iconText.Text = [char]0x26A0;  $iconText.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString('#F0A500') }
        'Error'       { $iconText.Text = [char]0x2715;  $iconText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Avd.Btn.Danger.Bg') }
        'Question'    { $iconText.Text = '?';           $iconText.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString('#0078D4') }
    }

    $msgText = New-Object System.Windows.Controls.TextBlock
    $msgText.Text         = $Message
    $msgText.TextWrapping = 'Wrap'
    $msgText.MaxWidth     = 380
    $msgText.VerticalAlignment = 'Top'
    $msgText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Avd.Window.Fg')

    $contentRow = New-Object System.Windows.Controls.StackPanel
    $contentRow.Orientation = 'Horizontal'
    $contentRow.Margin      = '20,20,20,16'
    [void]$contentRow.Children.Add($iconText)
    [void]$contentRow.Children.Add($msgText)

    $applyBtnStyle = {
        param([System.Windows.Controls.Button]$Btn, [string]$BgKey, [string]$HoverKey, [string]$PressKey)
        $Btn.Template = [Windows.Markup.XamlReader]::Parse("
            <ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
                             xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='Button'>
                <Border x:Name='Bd' Background='{DynamicResource $BgKey}' CornerRadius='4' Padding='{TemplateBinding Padding}'>
                    <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='Bd' Property='Background' Value='{DynamicResource $HoverKey}'/></Trigger>
                    <Trigger Property='IsPressed'   Value='True'><Setter TargetName='Bd' Property='Background' Value='{DynamicResource $PressKey}'/></Trigger>
                    <Trigger Property='IsEnabled'   Value='False'><Setter TargetName='Bd' Property='Opacity'   Value='0.45'/></Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>")
        $Btn.BorderThickness = 0; $Btn.FontSize = 12; $Btn.FontWeight = 'SemiBold'
        $Btn.Cursor = [System.Windows.Input.Cursors]::Hand
    }

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation         = 'Horizontal'
    $btnRow.HorizontalAlignment = 'Right'
    $btnRow.Margin              = '12,4,16,16'

    $script:_ptDlgResult = $false

    $btnPrimary           = New-Object System.Windows.Controls.Button
    $btnPrimary.Content   = if ($Buttons -eq 'YesNo') { 'Yes' } else { 'OK' }
    $btnPrimary.Width     = 90; $btnPrimary.Height = 30; $btnPrimary.Padding = '10,0'
    $btnPrimary.IsDefault = $true
    & $applyBtnStyle $btnPrimary 'Avd.Btn.Save.Bg' 'Avd.Btn.Save.Hover' 'Avd.Btn.Save.Press'
    $btnPrimary.Foreground = [System.Windows.Media.Brushes]::White
    $btnPrimary.Add_Click({ $script:_ptDlgResult = $true; $win.Close() }.GetNewClosure())

    if ($Buttons -eq 'YesNo') {
        $btnSecondary          = New-Object System.Windows.Controls.Button
        $btnSecondary.Content  = 'No'
        $btnSecondary.Width    = 90; $btnSecondary.Height = 30; $btnSecondary.Padding = '10,0'
        $btnSecondary.Margin   = '0,0,8,0'
        $btnSecondary.IsCancel = $true
        & $applyBtnStyle $btnSecondary 'Avd.Btn.Cancel.Bg' 'Avd.Btn.Cancel.Hover' 'Avd.Btn.Cancel.Press'
        $btnSecondary.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Avd.Fg.Label')
        $btnSecondary.Add_Click({ $script:_ptDlgResult = $false; $win.Close() }.GetNewClosure())
        [void]$btnRow.Children.Add($btnSecondary)
    }
    [void]$btnRow.Children.Add($btnPrimary)

    $outer = New-Object System.Windows.Controls.DockPanel
    $outer.LastChildFill = $true
    [System.Windows.Controls.DockPanel]::SetDock($btnRow, 'Bottom')
    [void]$outer.Children.Add($btnRow)
    [void]$outer.Children.Add($contentRow)

    $win.Content = $outer
    $win.ShowDialog() | Out-Null
    return $script:_ptDlgResult
}

# =============================================================================
# Background job runner helper
# =============================================================================

function Start-BgJob {
    param(
        [scriptblock]$Script,
        [object[]]   $Arguments,
        [hashtable]  $NamedArguments,
        [scriptblock]$OnComplete
    )

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = "MTA"
    $rs.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    if ($NamedArguments) { foreach ($k in $NamedArguments.Keys) { [void]$ps.AddParameter($k, $NamedArguments[$k]) } }

    $handle = $ps.BeginInvoke()

    # Poll for completion on a dispatcher timer.
    # GetNewClosure() is essential - without it the tick scriptblock cannot
    # see $handle, $ps, $rs or $OnComplete from the enclosing function scope.
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $tickBlock = {
        if ($handle.IsCompleted) {
            $timer.Stop()
            try   { $output = $ps.EndInvoke($handle) }
            catch { $output = $null }
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
            & $OnComplete $output
        }
    }.GetNewClosure()
    $timer.Add_Tick($tickBlock)
    $timer.Start()
}

# =============================================================================
# Delete button logic
# =============================================================================

$RunDeleteBtn.Add_Click({

    $folderName = $FolderInput.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($folderName)) {
        Show-ThemedDialog -Title "Input Required" -Message "Please enter a profile folder name." -Icon Warning | Out-Null
        return
    }

    # Collect selected storage accounts
    $selectedAccounts = Get-CheckedAccounts $script:StorageCheckboxes
    if ($selectedAccounts.Count -eq 0) {
        Show-ThemedDialog -Title "No Storage Account Selected" -Message "Please select at least one storage account." -Icon Warning | Out-Null
        return
    }

    $RunDeleteBtn.IsEnabled = $false
    $ClearLogBtn.IsEnabled  = $false
    $StatusBar.Text         = "Running lock check..."
    Clear-Log

    # Capture closure vars
    $fn         = $folderName
    $sa         = @($selectedAccounts)
    $helperCode = $script:storageHelperCode
    $logPath    = if ($script:LogFile) { $script:LogFile } else { "" }
    # Acquire OAuth bearer token for Azure Files data plane access.
    # Get-ArmToken handles caching and automatic refresh when within 5 min of expiry.
    try {
        $storageTok = Get-ArmToken -ResourceUrl 'https://storage.azure.com/'
    } catch {
        Write-Log "ERROR [ProfileTools] Storage token acquisition failed (lock cleanup): $_"
        Show-ThemedDialog -Title "Token Error" -Message "Failed to acquire storage token:`n`n$_`n`nCheck your Azure sign-in and RBAC permissions." -Icon Error | Out-Null
        $RunDeleteBtn.IsEnabled = $true
        $ClearLogBtn.IsEnabled  = $true
        $StatusBar.Text = "Ready."
        return
    }
    # Convert to plain hashtable - OrderedDictionary does not have ContainsKey()
    $shareMap = @{}; foreach ($k in $StorageAccountShareMap.Keys) { $shareMap[$k] = $StorageAccountShareMap[$k] }
    # Build per-account share name and subpath maps from the UNC paths in the storage map
    $shareNameMap    = @{}
    $shareSubPathMap = @{}
    foreach ($k in $StorageAccountShareMap.Keys) {
        $unc = $StorageAccountShareMap[$k]
        $pm = [regex]::Match($unc, '\\\\[^.\\]+\.file\.core\.windows\.net\\([^\\]+)(?:\\(.+))?')
        if ($pm.Success) {
            $shareNameMap[$k]    = $pm.Groups[1].Value
            $shareSubPathMap[$k] = $pm.Groups[2].Value
        }
    }

    # Search each selected share for folders whose names contain the input string.
    # A "perfect match" (input equals the folder name exactly, case-insensitive,
    # and only one match found) skips the picker and proceeds automatically.
    $StatusBar.Text = "Searching shares for '$fn'..."
    $searchErrs = [System.Collections.Generic.List[string]]::new()
    $foundFolders = Find-ProfileFolders -SearchName $fn -SelectedAccounts $sa -ShareMap $shareMap -StorageToken $storageTok -SearchErrors ([ref]$searchErrs)

    if ($foundFolders.Count -eq 0) {
        $errDetail = if ($searchErrs.Count -gt 0) { "`n`nSearch errors:`n" + ($searchErrs -join "`n") } else { '' }
        Show-ThemedDialog -Title "Folder Not Found" `
            -Message "No profile folders starting with '$fn' were found in the selected storage account(s).$errDetail" | Out-Null
        $RunDeleteBtn.IsEnabled = $true
        $ClearLogBtn.IsEnabled  = $true
        $StatusBar.Text = "Ready."
        return
    }

    # Exact match: exactly one result whose folder name equals the input exactly.
    # Skip the picker and proceed directly in that case.
    $exactMatches = @($foundFolders | Where-Object { $_.FolderName -ieq $fn })
    if ($foundFolders.Count -eq 1 -and $exactMatches.Count -eq 1) {
        $chosenFolders = @($foundFolders[0])
    } else {
        # Multiple matches, or a single partial match - let the user pick (multi-select).
        $chosenFolders = Show-FolderPickerDialog -FolderMatches $foundFolders -SearchName $fn
        if (-not $chosenFolders -or $chosenFolders.Count -eq 0) {
            $RunDeleteBtn.IsEnabled = $true
            $ClearLogBtn.IsEnabled  = $true
            $StatusBar.Text = "Ready."
            return
        }
        # All selected folders must share the same folder name so the lock-check
        # script can target a single path across multiple storage accounts.
        $uniqueNames = @($chosenFolders | Select-Object -ExpandProperty FolderName -Unique)
        if ($uniqueNames.Count -gt 1) {
            Show-ThemedDialog -Title "Selection Error" `
                -Message "All selected folders must have the same name.`n`nPlease re-select folders with a single matching name." `
                -Icon Warning | Out-Null
            $RunDeleteBtn.IsEnabled = $true
            $ClearLogBtn.IsEnabled  = $true
            $StatusBar.Text = "Ready."
            return
        }
    }

    $deletePaths = @($chosenFolders | Select-Object -ExpandProperty FolderPath)
    $fn          = $chosenFolders[0].FolderName
    $sa          = @($chosenFolders | Select-Object -ExpandProperty StorageAccount -Unique)

    $checkArgs = @{ StorageHelperCode=$helperCode; StorageToken=$storageTok; FolderName=$fn; SelectedAccounts=$sa; ShareNameMap=$shareNameMap; ShareSubPathMap=$shareSubPathMap; LogFile=$logPath }
    # .GetNewClosure() captures local variables ($storageTok, $helperCode, $fn, $logPath,
    # $deletePaths, $lockCleanupScript, etc.) so they survive into the async OnComplete
    # callback. Without it, Phase 2 (lock cleanup) cannot build its argument hashtable
    # because the Click handler's local scope has already exited by the time the timer fires.
    Start-BgJob -Script $deleteScript -NamedArguments $checkArgs -OnComplete ({
        param($result)

        if (-not $result) {
            Write-Log "  [ERROR] Operation failed - no result returned." "#EF4444"
            $StatusBar.Text = "Error - see log."
            $RunDeleteBtn.IsEnabled = $true
            $ClearLogBtn.IsEnabled  = $true
            return
        }

        # Flush phase 1 messages to log
        foreach ($m in $result.Messages) { Write-Log $m.Text $m.Colour }

        # -- Permission error popup -------------------------------------------
        # If any storage account returned AuthorizationPermissionMismatch, show
        # a clear popup explaining the required RBAC role before continuing.
        if ($result.PermissionError) {
            Show-ThemedDialog -Title "Storage Permission Error" -Message (
                "One or more storage accounts returned a permission error.`n`n" +
                "OAuth data-plane access requires the RBAC role:`n" +
                "  'Storage File Data Privileged Contributor'`n`n" +
                "Assign this role on each storage account (or its resource group/subscription) " +
                "for your user account or service principal.`n`n" +
                "Note: 'Contributor' or 'Storage Account Contributor' are management-plane roles " +
                "and do NOT grant data-plane (file) access.") -Icon Warning | Out-Null
        }

        # -- Lock confirmation if needed --------------------------------------
        if ($result.RequiresLockConfirm) {
            $answer = Show-ThemedDialog -Message "Active locks were found on this profile.`n`nClose all handles and remove lock files to proceed?`n`nWARNING: This will forcefully disconnect the user's session!" -Title "Locks Detected - Confirm Force-Close" -Buttons YesNo -Icon Warning

            if (-not $answer) {
                Write-Log ""
                Write-Log "  [ABORTED] Lock cleanup declined. No files were deleted." "#F59E0B"
                Write-Log ""
                $StatusBar.Text = "Aborted - locks not cleared."
                $RunDeleteBtn.IsEnabled = $true
                $ClearLogBtn.IsEnabled  = $true
                return
            }

            $lockedList  = @($result.LockedAccounts)
            $fn2         = $fn
            $StatusBar.Text = "Clearing locks..."

            $unlockArgs = @{ StorageHelperCode=$helperCode; StorageToken=$storageTok; FolderName=$fn2; LockedAccounts=$lockedList; ShareNameMap=$shareNameMap; ShareSubPathMap=$shareSubPathMap; LogFile=$logPath }
            Start-BgJob -Script $lockCleanupScript -NamedArguments $unlockArgs -OnComplete {
                param($cleanResult)

                foreach ($m in $cleanResult.Messages) { Write-Log $m.Text $m.Colour }

                if ($cleanResult.Errors.Count -gt 0) {
                    Write-Log ""
                    Write-Log "  [ERROR] Lock cleanup failed - deletion aborted. Investigate manually." "#EF4444"
                    $StatusBar.Text = "Error during lock cleanup."
                    $RunDeleteBtn.IsEnabled = $true
                    $ClearLogBtn.IsEnabled  = $true
                    return
                }

                Write-Log ""
                Write-Log "  OK All locks cleared. Proceeding to deletion..." "#34D399"

                # Confirm deletion
                $pathList = ($deletePaths | ForEach-Object { "  - $_" }) -join "`n"
                $delAnswer = Show-ThemedDialog -Title "Confirm Permanent Deletion" `
                    -Message "The following folders will be PERMANENTLY deleted:`n`n$pathList`n`nThis cannot be undone. Are you sure?" -Buttons YesNo -Icon Warning

                if (-not $delAnswer) {
                    Write-Log ""
                    Write-Log "  [CANCELLED] Deletion aborted. Locks were cleared but folders were NOT deleted." "#F59E0B"
                    Write-Log ""
                    $StatusBar.Text = "Cancelled - folders not deleted."
                    $RunDeleteBtn.IsEnabled = $true
                    $ClearLogBtn.IsEnabled  = $true
                    return
                }

                # Audit log - record each profile folder being deleted
                foreach ($p in $deletePaths) { Write-AuditLog -Action 'ProfileDelete' -Target $p -Details "Folder: $(Split-Path $p -Leaf)" }

                $StatusBar.Text = "Deleting profile folders..."
                $pathsArg = @($deletePaths)
                Start-BgJob -Script $removeScript -NamedArguments @{ Paths = $pathsArg } -OnComplete {
                    param($removeResult)
                    foreach ($m in $removeResult.Messages) { Write-Log $m.Text $m.Colour }
                    $StatusBar.Text = "Complete."
                    $FolderInput.Text = ""
                    $RunDeleteBtn.IsEnabled = $true
                    $ClearLogBtn.IsEnabled  = $true
                }
            }

        } else {
            # No locks - straight to deletion confirm
            $pathList = ($deletePaths | ForEach-Object { "  - $_" }) -join "`n"

            $delAnswer = Show-ThemedDialog -Title "Confirm Permanent Deletion" `
                -Message "No locks detected. The following folders will be PERMANENTLY deleted:`n`n$pathList`n`nThis cannot be undone. Are you sure?" -Buttons YesNo -Icon Warning

            if (-not $delAnswer) {
                Write-Log ""
                Write-Log "  [CANCELLED] Deletion aborted by user." "#F59E0B"
                Write-Log ""
                $StatusBar.Text = "Cancelled."
                $RunDeleteBtn.IsEnabled = $true
                $ClearLogBtn.IsEnabled  = $true
                return
            }

            # Audit log - record each profile folder being deleted
            foreach ($p in $deletePaths) { Write-AuditLog -Action 'ProfileDelete' -Target $p -Details "Folder: $(Split-Path $p -Leaf)" }

            $StatusBar.Text = "Deleting profile folders..."
            Write-Log ""
            Write-Log "  PHASE 2 - Lock Cleanup" "#3B8ED4"
            Write-Log ("  " + ([string][char]0x2500) * 48) "#3B5A7A"
            Write-Log "  OK Skipped - no locks detected." "#34D399"
            $pathsArg = @($deletePaths)
            Start-BgJob -Script $removeScript -NamedArguments @{ Paths = $pathsArg } -OnComplete {
                param($removeResult)
                foreach ($m in $removeResult.Messages) { Write-Log $m.Text $m.Colour }
                $StatusBar.Text = "Complete."
                $FolderInput.Text = ""
                $RunDeleteBtn.IsEnabled = $true
                $ClearLogBtn.IsEnabled  = $true
            }
        }
    }).GetNewClosure()
})

# =============================================================================
# Clear log button
# =============================================================================

$ClearLogBtn.Add_Click({
    Clear-Log
    $StatusBar.Text = "Ready."
})

# =============================================================================
# Remove Profile Locks tab - log and button logic
# =============================================================================

$script:unlockLogItems = New-Object System.Collections.ObjectModel.ObservableCollection[PSCustomObject]
$UnlockLogOutput.ItemsSource = $script:unlockLogItems

function Write-UnlockLog {
    param(
        [string]$Message,
        [string]$Colour = "#D1D5DB"
    )
    $entry = [PSCustomObject]@{ Text = $Message; Colour = $Colour }
    $window.Dispatcher.Invoke([Action]{
        $script:unlockLogItems.Add($entry)
        $UnlockLogScroller.ScrollToEnd()
    })
}

function Clear-UnlockLog {
    $window.Dispatcher.Invoke([Action]{ $script:unlockLogItems.Clear() })
}

$ClearUnlockLogBtn.Add_Click({
    Clear-UnlockLog
    $StatusBar.Text = "Ready."
})

$RunUnlockBtn.Add_Click({

    $folderName = $UnlockFolderInput.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($folderName)) {
        Show-ThemedDialog -Title "Input Required" -Message "Please enter a profile folder name." -Icon Warning | Out-Null
        return
    }

    $selectedAccounts = Get-CheckedAccounts $script:UnlockStorageCheckboxes
    if ($selectedAccounts.Count -eq 0) {
        Show-ThemedDialog -Title "No Storage Account Selected" -Message "Please select at least one storage account." -Icon Warning | Out-Null
        return
    }

    $RunUnlockBtn.IsEnabled      = $false
    $ClearUnlockLogBtn.IsEnabled = $false
    $StatusBar.Text              = "Checking for locks..."
    Clear-UnlockLog

    $fn         = $folderName
    $sa         = @($selectedAccounts)
    $helperCode = $script:storageHelperCode
    $logPath    = if ($script:LogFile) { $script:LogFile } else { "" }
    # Build per-account share name and subpath maps from the UNC paths in the storage map
    $shareNameMap    = @{}
    $shareSubPathMap = @{}
    foreach ($k in $StorageAccountShareMap.Keys) {
        $unc = $StorageAccountShareMap[$k]
        $pm = [regex]::Match($unc, '\\\\[^.\\]+\.file\.core\.windows\.net\\([^\\]+)(?:\\(.+))?')
        if ($pm.Success) {
            $shareNameMap[$k]    = $pm.Groups[1].Value
            $shareSubPathMap[$k] = $pm.Groups[2].Value
        }
    }
    # Acquire a fresh OAuth bearer token for Azure Files data plane access
    try {
        $storageTok = Get-ArmToken -ResourceUrl 'https://storage.azure.com/'
    } catch {
        Write-Log "ERROR [ProfileTools] Storage token acquisition failed (unlock): $_"
        Show-ThemedDialog -Title "Token Error" -Message "Failed to acquire storage token:`n`n$_`n`nCheck your Azure sign-in and RBAC permissions." -Icon Error | Out-Null
        $RunUnlockBtn.IsEnabled      = $true
        $ClearUnlockLogBtn.IsEnabled = $true
        $StatusBar.Text = "Ready."
        return
    }

    # Search shares for matching folders - same picker logic as the delete tab.
    $shareMap = @{}; foreach ($k in $StorageAccountShareMap.Keys) { $shareMap[$k] = $StorageAccountShareMap[$k] }
    $StatusBar.Text = "Searching shares for '$fn'..."
    $searchErrs = [System.Collections.Generic.List[string]]::new()
    $foundFolders = Find-ProfileFolders -SearchName $fn -SelectedAccounts $sa -ShareMap $shareMap -StorageToken $storageTok -SearchErrors ([ref]$searchErrs)

    if ($foundFolders.Count -eq 0) {
        $errDetail = if ($searchErrs.Count -gt 0) { "`n`nSearch errors:`n" + ($searchErrs -join "`n") } else { '' }
        Show-ThemedDialog -Title "Folder Not Found" `
            -Message "No profile folders starting with '$fn' were found in the selected storage account(s).$errDetail" | Out-Null
        $RunUnlockBtn.IsEnabled      = $true
        $ClearUnlockLogBtn.IsEnabled = $true
        $StatusBar.Text = "Ready."
        return
    }

    $exactMatches = @($foundFolders | Where-Object { $_.FolderName -ieq $fn })
    if ($foundFolders.Count -eq 1 -and $exactMatches.Count -eq 1) {
        $chosenFolders = @($foundFolders[0])
    } else {
        $chosenFolders = Show-FolderPickerDialog -FolderMatches $foundFolders -SearchName $fn
        if (-not $chosenFolders -or $chosenFolders.Count -eq 0) {
            $RunUnlockBtn.IsEnabled      = $true
            $ClearUnlockLogBtn.IsEnabled = $true
            $StatusBar.Text = "Ready."
            return
        }
        $uniqueNames = @($chosenFolders | Select-Object -ExpandProperty FolderName -Unique)
        if ($uniqueNames.Count -gt 1) {
            Show-ThemedDialog -Title "Selection Error" `
                -Message "All selected folders must have the same name.`n`nPlease re-select folders with a single matching name." `
                -Icon Warning | Out-Null
            $RunUnlockBtn.IsEnabled      = $true
            $ClearUnlockLogBtn.IsEnabled = $true
            $StatusBar.Text = "Ready."
            return
        }
    }
    $fn = $chosenFolders[0].FolderName
    $sa = @($chosenFolders | Select-Object -ExpandProperty StorageAccount -Unique)

    $checkArgs = @{ StorageHelperCode=$helperCode; StorageToken=$storageTok; FolderName=$fn; SelectedAccounts=$sa; ShareNameMap=$shareNameMap; ShareSubPathMap=$shareSubPathMap; LogFile=$logPath }

    Start-BgJob -Script $deleteScript -NamedArguments $checkArgs -OnComplete ({
        param($result)

        if (-not $result) {
            Write-UnlockLog "  [ERROR] Operation failed - no result returned." "#EF4444"
            $StatusBar.Text = "Error - see log."
            $RunUnlockBtn.IsEnabled      = $true
            $ClearUnlockLogBtn.IsEnabled = $true
            return
        }

        foreach ($m in $result.Messages) { Write-UnlockLog $m.Text $m.Colour }

        # -- Permission error popup -------------------------------------------
        if ($result.PermissionError) {
            Show-ThemedDialog -Title "Storage Permission Error" -Message (
                "One or more storage accounts returned a permission error.`n`n" +
                "OAuth data-plane access requires the RBAC role:`n" +
                "  'Storage File Data Privileged Contributor'`n`n" +
                "Assign this role on each storage account (or its resource group/subscription) " +
                "for your user account or service principal.`n`n" +
                "Note: 'Contributor' or 'Storage Account Contributor' are management-plane roles " +
                "and do NOT grant data-plane (file) access.") -Icon Warning | Out-Null
        }

        if ($result.RequiresLockConfirm) {
            $answer = Show-ThemedDialog -Message "Active locks were found on this profile.`n`nClose all handles and remove lock files?`n`nWARNING: This will forcefully disconnect the user's session!" -Title "Locks Detected - Confirm Force-Close" -Buttons YesNo -Icon Warning

            if (-not $answer) {
                Write-UnlockLog ""
                Write-UnlockLog "  [ABORTED] Lock cleanup declined." "#F59E0B"
                Write-UnlockLog ""
                $StatusBar.Text = "Aborted - locks not cleared."
                $RunUnlockBtn.IsEnabled      = $true
                $ClearUnlockLogBtn.IsEnabled = $true
                return
            }

            # Audit log - record the profile unlock
            $lockedDetail = if ($result.LockedAccounts -and $result.LockedAccounts.Count -gt 0) { "Locked accounts: $($result.LockedAccounts -join ', ')" } else { "No locked accounts found" }
            Write-AuditLog -Action 'ProfileUnlock' -Target $fn -Details $lockedDetail

            $lockedList = @($result.LockedAccounts)
            $fn2        = $fn
            $StatusBar.Text = "Clearing locks..."

            $unlockArgs = @{ StorageHelperCode=$helperCode; StorageToken=$storageTok; FolderName=$fn2; LockedAccounts=$lockedList; ShareNameMap=$shareNameMap; ShareSubPathMap=$shareSubPathMap; LogFile=$logPath }
            Start-BgJob -Script $lockCleanupScript -NamedArguments $unlockArgs -OnComplete {
                param($cleanResult)

                foreach ($m in $cleanResult.Messages) { Write-UnlockLog $m.Text $m.Colour }

                if ($cleanResult.Errors.Count -gt 0) {
                    Write-UnlockLog ""
                    Write-UnlockLog "  [ERROR] Lock cleanup failed. Investigate manually." "#EF4444"
                    $StatusBar.Text = "Error during lock cleanup."
                } else {
                    Write-UnlockLog ""
                    Write-UnlockLog "  OK All locks cleared successfully. Profile folder was NOT deleted." "#34D399"
                    Write-UnlockLog ""
                    $StatusBar.Text = "Complete - locks removed."
                    $UnlockFolderInput.Text = ""
                }

                $RunUnlockBtn.IsEnabled      = $true
                $ClearUnlockLogBtn.IsEnabled = $true
            }

        } else {
            Write-UnlockLog ""
            Write-UnlockLog "  OK No locks found on this profile. Nothing to do." "#34D399"
            Write-UnlockLog ""
            $StatusBar.Text = "Complete - no locks found."
            $RunUnlockBtn.IsEnabled      = $true
            $ClearUnlockLogBtn.IsEnabled = $true
        }
    }).GetNewClosure()
})

# =============================================================================
# Allow pressing Enter in the folder input to trigger run
# =============================================================================

$FolderInput.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return -and $RunDeleteBtn.IsEnabled) {
        $RunDeleteBtn.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
})

$UnlockFolderInput.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return -and $RunUnlockBtn.IsEnabled) {
        $RunUnlockBtn.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    }
})

# =============================================================================
# Cleanup on close
# =============================================================================

$window.Add_Closed({
    foreach ($j in @($script:_ptActiveJobs)) {
        try { Stop-Job  -Job $j -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:_ptActiveJobs.Clear()
})

# =============================================================================
# Window Icon
# =============================================================================

Set-WindowIcon -Window $window -IconPath (Join-Path $PSScriptRoot 'data\avd-dashboard.ico')

# Apply initial dark title bar
try {
    $window.Add_SourceInitialized({
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $v = [int]$script:_ptDark
        [void][Win32.DwmApiPT]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
    })
} catch {}

# Wire dark toggle (standalone mode only)
$_ptDarkToggle      = $window.FindName("DarkToggle")
$_ptDarkTogglePanel = $window.FindName("DarkTogglePanel")
if (-not $_ptLaunchedFromDashboard -and $_ptDarkToggle) {
    if ($_ptDarkTogglePanel) { $_ptDarkTogglePanel.Visibility = 'Visible' }
    $_ptDarkToggle.IsChecked = $script:_ptDark
    $_ptDarkToggle.Add_Checked({
        try { Set-ItemProperty -Path $script:_ptRegPath -Name 'DarkTheme' -Value 1 } catch {}
        Switch-ProfileTheme $true
    })
    $_ptDarkToggle.Add_Unchecked({
        try { Set-ItemProperty -Path $script:_ptRegPath -Name 'DarkTheme' -Value 0 } catch {}
        Switch-ProfileTheme $false
    })
}

# =============================================================================
# Show Window
# =============================================================================

Set-SplashStatus "Ready" -Progress 100
$splashWin.Close()
[void]$window.ShowDialog()