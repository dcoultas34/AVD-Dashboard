# =============================================================================
# session-detail.ps1  -  Session detail windows, shadow, RDP and messaging
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Encapsulates the user session detail popup windows and all associated
# operations (shadow, RDP, message, log off) so the main dashboard script
# stays clean. Dot-source this file AFTER the main XAML window is loaded,
# then call the one public lifecycle function:
#
#   Initialize-SessionDetail   - once, after $window and $script:PoolGrid exist;
#                                wires the PoolGrid double-click handler
#
# PUBLIC ENTRY POINTS (called from the main script or card click handlers)
# -------------------------------------------------------------------------
#   Show-SessionDetail         - per-pool session window (PoolGrid double-click)
#   Show-GlobalSessionDetail   - cross-pool session window (summary card clicks)
#
# DATA FLOW
# ---------
# Both session windows fetch data on demand via Start-DetailJob, which runs a
# scriptblock in a dedicated MTA runspace and fires a callback on the UI thread
# when complete. The per-pool and global variants each have their own fetch/
# logoff scriptblocks ($script:sdFetchScript / $script:sdLogoffScript and
# $script:gsFetchScript / $script:gsLogoffScript respectively).
#
# Each fetch script:
#   1. Queries the AVD REST API for user sessions in the host pool(s)
#   2. If a Log Analytics Workspace (LAW) is configured, runs a single
#      optimised KQL query against WVDConnections + WVDConnectionNetworkData
#      to enrich each session row with:
#        - Client info:     ClientType, ClientOS, ClientVersion, UdpUse,
#                           TransportType, UdpType, ClientSideIPAddress,
#                           IsClientPrivateLink,
#                           IsSessionHostPrivateLink, GatewayRegion
#        - RTT metrics:     Avg RTT, P95 RTT (from WVDConnectionNetworkData)
#        - Bandwidth:       Avg BW, P95 BW   (from WVDConnectionNetworkData,
#                           EstAvailableBandwidthKBps converted to Mbps)
#        - Connect Time:    Started -> Connected duration (from WVDConnections
#                           State events per CorrelationId; includes full
#                           gateway orchestration + load balancing time)
#      Client info uses arg_max(TimeGenerated) on rows where ClientType is
#      non-empty to get the latest connection event (disconnect/completion
#      events lack client fields). RTT and BW are aggregated across all
#      connection network data samples in the 8h window.
#      Username matching normalises both sides to short username (strip
#      DOMAIN\ prefix and @domain suffix) for reliable matching.
#   3. Returns PSCustomObject rows to the UI callback which builds a DataTable.
#
# CONFIGURATION (near top of this file)
# --------------------------------------
#   $script:Show*                 - column visibility toggles (set $false to hide)
#   $script:LawRttAmberMs/RedMs  - RTT heat map thresholds (green/amber/red)
#
# MFA / CONDITIONAL ACCESS RE-AUTHENTICATION
# -------------------------------------------
# ARM write operations (logoff DELETE, drain PATCH) may fail with HTTP 403
# "RequestDisallowedByAzure" when Azure Conditional Access requires MFA
# step-up.  Scriptblocks detect this and return an
# MFA_CHALLENGE:<base64-claims>:::<session> marker.  OnComplete callbacks
# call Resolve-MfaChallenge (in rest-api-helpers.ps1), which launches a
# hidden child powershell.exe.
#
# First MFA: prompts the user, child runs Connect-AzAccount -ClaimsChallenge
# (browser MFA) then executes the ARM operations via Invoke-AzRestMethod.
# Sets $_mfaEverDone flag on success.
#
# Subsequent MFA: no dialog, child just does Import-Module Az.Accounts
# (loads saved context + MSAL cache from disk) then Invoke-AzRestMethod.
# The Az HTTP pipeline handles claims challenges using cached MFA tokens
# silently - no browser needed.  If cache has expired, resets the flag
# so the next attempt shows the full interactive MFA dialog again.
#
# DEPENDENCIES (from the main script scope)
# -----------------------------------------
#   $window                  - main WPF Window
#   $script:PoolGrid         - Per Host Pool DataGrid (for double-click handler)
#   $contextFile             - path to the exported Az context file
#   $subscriptionId          - current subscription ID
#   $RefreshIntervalSeconds  - auto-refresh interval
#   $RunspaceMaxSessionPool  - max parallel runspaces for global session fetch
#   $_cfg                    - config hashtable (Messaging defaults, Shadow settings)
#   $script:azArmToken       - ARM bearer token (refreshed on logoff)
#   $script:azAccountId      - Azure account ID
#   $script:azTenantId       - Azure tenant ID
#   $script:vmRgMap          - VM name -> resource group map (for IP resolution)
#   $script:ShadowMethod     - 'MSTSC' or 'MSRA'
#   $script:ShadowNoConsent  - $true to pass /noConsentPrompt to mstsc
#   $script:ShadowUseIP      - $true to resolve VM private IP before connecting
#   $script:lastData         - most recent dashboard data (host pool list for global view)
#   $script:LawWorkspaceResourceId - Log Analytics Workspace resource ID (for LAW queries)
#   $script:LogFile          - log file path (set by -EnableLogging on main script)
#   $script:restHelperDef    - compact Invoke-Arm function string for runspace injection
# =============================================================================

# Track the currently open detail window so we can close it before opening a new one.
# This prevents $script:sd* variable collisions when switching between detail views.
$script:sdOpenWindow = $null

# Optional host-name pre-filter applied by Update-SessionFilter.
# Set by Show-SessionDetail when called from the Session Hosts tab double-click;
# cleared by Show-GlobalSessionDetail and by Show-SessionDetail when no filter is passed.
$script:sdHostFilter = ''

# (Session detail LAW logging uses the main -EnableLogging log file when enabled)

# =============================================================================
# Session Detail - Column visibility toggles
# Set to $false to hide a column from the session detail grid.
# =============================================================================
$script:ShowClientType       = $true   # Client Type (e.g. HTML, RDC)
$script:ShowClientOS         = $true   # Client OS (e.g. Windows 11)
$script:ShowClientVersion    = $true   # Client Version string
# --- RDP Transport columns ---
# WVDConnections has three transport-related fields: UdpUse, TransportType, UdpType.
# IMPORTANT: These fields only reflect the INITIAL TCP WebSocket negotiation. They do NOT
# update after the client upgrades to RDP Shortpath (UDP). For active sessions,
# TransportType/UdpType will always show "TCP Websocket" even when UDP Multipath is active.
# The accurate transport is only recorded in:
#   1. WVDConnections "Completed" rows (at disconnect) - but not useful for active sessions
#   2. WVDCheckpoints "ShortpathEstablished" event - Parameters.initialUdpType
# Because of this, RDP Shortpath/TransportType/UDPType are hidden by default (misleading),
# and the "Transport" column (from WVDCheckpoints) is the recommended source of truth.
$script:ShowRDPShortpath     = $false  # RDP Shortpath (raw UdpUse from WVDConnections - unreliable for active sessions)
$script:ShowTransportType    = $false  # Transport Type (from WVDConnections - only shows initial TCP negotiation)
$script:ShowUDPType          = $false  # UDP Type (from WVDConnections - only shows initial TCP negotiation)
# Transport: actual negotiated transport from WVDCheckpoints "ShortpathEstablished" event.
# After Shortpath upgrade, WVDCheckpoints logs the real protocol:
#   Name == "ShortpathEstablished", Parameters.initialUdpType = e.g. "Multipath_Direct_UDP"
# Values include: Multipath_Direct_UDP, Multipath_Relayed_UDP, Direct_UDP, Relayed_UDP.
# Shows "-" if no Shortpath upgrade occurred (session stayed on TCP WebSocket).
$script:ShowTransport        = $true   # Transport (from WVDCheckpoints ShortpathEstablished)
$script:ShowClientIP         = $true   # Client IP (ClientSideIPAddress from WVDConnections)
$script:ShowClientPrivLink   = $true   # IsClientPrivateLink
$script:ShowHostPrivLink     = $true   # IsSessionHostPrivateLink
$script:ShowAvgRTT           = $true   # Avg RTT (ms)
$script:ShowP95RTT           = $true   # P95 RTT (ms)
$script:ShowAvgBW            = $true   # Avg Bandwidth (Kbps/Mbps)
$script:ShowP95BW            = $true   # P95 Bandwidth (Kbps/Mbps)
$script:ShowConnectTime      = $true   # Connect Time (Started -> Connected duration)
$script:ShowGatewayRegion    = $true   # Gateway Region (Azure gateway region)

# =============================================================================
# RTT heat map thresholds for Avg RTT and P95 RTT columns.
# =============================================================================
$script:LawRttAmberMs = 100   # >= this ms -> amber
$script:LawRttRedMs   = 200   # >= this ms -> red

# =============================================================================
# LAW connection lookup window for WVDConnections and WVDCheckpoints queries.
# WVDConnectionNetworkData (RTT/BW) is always restricted to the last 8 hours to
# reflect current network performance. However, WVDConnections and WVDCheckpoints
# only record events at connection time (not continuously), so long-running sessions
# whose original connect event is older than 8h would show no data. This window
# controls how far back those one-time events are searched.
# Set to cover the maximum expected session lifetime in your environment.
#
#   $script:LawConnectionLookbackWindow  - KQL ago() duration  e.g. '8h', '24h', '7d'
#   $script:LawConnectionLookbackTimespan - ISO 8601 equivalent e.g. 'PT8H', 'P1D', 'P7D'
#   Both values must represent the same duration and be updated together.
# =============================================================================
$script:LawConnectionLookbackWindow   = '24h'   # KQL ago() syntax  - used inside the query
$script:LawConnectionLookbackTimespan = 'P1D'   # ISO 8601 duration - used in the API request body

# =============================================================================
# Client Type / Client OS friendly name mappings
# Raw values from WVDConnections are long package identifiers. These maps
# translate them to short, readable names shown in the session detail grid.
# Add new entries as new client types are observed in your environment.
# =============================================================================
$script:ClientTypeMap = @{
    'com.microsoft.rdc.windows.wa.msrdc.msix.x64'     = 'Windows App'
    'com.microsoft.rdc.windows.wa.msrdc.msix.arm64'   = 'Windows App (ARM)'
    'com.microsoft.rdc.macos'                          = 'macOS App'
    'com.microsoft.rdc.ios'                            = 'iOS App'
    'com.microsoft.rdc.android'                        = 'Android App'
    'com.microsoft.rdc.windows.msrdcw'                 = 'Remote Desktop (MSRDCW)'
    'com.microsoft.rdc.html'                           = 'Web Browser'
}
$script:ClientOSMap = @{
    'WINDOWS' = 'Windows'
    'MACOS'   = 'macOS'
    'IOS'     = 'iOS'
    'ANDROID' = 'Android'
    'LINUX'   = 'Linux'
}

# ---------------------------------------------------------------------------
# CIDR matching helpers - classify Client IP as Office / VPN / Public
# ---------------------------------------------------------------------------

function script:Test-IpInCidr {
    param([string]$IP, [string]$Cidr)
    if (-not $Cidr -or $Cidr -notmatch '/') { return $false }
    $parts = $Cidr -split '/'
    $netBytes = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    $ipBytes  = [System.Net.IPAddress]::Parse($IP).GetAddressBytes()
    $bits     = [int]$parts[1]
    for ($i = 0; $i -lt 4; $i++) {
        $mask = if ($bits -ge 8) { 255 } elseif ($bits -gt 0) { [byte](256 - [Math]::Pow(2, 8 - $bits)) } else { 0 }
        if (($ipBytes[$i] -band $mask) -ne ($netBytes[$i] -band $mask)) { return $false }
        $bits = [Math]::Max(0, $bits - 8)
    }
    return $true
}

function script:Get-IpLocation {
    param([string]$RawIP)
    if (-not $RawIP -or $RawIP -eq '-') { return '-' }
    # Take first IP, strip port if present (e.g. "172.17.112.25, 20.162.97.19:46080")
    $first = ($RawIP -split ',')[0].Trim()
    $first = ($first -split ':')[0]
    if (-not $first -or $first -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return '-' }
    # Check configured named ranges in order (first match wins)
    foreach ($entry in $script:NetworkRangesList) {
        foreach ($cidr in $entry.Ranges) {
            if (Test-IpInCidr -IP $first -Cidr $cidr) { return $entry.Label }
        }
    }
    # RFC 1918 private ranges not matched above → Office
    foreach ($cidr in @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')) {
        if (Test-IpInCidr -IP $first -Cidr $cidr) { return 'Office' }
    }
    return 'Public'
}

# =============================================================================
# CSV Export
# =============================================================================

function script:Invoke-SessionExport {
    if (-not $script:sdDataTable) { return }

    $dlg          = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = "UserSessions_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"

    if ($dlg.ShowDialog() -eq $true) {
        try {
            $hidden = @('Session Host FQDN', 'Host Pool', '_AvgRTTSort', '_P95RTTSort', '_AvgRTTColor', '_P95RTTColor')
            $script:sdDataTable.Rows |
                ForEach-Object {
                    $row = $_
                    $obj = [ordered]@{}
                    foreach ($col in $script:sdDataTable.Columns) {
                        if ($col.ColumnName -notin $hidden) {
                            $obj[$col.ColumnName] = $row[$col.ColumnName]
                        }
                    }
                    [PSCustomObject]$obj
                } |
                Export-Csv -Path $dlg.FileName -NoTypeInformation -Force
            $script:sdStatus.Text = "Exported $($script:sdDataTable.Rows.Count) row(s) to $($dlg.FileName)"
        } catch {
            Show-ThemedDialog -Message "Export failed:`n$_" -Title 'Export Error' -Icon 'Error'
        }
    }
}

# Dot-source session history module (lock/unlock and session lifecycle modal)
. "$PSScriptRoot\session-history.ps1"

# =============================================================================
# Session Detail Window XAML
# =============================================================================

$sessionXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="User Sessions"
    Height="520" Width="1140"
    MinHeight="340" MinWidth="800"
    WindowStartupLocation="CenterScreen"
    Background="{DynamicResource Avd.Window.Bg}"
    Foreground="{DynamicResource Avd.Window.Fg}"
    FontFamily="Segoe UI">
    <Window.Resources>
        <!-- THEME_SLOT -->
        <Style TargetType="DataGridCell">
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
    </Window.Resources>
    <DockPanel>

        <!-- Status bar -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.StatusBar.Bg}" Height="32">
            <Grid Margin="12,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="SessionStatus" Grid.Column="0"
                           Foreground="White" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="SessionCountdown" Grid.Column="1"
                           Foreground="#B3D7F5" FontSize="12"
                           VerticalAlignment="Center" Margin="0,0,12,0"/>
                <Button x:Name="SessionRefreshButton" Grid.Column="2"
                        Content="Refresh" Margin="0,0,8,0"
                        Background="#005A9E" Foreground="White" BorderThickness="0"
                        Padding="14,5" FontSize="12" FontWeight="SemiBold" Cursor="Hand"
                        VerticalAlignment="Center">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="Bdr" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="Bdr" Property="Background" Value="#004F8C"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="LogoffDisconnectedButton" Grid.Column="3"
                        Content="Log Off Disconnected" Margin="0,0,8,0"
                        Background="#8B2500" Foreground="White" BorderThickness="0"
                        Padding="14,5" FontSize="12" FontWeight="SemiBold" Cursor="Hand"
                        VerticalAlignment="Center">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdDc" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdDc" Property="Background" Value="#6B1A00"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="MessageAllButton" Grid.Column="4"
                        Content="Message All" Margin="0,0,8,0"
                        Background="#038387" Foreground="White" BorderThickness="0"
                        Padding="14,5" FontSize="12" FontWeight="SemiBold" Cursor="Hand"
                        VerticalAlignment="Center">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdMsgA" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdMsgA" Property="Background" Value="#025E61"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="MessageSelectedButton" Grid.Column="5"
                        Content="Message Selected" IsEnabled="False" Margin="0,0,8,0"
                        Background="#038387" Foreground="White" BorderThickness="0"
                        Padding="14,5" FontSize="12" FontWeight="SemiBold" Cursor="Hand"
                        VerticalAlignment="Center">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdMsg" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="BdMsg" Property="Background" Value="#888"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdMsg" Property="Background" Value="#025E61"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="LogoffButton" Grid.Column="6"
                        Content="Log Off Selected" IsEnabled="False"
                        Background="#C42B1C" Foreground="White" BorderThickness="0"
                        Padding="14,5" FontSize="12" FontWeight="SemiBold" Cursor="Hand"
                        VerticalAlignment="Center">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="Bd" Property="Background" Value="#888"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="#A02010"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>
        </Border>

        <!-- Header -->
        <StackPanel DockPanel.Dock="Top" Margin="20,14,20,10">
            <TextBlock x:Name="SessionTitle" FontSize="18" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"/>
            <TextBlock x:Name="SessionSubtitle" FontSize="12" Foreground="{DynamicResource Avd.Fg.Muted}" Margin="0,3,0,0"/>
            <TextBlock Text="Tip: Hold Ctrl or Shift to select multiple sessions, then click Log Off Selected."
                       FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,4,0,0"/>
        </StackPanel>

        <!-- Filter bar -->
        <Border DockPanel.Dock="Top" Margin="20,0,20,6">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="220"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Filter user:" VerticalAlignment="Center"
                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,0,8,0"/>
                <TextBox x:Name="SessionFilterBox" Grid.Column="1"
                         FontSize="12" Padding="8,4" VerticalContentAlignment="Center"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}"
                         Foreground="{DynamicResource Avd.Fg.Label}"/>
                <Button x:Name="SessionClearFiltersButton" Grid.Column="2"
                        Content="Clear Filters" Background="#888" Foreground="White"
                        BorderThickness="0" Padding="10,4" FontSize="11" Cursor="Hand"
                        VerticalAlignment="Center" Margin="8,0,0,0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdCf" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdCf" Property="Background" Value="#666"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="ExportCsvButton" Grid.Column="4"
                        Content="Export CSV" IsEnabled="False"
                        Background="#005A9E" Foreground="White" BorderThickness="0"
                        Padding="14,5" FontSize="12" FontWeight="SemiBold" Cursor="Hand"
                        VerticalAlignment="Center">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdEx" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="BdEx" Property="Background" Value="#888"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdEx" Property="Background" Value="#004F8C"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="AdvancedDetailButton" Grid.Column="5"
                        Content="Session History" IsEnabled="False"
                        Background="#005A9E" Foreground="White" BorderThickness="0"
                        Padding="14,5" FontSize="12" FontWeight="SemiBold" Cursor="Hand"
                        VerticalAlignment="Center" Margin="6,0,0,0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdAdv" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="BdAdv" Property="Background" Value="#888"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdAdv" Property="Background" Value="#004F8C"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>
        </Border>

        <!-- Session grid - extended selection mode -->
        <DataGrid x:Name="SessionGrid" Margin="20,0,20,12"
                  Background="{DynamicResource Avd.Grid.Bg}" BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1"
                  RowBackground="{DynamicResource Avd.Grid.Bg}" AlternatingRowBackground="{DynamicResource Avd.AltRow.Bg}"
                  Foreground="{DynamicResource Avd.Window.Fg}"
                  GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{DynamicResource Avd.Border.Grid}"
                  ColumnHeaderHeight="36" RowHeight="32" FontSize="13"
                  IsReadOnly="True" AutoGenerateColumns="True"
                  SelectionMode="Extended" SelectionUnit="FullRow"
                  CanUserResizeRows="False" CanUserAddRows="False"
                  RowHeaderWidth="0"
                  HorizontalScrollBarVisibility="Auto">
            <!-- Ctrl+MouseWheel zoom: LayoutTransform with ScaleTransform scales the
                 entire grid (headers, rows, text) uniformly. Wired to PreviewMouseWheel
                 in both Show-GlobalSessionDetail and Show-SessionDetail code-behind.
                 Range: 60% (fit more rows on screen) to 150% (enlarge for readability). -->
            <DataGrid.LayoutTransform>
                <ScaleTransform x:Name="GridZoom" ScaleX="1" ScaleY="1"/>
            </DataGrid.LayoutTransform>
            <DataGrid.Resources>
                <Style TargetType="DataGridColumnHeader">
                    <Setter Property="Background"                 Value="{DynamicResource Avd.ColHeader.Bg}"/>
                    <Setter Property="Foreground"                 Value="White"/>
                    <Setter Property="FontWeight"                 Value="SemiBold"/>
                    <Setter Property="FontSize"                   Value="12"/>
                    <Setter Property="Padding"                    Value="12,0"/>
                    <Setter Property="HorizontalContentAlignment" Value="Center"/>
                    <Setter Property="BorderBrush"                Value="{DynamicResource Avd.ColHeader.Border}"/>
                    <Setter Property="BorderThickness"            Value="0,0,1,0"/>
                </Style>
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
                </Style>
            </DataGrid.Resources>
        </DataGrid>

    </DockPanel>
