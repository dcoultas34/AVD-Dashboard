<#
.SYNOPSIS
    WPF live dashboard for monitoring Azure Virtual Desktop environments and Azure Files
    storage accounts within an Azure subscription.

.DESCRIPTION
    Opens a pop-out WPF dashboard window providing real-time visibility into AVD
    infrastructure and Azure Files storage. All data is collected in persistent background
    runspaces so the UI remains fully responsive at all times.

    AVD Features:
      - Per Host Pool tab: displays each host pool with VM counts (total, on, off),
        active and disconnected user sessions, workspace, region, scaling plan status,
        and host pool resource group.
      - Session counts per region are accurate - each session is matched to the actual
        region of the VM it is running on, not estimated proportionally.
      - Low-priority host pool patterns: host pools matching configured name patterns
        (e.g. -UAT, -TEST) are sorted to the bottom of the Per Host Pool tab.
      - Secondary region highlighting: rows where sessions are running in a configured
        secondary region are highlighted red. Togglable via Settings UI.
      - By Region tab: aggregates host pool data by Azure region.
      - Summary cards: show subscription-wide totals for host pools, VMs, sessions.
        Clicking the Active, Disconnected or Total Sessions cards opens a cross-pool
        session viewer with per-user detail and bulk logoff capability.
      - Session detail window: opened by double-clicking a host pool row. Shows all
        sessions with username, session host, state and type. Supports individual and
        bulk logoff, with a dedicated "Log Off Disconnected" button.
      - Session History: modal window querying LAW for lock/unlock events
        (Security EventID 4800/4801) and session lifecycle events (TerminalServices
        EventID 21/23/24/25) across session hosts. Right-click for per-user lock
        history or session history with selectable time range (12h to 7d). Optional
        via config.
      - Auto-refresh on a configurable interval (default 30s) with countdown display.

    Session Hosts Tab:
      - All session hosts across every host pool in a single filterable grid.
      - CPU %, Mem %, Disk %, Input Delay Median, and Input Delay P95 columns from Log
        Analytics Workspace with heat map colouring. Input Delay P95 matches the
        Microsoft AVD Insights workbook metric.
      - Performance History chart (CPU/Mem over 1h-24h) via right-click.
      - Run Command: execute predefined PowerShell scripts on VMs via the Azure Run
        Command API. Commands defined in data/run-commands.psd1 with live reload.
      - Power actions (Start, Deallocate, Restart) with multi-select support.
      - Copy Hostname, Copy IP Address, and RDP via right-click context menu.

    Azure Files Features:
      - Azure Files tab: queries all FileStorage kind storage accounts and displays
        per-share quota, used space, free space and used percentage via Azure Monitor
        metrics.
      - Storage warning card: always visible on the dashboard header. Shows a green
        tick when all shares are healthy, or an amber warning with the worst offender
        when any share exceeds the configured usage threshold (default 90%). Clicking
        the card navigates to the Azure Files tab.
      - Configurable auto-refresh interval (default 15 minutes).
      - Profile Tools button: launches the companion Profile-Tools.ps1 script from
        the same folder, providing a GUI for FSLogix profile management tasks such
        as lock detection, handle cleanup, and profile folder deletion.

    Settings (persisted to HKCU:\Software\AVDDashboard):
      - AVD data refresh interval (seconds)
      - Azure Files refresh interval (minutes)
      - Storage warning threshold (%)
      - Excluded host pool names
      - AVD included resource groups (limit AVD queries to specific RGs)
      - AVD excluded resource groups (exclude specific RGs from AVD queries)
      - Azure Files resource groups (limit Files queries to specific RGs)
      - Secondary region highlighting toggle (enabled/disabled)

    Shadow Session (right-click on Active sessions):
      - Right-click any Active session in the session detail window.
      - "Shadow (View Only)" - connects without control.
      - "Shadow (With Control)" - connects with full control of the session.
      - Uses mstsc.exe (Remote Desktop) or msra.exe (Remote Assistance) depending
        on the $ShadowMethod config variable.
      - $ShadowMethod and $ShadowUseIP are defined in config.psd1.

      MSTSC shadow requirements:
      - The "Remote Desktop - Shadow (TCP-In)" firewall rule must be enabled on
        session hosts (uses port 445). If port 445 is blocked, use MSRA instead.
      - GPO "Set rules for remote control" must be configured on session hosts:
        HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Shadow
        1 = full control with user consent, 2 = full control without consent (recommended for helpdesk).
      - MSRA (Remote Assistance) uses port 3389 only and does not require port 445.

    Performance:
      - All Azure API calls use direct REST API via bearer token. Only Az.Accounts is
        required (for token acquisition). RunspacePool threads use a compact Invoke-Arm
        helper injected via scriptblock string, eliminating all module import overhead.
      - Parallel host pool queries use a capped RunspacePool (max 10 concurrent) to
        avoid ARM API throttling under large deployments.
      - RG location lookups are cached persistently across refresh cycles so unchanged
        resource group regions are never re-queried.

    Customer/environment-specific settings are loaded from config.psd1,
    which must be present in the config subfolder alongside this script. See
    that file for all configurable values.

.PARAMETER RefreshIntervalSeconds
    How often the AVD data refreshes in seconds. Defaults to 30.
    Can also be set via the Settings UI.

.PARAMETER UseDeviceAuthentication
    When specified, uses device code flow instead of the default interactive browser
    flow. A URL and one-time code are printed to the PowerShell console window;
    complete sign-in there before the dashboard loads. Use this when the interactive
    browser prompt is blocked (e.g. by a corporate proxy).

.PARAMETER UseExistingContext
    When specified, skips authentication entirely and uses the current Az PowerShell
    context. If no active context is found the dashboard exits with a prompt to
    authenticate first (e.g. by running Connect-AzAccount in a PowerShell window).
    Use this when the user has already authenticated manually before launching.

.PARAMETER UseServicePrincipal
    When specified, authenticates non-interactively using a service principal
    (App ID + Client Secret). On first launch a WPF dialog prompts for the App ID
    and Client Secret; the credential is saved as a DPAPI-encrypted file at
    %APPDATA%\AVDDashboard\sp-credential.xml and reused silently on subsequent
    launches. The tenant is taken from Azure.TenantId in config.psd1 (must not be
    empty). If sign-in fails the user is offered the option to clear the saved
    credential and re-enter it.

.PARAMETER EnableLogging
    When specified, writes detailed diagnostic logs to timestamped files in the
    user's TEMP folder. Three log files may be created:
      - avd-dashboard-<timestamp>.log : main log with REST API calls (method,
        URI, status, duration), LAW query diagnostics, and tab refresh errors.
      - avd-dashboard-mfa-debug.txt : MFA parent process log (marker detection,
        claims extraction, child launch/exit, result parsing).
      - avd-dashboard-mfa-child.log : MFA child process log (module load,
        Connect-AzAccount result, ARM operation results).
    The main log path is printed to the PowerShell console on startup. MFA logs
    are only created when an MFA elevation is triggered. Use this when
    troubleshooting REST API errors, LAW data issues, or MFA authentication
    problems. When not specified, all logging code is skipped with zero overhead.

.PARAMETER ConfigFile
    Path to an alternative config.psd1 file. Defaults to config\config.psd1
    relative to the script root.

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-05-30b
    Requires      : PowerShell 5.1 or PowerShell 7 (Windows)

    DISCLAIMER:
    This script is provided as-is with no warranty, guarantee, or support of any kind.
    Use at your own risk. The author accepts no responsibility for any issues,
    data loss, or damages arising from the use of this script in any environment.
    Always test in a non-production environment before deploying.

    Version history moved to CHANGELOG.md.

    Requirements:
      - Az.Accounts module

.EXAMPLE
    .\avd-live-dashboard.ps1

.EXAMPLE
    .\avd-live-dashboard.ps1 -RefreshIntervalSeconds 60
#>

param(
    [int]$RefreshIntervalSeconds = 30,
    [switch]$UseDeviceAuthentication,
    [switch]$UseExistingContext,
    [switch]$UseServicePrincipal,
    [switch]$EnableLogging,
    [string]$ConfigFile
)

# =============================================================================
# Script version - not customer-specific, stays here rather than in config
# =============================================================================

$ScriptVersion = "2026-05-30b"

# All native type definitions and assembly loads are done here, before any WPF windows
# are created. Show-ConfigPicker (the startup config picker) runs before the main
# pre-flight section, so anything it needs must be initialised at this point.

# WPF assemblies
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Data

# Native Win32 types: DWM (dark title bar), DWM console hiding, and Shell32 (taskbar AppID).
# Defined early so the startup config picker gets a dark title bar and the correct taskbar icon.
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DwmApiHelper {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
public class ConsoleHelper {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@ -ErrorAction Stop
} catch {}

# Set the AppUserModelID so the process appears as "AVD Dashboard" in the taskbar
# (separate from the generic PowerShell group) with the custom window icon.
# Must be set before any window is shown - moving it here ensures the startup
# config picker also gets the correct taskbar entry rather than the PS icon.
try {
    $null = Add-Type -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@ -Name 'Shell32' -Namespace 'Win32' -PassThru -ErrorAction Stop
    [Win32.Shell32]::SetCurrentProcessExplicitAppUserModelID('AVDDashboard') | Out-Null
} catch {}

# =============================================================================
# Registry base path
# Single config: flat key HKCU:\Software\AVDDashboard (unchanged from before).
# Multiple configs: Resolve-StartupConfig sets a per-config subkey so each
# environment keeps its own saved settings.
# =============================================================================

# $script:RegPath is the active registry subkey for the current config's settings.
# Single config  → HKCU:\Software\AVDDashboard        (flat, unchanged from before multi-config)
# Multiple configs → HKCU:\Software\AVDDashboard\<slug>  (per-config subkey, set by Resolve-StartupConfig)
#
# $script:GlobalRegPath always points at the root key and never changes.
# It is used for settings that are global (not per-config), currently just DarkTheme.
# Registry layout (multi-config example):
#   HKCU:\Software\AVDDashboard\
#       DarkTheme      = 1           ← global UI pref, read/written via GlobalRegPath
#       DefaultConfig  = "prod"      ← slug of the config to auto-load next launch
#       prod\
#           RefreshInterval = 30
#           ExcludedPools   = ...
#           ...
#       staging\
#           RefreshInterval = 60
#           ...
$script:RegPath           = 'HKCU:\Software\AVDDashboard'
$script:GlobalRegPath     = 'HKCU:\Software\AVDDashboard'
$script:_availableConfigs = @()

# =============================================================================
# Get-AvailableConfigs
# Scans config\*.psd1 (excluding the example template) and returns an array of
# objects with Path, Slug (filename without extension), and DisplayName.
# DisplayName comes from the optional Name = '...' key inside each .psd1 file;
# falls back to the slug if the key is absent or the file cannot be parsed.
# =============================================================================
function Get-AvailableConfigs {
    @(
        Get-ChildItem -Path (Join-Path $PSScriptRoot 'config') -Filter '*.psd1' -ErrorAction SilentlyContinue |
        Where-Object  { $_.Name -ne 'EXAMPLE-config.psd1' } |
        Sort-Object   Name |
        ForEach-Object {
            $_slug = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            $_disp = $_slug   # default display name - overridden below if Name key is present
            try {
                $_d = & ([scriptblock]::Create([System.IO.File]::ReadAllText($_.FullName)))
                if ($_d.Name) { $_disp = [string]$_d.Name }
            } catch {}
            [PSCustomObject]@{ Path = $_.FullName; Slug = $_slug; DisplayName = $_disp }
        }
    )
}

# =============================================================================
# Show-ConfigPicker
# Modal WPF dialog listing available configs. Used at startup (AllowCancel=$false,
# button says "Load") and from the in-dashboard Switch Config button
# (AllowCancel=$true, button says "Switch").
#
# Returns a hashtable: { Config, SetDefault, ClearDefault }
#   Config       - PSCustomObject from Get-AvailableConfigs, or $null if ClearDefault
#   SetDefault   - $true if the user ticked "Remember this choice"
#   ClearDefault - $true if the user clicked "Clear saved default"
# Returns $null if the user cancelled.
#
# Theme: reads DarkTheme from GlobalRegPath (the root key) so the picker is
# correctly themed even at startup before a config has been selected.
# The theme ResourceDictionary is injected into <!-- THEME_SLOT --> in the XAML
# so all DynamicResource colour keys resolve correctly.
# =============================================================================
function Show-ConfigPicker {
    param([object[]]$Configs, [bool]$AllowCancel = $true)

    # Determine theme: use $script:DarkTheme if already set (in-dashboard switch),
    # otherwise read directly from the global root registry key.
    # DarkTheme is a global setting - it never lives in a per-config subkey.
    $_dark = if ($null -ne $script:DarkTheme) { [bool]$script:DarkTheme } else {
        try { [bool][int](Get-ItemProperty -Path $script:GlobalRegPath -Name 'DarkTheme' -ErrorAction Stop).DarkTheme } catch { $false }
    }
    $_tf = if ($_dark) { 'dark' } else { 'light' }

    # Load the appropriate theme XAML so DynamicResource colour keys resolve correctly.
    # The <!-- THEME_SLOT --> placeholder in the Window XAML is replaced with this content.
    $_themeContent = Get-Content -Raw -Path (Join-Path $PSScriptRoot "data\$_tf-theme.xaml") -ErrorAction SilentlyContinue

    $_cxRaw = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AVD Live Dashboard - Select Configuration"
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
            <!-- Shown only when a default is already saved, so the user can clear it -->
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
                        Foreground="White"
                        BorderThickness="0" FontSize="13" FontWeight="SemiBold" Cursor="Hand">
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
    # Inject theme content then parse as XML
    $_cxRaw = $_cxRaw -replace '<!-- THEME_SLOT -->', $_themeContent
    [xml]$_cx = $_cxRaw
    $_reader = New-Object System.Xml.XmlNodeReader($_cx)
    $_w      = [System.Windows.Markup.XamlReader]::Load($_reader)

    # Apply dark title bar via DWM when in dark mode.
    # SourceInitialized fires once the HWND exists but before the window is shown,
    # which is the correct moment for DwmSetWindowAttribute. We use $sender ($s)
    # instead of closing over $_w to avoid PowerShell event handler closure issues.
    if ($_dark) {
        $_w.Add_SourceInitialized({
            param($s, $e)
            try {
                $_hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($s)).Handle
                $_dv = 1; [void][DwmApiHelper]::DwmSetWindowAttribute($_hwnd, 20, [ref]$_dv, 4)
            } catch {}
        })
    }

    # Set window icon - Set-WindowIcon is not yet available at startup (rest-api-helpers.ps1
    # hasn't been dot-sourced yet), so the icon is loaded inline here.
    $_iconPath = Join-Path $PSScriptRoot 'data\avd-dashboard.ico'
    if (Test-Path $_iconPath) {
        try {
            $_stream = [System.IO.File]::OpenRead((Resolve-Path $_iconPath).ProviderPath)
            $_w.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
                $_stream,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $_stream.Close()
        } catch {}
    }

    $_list   = $_w.FindName('ConfigList')
    $_okBtn  = $_w.FindName('OkBtn')
    $_cnlBtn = $_w.FindName('CancelBtn')
    $_setDef = $_w.FindName('SetDefaultCheck')
    $_clrBtn = $_w.FindName('ClearDefaultBtn')

    # Populate list with display names from the configs array
    foreach ($_c in $Configs) { [void]$_list.Items.Add($_c.DisplayName) }
    if ($_list.Items.Count -gt 0) { $_list.SelectedIndex = 0 }

    # Show "Clear saved default" link only when a default is already saved
    # and the caller allows cancellation (i.e. this is an in-dashboard switch, not startup)
    $_rootReg = 'HKCU:\Software\AVDDashboard'
    $_hasDef  = $false
    try { $_hasDef = $null -ne (Get-ItemProperty -Path $_rootReg -Name 'DefaultConfig' -ErrorAction Stop).DefaultConfig } catch {}
    if ($_hasDef -and $AllowCancel) { $_clrBtn.Visibility = 'Visible' }

    # At startup (AllowCancel=$false) Cancel is hidden and the button says "Load".
    # From the Switch Config button (AllowCancel=$true) Cancel is shown and button says "Switch".
    if (-not $AllowCancel) { $_cnlBtn.Visibility = 'Collapsed' }
    if ($AllowCancel)      { $_okBtn.Content = 'Switch' }

    $_okBtn.Add_Click({
        if ($_list.SelectedIndex -lt 0) { return }
        $script:_cfgPickerResult = @{
            Config       = $Configs[$_list.SelectedIndex]
            SetDefault   = [bool]$_setDef.IsChecked
            ClearDefault = $false
        }
        $_w.DialogResult = $true; $_w.Close()
    })
    $_cnlBtn.Add_Click({ $_w.DialogResult = $false; $_w.Close() })
    $_clrBtn.Add_Click({
        # User clicked "Clear saved default" - signal caller to remove the DefaultConfig registry value
        $script:_cfgPickerResult = @{ Config = $null; SetDefault = $false; ClearDefault = $true }
        $_w.DialogResult = $true; $_w.Close()
    })

    $null = $_w.ShowDialog()
    if (-not $_w.DialogResult) { return $null }
    return $script:_cfgPickerResult
}

# =============================================================================
# Resolve-StartupConfig
# Called once at startup to determine which config file to load.
#
# Logic:
#   1 file found  → load it silently; $script:RegPath stays at the root flat key.
#   0 files found → fall back to config\config.psd1 (original behaviour).
#   2+ files found:
#     a) DefaultConfig registry value present and matching file exists
#        → load silently; $script:RegPath set to per-config subkey.
#     b) No usable default → show picker; save DefaultConfig if user ticked
#        "Remember this choice"; set $script:RegPath to per-config subkey.
#
# Returns the full path of the config file to load.
# =============================================================================
function Resolve-StartupConfig {
    $configs = Get-AvailableConfigs
    $script:_availableConfigs = $configs   # stored so the Switch Config button can reference them later

    if ($configs.Count -le 1) {
        # Single config (or none): flat registry path unchanged - existing installs are unaffected
        if ($configs.Count -eq 1) { return $configs[0].Path }
        return Join-Path $PSScriptRoot 'config\config.psd1'   # fallback if config folder is empty
    }

    # Multiple configs: check whether the user has previously saved a default choice
    $_rootReg   = 'HKCU:\Software\AVDDashboard'
    $_savedSlug = try { (Get-ItemProperty -Path $_rootReg -Name 'DefaultConfig' -ErrorAction Stop).DefaultConfig } catch { $null }
    if ($_savedSlug) {
        $_m = $configs | Where-Object { $_.Slug -eq $_savedSlug } | Select-Object -First 1
        if ($_m) {
            # Default found and the file still exists - load silently without showing the picker
            $script:RegPath = "$_rootReg\$($_m.Slug)"
            return $_m.Path
        }
        # Default slug saved but the file has been removed - fall through to show picker
    }

    # No usable default: show the picker. Cancel is disabled at startup so the
    # user must choose a config before the dashboard can open.
    $_p = Show-ConfigPicker -Configs $configs -AllowCancel $false
    if (-not $_p -or -not $_p.Config) { exit }

    # Save DefaultConfig to root registry if user ticked "Remember this choice"
    if ($_p.SetDefault) {
        if (-not (Test-Path $_rootReg)) { try { New-Item -Path $_rootReg -Force | Out-Null } catch {} }
        try { Set-ItemProperty -Path $_rootReg -Name 'DefaultConfig' -Value $_p.Config.Slug } catch {}
    }

    # Switch to the per-config registry subkey for this config's settings
    $script:RegPath = "$_rootReg\$($_p.Config.Slug)"
    return $_p.Config.Path
}

# =============================================================================
# Customer / Environment Configuration
# All environment-specific settings are loaded from config.psd1 which
# must be present in the config subfolder alongside this script. Edit that file
# - not this one - when deploying to a new customer or environment.
# =============================================================================

$_configFile = if ($ConfigFile) { $ConfigFile } else { Resolve-StartupConfig }
$script:_configFile = $_configFile   # exposed for Invoke-ConfigReload
if (-not (Test-Path $_configFile)) {
    [System.Windows.MessageBox]::Show(
        "Configuration file not found:`n`n$_configFile`n`nEnsure config.psd1 is in the config subfolder alongside this script.",
        "Missing Configuration File", "OK", "Error") | Out-Null
    exit 1
}

try {
    $_cfg = & ([scriptblock]::Create([System.IO.File]::ReadAllText($_configFile)))
} catch {
    [System.Windows.MessageBox]::Show(
        "config.psd1 could not be parsed:`n`n$_`n`nCheck the file for syntax errors.",
        "Invalid Configuration File", "OK", "Error") | Out-Null
    exit 1
}

# Azure connection
$DefaultTenantId              = [string]$_cfg.Azure.TenantId
$DefaultSubscriptionId        = [string]$_cfg.Azure.SubscriptionId

# Azure Files
$DefaultFilesRGs              = @($_cfg.AzureFiles.FilesRGs           | Where-Object { $_ })
$DefaultStorageWarningPct     = [int]$_cfg.AzureFiles.StorageWarningPct
$StorageAccountKinds          = @($_cfg.AzureFiles.StorageAccountKinds | Where-Object { $_ })


# AVD Host Pools
$DefaultAvdIncludeRGs         = @($_cfg.AVDHostPools.IncludeRGs            | Where-Object { $_ })
$DefaultAvdExcludeRGs         = @($_cfg.AVDHostPools.ExcludeRGs            | Where-Object { $_ })
$LowPriorityHostPoolPatterns  = @($_cfg.AVDHostPools.LowPriorityPatterns   | Where-Object { $_ })
$DefaultExcludedPools         = @($_cfg.AVDHostPools.ExcludedHostPools      | Where-Object { $_ })
$SecondaryRegions             = @($_cfg.AVDHostPools.SecondaryRegions       | Where-Object { $_ })
$SecondaryRegionHighlightEnabled = [bool]$_cfg.AVDHostPools.SecondaryRegionHighlightEnabled
$HiddenColumns                = @($_cfg.AVDHostPools.HiddenColumns          | Where-Object { $_ })
$script:HostGroupPatterns     = if ($_cfg.AVDHostPools.HostGroupPatterns) { $_cfg.AVDHostPools.HostGroupPatterns } else { @{ A = ''; B = '' } }
$script:ScalingExcludeTag     = if ($_cfg.AVDHostPools.ScalingExcludeTag) { $_cfg.AVDHostPools.ScalingExcludeTag } else { 'ExcludeFromScaling' }
$script:ShowRGVMCount         = if ($null -ne $_cfg.AVDHostPools.ShowRGVMCount) { [bool]$_cfg.AVDHostPools.ShowRGVMCount } else { $true } # Default on; registry can override

# Dashboard (global)
$HiddenTabs                        = @($_cfg.Dashboard.HiddenTabs               | Where-Object { $_ })
$script:DefaultHiddenTabs          = $HiddenTabs
$script:HideSettingsButton         = [bool]$_cfg.Dashboard.HideSettingsButton
$script:HideSessionHistory         = [bool]$_cfg.Dashboard.HideSessionHistory           # Hide the Session History button in session detail windows


# Shadow / RDP
$ShadowMethod                 = [string]$_cfg.ShadowRDP.ShadowMethod
$ShadowUseIP                  = [bool]$_cfg.ShadowRDP.ShadowUseIP

# Infrastructure Servers  (consumed by scripts/tab-infrastructure.ps1 via shared script scope)
# Registry settings (loaded below) can override ResourceGroups at runtime; ExcludePatterns is config-only.
$DefaultInfraRGs             = @($_cfg.InfrastructureServers.ResourceGroups  | Where-Object { $_ })
$script:InfraExcludePatterns = @($_cfg.InfrastructureServers.ExcludePatterns | Where-Object { $_ })

# Images  (consumed by scripts/tab-images.ps1)
$script:ImgRGs             = @($_cfg.Images.ResourceGroups  | Where-Object { $_ })
$script:ImgIncludePatterns = @($_cfg.Images.IncludePatterns | Where-Object { $_ })
$script:ImgGalleryRGs      = @($_cfg.Images.GalleryRGs      | Where-Object { $_ })
$script:ImgPrepVMSizes     = @($_cfg.Images.PrepVMSizes     | Where-Object { $_ })
if ($script:ImgPrepVMSizes.Count -eq 0) { $script:ImgPrepVMSizes = @('Standard_D2s_v5','Standard_D4s_v5','Standard_D8s_v5') }
$script:ImgPrepVMSizeDefault = if ($_cfg.Images.PrepVMSizeDefault) { [string]$_cfg.Images.PrepVMSizeDefault } else { 'Standard_D4s_v5' }
$script:ImgRefreshIntervalSeconds = if ([int]$_cfg.Images.RefreshIntervalSeconds -gt 0) {
    [int]$_cfg.Images.RefreshIntervalSeconds } else { 60 }
$script:ImgVersionsToKeep = if ([int]$_cfg.Images.ImageVersionsToKeep -gt 0) { [int]$_cfg.Images.ImageVersionsToKeep } else { 5 }
$script:ImgBisFPath       = if ($_cfg.Images.BisFPath) { [string]$_cfg.Images.BisFPath } else { 'C:\_source\Bis-F' }
$script:ImgRegion1        = if ($_cfg.Images.ReplicationRegion1) { [string]$_cfg.Images.ReplicationRegion1 } else { '' }
$script:ImgRegion1Replicas = if ([int]$_cfg.Images.ReplicationRegion1Replicas -gt 0) { [int]$_cfg.Images.ReplicationRegion1Replicas } else { 1 }
$script:ImgRegion2        = if ($_cfg.Images.ReplicationRegion2) { [string]$_cfg.Images.ReplicationRegion2 } else { '' }
$script:ImgRegion2Replicas = if ([int]$_cfg.Images.ReplicationRegion2Replicas -gt 0) { [int]$_cfg.Images.ReplicationRegion2Replicas } else { 1 }

# Azure DevOps  (consumed by scripts/tab-azuredevops.ps1)
$script:AdoOrgUrl                  = [string]$_cfg.AzureDevOps.OrganisationUrl
$script:AdoRefreshIntervalSeconds  = if ([int]$_cfg.AzureDevOps.RefreshIntervalSeconds -gt 0) {
    [int]$_cfg.AzureDevOps.RefreshIntervalSeconds } else { 30 }

# Log Analytics  (consumed by scripts/tab-sessionhosts.ps1 - CPU % / Mem % columns)
$script:LawWorkspaceResourceId = [string]$_cfg.LogAnalytics.WorkspaceResourceId
$script:LawQueryBaseUrl        = [string]$_cfg.LogAnalytics.QueryBaseUrl
# Input Delay process exclusions (consumed by scripts/tab-sessionhosts.ps1)
$script:InputDelayExcludeProcesses = @($_cfg.LogAnalytics.InputDelayExcludeProcesses)
if (-not $script:InputDelayExcludeProcesses) { $script:InputDelayExcludeProcesses = @() }

# Network Ranges (consumed by scripts/session-detail.ps1 - Location column)
# Array of @{ Label = '...'; Ranges = @('cidr', ...) } - checked in order, first match wins.
# Filter each entry's Ranges to valid CIDR strings only.
$script:NetworkRangesList = @(
    foreach ($entry in @($_cfg.NetworkRanges)) {
        if (-not $entry.Label -or -not $entry.Ranges) { continue }
        $valid = @($entry.Ranges | Where-Object { $_ -and $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$' })
        if ($valid.Count -gt 0) {
            @{ Label = [string]$entry.Label; Ranges = $valid }
        }
    }
)

# Fallbacks for critical values
if ($StorageAccountKinds.Count -eq 0) { $StorageAccountKinds = @('FileStorage', 'StorageV2') }
if ([string]::IsNullOrWhiteSpace($ShadowMethod)) { $ShadowMethod = 'MSTSC' }

# =============================================================================
# Performance Tuning - RunspacePool concurrency limits
# Controls the maximum number of parallel Azure API calls for each pool.
# Increase values for large environments with many host pools or storage accounts.
# Decrease values if you experience ARM API throttling (429 errors).
# Minimum effective value for all settings is 1.
# =============================================================================

# Persistent pool reused every refresh cycle for per-host-pool session host and
# user session queries. Capped to avoid overwhelming the ARM API under large
# deployments. Pools above this count are queued rather than run simultaneously.
$RunspaceMaxHpPool = 10

# Temporary pool created per refresh cycle for resource group location lookups.
# Only runs for RGs not yet in the persistent location cache, so rarely reaches
# the cap after the first refresh.
$RunspaceMaxRgLookup = 8

# Temporary pool created per Azure Files refresh for parallel storage account
# metric queries (quota, used, free GiB via Azure Monitor). One runspace per
# storage account up to this cap.
$RunspaceMaxStorage = 8

# Pool created per invocation of the session detail / cross-pool session window.
# One runspace per host pool in the view up to this cap.
$script:RunspaceMaxSessionPool = 10  # consumed by scripts/session-detail.ps1 via shared script scope

# =============================================================================
# Cleanup any stale timers/runspaces from previous runs in the same session
# =============================================================================

# Stop timers - try both $script: and $global: since ISE runs in global scope
foreach ($timerVar in @('script:masterTimer','script:detailTimer','script:pollTimer','script:sdCountdownTimer',
                         'global:masterTimer','global:detailTimer','global:pollTimer','global:sdCountdownTimer')) {
    try {
        $t = Get-Variable -Name ($timerVar -replace '^.*:') `
                          -Scope ($timerVar -replace ':.*') `
                          -ErrorAction SilentlyContinue
        if ($t -and $t.Value -and $t.Value.IsEnabled) { $t.Value.Stop() }
    } catch {}
}
# Dispose lingering runspaces and pools
foreach ($psVar in @('script:detailPS','global:detailPS','script:bgRunspace','global:bgRunspace','script:filesRunspace','global:filesRunspace',
                     'script:hpPool','global:hpPool','script:metaPool','global:metaPool','script:saPool','global:saPool')) {
    try {
        $p = Get-Variable -Name ($psVar -replace '^.*:') `
                          -Scope ($psVar -replace ':.*') `
                          -ErrorAction SilentlyContinue
        if ($p -and $p.Value) {
            try { $p.Value.Stop() }              catch {}
            try { $p.Value.Runspace.Close() }    catch {}
            try { $p.Value.Dispose() }           catch {}
        }
    } catch {}
}
# Kill any orphaned background jobs
Get-Job | Where-Object { $_.State -ne 'Running' } | Remove-Job -Force -ErrorAction SilentlyContinue
Get-Job | Where-Object { $_.Name -match 'Job\d+' -and $_.State -eq 'Running' } |
    Stop-Job -PassThru | Remove-Job -Force -ErrorAction SilentlyContinue

# =============================================================================
# Pre-flight
# =============================================================================

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Data

# Set a unique AppUserModelID so the dashboard appears as its own taskbar entry
# (separate from the PowerShell group) and shows the custom window icon.
try {
    $null = Add-Type -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@ -Name 'Shell32' -Namespace 'Win32' -PassThru -ErrorAction Stop
    [Win32.Shell32]::SetCurrentProcessExplicitAppUserModelID('AVDDashboard') | Out-Null
} catch { <# non-critical - continue without custom taskbar grouping #> }

# -- Module check --
$requiredModules = @('Az.Accounts')
$missingModules  = $requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_ ) }

if ($missingModules) {
    $msg = "The following required PowerShell modules are not installed:`n`n" +
           ($missingModules -join "`n") +
           "`n`nWould you like to install them now for the current user?"
    $answer = [System.Windows.MessageBox]::Show(
        $msg,
        "Missing Modules",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($answer -eq 'Yes') {
        try {
            foreach ($mod in $missingModules) {
                [System.Windows.MessageBox]::Show(
                    "Installing $mod - this may take a moment.`n`nClick OK to continue.",
                    "Installing $mod",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information
                ) | Out-Null
                # Ensure NuGet provider is available (required on clean machines)
                if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
                }
                Install-Module -Name $mod -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            }
            [System.Windows.MessageBox]::Show(
                "All modules installed successfully.`n`nClick OK to launch the dashboard.",
                "Installation Complete",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
        } catch {
            [System.Windows.MessageBox]::Show(
                "Failed to install modules:`n`n$_`n`nPlease install manually:`nInstall-Module " + ($missingModules -join ", ") + " -Scope CurrentUser",
                "Installation Failed",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
            exit 1
        }
    } else {
        exit 1
    }
}

# -- Logging setup (early, so auth events are captured) -----------------------
# $script:LogFile is set here when -EnableLogging is passed so that auth-stage
# events can be written. The Write-Log function is defined later in
# rest-api-helpers.ps1; until then we write directly with AppendAllText.
if ($EnableLogging) {
    $script:LogFile = Join-Path $env:TEMP "avd-dashboard-$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
    Write-Host "Logging enabled: $($script:LogFile)" -ForegroundColor Cyan
}
function script:Write-LogEarly {
    param([string]$Message)
    if (-not $script:LogFile) { return }
    try { [System.IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n") } catch {}
}
Write-LogEarly "AVD Live Dashboard v$ScriptVersion | Auth starting | PS $($PSVersionTable.PSVersion)"

# -- Azure authentication ------------------------------------------------------
# Handled by scripts\connect-azure.ps1 (Connect-AzureDashboard).
# Browser flow is the default; see param block above for available switches.

. "$PSScriptRoot\scripts\connect-azure.ps1"

$_cfgBase  = [System.IO.Path]::GetFileNameWithoutExtension($_configFile)
$azContext = Connect-AzureDashboard `
    -TenantId               $DefaultTenantId `
    -SubscriptionId         $DefaultSubscriptionId `
    -UseDeviceAuthentication:$UseDeviceAuthentication `
    -UseExistingContext:$UseExistingContext `
    -UseServicePrincipal:$UseServicePrincipal `
    -CredentialTag          $_cfgBase `
    -LogCallback            { param($m); Write-LogEarly $m }

$subscriptionId        = $azContext.Subscription.Id
$script:azAccountId    = $azContext.Account.Id
$script:azTenantId     = $azContext.Tenant.Id
$script:azArmToken     = ''   # populated fresh before each logoff

# Load REST API helper functions (replaces all Az module calls except Az.Accounts).
# This dot-sources rest-api-helpers.ps1 which defines:
#   - Get-ArmToken          : cached bearer token acquisition via Az.Accounts
#   - Invoke-ArmRestMethod  : core REST wrapper (pagination, retry, backoff)
#   - $script:restHelperDef : compact "Invoke-Arm" string for RunspacePool injection
#   - 20+ resource wrappers : Get-ArmHostPools, Get-ArmSessionHosts, etc.
# See rest-api-helpers.ps1 header for full architecture documentation.
. "$PSScriptRoot\scripts\rest-api-helpers.ps1"
. "$PSScriptRoot\scripts\audit-log.ps1"

# Set the audit log directory to the project root (logs/ subfolder sits here)
$script:AuditLogDir = $PSScriptRoot

# Audit: record dashboard launch
Write-AuditLog -Action 'DashboardLaunch' -Target $azContext.Subscription.Name -Details "Subscription: $subscriptionId"

# =============================================================================
# Diagnostic Logging  (-EnableLogging switch)
#
# When -EnableLogging is passed, $script:LogFile is set to a timestamped file
# in %TEMP% (e.g. avd-dashboard-2026-03-09_143022.log). This single variable
# acts as both the file path AND the feature flag: if it's empty/null, all
# logging is skipped with zero overhead throughout the codebase.
#
# What gets logged when enabled:
#   - REST API calls : every Invoke-ArmRestMethod / Invoke-Arm call logs the
#     HTTP method, URI, status code, duration (ms), and retry attempts.
#     (rest-api-helpers.ps1 - both full and compact Invoke-Arm variants)
#   - Session Hosts Phase 4 (LAW enrichment) : workspace ID, enabled metrics,
#     KQL query, API response status, row counts, VM match results.
#     (tab-sessionhosts.ps1)
#   - MFA child process : when MFA elevation is triggered, the parent writes
#     to avd-dashboard-mfa-debug.txt and the child powershell.exe writes to
#     avd-dashboard-mfa-child.log (both in %TEMP%). These track module load,
#     Connect-AzAccount result, each ARM operation, and final outcome.
#     (rest-api-helpers.ps1 - Resolve-MfaChallenge)
#   - Tab refresh errors : Phase 3/4 errors, region lookups, image version
#     queries, and any caught exceptions during refresh cycles.
#
# How it flows:
#   - Main thread + dot-sourced scripts : call Write-Log (checks $script:LogFile)
#   - Persistent runspaces (bgRunspace, filesRunspace) : $LogFile is injected
#     via SessionStateProxy.SetVariable and used by the compact Invoke-Arm
#   - Pool threads (hpPool, metaPool) : $LogFile is passed via AddArgument
#     and extracted as $args[N], then used with [IO.File]::AppendAllText
#
# The log file path is printed to the console on startup so users know where
# to find it. Launch via Launch-AVD-Dashboard-Logging.cmd for convenience.
# =============================================================================
if ($EnableLogging) {
    # $script:LogFile already set before auth - just log the post-auth context now
    Write-Log "AVD Live Dashboard v$ScriptVersion | PS $($PSVersionTable.PSVersion) | Sub: $($azContext.Subscription.Name)"
    Write-Log "[Config] LawWorkspaceResourceId from config: '$($script:LawWorkspaceResourceId)'"
    Write-Log "[Config] LawQueryBaseUrl from config: '$($script:LawQueryBaseUrl)'"
}

$script:armToken = Get-ArmToken

# =============================================================================
# Splash / Loading Window - shown immediately so the user knows something is happening
# =============================================================================

# Quick early read of dark theme - global setting, always at the root registry key
$_earlyDark = try {
    $k = Get-ItemProperty -Path $script:GlobalRegPath -Name 'DarkTheme' -ErrorAction Stop
    [bool][int]$k.DarkTheme
} catch { $false }

[xml]$splashXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="AVD Live Dashboard" Height="160" Width="420"
    ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
    Background="Transparent" FontFamily="Segoe UI"
    WindowStyle="None" AllowsTransparency="True" Topmost="True">
    <Border x:Name="SplashBorder" CornerRadius="8" Background="White" BorderBrush="#DDE1E7" BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect BlurRadius="20" ShadowDepth="2" Opacity="0.15" Color="#000000"/>
        </Border.Effect>
        <StackPanel VerticalAlignment="Center" Margin="30,24">
            <TextBlock Text="AVD Live Dashboard"
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

if ($_earlyDark) {
    $splashWin.FindName("SplashBorder").Background  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x25,0x25,0x26))
    $splashWin.FindName("SplashBorder").BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x3F,0x3F,0x46))
    $splashStatus.Foreground  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x9D,0x9D,0x9D))
    $splashProgress.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x3F,0x3F,0x46))
}

$splashWin.Show()
$splashWin.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)

function Set-SplashStatus {
    param([string]$Text, [int]$Progress = -1)
    $splashWin.Dispatcher.Invoke([Action]{
        $splashStatus.Text = $Text
        if ($Progress -ge 0) { $splashProgress.Value = $Progress }
    }, [System.Windows.Threading.DispatcherPriority]::Render)
}

# Export the current Az context to a temp file so background runspaces can
# import it - new runspaces do not inherit authentication from the parent session.
$contextFile = [System.IO.Path]::GetTempFileName() + ".json"

# -- Open persistent runspaces and save Az context ─────────────────────────────
# The dashboard uses two types of background execution:
#
# 1. PERSISTENT RUNSPACES (single-thread, long-lived, reused across refreshes)
#    - bgRunspace       : main AVD data collection (host pools, sessions, regions)
#    - filesRunspace    : Azure Files storage account + share metrics
#    - vmRefreshRunspace: Session Hosts tab (created in tab-sessionhosts.ps1)
#    - infraRefreshRunspace: Infrastructure tab (created in tab-infrastructure.ps1)
#    Variables are injected via SessionStateProxy.SetVariable() before each
#    BeginInvoke(). The Invoke-Arm function is dot-sourced into scope from
#    $restHelperDef so these runspaces can make REST calls.
#
# 2. RUNSPACEPOOL THREADS (pooled, short-lived, for parallel fan-out queries)
#    - hpPool   : parallel per-host-pool session queries (max 10 concurrent)
#    - metaPool : parallel metadata queries (host pools, app groups, workspaces, scaling plans)
#    - saPool   : parallel per-storage-account share/metric queries
#    Pool threads get $restHelperDef prepended to their scriptblocks via
#    [scriptblock]::Create($restHelperDef + '...') and receive arguments
#    via .AddArgument(). They CANNOT use param() - see rest-api-helpers.ps1.
#
# All REST calls use bearer tokens passed from the main thread. No Azure
# modules are imported into any runspace - only Az.Accounts is loaded in the
# main thread for token acquisition.
Set-SplashStatus "Initialising runspaces and saving Azure context..." -Progress 10

$script:bgRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$script:bgRunspace.ApartmentState = "MTA"
$script:bgRunspace.Open()

$script:filesRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$script:filesRunspace.ApartmentState = "MTA"
$script:filesRunspace.Open()

Save-AzContext -Path $contextFile -Force | Out-Null

# -- Create persistent RunspacePools for parallel fan-out queries ───────────────
# These pools are created once at startup and reused every refresh cycle.
# hpPool  : one thread per host pool, queries session hosts + user sessions in parallel
# metaPool: 4 threads for metadata (host pools, app groups, workspaces, scaling plans)
# saPool  : one thread per storage account for Azure Files share + metric queries
Set-SplashStatus "Creating persistent runspace pools..." -Progress 70

$script:hpPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $RunspaceMaxHpPool)
$script:hpPool.Open()

$script:metaPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 4)
$script:metaPool.Open()

$script:saPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $RunspaceMaxStorage)
$script:saPool.Open()

# =============================================================================
# Background Data Collection Script ($dataScript)
#
# This scriptblock runs inside bgRunspace on every refresh cycle. It:
#   1. Queries metadata in parallel via metaPool (host pools, app groups, etc.)
#   2. Filters host pools by include/exclude RG patterns
#   3. Queries session hosts + user sessions per host pool via hpPool
#   4. Resolves RG locations (cached across refreshes)
#   5. Resolves image versions per region via per-VM REST queries
#   6. Aggregates results into PSCustomObject rows for Update-UI
#
# The script receives all its data via SessionStateProxy variables (see the
# masterTimer tick handler below). It returns a single data object consumed
# by Update-UI on the WPF dispatcher thread.
# =============================================================================

$dataScript = {
    # Variables injected via SessionStateProxy:
    # $ArmToken, $SubId, $SubscriptionName, $ExcludedPoolsCsv,
    # $AvdIncludeRGsCsv, $AvdExcludeRGsCsv, $RgLocationCache, $LowPriorityPattern,
    # $HostGroupPatternA, $HostGroupPatternB,
    # $HpPool (persistent RunspacePool), $MetaPool (persistent RunspacePool),
    # $MaxRgLookup, $RestHelperDef

    # -------------------------------------------------------------------------
    # Fetch host pools, app groups, workspaces and scaling plans in parallel.
    # These four calls have no dependencies on each other so there is no reason
    # to wait for each one before starting the next.
    # -------------------------------------------------------------------------
    $metaPool = $MetaPool
    $avdApi   = '2024-04-03'

    # HostPool uses a newer preview API to retrieve the deploymentScope property
    # (Geographical / Regional). Other AVD resources stay on the stable API.
    $avdApiPreview = '2026-01-01-preview'

    $metaScript = [scriptblock]::Create($RestHelperDef + @'
        $tok = $args[0]; $subId = $args[1]; $cmd = $args[2]; $api = $args[3]; $LogFile = $args[4]; $apiPreview = $args[5]
        switch ($cmd) {
            'HostPool'    { Invoke-Arm -Path "/subscriptions/$subId/providers/Microsoft.DesktopVirtualization/hostPools"        -Token $tok -ApiVersion $apiPreview }
            'AppGroup'    { Invoke-Arm -Path "/subscriptions/$subId/providers/Microsoft.DesktopVirtualization/applicationGroups" -Token $tok -ApiVersion $api }
            'Workspace'   { Invoke-Arm -Path "/subscriptions/$subId/providers/Microsoft.DesktopVirtualization/workspaces"       -Token $tok -ApiVersion $api }
            'ScalingPlan'       { Invoke-Arm -Path "/subscriptions/$subId/providers/Microsoft.DesktopVirtualization/scalingPlans"     -Token $tok -ApiVersion $api }
        }
'@)

    $metaJobs = foreach ($cmd in @('HostPool','AppGroup','Workspace','ScalingPlan')) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $metaPool
        [void]$ps.AddScript($metaScript).AddArgument($ArmToken).AddArgument($SubId).AddArgument($cmd).AddArgument($avdApi).AddArgument($LogFile).AddArgument($avdApiPreview)
        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Cmd = $cmd }
    }

    $metaResults = @{}
    try {
        foreach ($job in $metaJobs) {
            try   { $metaResults[$job.Cmd] = $job.PS.EndInvoke($job.Handle) }
            catch { if ($job.Cmd -eq 'HostPool') { throw } }   # HostPool is mandatory
            $job.PS.Dispose()
        }
    } finally {
        # Safety net: dispose any PS instances not yet disposed (prevents zombie leaks)
        foreach ($job in $metaJobs) { try { $job.PS.Dispose() } catch {} }
    }

    $allHostPools    = $metaResults['HostPool']
    $allAppGroups    = $metaResults['AppGroup']
    $allWorkspaces   = $metaResults['Workspace']
    $allScalingPlans = $metaResults['ScalingPlan']

    $ExcludedPools  = @($ExcludedPoolsCsv  -split ',' | Where-Object { $_ })
    $AvdIncludeRGs  = @($AvdIncludeRGsCsv  -split ',' | Where-Object { $_ })
    $AvdExcludeRGs  = @($AvdExcludeRGsCsv  -split ',' | Where-Object { $_ })

    # Filter host pools: inclusion by RG first, then exclusion by RG, then exclusion by pool name
    $hostPools = $allHostPools
    if ($AvdIncludeRGs.Count -gt 0) {
        $hostPools = $hostPools | Where-Object {
            $rg = $_.id.Split("/")[4]
            $AvdIncludeRGs | Where-Object { $rg -like $_ } | Select-Object -First 1
        }
    }
    if ($AvdExcludeRGs.Count -gt 0) {
        $hostPools = $hostPools | Where-Object {
            $rg = $_.id.Split("/")[4]
            -not ($AvdExcludeRGs | Where-Object { $rg -like $_ } | Select-Object -First 1)
        }
    }
    if ($ExcludedPools.Count -gt 0) {
        $hostPools = $hostPools | Where-Object { $_.name -notin $ExcludedPools }
    }
    $hostPools  = @($hostPools)
    $totalPools = $hostPools.Count
    $rgCache    = @{}

    # Build hostpool-name -> workspace-name lookup via application groups
    $hpWorkspaceMap = @{}
    if ($allAppGroups -and $allWorkspaces) {
        $agToWs = @{}
        foreach ($ws in $allWorkspaces) {
            foreach ($agRef in $ws.properties.applicationGroupReferences) {
                $agToWs[$agRef.ToLower()] = $ws.name
            }
        }
        foreach ($ag in $allAppGroups) {
            $wsName = $agToWs[$ag.id.ToLower()]
            if ($wsName -and $ag.properties.hostPoolArmPath) {
                $hpName = $ag.properties.hostPoolArmPath.Split("/")[-1]
                if (-not $hpWorkspaceMap.ContainsKey($hpName)) {
                    $hpWorkspaceMap[$hpName] = $wsName
                }
            }
        }
    }

    # Build hostpool-name -> scaling plan enabled map and ARM resource ID map
    $hpScalingMap       = @{}
    $hpScalingPlanIdMap = @{}
    if ($allScalingPlans) {
        foreach ($sp in $allScalingPlans) {
            foreach ($ref in $sp.properties.hostPoolReferences) {
                $hpKey = $ref.hostPoolArmPath.Split("/")[-1]
                if (-not $hpScalingMap.ContainsKey($hpKey) -or $ref.scalingPlanEnabled) {
                    $hpScalingMap[$hpKey]       = [bool]$ref.scalingPlanEnabled
                    $hpScalingPlanIdMap[$hpKey] = [string]$sp.id
                }
            }
        }
    }

    # Build hostpool-name -> deployment scope map (Geographical / Regional)
    # and hostpool-name -> location map (the host pool resource's own Azure region).
    # Scope requires the 2026-01-01-preview API; older pools default to Geographical.
    $hpScopeMap              = @{}
    $hpLocationMap           = @{}
    $hpValidationMap         = @{}
    $hpStartVMMap            = @{}
    $hpMaxSessionMap         = @{}
    $hpLBTypeMap             = @{}
    $hpNetworkMap            = @{}
    $hpPrivateEndpointMap    = @{}
    $hpPrivateEndpointDetails = @{}
    foreach ($hp in $allHostPools) {
        $hpScopeMap[$hp.name]      = if ($hp.properties.deploymentScope) { [string]$hp.properties.deploymentScope } else { 'Geographical' }
        $hpLocationMap[$hp.name]   = if ($hp.location) { [string]$hp.location } else { '' }
        $hpValidationMap[$hp.name] = if ($hp.properties.validationEnvironment) { 'Yes' } else { 'No' }
        $hpStartVMMap[$hp.name]    = if ($hp.properties.startVMOnConnect) { 'Yes' } else { 'No' }
        $hpMaxSessionMap[$hp.name] = if ($null -ne $hp.properties.maxSessionLimit) { [int]$hp.properties.maxSessionLimit } else { 0 }
        $hpLBTypeMap[$hp.name]     = if ($hp.properties.loadBalancerType) { [string]$hp.properties.loadBalancerType } else { '' }
        # publicNetworkAccess: Enabled / Disabled / EnabledForSessionHostsOnly / EnabledForClientsOnly.
        # Absent on older pools - default to Public (same as Azure's own default behaviour).
        $hpNetworkMap[$hp.name]    = switch ([string]$hp.properties.publicNetworkAccess) {
            'Enabled'                    { 'Public'       }
            'Disabled'                   { 'Private'      }
            'EnabledForSessionHostsOnly' { 'Hosts Only'   }
            'EnabledForClientsOnly'      { 'Clients Only' }
            default                      { 'Public'       }
        }
    }

    # -------------------------------------------------------------------------
    # Private Endpoint maps
    #
    # Azure AVD host pools support Private Link. When a private endpoint is
    # attached, it appears under $hp.properties.privateEndpointConnections[]
    # directly on the host pool ARM resource - no separate API call is needed.
    #
    # Two maps are built here:
    #   $hpPrivateEndpointMap     : hostpool name -> count (shown in the grid column)
    #   $hpPrivateEndpointDetails : hostpool name -> list of PSCustomObjects with
    #                               the PE connection name, displayed in the right-
    #                               click "Private Endpoints" popup.
    #
    # Note: the PE connection name is extracted from the 'name' property of each
    # sub-resource; if that is absent (older API versions), the last segment of
    # the 'id' field is used as a fallback.
    #
    # IMPORTANT: these maps are local variables inside $dataScript (which runs in
    # a background runspace). They are passed back to the main thread via the
    # return object (PrivateEndpointDetails) and stored into $script: scope by
    # Update-UI. Script-scope assignments made inside a runspace are NOT visible
    # on the main thread - hence the explicit pass-through via the Data object.
    # -------------------------------------------------------------------------
    # ── Phase 1: collect PE connection names and ARM resource IDs ────────────────
    # Each privateEndpointConnection sub-resource carries the ARM id of the actual
    # PE resource in properties.privateEndpoint.id. We collect these so we can
    # look up the PE resource location in Phase 2.
    $allPeIds = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($hp in $allHostPools) {
        $peConns = @($hp.properties.privateEndpointConnections)

        # Count for the "Private Endpoints" grid column
        $hpPrivateEndpointMap[$hp.name] = $peConns.Count

        # Build initial detail rows (location filled in after the parallel fetch)
        $hpPrivateEndpointDetails[$hp.name] = @($peConns | ForEach-Object {
            $peName = if ([string]$_.name) { [string]$_.name } `
                      elseif ([string]$_.id) { ([string]$_.id).Split('/')[-1] } `
                      else { 'Unknown' }
            $peResourceId = [string]$_.properties.privateEndpoint.id
            # Track every unique PE resource id so we can resolve its location
            if ($peResourceId) {
                [void]$allPeIds.Add([PSCustomObject]@{ HpName = $hp.name; PeName = $peName; PeResourceId = $peResourceId })
            }
            [PSCustomObject]@{ Name = $peName; Region = '' }
        })
    }

    # ── Phase 2: resolve PE resource locations in parallel ───────────────────────
    # GET each PE resource by its full ARM id to retrieve the 'location' property.
    # Uses $MetaPool (already available in this scope) to fan out concurrently.
    # Failures are non-fatal - the Region column will show blank for that PE.
    if ($allPeIds.Count -gt 0) {
        $peLocationScript = [scriptblock]::Create($RestHelperDef + @'
            $tok = $args[0]; $peId = $args[1]; $LogFile = $args[2]
            try {
                $r = Invoke-Arm -Path $peId -Token $tok -ApiVersion '2024-01-01'
                [PSCustomObject]@{ PeResourceId = $peId; Location = if ($r.location) { [string]$r.location } else { '' } }
            } catch {
                [PSCustomObject]@{ PeResourceId = $peId; Location = '' }
            }
'@)

        $peJobs = foreach ($pe in $allPeIds) {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $metaPool
            [void]$ps.AddScript($peLocationScript).AddArgument($ArmToken).AddArgument($pe.PeResourceId).AddArgument($LogFile)
            [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); HpName = $pe.HpName; PeName = $pe.PeName; PeResourceId = $pe.PeResourceId }
        }

        # Collect results and build a resourceId -> location lookup
        $peLocationMap = @{}
        foreach ($job in $peJobs) {
            try {
                $result = $job.PS.EndInvoke($job.Handle)
                if ($result -and $result.Location) { $peLocationMap[$job.PeResourceId] = $result.Location }
            } catch {}
            $job.PS.Dispose()
        }

        # Merge locations back into $hpPrivateEndpointDetails
        foreach ($pe in $allPeIds) {
            $loc = if ($peLocationMap.ContainsKey($pe.PeResourceId)) { $peLocationMap[$pe.PeResourceId] } else { '' }
            $row = $hpPrivateEndpointDetails[$pe.HpName] | Where-Object { $_.Name -eq $pe.PeName } | Select-Object -First 1
            if ($row) { $row.Region = $loc }
        }
    }

    # -------------------------------------------------------------------------
    # RunspacePool: all host pool queries run in parallel (REST API)
    # -------------------------------------------------------------------------
    $hpScript = [scriptblock]::Create($RestHelperDef + @'
        $tok = $args[0]; $subId = $args[1]; $rg = $args[2]; $name = $args[3]; $api = $args[4]; $LogFile = $args[5]
        $sh = Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.DesktopVirtualization/hostPools/$name/sessionHosts"  -Token $tok -ApiVersion $api
        $us = Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.DesktopVirtualization/hostPools/$name/userSessions"  -Token $tok -ApiVersion $api
        [PSCustomObject]@{ HpName = $name; HpRg = $rg; Hosts = @($sh); Sessions = @($us) }
'@)

    $pool = $HpPool

    $handles = @(foreach ($hp in $hostPools) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($hpScript).AddArgument($ArmToken).AddArgument($SubId).AddArgument($hp.id.Split("/")[4]).AddArgument($hp.name).AddArgument($avdApi).AddArgument($LogFile)
        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    })

    $hpResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        foreach ($h in $handles) {
            $output = $h.PS.EndInvoke($h.Handle)
            if ($output -and $output.Count -gt 0) { $hpResults.Add($output[0]) }
            $h.PS.Dispose()
        }
    } finally {
        # Safety net: dispose any PS instances not yet disposed (prevents zombie leaks)
        foreach ($h in $handles) { try { $h.PS.Dispose() } catch {} }
    }

    # Seed rgCache from persistent cross-refresh cache
    if ($RgLocationCache) { foreach ($kv in $RgLocationCache.GetEnumerator()) { $rgCache[$kv.Key] = $kv.Value } }
    $rgToFetch = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in $hpResults) {
        foreach ($sh in $r.Hosts) {
            if ($sh.properties.resourceId) {
                $rgn = $sh.properties.resourceId.Split("/")[4]
                if (-not $rgCache.ContainsKey($rgn)) { [void]$rgToFetch.Add($rgn) }
            }
        }
    }
    if ($rgToFetch.Count -gt 0) {
        $rgPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, [Math]::Min($rgToFetch.Count, $MaxRgLookup))
        $rgPool.Open()
        try {
            $rgScript = [scriptblock]::Create($RestHelperDef + @'
                $tok = $args[0]; $subId = $args[1]; $rgn = $args[2]; $LogFile = $args[3]
                $rg = Invoke-Arm -Path "/subscriptions/$subId/resourcegroups/$rgn" -Token $tok -ApiVersion '2024-03-01' -FullResponse
                if ($rg) { [PSCustomObject]@{ Name = $rg.name; Location = $rg.location } }
'@)
            $rgHandles = @(foreach ($rgn in $rgToFetch) {
                $p = [System.Management.Automation.PowerShell]::Create(); $p.RunspacePool = $rgPool
                [void]$p.AddScript($rgScript).AddArgument($ArmToken).AddArgument($SubId).AddArgument($rgn).AddArgument($LogFile)
                [PSCustomObject]@{ PS = $p; Handle = $p.BeginInvoke() }
            })
            foreach ($rh in $rgHandles) {
                try {
                    $out = $rh.PS.EndInvoke($rh.Handle)
                    if ($out -and $out[0]) { $rgCache[$out[0].Name] = $out[0].Location }
                } catch {
                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [RGLookup] EndInvoke failed: $_`r`n") } catch {} }
                } finally { $rh.PS.Dispose() }
            }
        } finally { $rgPool.Close(); $rgPool.Dispose() }
    }
    $newRgLocations = @{}
    foreach ($k in $rgCache.Keys) {
        if (-not $RgLocationCache -or -not $RgLocationCache.ContainsKey($k)) { $newRgLocations[$k] = $rgCache[$k] }
    }

    # -------------------------------------------------------------------------
    # Aggregate
    # -------------------------------------------------------------------------
    $results    = [System.Collections.Generic.List[PSCustomObject]]::new()
    $imgQueries = [System.Collections.Generic.List[PSCustomObject]]::new()
    $vmRgMap = @{}   # VM short name -> resource group, for fast RDP IP lookup

    foreach ($r in $hpResults) {
        $hpName       = $r.HpName
        $hpRg         = $r.HpRg
        $sessionHosts = @($r.Hosts)
        $userSessions = @($r.Sessions)
        $totalVMs     = $sessionHosts.Count
        $activeSess   = @($userSessions | Where-Object { $_.properties.sessionState -eq "Active"       }).Count
        $disconnSess  = @($userSessions | Where-Object { $_.properties.sessionState -eq "Disconnected" }).Count

        if ($totalVMs -eq 0) {
            # Empty host pool (no session hosts registered). Still show a row so
            # the admin knows the pool exists. VM Region is "N/A" since there are
            # no VMs to derive a region from.
            $results.Add([PSCustomObject]@{
                "Host Pool"      = $hpName                                                              # Host pool display name
                "HP Region"      = if ($hpLocationMap[$hpName]) { $hpLocationMap[$hpName] } else { '' } # Azure region of the host pool resource
                "Workspace"      = if ($hpWorkspaceMap.ContainsKey($hpName)) { $hpWorkspaceMap[$hpName] } else { "" } # Linked workspace
                "VM Region"      = "N/A"                                                                # No VMs -> no region
                "Image Version A" = ""                                                                  # No VMs -> no image
                "Image Version B" = ""                                                                  # No VMs -> no image
                "Total VMs"      = 0
                "RG VMs"         = ''
                "_RGVMDiff"      = '0'
                "VMs Available"  = 0
                "VMs Not Available" = 0
                "VMs Drained"    = 0                                                                # No VMs -> 0 drained; field must match the non-empty pool row schema
                "Active Users"   = $activeSess
                "Disconnected"   = $disconnSess
                "Total Sessions" = $activeSess + $disconnSess
                "Scaling Plan"   = if ($hpScalingMap[$hpName]) { "Yes" } else { "No" }                  # Whether a scaling plan is attached
                "Max Sessions"   = if ($hpMaxSessionMap[$hpName] -and [int]$hpMaxSessionMap[$hpName] -ge 999999) { 'N/A' } elseif ($hpMaxSessionMap[$hpName]) { [string]$hpMaxSessionMap[$hpName] } else { '0' }
                "Load Balancer"  = if ($hpLBTypeMap[$hpName]) { $hpLBTypeMap[$hpName] } else { "" }
                "Validation"     = if ($hpValidationMap[$hpName]) { $hpValidationMap[$hpName] } else { "No" }
                "Start VM on Connect" = if ($hpStartVMMap[$hpName]) { $hpStartVMMap[$hpName] } else { "No" }
                "Network Access"    = if ($hpNetworkMap[$hpName]) { $hpNetworkMap[$hpName] } else { "Public" } # publicNetworkAccess: Public / Private / Hosts Only / Clients Only
                "Private Endpoints" = if ($hpPrivateEndpointMap.ContainsKey($hpName)) { [string]$hpPrivateEndpointMap[$hpName] } else { '0' }
                "Host Pool RG"   = $hpRg                                                                # Resource group of the host pool resource
                "_VMRG"          = ""                                                                   # Session host VM resource group (empty - no VMs)
                "_ScalingPlanId" = if ($hpScalingPlanIdMap.ContainsKey($hpName)) { $hpScalingPlanIdMap[$hpName] } else { '' } # ARM resource ID of the attached scaling plan
                "Scope"          = if ($hpScopeMap[$hpName]) { $hpScopeMap[$hpName] } else { "Geographical" } # Deployment scope: Geographical or Regional (preview API)
                "HP Location"    = if ($hpLocationMap[$hpName]) { $hpLocationMap[$hpName] } else { "" } # Azure region where the host pool resource itself is deployed
            })
            continue
        }

        # Build a lookup: short VM hostname -> region, from the session host list
        # Also build vmRgMap: short VM hostname -> resource group (used for fast RDP IP lookup)
        $shRegionMap = @{}
        foreach ($sh in $sessionHosts) {
            if ($sh.properties.resourceId) {
                $rgName = $sh.properties.resourceId.Split("/")[4]
                $loc    = if ($rgCache.ContainsKey($rgName)) { $rgCache[$rgName] } else { "unknown" }
                # $sh.name is "hostpoolname/vm.domain.com" - extract just the VM short name
                $vmHost = ($sh.name.Split("/")[-1] -split "\.")[0].ToLower()
                $shRegionMap[$vmHost] = $loc
                if (-not $vmRgMap.ContainsKey($vmHost)) { $vmRgMap[$vmHost] = $rgName }
            }
        }

        # Count sessions per region by matching each session to its host's actual region
        $activeByRegion  = @{}
        $disconnByRegion = @{}
        foreach ($us in $userSessions) {
            # User session name is "hostpool/sessionhost.domain.com/sessionid"
            $uHost = ($us.name.Split("/")[1] -split "\.")[0].ToLower()
            $uLoc  = if ($shRegionMap.ContainsKey($uHost)) { $shRegionMap[$uHost] } else { "unknown" }
            if ($us.properties.sessionState -eq "Active") {
                $activeByRegion[$uLoc] = ([int]$activeByRegion[$uLoc]) + 1
            } elseif ($us.properties.sessionState -eq "Disconnected") {
                $disconnByRegion[$uLoc] = ([int]$disconnByRegion[$uLoc]) + 1
            }
        }

        $vmsByRg = $sessionHosts |
            Where-Object { $_.properties.resourceId } |
            Group-Object { $_.properties.resourceId.Split("/")[4] }

        foreach ($grp in $vmsByRg) {
            $loc    = if ($rgCache.ContainsKey($grp.Name)) { $rgCache[$grp.Name] } else { "unknown" }
            $hosts  = $grp.Group
            $on      = @($hosts | Where-Object { $_.properties.status -eq "Available" }).Count
            $drained = @($hosts | Where-Object { -not $_.properties.allowNewSession }).Count
            $active = if ($activeByRegion.ContainsKey($loc))  { [int]$activeByRegion[$loc]  } else { 0 }
            $discon = if ($disconnByRegion.ContainsKey($loc)) { [int]$disconnByRegion[$loc] } else { 0 }

            # Queue REST VM calls to resolve image versions for A and B host groups.
            # When patterns are configured, find one VM per group. When no patterns
            # or no match, column A gets the first VM found and column B shows "N/A".
            $hgEnabled = ($HostGroupPatternA -and $HostGroupPatternB)
            if ($hgEnabled) {
                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ImgVersion] $hpName - A/B patterns enabled (A='*$HostGroupPatternA*', B='*$HostGroupPatternB*')`r`n") } catch {} }
                foreach ($label in @('A','B')) {
                    $pat = if ($label -eq 'A') { $HostGroupPatternA } else { $HostGroupPatternB }
                    $matchSh = $null
                    foreach ($sh in $grp.Group) {
                        $vmShort = ($sh.name.Split("/")[-1] -split "\.")[0]
                        if ($vmShort -like "*$pat*") { $matchSh = $sh; break }
                    }
                    if ($matchSh) {
                        $vmName = ($matchSh.name.Split("/")[-1] -split "\.")[0]
                        $vmRg   = $matchSh.properties.resourceId.Split("/")[4]
                        [void]$imgQueries.Add([PSCustomObject]@{ Key = "$hpName|$loc|$label"; VmName = $vmName; VmRg = $vmRg })
                        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ImgVersion] $hpName Group $label - matched VM '$vmName' (pattern '*$pat*')`r`n") } catch {} }
                    } else {
                        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ImgVersion] $hpName Group $label - no VM matched pattern '*$pat*'`r`n") } catch {} }
                    }
                }
            }
            # When patterns are NOT configured, use the first VM for column A.
            # When patterns ARE configured, respect the match results - if a group
            # has no matching VMs, that column shows "N/A" (no fallback).
            if (-not $hgEnabled) {
                $firstSh     = $grp.Group[0]
                $firstVmName = ($firstSh.name.Split("/")[-1] -split "\.")[0]
                $firstVmRg   = $firstSh.properties.resourceId.Split("/")[4]
                [void]$imgQueries.Add([PSCustomObject]@{ Key = "$hpName|$loc|A"; VmName = $firstVmName; VmRg = $firstVmRg })
                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ImgVersion] $hpName No patterns configured - using first VM '$firstVmName' for Column A`r`n") } catch {} }
            }

            # One row per host pool + VM region combination. A single host pool with
            # VMs across two regions (e.g. ukwest and francecentral) produces two rows.
            $results.Add([PSCustomObject]@{
                "Host Pool"      = $hpName                                                              # Host pool display name
                "HP Region"      = if ($hpLocationMap[$hpName]) { $hpLocationMap[$hpName] } else { '' } # Azure region of the host pool resource
                "Workspace"      = if ($hpWorkspaceMap.ContainsKey($hpName)) { $hpWorkspaceMap[$hpName] } else { "" } # Linked workspace
                "VM Region"      = $loc                                                                 # Azure region where the session host VMs are deployed
                "Image Version A" = ""                                                                  # Populated later from VM metadata (image reference query)
                "Image Version B" = ""                                                                  # Populated later from VM metadata (image reference query)
                "Total VMs"      = $hosts.Count                                                         # Total session hosts in this region group
                "RG VMs"         = ''    # Back-filled after RG VM count pool completes
                "_RGVMDiff"      = '0'  # Back-filled after RG VM count pool completes
                "VMs Available"         = $on                                                                  # VMs with status "Available"
                "VMs Not Available"        = $hosts.Count - $on                                                   # VMs not Available (Shutdown, Deallocated, etc.)
                "VMs Drained"    = $drained                                                                 # VMs with drain mode enabled (allowNewSession = false)
                "Active Users"   = $active                                                              # Active user sessions in this region
                "Disconnected"   = $discon                                                              # Disconnected user sessions in this region
                "Total Sessions" = $active + $discon                                                    # Total sessions (active + disconnected)
                "Scaling Plan"   = if ($hpScalingMap[$hpName]) { "Yes" } else { "No" }                  # Whether a scaling plan is attached
                "Max Sessions"   = if ($hpMaxSessionMap[$hpName] -and [int]$hpMaxSessionMap[$hpName] -ge 999999) { 'N/A' } elseif ($hpMaxSessionMap[$hpName]) { [string]$hpMaxSessionMap[$hpName] } else { '0' }
                "Load Balancer"  = if ($hpLBTypeMap[$hpName]) { $hpLBTypeMap[$hpName] } else { "" }
                "Validation"     = if ($hpValidationMap[$hpName]) { $hpValidationMap[$hpName] } else { "No" }
                "Start VM on Connect" = if ($hpStartVMMap[$hpName]) { $hpStartVMMap[$hpName] } else { "No" }
                "Network Access"    = if ($hpNetworkMap[$hpName]) { $hpNetworkMap[$hpName] } else { "Public" } # publicNetworkAccess: Public / Private / Hosts Only / Clients Only
                "Private Endpoints" = if ($hpPrivateEndpointMap.ContainsKey($hpName)) { [string]$hpPrivateEndpointMap[$hpName] } else { '0' }
                "Host Pool RG"   = $hpRg                                                                # Resource group of the host pool resource
                "_VMRG"          = $grp.Name                                                            # Session host VM resource group
                "_ScalingPlanId" = if ($hpScalingPlanIdMap.ContainsKey($hpName)) { $hpScalingPlanIdMap[$hpName] } else { '' } # ARM resource ID of the attached scaling plan
                "Scope"          = if ($hpScopeMap[$hpName]) { $hpScopeMap[$hpName] } else { "Geographical" } # Deployment scope: Geographical or Regional (preview API)
                "HP Location"    = if ($hpLocationMap[$hpName]) { $hpLocationMap[$hpName] } else { "" } # Azure region where the host pool resource itself is deployed
            })
        }
    }

    # -------------------------------------------------------------------------
    # Resolve image versions AND RG VM counts in parallel simultaneously.
    # Both pool types are started (BeginInvoke) before either is collected,
    # so the ARM calls for image versions and VM list queries overlap in time.
    # -------------------------------------------------------------------------

    # -- Start image version pool (BeginInvoke only, collect later) -----------
    $imgVersionMap = @{}
    $imgHandles    = @()
    $imgPool       = $null
    if ($imgQueries.Count -gt 0) {
        $imgPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
            1, [Math]::Min($imgQueries.Count, 10))
        $imgPool.Open()
        $imgScript = [scriptblock]::Create($RestHelperDef + @'
            $tok = $args[0]; $subId = $args[1]; $rg = $args[2]; $vmn = $args[3]; $LogFile = $args[4]
            $vm = Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/$vmn" -Token $tok -ApiVersion '2024-07-01' -FullResponse
            if ($vm) {
                $ref = $vm.properties.storageProfile.imageReference
                # Gallery VMs: exactVersion is set directly on the VM imageReference
                $ver = $ref.exactVersion
                # Fallback: some older gallery VMs may not have exactVersion on the VM object
                # but retain it on the OS disk's creationData. Marketplace images hit this path
                # too but return nothing (galleryImageReference is absent) - they show N/A.
                # Note: disks use a different API version to VMs; 2024-07-01 is not valid for disks.
                if (-not $ver -and $vm.properties.storageProfile.osDisk.managedDisk.id) {
                    $diskRg   = $vm.properties.storageProfile.osDisk.managedDisk.id.Split('/')[4]
                    $diskName = $vm.properties.storageProfile.osDisk.name
                    $d = Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$diskRg/providers/Microsoft.Compute/disks/$diskName" -Token $tok -ApiVersion '2024-03-02' -FullResponse
                    $ver = $d.properties.creationData.galleryImageReference.exactVersion
                }
                $ver
            }
'@)
        $imgHandles = @(foreach ($q in $imgQueries) {
            $p = [System.Management.Automation.PowerShell]::Create()
            $p.RunspacePool = $imgPool
            [void]$p.AddScript($imgScript).AddArgument($ArmToken).AddArgument($SubId).AddArgument($q.VmRg).AddArgument($q.VmName).AddArgument($LogFile)
            [PSCustomObject]@{ PS = $p; Handle = $p.BeginInvoke(); Key = $q.Key; VmName = $q.VmName }
        })
    }

    # -- Start RG VM count pool (BeginInvoke only, collect later) -------------
    # Runs concurrently with imgPool above - both sets of ARM calls in flight together.
    # Wrapped in try/catch so any pool-creation failure never prevents results returning.
    # Skipped entirely when ShowRGVMCount is $false (config or Settings toggle).
    $rgVmCountMap = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    $rgVmHandles  = @()
    $rgVmPool     = $null
    if (-not $ShowRGVMCount) {
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [RGVMCount] Skipped - ShowRGVMCount is disabled`r`n") } catch {} }
    } else {
    try {
        $uniqueVmRgs = @($results | ForEach-Object { $_.'_VMRG' } | Where-Object { $_ } | Sort-Object -Unique)
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [RGVMCount] Starting - $($uniqueVmRgs.Count) unique VM RG(s): $($uniqueVmRgs -join ', ')`r`n") } catch {} }
        if ($uniqueVmRgs.Count -gt 0) {
            $rgVmPool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
                1, [Math]::Min($uniqueVmRgs.Count, 10))
            $rgVmPool.Open()
            $rgVmScript = [scriptblock]::Create($RestHelperDef + @'
                $tok = $args[0]; $subId = $args[1]; $rgn = $args[2]; $LogFile = $args[3]
                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [RGVMCount] Querying RG '$rgn'`r`n") } catch {} }
                $vms = Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$rgn/providers/Microsoft.Compute/virtualMachines" -Token $tok -ApiVersion '2024-07-01'
                $cnt = @($vms).Count
                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [RGVMCount] RG '$rgn' -> $cnt VM(s)`r`n") } catch {} }
                [PSCustomObject]@{ RG = $rgn; Count = $cnt }
'@)
            $rgVmHandles = @(foreach ($rgn in $uniqueVmRgs) {
                $p = [System.Management.Automation.PowerShell]::Create()
                $p.RunspacePool = $rgVmPool
                [void]$p.AddScript($rgVmScript).AddArgument($ArmToken).AddArgument($SubId).AddArgument($rgn).AddArgument($LogFile)
                [PSCustomObject]@{ PS = $p; Handle = $p.BeginInvoke(); RG = $rgn }
            })
        }
    } catch {
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [RGVMCount] Pool start failed: $_`r`n") } catch {} }
        $rgVmPool = $null; $rgVmHandles = @()
    }
    } # end if ShowRGVMCount

    # -- Collect image version results ----------------------------------------
    if ($imgPool) {
        try {
            foreach ($ih in $imgHandles) {
                try {
                    $out = $ih.PS.EndInvoke($ih.Handle)
                    $imgVersionMap[$ih.Key] = if ($out -and $out[0]) { [string]$out[0] } else { "" }
                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ImgVersion] $($ih.Key): VM '$($ih.VmName)' -> $(if ($imgVersionMap[$ih.Key]) { "version '$($imgVersionMap[$ih.Key])'" } else { 'no version returned' })`r`n") } catch {} }
                } catch {
                    $imgVersionMap[$ih.Key] = ""
                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ImgVersion] $($ih.Key): VM '$($ih.VmName)' -> EndInvoke failed: $_`r`n") } catch {} }
                } finally { $ih.PS.Dispose() }
            }
        } finally { $imgPool.Close(); $imgPool.Dispose() }
    }

    # -- Collect RG VM count results ------------------------------------------
    if ($rgVmPool) {
        try {
            foreach ($rh in $rgVmHandles) {
                try {
                    $out = $rh.PS.EndInvoke($rh.Handle)
                    if ($out -and $out[0]) { $rgVmCountMap[$out[0].RG] = [int]$out[0].Count }
                } catch {
                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [RGVMCount] EndInvoke failed for $($rh.RG): $_`r`n") } catch {} }
                } finally { try { $rh.PS.Dispose() } catch {} }
            }
        } catch {
            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [RGVMCount] Collect failed: $_`r`n") } catch {} }
        } finally {
            try { $rgVmPool.Close(); $rgVmPool.Dispose() } catch {}
        }
    }

    # -- Patch image versions and RG VM counts into result rows ---------------
    # When patterns are configured: missing group = "N/A" (for both A and B).
    # When no patterns: column A gets the version, column B shows "N/A".
    $hgEnabled = ($HostGroupPatternA -and $HostGroupPatternB)
    foreach ($row in $results) {
        $baseKey = "$($row.'Host Pool')|$($row.'VM Region')"
        foreach ($label in @('A','B')) {
            $k = "$baseKey|$label"
            if ($imgVersionMap.ContainsKey($k)) {
                $ver = $imgVersionMap[$k]
                if ($ver -match '^\d{4}(\d{2}\..+)$') { $ver = $matches[1] }
                $row."Image Version $label" = if ($ver) { $ver } else { "N/A" }
            } else {
                # No query was made for this column:
                #   - Patterns enabled: no VMs matched this group -> "N/A"
                #   - No patterns: column B is always "N/A" (only A is queried)
                $row."Image Version $label" = if ($hgEnabled -or $label -eq 'B') { "N/A" } else { "" }
            }
            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ImgVersion] $($row.'Host Pool') Image Version $label = '$($row."Image Version $label")'`r`n") } catch {} }
        }

        # Back-fill RG VM count (map is now populated)
        $vmRg = [string]$row.'_VMRG'
        if ($vmRg -and $rgVmCountMap.ContainsKey($vmRg)) {
            $rgCount = $rgVmCountMap[$vmRg]
            $diff    = $rgCount - [int]$row.'Total VMs'
            $row.'RG VMs'    = [string]$rgCount
            $row.'_RGVMDiff' = [string]$diff
            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [RGVMCount] '$($row.'Host Pool')' RG='$vmRg' TotalVMs=$($row.'Total VMs') RGVMs=$rgCount Diff=$diff`r`n") } catch {} }
        } elseif ($vmRg) {
            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [RGVMCount] '$($row.'Host Pool')' RG='$vmRg' - not found in map ($(if ($rgVmCountMap.Count -eq 0) { 'map empty' } else { "map has $($rgVmCountMap.Count) key(s): $($rgVmCountMap.Keys -join ', ')" }))`r`n") } catch {} }
        }
    }

    $regionSummary = $results |
        Group-Object "VM Region" |
        ForEach-Object {
            $tvms=$ton=$toff=$tdrn=$tact=$tdis=$tses=0
            $hps = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($row in $_.Group) {
                $tvms += $row."Total VMs";     $ton  += $row."VMs Available"
                $toff += $row."VMs Not Available"; $tdrn += $row."VMs Drained"
                $tact += $row."Active Users"
                $tdis += $row."Disconnected";  $tses += $row."Total Sessions"
                [void]$hps.Add($row."Host Pool")
            }
            [PSCustomObject]@{
                "VM Region"         = $_.Name
                "Host Pools"        = $hps.Count
                "Total VMs"         = $tvms
                "VMs Available"     = $ton
                "VMs Not Available" = $toff
                "VMs Drained"       = $tdrn
                "Active Users"      = $tact
                "Disconnected"      = $tdis
                "Total Sessions"    = $tses
            }
        } | Sort-Object "VM Region"

    $totVMs=$totOn=$totOff=$totDrn=$totAct=$totDis=$totSes=0
    foreach ($row in $results) {
        $totVMs += $row."Total VMs";     $totOn  += $row."VMs Available"
        $totOff += $row."VMs Not Available"; $totDrn += $row."VMs Drained"
        $totAct += $row."Active Users"
        $totDis += $row."Disconnected";  $totSes += $row."Total Sessions"
    }

    return [PSCustomObject]@{
        HostPools      = $totalPools
        Results        = @($results | Sort-Object @{Expression={if ($LowPriorityPattern -and $_."Host Pool" -match $LowPriorityPattern) { 1 } else { 0 }}}, "Host Pool", "VM Region")
        RegionSummary  = @($regionSummary)
        TotalVMs       = $totVMs
        OnVMs          = $totOn
        OffVMs         = $totOff
        Active         = $totAct
        Disconnected   = $totDis
        TotalSessions  = $totSes
        Subscription      = $SubscriptionName
        Timestamp         = Get-Date
        NewRgLocations         = $newRgLocations
        VmRgMap                = $vmRgMap
        # Passed to Update-UI so the main thread can store it in $script: scope.
        # Cannot write $script: directly from inside a runspace - it would target
        # the runspace's own script scope, not the main thread's.
        PrivateEndpointDetails = $hpPrivateEndpointDetails
    }
}


# =============================================================================
# Helper: PSCustomObject list -> DataTable (WPF DataGrid binds cleanly to this)
# =============================================================================

function ConvertTo-DataTable {
    param([object[]]$Objects)

    $dt = New-Object System.Data.DataTable
    if (-not $Objects -or $Objects.Count -eq 0) { return ,$dt }

    # Build the schema from the UNION of all objects' properties so that a row with
    # fewer fields (e.g. an empty host pool) appearing first does not cause later rows
    # with additional columns to throw "Column X does not belong to table".
    foreach ($obj in $Objects) {
        foreach ($p in $obj.PSObject.Properties) {
            if ($dt.Columns.Contains($p.Name)) { continue }
            $val = $p.Value
            $colType = if     ($val -is [double]) { [double] }
                       elseif ($val -is [int])    { [int] }
                       else                       { [string] }
            $dt.Columns.Add($p.Name, $colType) | Out-Null
        }
    }
    foreach ($obj in $Objects) {
        $row = $dt.NewRow()
        foreach ($prop in $obj.PSObject.Properties.Name) {
            if (-not $dt.Columns.Contains($prop)) { continue }  # skip if column somehow still missing
            $v = $obj.$prop
            $row[$prop] = if ($null -eq $v) { [DBNull]::Value } else { $v }
        }
        $dt.Rows.Add($row) | Out-Null
    }
    return ,$dt
}

# =============================================================================
# Registry Settings  (HKCU so no elevation needed)
# $script:RegPath is set at startup (flat for single config, subkey for multi)
# =============================================================================

function Read-Settings {
    $defaults = @{ RefreshInterval = 30; FilesRefreshInterval = 900; StorageWarningPct = 90; ShadowMethod = 'MSTSC'; ShadowNoConsent = 0; ShadowUseIP = 0; ExcludedPools = @(); AvdIncludeRGs = @(); AvdExcludeRGs = @(); FilesRGs = @(); InfraRGs = @(); SecondaryRegionHighlight = 1; HiddenTabs = @(); HiddenTabsSaved = $false; HiddenColumns = @(); LowPriorityPatterns = @(); SecondaryRegions = @(); ScalingExcludeTag = ''; StorageAccountKinds = @(); InfraExcludePatterns = @(); DrainSetScalingTag = 1; AdoOrgUrl = ''; AdoRefreshInterval = 0; ShowRGVMCount = $null; DarkTheme = 0 }
    try {
        if (-not (Test-Path $script:RegPath)) { return $defaults }
        $k = Get-ItemProperty -Path $script:RegPath -ErrorAction Stop
        $excl = if ($k.ExcludedPools) { $k.ExcludedPools -split ',' | Where-Object { $_ } } else { @() }
        @{
            RefreshInterval = if ($k.RefreshInterval) { [int]$k.RefreshInterval } else { 30 }
            FilesRefreshInterval = if ($k.FilesRefreshInterval) { [int]$k.FilesRefreshInterval } else { 900 }
            StorageWarningPct    = if ($k.StorageWarningPct)    { [int]$k.StorageWarningPct }    else { 90 }
            ShadowMethod         = if ($k.ShadowMethod)          { $k.ShadowMethod }               else { 'MSTSC' }
            ShadowNoConsent      = if ($null -ne $k.ShadowNoConsent) { [int]$k.ShadowNoConsent }  else { 0 }
            ShadowUseIP          = if ($k.ShadowUseIP)          { [int]$k.ShadowUseIP }          else { 0 }
            AvdIncludeRGs        = @(if ($k.AvdIncludeRGs) { $k.AvdIncludeRGs -split ',' | Where-Object { $_ } } else { @() })
            AvdExcludeRGs        = @(if ($k.AvdExcludeRGs) { $k.AvdExcludeRGs -split ',' | Where-Object { $_ } } else { @() })
            FilesRGs             = @(if ($k.FilesRGs)  { $k.FilesRGs  -split ',' | Where-Object { $_ } } else { @() })
            InfraRGs             = @(if ($k.InfraRGs)  { $k.InfraRGs  -split ',' | Where-Object { $_ } } else { @() })
            ExcludedPools        = @($excl)
            SecondaryRegionHighlight = if ($null -ne $k.SecondaryRegionHighlight) { [int]$k.SecondaryRegionHighlight } else { 1 }
            # Display/filter settings.
            # '__none__' sentinel = user explicitly saved an empty list → registry wins with @().
            # Empty string / missing key = never saved → fall back to config.psd1 default.
            HiddenTabs           = @(if ($k.HiddenTabs -eq '__none__') { @() } elseif ($k.HiddenTabs) { $k.HiddenTabs -split ',' | Where-Object { $_ } } else { @() })
            HiddenTabsSaved      = [bool]($k.HiddenTabs)  # $true if registry has any value (including '__none__')
            HiddenColumns        = @(if ($k.HiddenColumns)        { $k.HiddenColumns -split ',' | Where-Object { $_ } } else { @() })
            LowPriorityPatterns  = @(if ($k.LowPriorityPatterns)  { $k.LowPriorityPatterns -split ',' | Where-Object { $_ } } else { @() })
            SecondaryRegions     = @(if ($k.SecondaryRegions)      { $k.SecondaryRegions -split ',' | Where-Object { $_ } } else { @() })
            ScalingExcludeTag    = if ($k.ScalingExcludeTag)       { $k.ScalingExcludeTag } else { '' }
            StorageAccountKinds  = @(if ($k.StorageAccountKinds)   { $k.StorageAccountKinds -split ',' | Where-Object { $_ } } else { @() })
            InfraExcludePatterns = @(if ($k.InfraExcludePatterns)  { $k.InfraExcludePatterns -split ',' | Where-Object { $_ } } else { @() })
            DrainSetScalingTag   = if ($null -ne $k.DrainSetScalingTag) { [int]$k.DrainSetScalingTag } else { 1 }
            ShowRGVMCount        = if ($null -ne $k.ShowRGVMCount) { [int]$k.ShowRGVMCount } else { $null }
            AdoOrgUrl            = if ($k.AdoOrgUrl)               { [string]$k.AdoOrgUrl } else { '' }
            AdoRefreshInterval   = if ($k.AdoRefreshInterval)     { [int]$k.AdoRefreshInterval } else { 0 }
            # DarkTheme is a global UI preference - always read from the root key,
            # never from the per-config subkey, so the setting survives config switches.
            DarkTheme            = try { [int](Get-ItemProperty -Path $script:GlobalRegPath -Name 'DarkTheme' -ErrorAction Stop).DarkTheme } catch { 0 }
        }
    } catch { $defaults }
}

function Write-Settings {
    param(
        [int]$RefreshInterval, [int]$FilesRefreshInterval, [int]$StorageWarningPct,
        [string]$ShadowMethod, [int]$ShadowNoConsent, [int]$ShadowUseIP,
        [string[]]$ExcludedPools, [string[]]$AvdIncludeRGs, [string[]]$AvdExcludeRGs,
        [string[]]$FilesRGs, [string[]]$InfraRGs, [int]$SecondaryRegionHighlight,
        # Display/filter settings (registry overrides config.psd1)
        [string[]]$HiddenTabs, [string[]]$HiddenColumns, [string[]]$LowPriorityPatterns,
        [string[]]$SecondaryRegions, [string]$ScalingExcludeTag, [string[]]$StorageAccountKinds,
        [string[]]$InfraExcludePatterns, [int]$DrainSetScalingTag = 1,
        [int]$ShowRGVMCount = 1,
        [string]$AdoOrgUrl = '',
        [int]$DarkTheme = 0
    )
    if (-not (Test-Path $script:RegPath)) { New-Item -Path $script:RegPath -Force | Out-Null }
    Set-ItemProperty -Path $script:RegPath -Name 'RefreshInterval'           -Value $RefreshInterval
    Set-ItemProperty -Path $script:RegPath -Name 'FilesRefreshInterval'      -Value $FilesRefreshInterval
    Set-ItemProperty -Path $script:RegPath -Name 'StorageWarningPct'         -Value $StorageWarningPct
    Set-ItemProperty -Path $script:RegPath -Name 'ShadowMethod'              -Value $ShadowMethod
    Set-ItemProperty -Path $script:RegPath -Name 'ShadowNoConsent'           -Value $ShadowNoConsent
    Set-ItemProperty -Path $script:RegPath -Name 'ShadowUseIP'               -Value $ShadowUseIP
    Set-ItemProperty -Path $script:RegPath -Name 'ExcludedPools'             -Value ($ExcludedPools -join ',')
    Set-ItemProperty -Path $script:RegPath -Name 'AvdIncludeRGs'             -Value ($AvdIncludeRGs -join ',')
    Set-ItemProperty -Path $script:RegPath -Name 'AvdExcludeRGs'             -Value ($AvdExcludeRGs -join ',')
    Set-ItemProperty -Path $script:RegPath -Name 'FilesRGs'                  -Value ($FilesRGs -join ',')
    Set-ItemProperty -Path $script:RegPath -Name 'InfraRGs'                  -Value ($InfraRGs -join ',')
    Set-ItemProperty -Path $script:RegPath -Name 'SecondaryRegionHighlight'  -Value $SecondaryRegionHighlight
    # Display/filter settings
    # '__none__' sentinel: user explicitly saved an empty HiddenTabs list.
    # Distinguishes "user cleared all hidden tabs" from "never been saved" (empty string).
    $hiddenTabsRegVal = if ($HiddenTabs.Count -gt 0) { $HiddenTabs -join ',' } else { '__none__' }
    Set-ItemProperty -Path $script:RegPath -Name 'HiddenTabs'               -Value $hiddenTabsRegVal
    Set-ItemProperty -Path $script:RegPath -Name 'HiddenColumns'            -Value ($HiddenColumns -join ',')
    Set-ItemProperty -Path $script:RegPath -Name 'LowPriorityPatterns'      -Value ($LowPriorityPatterns -join ',')
    Set-ItemProperty -Path $script:RegPath -Name 'SecondaryRegions'         -Value ($SecondaryRegions -join ',')
    Set-ItemProperty -Path $script:RegPath -Name 'ScalingExcludeTag'        -Value $ScalingExcludeTag
    Set-ItemProperty -Path $script:RegPath -Name 'StorageAccountKinds'      -Value ($StorageAccountKinds -join ',')
    Set-ItemProperty -Path $script:RegPath -Name 'InfraExcludePatterns'     -Value ($InfraExcludePatterns -join ',')
    Set-ItemProperty -Path $script:RegPath -Name 'DrainSetScalingTag'       -Value $DrainSetScalingTag
    Set-ItemProperty -Path $script:RegPath -Name 'ShowRGVMCount'           -Value $ShowRGVMCount
    Set-ItemProperty -Path $script:RegPath -Name 'AdoOrgUrl'               -Value $AdoOrgUrl
    # DarkTheme is written to the root key (GlobalRegPath), not the per-config subkey,
    # so the theme preference is shared across all configs on this machine.
    if (-not (Test-Path $script:GlobalRegPath)) { New-Item -Path $script:GlobalRegPath -Force | Out-Null }
    Set-ItemProperty -Path $script:GlobalRegPath -Name 'DarkTheme'         -Value $DarkTheme
}

# =============================================================================
# Reload config.psd1 at runtime without restarting the script.
# Re-parses the config file, updates all config-derived default variables, then
# re-applies registry overrides (registry still takes priority over config defaults,
# matching the same precedence applied at script startup).
# Note: Azure tenant/subscription changes are intentionally excluded - those require
# a script restart as they affect the authentication and subscription context.
# =============================================================================
function Invoke-ConfigReload {
    if (-not (Test-Path $script:_configFile)) {
        throw "Config file not found: $script:_configFile"
    }
    try {
        $c = & ([scriptblock]::Create([System.IO.File]::ReadAllText($script:_configFile)))
    } catch {
        throw "config.psd1 could not be parsed: $_"
    }

    # Re-assign config-derived default variables (script scope so registry override can use them)
    $script:DefaultFilesRGs              = @($c.AzureFiles.FilesRGs                    | Where-Object { $_ })
    $script:DefaultStorageWarningPct     = [int]$c.AzureFiles.StorageWarningPct
    $script:DefaultStorageAccountKinds  = @($c.AzureFiles.StorageAccountKinds          | Where-Object { $_ })
    $script:DefaultAvdIncludeRGs         = @($c.AVDHostPools.IncludeRGs                | Where-Object { $_ })
    $script:DefaultAvdExcludeRGs         = @($c.AVDHostPools.ExcludeRGs                | Where-Object { $_ })
    $script:DefaultLowPriorityPatterns   = @($c.AVDHostPools.LowPriorityPatterns       | Where-Object { $_ })
    $script:DefaultExcludedPools         = @($c.AVDHostPools.ExcludedHostPools         | Where-Object { $_ })
    $script:DefaultSecondaryRegions      = @($c.AVDHostPools.SecondaryRegions          | Where-Object { $_ })
    $script:DefaultSecondaryRegionHighlight = [bool]$c.AVDHostPools.SecondaryRegionHighlightEnabled
    $script:DefaultHiddenColumns         = @($c.AVDHostPools.HiddenColumns             | Where-Object { $_ })
    $script:DefaultHiddenTabs            = @($c.Dashboard.HiddenTabs                   | Where-Object { $_ })
    $script:DefaultShadowMethod          = if ([string]::IsNullOrWhiteSpace([string]$c.ShadowRDP.ShadowMethod)) { 'MSTSC' } else { [string]$c.ShadowRDP.ShadowMethod }
    $script:DefaultShadowUseIP           = [bool]$c.ShadowRDP.ShadowUseIP
    $script:DefaultInfraRGs              = @($c.InfrastructureServers.ResourceGroups   | Where-Object { $_ })
    $script:DefaultScalingExcludeTag     = if ($c.AVDHostPools.ScalingExcludeTag) { $c.AVDHostPools.ScalingExcludeTag } else { 'ExcludeFromScaling' }
    if ($script:DefaultStorageAccountKinds.Count -eq 0) { $script:DefaultStorageAccountKinds = @('FileStorage', 'StorageV2') }

    # Config-only variables (no registry override) - applied directly
    $script:HostGroupPatterns       = if ($c.AVDHostPools.HostGroupPatterns) { $c.AVDHostPools.HostGroupPatterns } else { @{ A = ''; B = '' } }
    $script:LawWorkspaceResourceId  = [string]$c.LogAnalytics.WorkspaceResourceId
    $script:LawQueryBaseUrl         = [string]$c.LogAnalytics.QueryBaseUrl
    $script:InputDelayExcludeProcesses = @($c.LogAnalytics.InputDelayExcludeProcesses)
    if (-not $script:InputDelayExcludeProcesses) { $script:InputDelayExcludeProcesses = @() }
    $script:InfraExcludePatterns    = @($c.InfrastructureServers.ExcludePatterns | Where-Object { $_ })
    $script:ImgGalleryRGs          = @($c.Images.GalleryRGs | Where-Object { $_ })
    $script:ImgPrepVMSizes         = @($c.Images.PrepVMSizes | Where-Object { $_ })
    if ($script:ImgPrepVMSizes.Count -eq 0) { $script:ImgPrepVMSizes = @('Standard_D2s_v5','Standard_D4s_v5','Standard_D8s_v5') }
    $script:ImgPrepVMSizeDefault   = if ($c.Images.PrepVMSizeDefault) { [string]$c.Images.PrepVMSizeDefault } else { 'Standard_D4s_v5' }
    $script:ScalingExcludeTag       = $script:DefaultScalingExcludeTag
    $script:NetworkRangesList       = @(
        foreach ($entry in @($c.NetworkRanges)) {
            if (-not $entry.Label -or -not $entry.Ranges) { continue }
            $valid = @($entry.Ranges | Where-Object { $_ -and $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$' })
            if ($valid.Count -gt 0) { @{ Label = [string]$entry.Label; Ranges = $valid } }
        }
    )

    # Re-apply registry overrides (registry wins over reloaded config defaults)
    $saved = Read-Settings
    $script:StorageWarningPct           = if ($saved.StorageWarningPct) { $saved.StorageWarningPct } else { $script:DefaultStorageWarningPct }
    $script:ShadowMethod                = if ($saved.ShadowMethod) { $saved.ShadowMethod } else { $script:DefaultShadowMethod }
    $script:ShadowNoConsent             = if ($null -ne $saved.ShadowNoConsent) { [bool][int]$saved.ShadowNoConsent } else { $false }
    $script:ShadowUseIP                 = if ($saved.ShadowUseIP) { [bool][int]$saved.ShadowUseIP } else { $script:DefaultShadowUseIP }
    $script:AvdIncludeRGs               = if ($saved.AvdIncludeRGs.Count -gt 0)  { $saved.AvdIncludeRGs }  else { $script:DefaultAvdIncludeRGs }
    $script:AvdExcludeRGs               = if ($saved.AvdExcludeRGs.Count -gt 0)  { $saved.AvdExcludeRGs }  else { $script:DefaultAvdExcludeRGs }
    $script:FilesRGs                    = if ($saved.FilesRGs.Count -gt 0)        { $saved.FilesRGs }        else { $script:DefaultFilesRGs }
    $script:InfraRGs                    = if ($saved.InfraRGs.Count -gt 0)        { $saved.InfraRGs }        else { $script:DefaultInfraRGs }
    $script:ExcludedPools               = if ($saved.ExcludedPools.Count -gt 0)   { $saved.ExcludedPools }   else { $script:DefaultExcludedPools }
    $script:StorageAccountKinds         = if ($saved.StorageAccountKinds.Count -gt 0) { $saved.StorageAccountKinds } else { $script:DefaultStorageAccountKinds }
    $script:SecondaryRegions            = if ($saved.SecondaryRegions.Count -gt 0)    { $saved.SecondaryRegions }    else { $script:DefaultSecondaryRegions }
    $script:SecondaryRegionHighlight    = if ($null -ne $saved.SecondaryRegionHighlight) { [bool][int]$saved.SecondaryRegionHighlight } else { $script:DefaultSecondaryRegionHighlight }
    $script:HiddenColumns               = if ($saved.HiddenColumns.Count -gt 0)       { $saved.HiddenColumns }       else { $script:DefaultHiddenColumns }
    # Effective hidden tabs = registry-saved union config defaults (config is the hard floor)
    $script:HiddenTabs                  = @(@(if ($saved.HiddenTabsSaved) { $saved.HiddenTabs } else { $script:DefaultHiddenTabs }) + $script:DefaultHiddenTabs | Select-Object -Unique)
    $script:LowPriorityHostPoolPatterns = if ($saved.LowPriorityPatterns.Count -gt 0)  { $saved.LowPriorityPatterns }  else { $script:DefaultLowPriorityPatterns }
    $script:ScalingExcludeTag           = if ($saved.ScalingExcludeTag)                { $saved.ScalingExcludeTag }    else { $script:DefaultScalingExcludeTag }
    $script:InfraExcludePatterns        = if ($saved.InfraExcludePatterns.Count -gt 0) { $saved.InfraExcludePatterns } else { $script:InfraExcludePatterns }
    $script:ShowRGVMCount               = if ($null -ne $saved.ShowRGVMCount) { [bool][int]$saved.ShowRGVMCount } else { $script:ShowRGVMCount }
}

# Load saved settings - registry values take priority, script defaults used as fallback
$savedSettings                       = Read-Settings
$script:RefreshIntervalSeconds       = $savedSettings.RefreshInterval
$script:FilesRefreshIntervalSeconds  = $savedSettings.FilesRefreshInterval
$script:StorageWarningPct            = if ($savedSettings.StorageWarningPct) { $savedSettings.StorageWarningPct } else { $DefaultStorageWarningPct }
$script:ShadowMethod                 = if ($savedSettings.ShadowMethod) { $savedSettings.ShadowMethod } else { $ShadowMethod }
$script:ShadowNoConsent              = if ($null -ne $savedSettings.ShadowNoConsent) { [bool][int]$savedSettings.ShadowNoConsent } else { $false }
$script:ShadowUseIP                  = if ($savedSettings.ShadowUseIP) { [bool][int]$savedSettings.ShadowUseIP } else { $ShadowUseIP }
$script:AvdIncludeRGs                = if ($savedSettings.AvdIncludeRGs.Count -gt 0) { $savedSettings.AvdIncludeRGs } else { $DefaultAvdIncludeRGs }
$script:AvdExcludeRGs                = if ($savedSettings.AvdExcludeRGs.Count -gt 0) { $savedSettings.AvdExcludeRGs } else { $DefaultAvdExcludeRGs }
$script:FilesRGs                     = if ($savedSettings.FilesRGs.Count -gt 0) { $savedSettings.FilesRGs } else { $DefaultFilesRGs }
$script:InfraRGs                     = if ($savedSettings.InfraRGs.Count -gt 0) { $savedSettings.InfraRGs } else { $DefaultInfraRGs }
$script:ExcludedPools                = if ($savedSettings.ExcludedPools.Count -gt 0) { $savedSettings.ExcludedPools } else { $DefaultExcludedPools }

# Display/filter settings - registry overrides config.psd1 when a value has been saved
$script:StorageAccountKinds          = if ($savedSettings.StorageAccountKinds.Count -gt 0)  { $savedSettings.StorageAccountKinds }  else { $StorageAccountKinds }
$script:SecondaryRegions             = if ($savedSettings.SecondaryRegions.Count -gt 0)     { $savedSettings.SecondaryRegions }     else { $SecondaryRegions }
$script:SecondaryRegionHighlight     = if ($null -ne $savedSettings.SecondaryRegionHighlight) { [bool][int]$savedSettings.SecondaryRegionHighlight } else { $SecondaryRegionHighlightEnabled }
$script:HiddenColumns                = if ($savedSettings.HiddenColumns.Count -gt 0)        { $savedSettings.HiddenColumns }        else { $HiddenColumns }
# Effective hidden tabs = registry-saved union config defaults (config is the hard floor)
$script:HiddenTabs                   = @(@(if ($savedSettings.HiddenTabsSaved) { $savedSettings.HiddenTabs } else { $HiddenTabs }) + $HiddenTabs | Select-Object -Unique)
$script:LowPriorityHostPoolPatterns  = if ($savedSettings.LowPriorityPatterns.Count -gt 0)  { $savedSettings.LowPriorityPatterns }  else { $LowPriorityHostPoolPatterns }
$script:ScalingExcludeTag            = if ($savedSettings.ScalingExcludeTag)                 { $savedSettings.ScalingExcludeTag }    else { $script:ScalingExcludeTag }
$script:InfraExcludePatterns         = if ($savedSettings.InfraExcludePatterns.Count -gt 0)  { $savedSettings.InfraExcludePatterns } else { $script:InfraExcludePatterns }
$script:DrainSetScalingTag           = [bool]$savedSettings.DrainSetScalingTag
$script:ShowRGVMCount                = if ($null -ne $savedSettings.ShowRGVMCount) { [bool][int]$savedSettings.ShowRGVMCount } else { $script:ShowRGVMCount }
$script:DarkTheme                    = if ($null -ne $savedSettings.DarkTheme) { [bool][int]$savedSettings.DarkTheme } else { $false }

# Registry AdoOrgUrl overrides config.psd1 when set
if ($savedSettings.AdoOrgUrl) { $script:AdoOrgUrl = $savedSettings.AdoOrgUrl }
# Registry AdoRefreshInterval overrides config.psd1 when set
if ($savedSettings.AdoRefreshInterval -gt 0) { $script:AdoRefreshIntervalSeconds = $savedSettings.AdoRefreshInterval }

# =============================================================================
# Load tab modules  (must happen before XAML is built so their $*Tab_Xaml
# variables are available for placeholder substitution below)
# =============================================================================

. "$PSScriptRoot\scripts\tab-sessionhosts.ps1"
. "$PSScriptRoot\scripts\cost-lookup.ps1"
# Apply config override for pricing mode.
# PricingWindowsLicence=$true  → Windows Server PAYG (licence bundled in rate)
# PricingWindowsLicence=$false → Linux/base rate (correct for W10/11 multisession and AHB)
if ($null -ne $_cfg.Costs) { $script:UseAHBPricing = -not [bool]$_cfg.Costs.PricingWindowsLicence }
. "$PSScriptRoot\scripts\tab-sessioninfo.ps1"
. "$PSScriptRoot\scripts\tab-azurefiles.ps1"
. "$PSScriptRoot\scripts\tab-monitoring.ps1"
. "$PSScriptRoot\scripts\tab-images.ps1"
. "$PSScriptRoot\scripts\tab-infrastructure.ps1"
. "$PSScriptRoot\scripts\tab-azuredevops.ps1"
. "$PSScriptRoot\scripts\session-detail.ps1"
. "$PSScriptRoot\scripts\run-command.ps1"

# =============================================================================
# XAML Window Definition
# =============================================================================

Set-SplashStatus "Building dashboard UI..." -Progress 90

# Tab XAML fragments are injected by replacing placeholder comments.
# Using a string variable + -replace keeps the main XAML as a clean single-quoted
# heredoc (no variable-expansion escaping needed).
$rawXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="AVD Live Dashboard"
    Height="820" Width="1276"
    MinHeight="560" MinWidth="1120"
    WindowStartupLocation="CenterScreen"
    Background="{DynamicResource Avd.Window.Bg}"
    Foreground="{DynamicResource Avd.Window.Fg}"
    FontFamily="Segoe UI"
    UseLayoutRounding="True"
    TextOptions.TextFormattingMode="Display"
    TextOptions.TextRenderingMode="ClearType">

    <Window.Resources>
        <!-- THEME_SLOT -->

        <!-- DataGrid base style -->
        <Style TargetType="DataGrid">
            <Setter Property="Background"               Value="{DynamicResource Avd.Grid.Bg}"/>
            <Setter Property="BorderBrush"              Value="{DynamicResource Avd.Border.Std}"/>
            <Setter Property="BorderThickness"          Value="1"/>
            <Setter Property="RowBackground"            Value="{DynamicResource Avd.Grid.Bg}"/>
            <Setter Property="AlternatingRowBackground" Value="{DynamicResource Avd.AltRow.Bg}"/>
            <Setter Property="GridLinesVisibility"      Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource Avd.Border.Grid}"/>
            <Setter Property="ColumnHeaderHeight"       Value="38"/>
            <Setter Property="RowHeight"                Value="34"/>
            <Setter Property="FontSize"                 Value="13"/>
            <Setter Property="Foreground"               Value="{DynamicResource Avd.Window.Fg}"/>
            <Setter Property="IsReadOnly"               Value="True"/>
            <Setter Property="AutoGenerateColumns"      Value="True"/>
            <Setter Property="SelectionMode"            Value="Single"/>
            <Setter Property="CanUserResizeRows"        Value="False"/>
            <Setter Property="CanUserAddRows"           Value="False"/>
            <Setter Property="RowHeaderWidth"           Value="0"/>
            <Setter Property="HeadersVisibility"        Value="Column"/>
            <Setter Property="VerticalScrollBarVisibility"   Value="Auto"/>
            <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
        </Style>

        <!-- Row header style - zero-width, background matches grid so no white strip on scroll -->
        <Style TargetType="DataGridRowHeader">
            <Setter Property="Background"   Value="{DynamicResource Avd.Grid.Bg}"/>
            <Setter Property="BorderBrush"  Value="{DynamicResource Avd.Grid.Bg}"/>
            <Setter Property="Width"        Value="0"/>
            <Setter Property="MinWidth"     Value="0"/>
        </Style>

        <!-- Column header style -->
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background"                 Value="{DynamicResource Avd.ColHeader.Bg}"/>
            <Setter Property="Foreground"                 Value="{DynamicResource Avd.ColHeader.Fg}"/>
            <Setter Property="FontWeight"                 Value="SemiBold"/>
            <Setter Property="FontSize"                   Value="12"/>
            <Setter Property="Padding"                    Value="12,0"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="VerticalContentAlignment"   Value="Center"/>
            <Setter Property="BorderBrush"                Value="{DynamicResource Avd.ColHeader.Border}"/>
            <Setter Property="BorderThickness"            Value="0,0,1,0"/>
        </Style>

        <!-- Centre cell content -->
        <Style TargetType="DataGridCell">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
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

        <!-- Tab item style - bottom-border underline -->
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
                                <Setter TargetName="TabBorder" Property="BorderBrush" Value="{DynamicResource Avd.Fg.Accent}"/>
                                <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Accent}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="TabBorder" Property="Background" Value="{DynamicResource Avd.TabHover.Bg}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Card border style -->
        <Style x:Key="CardBorder" TargetType="Border">
            <Setter Property="Background"      Value="{DynamicResource Avd.Card.Bg}"/>
            <Setter Property="CornerRadius"    Value="8"/>
            <Setter Property="Padding"         Value="20,14"/>
            <Setter Property="Margin"          Value="6,0,6,0"/>
            <Setter Property="MinWidth"        Value="120"/>
            <Setter Property="BorderBrush"     Value="{DynamicResource Avd.Border.Std}"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>

        <!-- Status-bar button style -->
        <Style x:Key="RefreshBtn" TargetType="Button">
            <Setter Property="Background"      Value="{DynamicResource Avd.Btn.Std.Bg}"/>
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
                                <Setter Property="Background" Value="{DynamicResource Avd.Btn.Std.Hover}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="{DynamicResource Avd.Btn.Std.Press}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

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

    </Window.Resources>

    <DockPanel>

        <!-- == Status Bar == -->
        <!-- StatusText occupies Column 0 (Width="*") which fills all remaining
             space after the Auto-width button panel. Long messages (e.g. bulk
             deallocate results listing many VM names) would otherwise be silently
             clipped. TextTrimming="CharacterEllipsis" shows '...' at the cutoff
             and the self-bound ToolTip lets the user hover to read the full text. -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.StatusBar.Bg}" Height="32">
            <Grid Margin="12,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusText"
                           Grid.Column="0"
                           Foreground="White" FontSize="12"
                           VerticalAlignment="Center"
                           TextTrimming="CharacterEllipsis"
                           ToolTip="{Binding RelativeSource={RelativeSource Self}, Path=Text}"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="CountdownText"
                               Foreground="{DynamicResource Avd.Fg.Countdown}" FontSize="12"
                               VerticalAlignment="Center" Margin="0,0,14,0"/>
                    <Button x:Name="RefreshButton"
                            Content="Refresh Now"
                            Style="{StaticResource RefreshBtn}"
                            Margin="0,0,8,0"/>
                    <Button x:Name="SwitchConfigButton"
                            Content="Switch Config"
                            Style="{StaticResource RefreshBtn}"
                            Visibility="Collapsed"
                            Margin="0,0,8,0"/>
                    <Button x:Name="SwitchSubButton"
                            Content="Switch Subscription"
                            Style="{StaticResource RefreshBtn}"
                            Margin="0,0,8,0"/>
                    <Button x:Name="SettingsButton"
                            Content="Settings"
                            Style="{StaticResource RefreshBtn}"
                            Margin="0,0,8,0"/>
                    <Button x:Name="AboutButton"
                            Content="About"
                            Style="{StaticResource RefreshBtn}"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- == Header == -->
        <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.Header.Bg}" Padding="20,14,20,14"
                Effect="{DynamicResource Avd.CardShadow}">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                    <TextBlock Text="AVD Live Dashboard"
                               FontSize="20" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"/>
                    <TextBlock x:Name="ConnectedAsText"
                               FontSize="12" Foreground="{DynamicResource Avd.Fg.Muted}"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="Dark" FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}"
                               VerticalAlignment="Center" Margin="0,0,6,0"/>
                    <ToggleButton x:Name="DarkToggle" Style="{StaticResource ToggleSwitch}"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- == Main Content == -->
        <Grid Margin="20,16,20,16">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>  <!-- cards   -->
                <RowDefinition Height="16"/>    <!-- spacer  -->
                <RowDefinition Height="*"/>     <!-- tabs    -->
            </Grid.RowDefinitions>

            <!-- == Summary Cards == -->
            <Grid Grid.Row="0">
                <UniformGrid Rows="1">

                <Border x:Name="CardPoolsBorder" Style="{StaticResource CardBorder}" Cursor="Hand">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardPools" Text="-"
                                   FontSize="30" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"
                                   HorizontalAlignment="Center"/>
                        <TextBlock Text="Host Pools"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>

                <Border x:Name="CardVMsBorder" Style="{StaticResource CardBorder}" Cursor="Hand">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardVMs" Text="-"
                                   FontSize="30" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"
                                   HorizontalAlignment="Center"/>
                        <TextBlock Text="Total VMs"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>

                <Border Style="{StaticResource CardBorder}">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardOn" Text="-"
                                   FontSize="30" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Available}"
                                   HorizontalAlignment="Center"/>
                        <TextBlock Text="VMs Available"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>

                <Border Style="{StaticResource CardBorder}">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardOff" Text="-"
                                   FontSize="30" FontWeight="Bold" Foreground="#D83B01"
                                   HorizontalAlignment="Center"/>
                        <TextBlock Text="VMs Not Available"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>

                <Border x:Name="CardActiveBorder" Style="{StaticResource CardBorder}" Cursor="Hand">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardActive" Text="-"
                                   FontSize="30" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"
                                   HorizontalAlignment="Center"/>
                        <TextBlock Text="Active Sessions"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>

                <Border x:Name="CardDisconnBorder" Style="{StaticResource CardBorder}" Cursor="Hand">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardDisconn" Text="-"
                                   FontSize="30" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Disconnected}"
                                   HorizontalAlignment="Center"/>
                        <TextBlock Text="Disconnected"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>

                <Border x:Name="CardTotalBorder" Style="{StaticResource CardBorder}" Cursor="Hand">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardTotal" Text="-"
                                   FontSize="30" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"
                                   HorizontalAlignment="Center"/>
                        <TextBlock Text="Total Sessions"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Border>

                <!-- Storage card - always visible, green OK or amber warning -->
                <Border x:Name="CardStorageBorder"
                        Style="{StaticResource CardBorder}"
                        Visibility="Visible" Cursor="Hand">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock x:Name="CardStorageIcon" Text="-"
                                   FontSize="30" FontWeight="Bold"
                                   Foreground="{DynamicResource Avd.Fg.Hint}" HorizontalAlignment="Center"/>
                        <TextBlock x:Name="CardStorageText"
                                   Text="Storage"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   HorizontalAlignment="Center" Margin="0,4,0,0"
                                   TextWrapping="Wrap" MaxWidth="100"
                                   TextAlignment="Center"/>
                    </StackPanel>
                </Border>

                </UniformGrid>
            </Grid>

            <!-- == Tab Control == -->
            <TabControl x:Name="MainTabControl" Grid.Row="2"
                        Background="Transparent" BorderThickness="0">

                <TabItem x:Name="PerHostPoolTab" Header="Per Host Pool">
                    <DataGrid x:Name="PoolGrid" Margin="0" ColumnWidth="Auto"/>
                </TabItem>

                <TabItem Header="By Region">
                    <DataGrid x:Name="RegionGrid" Margin="0"/>
                </TabItem>

                <!-- TAB:SESSION_HOSTS -->

                <!-- TAB:SESSION_INFO -->

                <!-- TAB:AZURE_FILES -->

                <!-- TAB:IMAGES -->

                <!-- TAB:INFRASTRUCTURE -->

                <!-- TAB:MONITORING -->

                <!-- TAB:AZURE_DEVOPS -->

            </TabControl>

        </Grid>
    </DockPanel>
</Window>
'@

# Inject tab XAML fragments by replacing placeholder comments, then parse.
$mergedXaml = (((((((
    $rawXaml `
    -replace '<!-- TAB:SESSION_HOSTS -->',  $SessionHostsTab_Xaml) `
    -replace '<!-- TAB:SESSION_INFO -->',   $SessionInfoTab_Xaml) `
    -replace '<!-- TAB:AZURE_FILES -->',    $AzureFilesTab_Xaml) `
    -replace '<!-- TAB:MONITORING -->',     $MonitoringTab_Xaml) `
    -replace '<!-- TAB:IMAGES -->',         $ImagesTab_Xaml) `
    -replace '<!-- TAB:INFRASTRUCTURE -->', $InfrastructureTab_Xaml) `
    -replace '<!-- TAB:AZURE_DEVOPS -->',   $AzureDevOpsTab_Xaml)

# Inject theme resource dictionary into THEME_SLOT placeholder
$script:_themeFile = if ($script:DarkTheme) { 'dark' } else { 'light' }
$_themeFile        = $script:_themeFile
$_themeContent     = Get-Content -Raw -Path "$PSScriptRoot\data\$_themeFile-theme.xaml" -ErrorAction Stop
$mergedXaml        = $mergedXaml -replace '<!-- THEME_SLOT -->', $_themeContent

try {
    [xml]$xaml = $mergedXaml
} catch {
    Write-Log "ERROR [XML Parse] $_"
    throw
}

# =============================================================================
# Load Window
# =============================================================================

try {
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:MainWindow = $window
} catch {
    Write-Log "ERROR [XAML Load] $_"
    throw
}

# Registry of secondary windows that need theme updates when the user toggles dark mode.
# Each popup that carries its own theme ResourceDictionary registers itself here on open
# and removes itself on close. Switch-DashboardTheme iterates this list.
$script:_themedWindows = [System.Collections.Generic.List[System.Windows.Window]]::new()

function Register-ThemedWindow   { param([System.Windows.Window]$Win) [void]$script:_themedWindows.Add($Win) }
function Unregister-ThemedWindow { param([System.Windows.Window]$Win) [void]$script:_themedWindows.Remove($Win) }

# =============================================================================
# Show-ThemedDialog  -  themed replacement for [System.Windows.MessageBox]::Show()
#
# Renders a modal WPF dialog that matches the dashboard's dark/light theme.
# Called from any in-app context where a MessageBox would otherwise be used.
# Startup errors that fire before the WPF window exists should still use
# [System.Windows.MessageBox]::Show() directly.
#
# Parameters
#   Message  - Body text (supports `n newlines and long strings; wraps automatically)
#   Title    - Window title bar text
#   Buttons  - 'OK' | 'OKCancel' | 'YesNo'
#   Icon     - 'Information' | 'Warning' | 'Error' | 'Question'
#   Owner    - Optional explicit owner window; defaults to the active detail window
#              ($script:sdOpenWindow) or the main dashboard window
#
# Returns
#   $true  - user clicked OK or Yes
#   $false - user clicked Cancel, No, or closed the window with X
# =============================================================================
function Show-ThemedDialog {
    param(
        [string]$Message,
        [string]$Title   = 'AVD Dashboard',
        [ValidateSet('OK','OKCancel','YesNo')]
        [string]$Buttons = 'OK',
        [ValidateSet('Information','Warning','Error','Question')]
        [string]$Icon    = 'Information',
        [System.Windows.Window]$Owner = $null
    )

    # ── Resolve owner window ─────────────────────────────────────────────────
    # Use the session-detail window when it is open (it is in the foreground),
    # otherwise fall back to the main dashboard window.
    $_owner = if ($Owner) { $Owner }
              elseif ($script:sdOpenWindow -and $script:sdOpenWindow.IsLoaded) { $script:sdOpenWindow }
              else { $script:MainWindow }

    # ── Build WPF window ─────────────────────────────────────────────────────
    $win = New-Object System.Windows.Window
    $win.Title                 = $Title
    $win.Width                 = 400
    $win.MaxWidth              = 600
    $win.SizeToContent         = 'Height'
    $win.ResizeMode            = 'NoResize'
    $win.WindowStartupLocation = 'CenterOwner'
    $win.Owner                 = $_owner
    $win.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'Avd.Window.Bg')
    $win.SetResourceReference([System.Windows.Window]::ForegroundProperty,  'Avd.Window.Fg')

    # ── Inject current theme as a MergedDictionary ──────────────────────────
    # Reads the theme file fresh so the dialog is correct even if the user
    # toggled dark/light mode after the dashboard started.
    $_themeFile    = if ($script:DarkTheme) { 'dark' } else { 'light' }
    $_themeContent = Get-Content -Raw -Path "$PSScriptRoot\data\$_themeFile-theme.xaml" -ErrorAction SilentlyContinue
    $_themeRd      = [Windows.Markup.XamlReader]::Parse("<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$_themeContent</ResourceDictionary>")
    $win.Resources.MergedDictionaries.Add($_themeRd)

    # Window icon and dark title bar chrome
    try { Set-WindowIcon -Window $win -IconPath (Join-Path $PSScriptRoot 'data\avd-dashboard.ico') } catch {}
    if ($script:DarkTheme) {
        $win.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
            $v = 1; [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    }

    # Register so Switch-DashboardTheme can push resource updates while open
    Register-ThemedWindow $win
    $win.Add_Closed({ Unregister-ThemedWindow $win }.GetNewClosure())

    # ── Icon glyph + colour ──────────────────────────────────────────────────
    $iconText           = New-Object System.Windows.Controls.TextBlock
    $iconText.FontSize  = 32
    $iconText.Margin    = '0,2,14,0'
    $iconText.VerticalAlignment = 'Top'
    switch ($Icon) {
        'Information' { $iconText.Text = [char]0x2139; $iconText.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString('#0078D4') }
        'Warning'     { $iconText.Text = [char]0x26A0;  $iconText.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString('#F0A500') }
        'Error'       { $iconText.Text = [char]0x2715;  $iconText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Avd.Btn.Danger.Bg') }
        'Question'    { $iconText.Text = '?';           $iconText.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString('#0078D4') }
    }

    # ── Message text ─────────────────────────────────────────────────────────
    $msgText                = New-Object System.Windows.Controls.TextBlock
    $msgText.Text           = $Message
    $msgText.TextWrapping   = 'Wrap'
    $msgText.MaxWidth       = 360
    $msgText.VerticalAlignment = 'Top'
    $msgText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Avd.Window.Fg')

    # ── Content row (icon + message, horizontal) ──────────────────────────────
    $contentRow             = New-Object System.Windows.Controls.StackPanel
    $contentRow.Orientation = 'Horizontal'
    $contentRow.Margin      = '20,20,20,16'
    [void]$contentRow.Children.Add($iconText)
    [void]$contentRow.Children.Add($msgText)

    # ── Button helper (same pattern as Show-RunCommandPicker) ─────────────────
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

    # ── Button bar ────────────────────────────────────────────────────────────
    $btnRow                     = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation         = 'Horizontal'
    $btnRow.HorizontalAlignment = 'Right'
    $btnRow.Margin              = '12,4,16,16'

    $script:_tdlgResult = $false   # default: Cancel/No/X

    # Primary (OK / Yes) button - always rightmost
    $btnPrimary           = New-Object System.Windows.Controls.Button
    $btnPrimary.Content   = if ($Buttons -eq 'YesNo') { 'Yes' } else { 'OK' }
    $btnPrimary.Width     = 90; $btnPrimary.Height = 30; $btnPrimary.Padding = '10,0'
    $btnPrimary.IsDefault = $true
    & $applyBtnStyle $btnPrimary 'Avd.Btn.Save.Bg' 'Avd.Btn.Save.Hover' 'Avd.Btn.Save.Press'
    $btnPrimary.Foreground = [System.Windows.Media.Brushes]::White
    $btnPrimary.Add_Click({ $script:_tdlgResult = $true; $win.Close() }.GetNewClosure())

    # Secondary (Cancel / No) button - shown for OKCancel and YesNo only
    if ($Buttons -ne 'OK') {
        $btnSecondary          = New-Object System.Windows.Controls.Button
        $btnSecondary.Content  = if ($Buttons -eq 'YesNo') { 'No' } else { 'Cancel' }
        $btnSecondary.Width    = 90; $btnSecondary.Height = 30; $btnSecondary.Padding = '10,0'
        $btnSecondary.Margin   = '0,0,8,0'
        $btnSecondary.IsCancel = $true
        & $applyBtnStyle $btnSecondary 'Avd.Btn.Cancel.Bg' 'Avd.Btn.Cancel.Hover' 'Avd.Btn.Cancel.Press'
        $btnSecondary.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Avd.Fg.Label')
        $btnSecondary.Add_Click({ $script:_tdlgResult = $false; $win.Close() }.GetNewClosure())
        [void]$btnRow.Children.Add($btnSecondary)
    }
    [void]$btnRow.Children.Add($btnPrimary)

    # ── Outer DockPanel ───────────────────────────────────────────────────────
    $outer = New-Object System.Windows.Controls.DockPanel
    $outer.LastChildFill = $true
    [System.Windows.Controls.DockPanel]::SetDock($btnRow, 'Bottom')
    [void]$outer.Children.Add($btnRow)
    [void]$outer.Children.Add($contentRow)

    $win.Content = $outer
    $win.ShowDialog() | Out-Null
    return $script:_tdlgResult
}

function Switch-DashboardTheme {
    param([bool]$Dark)
    $script:DarkTheme  = $Dark
    $script:_themeFile = if ($Dark) { 'dark' } else { 'light' }
    $_tc = Get-Content -Raw -Path "$PSScriptRoot\data\$script:_themeFile-theme.xaml" -ErrorAction Stop
    # Parse new theme into a temporary ResourceDictionary, then overwrite each key in
    # $window.Resources in-place. WPF fires DynamicResource change notifications for each
    # overwritten key, updating all {DynamicResource Avd.*} consumers immediately.
    $_rd = [System.Windows.Markup.XamlReader]::Parse("<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$_tc</ResourceDictionary>")
    foreach ($_key in @($_rd.Keys)) {
        $window.Resources[$_key] = $_rd[$_key]
    }

    # Push the same resource updates to every registered secondary window (Run Command,
    # Session Detail, etc.). Setting keys directly on the window's own Resources dictionary
    # overrides the stale injected MergedDictionary and fires DynamicResource notifications.
    foreach ($_sw in @($script:_themedWindows)) {
        if (-not $_sw -or -not $_sw.IsLoaded) { continue }
        foreach ($_key in @($_rd.Keys)) { $_sw.Resources[$_key] = $_rd[$_key] }
        # Update title bar chrome to match
        try {
            $_hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($_sw)).Handle
            $_v = [int]$Dark
            [void][DwmApiHelper]::DwmSetWindowAttribute($_hwnd, 20, [ref]$_v, 4)
        } catch {}
    }

    # Rebuild pool row style: BasedOn theme (hover/select) + _IsSecondary tint trigger
    $_poolBaseStyle = $window.TryFindResource('Avd.DataGridRow.Style')
    $_newStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridRow])
    if ($_poolBaseStyle) { $_newStyle.BasedOn = $_poolBaseStyle }
    $_secBrush = $window.TryFindResource('Avd.Secondary.Bg')
    $_secTrig  = New-Object System.Windows.DataTrigger
    $_secTrig.Binding = New-Object System.Windows.Data.Binding('[_IsSecondary]')
    $_secTrig.Value   = 'True'
    [void]$_secTrig.Setters.Add((New-Object System.Windows.Setter([System.Windows.Controls.DataGridRow]::BackgroundProperty, $_secBrush)))
    [void]$_newStyle.Triggers.Add($_secTrig)
    if ($script:PoolGrid) { $script:PoolGrid.RowStyle = $_newStyle }

    # SHGrid: use theme style directly (no extra triggers needed)
    if ($script:SHGrid) {
        $_shStyle = $window.TryFindResource('Avd.DataGridRow.Style')
        if ($_shStyle) { $script:SHGrid.RowStyle = $_shStyle }
    }

    # Force SHGrid column regeneration so metric cell colours reflect the new theme.
    # CellStyle trigger setters are frozen once applied; the only way to update them is
    # to make the DataGrid re-run AutoGeneratingColumn by briefly clearing ItemsSource.
    if ($script:SHGrid -and $script:SHGrid.ItemsSource) {
        $_shView = $script:SHGrid.ItemsSource
        $script:SHGrid.ItemsSource = $null
        $script:SHGrid.ItemsSource = $_shView
    }

    # Reset storage tile to current card background (next Azure Files refresh will re-apply state colours)
    if ($script:CardStorageBorder) {
        $script:CardStorageBorder.Background  = $window.Resources['Avd.Card.Bg']
        $script:CardStorageBorder.BorderBrush = $window.Resources['Avd.Border.Std']
    }

    # Flush WPF render pass so client area updates visually before DWM changes the title bar
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    # Update title bar
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $v = [int]$Dark
        [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
    } catch {}

    # Redraw monitoring canvas charts - they use hardcoded colours evaluated at draw time,
    # not DynamicResource, so must be explicitly redrawn when the theme changes.
    if ($script:_monSessionHistoryData) {
        Update-SessionHistoryChart -Canvas $script:monSessionHistoryCanvas `
            -SessionsData     $script:_monSessionHistoryData.Sessions `
            -DisconnectedData $script:_monSessionHistoryData.Disconnected `
            -TotalData        $script:_monSessionHistoryData.Total `
            -BinMinutes       $script:_monSessionHistoryBinMins
    }
    if ($script:_monWinlogonData -and $script:_monWinlogonData.Count -gt 0) {
        Update-WinlogonChart -Canvas $script:monWinlogonCanvas -StageData $script:_monWinlogonData
    }
}