</Window>
'@


# =============================================================================
# Global Session Detail - fetches sessions across ALL host pools, filtered by state
# =============================================================================

# ── MFA / Conditional Access handling in logoff scripts ──────────────────────
# Azure Conditional Access (CA) policies can enforce MFA at the ARM level.
# When a DELETE (logoff) request is made with a token that lacks the required
# MFA claim, ARM returns HTTP 403 with error code "RequestDisallowedByAzure".
#
# WHY INVOKE-ARM CAN'T HANDLE THIS:
#   Invoke-Arm is a lightweight REST helper that gets a bearer token and makes
#   a simple HTTP call. It has no claims challenge handling - if it gets a 403,
#   it just throws. Adding claims handling to Invoke-Arm would be impractical
#   because it runs in background runspaces that can't do interactive auth.
#
# WHY A CHILD PROCESS IS NEEDED:
#   Invoke-AzRestMethod (from Az.Accounts) has a full HTTP pipeline that
#   automatically detects 403 + claims, calls AcquireTokenSilent(claims)
#   against the MSAL token cache, and retries - all transparently. However,
#   it requires Az.Accounts module loaded with a valid context. A child
#   powershell.exe process is used because:
#     - Background runspaces have no interactive host for browser-based MFA
#     - Running Connect-AzAccount on the WPF UI thread would block the
#       dispatcher / message loop
#     - The child process's MSAL tokens are saved to the shared disk cache
#       (~/.Azure/) so subsequent child processes can reuse them silently
#
# MFA DETECTION:
#   The catch blocks below detect RequestDisallowedByAzure and extract the
#   base64-encoded claims challenge from three possible locations (PS5.1
#   exposes different parts of the HTTP response depending on error propagation):
#     1. WWW-Authenticate response header  (standard OAuth2 claims challenge)
#     2. ErrorDetails.Message              (PS5.1 often includes the JSON body)
#     3. Stringified error text            (fallback - body may be in $_.ToString())
#
#   If detected, the error is returned with a "MFA_CHALLENGE:<claims>:::<session>"
#   prefix marker.  The OnComplete callbacks check for this marker and call
#   Resolve-MfaChallenge (defined in rest-api-helpers.ps1), which handles both
#   interactive (first MFA) and silent (subsequent MFA via cached tokens) flows.
# ─────────────────────────────────────────────────────────────────────────────

$script:gsLogoffScript = {
    param($tok, $subId, $restDef, $ids)
    # Define Invoke-Arm in this runspace from the injected string definition
    . ([scriptblock]::Create($restDef))
    $errs = @()
    foreach ($id in $ids) {
        try {
            Invoke-Arm -Method DELETE `
                -Path "/subscriptions/$subId/resourceGroups/$($id.HpRG)/providers/Microsoft.DesktopVirtualization/hostPools/$($id.HpName)/sessionHosts/$($id.SessionHost)/userSessions/$($id.SessionId)?force=true" `
                -Token $tok -ApiVersion '2024-04-03' -FullResponse | Out-Null
        }
        catch {
            $errText = "$_"
            # Detect MFA/Conditional Access enforcement (ARM 403 with claims challenge).
            # See comment block above gsLogoffScript for full explanation.
            if ($errText -match 'RequestDisallowedByAzure' -or $errText -match 'insufficient_claims') {
                $mfaClaims = $null
                try {
                    # 1) WWW-Authenticate header: walk exception chain to find HttpWebResponse
                    #    (PS5.1 wraps the original WebException in a RuntimeException on re-throw)
                    $ex = $_.Exception
                    while ($ex) {
                        if ($ex.Response) {
                            $wwwAuth = $ex.Response.Headers['WWW-Authenticate']
                            if ($wwwAuth -match 'claims="([^"]+)"') { $mfaClaims = $Matches[1] }
                            break
                        }
                        $ex = $ex.InnerException
                    }
                } catch {}
                # 2) ErrorDetails.Message: PS5.1 populates this with the JSON response body
                if (-not $mfaClaims) {
                    try {
                        $det = $_.ErrorDetails.Message
                        if ($det -match '"claimsChallenge"\s*:\s*"([^"]+)"') { $mfaClaims = $Matches[1] }
                    } catch {}
                }
                # 3) Stringified error: the full ARM error JSON may appear in $_.ToString()
                if (-not $mfaClaims -and $errText -match '"claimsChallenge"\s*:\s*"([^"]+)"') {
                    $mfaClaims = $Matches[1]
                }
                # Return with MFA_CHALLENGE marker so the OnComplete callback can trigger re-auth
                $errs += "MFA_CHALLENGE:$($mfaClaims):::$($id.HpName)/$($id.SessionHost)/$($id.SessionId): $errText"
            } else {
                $errs += "$($id.HpName)/$($id.SessionHost)/$($id.SessionId): $errText"
            }
        }
    }
    return $errs
}

$script:gsFetchScript = {
    param($tok, $subId, $restDef, $hpList, $stateFilter, $maxPool, $lawId, $rttAmber, $rttRed, $connLookback, $connTimespan, $LogFile, $lawQueryBaseUrl, $lawTok)
    if (-not $maxPool) { $maxPool = 10 }
    # Define Invoke-Arm in this runspace from the injected string definition
    . ([scriptblock]::Create($restDef))

    # Plain RunspacePool - no module imports needed (REST API via bearer token)
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, [Math]::Min($hpList.Count, $maxPool))
    $pool.Open()

    $hpFetch = [scriptblock]::Create($restDef + @'
        $tok = $args[0]; $subId = $args[1]; $rg = $args[2]; $hp = $args[3]
        $sessions = @(Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.DesktopVirtualization/hostPools/$hp/userSessions" -Token $tok -ApiVersion '2024-04-03')
        foreach ($s in $sessions) {
            $parts = $s.name.Split("/")
            [PSCustomObject]@{
                HpName     = $hp
                UserName   = if ($s.properties.activeDirectoryUserName) { $s.properties.activeDirectoryUserName } else { $s.properties.userPrincipalName }
                SessionId  = $parts[-1]
                ShortHost  = ($parts[-2] -split "\.")[0]
                FullHost   = $parts[-2]
                State      = [string]$s.properties.sessionState
                Type       = if ($s.properties.applicationType) { [string]$s.properties.applicationType } else { "Desktop" }
                CreateTime = $s.properties.createTime
            }
        }
'@)

    $handles = @(foreach ($hp in $hpList) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($hpFetch).AddArgument($tok).AddArgument($subId).AddArgument($hp.RG).AddArgument($hp.Name)
        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    })

    $allList = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($h in $handles) {
            $out = $h.PS.EndInvoke($h.Handle); $h.PS.Dispose()
            if ($out) { foreach ($item in $out) { $allList.Add($item) } }
        }
    } finally {
        # Safety net: dispose any PS instances not yet disposed (prevents zombie leaks)
        foreach ($h in $handles) { try { $h.PS.Dispose() } catch {} }
        $pool.Close(); $pool.Dispose()
    }
    $all = @($allList)

    $filtered = if ($stateFilter -eq "All") { $all } else { $all | Where-Object { $_.State -eq $stateFilter } }
    $now = [DateTime]::UtcNow
    $rows = @($filtered | ForEach-Object {
        $span = if ($_.CreateTime) { $now - ([DateTime]$_.CreateTime).ToUniversalTime() } else { $null }
        $sessionAge = if ($span) {
            if    ($span.TotalDays  -ge 1) { "{0}d {1}h {2}m" -f [int]$span.TotalDays, $span.Hours, $span.Minutes }
            elseif ($span.TotalHours -ge 1) { "{0}h {1}m"      -f [int]$span.TotalHours, $span.Minutes }
            else                            { "{0}m"            -f [int]$span.TotalMinutes }
        } else { "" }
        $logonTime = if ($_.CreateTime) { ([DateTime]$_.CreateTime).ToLocalTime().ToString("MM/dd/yyyy h:mm tt") } else { "" }
        [PSCustomObject]@{
            "Host Pool"         = $_.HpName
            "User"              = $_.UserName
            "ID"                = $_.SessionId
            "Session Host"      = $_.ShortHost
            "Session Host FQDN" = $_.FullHost
            "State"             = $_.State
            "Session Type"      = $_.Type
            "Logon Time"        = $logonTime
            "Connect Time"      = "-"
            "Session Age"       = $sessionAge
            "Avg RTT"           = "-"
            "P95 RTT"           = "-"
            "Avg BW"            = "-"
            "P95 BW"            = "-"
            "Transport"         = "-"
            "Gateway Region"    = "-"
            "Client Type"       = "-"
            "Client OS"         = "-"
            "Client Version"    = "-"
            "RDP Shortpath"     = "-"
            "Transport Type"    = "-"
            "UDP Type"          = "-"
            "Client IP"         = "-"
            "Client Private Link"  = "-"
            "Host Private Link"    = "-"
            "_AvgRTTSort"       = [double]-1
            "_P95RTTSort"       = [double]-1
            "_AvgRTTColor"      = ""
            "_P95RTTColor"      = ""
            "_LawEnriched"      = $false
        }
    })

    # Query WVDConnections + WVDConnectionNetworkData for per-user RTT and client info
    # UserName format: AVD REST may return DOMAIN\user or user@domain.com.
    # WVDConnections.UserName is typically UPN (user@domain.com).
    # We normalise both sides to short username (strip domain) for reliable matching.
    if ($lawId -and $rows.Count -gt 0) {
        try {
            $getShortUser = { param($u)
                $u = $u.ToLower()
                if ($u.Contains('\')) { $u = $u.Split('\')[-1] }
                if ($u.Contains('@')) { $u = $u.Split('@')[0] }
                $u
            }

            $pairs = @($rows | ForEach-Object {
                $u  = & $getShortUser $_.'User'
                $sh = $_.'Session Host'.ToLower()
                "'$u|$sh'"
            } | Select-Object -Unique)
            $pairList = $pairs -join ','

            # Single optimised KQL query combining client info, RTT/BW metrics, and connect time.
            # All three datasets are derived from the same base 'conns' filtered set.
            # Results are joined by UserKey (shortuser|sessionhost) for per-user-session data.
            $lawKql = @"
// Base: all WVDConnections rows matching our user|host pairs.
// Uses ago($($script:LawConnectionLookbackWindow)) so that long-running sessions are still matched -
// the original connection event must be found here to obtain the CorrelationId used
// to join WVDConnectionNetworkData. RTT/BW data is restricted to ago(8h) separately.
// Adjust LawConnectionLookbackWindow at the top of session-detail.ps1.
let pairs = dynamic([$pairList]);
let conns = WVDConnections
| where TimeGenerated > ago($connLookback)
| extend SH = tolower(split(SessionHostName, '.')[0])
| extend ShortUser = tolower(case(UserName contains '\\', tostring(split(UserName, '\\')[1]), UserName contains '@', tostring(split(UserName, '@')[0]), UserName))
| extend UserKey = strcat(ShortUser, '|', SH)
| where UserKey in (pairs);
// Client info: latest connection event per user (filter isnotempty to skip disconnect events)
let clientInfo = conns
| where isnotempty(ClientType)
| summarize arg_max(TimeGenerated, ClientType, ClientOS, ClientVersion, UdpUse, TransportType, UdpType, ClientSideIPAddress, IsClientPrivateLink, IsSessionHostPrivateLink, GatewayRegion) by UserKey
| project UserKey, ClientType, ClientOS, ClientVersion, UdpUse, TransportType, UdpType, ClientSideIPAddress, IsClientPrivateLink, IsSessionHostPrivateLink, GatewayRegion;
// RTT + Bandwidth: aggregate from WVDConnectionNetworkData, pre-filtered by CorrelationId.
// Restricted to ago(8h) to reflect current/recent network performance only.
// EstAvailableBandwidthKBps is in KBps (kilobytes/sec); converted to Mbps in PowerShell
let cids = conns | project CorrelationId;
let rttData = WVDConnectionNetworkData
| where TimeGenerated > ago(8h)
| where CorrelationId in (cids)
| join kind=inner (conns | project CorrelationId, UserKey) on CorrelationId
| summarize AvgRtt = round(avg(EstRoundTripTimeInMs), 0),
            P95Rtt = round(percentile(EstRoundTripTimeInMs, 95), 0),
            AvgBW  = round(avg(EstAvailableBandwidthKBps), 0),
            P95BW  = round(percentile(EstAvailableBandwidthKBps, 95), 0)
         by UserKey;
// Connect time: Started -> Connected duration per CorrelationId, take most recent per user.
// Includes full gateway orchestration + load balancing time (more accurate than portal).
let connectTime = conns
| summarize StartTime = minif(TimeGenerated, State == "Started"),
            ConnectedTime = minif(TimeGenerated, State == "Connected")
         by CorrelationId, UserKey
| where isnotempty(StartTime) and isnotempty(ConnectedTime)
| extend ConnectSec = datetime_diff('second', ConnectedTime, StartTime)
| summarize arg_max(StartTime, ConnectSec) by UserKey
| project UserKey, ConnectSec;
// Transport: actual negotiated transport from WVDCheckpoints "ShortpathEstablished" event.
// WVDConnections Started/Connected rows always show "TCP Websocket" (initial negotiation).
// After Shortpath upgrade, the real protocol is recorded in WVDCheckpoints where
// Name == "ShortpathEstablished" and Parameters.initialUdpType contains the value
// (e.g. "Multipath_Direct_UDP", "Multipath_Relayed_UDP", "Direct_UDP", "Relayed_UDP").
// Shows empty/null if no Shortpath upgrade occurred (session stayed on TCP).
// Uses ago($($script:LawConnectionLookbackWindow)) to match long-running sessions -
// ShortpathEstablished fires once at connection time, so for old sessions the event
// is outside an 8h window. Adjust LawConnectionLookbackWindow at the top of session-detail.ps1.
let transport = WVDCheckpoints
| where TimeGenerated > ago($connLookback)
| where Name == "ShortpathEstablished"
| extend ParsedParams = parse_json(Parameters)
| extend TransportUdp = tostring(ParsedParams.initialUdpType)
| where isnotempty(TransportUdp)
| join kind=inner (conns | project CorrelationId, UserKey) on CorrelationId
| summarize arg_max(TimeGenerated, TransportUdp) by UserKey
| project UserKey, TransportUdp;
// Final join: client info left-joined with RTT/BW, connect time, and transport
clientInfo
| join kind=leftouter (rttData) on UserKey
| join kind=leftouter (connectTime) on UserKey
| join kind=leftouter (transport) on UserKey
| project UserKey, ClientType, ClientOS, ClientVersion, UdpUse, TransportType, UdpType, ClientSideIPAddress, IsClientPrivateLink, IsSessionHostPrivateLink, GatewayRegion, AvgRtt, P95Rtt, AvgBW, P95BW, ConnectSec, TransportUdp
"@
            $lawBody = @{ query = $lawKql; timespan = $connTimespan }
            $lawSw = $null; if ($LogFile) { $lawSw = [System.Diagnostics.Stopwatch]::StartNew() }
            $lawResp = if ($lawQueryBaseUrl -and $lawTok) {
                Invoke-RestMethod -Method POST -Uri "$lawQueryBaseUrl/v1$lawId/query" `
                    -Body (ConvertTo-Json $lawBody -Compress) `
                    -Headers @{ Authorization = "Bearer $lawTok"; 'Content-Type' = 'application/json' }
            } else {
                Invoke-Arm -Method POST -Path "$lawId/api/query" -Token $tok -ApiVersion '2020-08-01' -Body $lawBody -FullResponse
            }
            if ($LogFile -and $lawSw) {
                $lawSw.Stop()
                $rowCount = if ($lawResp.tables -and $lawResp.tables[0].rows) { $lawResp.tables[0].rows.Count } else { 0 }
                try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] SessionDetail LAW query: $($pairs.Count) pairs, $rowCount rows returned ($($lawSw.ElapsedMilliseconds)ms)`r`n") } catch {}
            }

            # Parse LAW response and map results back to session rows by UserKey.
            # Column names use fallback chain (.name -> .ColumnName -> string) for PS5.1 compat.
            if ($lawResp.tables -and $lawResp.tables[0].rows) {
                $cols = @($lawResp.tables[0].columns | ForEach-Object {
                    $n = [string]$_.name; if (-not $n) { $n = [string]$_.ColumnName }; if (-not $n) { $n = [string]$_ }; $n
                })
                $colsLower = @($cols | ForEach-Object { $_.ToLower() })
                $idxKey     = [array]::IndexOf($colsLower, 'userkey')
                $idxCType   = [array]::IndexOf($colsLower, 'clienttype')
                $idxCOS     = [array]::IndexOf($colsLower, 'clientos')
                $idxCVer    = [array]::IndexOf($colsLower, 'clientversion')
                $idxUdpUse  = [array]::IndexOf($colsLower, 'udpuse')
                $idxTrans   = [array]::IndexOf($colsLower, 'transporttype')
                $idxUdpType = [array]::IndexOf($colsLower, 'udptype')
                $idxCliIP   = [array]::IndexOf($colsLower, 'clientsideipaddress')
                $idxCliPL   = [array]::IndexOf($colsLower, 'isclientprivatelink')
                $idxHostPL  = [array]::IndexOf($colsLower, 'issessionhostprivatelink')
                $idxGwReg   = [array]::IndexOf($colsLower, 'gatewayregion')
                $idxAvgRtt  = [array]::IndexOf($colsLower, 'avgrtt')
                $idxP95Rtt  = [array]::IndexOf($colsLower, 'p95rtt')
                $idxAvgBW   = [array]::IndexOf($colsLower, 'avgbw')
                $idxP95BW   = [array]::IndexOf($colsLower, 'p95bw')
                $idxCSec    = [array]::IndexOf($colsLower, 'connectsec')
                # Transport: initialUdpType from WVDCheckpoints ShortpathEstablished event
                $idxTransUdp = [array]::IndexOf($colsLower, 'transportudp')

                if ($idxKey -ge 0) {
                    $dataMap = @{}
                    foreach ($r in $lawResp.tables[0].rows) {
                        $dataMap[[string]$r[$idxKey]] = $r
                    }
                    foreach ($row in $rows) {
                        $key = "$(& $getShortUser $row.'User')|$($row.'Session Host'.ToLower())"
                        if ($dataMap.ContainsKey($key)) {
                            $row.'_LawEnriched' = $true
                            $r = $dataMap[$key]
                            if ($idxCType  -ge 0 -and $r[$idxCType])  { $row.'Client Type'    = [string]$r[$idxCType] }
                            if ($idxCOS    -ge 0 -and $r[$idxCOS])    { $row.'Client OS'      = [string]$r[$idxCOS] }
                            if ($idxCVer   -ge 0 -and $r[$idxCVer])   { $row.'Client Version'  = [string]$r[$idxCVer] }
                            if ($idxUdpUse  -ge 0 -and $r[$idxUdpUse]  -ne $null -and $r[$idxUdpUse]  -ne '') { $row.'RDP Shortpath'  = [string]$r[$idxUdpUse] }
                            if ($idxTrans   -ge 0 -and $r[$idxTrans]   -ne $null -and $r[$idxTrans]   -ne '') { $row.'Transport Type' = [string]$r[$idxTrans] }
                            if ($idxUdpType -ge 0 -and $r[$idxUdpType] -ne $null -and $r[$idxUdpType] -ne '') { $row.'UDP Type'       = [string]$r[$idxUdpType] }
                            if ($idxCliIP  -ge 0 -and $r[$idxCliIP]  -ne $null -and $r[$idxCliIP]  -ne '') { $row.'Client IP'           = [string]$r[$idxCliIP] }

                            if ($idxCliPL  -ge 0 -and $r[$idxCliPL]  -ne $null -and $r[$idxCliPL]  -ne '') { $row.'Client Private Link' = [string]$r[$idxCliPL] }
                            if ($idxHostPL -ge 0 -and $r[$idxHostPL] -ne $null -and $r[$idxHostPL] -ne '') { $row.'Host Private Link'   = [string]$r[$idxHostPL] }
                            if ($idxGwReg  -ge 0 -and $r[$idxGwReg]  -ne $null -and $r[$idxGwReg]  -ne '') { $row.'Gateway Region'     = [string]$r[$idxGwReg] }
                            if ($idxAvgRtt -ge 0 -and $r[$idxAvgRtt]) {
                                $avgVal = [double]$r[$idxAvgRtt]
                                $row.'Avg RTT'       = "$([int]$avgVal)ms"
                                $row.'_AvgRTTSort'   = $avgVal
                                $row.'_AvgRTTColor'  = if ($avgVal -ge $rttRed) { 'Red' } elseif ($avgVal -ge $rttAmber) { 'Amber' } else { 'Green' }
                            }
                            if ($idxP95Rtt -ge 0 -and $r[$idxP95Rtt]) {
                                $p95Val = [double]$r[$idxP95Rtt]
                                $row.'P95 RTT'       = "$([int]$p95Val)ms"
                                $row.'_P95RTTSort'   = $p95Val
                                $row.'_P95RTTColor'  = if ($p95Val -ge $rttRed) { 'Red' } elseif ($p95Val -ge $rttAmber) { 'Amber' } else { 'Green' }
                            }
                            # EstAvailableBandwidthKBps is KBps (kilobytes/sec); convert to Mbps (* 8 / 1000)
                            if ($idxAvgBW -ge 0 -and $r[$idxAvgBW] -ne $null -and $r[$idxAvgBW] -ne '') {
                                $kbps = [double]$r[$idxAvgBW]
                                $mbps = [Math]::Round($kbps * 8 / 1000, 1)
                                $row.'Avg BW' = "$mbps Mbps"
                            }
                            if ($idxP95BW -ge 0 -and $r[$idxP95BW] -ne $null -and $r[$idxP95BW] -ne '') {
                                $kbps = [double]$r[$idxP95BW]
                                $mbps = [Math]::Round($kbps * 8 / 1000, 1)
                                $row.'P95 BW' = "$mbps Mbps"
                            }
                            if ($idxCSec -ge 0 -and $r[$idxCSec] -ne $null -and $r[$idxCSec] -ne '') {
                                $sec = [int]$r[$idxCSec]
                                $row.'Connect Time' = if ($sec -ge 60) { "{0}m {1}s" -f [Math]::Floor($sec / 60), ($sec % 60) } else { "${sec}s" }
                            }
                            # Transport: raw initialUdpType from WVDCheckpoints ShortpathEstablished
                            if ($idxTransUdp -ge 0 -and $r[$idxTransUdp] -ne $null -and $r[$idxTransUdp] -ne '') { $row.'Transport' = [string]$r[$idxTransUdp] }
                        }
                    }
                }
            }
        } catch {
            # LAW enrichment failure is non-fatal; columns remain as '-'
            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] SessionDetail LAW error: $_`r`n") } catch {} }
        }
    }

    # Transport defaults to "-" (no WVDCheckpoints ShortpathEstablished event found).
    # For rows where LAW enrichment succeeded (_LawEnriched), this means the session
    # is on plain TCP - label it explicitly. Rows without LAW data stay as "-" (unknown).
    foreach ($row in $rows) {
        if ($row.'_LawEnriched' -and $row.'Transport' -eq '-') { $row.'Transport' = 'TCP' }
    }

    $rows
}