Set-SplashStatus "Binding UI controls..." -Progress 95
$script:firstLoadComplete = $false

# Named control references
$script:StatusText    = $window.FindName("StatusText")
$script:CountdownText = $window.FindName("CountdownText")
$script:ConnectedAsText   = $window.FindName("ConnectedAsText")
$script:ConnectedAsText.Text = "Connected as: $($azContext.Account.Id)   |   Subscription: $($azContext.Subscription.Name)"
$script:RefreshButton      = $window.FindName("RefreshButton")
$script:SwitchConfigButton = $window.FindName("SwitchConfigButton")
if ($script:_availableConfigs.Count -ge 2) { $script:SwitchConfigButton.Visibility = 'Visible' }
$script:SwitchSubButton = $window.FindName("SwitchSubButton")
$script:SettingsButton = $window.FindName("SettingsButton")
# config.psd1 HideSettingsButton option hides the button entirely (no registry equivalent)
if ($script:HideSettingsButton) { $script:SettingsButton.Visibility = 'Collapsed' }
$script:AboutButton    = $window.FindName("AboutButton")
$script:PoolGrid          = $window.FindName("PoolGrid")
$script:RegionGrid        = $window.FindName("RegionGrid")
$script:MainTabControl     = $window.FindName("MainTabControl")
$script:DarkToggle         = $window.FindName("DarkToggle")
$script:DarkToggle.IsChecked = $script:DarkTheme
# Dark mode toggle - written to the global root key so the preference applies
# across all configs. The per-config subkey ($script:RegPath) is not used here.
$script:DarkToggle.Add_Checked({
    try { Set-ItemProperty -Path $script:GlobalRegPath -Name 'DarkTheme' -Value 1 } catch {}
    Switch-DashboardTheme $true
})
$script:DarkToggle.Add_Unchecked({
    try { Set-ItemProperty -Path $script:GlobalRegPath -Name 'DarkTheme' -Value 0 } catch {}
    Switch-DashboardTheme $false
})

# Collapse any tabs listed in HiddenTabs config. Collapsed tabs are fully
# removed from the tab strip - the user cannot see or navigate to them.
if ($script:HiddenTabs.Count -gt 0) {
    foreach ($tab in $script:MainTabControl.Items) {
        if ($tab.Header -in $script:HiddenTabs) {
            $tab.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }
}
$script:CardStorageBorder  = $window.FindName("CardStorageBorder")
$script:CardStorageIcon    = $window.FindName("CardStorageIcon")
$script:CardStorageText    = $window.FindName("CardStorageText")
$script:CardPools     = $window.FindName("CardPools")
$script:CardVMs       = $window.FindName("CardVMs")
$script:CardOn        = $window.FindName("CardOn")
$script:CardOff       = $window.FindName("CardOff")
$script:CardActive    = $window.FindName("CardActive")
$script:CardDisconn   = $window.FindName("CardDisconn")
$script:CardTotal          = $window.FindName("CardTotal")
$script:CardActiveBorder   = $window.FindName("CardActiveBorder")
$script:CardDisconnBorder  = $window.FindName("CardDisconnBorder")
$script:CardTotalBorder    = $window.FindName("CardTotalBorder")
$script:CardPoolsBorder    = $window.FindName("CardPoolsBorder")
$script:CardVMsBorder      = $window.FindName("CardVMsBorder")
$script:PerHostPoolTab     = $window.FindName("PerHostPoolTab")
$script:RefreshIntervalSeconds = $RefreshIntervalSeconds
$script:rgLocationCache        = @{}   # persists across refreshes - RG locations never change
$script:vmRgMap                = @{}   # persists across refreshes - VM name -> RG for fast RDP IP lookup
$script:gridWidthAutoSet       = $true    # disabled - no auto-resize on PoolGrid
$script:shWidthAutoSet         = $true   # disabled - no auto-resize on Session Hosts tab

Set-SplashStatus "Configuring grid styles and layout..." -Progress 96

# =============================================================================
# PoolGrid - hide _IsSecondary helper column and apply secondary-region row style
# =============================================================================

$script:PoolGrid.Add_AutoGeneratingColumn({
    param($s, $e)
    if ($e.Column.Header -in @('_IsSecondary', '_VMRG', '_RGVMDiff', '_ScalingPlanId')) { $e.Cancel = $true; return }
    # Hide RG VMs column when the feature is disabled - no data is collected so the column would be empty
    if (-not $script:ShowRGVMCount -and $e.Column.Header -eq 'RG VMs') { $e.Cancel = $true; return }
    if ($script:HiddenColumns.Count -gt 0 -and $e.Column.Header -in $script:HiddenColumns) { $e.Cancel = $true; return }
    $colName = [string]$e.Column.Header
    if ($colName -in @('VMs Available', 'VMs Not Available')) {
        $hdrTb = New-Object System.Windows.Controls.TextBlock
        $hdrTb.Text = switch ($colName) {
            'VMs Available'     { "VMs`nAvailable" }
            'VMs Not Available' { "VMs Not`nAvailable" }
        }
        $hdrTb.TextAlignment      = [System.Windows.TextAlignment]::Center
        $hdrTb.VerticalAlignment  = [System.Windows.VerticalAlignment]::Center
        $e.Column.Header = $hdrTb
    }

    # "RG VMs" column: red cell when count differs from Total VMs, transparent when they match.
    # BasedOn the global DataGridCell style so the centred ContentPresenter template is inherited.
    if ($colName -eq 'RG VMs') {
        $baseStyle = $s.FindResource([System.Windows.Controls.DataGridCell])
        $cellStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridCell])
        if ($baseStyle) { $cellStyle.BasedOn = $baseStyle }

        # Use DataTriggers exclusively - no default Background setter.
        # DataTriggers have higher WPF precedence than the inherited IsSelected property
        # Trigger from the base style, so red is preserved when the row is selected.
        # Add transparent triggers first (diff==0, empty), then red triggers for each
        # non-zero diff value. Later triggers win, so red takes effect whenever neither
        # transparent condition is active.

        # diff == "0" → transparent (counts match)
        $t0 = New-Object System.Windows.DataTrigger
        $t0.Binding = New-Object System.Windows.Data.Binding('[_RGVMDiff]')
        $t0.Value   = '0'
        [void]$t0.Setters.Add((New-Object System.Windows.Setter(
            [System.Windows.Controls.DataGridCell]::BackgroundProperty,
            [System.Windows.Media.Brushes]::Transparent)))
        [void]$cellStyle.Triggers.Add($t0)

        # RG VMs empty → transparent (host pool has no session hosts)
        $tEmpty = New-Object System.Windows.DataTrigger
        $tEmpty.Binding = New-Object System.Windows.Data.Binding('[RG VMs]')
        $tEmpty.Value   = ''
        [void]$tEmpty.Setters.Add((New-Object System.Windows.Setter(
            [System.Windows.Controls.DataGridCell]::BackgroundProperty,
            [System.Windows.Media.Brushes]::Transparent)))
        [void]$cellStyle.Triggers.Add($tEmpty)

        # Non-zero diff → red. WPF DataTriggers can't express "!= value" so enumerate
        # the realistic range. These are added after the transparent triggers so they win.
        $redBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xFF, 0x6B, 0x6B))
        foreach ($diffVal in (@(1..30) + @(-30..-1))) {
            $tRed = New-Object System.Windows.DataTrigger
            $tRed.Binding = New-Object System.Windows.Data.Binding('[_RGVMDiff]')
            $tRed.Value   = [string]$diffVal
            [void]$tRed.Setters.Add((New-Object System.Windows.Setter(
                [System.Windows.Controls.DataGridCell]::BackgroundProperty, $redBrush)))
            [void]$cellStyle.Triggers.Add($tRed)
        }

        $e.Column.CellStyle = $cellStyle
    }
})