# =============================================================================
# Shadow Session - right-click context menu for active sessions
# =============================================================================

function Add-SessionContextMenu {
    param(
        [System.Windows.Controls.DataGrid]$Grid,
        [System.Windows.Controls.Button]$LogoffButton
    )

    $ctxMenu = New-Object System.Windows.Controls.ContextMenu

    $menuShadow  = New-Object System.Windows.Controls.MenuItem
    $menuShadow.Header = "Shadow Session (View Only)"

    $menuControl = New-Object System.Windows.Controls.MenuItem
    $menuControl.Header = "Shadow Session (With Control)"

    $menuSep    = New-Object System.Windows.Controls.Separator

    $menuRDP    = New-Object System.Windows.Controls.MenuItem
    $menuRDP.Header = "RDP to Session Host"

    $menuSep2   = New-Object System.Windows.Controls.Separator

    $menuMsg    = New-Object System.Windows.Controls.MenuItem
    $menuMsg.Header = "Send Message to User"

    $menuSep3   = New-Object System.Windows.Controls.Separator

    $menuLogoff = New-Object System.Windows.Controls.MenuItem
    $menuLogoff.Header = "Log Off Session"

    $menuSep4   = New-Object System.Windows.Controls.Separator

    $menuRunCmd = New-Object System.Windows.Controls.MenuItem
    $menuRunCmd.Header = "Run Command..."

    [void]$ctxMenu.Items.Add($menuShadow)   # [0]
    [void]$ctxMenu.Items.Add($menuControl)  # [1]
    [void]$ctxMenu.Items.Add($menuSep)      # [2]
    [void]$ctxMenu.Items.Add($menuRDP)      # [3]
    [void]$ctxMenu.Items.Add($menuSep2)     # [4]
    [void]$ctxMenu.Items.Add($menuMsg)      # [5]
    [void]$ctxMenu.Items.Add($menuSep3)     # [6]
    [void]$ctxMenu.Items.Add($menuLogoff)   # [7]
    [void]$ctxMenu.Items.Add($menuSep4)     # [8]
    [void]$ctxMenu.Items.Add($menuRunCmd)   # [9]

    $Grid.Add_PreviewMouseRightButtonDown({
        $node = $_.OriginalSource
        while ($null -ne $node -and $node -isnot [System.Windows.Controls.DataGridRow]) {
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        }
        if ($null -ne $node) { $node.IsSelected = $true }
    }.GetNewClosure())

    $Grid.Add_ContextMenuOpening({
        $sel      = @($Grid.SelectedItems)
        $isActive = $sel.Count -gt 0 -and $null -ne $sel[0] -and $sel[0]["State"] -eq "Active"
        $hasRow   = $sel.Count -gt 0 -and $null -ne $sel[0]
        $ctxMenu.Items[0].IsEnabled = $isActive   # Shadow View Only
        $ctxMenu.Items[1].IsEnabled = $isActive   # Shadow With Control
        # [2] = separator
        $ctxMenu.Items[3].IsEnabled = $hasRow     # RDP to Session Host
        # [4] = separator
        $ctxMenu.Items[5].IsEnabled = $isActive   # Send Message (Active only)
        # [6] = separator
        $ctxMenu.Items[7].IsEnabled = $hasRow     # Log Off
        # [8] = separator
        $ctxMenu.Items[9].IsEnabled = $hasRow     # Run Command
    }.GetNewClosure())

    $menuShadow.Add_Click({
        $sel = @($Grid.SelectedItems)
        if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
        $row = $sel[0]
        if ($row["State"] -ne "Active") { return }
        Invoke-ShadowFromRow -SessionHost ([string]$row["Session Host FQDN"]) -SessionId ([string]$row["ID"]) -User ([string]$row["User"]) -AllowControl $false
    }.GetNewClosure())

    $menuControl.Add_Click({
        $sel = @($Grid.SelectedItems)
        if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
        $row = $sel[0]
        if ($row["State"] -ne "Active") { return }
        Invoke-ShadowFromRow -SessionHost ([string]$row["Session Host FQDN"]) -SessionId ([string]$row["ID"]) -User ([string]$row["User"]) -AllowControl $true
    }.GetNewClosure())

    $menuRDP.Add_Click({
        $sel = @($Grid.SelectedItems)
        if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
        $row = $sel[0]
        Invoke-RDPToSessionHost -SessionHost ([string]$row["Session Host FQDN"])
    }.GetNewClosure())

    $menuMsg.Add_Click({
        $sel = @($Grid.SelectedItems)
        if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
        $row = $sel[0]
        if ($row["State"] -ne "Active") { return }
        Invoke-SendMessageToUser `
            -ResourceGroupName ([string]$row["HP RG"]) `
            -HostPoolName      ([string]$row["Host Pool"]) `
            -SessionHostName   ([string]$row["Session Host FQDN"]) `
            -UserSessionId     ([string]$row["ID"]) `
            -User              ([string]$row["User"]) `
            -Owner             ([System.Windows.Window]::GetWindow($Grid))
    }.GetNewClosure())

    $menuLogoff.Add_Click({
        try {
            $LogoffButton.RaiseEvent(
                [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            )
        }
        catch {
            Show-ThemedDialog -Message "Context menu log off error: $_" -Title 'Log Off Error' -Icon 'Error'
        }
    }.GetNewClosure())

    $menuRunCmd.Add_Click({
        $sel = @($Grid.SelectedItems)
        if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
        $row    = $sel[0]
        # "Session Host" column already holds the short VM name (e.g. "avd-vm-0").
        # Avoid $row["HP RG"] - that column is not in the DataTable and accessing it
        # on a DataRowView throws, silently killing the handler. Show-RunCommandPicker
        # resolves the VM resource group from $script:vmRgMap using the VM name.
        $vmName = [string]$row["Session Host"]
        Show-RunCommandPicker -VmName $vmName -RG ''
    }.GetNewClosure())

    $Grid.ContextMenu = $ctxMenu
    $script:shadowCtxMenu = $ctxMenu
}

function script:Show-MessageComposeDialog {
    param(
        [string]$Recipient,
        [System.Windows.Window]$Owner
    )

    $msgXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Send Message to User"
    Height="280" Width="480"
    WindowStartupLocation="CenterOwner"
    ResizeMode="NoResize"
    Background="{DynamicResource Avd.Window.Bg}"
    Foreground="{DynamicResource Avd.Window.Fg}"
    FontFamily="Segoe UI">
    <Window.Resources>
        <!-- THEME_SLOT -->
    </Window.Resources>
    <DockPanel Margin="20">
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal"
                    HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="SendButton" Content="Send" Width="90" Height="32"
                    Background="#0078D4" Foreground="White" BorderThickness="0"
                    FontSize="13" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,8,0">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bdr" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bdr" Property="Background" Value="#005A9E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button x:Name="CancelButton" Content="Cancel" Width="90" Height="32"
                    Background="{DynamicResource Avd.Btn.Cancel.Bg}" Foreground="{DynamicResource Avd.Fg.Label}" BorderThickness="0"
                    FontSize="13" Cursor="Hand">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="BdrC" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BdrC" Property="Background" Value="{DynamicResource Avd.Btn.Cancel.Hover}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>
        <StackPanel>
            <TextBlock x:Name="RecipientLabel" FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,0,0,12"/>
            <TextBlock Text="Title" FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,0,0,4"/>
            <TextBox x:Name="TitleBox" FontSize="13" Padding="8,6"
                     BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                     Background="{DynamicResource Avd.Input.Bg}"
                     Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,12"/>
            <TextBlock Text="Message" FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,0,0,4"/>
            <TextBox x:Name="BodyBox" FontSize="13" Padding="8,6"
                     BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                     Background="{DynamicResource Avd.Input.Bg}"
                     Foreground="{DynamicResource Avd.Fg.Label}" Height="80" TextWrapping="Wrap"
                     AcceptsReturn="True" VerticalScrollBarVisibility="Auto"/>
        </StackPanel>
    </DockPanel>
</Window>
'@

    $msgXaml = $msgXaml -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\..\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    $reader     = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($msgXaml))
    $msgWin     = [Windows.Markup.XamlReader]::Load($reader)
    try { Set-WindowIcon -Window $msgWin -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}
    if ($script:DarkTheme) {
        $msgWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($msgWin)).Handle
            $v = 1
            [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    }
    $sendBtn    = $msgWin.FindName("SendButton")
    $cancelBtn  = $msgWin.FindName("CancelButton")
    $titleBox   = $msgWin.FindName("TitleBox")
    $bodyBox    = $msgWin.FindName("BodyBox")
    $recipLabel = $msgWin.FindName("RecipientLabel")

    $recipLabel.Text = "To: $Recipient"
    $titleBox.Text   = $_cfg.Messaging.DefaultTitle
    $bodyBox.Text    = $_cfg.Messaging.DefaultBody
    $msgWin.Owner    = $Owner

    $sendBtn.Add_Click({
        if ([string]::IsNullOrWhiteSpace($bodyBox.Text)) {
            Show-ThemedDialog -Message 'Please enter a message body.' -Title 'Send Message' -Icon 'Warning'
            return
        }
        $msgWin.DialogResult = $true
    }.GetNewClosure())

    $cancelBtn.Add_Click({ $msgWin.DialogResult = $false }.GetNewClosure())

    if (-not $msgWin.ShowDialog()) { return $null }

    $title = $titleBox.Text.Trim()
    $body  = $bodyBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { $title = $_cfg.Messaging.DefaultTitle }
    return [PSCustomObject]@{ Title = $title; Body = $body }
}

function script:Invoke-SendMessageToUser {
    param(
        [string]$ResourceGroupName,
        [string]$HostPoolName,
        [string]$SessionHostName,
        [string]$UserSessionId,
        [string]$User,
        [System.Windows.Window]$Owner
    )

    $msg = Show-MessageComposeDialog -Recipient $User -Owner $Owner
    if ($null -eq $msg) { return }

    try {
        $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
        Send-ArmUserSessionMessage `
            -SubscriptionId $_subId `
            -ResourceGroup  $ResourceGroupName `
            -HostPool       $HostPoolName `
            -SessionHost    $SessionHostName `
            -SessionId      $UserSessionId `
            -MessageTitle   $msg.Title `
            -MessageBody    $msg.Body `
            -Token          (Get-ArmToken)

        Write-AuditLog -Action 'SendMessage' -Target $SessionHostName -Details "$User - $($msg.Title)"
        Show-ThemedDialog -Message "Message sent to $User successfully." -Title 'Send Message' -Icon 'Information'
    }
    catch {
        Show-ThemedDialog -Message "Failed to send message:`n$_" -Title 'Send Message Error' -Icon 'Error'
    }
}