# Build row style: BasedOn theme (hover/select) + _IsSecondary tint trigger
$poolRowStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridRow])
$_poolBase = $script:MainWindow.TryFindResource('Avd.DataGridRow.Style')
if ($_poolBase) { $poolRowStyle.BasedOn = $_poolBase }
$secondaryTrigger = New-Object System.Windows.DataTrigger
$secondaryTrigger.Binding = New-Object System.Windows.Data.Binding('[_IsSecondary]')
$secondaryTrigger.Value   = 'True'
[void]$secondaryTrigger.Setters.Add(
    (New-Object System.Windows.Setter(
        [System.Windows.Controls.DataGridRow]::BackgroundProperty,
        $script:MainWindow.TryFindResource('Avd.Secondary.Bg')
    ))
)
[void]$poolRowStyle.Triggers.Add($secondaryTrigger)
$script:PoolGrid.RowStyle = $poolRowStyle

# =============================================================================
# PoolGrid - Context menu: Enable / Disable Scaling Plan
# =============================================================================

function Invoke-PoolScalingPlanToggle {
    param([string]$HostPoolName, [string]$ScalingPlanId, [bool]$Enable)

    $parts  = $ScalingPlanId.Split('/')
    $spSub  = $parts[2]
    $spRg   = $parts[4]
    $spName = $parts[-1]
    $verb   = if ($Enable) { 'Enabling' } else { 'Disabling' }
    $noun   = if ($Enable) { 'enabled'  } else { 'disabled'  }

    $current = Invoke-ArmRestMethod `
        -Path "/subscriptions/$spSub/resourceGroups/$spRg/providers/Microsoft.DesktopVirtualization/scalingPlans/$spName" `
        -Token $script:armToken -ApiVersion $script:ApiVersions.DesktopVirtualization -FullResponse

    if (-not $current -or -not $current.properties.hostPoolReferences) {
        Show-ThemedDialog -Message "Could not retrieve scaling plan '$spName'." -Title 'Scaling Plan' -Icon 'Error'
        return
    }

    $refs = @($current.properties.hostPoolReferences | ForEach-Object {
        $hpKey = $_.hostPoolArmPath.Split('/')[-1]
        [PSCustomObject]@{
            hostPoolArmPath    = $_.hostPoolArmPath
            scalingPlanEnabled = if ($hpKey -eq $HostPoolName) { $Enable } else { [bool]$_.scalingPlanEnabled }
        }
    })

    $body = @{ properties = @{ hostPoolReferences = $refs } }

    $resp = Invoke-ArmRestMethod -Method PATCH `
        -Path "/subscriptions/$spSub/resourceGroups/$spRg/providers/Microsoft.DesktopVirtualization/scalingPlans/$spName" `
        -Token $script:armToken -ApiVersion $script:ApiVersions.DesktopVirtualization `
        -Body $body -FullResponse

    if ($resp -and $resp.id) {
        $selItem = $script:PoolGrid.SelectedItem
        if ($selItem) {
            $selItem['Scaling Plan'] = if ($Enable) { 'Yes' } else { 'No' }
            $script:PoolGrid.Items.Refresh()
        }
        Show-ThemedDialog -Message "Scaling plan '$spName' $noun for host pool '$HostPoolName'." -Title "$verb Scaling Plan" -Icon 'Information'
    } else {
        Show-ThemedDialog -Message "Failed to update scaling plan '$spName'. Check token/permissions." -Title 'Scaling Plan' -Icon 'Error'
    }
}

# =============================================================================
# PoolGrid - Context menu: Private Endpoints
# =============================================================================

# Show-PrivateEndpoints
# ---------------------
# Displays a modal popup listing all private endpoint connections attached to
# the specified AVD host pool, including the real Azure region of each PE.
#
# PE data is sourced from $script:hpPrivateEndpointDetails, populated during the
# refresh cycle in two phases:
#   Phase 1 - PE connection names read from $hp.properties.privateEndpointConnections
#   Phase 2 - PE resource locations resolved via parallel GET calls against each
#              PE's ARM resource id (properties.privateEndpoint.id), using the
#              Microsoft.Network API version 2024-01-01
#
# No additional API calls are made at popup time - all data is pre-fetched.
#
# The PE connection name is the Azure sub-resource name (e.g. "mypool-pe1.abc123")
# matching what is shown in the Azure Portal under:
#   Host Pool > Networking > Private endpoint connections
function Show-PrivateEndpoints {
    param([string]$HostPool)

    # Look up pre-fetched PE details for this host pool
    $details = $script:hpPrivateEndpointDetails[$HostPool]
    if (-not $details -or $details.Count -eq 0) {
        # Either no PEs are configured, or data has not loaded yet
        Show-ThemedDialog -Message "No private endpoints found for $HostPool." -Title 'Private Endpoints' -Icon 'Information'
        return
    }

    # Build a simple modal window with a single-column DataGrid listing PE names
    $popXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Private Endpoints - $HostPool"
        Width="560" Height="240"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        Background="#F5F6FA" FontFamily="Segoe UI">
    <DockPanel Margin="12">
        <DataGrid x:Name="PE_Grid"
                  AutoGenerateColumns="False" IsReadOnly="True"
                  CanUserSortColumns="True" GridLinesVisibility="Horizontal"
                  Background="White" RowBackground="White"
                  AlternatingRowBackground="#F0F4FA"
                  BorderThickness="1" BorderBrush="#CCC"
                  HeadersVisibility="Column" SelectionMode="Single">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Name"   Binding="{Binding Name}"   Width="*"/>
                <DataGridTextColumn Header="Region" Binding="{Binding Region}" Width="120"/>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
"@
    $popReader = [System.Xml.XmlNodeReader]::new([xml]$popXaml)
    $popWin    = [System.Windows.Markup.XamlReader]::Load($popReader)
    $popWin.Owner = $script:MainWindow

    # Bind the pre-fetched PE detail list to the grid
    $peGrid = $popWin.FindName('PE_Grid')
    $peGrid.ItemsSource = $details

    [void]$popWin.ShowDialog()
}

# =============================================================================
# PoolGrid - Context menu: Scaling Plan History
# =============================================================================

function Show-ScalingPlanHistory {
    param([string]$HostPool)

    $lawId = $script:LawWorkspaceResourceId
    if (-not $lawId) {
        Show-ThemedDialog -Message 'Log Analytics workspace is not configured.' -Title 'Scaling Plan History' -Icon 'Warning'
        return
    }

    # Load KQL from file and substitute the host pool name placeholder
    $kqlFile = Join-Path $PSScriptRoot "data\kql\scaling-plan-history.kql"
    $kql = (Get-Content $kqlFile -Raw) -replace '\{\{HostPool\}\}', $HostPool
    # Strip KQL comment lines before sending to the REST API
    $kql = ($kql -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"

    # ── Build popup window ────────────────────────────────────────────────────
    $popXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Scaling Plan History - $HostPool (Last 24h)"
        Width="1080" Height="460"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        Background="#F5F6FA" FontFamily="Segoe UI">
    <DockPanel Margin="12">
        <TextBlock x:Name="SP_Status" DockPanel.Dock="Bottom"
                   FontSize="11" Foreground="#555" Margin="0,6,0,0"
                   Text="Loading..."/>
        <DataGrid x:Name="SP_Grid" Visibility="Collapsed"
                  AutoGenerateColumns="False" IsReadOnly="True"
                  CanUserSortColumns="True" GridLinesVisibility="Horizontal"
                  Background="White" RowBackground="White"
                  AlternatingRowBackground="#F0F4FA"
                  BorderThickness="1" BorderBrush="#CCC"
                  HeadersVisibility="Column" SelectionMode="Single">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Evaluation Time" Binding="{Binding [EvaluationTime]}" Width="Auto">
                    <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                            <Setter Property="HorizontalAlignment" Value="Center"/>
                            <Setter Property="VerticalAlignment"   Value="Center"/>
                        </Style>
                    </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Host Pool"       Binding="{Binding [HostPool]}"       Width="Auto">
                    <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                            <Setter Property="HorizontalAlignment" Value="Center"/>
                            <Setter Property="VerticalAlignment"   Value="Center"/>
                        </Style>
                    </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Schedule"        Binding="{Binding [Schedule]}"       Width="Auto">
                    <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                            <Setter Property="HorizontalAlignment" Value="Center"/>
                            <Setter Property="VerticalAlignment"   Value="Center"/>
                        </Style>
                    </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Phase"           Binding="{Binding [Phase]}"          Width="Auto">
                    <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                            <Setter Property="HorizontalAlignment" Value="Center"/>
                            <Setter Property="VerticalAlignment"   Value="Center"/>
                        </Style>
                    </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Reason"          Binding="{Binding [Reason]}"         Width="*">
                    <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                            <Setter Property="TextWrapping" Value="Wrap"/>
                        </Style>
                    </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
"@

    $popWin   = [Windows.Markup.XamlReader]::Parse($popXaml)
    $spGrid   = $popWin.FindName('SP_Grid')
    $spStatus = $popWin.FindName('SP_Status')
    $popWin.Owner = $window
    try { Set-WindowIcon -Window $popWin -IconPath (Join-Path $PSScriptRoot 'data\avd-dashboard.ico') } catch {}
    $popWin.Show()

    # Force a render pass so "Loading..." is visible before the blocking REST call
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [Action]{ $frame.Continue = $false }
    ) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)

    # ── Run LAW query (window is now painted, blocking is fine) ───────────────
    try {
        $resp = Invoke-LawQuery -Kql $kql -Timespan 'P1D' `
                    -WorkspaceResourceId $lawId `
                    -QueryBaseUrl $script:LawQueryBaseUrl

        $table = $resp.tables[0]
        if (-not $table -or $table.rows.Count -eq 0) {
            $spStatus.Text = "No autoscale evaluation events found for '$HostPool' in the last 24 hours."
            return
        }

        # Build column index lookup - tolerates PS5.1 (.name) and PS7 (.ColumnName)
        $cols      = @($table.columns | ForEach-Object { $n = [string]$_.name; if (-not $n) { $n = [string]$_.ColumnName }; $n })
        $colsLower = @($cols | ForEach-Object { $_.ToLower() })
        $idxTime     = [array]::IndexOf($colsLower, 'evaluationtime')
        $idxHostPool = [array]::IndexOf($colsLower, 'hostpool')
        $idxSched    = [array]::IndexOf($colsLower, 'schedule')
        $idxPhase    = [array]::IndexOf($colsLower, 'phase')
        $idxReason   = [array]::IndexOf($colsLower, 'reason')

        $dt = New-Object System.Data.DataTable
        [void]$dt.Columns.Add('EvaluationTime')
        [void]$dt.Columns.Add('HostPool')
        [void]$dt.Columns.Add('Schedule')
        [void]$dt.Columns.Add('Phase')
        [void]$dt.Columns.Add('Reason')

        foreach ($r in $table.rows) {
            $dr = $dt.NewRow()
            # EvaluationTime comes from LAW as UTC - convert to local so BST users
            # see the correct time rather than UTC (1h behind in BST).
            if ($idxTime -ge 0 -and $r[$idxTime]) {
                try {
                    $utcDt = [datetime]::ParseExact([string]$r[$idxTime], 'yyyy-MM-dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::AssumeUniversal)
                    $dr['EvaluationTime'] = $utcDt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
                } catch {
                    $dr['EvaluationTime'] = [string]$r[$idxTime]
                }
            } else { $dr['EvaluationTime'] = '-' }
            $dr['HostPool'] = if ($idxHostPool -ge 0) { [string]$r[$idxHostPool] } else { '-' }
            $dr['Schedule'] = if ($idxSched    -ge 0) { [string]$r[$idxSched]    } else { '-' }
            $dr['Phase']    = if ($idxPhase    -ge 0) { [string]$r[$idxPhase]    } else { '-' }
            $dr['Reason']   = if ($idxReason   -ge 0) { [string]$r[$idxReason]   } else { '-' }
            [void]$dt.Rows.Add($dr)
        }

        $spGrid.ItemsSource = $dt.DefaultView
        $spGrid.Visibility  = 'Visible'
        $spStatus.Text = "$($dt.Rows.Count) evaluation event(s) in the last 24 hours."

    } catch {
        $spStatus.Text = "Error querying Log Analytics: $_"
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ScalingHistory] Error: $_`r`n") } catch {} }
    }
}

function Show-StartVmHistory {
    param([string]$HostPool, [string]$VmRg)

    $avdAppId = '9cdead84-a844-4324-93f2-b2e6bb768d07'  # Azure Virtual Desktop service principal (fixed across all tenants)

    if (-not $VmRg) {
        Show-ThemedDialog -Message 'No session host VM resource group available for this host pool.' -Title 'Start VM History' -Icon 'Warning'
        return
    }

    $subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }

    $popXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Start VM History - $HostPool (Last 24h)"
        Width="820" Height="460"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        Background="#F5F6FA" FontFamily="Segoe UI">
    <DockPanel Margin="12">
        <TextBlock x:Name="SV_Status" DockPanel.Dock="Bottom"
                   FontSize="11" Foreground="#555" Margin="0,6,0,0"
                   Text="Loading..."/>
        <DataGrid x:Name="SV_Grid" Visibility="Collapsed"
                  AutoGenerateColumns="False" IsReadOnly="True"
                  CanUserSortColumns="True" GridLinesVisibility="Horizontal"
                  Background="White" RowBackground="White"
                  AlternatingRowBackground="#F0F4FA"
                  BorderThickness="1" BorderBrush="#CCC"
                  HeadersVisibility="Column" SelectionMode="Single">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Start Time" Binding="{Binding [StartTime]}" Width="Auto">
                    <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                            <Setter Property="HorizontalAlignment" Value="Center"/>
                            <Setter Property="VerticalAlignment"   Value="Center"/>
                        </Style>
                    </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="VM Name" Binding="{Binding [VMName]}" Width="Auto">
                    <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                            <Setter Property="HorizontalAlignment" Value="Center"/>
                            <Setter Property="VerticalAlignment"   Value="Center"/>
                        </Style>
                    </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Operation" Binding="{Binding [Operation]}" Width="Auto">
                    <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                            <Setter Property="HorizontalAlignment" Value="Center"/>
                            <Setter Property="VerticalAlignment"   Value="Center"/>
                        </Style>
                    </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Status" Binding="{Binding [Status]}" Width="Auto">
                    <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                            <Setter Property="HorizontalAlignment" Value="Center"/>
                            <Setter Property="VerticalAlignment"   Value="Center"/>
                        </Style>
                    </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Initiated By" Binding="{Binding [Caller]}" Width="*"/>
            </DataGrid.Columns>
        </DataGrid>
    </DockPanel>
</Window>
"@

    $popWin   = [Windows.Markup.XamlReader]::Parse($popXaml)
    $svGrid   = $popWin.FindName('SV_Grid')
    $svStatus = $popWin.FindName('SV_Status')
    $popWin.Owner = $window
    $popWin.Show()

    # Build URL and grab token on UI thread before handing off to runspace
    $startTime = (Get-Date).ToUniversalTime().AddHours(-24).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $apiFilter = "`$filter=eventTimestamp ge '$startTime' and resourceGroupName eq '$VmRg'&`$top=500"
    $apiUrl    = "https://management.azure.com/subscriptions/$subId/providers/microsoft.insights/eventtypes/management/values?$apiFilter&api-version=2015-04-01"
    $tok       = Get-ArmToken

    # Run the HTTP call in a background runspace so the UI thread stays responsive
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $url = $args[0]; $token = $args[1]
        $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -ErrorAction Stop
        $resp.value
    }).AddArgument($apiUrl).AddArgument($tok)
    $handle = $ps.BeginInvoke()

    # Poll every 300 ms on the dispatcher; update UI when done
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        try {
            $events = @($ps.EndInvoke($handle))
        } catch {
            $svStatus.Text = "Error querying Activity Log: $_"
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [StartVMHistory] Error: $_`r`n") } catch {} }
            $ps.Dispose(); $rs.Dispose()
            return
        }
        $ps.Dispose(); $rs.Dispose()

        # Keep only AVD-initiated final-state rows - filters out manual starts and intermediate Accepted/Started duplicates
        $startEvents = @($events | Where-Object {
            ([string]$_.operationName.localizedValue -like '*Start Virtual Machine*' -or
             [string]$_.operationName.value          -like '*virtualMachines/start*') -and
            [string]$_.status.value -in @('Succeeded', 'Failed') -and
            [string]$_.claims.appid -eq $avdAppId
        })

        if ($startEvents.Count -eq 0) {
            $svStatus.Text = "No Start VM operations found in resource group '$VmRg' in the last 24 hours."
            return
        }

        $dt = New-Object System.Data.DataTable
        [void]$dt.Columns.Add('StartTime')
        [void]$dt.Columns.Add('VMName')
        [void]$dt.Columns.Add('Operation')
        [void]$dt.Columns.Add('Status')
        [void]$dt.Columns.Add('Caller')

        foreach ($ev in ($startEvents | Sort-Object { $_.eventTimestamp } -Descending)) {
            $dr = $dt.NewRow()
            $dr['StartTime'] = try { ([datetime]$ev.eventTimestamp).ToString('yyyy-MM-dd HH:mm:ss') } catch { [string]$ev.eventTimestamp }
            $dr['VMName']    = ([string]$ev.resourceId).Split('/')[-1]
            $dr['Operation'] = if ([string]$ev.operationName.localizedValue) { [string]$ev.operationName.localizedValue } else { [string]$ev.operationName.value }
            $dr['Status']    = [string]$ev.status.value
            $dr['Caller']    = 'Azure Virtual Desktop'
            [void]$dt.Rows.Add($dr)
        }

        $svGrid.ItemsSource = $dt.DefaultView
        $svGrid.Visibility  = 'Visible'
        $svStatus.Text = "$($dt.Rows.Count) Start VM operation(s) in the last 24 hours (resource group: $VmRg)."
    }.GetNewClosure())
    $timer.Start()
}

# ── PoolGrid context menu wiring ───────────────────────────────────────────
$poolCtxMenu   = New-Object System.Windows.Controls.ContextMenu
$menuPoolToggleScaling     = New-Object System.Windows.Controls.MenuItem
$menuPoolToggleScaling.Header = "Toggle Scaling Plan"
[void]$poolCtxMenu.Items.Add($menuPoolToggleScaling)
$menuPoolSep1    = New-Object System.Windows.Controls.Separator
[void]$poolCtxMenu.Items.Add($menuPoolSep1)
$menuPoolScale = New-Object System.Windows.Controls.MenuItem
$menuPoolScale.Header = "Scaling Plan History (24h)"
[void]$poolCtxMenu.Items.Add($menuPoolScale)
$menuPoolStartVm = New-Object System.Windows.Controls.MenuItem
$menuPoolStartVm.Header = "Start VM History (24h)"
[void]$poolCtxMenu.Items.Add($menuPoolStartVm)
# "Private Endpoints" menu item - opens a popup listing all PE connection names
# for the selected host pool. The PE data is pre-fetched during the refresh cycle
# from $hp.properties.privateEndpointConnections and stored in
# $script:hpPrivateEndpointDetails (keyed by host pool name).
$menuPoolPrivateEndpoints = New-Object System.Windows.Controls.MenuItem
$menuPoolPrivateEndpoints.Header = "Private Endpoints"
[void]$poolCtxMenu.Items.Add($menuPoolPrivateEndpoints)

# Select the row under the cursor on right-click (mirrors Session Hosts pattern)
$script:PoolGrid.Add_PreviewMouseRightButtonDown({
    $node = $_.OriginalSource
    while ($null -ne $node -and $node -isnot [System.Windows.Controls.DataGridRow]) {
        $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    if ($null -ne $node -and -not $node.IsSelected) {
        $script:PoolGrid.SelectedItems.Clear()
        $node.IsSelected = $true
    }
}.GetNewClosure())

# Enable menu item whenever a row is selected
$script:PoolGrid.Add_ContextMenuOpening({
    $sel    = @($script:PoolGrid.SelectedItems)
    $hasOne = $sel.Count -gt 0 -and $null -ne $sel[0]
    $menuPoolScale.IsEnabled              = $hasOne
    $menuPoolStartVm.IsEnabled            = $hasOne
    $menuPoolPrivateEndpoints.IsEnabled   = $hasOne
    $hasScalingPlan = $hasOne -and -not [string]::IsNullOrWhiteSpace([string]$sel[0]['_ScalingPlanId'])
    $scalingEnabled = $hasOne -and ([string]$sel[0]['Scaling Plan'] -eq 'Yes')
    $menuPoolToggleScaling.IsEnabled = $hasScalingPlan
    $menuPoolToggleScaling.Header    = if ($scalingEnabled) { 'Disable Scaling Plan' } else { 'Enable Scaling Plan' }
}.GetNewClosure())

$menuPoolScale.Add_Click({
    $sel = @($script:PoolGrid.SelectedItems)
    if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
    Show-ScalingPlanHistory -HostPool ([string]$sel[0]['Host Pool'])
}.GetNewClosure())

$menuPoolStartVm.Add_Click({
    $sel = @($script:PoolGrid.SelectedItems)
    if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
    Show-StartVmHistory -HostPool ([string]$sel[0]['Host Pool']) -VmRg ([string]$sel[0]['_VMRG'])
}.GetNewClosure())

$menuPoolToggleScaling.Add_Click({
    $sel = @($script:PoolGrid.SelectedItems)
    if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
    $enable = ([string]$sel[0]['Scaling Plan'] -ne 'Yes')
    Invoke-PoolScalingPlanToggle -HostPoolName ([string]$sel[0]['Host Pool']) -ScalingPlanId ([string]$sel[0]['_ScalingPlanId']) -Enable $enable
}.GetNewClosure())

# Opens the Private Endpoints popup for the selected host pool row
$menuPoolPrivateEndpoints.Add_Click({
    $sel = @($script:PoolGrid.SelectedItems)
    if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
    Show-PrivateEndpoints -HostPool ([string]$sel[0]['Host Pool'])
}.GetNewClosure())

$script:PoolGrid.ContextMenu = $poolCtxMenu

# =============================================================================
# Initialise tab modules
# =============================================================================

Initialize-SessionHostsTab  -Window $window -ContextFile $contextFile -SubscriptionId $subscriptionId -HpPool $script:hpPool
Initialize-SessionInfoTab   -Window $window
Initialize-AzureFilesTab    -Window $window -ContextFile $contextFile -SubscriptionId $subscriptionId
Initialize-MonitoringTab    -Window $window
Initialize-ImagesTab         -Window $window -ContextFile $contextFile -SubscriptionId $subscriptionId
Initialize-InfrastructureTab -Window $window -ContextFile $contextFile -SubscriptionId $subscriptionId
Initialize-AzureDevOpsTab   -Window $window
Initialize-SessionDetail

# Wire up the Session Hosts tab visit flag.
# The Session Hosts data load is intentionally deferred until the user first
# clicks the tab - loading it at startup wastes API calls when the user may
# never need it in the current session. $script:vmTabVisited is checked by
# Invoke-SessionHostsTabTimer's first-run gate in tab-sessionhosts.ps1.
$script:MainTabControl.Add_SelectionChanged({
    if ($script:MainTabControl.SelectedItem -eq $script:SessionHostsTab) {
        $script:vmTabVisited = $true
    }
    if ($script:MainTabControl.SelectedItem -eq $script:AzureDevOpsTab) {
        $script:adoTabVisited = $true
    }
})

# =============================================================================
# UI Update Function (always called on the Dispatcher / UI thread)
# =============================================================================

function Update-UI {
    param([PSCustomObject]$Data)

    # On the very first data load, close the splash and bring the main window forward
    if (-not $script:firstLoadComplete) {
        $script:firstLoadComplete = $true
        if ($splashWin.IsVisible) { $splashWin.Close() }
        try {
            $conHwnd = [ConsoleHelper]::GetConsoleWindow()
            if ($conHwnd -ne [IntPtr]::Zero) { [void][ConsoleHelper]::ShowWindow($conHwnd, 0) }
        } catch {}
        $window.Activate()
        $window.Topmost = $true
        $window.Topmost = $false
        $window.Focus()
    }

    $script:lastData = $Data   # cache for card click handlers

    # Merge any newly discovered RG locations into the persistent cache
    if ($Data.NewRgLocations) {
        foreach ($kv in $Data.NewRgLocations.GetEnumerator()) {
            $script:rgLocationCache[$kv.Key] = $kv.Value
        }
    }
    # Merge VM -> RG map for fast RDP IP resolution
    if ($Data.VmRgMap) {
        foreach ($kv in $Data.VmRgMap.GetEnumerator()) {
            $script:vmRgMap[$kv.Key] = $kv.Value
        }
    }
    # Store PE details on the main thread so Show-PrivateEndpoints can read them.
    # The map originates in the background runspace ($dataScript) and is carried
    # here via the Data return object - direct $script: writes from the runspace
    # are invisible to the main thread.
    if ($Data.PrivateEndpointDetails) {
        $script:hpPrivateEndpointDetails = $Data.PrivateEndpointDetails
    }
    $ts = $Data.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
    $script:StatusText.Text = "Last updated : $ts"

    $script:CardPools.Text   = $Data.HostPools
    $script:CardVMs.Text     = $Data.TotalVMs
    $script:CardOn.Text      = $Data.OnVMs
    $script:CardOff.Text     = $Data.OffVMs
    $script:CardActive.Text  = $Data.Active
    $script:CardDisconn.Text = $Data.Disconnected
    $script:CardTotal.Text   = $Data.TotalSessions

    # Build pool DataTable - add hidden _IsSecondary flag for row highlighting
    $poolDt = ConvertTo-DataTable -Objects @($Data.Results)
    if (-not $poolDt.Columns.Contains('_IsSecondary')) {
        $poolDt.Columns.Add('_IsSecondary') | Out-Null
    }
    foreach ($row in $poolDt.Rows) {
        $inSecondary = $script:SecondaryRegionHighlight -and
                       $script:SecondaryRegions.Count -gt 0 -and
                       ([string]$row['VM Region']) -in $script:SecondaryRegions
        $hasSessions = [int]$row['Total Sessions'] -gt 0
        $row['_IsSecondary'] = ($inSecondary -and $hasSessions).ToString()
    }
    $script:PoolGrid.ItemsSource = $poolDt.DefaultView

    # AutoGeneratingColumn cancels the RG VMs column when ShowRGVMCount is $false,
    # but only works on the first ItemsSource assignment. On subsequent refreshes the
    # column already exists, so visibility must be set directly on the column object.
    foreach ($col in $script:PoolGrid.Columns) {
        if ($col.Header -eq 'RG VMs') {
            $col.Visibility = if ($script:ShowRGVMCount) { 'Visible' } else { 'Collapsed' }
            break
        }
    }

    $script:RegionGrid.ItemsSource = (ConvertTo-DataTable -Objects @($Data.RegionSummary)).DefaultView

    # On first load, auto-fit window width to the PoolGrid so all visible
    # columns fit without a horizontal scrollbar. The Session Hosts tab runs
    # its own independent refresh (like Infrastructure) so its grid is not
    # measured here.
    if (-not $script:gridWidthAutoSet) {
        $window.Dispatcher.BeginInvoke([Action]{
            $poolWidth = 0
            foreach ($col in $script:PoolGrid.Columns) { $poolWidth += $col.ActualWidth }
            if ($poolWidth -gt 0) {
                # 90px covers window chrome borders + TabControl border + scrollbar + small buffer
                $desired = $poolWidth + 90
                $maxW    = [System.Windows.SystemParameters]::WorkArea.Width
                $window.Width = [Math]::Max($window.MinWidth,
                                            [Math]::Min([Math]::Ceiling($desired), $maxW))
                $script:gridWidthAutoSet = $true
            }
        }, [System.Windows.Threading.DispatcherPriority]::Background)
    }
}

# =============================================================================
# Background Refresh  (data collected in runspace, result marshalled to UI thread)
# =============================================================================

$script:bgHandle       = $null
$script:bgPS           = $null
$script:nextRefreshAt  = [DateTime]::Now   # trigger immediate first load
$script:fetchStartTime = [DateTime]::MinValue
Set-SplashStatus "Preparing to query Azure..." -Progress 98

# =============================================================================
# Master Timer - the heartbeat of the dashboard
#
# Runs every 1 second on the WPF dispatcher (UI) thread. Each tick it:
#   1. Checks if a background refresh is running (bgHandle) - if so, polls for
#      completion and calls Update-UI with the result when done.
#   2. If no refresh is running, updates the countdown display and fires a new
#      refresh when the interval expires.
#   3. Also ticks tab-specific timers (Session Hosts, Azure Files, Infrastructure)
#      and the Run Command completion poller.
#
# The refresh cycle flow:
#   Timer tick -> Get-ArmToken (cached) -> inject vars into bgRunspace ->
#   BeginInvoke($dataScript) -> [runs in background: REST queries via pools] ->
#   next tick: EndInvoke -> Update-UI on dispatcher thread -> schedule next refresh
# =============================================================================

$script:masterTimer          = New-Object System.Windows.Threading.DispatcherTimer
$script:masterTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:masterTimer.Add_Tick({

    # ---- If a refresh is running, check whether it has finished ----
    if ($script:bgHandle) {
        if (-not $script:bgHandle.IsCompleted) {
            $script:CountdownText.Text = "Refreshing..."
            if (-not $script:firstLoadComplete -and $splashWin -and $splashWin.IsVisible -and
                $script:fetchStartTime -gt [DateTime]::MinValue) {
                $elapsed = ([DateTime]::Now - $script:fetchStartTime).TotalSeconds
                $splashMsg = if     ($elapsed -lt 3)  { "Querying host pools, workspaces and scaling plans..." }
                             elseif ($elapsed -lt 8)  { "Fetching session hosts and user session data..." }
                             elseif ($elapsed -lt 15) { "Resolving VM regions and building results..." }
                             else                     { "Still loading - please wait..." }
                Set-SplashStatus $splashMsg -Progress 99
            }
            return
        }

        # Refresh finished - collect result
        $handle = $script:bgHandle
        $ps     = $script:bgPS
        $script:bgHandle = $null
        $script:bgPS     = $null

        try {
            $data = $ps.EndInvoke($handle)
            if ($data) {
                Update-UI -Data $data
            } else {
                $script:StatusText.Text = "No data returned - check authentication"
            }
        }
        catch {
            Write-Log "ERROR [Main Refresh] $_"
            # Close the splash screen before showing any MessageBox.
            # If the first data load fails the splash is still the foreground window
            # and will sit on top of the dialog. Closing it first and activating the
            # main window ensures the dialog appears centred over the dashboard.
            if ($splashWin -and $splashWin.IsVisible) {
                $splashWin.Dispatcher.Invoke([Action]{ $splashWin.Close() },
                    [System.Windows.Threading.DispatcherPriority]::Send)
            }
            $window.Activate()
            $window.Topmost = $true
            $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
            $window.Topmost = $false
            $errStr = "$_"
            if ($errStr -match 'AuthorizationFailed|does not have.*permission|does not have.*access|403|Forbidden|unauthorized' -or
                $errStr -match 'The client.*does not have authorization') {
                $script:StatusText.Text = "Access denied - click Switch Subscription to choose one you have permissions on"
                Show-ThemedDialog -Message "The signed-in account does not have permission to read this subscription.`n`nAccount: $($script:azAccountId)`nSubscription: $($azContext.Subscription.Name)`n`nPlease ensure the account has at least Reader role on the subscription, or use Switch Subscription to select a different one." -Title 'Subscription Access Denied' -Icon 'Warning'
            } elseif ($errStr -match 'InvalidSubscriptionId|provided subscription.*identifier|subscription.*is not.*valid|SubscriptionNotFound') {
                $script:StatusText.Text = "Invalid subscription - use Switch Subscription to select a valid one"
                Show-ThemedDialog -Message "The selected subscription could not be found or is not accessible.`n`nThis usually means:`n  - The subscription no longer exists`n  - Your account does not have access to it`n  - The subscription ID stored in settings is incorrect`n`nUse the Switch Subscription button to select a valid subscription." -Title 'Invalid Subscription' -Icon 'Warning'
            } else {
                $script:StatusText.Text = "Refresh error: $_"
            }
        }
        finally {
            try { $ps.Dispose() } catch {}
            $script:nextRefreshAt = [DateTime]::Now.AddSeconds($script:RefreshIntervalSeconds)
        }
        return
    }

    # ---- No job running - update countdown or fire a new job ----
    $remaining = ($script:nextRefreshAt - [DateTime]::Now).TotalSeconds
    if ($remaining -le 0) {
        $script:CountdownText.Text = "Refreshing..."
        $script:nextRefreshAt      = [DateTime]::Now.AddSeconds($script:RefreshIntervalSeconds + 9999)

        # Inject variables into bgRunspace before BeginInvoke.
        # SessionStateProxy.SetVariable writes directly into the runspace's scope,
        # making these available as top-level variables ($ArmToken, $SubId, etc.)
        # inside $dataScript. This is the ONLY safe way to pass data into a
        # persistent runspace between invocations.
        $_subId   = if ($script:currentSubscriptionId)   { $script:currentSubscriptionId }   else { $subscriptionId }
        $_subName = if ($script:currentSubscriptionName) { $script:currentSubscriptionName } else { $azContext.Subscription.Name }
        # Refresh ARM token before each dispatch (cached unless near expiry).
        # This token is passed into the runspace and forwarded to all pool threads.
        $script:armToken = Get-ArmToken
        $script:bgRunspace.SessionStateProxy.SetVariable("ArmToken",           $script:armToken)
        $script:bgRunspace.SessionStateProxy.SetVariable("SubId",              $_subId)
        $script:bgRunspace.SessionStateProxy.SetVariable("SubscriptionName",   $_subName)
        $script:bgRunspace.SessionStateProxy.SetVariable("ExcludedPoolsCsv",   ($script:ExcludedPools -join ','))
        $script:bgRunspace.SessionStateProxy.SetVariable("AvdIncludeRGsCsv",   ($script:AvdIncludeRGs -join ','))
        $script:bgRunspace.SessionStateProxy.SetVariable("AvdExcludeRGsCsv",   ($script:AvdExcludeRGs -join ','))
        $script:bgRunspace.SessionStateProxy.SetVariable("RgLocationCache",    $script:rgLocationCache)
        $script:bgRunspace.SessionStateProxy.SetVariable("LowPriorityPattern", ($script:LowPriorityHostPoolPatterns -join '|'))
        $script:bgRunspace.SessionStateProxy.SetVariable("HostGroupPatternA",  $script:HostGroupPatterns.A)
        $script:bgRunspace.SessionStateProxy.SetVariable("HostGroupPatternB",  $script:HostGroupPatterns.B)
        $script:bgRunspace.SessionStateProxy.SetVariable("HpPool",             $script:hpPool)   # persistent pool
        $script:bgRunspace.SessionStateProxy.SetVariable("MetaPool",           $script:metaPool) # persistent pool
        $script:bgRunspace.SessionStateProxy.SetVariable("MaxRgLookup",        $RunspaceMaxRgLookup)
        $script:bgRunspace.SessionStateProxy.SetVariable("RestHelperDef",      $script:restHelperDef)
        $script:bgRunspace.SessionStateProxy.SetVariable("LogFile",            $script:LogFile)
        $script:bgRunspace.SessionStateProxy.SetVariable("ShowRGVMCount",      $script:ShowRGVMCount)

        $script:bgPS          = [System.Management.Automation.PowerShell]::Create()
        $script:bgPS.Runspace = $script:bgRunspace
        [void]$script:bgPS.AddScript($dataScript)
        if (-not $script:firstLoadComplete) {
            $script:fetchStartTime = [DateTime]::Now
            Set-SplashStatus "Connecting to Azure subscription..." -Progress 99
        }
        $script:bgHandle      = $script:bgPS.BeginInvoke()
    }
    else {
        $script:CountdownText.Text = "Next refresh in $([Math]::Ceiling($remaining))s"
    }


    Invoke-SessionHostsTabTimer
    Invoke-SessionInfoTabTimer
    Invoke-AzureFilesTabTimer
    Invoke-ImagesTabTimer
    Invoke-InfrastructureTabTimer
    Invoke-AzureDevOpsTabTimer
    Invoke-RunCommandTimer
})
$script:masterTimer.Start()

# =============================================================================
# Summary Card Click Handlers
# =============================================================================

$script:CardPoolsBorder.Add_MouseLeftButtonUp({
    $script:MainTabControl.SelectedItem = $script:PerHostPoolTab
})
$script:CardVMsBorder.Add_MouseLeftButtonUp({
    $script:MainTabControl.SelectedItem = $script:SessionHostsTab
})

$script:CardActiveBorder.Add_MouseLeftButtonUp({
    if ($script:lastData -and $script:lastData.Active -gt 0) {
        Show-GlobalSessionDetail -StateFilter "Active"
    }
})
$script:CardDisconnBorder.Add_MouseLeftButtonUp({
    if ($script:lastData -and $script:lastData.Disconnected -gt 0) {
        Show-GlobalSessionDetail -StateFilter "Disconnected"
    }
})
$script:CardStorageBorder.Add_MouseLeftButtonUp({
    $script:MainTabControl.SelectedItem = $script:AzureFilesTab
})

$script:CardTotalBorder.Add_MouseLeftButtonUp({
    if ($script:lastData -and $script:lastData.TotalSessions -gt 0) {
        Show-GlobalSessionDetail -StateFilter "All"
    }
})

# =============================================================================
# Settings Window
# =============================================================================

$_settingsXamlRaw = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="AVD Live Dashboard Settings"
    Height="780" Width="1020"
    MinHeight="600" MinWidth="900"
    WindowStartupLocation="CenterOwner"
    ResizeMode="CanResizeWithGrip"
    Background="{DynamicResource Avd.Window.Bg}"
    Foreground="{DynamicResource Avd.Window.Fg}"
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
                         FontFamily="Consolas" Foreground="{DynamicResource Avd.Fg.Accent}"/>
                </TextBlock>
            </StackPanel>
        </Border>

        <!-- Bottom: status + buttons -->
        <DockPanel DockPanel.Dock="Bottom" Margin="0,16,0,0">
            <Button x:Name="SettingsReloadConfigBtn" Content="Reload Config"
                    DockPanel.Dock="Left"
                    Width="120" Height="32"
                    Foreground="{DynamicResource Avd.Fg.Secondary}"
                    BorderThickness="0" FontSize="13" Cursor="Hand">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{DynamicResource Avd.Btn.Neutral.Bg}" CornerRadius="4" Padding="8,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Btn.Neutral.Hover}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Btn.Neutral.Press}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal"
                        HorizontalAlignment="Right">
                <Button x:Name="SettingsCancelBtn" Content="Cancel"
                        Width="90" Height="32" Margin="0,0,10,0"
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
                <Button x:Name="SettingsSaveBtn" Content="Save"
                        Width="90" Height="32"
                        Foreground="White"
                        BorderThickness="0" FontSize="13" FontWeight="SemiBold" Cursor="Hand">
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
            <TextBlock x:Name="SettingsStatus" FontSize="11" Foreground="#C42B1C"
                       VerticalAlignment="Center" TextWrapping="Wrap"/>
        </DockPanel>

        <!-- Two-column layout: Operational (left) | Display & Filter (right) -->
        <Grid>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="24"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- ============================================================= -->
            <!-- LEFT COLUMN: Operational Settings                             -->
            <!-- ============================================================= -->
            <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="0,0,4,0">

                <TextBlock Text="Operational Settings" FontSize="18" FontWeight="Bold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" Margin="0,0,0,20"/>

                <!-- Refresh Interval -->
                <TextBlock Text="Refresh Interval (seconds)" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBox x:Name="RefreshIntervalBox"
                         Height="32" FontSize="13" Padding="8,4"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" VerticalContentAlignment="Center"/>
                <TextBlock Text="Minimum 10 seconds. Applies immediately on save."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,16"/>

                <!-- Azure Files Refresh Interval -->
                <TextBlock Text="Azure Files Refresh (minutes)" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBox x:Name="FilesIntervalBox"
                         Height="32" FontSize="13" Padding="8,4"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" VerticalContentAlignment="Center"/>
                <TextBlock Text="Minimum 1 minute. Default is 15 minutes."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,16"/>

                <!-- Storage Warning Threshold -->
                <TextBlock Text="Storage Warning Threshold (%)" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBox x:Name="StorageWarningPctBox"
                         Height="32" FontSize="13" Padding="8,4"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" VerticalContentAlignment="Center"/>
                <TextBlock Text="Warning card when any share exceeds this %. Default 90."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,16"/>

                <!-- Shadow Method -->
                <TextBlock Text="Shadow Method" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                    <RadioButton x:Name="ShadowMstscRadio" Content="Remote Desktop (mstsc)" IsChecked="True"
                                 Foreground="{DynamicResource Avd.Window.Fg}"
                                 FontSize="12" Margin="0,0,16,0" GroupName="ShadowMethodGroup"/>
                    <RadioButton x:Name="ShadowMsraRadio"  Content="Remote Assistance (msra)"
                                 Foreground="{DynamicResource Avd.Window.Fg}"
                                 FontSize="12" GroupName="ShadowMethodGroup"/>
                </StackPanel>
                <CheckBox x:Name="ShadowNoConsentCheck"
                          Content="Skip user consent (/noConsentPrompt) - mstsc only"
                          Foreground="{DynamicResource Avd.Window.Fg}"
                          FontSize="12" Margin="0,4,0,4" IsChecked="False"/>
                <TextBlock Text="Requires Allow Remote Control GPO on session hosts."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,2,0,16"/>

                <!-- ── Session Hosts ── -->
                <TextBlock Text="Session Hosts" FontSize="15" FontWeight="Bold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" Margin="0,0,0,4"/>
                <Border BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1" Margin="0,0,0,10"/>

                <TextBlock Text="Connection Mode" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                    <RadioButton x:Name="ShadowDnsRadio" Content="DNS Hostname" IsChecked="True"
                                 Foreground="{DynamicResource Avd.Window.Fg}"
                                 FontSize="12" Margin="0,0,16,0" GroupName="ShadowMode"/>
                    <RadioButton x:Name="ShadowIpRadio"  Content="IP Address"
                                 Foreground="{DynamicResource Avd.Window.Fg}"
                                 FontSize="12" GroupName="ShadowMode"/>
                </StackPanel>
                <TextBlock Text="IP resolves VM private IP via Azure. Applies to Shadow and RDP."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,12"/>

                <TextBlock Text="Excluded Host Pools" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBlock Text="Host pool names to exclude, one per line (exact, case-insensitive)."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="ExcludedPoolsBox"
                         Height="70" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>

                <TextBlock Text="AVD Included Resource Groups" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,12,0,6"/>
                <TextBlock Text="Only query these RGs, one per line. Blank = all."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="AvdIncludeRGsBox"
                         Height="60" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>

                <TextBlock Text="AVD Excluded Resource Groups" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,12,0,6"/>
                <TextBlock Text="Exclude these RGs, one per line. Applied after inclusion."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="AvdExcludeRGsBox"
                         Height="60" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>

                <!-- ── Azure Files ── -->
                <TextBlock Text="Azure Files" FontSize="15" FontWeight="Bold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" Margin="0,20,0,4"/>
                <Border BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1" Margin="0,0,0,10"/>

                <TextBlock Text="Resource Groups" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBlock Text="Limit Azure Files query to these RGs. Blank = all."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="FilesRGsBox"
                         Height="60" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>

                <!-- ── Images (hidden when Images tab is hidden) ── -->
                <StackPanel x:Name="ImgSettingsPanel">
                <TextBlock Text="Images" FontSize="15" FontWeight="Bold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" Margin="0,20,0,4"/>
                <Border BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1" Margin="0,0,0,10"/>

                <TextBlock Text="Resource Groups" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBlock Text="RGs for image VMs. Blank = empty tab."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="ImgRGsBox"
                         Height="60" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>

                <TextBlock Text="Include Patterns" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,12,0,6"/>
                <TextBlock Text="Only show VMs matching these substrings (one per line). Blank = all VMs."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="ImgIncludePatternsBox"
                         Height="60" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>

                <TextBlock Text="Gallery Resource Groups" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,12,0,6"/>
                <TextBlock Text="RGs to search for Shared Image Galleries (Create Image dialog). One per line. Blank = search entire subscription."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="ImgGalleryRGsBox"
                         Height="60" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>

                <TextBlock Text="Preparation VM Sizes" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,12,0,6"/>
                <TextBlock Text="VM sizes offered in the Create Image dialog (one per line)."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="ImgPrepVMSizesBox"
                         Height="80" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>

                <TextBlock Text="Preparation VM Size Default" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,12,0,6"/>
                <TextBlock Text="Size pre-selected in the Create Image dialog."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <ComboBox x:Name="ImgPrepVMSizeDefaultBox"
                          Height="30" FontSize="12"
                          BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                          Background="{DynamicResource Avd.Input.Bg}"/>

                <TextBlock Text="Image Versions to Keep" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,12,0,6"/>
                <TextBlock Text="Number of versions to retain per image definition (Clean Image Versions button). Newest N kept; older deleted. Default: 5"
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="ImgVersionsToKeepBox"
                         Width="80" HorizontalAlignment="Left"
                         Height="30" FontSize="12" Padding="8,4"
                         VerticalContentAlignment="Center"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}"/>

                <TextBlock Text="BIS-F Path" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,12,0,6"/>
                <TextBlock Text="Path to BIS-F on the preparation VM (e.g. C:\_source\Bis-F). Used by Create Image."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="ImgBisFPathBox"
                         Height="30" FontSize="12" Padding="8,4"
                         VerticalContentAlignment="Center"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}"/>

                <TextBlock Text="Replication Region 1" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,12,0,6"/>
                <TextBlock Text="Primary gallery replication region (e.g. westeurope). Required."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="8"/>
                        <ColumnDefinition Width="60"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="ImgRegion1Box" Grid.Column="0"
                             Height="30" FontSize="12" Padding="8,4"
                             VerticalContentAlignment="Center"
                             Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                             BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                             Background="{DynamicResource Avd.Input.Bg}"/>
                    <TextBox x:Name="ImgRegion1ReplicasBox" Grid.Column="2"
                             Height="30" FontSize="12" Padding="8,4"
                             VerticalContentAlignment="Center"
                             Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                             BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                             Background="{DynamicResource Avd.Input.Bg}" ToolTip="Replica count"/>
                </Grid>

                <TextBlock Text="Replication Region 2" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,12,0,6"/>
                <TextBlock Text="Optional second replication region. Leave blank to replicate to one region only."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="8"/>
                        <ColumnDefinition Width="60"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="ImgRegion2Box" Grid.Column="0"
                             Height="30" FontSize="12" Padding="8,4"
                             VerticalContentAlignment="Center"
                             Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                             BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                             Background="{DynamicResource Avd.Input.Bg}"/>
                    <TextBox x:Name="ImgRegion2ReplicasBox" Grid.Column="2"
                             Height="30" FontSize="12" Padding="8,4"
                             VerticalContentAlignment="Center"
                             Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                             BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                             Background="{DynamicResource Avd.Input.Bg}" ToolTip="Replica count"/>
                </Grid>
                </StackPanel>

                <!-- ── Infrastructure ── -->
                <TextBlock Text="Infrastructure" FontSize="15" FontWeight="Bold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" Margin="0,20,0,4"/>
                <Border BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1" Margin="0,0,0,10"/>

                <TextBlock Text="Resource Groups" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBlock Text="RGs for infrastructure VMs. Blank = empty tab."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="InfraRGsBox"
                         Height="60" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>

            </StackPanel>
            </ScrollViewer>

            <!-- Vertical separator -->
            <Border Grid.Column="1" Width="1" Background="{DynamicResource Avd.Border.Std}"
                    HorizontalAlignment="Center" Margin="0,0,0,0"/>

            <!-- ============================================================= -->
            <!-- RIGHT COLUMN: Display & Filter Settings                       -->
            <!-- ============================================================= -->
            <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="4,0,0,0">

                <TextBlock Text="Display &amp; Filter Settings" FontSize="18" FontWeight="Bold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" Margin="0,0,0,4"/>
                <TextBlock Text="Override config.psd1 values. Saved to registry."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,16"/>

                <!-- Secondary Region Highlighting -->
                <CheckBox x:Name="SecondaryRegionHighlightCheck"
                          Content="Highlight secondary region sessions (red rows)"
                          Foreground="{DynamicResource Avd.Window.Fg}"
                          FontSize="12" Margin="0,0,0,8" IsChecked="True"/>


                <!-- Hidden Tabs -->
                <TextBlock Text="Hidden Tabs" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBlock Text="Checked tabs are hidden from the tab strip."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,8"/>
                <WrapPanel Margin="0,0,0,4">
                    <CheckBox x:Name="HTabPerHostPool"    Content="Per Host Pool"    Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HTabByRegion"       Content="By Region"        Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HTabSessionHosts"   Content="Session Hosts"    Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HTabAzureFiles"     Content="Azure Files"      Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HTabMonitoring"     Content="Monitoring"       Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HTabImages"         Content="Images"           Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HTabInfrastructure" Content="Infrastructure"   Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HTabAzureDevOps"    Content="Azure DevOps"     Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                </WrapPanel>
                <TextBlock Text="Changes apply immediately on save."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,2,0,16"/>

                <!-- Hidden Columns -->
                <TextBlock Text="Hidden Columns (Per Host Pool)" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBlock Text="Checked columns are hidden. Takes effect on next refresh."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,8"/>
                <WrapPanel Margin="0,0,0,4">
                    <CheckBox x:Name="HColHostPool"       Content="Host Pool"        Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColHPRegion"       Content="HP Region"        Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColWorkspace"      Content="Workspace"        Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColVMRegion"       Content="VM Region"        Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColImageVersionA"  Content="Image Version A"  Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColImageVersionB"  Content="Image Version B"  Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColTotalVMs"       Content="Total VMs"        Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColVMsOn"          Content="VMs Available"           Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColVMsOff"         Content="VMs Not Available"       Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColVMsDrained"     Content="VMs Drained"             Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColActiveUsers"    Content="Active Users"     Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColDisconnected"   Content="Disconnected"     Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColTotalSessions"  Content="Total Sessions"   Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColScalingPlan"    Content="Scaling Plan"     Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColMaxSessions"    Content="Max Sessions"     Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColLoadBalancer"   Content="Load Balancer"    Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColValidation"     Content="Validation"       Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColStartVMOnConnect" Content="Start VM on Connect" Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColRGVMs"          Content="RG VMs"           Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColNetworkAccess"     Content="Network Access"    Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColPrivateEndpoints" Content="Private Endpoints" Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColHostPoolRG"        Content="Host Pool RG"      Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColScope"          Content="Scope"            Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                    <CheckBox x:Name="HColHPLocation"     Content="HP Location"      Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,16,4"/>
                </WrapPanel>
                <TextBlock FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,2,0,16"/>

                <!-- Low Priority Patterns -->
                <TextBlock Text="Low Priority Host Pool Patterns" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBlock Text="Substrings sorted to bottom of Per Host Pool tab (one per line)."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="LowPriorityPatternsBox"
                         Height="60" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>
                <TextBlock Text="Example: -UAT, -TEST, -DEV"
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,16"/>

                <!-- Secondary Regions -->
                <TextBlock Text="Secondary Regions" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBlock Text="Azure regions treated as secondary (one per line)."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="SecondaryRegionsBox"
                         Height="60" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>
                <TextBlock Text="Example: francecentral, westeurope"
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,16"/>

                <!-- Scaling Exclude Tag -->
                <TextBlock Text="Scaling Exclude Tag" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBox x:Name="ScalingExcludeTagBox"
                         Height="32" FontSize="13" Padding="8,4"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" VerticalContentAlignment="Center"/>
                <TextBlock Text="VM tag name for scaling exclusion. Default: ExcludeFromScaling"
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,6"/>
                <CheckBox x:Name="DrainSetScalingTagCheck"
                          Content="Set/remove scaling exclude tag when enabling/disabling drain mode"
                          Foreground="{DynamicResource Avd.Window.Fg}"
                          FontSize="12" Margin="0,0,0,16"/>

                <!-- Storage Account Kinds -->
                <TextBlock Text="Storage Account Kinds" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBlock Text="Account types for the Azure Files tab."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,8"/>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                    <CheckBox x:Name="SAKindFileStorage" Content="FileStorage (Premium)" Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12" Margin="0,0,20,0"/>
                    <CheckBox x:Name="SAKindStorageV2"   Content="StorageV2 (Standard)"  Foreground="{DynamicResource Avd.Window.Fg}" FontSize="12"/>
                </StackPanel>
                <TextBlock Text="At least one kind must be selected."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,16"/>

                <!-- Per Host Pool: RG VM Count -->
                <TextBlock Text="Per Host Pool: RG VM Count" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <CheckBox x:Name="ShowRGVMCountCheck"
                          Content="Compare RG VM count with session host count (requires extra ARM call per VM resource group)"
                          Foreground="{DynamicResource Avd.Window.Fg}"
                          FontSize="12" Margin="0,0,0,4"/>
                <TextBlock Text="When enabled, flags VMs in the RG that are not registered as session hosts."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,16"/>

                <!-- Infrastructure Exclude Patterns -->
                <TextBlock Text="Infrastructure Exclude Patterns" FontSize="13" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,6"/>
                <TextBlock Text="VM name substrings to exclude (one per line, case-insensitive)."
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,6"/>
                <TextBox x:Name="InfraExcludePatternsBox"
                         Height="60" FontSize="12" Padding="8,6"
                         Foreground="{DynamicResource Avd.Window.Fg}" CaretBrush="{DynamicResource Avd.Window.Fg}"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" AcceptsReturn="True"
                         VerticalScrollBarVisibility="Auto"
                         TextWrapping="NoWrap"/>
                <TextBlock Text="Example: -TEMP, -OLD"
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,0"/>


            </StackPanel>
            </ScrollViewer>

        </Grid>

    </DockPanel>