function script:Invoke-ShadowFromRow {
    param(
        [string]$SessionHost,
        [string]$SessionId,
        [string]$User,
        [bool]$AllowControl
    )

    $WarningPreference = 'SilentlyContinue'
    try {
        $fqdn = $SessionHost

        if ([string]::IsNullOrWhiteSpace($fqdn) -or [string]::IsNullOrWhiteSpace($SessionId)) {
            Show-ThemedDialog -Message 'Could not determine session host or session ID for this row.' -Title 'Shadow Error' -Icon 'Error'
            return
        }

        $target = $fqdn
        if ($script:ShadowUseIP) {
            $vmName = $fqdn.Split(".")[0].ToLower()
            $vmRG   = $script:vmRgMap[$vmName]
            if (-not [string]::IsNullOrWhiteSpace($vmRG)) {
                try {
                    $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
                    $vm     = Get-ArmVirtualMachine -SubscriptionId $_subId -ResourceGroup $vmRG -VmName $vmName -Token (Get-ArmToken)
                    $nicId  = $vm.properties.networkProfile.networkInterfaces[0].id
                    $nic    = Get-ArmNetworkInterface -ResourceId $nicId -Token (Get-ArmToken)
                    $ip     = [string]$nic.properties.ipConfigurations[0].properties.privateIPAddress
                    if (-not [string]::IsNullOrWhiteSpace($ip)) { $target = $ip }
                } catch {
                    Show-ThemedDialog -Message "IP resolution failed, falling back to DNS hostname.`n`n$_" -Title 'Shadow Warning' -Icon 'Warning'
                }
            } else {
                Show-ThemedDialog -Message "VM '$vmName' not found in cached host data.`n`nConnecting via DNS hostname - wait for a dashboard refresh and try again if this fails." -Title 'Shadow Warning' -Icon 'Warning'
            }
        }

        # Audit log - record the shadow connection
        $shadowType = if ($AllowControl) { 'Shadow (Control)' } else { 'Shadow (View)' }
        Write-AuditLog -Action 'Shadow' -Target $vmName -Details "$User (session $SessionId) - $shadowType"

        if ($script:ShadowMethod -eq "MSRA") {
            $shadowArgs = "/OfferRa $target ${User}:$SessionId"
            Start-Process -FilePath "$env:SystemRoot\System32\msra.exe" -ArgumentList $shadowArgs
        } else {
            $shadowArgs = "/v:$target /shadow:$SessionId"
            if ($script:ShadowNoConsent) { $shadowArgs += " /noConsentPrompt" }
            if ($AllowControl) { $shadowArgs += " /control" }
            Write-AuditLog -Action 'ShadowCmd' -Target $target -Details "mstsc.exe $shadowArgs"
            Start-Process -FilePath "$env:SystemRoot\System32\mstsc.exe" -ArgumentList $shadowArgs
        }
    }
    catch {
        Show-ThemedDialog -Message "Failed to start shadow session: $_" -Title 'Shadow Error' -Icon 'Error'
    }
}

function script:Invoke-RDPToSessionHost {
    param(
        [string]$SessionHost,  # FQDN of the session host
        [string]$IPAddress     # optional: pre-resolved IP (skips the API call when already known)
    )

    $WarningPreference = 'SilentlyContinue'
    try {
        if ([string]::IsNullOrWhiteSpace($SessionHost)) {
            Show-ThemedDialog -Message 'Could not determine the session host for this row.' -Title 'RDP Error' -Icon 'Error'
            return
        }

        $target = $SessionHost   # fallback to FQDN if IP resolution fails or disabled
        $vmName = $SessionHost.Split(".")[0].ToLower()

        if (-not [string]::IsNullOrWhiteSpace($IPAddress)) {
            # Caller already resolved the IP (e.g. Session Hosts tab Query Details cache)
            $target = $IPAddress
        } elseif ($script:ShadowUseIP) {
            # Resolve private IP only if ShadowUseIP is enabled (shared setting for both
            # shadow and RDP connections - controlled via Settings UI -> Connection Mode).
            $vmRG   = $script:vmRgMap[$vmName]
            if (-not [string]::IsNullOrWhiteSpace($vmRG)) {
                try {
                    $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
                    $vm     = Get-ArmVirtualMachine -SubscriptionId $_subId -ResourceGroup $vmRG -VmName $vmName -Token (Get-ArmToken)
                    $nicId  = $vm.properties.networkProfile.networkInterfaces[0].id
                    $nic    = Get-ArmNetworkInterface -ResourceId $nicId -Token (Get-ArmToken)
                    $ip     = [string]$nic.properties.ipConfigurations[0].properties.privateIPAddress
                    if (-not [string]::IsNullOrWhiteSpace($ip)) { $target = $ip }
                }
                catch {
                    Show-ThemedDialog -Message "IP resolution failed, falling back to DNS hostname.`n`n$_" -Title 'RDP Warning' -Icon 'Warning'
                }
            } else {
                Show-ThemedDialog -Message "VM '$vmName' not found in cached host data.`n`nConnecting via DNS hostname - wait for a dashboard refresh and try again if this fails." -Title 'RDP Warning' -Icon 'Warning'
            }
        }

        Start-Process -FilePath "$env:SystemRoot\System32\mstsc.exe" -ArgumentList "/v:$target"
    }
    catch {
        Show-ThemedDialog -Message "Failed to launch RDP: $_" -Title 'RDP Error' -Icon 'Error'
    }

    # Audit log outside the try/catch so it never blocks or masks the RDP launch
    try { Write-AuditLog -Action 'RDP' -Target $vmName -Details $target } catch {}
}


# Run Command engine (Import, Picker, Execute, Output, Timer) moved to scripts\run-command.ps1


# =============================================================================
# Async helper - runs a scriptblock in a runspace, fires callback on UI thread
# =============================================================================