</Window>
'@

$script:SettingsXamlRaw = $_settingsXamlRaw

# =============================================================================
# About Dialog
# =============================================================================

function Show-About {
    $_aboutXamlRaw = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="About AVD Live Dashboard"
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
            <TextBlock Text="AVD Live Dashboard" FontSize="18" FontWeight="Bold"
                       Foreground="{DynamicResource Avd.Fg.Accent}"/>
            <TextBlock x:Name="AboutVersion"   FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,4,0,0"/>
            <TextBlock x:Name="AboutPSVersion" FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,2,0,0"/>
            <TextBlock FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,2,0,0">GitHub: <Hyperlink x:Name="AboutGitHub" Foreground="{DynamicResource Avd.Fg.Accent}" TextDecorations="None">virtualwebber/AVD-Dashboard</Hyperlink></TextBlock>
        </StackPanel>

        <!-- Close button -->
        <Button DockPanel.Dock="Bottom" x:Name="AboutCloseBtn"
                Content="Close" HorizontalAlignment="Right"
                Width="90" Height="32" Margin="0,16,0,0"
                Foreground="White"
                BorderThickness="0" FontSize="13" FontWeight="SemiBold" Cursor="Hand">
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

        <!-- Disclaimer -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.Card.Bg}" CornerRadius="6" Padding="14,12"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1" Margin="0,12,0,0">
            <StackPanel>
                <TextBlock Text="DISCLAIMER" FontSize="11" FontWeight="Bold" Foreground="#C42B1C" Margin="0,0,0,6"/>
                <TextBlock TextWrapping="Wrap" FontSize="11" Foreground="{DynamicResource Avd.Fg.Label}" LineHeight="18">
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
    $_aboutXamlRaw = $_aboutXamlRaw -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    [xml]$aboutXaml = $_aboutXamlRaw
    $aReader = New-Object System.Xml.XmlNodeReader $aboutXaml
    $aWin    = [System.Windows.Markup.XamlReader]::Load($aReader)
    $aWin.Owner = $window
    try { Set-WindowIcon -Window $aWin -IconPath (Join-Path $PSScriptRoot 'data\avd-dashboard.ico') } catch {}
    if ($script:DarkTheme) {
        $aWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($aWin)).Handle
            $v = 1
            [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    }
    $aWin.FindName("AboutVersion").Text   = "Version $ScriptVersion"
    $aWin.FindName("AboutPSVersion").Text = "PowerShell $($PSVersionTable.PSVersion)"
    $aWin.FindName("AboutCloseBtn").Add_Click({ $aWin.Close() })
    $aWin.FindName("AboutGitHub").Add_Click({ Start-Process "https://github.com/virtualwebber/AVD-Dashboard" })

    $aWin.ShowDialog() | Out-Null
}

function Show-Settings {
    $_sXml   = $script:SettingsXamlRaw -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    [xml]$_sXmlDoc = $_sXml
    $sReader = New-Object System.Xml.XmlNodeReader $_sXmlDoc
    $sWin    = [System.Windows.Markup.XamlReader]::Load($sReader)
    $sWin.Owner = $window
    try { Set-WindowIcon -Window $sWin -IconPath (Join-Path $PSScriptRoot 'data\avd-dashboard.ico') } catch {}
    $sWin.Add_SourceInitialized({
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($sWin)).Handle
        $v = [int]$script:DarkTheme
        [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
    })

    $sInterval      = $sWin.FindName("RefreshIntervalBox")
    $sFilesInterval = $sWin.FindName("FilesIntervalBox")
    $sPools         = $sWin.FindName("ExcludedPoolsBox")
    $sAvdIncludeRGs     = $sWin.FindName("AvdIncludeRGsBox")
    $sAvdExcludeRGs     = $sWin.FindName("AvdExcludeRGsBox")
    $sFilesRGs          = $sWin.FindName("FilesRGsBox")
    $sImgRGs              = $sWin.FindName("ImgRGsBox")
    $sImgIncludePatterns  = $sWin.FindName("ImgIncludePatternsBox")
    $sImgGalleryRGs       = $sWin.FindName("ImgGalleryRGsBox")
    $sImgPrepVMSizes      = $sWin.FindName("ImgPrepVMSizesBox")
    $sImgPrepVMSizeDefault  = $sWin.FindName("ImgPrepVMSizeDefaultBox")
    $sImgVersionsToKeep     = $sWin.FindName("ImgVersionsToKeepBox")
    $sImgBisFPath           = $sWin.FindName("ImgBisFPathBox")
    $sImgRegion1            = $sWin.FindName("ImgRegion1Box")
    $sImgRegion1Replicas    = $sWin.FindName("ImgRegion1ReplicasBox")
    $sImgRegion2            = $sWin.FindName("ImgRegion2Box")
    $sImgRegion2Replicas    = $sWin.FindName("ImgRegion2ReplicasBox")
    $sInfraRGs              = $sWin.FindName("InfraRGsBox")
    $sStorageWarnPct    = $sWin.FindName("StorageWarningPctBox")
    $sShadowMstsc       = $sWin.FindName("ShadowMstscRadio")
    $sShadowNoConsent   = $sWin.FindName("ShadowNoConsentCheck")
    $sShadowMsra        = $sWin.FindName("ShadowMsraRadio")
    $sShadowDns         = $sWin.FindName("ShadowDnsRadio")
    $sShadowIp          = $sWin.FindName("ShadowIpRadio")
    $sStatus            = $sWin.FindName("SettingsStatus")
    $sSave          = $sWin.FindName("SettingsSaveBtn")
    $sCancel        = $sWin.FindName("SettingsCancelBtn")
    $sReloadConfig  = $sWin.FindName("SettingsReloadConfigBtn")

    # Pre-populate with current values
    $sInterval.Text      = $script:RefreshIntervalSeconds
    $sFilesInterval.Text = [Math]::Round($script:FilesRefreshIntervalSeconds / 60)
    $sPools.Text         = ($script:ExcludedPools -join "`r`n")
    $sAvdIncludeRGs.Text     = ($script:AvdIncludeRGs -join "`r`n")
    $sAvdExcludeRGs.Text     = ($script:AvdExcludeRGs -join "`r`n")
    $sFilesRGs.Text          = ($script:FilesRGs -join "`r`n")
    $sImgRGs.Text            = ($script:ImgRGs -join "`r`n")
    $sImgIncludePatterns.Text = ($script:ImgIncludePatterns -join "`r`n")
    $sImgGalleryRGs.Text          = ($script:ImgGalleryRGs -join "`r`n")
    $sImgPrepVMSizes.Text         = ($script:ImgPrepVMSizes -join "`r`n")
    $sImgPrepVMSizeDefault.ItemsSource    = $script:ImgPrepVMSizes
    $sImgPrepVMSizeDefault.SelectedItem  = if ($script:ImgPrepVMSizeDefault -in $script:ImgPrepVMSizes) { $script:ImgPrepVMSizeDefault } else { $script:ImgPrepVMSizes | Select-Object -First 1 }
    $sImgVersionsToKeep.Text      = [string]$script:ImgVersionsToKeep
    $sImgBisFPath.Text            = $script:ImgBisFPath
    $sImgRegion1.Text             = $script:ImgRegion1
    $sImgRegion1Replicas.Text     = [string]$script:ImgRegion1Replicas
    $sImgRegion2.Text             = $script:ImgRegion2
    $sImgRegion2Replicas.Text     = [string]$script:ImgRegion2Replicas
    $sInfraRGs.Text               = ($script:InfraRGs -join "`r`n")
    $sStorageWarnPct.Text    = $script:StorageWarningPct
    if ($script:ShadowMethod -eq "MSRA") { $sShadowMsra.IsChecked = $true } else { $sShadowMstsc.IsChecked = $true }
    $sShadowNoConsent.IsChecked = $script:ShadowNoConsent
    if ($script:ShadowUseIP) { $sShadowIp.IsChecked = $true } else { $sShadowDns.IsChecked = $true }

    $sSecondaryHighlight = $sWin.FindName("SecondaryRegionHighlightCheck")
    $sSecondaryHighlight.IsChecked = $script:SecondaryRegionHighlight

    # ---- Display/filter controls ----
    # Hidden Tabs checkboxes (x:Name maps to tab header)
    $htabMap = @{
        'Per Host Pool'  = $sWin.FindName("HTabPerHostPool")
        'By Region'      = $sWin.FindName("HTabByRegion")
        'Session Hosts'  = $sWin.FindName("HTabSessionHosts")
        'Azure Files'    = $sWin.FindName("HTabAzureFiles")
        'Monitoring'     = $sWin.FindName("HTabMonitoring")
        'Images'         = $sWin.FindName("HTabImages")
        'Infrastructure' = $sWin.FindName("HTabInfrastructure")
        'Azure DevOps'   = $sWin.FindName("HTabAzureDevOps")
    }
    # Hidden Columns checkboxes (x:Name maps to column header)
    $hcolMap = @{
        'Host Pool'      = $sWin.FindName("HColHostPool")
        'HP Region'      = $sWin.FindName("HColHPRegion")
        'Workspace'      = $sWin.FindName("HColWorkspace")
        'VM Region'      = $sWin.FindName("HColVMRegion")
        'Image Version A' = $sWin.FindName("HColImageVersionA")
        'Image Version B' = $sWin.FindName("HColImageVersionB")
        'Total VMs'      = $sWin.FindName("HColTotalVMs")
        'VMs Available'      = $sWin.FindName("HColVMsOn")
        'VMs Not Available'  = $sWin.FindName("HColVMsOff")
        'VMs Drained'        = $sWin.FindName("HColVMsDrained")
        'Active Users'   = $sWin.FindName("HColActiveUsers")
        'Disconnected'   = $sWin.FindName("HColDisconnected")
        'Total Sessions' = $sWin.FindName("HColTotalSessions")
        'Scaling Plan'   = $sWin.FindName("HColScalingPlan")
        'Max Sessions'   = $sWin.FindName("HColMaxSessions")
        'Load Balancer'  = $sWin.FindName("HColLoadBalancer")
        'Validation'     = $sWin.FindName("HColValidation")
        'Start VM on Connect' = $sWin.FindName("HColStartVMOnConnect")
        'RG VMs'         = $sWin.FindName("HColRGVMs")
        'Network Access'    = $sWin.FindName("HColNetworkAccess")
        'Private Endpoints' = $sWin.FindName("HColPrivateEndpoints")
        'Host Pool RG'      = $sWin.FindName("HColHostPoolRG")
        'Scope'          = $sWin.FindName("HColScope")
        'HP Location'    = $sWin.FindName("HColHPLocation")
    }
    $sLowPriority       = $sWin.FindName("LowPriorityPatternsBox")
    $sSecRegions        = $sWin.FindName("SecondaryRegionsBox")
    $sScalingTag        = $sWin.FindName("ScalingExcludeTagBox")
    $sDrainSetTag       = $sWin.FindName("DrainSetScalingTagCheck")
    $sShowRGVMCount     = $sWin.FindName("ShowRGVMCountCheck")
    $sSAKindFile        = $sWin.FindName("SAKindFileStorage")
    $sSAKindV2          = $sWin.FindName("SAKindStorageV2")
    $sInfraExclude      = $sWin.FindName("InfraExcludePatternsBox")

    # Pre-populate Hidden Tabs checkboxes
    foreach ($entry in $htabMap.GetEnumerator()) {
        $entry.Value.IsChecked = ($entry.Key -in $script:HiddenTabs)
    }

    # Hide Images settings panel when the Images tab is hidden; toggle live on checkbox change
    $sImgSettingsPanel = $sWin.FindName("ImgSettingsPanel")
    $sImgSettingsPanel.Visibility = if ($htabMap['Images'].IsChecked) { 'Collapsed' } else { 'Visible' }
    $htabMap['Images'].Add_Checked(  { $sImgSettingsPanel.Visibility = 'Collapsed' }.GetNewClosure())
    $htabMap['Images'].Add_Unchecked({ $sImgSettingsPanel.Visibility = 'Visible'   }.GetNewClosure())

    # Collapse checkboxes for tabs hidden by config - they are not user-configurable
    foreach ($tabName in $script:DefaultHiddenTabs) {
        if ($htabMap.ContainsKey($tabName)) {
            $htabMap[$tabName].Visibility = 'Collapsed'
        }
    }

    # Pre-populate Hidden Columns checkboxes
    foreach ($entry in $hcolMap.GetEnumerator()) {
        $entry.Value.IsChecked = ($entry.Key -in $script:HiddenColumns)
    }
    # Hide the "RG VMs" hidden-column checkbox when the RG VM count feature is disabled
    # in config - the column doesn't exist so there's nothing to hide.
    if (-not $script:ShowRGVMCount) { $hcolMap['RG VMs'].Visibility = 'Collapsed' }
    # Pre-populate text fields
    $sLowPriority.Text  = ($script:LowPriorityHostPoolPatterns -join "`r`n")
    $sSecRegions.Text   = ($script:SecondaryRegions -join "`r`n")
    $sScalingTag.Text   = $script:ScalingExcludeTag
    $sDrainSetTag.IsChecked   = $script:DrainSetScalingTag
    $sShowRGVMCount.IsChecked = $script:ShowRGVMCount
    $sInfraExclude.Text = ($script:InfraExcludePatterns -join "`r`n")
    # Pre-populate Storage Account Kinds checkboxes
    $sSAKindFile.IsChecked = ('FileStorage' -in $script:StorageAccountKinds)
    $sSAKindV2.IsChecked   = ('StorageV2'   -in $script:StorageAccountKinds)

    $sCancel.Add_Click({ $sWin.Close() }.GetNewClosure())

    $sReloadConfig.Add_Click({
        try {
            Invoke-ConfigReload
            # Re-inject LAW workspace ID into the persistent runspace so Phase 4
            # picks up the new value without needing a full script restart.
            if ($script:vmRefreshRunspace) {
                $script:vmRefreshRunspace.SessionStateProxy.SetVariable('LawWorkspaceResourceId', $script:LawWorkspaceResourceId)
                $script:vmRefreshRunspace.SessionStateProxy.SetVariable('LawQueryBaseUrl',        $script:LawQueryBaseUrl)
            }
            $sStatus.Foreground = [System.Windows.Media.Brushes]::DarkGreen
            $sStatus.Text = "Config reloaded from file."
            if (-not $script:currentJob) { $script:nextRefreshAt = [DateTime]::Now }
            Reset-ImagesTab
            Reset-InfrastructureTab
        } catch {
            $sStatus.Foreground = [System.Windows.Media.Brushes]::Firebrick
            $sStatus.Text = "Reload failed: $_"
        }
    }.GetNewClosure())

    $sSave.Add_Click({
        # Validate AVD refresh interval
        $iv = 0
        if (-not [int]::TryParse($sInterval.Text.Trim(), [ref]$iv) -or $iv -lt 10) {
            $sStatus.Text = "Refresh interval must be a whole number of 10 or more."
            return
        }
        # Validate Files refresh interval
        $fiv = 0
        if (-not [int]::TryParse($sFilesInterval.Text.Trim(), [ref]$fiv) -or $fiv -lt 1) {
            $sStatus.Text = "Azure Files refresh interval must be 1 minute or more."
            return
        }

        # Parse excluded pools
        $excl = @($sPools.Text -split "`r`n|`n" |
                  ForEach-Object { $_.Trim() } |
                  Where-Object { $_ })

        # Read shadow settings
        $shadowMethod    = if ($sShadowMsra.IsChecked -eq $true) { "MSRA" } else { "MSTSC" }
        $shadowNoConsent = ($sShadowNoConsent.IsChecked -eq $true)
        $shadowUseIp     = ($sShadowIp.IsChecked -eq $true)

        # Validate storage warning threshold
        $swp = 0
        if (-not [int]::TryParse($sStorageWarnPct.Text.Trim(), [ref]$swp) -or $swp -lt 1 -or $swp -gt 100) {
            $sStatus.Text = "Storage warning threshold must be between 1 and 100."
            return
        }

        # Parse AVD RG filters
        $avdIncRgs = @($sAvdIncludeRGs.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $avdExcRgs = @($sAvdExcludeRGs.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        # Parse files RGs
        $filesRgs = @($sFilesRGs.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        # Parse Images RGs, include patterns, and gallery RGs
        $imgRgs        = @($sImgRGs.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $imgInclPats   = @($sImgIncludePatterns.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $imgGalleryRgs         = @($sImgGalleryRGs.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $imgPrepVMSizes        = @($sImgPrepVMSizes.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($imgPrepVMSizes.Count -eq 0) { $imgPrepVMSizes = @('Standard_D2s_v5','Standard_D4s_v5','Standard_D8s_v5') }
        $imgPrepVMSizeDefault  = [string]$sImgPrepVMSizeDefault.SelectedItem
        if (-not $imgPrepVMSizeDefault) { $imgPrepVMSizeDefault = 'Standard_D4s_v5' }
        $imgVersionsToKeepVal  = 0
        $imgVersionsToKeep     = if ([int]::TryParse($sImgVersionsToKeep.Text.Trim(), [ref]$imgVersionsToKeepVal) -and $imgVersionsToKeepVal -gt 0) { $imgVersionsToKeepVal } else { 5 }
        $imgBisFPath           = if ($sImgBisFPath.Text.Trim()) { $sImgBisFPath.Text.Trim() } else { 'C:\_source\Bis-F' }
        $imgRegion1            = $sImgRegion1.Text.Trim()
        $imgRegion1ReplicasVal = 0
        $imgRegion1Replicas    = if ([int]::TryParse($sImgRegion1Replicas.Text.Trim(), [ref]$imgRegion1ReplicasVal) -and $imgRegion1ReplicasVal -gt 0) { $imgRegion1ReplicasVal } else { 1 }
        $imgRegion2            = $sImgRegion2.Text.Trim()
        $imgRegion2ReplicasVal = 0
        $imgRegion2Replicas    = if ([int]::TryParse($sImgRegion2Replicas.Text.Trim(), [ref]$imgRegion2ReplicasVal) -and $imgRegion2ReplicasVal -gt 0) { $imgRegion2ReplicasVal } else { 1 }

        # Parse infrastructure RGs
        $infraRgs = @($sInfraRGs.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        # Read secondary region highlight toggle
        $secondaryHighlight = ($sSecondaryHighlight.IsChecked -eq $true)

        # ---- Parse display/filter settings ----

        # Hidden Tabs: collect checked tab names, then union in config defaults (config is the hard floor)
        $hiddenTabs = @(@($htabMap.GetEnumerator() | Where-Object { $_.Value.IsChecked -eq $true } | ForEach-Object { $_.Key }) + $script:DefaultHiddenTabs | Select-Object -Unique)

        # Hidden Columns: collect checked column names
        $hiddenCols = @($hcolMap.GetEnumerator() | Where-Object { $_.Value.IsChecked -eq $true } | ForEach-Object { $_.Key })

        # Low priority patterns (one per line)
        $lowPriPats = @($sLowPriority.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        # Secondary regions (one per line)
        $secRegs = @($sSecRegions.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        # Scaling exclude tag
        $scalingTag = $sScalingTag.Text.Trim()
        if (-not $scalingTag) { $scalingTag = 'ExcludeFromScaling' }
        $drainSetScalingTag = ($sDrainSetTag.IsChecked -eq $true)
        $showRgVmCount      = ($sShowRGVMCount.IsChecked -eq $true)

        # Storage account kinds (at least one must be selected)
        $saKinds = @()
        if ($sSAKindFile.IsChecked -eq $true) { $saKinds += 'FileStorage' }
        if ($sSAKindV2.IsChecked -eq $true)   { $saKinds += 'StorageV2' }
        if ($saKinds.Count -eq 0) {
            $sStatus.Text = "At least one Storage Account Kind must be selected."
            return
        }

        # Infrastructure exclude patterns (one per line)
        $infraExcPats = @($sInfraExclude.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        $adoUrl = $script:AdoOrgUrl

        # Save to registry
        try {
            Write-Settings `
                -RefreshInterval $iv `
                -FilesRefreshInterval ($fiv * 60) `
                -StorageWarningPct $swp `
                -ShadowMethod $shadowMethod `
                -ShadowNoConsent ([int]$shadowNoConsent) `
                -ShadowUseIP $shadowUseIp `
                -ExcludedPools $excl `
                -AvdIncludeRGs $avdIncRgs `
                -AvdExcludeRGs $avdExcRgs `
                -FilesRGs $filesRgs `
                -InfraRGs $infraRgs `
                -SecondaryRegionHighlight ([int]$secondaryHighlight) `
                -HiddenTabs $hiddenTabs `
                -HiddenColumns $hiddenCols `
                -LowPriorityPatterns $lowPriPats `
                -SecondaryRegions $secRegs `
                -ScalingExcludeTag $scalingTag `
                -StorageAccountKinds $saKinds `
                -InfraExcludePatterns $infraExcPats `
                -DrainSetScalingTag ([int]$drainSetScalingTag) `
                -ShowRGVMCount ([int]$showRgVmCount) `
                -AdoOrgUrl $adoUrl `
                -DarkTheme ([int]$script:DarkTheme)
        } catch {
            $sStatus.Text = "Failed to save to registry: $_"
            return
        }

        # Apply immediately - operational settings
        $script:RefreshIntervalSeconds      = $iv
        $script:FilesRefreshIntervalSeconds = $fiv * 60
        $script:ExcludedPools               = $excl
        $script:StorageWarningPct           = $swp
        $script:ShadowMethod                = $shadowMethod
        $script:ShadowNoConsent             = $shadowNoConsent
        $script:ShadowUseIP                 = $shadowUseIp
        $script:AvdIncludeRGs               = $avdIncRgs
        $script:AvdExcludeRGs               = $avdExcRgs
        $script:FilesRGs                    = $filesRgs
        $script:ImgRGs                      = $imgRgs
        $script:ImgIncludePatterns          = $imgInclPats
        $script:ImgGalleryRGs               = $imgGalleryRgs
        $script:ImgPrepVMSizes              = $imgPrepVMSizes
        $script:ImgPrepVMSizeDefault        = $imgPrepVMSizeDefault
        $sImgPrepVMSizeDefault.ItemsSource  = $script:ImgPrepVMSizes
        $sImgPrepVMSizeDefault.SelectedItem = if ($imgPrepVMSizeDefault -in $script:ImgPrepVMSizes) { $imgPrepVMSizeDefault } else { $script:ImgPrepVMSizes | Select-Object -First 1 }
        $script:ImgVersionsToKeep          = $imgVersionsToKeep
        $script:ImgBisFPath                = $imgBisFPath
        $script:ImgRegion1                 = $imgRegion1
        $script:ImgRegion1Replicas         = $imgRegion1Replicas
        $script:ImgRegion2                 = $imgRegion2
        $script:ImgRegion2Replicas         = $imgRegion2Replicas
        $script:imgCachedGalleries          = $null   # clear cache so dialog re-fetches with new RG scope
        $script:InfraRGs                    = $infraRgs
        $script:SecondaryRegionHighlight    = $secondaryHighlight

        # Apply immediately - display/filter settings
        $script:HiddenTabs                   = $hiddenTabs
        $script:HiddenColumns                = $hiddenCols
        $script:LowPriorityHostPoolPatterns  = $lowPriPats
        $script:SecondaryRegions             = $secRegs
        $script:ScalingExcludeTag            = $scalingTag
        $script:StorageAccountKinds          = $saKinds
        $script:InfraExcludePatterns         = $infraExcPats
        $script:DrainSetScalingTag          = $drainSetScalingTag
        $script:ShowRGVMCount               = $showRgVmCount
        # RG VMs column: AutoGeneratingColumn only runs once at grid build time, so the
        # column must be shown/hidden directly on the live Columns collection when the
        # setting changes in Settings without restarting.
        foreach ($col in $script:PoolGrid.Columns) {
            if ($col.Header -eq 'RG VMs') {
                $col.Visibility = if ($script:ShowRGVMCount) { 'Visible' } else { 'Collapsed' }
                break
            }
        }
        # Re-apply Hidden Tabs: show/collapse tabs based on new list
        foreach ($tab in $script:MainTabControl.Items) {
            if ($tab.Header -is [string]) {
                $tab.Visibility = if ($tab.Header -in $script:HiddenTabs) { 'Collapsed' } else { 'Visible' }
            }
        }

        # Trigger immediate refresh so changes take effect
        if (-not $script:currentJob) {
            $script:nextRefreshAt = [DateTime]::Now
        }
        Reset-ImagesTab
        Reset-InfrastructureTab

        $sWin.Close()
    })

    $sWin.ShowDialog() | Out-Null
}

# =============================================================================
# Switch Subscription
# =============================================================================

function Show-SwitchSubscription {
    # Fully synchronous - no timers, no async, no scope flag tricks.
    # Everything runs on the UI thread; Az calls take ~1-3s total which is acceptable.

    $script:StatusText.Text = "Loading subscriptions..."

    # Fetch subscriptions via REST API
    $subs = $null
    try {
        $tok = Get-ArmToken
        $rawSubs = Get-ArmSubscriptions -Token $tok
        $subs = @($rawSubs | ForEach-Object {
            [PSCustomObject]@{ Name = $_.displayName; Id = $_.subscriptionId; TenantId = $_.tenantId }
        } | Sort-Object Name)
    }
    catch { $script:StatusText.Text = "Failed to load subscriptions: $_"; return }
    $script:StatusText.Text = ""

    if (-not $subs -or $subs.Count -eq 0) {
        Show-ThemedDialog -Message 'No subscriptions found.' -Title 'Switch Subscription' -Icon 'Information'
        return
    }

    # Build picker dialog - returns the selected subscription object or $null
    $_subXamlRaw = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Switch Subscription" Height="420" Width="520"
        MinHeight="300" MinWidth="400"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize"
        Background="{DynamicResource Avd.Window.Bg}"
        Foreground="{DynamicResource Avd.Window.Fg}"
        FontFamily="Segoe UI">
    <Window.Resources>
        <!-- THEME_SLOT -->
    </Window.Resources>
    <DockPanel Margin="20,16,20,16">
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal"
                    HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="SubCancelBtn" Content="Cancel"
                    Width="90" Height="32" Margin="0,0,10,0"
                    Foreground="{DynamicResource Avd.Fg.Label}"
                    BorderThickness="0" FontSize="13" Cursor="Hand">
                <Button.Template><ControlTemplate TargetType="Button">
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
                </ControlTemplate></Button.Template>
            </Button>
            <Button x:Name="SubConfirmBtn" Content="Switch"
                    Width="90" Height="32" IsEnabled="False"
                    Foreground="White"
                    BorderThickness="0" FontSize="13" FontWeight="SemiBold" Cursor="Hand">
                <Button.Template><ControlTemplate TargetType="Button">
                    <Border x:Name="Bd" Background="{DynamicResource Avd.Btn.Save.Bg}" CornerRadius="4" Padding="8,0">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsEnabled" Value="False">
                            <Setter TargetName="Bd" Property="Background" Value="#AAD0EF"/>
                        </Trigger>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Btn.Save.Hover}"/>
                        </Trigger>
                        <Trigger Property="IsPressed" Value="True">
                            <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Btn.Save.Press}"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate></Button.Template>
            </Button>
        </StackPanel>
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
            <TextBlock Text="Switch Subscription" FontSize="18" FontWeight="Bold"
                       Foreground="{DynamicResource Avd.Fg.Accent}" Margin="0,0,0,4"/>
            <TextBlock Text="Select a subscription to switch to. The dashboard will refresh automatically."
                       FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}"/>
        </StackPanel>
        <ListBox x:Name="SubList" Background="{DynamicResource Avd.Card.Bg}"
                 BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1"
                 FontSize="13" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListBox.ItemContainerStyle>
                <Style TargetType="ListBoxItem">
                    <Setter Property="Padding" Value="12,8"/>
                    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                    <Style.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="Background" Value="{DynamicResource Avd.Hover.Bg}"/>
                        </Trigger>
                        <Trigger Property="IsSelected" Value="True">
                            <Setter Property="Background" Value="{DynamicResource Avd.Selected.Bg}"/>
                            <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Selected}"/>
                        </Trigger>
                    </Style.Triggers>
                </Style>
            </ListBox.ItemContainerStyle>
            <ListBox.ItemTemplate>
                <DataTemplate>
                    <StackPanel>
                        <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="13"/>
                        <TextBlock Text="{Binding Id}" FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,2,0,0"/>
                    </StackPanel>
                </DataTemplate>
            </ListBox.ItemTemplate>
        </ListBox>
    </DockPanel>
</Window>
'@
    $_subXamlRaw = $_subXamlRaw -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    [xml]$subXaml = $_subXamlRaw
    $subReader = New-Object System.Xml.XmlNodeReader $subXaml
    $subWin    = [System.Windows.Markup.XamlReader]::Load($subReader)
    $subWin.Owner = $window
    try { Set-WindowIcon -Window $subWin -IconPath (Join-Path $PSScriptRoot 'data\avd-dashboard.ico') } catch {}
    if ($script:DarkTheme) {
        $subWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($subWin)).Handle
            $v = 1
            [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    }

    $subList    = $subWin.FindName("SubList")
    $confirmBtn = $subWin.FindName("SubConfirmBtn")
    $cancelBtn  = $subWin.FindName("SubCancelBtn")

    $subList.ItemsSource = $subs
    $liveId      = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } elseif ($azContext.Subscription) { $azContext.Subscription.Id } else { '' }
    $currentItem = if ($liveId) { $subs | Where-Object { $_.Id.ToLower() -eq $liveId.ToLower() } | Select-Object -First 1 } else { $null }
    if ($currentItem) { $subList.SelectedItem = $currentItem }

    $subList.Add_SelectionChanged({
        $confirmBtn.IsEnabled = ($null -ne $subList.SelectedItem)
    }.GetNewClosure())
    $confirmBtn.IsEnabled = ($null -ne $subList.SelectedItem)

    # Use DialogResult tag to pass selection back - avoids any scope issues with nested loops
    $subWin.Tag = $null
    $cancelBtn.Add_Click({
        $subWin.Tag = $null
        $subWin.Close()
    }.GetNewClosure())
    $confirmBtn.Add_Click({
        $subWin.Tag = $subList.SelectedItem
        $subWin.Close()
    }.GetNewClosure())
    $subList.Add_MouseDoubleClick({
        if ($null -ne $subList.SelectedItem) {
            $subWin.Tag = $subList.SelectedItem
            $subWin.Close()
        }
    }.GetNewClosure())

    $subWin.ShowDialog() | Out-Null
    $selected = $subWin.Tag   # populated by confirm click, null if cancelled

    if (-not $selected) { return }

    # Guard: same subscription
    $liveNow = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $azContext.Subscription.Id }
    if ($selected.Id.ToLower() -eq $liveNow.ToLower()) { return }

    # Clear grids and cards immediately
    $script:PoolGrid.ItemsSource   = $null
    $script:RegionGrid.ItemsSource = $null
    $script:CardPools.Text   = "-"; $script:CardVMs.Text     = "-"
    $script:CardOn.Text      = "-"; $script:CardOff.Text     = "-"
    $script:CardActive.Text  = "-"; $script:CardDisconn.Text = "-"
    $script:CardTotal.Text   = "-"
    $script:StatusText.Text  = "Switching to '$($selected.Name)'..."

    # Cancel in-flight Azure Files job, clear the files grid and storage card
    Reset-AzureFilesTab

    # Discard any completed or in-flight AVD data job from the old subscription
    # so the master timer doesn't paint old data back and overwrite nextRefreshAt.
    # Capture and null the references first to prevent the master timer tick from
    # racing to EndInvoke/Dispose the same objects simultaneously.
    $oldHandle = $script:bgHandle
    $oldPS     = $script:bgPS
    $script:bgHandle = $null
    $script:bgPS     = $null
    if ($oldHandle) {
        if (-not $oldHandle.IsCompleted) {
            try { $oldPS.Stop() } catch {}
        }
        try { $oldPS.Dispose() } catch {}
    }

    # Clear subscription-specific caches
    $script:FilesRGs        = @()
    $script:AvdIncludeRGs   = @()
    $script:AvdExcludeRGs   = @()
    $script:rgLocationCache = @{}
    $script:vmRgMap         = @{}

    # Switch Az context synchronously (same pattern as fetch above)
    $swRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $swRS.ApartmentState = 'MTA'
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

    $result = $null
    try   { $result = $swPS.Invoke() | Select-Object -Last 1 }
    catch { $script:StatusText.Text = "Failed to switch subscription: $_"; return }
    finally { try { $swRS.Close(); $swPS.Dispose() } catch {} }

    if (-not $result) { $script:StatusText.Text = "Switch returned no result."; return }

    # Update script-scope context - master timer picks these up on next refresh
    $script:currentSubscriptionId   = $result.SubscriptionId
    $script:currentSubscriptionName = $result.SubscriptionName
    # Update tab-specific subscription IDs for REST API calls
    $script:vmSubId    = $result.SubscriptionId
    $script:filesSubId = $result.SubscriptionId
    $script:infraSubId = $result.SubscriptionId
    $script:ConnectedAsText.Text     = "Connected as: $($result.AccountId)   |   Subscription: $($result.SubscriptionName)"
    $script:StatusText.Text          = "Switched to '$($result.SubscriptionName)' - refreshing..."

    # Trigger immediate refresh of AVD data and VM tab
    $script:nextRefreshAt = [DateTime]::Now
    Reset-SessionHostsTab
    Reset-ImagesTab
    Reset-InfrastructureTab
}

function Show-SwitchConfig {
    if ($script:_availableConfigs.Count -lt 2) { return }
    $_p = Show-ConfigPicker -Configs $script:_availableConfigs -AllowCancel $true
    if (-not $_p) { return }
    $_rootReg = 'HKCU:\Software\AVDDashboard'
    if ($_p.ClearDefault) {
        try { Remove-ItemProperty -Path $_rootReg -Name 'DefaultConfig' -ErrorAction SilentlyContinue } catch {}
        $script:StatusText.Text = 'Default configuration cleared - you will be prompted on next launch.'
        return
    }
    if (-not $_p.Config) { return }
    if ($_p.SetDefault) {
        if (-not (Test-Path $_rootReg)) { try { New-Item -Path $_rootReg -Force | Out-Null } catch {} }
        try { Set-ItemProperty -Path $_rootReg -Name 'DefaultConfig' -Value $_p.Config.Slug } catch {}
    }
    if ($_p.Config.Path -eq $script:_configFile) { return }
    $script:RegPath      = "$_rootReg\$($_p.Config.Slug)"
    $script:_configFile  = $_p.Config.Path
    try { Invoke-ConfigReload } catch {
        $script:StatusText.Text = "Config switch failed: $_"
        return
    }
    if ($script:monRunspace) {
        try { $script:monRunspace.SessionStateProxy.SetVariable('workspaceId', $script:LawWorkspaceResourceId) } catch {}
    }
    $script:nextRefreshAt   = [DateTime]::Now
    $script:StatusText.Text = "Switched to '$($_p.Config.DisplayName)' - refreshing..."
}

# =============================================================================
# Button Handlers
# =============================================================================

$script:SettingsButton.Add_Click({ Show-Settings })
$script:AboutButton.Add_Click({ Show-About })
$script:SwitchConfigButton.Add_Click({ Show-SwitchConfig })
$script:SwitchSubButton.Add_Click({ Show-SwitchSubscription })

# Resolve script directory at script scope (used by tab-azurefiles.ps1 ToolsLaunchButton handler)
$script:dashboardDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$script:RefreshButton.Add_Click({
    if (-not $script:currentJob) {
        $script:nextRefreshAt = [DateTime]::Now
    }
})

# =============================================================================
# Session detail windows, shadow, RDP and messaging -> scripts\session-detail.ps1
# Run Command picker, execution, output and timer   -> scripts\run-command.ps1
# =============================================================================

# (moved) $sessionXaml, Show-SessionDetail, Show-GlobalSessionDetail,
#         Add-SessionContextMenu, Show-MessageComposeDialog,
#         Invoke-SendMessageToUser, Invoke-ShadowFromRow,
#         Invoke-RDPToSessionHost, Start-DetailJob, Update-SessionView,
#         Update-GlobalSessionView, Update-SessionFilter,
#         $script:sdFetchScript, $script:sdLogoffScript,
#         $script:gsFetchScript, $script:gsLogoffScript


# =============================================================================
# Clean up timers when window closes
# =============================================================================

$window.Add_Closed({
    $script:masterTimer.Stop()
    try { if ($script:bgPS)         { $script:bgPS.Stop(); $script:bgPS.Dispose() } }                   catch {}
    try { if ($script:filesPS)      { $script:filesPS.Stop(); $script:filesPS.Dispose() } }             catch {}
    try { if ($script:filesRunspace){ $script:filesRunspace.Close(); $script:filesRunspace.Dispose() } } catch {}
    try { if ($script:bgRunspace)   { $script:bgRunspace.Close(); $script:bgRunspace.Dispose() } }       catch {}
    try { if ($script:hpPool)       { $script:hpPool.Close(); $script:hpPool.Dispose() } }               catch {}
    try { if ($script:metaPool)     { $script:metaPool.Close(); $script:metaPool.Dispose() } }           catch {}
    try { if ($script:saPool)       { $script:saPool.Close(); $script:saPool.Dispose() } }               catch {}
    # Tab-level runspaces (session hosts, infrastructure, session detail)
    try { if ($script:vmPS)                { $script:vmPS.Stop(); $script:vmPS.Dispose() } }                   catch {}
    try { if ($script:vmRefreshRunspace)   { $script:vmRefreshRunspace.Close(); $script:vmRefreshRunspace.Dispose() } } catch {}
    try { if ($script:vmMetricsPS)         { $script:vmMetricsPS.Stop(); $script:vmMetricsPS.Dispose() } }         catch {}
    try { if ($script:vmMetricsRunspace)   { $script:vmMetricsRunspace.Close(); $script:vmMetricsRunspace.Dispose() } } catch {}
    try { if ($script:infraPS)             { $script:infraPS.Stop(); $script:infraPS.Dispose() } }             catch {}
    try { if ($script:infraRefreshRunspace){ $script:infraRefreshRunspace.Close(); $script:infraRefreshRunspace.Dispose() } } catch {}
    try { if ($script:shRunCmdPS)          { $script:shRunCmdPS.Stop(); $script:shRunCmdPS.Dispose() } }       catch {}
    try { if ($script:shRunCmdRS)          { $script:shRunCmdRS.Close(); $script:shRunCmdRS.Dispose() } }      catch {}
    try { if ($script:detailPS)            { $script:detailPS.Stop(); $script:detailPS.Dispose() } }           catch {}
    # Cost-lookup runspaces - these are only alive while Load Costs is in flight.
    # Without explicit cleanup here they become zombie threads if the window is
    # closed or crashes mid-fetch.
    try { if ($script:shCostPS)  { $script:shCostPS.Stop();  $script:shCostPS.Runspace.Dispose();  $script:shCostPS.Dispose() } }  catch {}
    try { if ($script:shTxnPS)   { $script:shTxnPS.Stop();   $script:shTxnPS.Runspace.Dispose();   $script:shTxnPS.Dispose() } }   catch {}
    try { if ($script:isCostPS)  { $script:isCostPS.Stop();  $script:isCostPS.Runspace.Dispose();  $script:isCostPS.Dispose() } }  catch {}
    try { if ($script:isTxnPS)   { $script:isTxnPS.Stop();   $script:isTxnPS.Runspace.Dispose();   $script:isTxnPS.Dispose() } }   catch {}
    try { if ($script:afCostPS)  { $script:afCostPS.Stop();  $script:afCostPS.Runspace.Dispose();  $script:afCostPS.Dispose() } }  catch {}
    # Kill any orphaned MFA child process (powershell.exe running Connect-AzAccount)
    try { if ($script:_mfaProc   -and -not $script:_mfaProc.HasExited)   { $script:_mfaProc.Kill() }   } catch {}
    # Kill any orphaned Profile Tools or Log Viewer child processes
    try { if ($script:toolsProc  -and -not $script:toolsProc.HasExited)  { $script:toolsProc.Kill() }  } catch {}
    try { if ($script:lvProc     -and -not $script:lvProc.HasExited)     { $script:lvProc.Kill() }     } catch {}
    if (Test-Path $contextFile) { Remove-Item $contextFile -Force -ErrorAction SilentlyContinue }
})

# =============================================================================
# Window Icon
# Drop a file named avd-dashboard.ico in the data subfolder to use a custom icon.
# =============================================================================
Set-WindowIcon -Window $window -IconPath (Join-Path $PSScriptRoot 'data\avd-dashboard.ico')

# =============================================================================
# Show Window
# =============================================================================

$window.Add_ContentRendered({
    # Skip activation on first render - the splash is still covering the window.
    # Update-UI will activate and focus once the first data load completes.
    if ($script:firstLoadComplete) {
        $window.Activate()
        $window.Topmost = $true
        $window.Topmost = $false
        $window.Focus()
    }
})

if ($script:DarkTheme) {
    $window.Add_SourceInitialized({
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        $v = 1
        [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
    })
}

[void]$window.ShowDialog()