function Start-DetailJob {
    param([scriptblock]$JobScript, [object[]]$JobArgs, [scriptblock]$OnComplete)

    if ($script:detailTimer -and $script:detailTimer.IsEnabled) {
        $script:detailTimer.Stop()
        $script:detailTimer = $null
    }
    if ($script:detailPS) {
        try { $script:detailPS.Stop() }           catch {}
        try { $script:detailPS.Runspace.Close() } catch {}
        try { $script:detailPS.Dispose() }        catch {}
        $script:detailPS     = $null
        $script:detailHandle = $null
    }

    $script:detailCallback   = $OnComplete

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()

    $script:detailPS          = [System.Management.Automation.PowerShell]::Create()
    $script:detailPS.Runspace = $rs
    [void]$script:detailPS.AddScript($JobScript)
    foreach ($arg in $JobArgs) { [void]$script:detailPS.AddArgument($arg) }
    $script:detailHandle = $script:detailPS.BeginInvoke()

    $script:detailTimer          = New-Object System.Windows.Threading.DispatcherTimer
    $script:detailTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:detailTimer.Add_Tick({
        if (-not $script:detailHandle.IsCompleted) { return }
        $script:detailTimer.Stop()
        $script:detailTimer = $null
        $result = $null
        try   { $result = $script:detailPS.EndInvoke($script:detailHandle) }
        catch {
            $errMsg = "Runspace error: $_"
            try { $script:sdStatus.Text = $errMsg } catch {}
            Show-ThemedDialog -Message $errMsg -Title 'Log Off Error' -Icon 'Error'
        }
        # Surface any non-terminating stream errors
        if ($script:detailPS.Streams.Error.Count -gt 0) {
            $streamErrs = ($script:detailPS.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
            $errMsg = "Stream errors:`n$streamErrs"
            try { $script:sdStatus.Text = $errMsg } catch {}
            Show-ThemedDialog -Message $errMsg -Title 'Log Off Error' -Icon 'Error'
        }
        try { $script:detailPS.Runspace.Close() } catch {}
        try { $script:detailPS.Dispose() }        catch {}
        $script:detailPS     = $null
        $script:detailHandle = $null
        try { & $script:detailCallback $result }
        catch {
            $errMsg = "Callback error: $_"
            try { $script:sdStatus.Text = $errMsg } catch {}
            Show-ThemedDialog -Message $errMsg -Title 'Log Off Error' -Icon 'Error'
        }
    })
    $script:detailTimer.Start()
}


# =============================================================================
# Per-pool session fetch + logoff scripts
# =============================================================================

$script:sdFetchScript = {
    param($tok, $subId, $restDef, $rg, $hp, $lawId, $rttAmber, $rttRed, $connLookback, $connTimespan, $LogFile, $lawQueryBaseUrl, $lawTok)
    # Define Invoke-Arm in this runspace from the injected string definition
    . ([scriptblock]::Create($restDef))
    $sessions = @(Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.DesktopVirtualization/hostPools/$hp/userSessions" -Token $tok -ApiVersion '2024-04-03')
    if ($sessions.Count -eq 0) { return $null }
    $now = [DateTime]::UtcNow

    # Build session rows
    $rows = @(foreach ($s in $sessions) {
        $parts = $s.name.Split("/")
        $upn   = if ($s.properties.activeDirectoryUserName) { $s.properties.activeDirectoryUserName } else { $s.properties.userPrincipalName }
        $ct    = $s.properties.createTime
        $span  = if ($ct) { $now - ([DateTime]$ct).ToUniversalTime() } else { $null }
        $sessionAge = if ($span) {
            if    ($span.TotalDays  -ge 1) { "{0}d {1}h {2}m" -f [int]$span.TotalDays, $span.Hours, $span.Minutes }
            elseif ($span.TotalHours -ge 1) { "{0}h {1}m"      -f [int]$span.TotalHours, $span.Minutes }
            else                            { "{0}m"            -f [int]$span.TotalMinutes }
        } else { "" }
        $logonTime = if ($ct) { ([DateTime]$ct).ToLocalTime().ToString("MM/dd/yyyy h:mm tt") } else { "" }
        [PSCustomObject]@{
            "User"              = $upn
            "ID"                = $parts[-1]
            "Session Host"      = ($parts[-2] -split '\.')[0]
            "Session Host FQDN" = $parts[-2]
            "State"             = [string]$s.properties.sessionState
            "Session Type"      = if ($s.properties.applicationType) { [string]$s.properties.applicationType } else { "Desktop" }
            "Logon Time"        = $logonTime
            "Connect Time"      = "-"
            "Session Age"       = $sessionAge
            "Avg RTT"           = "-"
            "P95 RTT"           = "-"
            "Avg BW"            = "-"
            "P95 BW"            = "-"
            "Transport"         = "-"
            "Gateway Region"    = "-"
            "Client Type"       = "-"
            "Client OS"         = "-"
            "Client Version"    = "-"
            "RDP Shortpath"     = "-"
            "Transport Type"    = "-"
            "UDP Type"          = "-"
            "Client IP"         = "-"
            "Client Private Link"  = "-"
            "Host Private Link"    = "-"
            "_AvgRTTSort"       = [double]-1
            "_P95RTTSort"       = [double]-1
            "_AvgRTTColor"      = ""
            "_P95RTTColor"      = ""
            "_LawEnriched"      = $false
        }
    })

    # Query WVDConnections + WVDConnectionNetworkData for per-user RTT and client info
    # UserName format: AVD REST may return DOMAIN\user or user@domain.com.
    # WVDConnections.UserName is typically UPN (user@domain.com).
    # We normalise both sides to short username (strip domain) for reliable matching.
    if ($lawId -and $rows.Count -gt 0) {
        try {
            # Normalise username: strip DOMAIN\ prefix or @domain suffix
            $getShortUser = { param($u)
                $u = $u.ToLower()
                if ($u.Contains('\')) { $u = $u.Split('\')[-1] }
                if ($u.Contains('@')) { $u = $u.Split('@')[0] }
                $u
            }

            # Build unique shortuser|sessionhost pairs for the KQL filter
            $pairs = @($rows | ForEach-Object {
                $u  = & $getShortUser $_.'User'
                $sh = $_.'Session Host'.ToLower()
                "'$u|$sh'"
            } | Select-Object -Unique)
            $pairList = $pairs -join ','

            # Single optimised KQL query combining client info, RTT/BW metrics, and connect time.
            # All three datasets are derived from the same base 'conns' filtered set.
            # Results are joined by UserKey (shortuser|sessionhost) for per-user-session data.
            $lawKql = @"
// Base: all WVDConnections rows matching our user|host pairs.
// Uses ago($($script:LawConnectionLookbackWindow)) so that long-running sessions are still matched -
// the original connection event must be found here to obtain the CorrelationId used
// to join WVDConnectionNetworkData. RTT/BW data is restricted to ago(8h) separately.
// Adjust LawConnectionLookbackWindow at the top of session-detail.ps1.
let pairs = dynamic([$pairList]);
let conns = WVDConnections
| where TimeGenerated > ago($connLookback)
| extend SH = tolower(split(SessionHostName, '.')[0])
| extend ShortUser = tolower(case(UserName contains '\\', tostring(split(UserName, '\\')[1]), UserName contains '@', tostring(split(UserName, '@')[0]), UserName))
| extend UserKey = strcat(ShortUser, '|', SH)
| where UserKey in (pairs);
// Client info: latest connection event per user (filter isnotempty to skip disconnect events)
let clientInfo = conns
| where isnotempty(ClientType)
| summarize arg_max(TimeGenerated, ClientType, ClientOS, ClientVersion, UdpUse, TransportType, UdpType, ClientSideIPAddress, IsClientPrivateLink, IsSessionHostPrivateLink, GatewayRegion) by UserKey
| project UserKey, ClientType, ClientOS, ClientVersion, UdpUse, TransportType, UdpType, ClientSideIPAddress, IsClientPrivateLink, IsSessionHostPrivateLink, GatewayRegion;
// RTT + Bandwidth: aggregate from WVDConnectionNetworkData, pre-filtered by CorrelationId.
// Restricted to ago(8h) to reflect current/recent network performance only.
// EstAvailableBandwidthKBps is in KBps (kilobytes/sec); converted to Mbps in PowerShell
let cids = conns | project CorrelationId;
let rttData = WVDConnectionNetworkData
| where TimeGenerated > ago(8h)
| where CorrelationId in (cids)
| join kind=inner (conns | project CorrelationId, UserKey) on CorrelationId
| summarize AvgRtt = round(avg(EstRoundTripTimeInMs), 0),
            P95Rtt = round(percentile(EstRoundTripTimeInMs, 95), 0),
            AvgBW  = round(avg(EstAvailableBandwidthKBps), 0),
            P95BW  = round(percentile(EstAvailableBandwidthKBps, 95), 0)
         by UserKey;
// Connect time: Started -> Connected duration per CorrelationId, take most recent per user.
// Includes full gateway orchestration + load balancing time (more accurate than portal).
let connectTime = conns
| summarize StartTime = minif(TimeGenerated, State == "Started"),
            ConnectedTime = minif(TimeGenerated, State == "Connected")
         by CorrelationId, UserKey
| where isnotempty(StartTime) and isnotempty(ConnectedTime)
| extend ConnectSec = datetime_diff('second', ConnectedTime, StartTime)
| summarize arg_max(StartTime, ConnectSec) by UserKey
| project UserKey, ConnectSec;
// Transport: actual negotiated transport from WVDCheckpoints "ShortpathEstablished" event.
// WVDConnections Started/Connected rows always show "TCP Websocket" (initial negotiation).
// After Shortpath upgrade, the real protocol is recorded in WVDCheckpoints where
// Name == "ShortpathEstablished" and Parameters.initialUdpType contains the value
// (e.g. "Multipath_Direct_UDP", "Multipath_Relayed_UDP", "Direct_UDP", "Relayed_UDP").
// Shows empty/null if no Shortpath upgrade occurred (session stayed on TCP).
// Uses ago($($script:LawConnectionLookbackWindow)) to match long-running sessions -
// ShortpathEstablished fires once at connection time, so for old sessions the event
// is outside an 8h window. Adjust LawConnectionLookbackWindow at the top of session-detail.ps1.
let transport = WVDCheckpoints
| where TimeGenerated > ago($connLookback)
| where Name == "ShortpathEstablished"
| extend ParsedParams = parse_json(Parameters)
| extend TransportUdp = tostring(ParsedParams.initialUdpType)
| where isnotempty(TransportUdp)
| join kind=inner (conns | project CorrelationId, UserKey) on CorrelationId
| summarize arg_max(TimeGenerated, TransportUdp) by UserKey
| project UserKey, TransportUdp;
// Final join: client info left-joined with RTT/BW, connect time, and transport
clientInfo
| join kind=leftouter (rttData) on UserKey
| join kind=leftouter (connectTime) on UserKey
| join kind=leftouter (transport) on UserKey
| project UserKey, ClientType, ClientOS, ClientVersion, UdpUse, TransportType, UdpType, ClientSideIPAddress, IsClientPrivateLink, IsSessionHostPrivateLink, GatewayRegion, AvgRtt, P95Rtt, AvgBW, P95BW, ConnectSec, TransportUdp
"@
            $lawBody = @{ query = $lawKql; timespan = $connTimespan }
            $lawSw = $null; if ($LogFile) { $lawSw = [System.Diagnostics.Stopwatch]::StartNew() }
            $lawResp = if ($lawQueryBaseUrl -and $lawTok) {
                Invoke-RestMethod -Method POST -Uri "$lawQueryBaseUrl/v1$lawId/query" `
                    -Body (ConvertTo-Json $lawBody -Compress) `
                    -Headers @{ Authorization = "Bearer $lawTok"; 'Content-Type' = 'application/json' }
            } else {
                Invoke-Arm -Method POST -Path "$lawId/api/query" -Token $tok -ApiVersion '2020-08-01' -Body $lawBody -FullResponse
            }
            if ($LogFile -and $lawSw) {
                $lawSw.Stop()
                $rowCount = if ($lawResp.tables -and $lawResp.tables[0].rows) { $lawResp.tables[0].rows.Count } else { 0 }
                try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] SessionDetail LAW query: $($pairs.Count) pairs, $rowCount rows returned ($($lawSw.ElapsedMilliseconds)ms)`r`n") } catch {}
            }

            # Parse LAW response and map results back to session rows by UserKey.
            # Column names use fallback chain (.name -> .ColumnName -> string) for PS5.1 compat.
            if ($lawResp.tables -and $lawResp.tables[0].rows) {
                $cols = @($lawResp.tables[0].columns | ForEach-Object {
                    $n = [string]$_.name; if (-not $n) { $n = [string]$_.ColumnName }; if (-not $n) { $n = [string]$_ }; $n
                })
                $colsLower = @($cols | ForEach-Object { $_.ToLower() })
                $idxKey     = [array]::IndexOf($colsLower, 'userkey')
                $idxCType   = [array]::IndexOf($colsLower, 'clienttype')
                $idxCOS     = [array]::IndexOf($colsLower, 'clientos')
                $idxCVer    = [array]::IndexOf($colsLower, 'clientversion')
                $idxUdpUse  = [array]::IndexOf($colsLower, 'udpuse')
                $idxTrans   = [array]::IndexOf($colsLower, 'transporttype')
                $idxUdpType = [array]::IndexOf($colsLower, 'udptype')
                $idxCliIP   = [array]::IndexOf($colsLower, 'clientsideipaddress')
                $idxCliPL   = [array]::IndexOf($colsLower, 'isclientprivatelink')
                $idxHostPL  = [array]::IndexOf($colsLower, 'issessionhostprivatelink')
                $idxGwReg   = [array]::IndexOf($colsLower, 'gatewayregion')
                $idxAvgRtt  = [array]::IndexOf($colsLower, 'avgrtt')
                $idxP95Rtt  = [array]::IndexOf($colsLower, 'p95rtt')
                $idxAvgBW   = [array]::IndexOf($colsLower, 'avgbw')
                $idxP95BW   = [array]::IndexOf($colsLower, 'p95bw')
                $idxCSec    = [array]::IndexOf($colsLower, 'connectsec')
                # Transport: initialUdpType from WVDCheckpoints ShortpathEstablished event
                $idxTransUdp = [array]::IndexOf($colsLower, 'transportudp')

                if ($idxKey -ge 0) {
                    $dataMap = @{}
                    foreach ($r in $lawResp.tables[0].rows) {
                        $dataMap[[string]$r[$idxKey]] = $r
                    }
                    foreach ($row in $rows) {
                        $key = "$(& $getShortUser $row.'User')|$($row.'Session Host'.ToLower())"
                        if ($dataMap.ContainsKey($key)) {
                            $row.'_LawEnriched' = $true
                            $r = $dataMap[$key]
                            if ($idxCType  -ge 0 -and $r[$idxCType])  { $row.'Client Type'    = [string]$r[$idxCType] }
                            if ($idxCOS    -ge 0 -and $r[$idxCOS])    { $row.'Client OS'      = [string]$r[$idxCOS] }
                            if ($idxCVer   -ge 0 -and $r[$idxCVer])   { $row.'Client Version'  = [string]$r[$idxCVer] }
                            if ($idxUdpUse  -ge 0 -and $r[$idxUdpUse]  -ne $null -and $r[$idxUdpUse]  -ne '') { $row.'RDP Shortpath'  = [string]$r[$idxUdpUse] }
                            if ($idxTrans   -ge 0 -and $r[$idxTrans]   -ne $null -and $r[$idxTrans]   -ne '') { $row.'Transport Type' = [string]$r[$idxTrans] }
                            if ($idxUdpType -ge 0 -and $r[$idxUdpType] -ne $null -and $r[$idxUdpType] -ne '') { $row.'UDP Type'       = [string]$r[$idxUdpType] }
                            if ($idxCliIP  -ge 0 -and $r[$idxCliIP]  -ne $null -and $r[$idxCliIP]  -ne '') { $row.'Client IP'           = [string]$r[$idxCliIP] }

                            if ($idxCliPL  -ge 0 -and $r[$idxCliPL]  -ne $null -and $r[$idxCliPL]  -ne '') { $row.'Client Private Link' = [string]$r[$idxCliPL] }
                            if ($idxHostPL -ge 0 -and $r[$idxHostPL] -ne $null -and $r[$idxHostPL] -ne '') { $row.'Host Private Link'   = [string]$r[$idxHostPL] }
                            if ($idxGwReg  -ge 0 -and $r[$idxGwReg]  -ne $null -and $r[$idxGwReg]  -ne '') { $row.'Gateway Region'     = [string]$r[$idxGwReg] }
                            if ($idxAvgRtt -ge 0 -and $r[$idxAvgRtt]) {
                                $avgVal = [double]$r[$idxAvgRtt]
                                $row.'Avg RTT'       = "$([int]$avgVal)ms"
                                $row.'_AvgRTTSort'   = $avgVal
                                $row.'_AvgRTTColor'  = if ($avgVal -ge $rttRed) { 'Red' } elseif ($avgVal -ge $rttAmber) { 'Amber' } else { 'Green' }
                            }
                            if ($idxP95Rtt -ge 0 -and $r[$idxP95Rtt]) {
                                $p95Val = [double]$r[$idxP95Rtt]
                                $row.'P95 RTT'       = "$([int]$p95Val)ms"
                                $row.'_P95RTTSort'   = $p95Val
                                $row.'_P95RTTColor'  = if ($p95Val -ge $rttRed) { 'Red' } elseif ($p95Val -ge $rttAmber) { 'Amber' } else { 'Green' }
                            }
                            # EstAvailableBandwidthKBps is KBps (kilobytes/sec); convert to Mbps (* 8 / 1000)
                            if ($idxAvgBW -ge 0 -and $r[$idxAvgBW] -ne $null -and $r[$idxAvgBW] -ne '') {
                                $kbps = [double]$r[$idxAvgBW]
                                $mbps = [Math]::Round($kbps * 8 / 1000, 1)
                                $row.'Avg BW' = "$mbps Mbps"
                            }
                            if ($idxP95BW -ge 0 -and $r[$idxP95BW] -ne $null -and $r[$idxP95BW] -ne '') {
                                $kbps = [double]$r[$idxP95BW]
                                $mbps = [Math]::Round($kbps * 8 / 1000, 1)
                                $row.'P95 BW' = "$mbps Mbps"
                            }
                            if ($idxCSec -ge 0 -and $r[$idxCSec] -ne $null -and $r[$idxCSec] -ne '') {
                                $sec = [int]$r[$idxCSec]
                                $row.'Connect Time' = if ($sec -ge 60) { "{0}m {1}s" -f [Math]::Floor($sec / 60), ($sec % 60) } else { "${sec}s" }
                            }
                            # Transport: raw initialUdpType from WVDCheckpoints ShortpathEstablished
                            if ($idxTransUdp -ge 0 -and $r[$idxTransUdp] -ne $null -and $r[$idxTransUdp] -ne '') { $row.'Transport' = [string]$r[$idxTransUdp] }
                        }
                    }
                }
            }
        } catch {
            # LAW enrichment failure is non-fatal; columns remain as '-'
            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] SessionDetail LAW error: $_`r`n") } catch {} }
        }
    }

    # Transport defaults to "-" (no WVDCheckpoints ShortpathEstablished event found).
    # For rows where LAW enrichment succeeded (_LawEnriched), this means the session
    # is on plain TCP - label it explicitly. Rows without LAW data stay as "-" (unknown).
    foreach ($row in $rows) {
        if ($row.'_LawEnriched' -and $row.'Transport' -eq '-') { $row.'Transport' = 'TCP' }
    }

    $rows
}

# Per-pool logoff script - same MFA detection as gsLogoffScript above.
# See comment block above gsLogoffScript for full MFA/CA handling explanation.
$script:sdLogoffScript = {
    param($tok, $subId, $restDef, $rg, $hp, $ids)
    # Define Invoke-Arm in this runspace from the injected string definition
    . ([scriptblock]::Create($restDef))
    $errs = @()
    foreach ($id in $ids) {
        try {
            Invoke-Arm -Method DELETE `
                -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.DesktopVirtualization/hostPools/$hp/sessionHosts/$($id.SessionHost)/userSessions/$($id.SessionId)?force=true" `
                -Token $tok -ApiVersion '2024-04-03' -FullResponse | Out-Null
        }
        catch {
            $errText = "$_"
            # Detect MFA/Conditional Access enforcement - see gsLogoffScript for details
            if ($errText -match 'RequestDisallowedByAzure' -or $errText -match 'insufficient_claims') {
                $mfaClaims = $null
                try {
                    $ex = $_.Exception
                    while ($ex) {
                        if ($ex.Response) {
                            $wwwAuth = $ex.Response.Headers['WWW-Authenticate']
                            if ($wwwAuth -match 'claims="([^"]+)"') { $mfaClaims = $Matches[1] }
                            break
                        }
                        $ex = $ex.InnerException
                    }
                } catch {}
                if (-not $mfaClaims) {
                    try {
                        $det = $_.ErrorDetails.Message
                        if ($det -match '"claimsChallenge"\s*:\s*"([^"]+)"') { $mfaClaims = $Matches[1] }
                    } catch {}
                }
                if (-not $mfaClaims -and $errText -match '"claimsChallenge"\s*:\s*"([^"]+)"') {
                    $mfaClaims = $Matches[1]
                }
                $errs += "MFA_CHALLENGE:$($mfaClaims):::$($id.SessionHost)/$($id.SessionId): $errText"
            } else {
                $errs += "$($id.SessionHost)/$($id.SessionId): $errText"
            }
        }
    }
    return $errs
}


# =============================================================================
# Session filter helpers
# =============================================================================

function script:_SD_PopulateHeaderComboBox {
    param(
        [System.Windows.Controls.ComboBox]$ComboBox,
        [string]$ColumnName
    )
    $ComboBox.Items.Clear()
    [void]$ComboBox.Items.Add('All')
    if (-not $script:sdDataTable -or $script:sdDataTable.Rows.Count -eq 0) { return }
    $values = [System.Collections.Generic.SortedSet[string]]::new()
    foreach ($row in $script:sdDataTable.Rows) {
        $val = [string]($row[$ColumnName])
        if ([string]::IsNullOrEmpty($val)) { [void]$values.Add('(blank)') }
        else { [void]$values.Add($val) }
    }
    foreach ($v in $values) { [void]$ComboBox.Items.Add($v) }
}

function script:Update-SessionFilter {
    if (-not $script:sdDataTable) { return }
    $parts = [System.Collections.Generic.List[string]]::new()
    # Per-column dropdown filters
    foreach ($col in $script:sdFilterableColumns) {
        $val = $script:sdDropdownSelections[$col]
        if (-not $val -or $val -eq 'All') { continue }
        if ($val -eq '(blank)') { $parts.Add("[$col] = ''") }
        else {
            $escapedVal = $val.Replace("'","''")
            $parts.Add("[$col] = '$escapedVal'")
        }
    }
    # Text filter on User column
    $text = $script:sdFilterBox.Text.Trim()
    if (-not [string]::IsNullOrEmpty($text)) {
        $escapedText = $text.Replace("'","''")
        $parts.Add("User LIKE '%$escapedText%'")
    }
    # Host filter - set when the window is opened from the Session Hosts tab
    # double-click handler so only sessions on that specific VM are shown.
    if (-not [string]::IsNullOrEmpty($script:sdHostFilter)) {
        $escapedHost = $script:sdHostFilter.Replace("'","''")
        $parts.Add("[Session Host] = '$escapedHost'")
    }
    $script:sdDataTable.DefaultView.RowFilter = if ($parts.Count -gt 0) {
        $parts -join ' AND '
    } else { '' }

    # Update status bar count to reflect filtered rows
    $filtered = $script:sdDataTable.DefaultView.Count
    $total    = $script:sdDataTable.Rows.Count
    if ($filtered -eq $total) {
        $script:sdStatus.Text = "$total session(s)   -   Select rows then click Log Off Selected"
    } else {
        $script:sdStatus.Text = "$filtered of $total session(s)   -   Select rows then click Log Off Selected"
    }
}


# =============================================================================
# Global session view (cross-pool)
# =============================================================================

function script:Update-GlobalSessionView {
    $script:sdStatus.Text       = "Loading sessions..."
    $script:sdLogoff.IsEnabled  = $false
    $script:sdMessage.IsEnabled = $false

    $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
    Start-DetailJob -JobScript $script:gsFetchScript `
                    -JobArgs @((Get-ArmToken), $_subId, $script:restHelperDef, $script:sdHpList, $script:sdStateFilter, $RunspaceMaxSessionPool, $script:LawWorkspaceResourceId, $script:LawRttAmberMs, $script:LawRttRedMs, $script:LawConnectionLookbackWindow, $script:LawConnectionLookbackTimespan, $script:LogFile, $script:LawQueryBaseUrl, ($(if ($script:LawQueryBaseUrl) { Get-LawToken } else { '' }))) `
                    -OnComplete {
        param($rows)
        # Save sort state before rebinding so user-chosen sort survives refresh
        foreach ($col in $script:sdGrid.Columns) {
            if ($null -ne $col.SortDirection) {
                $script:sdSortColumn    = [string]$col.SortMemberPath
                $script:sdSortDirection = $col.SortDirection
                break
            }
        }
        if ($rows) {
            $dt     = New-Object System.Data.DataTable
            $hidden = @("PSComputerName","RunspaceId","PSShowComputerName","Session Host FQDN","HP RG")
            $props  = $rows[0].PSObject.Properties.Name | Where-Object { $_ -notin $hidden }
            # Insert "Location" column after "User" for display ordering
            $userIdx = [array]::IndexOf($props, "User")
            $numericSortCols = @('_AvgRTTSort', '_P95RTTSort')
            foreach ($i in 0..($props.Count - 1)) {
                if ($props[$i] -in $numericSortCols) {
                    $dt.Columns.Add($props[$i], [double]) | Out-Null
                } else {
                    $dt.Columns.Add($props[$i]) | Out-Null
                }
                if ($i -eq $userIdx) { $dt.Columns.Add("Location") | Out-Null }
            }
            $dt.Columns.Add("Session Host FQDN") | Out-Null
            $dt.Columns.Add("HP RG")             | Out-Null
            foreach ($r in $rows) {
                $hpRg = ($script:sdHpList | Where-Object { $_.Name -eq $r."Host Pool" } | Select-Object -First 1).RG
                $dr   = $dt.NewRow()
                foreach ($p in $props) { $dr[$p] = $r.$p }
                $dr["Session Host FQDN"] = [string]$r."Session Host FQDN"
                $dr["HP RG"]             = [string]$hpRg
                # Apply friendly name mappings for Client Type and Client OS
                $rawCT = [string]$dr["Client Type"]
                if ($rawCT -and $rawCT -ne '-' -and $script:ClientTypeMap.ContainsKey($rawCT)) { $dr["Client Type"] = $script:ClientTypeMap[$rawCT] }
                $rawOS = [string]$dr["Client OS"]
                if ($rawOS -and $rawOS -ne '-') { $osKey = ($rawOS -split '\s')[0].ToUpper(); if ($script:ClientOSMap.ContainsKey($osKey)) { $dr["Client OS"] = $script:ClientOSMap[$osKey] } }
                # Classify Client IP into Office / VPN / Public
                try { $dr["Location"] = Get-IpLocation -RawIP ([string]$dr["Client IP"]) } catch { $dr["Location"] = "-" }
                $dt.Rows.Add($dr) | Out-Null
            }
            if (-not $script:sdGridHandlerRegistered) {
                $script:sdGrid.Add_AutoGeneratingColumn({
                    param($s, $e)
                    # Always-hidden helper columns
                    if ($e.Column.Header -in @("Session Host FQDN", "HP RG", "_AvgRTTSort", "_P95RTTSort", "_AvgRTTColor", "_P95RTTColor", "_LawEnriched")) { $e.Cancel = $true; return }
                    # User-toggled columns
                    $colToggle = @{
                        'Client Type'        = $script:ShowClientType
                        'Client OS'          = $script:ShowClientOS
                        'Client Version'     = $script:ShowClientVersion
                        'RDP Shortpath'      = $script:ShowRDPShortpath
                        'Transport Type'     = $script:ShowTransportType
                        'UDP Type'           = $script:ShowUDPType
                        'Transport'          = $script:ShowTransport
                        'Client IP'          = $script:ShowClientIP

                        'Client Private Link'= $script:ShowClientPrivLink
                        'Host Private Link'  = $script:ShowHostPrivLink
                        'Avg RTT'            = $script:ShowAvgRTT
                        'P95 RTT'            = $script:ShowP95RTT
                        'Avg BW'             = $script:ShowAvgBW
                        'P95 BW'             = $script:ShowP95BW
                        'Connect Time'       = $script:ShowConnectTime
                        'Gateway Region'     = $script:ShowGatewayRegion
                    }
                    $colName = [string]$e.Column.Header
                    if ($colToggle.ContainsKey($colName) -and -not $colToggle[$colName]) { $e.Cancel = $true; return }
                    $e.Column.SortMemberPath = switch ($colName) {
                        'Avg RTT' { '_AvgRTTSort' }
                        'P95 RTT' { '_P95RTTSort' }
                        default   { $colName }
                    }
                    # Centre-align metric columns; apply heat map to RTT
                    $metricCols = @('Avg RTT', 'P95 RTT', 'Avg BW', 'P95 BW', 'Connect Time')
                    if ($colName -in $metricCols) {
                        # Centre text horizontally + vertically via ElementStyle on the TextBlock
                        $elemStyle = New-Object System.Windows.Style
                        $elemStyle.TargetType = [System.Windows.Controls.TextBlock]
                        $taSetter = New-Object System.Windows.Setter
                        $taSetter.Property = [System.Windows.Controls.TextBlock]::TextAlignmentProperty
                        $taSetter.Value    = [System.Windows.TextAlignment]::Center
                        [void]$elemStyle.Setters.Add($taSetter)
                        $vaSetter = New-Object System.Windows.Setter
                        $vaSetter.Property = [System.Windows.FrameworkElement]::VerticalAlignmentProperty
                        $vaSetter.Value    = [System.Windows.VerticalAlignment]::Center
                        [void]$elemStyle.Setters.Add($vaSetter)
                        $e.Column.ElementStyle = $elemStyle
                    }
                    # Heat map for RTT columns
                    if ($colName -in @('Avg RTT', 'P95 RTT')) {
                        $colorCol = switch ($colName) { 'Avg RTT' { '_AvgRTTColor' } 'P95 RTT' { '_P95RTTColor' } }
                        $cellStyle = New-Object System.Windows.Style
                        $cellStyle.TargetType = [System.Windows.Controls.DataGridCell]
                        $cellStyle.BasedOn    = $s.CellStyle
                        foreach ($band in @(
                            @{ Value = 'Green'; Brush = $window.Resources['Avd.Metric.Green'] }
                            @{ Value = 'Amber'; Brush = $window.Resources['Avd.Metric.Amber'] }
                            @{ Value = 'Red';   Brush = $window.Resources['Avd.Metric.Red']   }
                        )) {
                            $trigger = New-Object System.Windows.DataTrigger
                            $binding = New-Object System.Windows.Data.Binding
                            $binding.Path = New-Object System.Windows.PropertyPath "[$colorCol]"
                            $trigger.Binding = $binding
                            $trigger.Value = $band.Value
                            $setter = New-Object System.Windows.Setter
                            $setter.Property = [System.Windows.Controls.Control]::BackgroundProperty
                            $setter.Value = $band.Brush
                            [void]$trigger.Setters.Add($setter)
                            [void]$cellStyle.Triggers.Add($trigger)
                        }
                        # IsSelected trigger added last so it wins over heat-map colours when the row is selected
                        $_rttSelTrig = New-Object System.Windows.Trigger
                        $_rttSelTrig.Property = [System.Windows.Controls.DataGridCell]::IsSelectedProperty
                        $_rttSelTrig.Value    = $true
                        [void]$_rttSelTrig.Setters.Add((New-Object System.Windows.Setter(
                            [System.Windows.Controls.Control]::BackgroundProperty,
                            $window.Resources['Avd.Selected.Bg'])))
                        [void]$_rttSelTrig.Setters.Add((New-Object System.Windows.Setter(
                            [System.Windows.Controls.Control]::ForegroundProperty,
                            $window.Resources['Avd.Fg.Selected'])))
                        [void]$cellStyle.Triggers.Add($_rttSelTrig)
                        $e.Column.CellStyle = $cellStyle
                    }
                    # Dropdown filter for filterable columns (Location, State)
                    if ($colName -in $script:sdFilterableColumns) {
                        $sp = New-Object System.Windows.Controls.StackPanel
                        $sp.Orientation = [System.Windows.Controls.Orientation]::Vertical
                        $tb = New-Object System.Windows.Controls.TextBlock
                        $tb.Text = $colName; $tb.FontSize = 12
                        $tb.Margin = [System.Windows.Thickness]::new(0,0,0,2)
                        $cb = New-Object System.Windows.Controls.ComboBox
                        $cb.Tag = $colName; $cb.FontSize = 11
                        [void]$cb.Items.Add('All')
                        $cb.SelectedItem = 'All'
                        $cb.Add_SelectionChanged({
                            param($s,$eArgs)
                            $script:sdDropdownSelections[$s.Tag] = $s.SelectedItem
                            Update-SessionFilter
                        })
                        $script:sdDropdownCombos[$colName] = $cb
                        [void]$sp.Children.Add($tb)
                        [void]$sp.Children.Add($cb)
                        $e.Column.Header = $sp
                    }
                })
                $script:sdGridHandlerRegistered = $true
            }
            $script:sdDataTable = $dt
            $script:sdGrid.ItemsSource = $dt.DefaultView
            $script:sdExportCsv.IsEnabled = $true
            $script:sdAdvDetail.IsEnabled = $true
            # Populate filter dropdowns with current data values
            foreach ($col in $script:sdFilterableColumns) {
                if ($script:sdDropdownCombos.ContainsKey($col)) {
                    $cb = $script:sdDropdownCombos[$col]
                    $savedVal = $script:sdDropdownSelections[$col]
                    _SD_PopulateHeaderComboBox -ComboBox $cb -ColumnName $col
                    if ($savedVal -and $cb.Items.Contains($savedVal)) { $cb.SelectedItem = $savedVal }
                    else { $cb.SelectedItem = 'All' }
                }
            }
            Update-SessionFilter
            # Restore sort state so user-chosen sort survives refresh
            if ($script:sdSortColumn) {
                $dir = if ($script:sdSortDirection -eq [System.ComponentModel.ListSortDirection]::Descending) { 'DESC' } else { 'ASC' }
                $dt.DefaultView.Sort = "[$($script:sdSortColumn)] $dir"
                foreach ($col in $script:sdGrid.Columns) {
                    if ($col.SortMemberPath -eq $script:sdSortColumn) {
                        $col.SortDirection = $script:sdSortDirection
                        break
                    }
                }
            }
            $script:sdStatus.Text = "$($rows.Count) session(s)   -   Select rows then click Log Off Selected"
        } else {
            $script:sdDataTable = $null
            $script:sdGrid.ItemsSource = $null
            $script:sdExportCsv.IsEnabled = $false
            $script:sdAdvDetail.IsEnabled = $false
            $script:sdStatus.Text = "No sessions found"
        }
        $script:sdNextRefreshAt = [DateTime]::Now.AddSeconds($script:sdRefreshInterval)
    }
}

function Show-GlobalSessionDetail {
    # Global view shows all pools - no host filter
    $script:sdHostFilter = ''
    param([string]$StateFilter = "All")

    if (-not $script:lastData) {
        Show-ThemedDialog -Message 'No data loaded yet - wait for the first refresh.' -Title 'Not Ready' -Icon 'Information'
        return
    }

    $hpList = @($script:lastData.Results | Select-Object -Property @{n="Name";e={$_."Host Pool"}}, @{n="RG";e={$_."Host Pool RG"}} -Unique)

    $title = switch ($StateFilter) {
        "Active"       { "Active Sessions - All Host Pools" }
        "Disconnected" { "Disconnected Sessions - All Host Pools" }
        default        { "All Sessions - All Host Pools" }
    }

    # Close any existing detail window before opening a new one
    if ($script:sdOpenWindow) {
        try { $script:sdOpenWindow.Close() } catch {}
        $script:sdOpenWindow = $null
    }

    $_sessionXamlRaw = $sessionXaml -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\..\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    [xml]$_sessionXmlDoc = $_sessionXamlRaw
    $reader    = New-Object System.Xml.XmlNodeReader $_sessionXmlDoc
    $detailWin = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:sdOpenWindow = $detailWin
    try { Set-WindowIcon -Window $detailWin -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}
    if ($script:DarkTheme) {
        $detailWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($detailWin)).Handle
            $v = 1
            [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    }

    $script:sdTitle     = $detailWin.FindName("SessionTitle")
    $script:sdSubtitle  = $detailWin.FindName("SessionSubtitle")
    $script:sdStatus    = $detailWin.FindName("SessionStatus")
    $script:sdCountdown = $detailWin.FindName("SessionCountdown")
    $script:sdGrid      = $detailWin.FindName("SessionGrid")
    $script:sdGridZoom  = $detailWin.FindName("GridZoom")
    # Apply the themed row style (Foreground, hover, selection colours) from the
    # window's own injected resource dictionary so dark mode text is correct.
    $_sdRowStyle = $detailWin.TryFindResource('Avd.DataGridRow.Style')
    if ($_sdRowStyle) { $script:sdGrid.RowStyle = $_sdRowStyle }
    $script:sdLogoff        = $detailWin.FindName("LogoffButton")
    $script:sdMessage       = $detailWin.FindName("MessageSelectedButton")
    $script:sdMessageAll    = $detailWin.FindName("MessageAllButton")
    $script:sdRefresh       = $detailWin.FindName("SessionRefreshButton")
    $script:sdLogoffDisconn = $detailWin.FindName("LogoffDisconnectedButton")
    $script:sdExportCsv     = $detailWin.FindName("ExportCsvButton")
    $script:sdAdvDetail     = $detailWin.FindName("AdvancedDetailButton")
    $script:sdFilterBox     = $detailWin.FindName("SessionFilterBox")
    $script:sdClearFilters  = $detailWin.FindName("SessionClearFiltersButton")

    # DataGrid.RowBackground coerces DataGridRow.Background and wins over RowStyle triggers,
    # so selection colour must be applied at cell level, not row level.
    # CellStyle: custom ControlTemplate (TemplateBinding Background) + IsSelected trigger that
    # sets the theme colour directly on the cell. Assigned as DataGrid.CellStyle (local value)
    # so it takes precedence over any implicit style.
    $_sdSelBrush   = $script:MainWindow.Resources['Avd.Selected.Bg']
    $_sdSelFgBrush = $script:MainWindow.Resources['Avd.Fg.Selected']
    $_sdWinFgBrush = $script:MainWindow.Resources['Avd.Window.Fg']
    $_sdSelHex   = '#{0:X2}{1:X2}{2:X2}' -f $_sdSelBrush.Color.R,   $_sdSelBrush.Color.G,   $_sdSelBrush.Color.B
    $_sdSelFgHex = '#{0:X2}{1:X2}{2:X2}' -f $_sdSelFgBrush.Color.R, $_sdSelFgBrush.Color.G, $_sdSelFgBrush.Color.B
    $_sdWinFgHex = '#{0:X2}{1:X2}{2:X2}' -f $_sdWinFgBrush.Color.R, $_sdWinFgBrush.Color.G, $_sdWinFgBrush.Color.B
    $script:sdGrid.CellStyle = [System.Windows.Markup.XamlReader]::Parse(@"
<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='DataGridCell'>
  <Setter Property='Template'>
    <Setter.Value>
      <ControlTemplate TargetType='DataGridCell'>
        <Border Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}'>
          <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
        </Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
  <Setter Property='Foreground' Value='$_sdWinFgHex'/>
  <Style.Triggers>
    <Trigger Property='IsSelected' Value='True'>
      <Setter Property='Background' Value='$_sdSelHex'/>
      <Setter Property='Foreground' Value='$_sdSelFgHex'/>
      <Setter Property='BorderBrush' Value='$_sdSelHex'/>
    </Trigger>
  </Style.Triggers>
</Style>
"@)

    # Hide Session History button if disabled in config (Dashboard.HideSessionHistory)
    if ($script:HideSessionHistory) {
        $script:sdAdvDetail.Visibility = [System.Windows.Visibility]::Collapsed
    }

    # Ctrl+MouseWheel zoom: scale the session grid between 60% and 150% in 5%
    # increments. Uses the XAML ScaleTransform (GridZoom) applied via LayoutTransform
    # so the grid resizes within its layout slot. PreviewMouseWheel fires before the
    # DataGrid's built-in scroll handler; Handled = $true prevents scrolling while zooming.
    $script:sdGrid.Add_PreviewMouseWheel({
        if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) {
            $_.Handled = $true
            $delta = if ($_.Delta -gt 0) { 0.05 } else { -0.05 }
            $new = [Math]::Round($script:sdGridZoom.ScaleX + $delta, 2)
            $new = [Math]::Max(0.6, [Math]::Min(1.5, $new))
            $script:sdGridZoom.ScaleX = $new
            $script:sdGridZoom.ScaleY = $new
        }
    })

    $script:sdTitle.Text    = $title
    $script:sdSubtitle.Text = "$($hpList.Count) host pool(s) - $($script:lastData.Subscription)"
    $script:sdStatus.Text   = "Loading sessions..."

    $script:sdCF                     = $contextFile
    $script:sdRG                     = $null
    $script:sdHP                     = $null
    $script:sdGridHandlerRegistered  = $false
    $script:sdDataTable              = $null
    $script:sdSortColumn             = $null
    $script:sdSortDirection          = $null
    $script:sdDropdownSelections     = @{}
    $script:sdDropdownCombos         = @{}
    $script:sdFilterableColumns      = @('Location', 'State')

    $script:sdStateFilter     = $StateFilter
    $script:sdHpList          = $hpList
    $script:sdNextRefreshAt   = [DateTime]::Now.AddYears(1)
    $script:sdRefreshInterval = $RefreshIntervalSeconds

    $script:sdCountdownTimer          = New-Object System.Windows.Threading.DispatcherTimer
    $script:sdCountdownTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:sdCountdownTimer.Add_Tick({
        if ($script:_mfaInProgress) { return }
        if ($script:detailHandle -and -not $script:detailHandle.IsCompleted) {
            $script:sdCountdown.Text = "Refreshing..."; return
        }
        $remaining = ($script:sdNextRefreshAt - [DateTime]::Now).TotalSeconds
        if ($remaining -le 0) {
            $script:sdNextRefreshAt  = [DateTime]::Now.AddYears(1)
            $script:sdCountdown.Text = "Refreshing..."
            Update-GlobalSessionView
        } else {
            $script:sdCountdown.Text = "Next refresh in $([Math]::Ceiling($remaining))s"
        }
    })
    $script:sdCountdownTimer.Start()
    $detailWin.Add_Closed({
        try { $script:sdCountdownTimer.Stop() } catch {}
        # Clean up any in-flight background job
        if ($script:detailTimer) { try { $script:detailTimer.Stop() } catch {}; $script:detailTimer = $null }
        if ($script:detailPS)    {
            try { $script:detailPS.Stop() }           catch {}
            try { $script:detailPS.Runspace.Close() } catch {}
            try { $script:detailPS.Dispose() }        catch {}
            $script:detailPS = $null; $script:detailHandle = $null
        }
        $script:sdOpenWindow = $null
    })

    $script:sdRefresh.Add_Click({ $script:sdNextRefreshAt = [DateTime]::Now })
    $script:sdExportCsv.Add_Click({ Invoke-SessionExport })
    $script:sdAdvDetail.Add_Click({ Show-SessionHistory })

    $script:sdGrid.Add_SelectionChanged({
        $hasRows = ($script:sdGrid.SelectedItems.Count -gt 0)
        $script:sdLogoff.IsEnabled  = $hasRows
        $script:sdMessage.IsEnabled = $hasRows
    })

    # Debounce text filter - only apply after 300ms of no typing to avoid lag
    $script:sdFilterTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:sdFilterTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:sdFilterTimer.Add_Tick({
        $script:sdFilterTimer.Stop()
        Update-SessionFilter
    })
    $script:sdFilterBox.Add_TextChanged({
        $script:sdFilterTimer.Stop()
        $script:sdFilterTimer.Start()
    })
    $script:sdClearFilters.Add_Click({
        $script:sdFilterTimer.Stop()
        $script:sdFilterBox.Text = ''
        $script:sdDropdownSelections = @{}
        foreach ($cb in $script:sdDropdownCombos.Values) {
            if ($cb -and $cb.Items.Count -gt 0) { $cb.SelectedItem = 'All' }
        }
        Update-SessionFilter
    })


    Add-SessionContextMenu -Grid $script:sdGrid -LogoffButton $script:sdLogoff

    $script:sdMessageAll.Add_Click({
        try {
            if (-not $script:sdDataTable) {
                Show-ThemedDialog -Message 'Session data not yet loaded - please wait.' -Title 'Message All' -Icon 'Information'
                return
            }
            $activeRows = @($script:sdDataTable.Select("State = 'Active'"))
            if ($activeRows.Count -eq 0) {
                Show-ThemedDialog -Message 'No active sessions found.' -Title 'Message All' -Icon 'Information'
                return
            }
            $msg = Show-MessageComposeDialog -Recipient "$($activeRows.Count) active user(s)" `
                       -Owner ([System.Windows.Window]::GetWindow($script:sdGrid))
            if ($null -eq $msg) { return }
            Write-AuditLog -Action 'SendMessage' -Target 'All Sessions' -Details "$($activeRows.Count) user(s) - $($msg.Title)"
            $errors = @()
            foreach ($row in $activeRows) {
                try {
                    $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
                    Send-ArmUserSessionMessage `
                        -SubscriptionId $_subId `
                        -ResourceGroup  ([string]$row["HP RG"]) `
                        -HostPool       ([string]$row["Host Pool"]) `
                        -SessionHost    ([string]$row["Session Host FQDN"]) `
                        -SessionId      ([string]$row["ID"]) `
                        -MessageTitle   $msg.Title `
                        -MessageBody    $msg.Body `
                        -Token          (Get-ArmToken)
                }
                catch { $errors += "$([string]$row["User"]): $_" }
            }
            if ($errors) {
                Show-ThemedDialog -Message "Some messages failed:`n$($errors -join "`n")" -Title 'Message All Error' -Icon 'Error'
            } else {
                Show-ThemedDialog -Message "Message sent to $($activeRows.Count) active session(s) successfully." -Title 'Message All' -Icon 'Information'
            }
        }
        catch {
            Show-ThemedDialog -Message "Error: $_" -Title 'Message All Error' -Icon 'Error'
        }
    })

    $script:sdMessage.Add_Click({
        try {
            $selected   = @($script:sdGrid.SelectedItems)
            $activeRows = @($selected | Where-Object { $null -ne $_ -and $_["State"] -eq "Active" })
            if ($activeRows.Count -eq 0) {
                Show-ThemedDialog -Message "No active sessions selected.`nMessages can only be sent to active sessions." -Title 'Send Message' -Icon 'Information'
                return
            }
            $recipient = if ($activeRows.Count -eq 1) { [string]$activeRows[0]["User"] } else { "$($activeRows.Count) users" }
            $msg = Show-MessageComposeDialog -Recipient $recipient `
                       -Owner ([System.Windows.Window]::GetWindow($script:sdGrid))
            if ($null -eq $msg) { return }
            Write-AuditLog -Action 'SendMessage' -Target 'Selected Sessions' -Details "$($activeRows.Count) user(s) - $($msg.Title)"
            $errors = @()
            foreach ($row in $activeRows) {
                try {
                    $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
                    Send-ArmUserSessionMessage `
                        -SubscriptionId $_subId `
                        -ResourceGroup  ([string]$row["HP RG"]) `
                        -HostPool       ([string]$row["Host Pool"]) `
                        -SessionHost    ([string]$row["Session Host FQDN"]) `
                        -SessionId      ([string]$row["ID"]) `
                        -MessageTitle   $msg.Title `
                        -MessageBody    $msg.Body `
                        -Token          (Get-ArmToken)
                }
                catch { $errors += "$([string]$row["User"]): $_" }
            }
            if ($errors) {
                Show-ThemedDialog -Message "Some messages failed:`n$($errors -join "`n")" -Title 'Send Message Error' -Icon 'Error'
            } else {
                Show-ThemedDialog -Message "Message sent to $($activeRows.Count) session(s) successfully." -Title 'Send Message' -Icon 'Information'
            }
        }
        catch {
            Show-ThemedDialog -Message "Error: $_" -Title 'Send Message Error' -Icon 'Error'
        }
    })

    $script:sdLogoff.Add_Click({
        try {
            $selected = @($script:sdGrid.SelectedItems)
            if ($selected.Count -eq 0) {
                Show-ThemedDialog -Message 'No sessions selected.' -Title 'Log Off' -Icon 'Information'
                return
            }

            $names   = ($selected | ForEach-Object { $_["User"] }) -join "`n"
            if (-not (Show-ThemedDialog -Message "Log off $($selected.Count) session(s)?`n`n$names" -Title 'Confirm Log Off' -Buttons 'YesNo' -Icon 'Warning')) { return }

            $script:sdStatus.Text      = "Logging off $($selected.Count) session(s)..."
            $script:sdLogoff.IsEnabled = $false

            $sessionIds = @($selected | ForEach-Object {
                [PSCustomObject]@{
                    SessionHost = [string]$_["Session Host FQDN"]
                    SessionId   = [string]$_["ID"]
                    HpName      = [string]$_["Host Pool"]
                    HpRG        = [string]$_["HP RG"]
                }
            })

            # Audit log - record each session being logged off
            foreach ($sid in $sessionIds) {
                $logoffUser = ($selected | Where-Object { $_["Session Host FQDN"] -eq $sid.SessionHost -and $_["ID"] -eq $sid.SessionId } | ForEach-Object { $_["User"] }) -join ''
                Write-AuditLog -Action 'Logoff' -Target $sid.SessionHost.Split('.')[0].ToLower() -Details "$logoffUser (session $($sid.SessionId))"
            }

            # Get a fresh ARM token from the main thread and pass it directly into
            # the runspace so the background job can authenticate without MSAL.
            try {
                $script:azArmToken = Get-ArmToken
            } catch {
                Show-ThemedDialog -Message "Failed to obtain ARM token: $_`n`nPlease restart the dashboard." -Title 'Auth Error' -Icon 'Error'
                return
            }

            $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
            # Pre-compute ARM operations for MFA retry (child process executes them directly)
            $script:_mfaArmOps = @($sessionIds | ForEach-Object {
                @{ Method = 'DELETE'; Path = "/subscriptions/$_subId/resourceGroups/$($_.HpRG)/providers/Microsoft.DesktopVirtualization/hostPools/$($_.HpName)/sessionHosts/$($_.SessionHost)/userSessions/$($_.SessionId)?force=true&api-version=2024-04-03" }
            })
            Start-DetailJob -JobScript $script:gsLogoffScript `
                            -JobArgs @($script:azArmToken, $_subId, $script:restHelperDef, $sessionIds) `
                            -OnComplete {
                param($errs)
                # Check for MFA enforcement error - child process authenticates and
                # executes the ARM calls directly (no token round-trip needed).
                if ($errs -and (Resolve-MfaChallenge -Errors $errs -ArmOperations $script:_mfaArmOps)) {
                    if ($script:_mfaRetryReady) {
                        $script:sdStatus.Text = "Log off complete - reloading..."
                    }
                    Update-GlobalSessionView
                    return
                }
                if ($errs) {
                    $msg = "Log off errors:`n$($errs -join "`n")"
                    $script:sdStatus.Text = "Errors - see popup"
                    Show-ThemedDialog -Message $msg -Title 'Log Off Error' -Icon 'Error'
                } else {
                    $script:sdStatus.Text = "Log off complete - reloading..."
                }
                Update-GlobalSessionView
            }
        }
        catch {
            Show-ThemedDialog -Message "Log off error: $_" -Title 'Log Off Error' -Icon 'Error'
        }
    })

    $gsDisconnBtn = $detailWin.FindName("LogoffDisconnectedButton")
    $gsDisconnBtn.Add_Click({
        try {
            if (-not $script:sdDataTable) {
                Show-ThemedDialog -Message 'Session data not yet loaded - please wait.' -Title 'Not Ready' -Icon 'Information'
                return
            }
            $disconnRows = @($script:sdDataTable.Select("State = 'Disconnected'"))
            if ($disconnRows.Count -eq 0) {
                Show-ThemedDialog -Message 'No disconnected sessions found.' -Title 'Nothing to Do' -Icon 'Information'
                return
            }
            if (-not (Show-ThemedDialog -Message "Log off $($disconnRows.Count) disconnected session(s)?" -Title 'Confirm Log Off Disconnected' -Buttons 'YesNo' -Icon 'Warning')) { return }

            $script:sdStatus.Text             = "Logging off $($disconnRows.Count) disconnected session(s)..."
            $script:sdLogoff.IsEnabled        = $false
            $script:sdLogoffDisconn.IsEnabled = $false
            try { $script:sdCountdownTimer.Stop() } catch {}

            $sessionIds = @($disconnRows | ForEach-Object {
                [PSCustomObject]@{
                    SessionHost = [string]$_["Session Host FQDN"]
                    SessionId   = [string]$_["ID"]
                    HpName      = [string]$_["Host Pool"]
                    HpRG        = [string]$_["HP RG"]
                }
            })

            try {
                $script:azArmToken = Get-ArmToken
            } catch {
                Show-ThemedDialog -Message "Failed to obtain ARM token: $_`n`nPlease restart the dashboard." -Title 'Auth Error' -Icon 'Error'
                return
            }

            $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
            $script:_mfaArmOps = @($sessionIds | ForEach-Object {
                @{ Method = 'DELETE'; Path = "/subscriptions/$_subId/resourceGroups/$($_.HpRG)/providers/Microsoft.DesktopVirtualization/hostPools/$($_.HpName)/sessionHosts/$($_.SessionHost)/userSessions/$($_.SessionId)?force=true&api-version=2024-04-03" }
            })
            Start-DetailJob -JobScript $script:gsLogoffScript `
                            -JobArgs @($script:azArmToken, $_subId, $script:restHelperDef, $sessionIds) `
                            -OnComplete {
                param($errs)
                if ($errs -and (Resolve-MfaChallenge -Errors $errs -ArmOperations $script:_mfaArmOps)) {
                    if ($script:_mfaRetryReady) {
                        $script:sdStatus.Text = "Logged off - reloading..."
                    }
                    $script:sdLogoffDisconn.IsEnabled = $true
                    try { $script:sdCountdownTimer.Start() } catch {}
                    Update-GlobalSessionView
                    return
                }
                $script:sdLogoffDisconn.IsEnabled = $true
                if ($errs) {
                    $script:sdStatus.Text = "Errors: $($errs -join ' | ')"
                } else {
                    $script:sdStatus.Text = "Logged off - reloading..."
                }
                try { $script:sdCountdownTimer.Start() } catch {}
                Update-GlobalSessionView
            }
        }
        catch {
            Show-ThemedDialog -Message "Error: $_" -Title 'Log Off Error' -Icon 'Error'
        }
    })

    Update-GlobalSessionView
    $detailWin.Show()
}


# =============================================================================
# Per-pool session view
# =============================================================================

function script:Update-SessionView {
    $script:sdStatus.Text       = "Loading sessions..."
    $script:sdLogoff.IsEnabled  = $false
    $script:sdMessage.IsEnabled = $false

    $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
    Start-DetailJob -JobScript $script:sdFetchScript `
                    -JobArgs @((Get-ArmToken), $_subId, $script:restHelperDef, $script:sdRG, $script:sdHP, $script:LawWorkspaceResourceId, $script:LawRttAmberMs, $script:LawRttRedMs, $script:LawConnectionLookbackWindow, $script:LawConnectionLookbackTimespan, $script:LogFile, $script:LawQueryBaseUrl, ($(if ($script:LawQueryBaseUrl) { Get-LawToken } else { '' }))) `
                    -OnComplete {
        param($rows)
        # Save sort state before rebinding so user-chosen sort survives refresh
        foreach ($col in $script:sdGrid.Columns) {
            if ($null -ne $col.SortDirection) {
                $script:sdSortColumn    = [string]$col.SortMemberPath
                $script:sdSortDirection = $col.SortDirection
                break
            }
        }
        if ($rows) {
            $dt    = New-Object System.Data.DataTable
            $skip  = @('PSComputerName','RunspaceId','PSShowComputerName')
            $props = $rows[0].PSObject.Properties.Name | Where-Object { $_ -notin $skip }
            # Insert "Location" column after "User" for display ordering
            $userIdx = [array]::IndexOf($props, "User")
            $numericSortCols = @('_AvgRTTSort', '_P95RTTSort')
            foreach ($i in 0..($props.Count - 1)) {
                if ($props[$i] -in $numericSortCols) {
                    $dt.Columns.Add($props[$i], [double]) | Out-Null
                } else {
                    $dt.Columns.Add($props[$i]) | Out-Null
                }
                if ($i -eq $userIdx) { $dt.Columns.Add("Location") | Out-Null }
            }
            $dt.Columns.Add("HP RG") | Out-Null
            $dt.Columns.Add("Host Pool") | Out-Null
            foreach ($r in $rows) {
                $dr = $dt.NewRow()
                foreach ($p in $props) { $dr[$p] = $r.$p }
                $dr["HP RG"]     = $script:sdRG
                $dr["Host Pool"] = $script:sdHP
                # Apply friendly name mappings for Client Type and Client OS
                $rawCT = [string]$dr["Client Type"]
                if ($rawCT -and $rawCT -ne '-' -and $script:ClientTypeMap.ContainsKey($rawCT)) { $dr["Client Type"] = $script:ClientTypeMap[$rawCT] }
                $rawOS = [string]$dr["Client OS"]
                if ($rawOS -and $rawOS -ne '-') { $osKey = ($rawOS -split '\s')[0].ToUpper(); if ($script:ClientOSMap.ContainsKey($osKey)) { $dr["Client OS"] = $script:ClientOSMap[$osKey] } }
                # Classify Client IP into Office / VPN / Public
                try { $dr["Location"] = Get-IpLocation -RawIP ([string]$dr["Client IP"]) } catch { $dr["Location"] = "-" }
                $dt.Rows.Add($dr) | Out-Null
            }
            if (-not $script:sdGridHandlerRegistered) {
                $script:sdGrid.Add_AutoGeneratingColumn({
                    param($s, $e)
                    # Always-hidden helper columns
                    if ($e.Column.Header -in @("Session Host FQDN", "HP RG", "Host Pool", "_AvgRTTSort", "_P95RTTSort", "_AvgRTTColor", "_P95RTTColor", "_LawEnriched")) { $e.Cancel = $true; return }
                    # User-toggled columns
                    $colToggle = @{
                        'Client Type'        = $script:ShowClientType
                        'Client OS'          = $script:ShowClientOS
                        'Client Version'     = $script:ShowClientVersion
                        'RDP Shortpath'      = $script:ShowRDPShortpath
                        'Transport Type'     = $script:ShowTransportType
                        'UDP Type'           = $script:ShowUDPType
                        'Transport'          = $script:ShowTransport
                        'Client IP'          = $script:ShowClientIP

                        'Client Private Link'= $script:ShowClientPrivLink
                        'Host Private Link'  = $script:ShowHostPrivLink
                        'Avg RTT'            = $script:ShowAvgRTT
                        'P95 RTT'            = $script:ShowP95RTT
                        'Avg BW'             = $script:ShowAvgBW
                        'P95 BW'             = $script:ShowP95BW
                        'Connect Time'       = $script:ShowConnectTime
                        'Gateway Region'     = $script:ShowGatewayRegion
                    }
                    $colName = [string]$e.Column.Header
                    if ($colToggle.ContainsKey($colName) -and -not $colToggle[$colName]) { $e.Cancel = $true; return }
                    $e.Column.SortMemberPath = switch ($colName) {
                        'Avg RTT' { '_AvgRTTSort' }
                        'P95 RTT' { '_P95RTTSort' }
                        default   { $colName }
                    }
                    # Centre-align metric columns; apply heat map to RTT
                    $metricCols = @('Avg RTT', 'P95 RTT', 'Avg BW', 'P95 BW', 'Connect Time')
                    if ($colName -in $metricCols) {
                        # Centre text horizontally + vertically via ElementStyle on the TextBlock
                        $elemStyle = New-Object System.Windows.Style
                        $elemStyle.TargetType = [System.Windows.Controls.TextBlock]
                        $taSetter = New-Object System.Windows.Setter
                        $taSetter.Property = [System.Windows.Controls.TextBlock]::TextAlignmentProperty
                        $taSetter.Value    = [System.Windows.TextAlignment]::Center
                        [void]$elemStyle.Setters.Add($taSetter)
                        $vaSetter = New-Object System.Windows.Setter
                        $vaSetter.Property = [System.Windows.FrameworkElement]::VerticalAlignmentProperty
                        $vaSetter.Value    = [System.Windows.VerticalAlignment]::Center
                        [void]$elemStyle.Setters.Add($vaSetter)
                        $e.Column.ElementStyle = $elemStyle
                    }
                    # Heat map for RTT columns
                    if ($colName -in @('Avg RTT', 'P95 RTT')) {
                        $colorCol = switch ($colName) { 'Avg RTT' { '_AvgRTTColor' } 'P95 RTT' { '_P95RTTColor' } }
                        $cellStyle = New-Object System.Windows.Style
                        $cellStyle.TargetType = [System.Windows.Controls.DataGridCell]
                        $cellStyle.BasedOn    = $s.CellStyle
                        foreach ($band in @(
                            @{ Value = 'Green'; Brush = $window.Resources['Avd.Metric.Green'] }
                            @{ Value = 'Amber'; Brush = $window.Resources['Avd.Metric.Amber'] }
                            @{ Value = 'Red';   Brush = $window.Resources['Avd.Metric.Red']   }
                        )) {
                            $trigger = New-Object System.Windows.DataTrigger
                            $binding = New-Object System.Windows.Data.Binding
                            $binding.Path = New-Object System.Windows.PropertyPath "[$colorCol]"
                            $trigger.Binding = $binding
                            $trigger.Value = $band.Value
                            $setter = New-Object System.Windows.Setter
                            $setter.Property = [System.Windows.Controls.Control]::BackgroundProperty
                            $setter.Value = $band.Brush
                            [void]$trigger.Setters.Add($setter)
                            [void]$cellStyle.Triggers.Add($trigger)
                        }
                        # IsSelected trigger added last so it wins over heat-map colours when the row is selected
                        $_rttSelTrig = New-Object System.Windows.Trigger
                        $_rttSelTrig.Property = [System.Windows.Controls.DataGridCell]::IsSelectedProperty
                        $_rttSelTrig.Value    = $true
                        [void]$_rttSelTrig.Setters.Add((New-Object System.Windows.Setter(
                            [System.Windows.Controls.Control]::BackgroundProperty,
                            $window.Resources['Avd.Selected.Bg'])))
                        [void]$_rttSelTrig.Setters.Add((New-Object System.Windows.Setter(
                            [System.Windows.Controls.Control]::ForegroundProperty,
                            $window.Resources['Avd.Fg.Selected'])))
                        [void]$cellStyle.Triggers.Add($_rttSelTrig)
                        $e.Column.CellStyle = $cellStyle
                    }
                    # Dropdown filter for filterable columns (Location, State)
                    if ($colName -in $script:sdFilterableColumns) {
                        $sp = New-Object System.Windows.Controls.StackPanel
                        $sp.Orientation = [System.Windows.Controls.Orientation]::Vertical
                        $tb = New-Object System.Windows.Controls.TextBlock
                        $tb.Text = $colName; $tb.FontSize = 12
                        $tb.Margin = [System.Windows.Thickness]::new(0,0,0,2)
                        $cb = New-Object System.Windows.Controls.ComboBox
                        $cb.Tag = $colName; $cb.FontSize = 11
                        [void]$cb.Items.Add('All')
                        $cb.SelectedItem = 'All'
                        $cb.Add_SelectionChanged({
                            param($s,$eArgs)
                            $script:sdDropdownSelections[$s.Tag] = $s.SelectedItem
                            Update-SessionFilter
                        })
                        $script:sdDropdownCombos[$colName] = $cb
                        [void]$sp.Children.Add($tb)
                        [void]$sp.Children.Add($cb)
                        $e.Column.Header = $sp
                    }
                })
                $script:sdGridHandlerRegistered = $true
            }
            $script:sdDataTable = $dt
            $script:sdGrid.ItemsSource = $dt.DefaultView
            $script:sdExportCsv.IsEnabled = $true
            $script:sdAdvDetail.IsEnabled = $true
            # Populate filter dropdowns with current data values
            foreach ($col in $script:sdFilterableColumns) {
                if ($script:sdDropdownCombos.ContainsKey($col)) {
                    $cb = $script:sdDropdownCombos[$col]
                    $savedVal = $script:sdDropdownSelections[$col]
                    _SD_PopulateHeaderComboBox -ComboBox $cb -ColumnName $col
                    if ($savedVal -and $cb.Items.Contains($savedVal)) { $cb.SelectedItem = $savedVal }
                    else { $cb.SelectedItem = 'All' }
                }
            }
            Update-SessionFilter
            # Restore sort state so user-chosen sort survives refresh
            if ($script:sdSortColumn) {
                $dir = if ($script:sdSortDirection -eq [System.ComponentModel.ListSortDirection]::Descending) { 'DESC' } else { 'ASC' }
                $dt.DefaultView.Sort = "[$($script:sdSortColumn)] $dir"
                foreach ($col in $script:sdGrid.Columns) {
                    if ($col.SortMemberPath -eq $script:sdSortColumn) {
                        $col.SortDirection = $script:sdSortDirection
                        break
                    }
                }
            }
            $script:sdStatus.Text = "$($rows.Count) session(s)   -   Select rows then click Log Off Selected"
        }
        else {
            $script:sdDataTable = $null
            $script:sdGrid.ItemsSource = $null
            $script:sdExportCsv.IsEnabled = $false
            $script:sdAdvDetail.IsEnabled = $false
            $script:sdStatus.Text = "No active sessions found"
        }
        $script:sdNextRefreshAt = [DateTime]::Now.AddSeconds($script:sdRefreshInterval)
    }
}

function Show-SessionDetail {
    param(
        [string]$HostPoolName,
        [string]$HostPoolRG,
        # Optional: short VM name (e.g. "avd-vm-0") to pre-filter the session list
        # to only that host. Set when called from the Session Hosts tab double-click.
        # Cleared when opening a full host-pool or global view.
        [string]$HostNameFilter = ''
    )
    $script:sdHostFilter = $HostNameFilter

    # Close any existing detail window before opening a new one
    if ($script:sdOpenWindow) {
        try { $script:sdOpenWindow.Close() } catch {}
        $script:sdOpenWindow = $null
    }

    $_sessionXamlRaw = $sessionXaml -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\..\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    [xml]$_sessionXmlDoc = $_sessionXamlRaw
    $reader    = New-Object System.Xml.XmlNodeReader $_sessionXmlDoc
    $detailWin = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:sdOpenWindow = $detailWin
    try { Set-WindowIcon -Window $detailWin -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}
    if ($script:DarkTheme) {
        $detailWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($detailWin)).Handle
            $v = 1
            [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    }

    $script:sdTitle     = $detailWin.FindName("SessionTitle")
    $script:sdSubtitle  = $detailWin.FindName("SessionSubtitle")
    $script:sdStatus    = $detailWin.FindName("SessionStatus")
    $script:sdCountdown = $detailWin.FindName("SessionCountdown")
    $script:sdGrid      = $detailWin.FindName("SessionGrid")
    $script:sdGridZoom  = $detailWin.FindName("GridZoom")
    # Apply themed row style so dark mode row text colour is correct
    $_sdRowStyle = $detailWin.TryFindResource('Avd.DataGridRow.Style')
    if ($_sdRowStyle) { $script:sdGrid.RowStyle = $_sdRowStyle }
    $script:sdLogoff          = $detailWin.FindName("LogoffButton")
    $script:sdMessage         = $detailWin.FindName("MessageSelectedButton")
    $script:sdMessageAll      = $detailWin.FindName("MessageAllButton")
    $script:sdRefresh         = $detailWin.FindName("SessionRefreshButton")
    $script:sdLogoffDisconn   = $detailWin.FindName("LogoffDisconnectedButton")
    $script:sdExportCsv       = $detailWin.FindName("ExportCsvButton")
    $script:sdAdvDetail       = $detailWin.FindName("AdvancedDetailButton")
    $script:sdFilterBox       = $detailWin.FindName("SessionFilterBox")
    $script:sdClearFilters    = $detailWin.FindName("SessionClearFiltersButton")

    $_sdSelBrush   = $script:MainWindow.Resources['Avd.Selected.Bg']
    $_sdSelFgBrush = $script:MainWindow.Resources['Avd.Fg.Selected']
    $_sdSelHex     = '#{0:X2}{1:X2}{2:X2}' -f $_sdSelBrush.Color.R,   $_sdSelBrush.Color.G,   $_sdSelBrush.Color.B
    $_sdSelFgHex   = '#{0:X2}{1:X2}{2:X2}' -f $_sdSelFgBrush.Color.R, $_sdSelFgBrush.Color.G, $_sdSelFgBrush.Color.B
    $script:sdGrid.CellStyle = [System.Windows.Markup.XamlReader]::Parse(@"
<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='DataGridCell'>
  <Setter Property='Template'>
    <Setter.Value>
      <ControlTemplate TargetType='DataGridCell'>
        <Border Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}'>
          <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center'/>
        </Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
  <Style.Triggers>
    <Trigger Property='IsSelected' Value='True'>
      <Setter Property='Background' Value='$_sdSelHex'/>
      <Setter Property='Foreground' Value='$_sdSelFgHex'/>
      <Setter Property='BorderBrush' Value='$_sdSelHex'/>
    </Trigger>
  </Style.Triggers>
</Style>
"@)

    # Session History is not available from the session hosts tab view
    $script:sdAdvDetail.Visibility = [System.Windows.Visibility]::Collapsed

    # Ctrl+MouseWheel zoom: scale the session grid between 60% and 150% in 5%
    # increments. Uses the XAML ScaleTransform (GridZoom) applied via LayoutTransform
    # so the grid resizes within its layout slot. PreviewMouseWheel fires before the
    # DataGrid's built-in scroll handler; Handled = $true prevents scrolling while zooming.
    $script:sdGrid.Add_PreviewMouseWheel({
        if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) {
            $_.Handled = $true
            $delta = if ($_.Delta -gt 0) { 0.05 } else { -0.05 }
            $new = [Math]::Round($script:sdGridZoom.ScaleX + $delta, 2)
            $new = [Math]::Max(0.6, [Math]::Min(1.5, $new))
            $script:sdGridZoom.ScaleX = $new
            $script:sdGridZoom.ScaleY = $new
        }
    })

    # When opened from the Session Hosts tab double-click, show the VM name in the
    # title so the user knows the view is filtered to a single session host.
    $script:sdTitle.Text    = if ($HostNameFilter) { "User Sessions - $HostNameFilter" } else { "User Sessions - $HostPoolName" }
    $script:sdSubtitle.Text = if ($HostNameFilter) { "$HostPoolName  |  $HostPoolRG" } else { "Host Pool RG : $HostPoolRG" }
    $script:sdStatus.Text   = "Loading sessions..."

    $script:sdCF                     = $contextFile
    $script:sdRG                     = $HostPoolRG
    $script:sdHP                     = $HostPoolName
    $script:sdGridHandlerRegistered  = $false
    $script:sdDataTable              = $null
    $script:sdSortColumn             = $null
    $script:sdSortDirection          = $null
    $script:sdDropdownSelections     = @{}
    $script:sdDropdownCombos         = @{}
    $script:sdFilterableColumns      = @('Location', 'State')

    $script:sdNextRefreshAt   = [DateTime]::Now.AddYears(1)
    $script:sdRefreshInterval = $RefreshIntervalSeconds

    $script:sdCountdownTimer          = New-Object System.Windows.Threading.DispatcherTimer
    $script:sdCountdownTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:sdCountdownTimer.Add_Tick({
        if ($script:detailHandle -and -not $script:detailHandle.IsCompleted) {
            $script:sdCountdown.Text = "Refreshing..."
            return
        }
        $remaining = ($script:sdNextRefreshAt - [DateTime]::Now).TotalSeconds
        if ($remaining -le 0) {
            $script:sdNextRefreshAt  = [DateTime]::Now.AddYears(1)
            $script:sdCountdown.Text = "Refreshing..."
            Update-SessionView
        }
        else {
            $script:sdCountdown.Text = "Next refresh in $([Math]::Ceiling($remaining))s"
        }
    })
    $script:sdCountdownTimer.Start()

    $detailWin.Add_Closed({
        try { $script:sdCountdownTimer.Stop() } catch {}
        # Clean up any in-flight background job
        if ($script:detailTimer) { try { $script:detailTimer.Stop() } catch {}; $script:detailTimer = $null }
        if ($script:detailPS)    {
            try { $script:detailPS.Stop() }           catch {}
            try { $script:detailPS.Runspace.Close() } catch {}
            try { $script:detailPS.Dispose() }        catch {}
            $script:detailPS = $null; $script:detailHandle = $null
        }
        $script:sdOpenWindow = $null
    })

    $script:sdRefresh.Add_Click({
        $script:sdNextRefreshAt = [DateTime]::Now
    })
    $script:sdExportCsv.Add_Click({ Invoke-SessionExport })

    $script:sdGrid.Add_SelectionChanged({
        $hasRows = ($script:sdGrid.SelectedItems.Count -gt 0)
        $script:sdLogoff.IsEnabled  = $hasRows
        $script:sdMessage.IsEnabled = $hasRows
    })

    # Debounce text filter - only apply after 300ms of no typing to avoid lag
    $script:sdFilterTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:sdFilterTimer.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:sdFilterTimer.Add_Tick({
        $script:sdFilterTimer.Stop()
        Update-SessionFilter
    })
    $script:sdFilterBox.Add_TextChanged({
        $script:sdFilterTimer.Stop()
        $script:sdFilterTimer.Start()
    })
    $script:sdClearFilters.Add_Click({
        $script:sdFilterTimer.Stop()
        $script:sdFilterBox.Text = ''
        $script:sdDropdownSelections = @{}
        foreach ($cb in $script:sdDropdownCombos.Values) {
            if ($cb -and $cb.Items.Count -gt 0) { $cb.SelectedItem = 'All' }
        }
        Update-SessionFilter
    })


    Add-SessionContextMenu -Grid $script:sdGrid -LogoffButton $script:sdLogoff

    $script:sdMessageAll.Add_Click({
        try {
            if (-not $script:sdDataTable) {
                Show-ThemedDialog -Message 'Session data not yet loaded - please wait.' -Title 'Message All' -Icon 'Information'
                return
            }
            $activeRows = @($script:sdDataTable.Select("State = 'Active'"))
            if ($activeRows.Count -eq 0) {
                Show-ThemedDialog -Message 'No active sessions found.' -Title 'Message All' -Icon 'Information'
                return
            }
            $msg = Show-MessageComposeDialog -Recipient "$($activeRows.Count) active user(s)" `
                       -Owner ([System.Windows.Window]::GetWindow($script:sdGrid))
            if ($null -eq $msg) { return }
            Write-AuditLog -Action 'SendMessage' -Target 'All Sessions' -Details "$($activeRows.Count) user(s) - $($msg.Title)"
            $errors = @()
            foreach ($row in $activeRows) {
                try {
                    $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
                    Send-ArmUserSessionMessage `
                        -SubscriptionId $_subId `
                        -ResourceGroup  ([string]$row["HP RG"]) `
                        -HostPool       ([string]$row["Host Pool"]) `
                        -SessionHost    ([string]$row["Session Host FQDN"]) `
                        -SessionId      ([string]$row["ID"]) `
                        -MessageTitle   $msg.Title `
                        -MessageBody    $msg.Body `
                        -Token          (Get-ArmToken)
                }
                catch { $errors += "$([string]$row["User"]): $_" }
            }
            if ($errors) {
                Show-ThemedDialog -Message "Some messages failed:`n$($errors -join "`n")" -Title 'Message All Error' -Icon 'Error'
            } else {
                Show-ThemedDialog -Message "Message sent to $($activeRows.Count) active session(s) successfully." -Title 'Message All' -Icon 'Information'
            }
        }
        catch {
            Show-ThemedDialog -Message "Error: $_" -Title 'Message All Error' -Icon 'Error'
        }
    })

    $script:sdMessage.Add_Click({
        try {
            $selected   = @($script:sdGrid.SelectedItems)
            $activeRows = @($selected | Where-Object { $null -ne $_ -and $_["State"] -eq "Active" })
            if ($activeRows.Count -eq 0) {
                Show-ThemedDialog -Message "No active sessions selected.`nMessages can only be sent to active sessions." -Title 'Send Message' -Icon 'Information'
                return
            }
            $recipient = if ($activeRows.Count -eq 1) { [string]$activeRows[0]["User"] } else { "$($activeRows.Count) users" }
            $msg = Show-MessageComposeDialog -Recipient $recipient `
                       -Owner ([System.Windows.Window]::GetWindow($script:sdGrid))
            if ($null -eq $msg) { return }
            Write-AuditLog -Action 'SendMessage' -Target 'Selected Sessions' -Details "$($activeRows.Count) user(s) - $($msg.Title)"
            $errors = @()
            foreach ($row in $activeRows) {
                try {
                    $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
                    Send-ArmUserSessionMessage `
                        -SubscriptionId $_subId `
                        -ResourceGroup  ([string]$row["HP RG"]) `
                        -HostPool       ([string]$row["Host Pool"]) `
                        -SessionHost    ([string]$row["Session Host FQDN"]) `
                        -SessionId      ([string]$row["ID"]) `
                        -MessageTitle   $msg.Title `
                        -MessageBody    $msg.Body `
                        -Token          (Get-ArmToken)
                }
                catch { $errors += "$([string]$row["User"]): $_" }
            }
            if ($errors) {
                Show-ThemedDialog -Message "Some messages failed:`n$($errors -join "`n")" -Title 'Send Message Error' -Icon 'Error'
            } else {
                Show-ThemedDialog -Message "Message sent to $($activeRows.Count) session(s) successfully." -Title 'Send Message' -Icon 'Information'
            }
        }
        catch {
            Show-ThemedDialog -Message "Error: $_" -Title 'Send Message Error' -Icon 'Error'
        }
    })

    $script:sdLogoff.Add_Click({
        try {
            $selected = @($script:sdGrid.SelectedItems)
            if ($selected.Count -eq 0) {
                Show-ThemedDialog -Message 'No sessions selected.' -Title 'Log Off' -Icon 'Information'
                return
            }

            $names   = ($selected | ForEach-Object { $_["User"] }) -join "`n"
            $confirm = Show-ThemedDialog -Message "Log off $($selected.Count) session(s)?`n`n$names" -Title 'Confirm Log Off' -Buttons 'YesNo' -Icon 'Warning'
            if (-not $confirm) { return }

            $script:sdStatus.Text      = "Logging off $($selected.Count) session(s)..."
            $script:sdLogoff.IsEnabled = $false

            $sessionIds = @($selected | ForEach-Object {
                [PSCustomObject]@{ SessionHost = [string]$_["Session Host FQDN"]; SessionId = [string]$_["ID"] }
            })

            # Audit log - record each session being logged off
            foreach ($sid in $sessionIds) {
                $logoffUser = ($selected | Where-Object { $_["Session Host FQDN"] -eq $sid.SessionHost -and $_["ID"] -eq $sid.SessionId } | ForEach-Object { $_["User"] }) -join ''
                Write-AuditLog -Action 'Logoff' -Target $sid.SessionHost.Split('.')[0].ToLower() -Details "$logoffUser (session $($sid.SessionId))"
            }

            try {
                $script:azArmToken = Get-ArmToken
            } catch {
                Show-ThemedDialog -Message "Failed to obtain ARM token: $_`n`nPlease restart the dashboard." -Title 'Auth Error' -Icon 'Error'
                return
            }

            $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
            $script:_mfaArmOps = @($sessionIds | ForEach-Object {
                @{ Method = 'DELETE'; Path = "/subscriptions/$_subId/resourceGroups/$($script:sdRG)/providers/Microsoft.DesktopVirtualization/hostPools/$($script:sdHP)/sessionHosts/$($_.SessionHost)/userSessions/$($_.SessionId)?force=true&api-version=2024-04-03" }
            })
            Start-DetailJob -JobScript $script:sdLogoffScript `
                            -JobArgs @($script:azArmToken, $_subId, $script:restHelperDef, $script:sdRG, $script:sdHP, $sessionIds) `
                            -OnComplete {
                param($errs)
                if ($errs -and (Resolve-MfaChallenge -Errors $errs -ArmOperations $script:_mfaArmOps)) {
                    if ($script:_mfaRetryReady) {
                        $script:sdStatus.Text = "Log off complete - reloading..."
                    }
                    Update-SessionView
                    return
                }
                if ($errs) {
                    $msg = "Log off errors:`n$($errs -join "`n")"
                    $script:sdStatus.Text = "Errors - see popup"
                    Show-ThemedDialog -Message $msg -Title 'Log Off Error' -Icon 'Error'
                } else {
                    $script:sdStatus.Text = "Log off complete - reloading..."
                }
                Update-SessionView
            }
        }
        catch {
            Show-ThemedDialog -Message "Log off error: $_" -Title 'Log Off Error' -Icon 'Error'
        }
    })

    $ppDisconnBtn = $detailWin.FindName("LogoffDisconnectedButton")
    $ppDisconnBtn.Add_Click({
        try {
            if (-not $script:sdDataTable) {
                Show-ThemedDialog -Message 'Session data not yet loaded - please wait.' -Title 'Not Ready' -Icon 'Information'
                return
            }
            $disconnRows = @($script:sdDataTable.Select("State = 'Disconnected'"))
            if ($disconnRows.Count -eq 0) {
                Show-ThemedDialog -Message 'No disconnected sessions found.' -Title 'Nothing to Do' -Icon 'Information'
                return
            }
            $confirm = Show-ThemedDialog -Message "Log off $($disconnRows.Count) disconnected session(s)?" -Title 'Confirm Log Off Disconnected' -Buttons 'YesNo' -Icon 'Warning'
            if (-not $confirm) { return }

            $script:sdStatus.Text             = "Logging off $($disconnRows.Count) disconnected session(s)..."
            $script:sdLogoff.IsEnabled        = $false
            $script:sdLogoffDisconn.IsEnabled = $false
            try { $script:sdCountdownTimer.Stop() } catch {}

            $sessionIds = @($disconnRows | ForEach-Object {
                [PSCustomObject]@{ SessionHost = [string]$_["Session Host FQDN"]; SessionId = [string]$_["ID"] }
            })

            try {
                $script:azArmToken = Get-ArmToken
            } catch {
                Show-ThemedDialog -Message "Failed to obtain ARM token: $_`n`nPlease restart the dashboard." -Title 'Auth Error' -Icon 'Error'
                return
            }

            $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
            $script:_mfaArmOps = @($sessionIds | ForEach-Object {
                @{ Method = 'DELETE'; Path = "/subscriptions/$_subId/resourceGroups/$($script:sdRG)/providers/Microsoft.DesktopVirtualization/hostPools/$($script:sdHP)/sessionHosts/$($_.SessionHost)/userSessions/$($_.SessionId)?force=true&api-version=2024-04-03" }
            })
            Start-DetailJob -JobScript $script:sdLogoffScript `
                            -JobArgs @($script:azArmToken, $_subId, $script:restHelperDef, $script:sdRG, $script:sdHP, $sessionIds) `
                            -OnComplete {
                param($errs)
                if ($errs -and (Resolve-MfaChallenge -Errors $errs -ArmOperations $script:_mfaArmOps)) {
                    if ($script:_mfaRetryReady) {
                        $script:sdStatus.Text = "Disconnected sessions logged off - reloading..."
                    }
                    $script:sdLogoffDisconn.IsEnabled = $true
                    try { $script:sdCountdownTimer.Start() } catch {}
                    Update-SessionView
                    return
                }
                $script:sdLogoffDisconn.IsEnabled = $true
                if ($errs) {
                    $script:sdStatus.Text = "Completed with errors: $($errs -join ' | ')"
                } else {
                    $script:sdStatus.Text = "Disconnected sessions logged off - reloading..."
                }
                try { $script:sdCountdownTimer.Start() } catch {}
                Update-SessionView
            }
        }
        catch {
            Show-ThemedDialog -Message "Error: $_" -Title 'Log Off Error' -Icon 'Error'
        }
    })

    Update-SessionView
    $detailWin.Show()
}


# =============================================================================
# Initialise - wires the PoolGrid double-click to open the per-pool session window
# =============================================================================

function Initialize-SessionDetail {
    $script:PoolGrid.Add_MouseDoubleClick({
        $row = $script:PoolGrid.SelectedItem
        if ($row -and $row["Total Sessions"] -gt 0) {
            Show-SessionDetail -HostPoolName $row["Host Pool"] -HostPoolRG $row["Host Pool RG"]
        }
        elseif ($row) {
            Show-ThemedDialog -Message "No sessions currently active for '$($row["Host Pool"])'." -Title 'No Sessions' -Icon 'Information'
        }
    })
}
