# =============================================================================
# tab-monitoring.ps1  -  Monitoring tab module
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Encapsulates everything needed for the Monitoring tab in one file so the
# main dashboard script stays clean. Dot-source this file BEFORE the XAML
# string is built; the main script then injects $MonitoringTab_Xaml into its
# XAML via a placeholder comment and calls the public lifecycle function:
#
#   Initialize-MonitoringTab  - once, after $window is loaded
#
# FEATURES
# --------
# 1. "Open AVD Insights in Azure Portal" button (unchanged from original)
# 2. Winlogon Stages bar chart - queries WVDCheckpoints table in Log Analytics
#    for logon stage timing data (Group Policy, FSLogix, User Auth, Shell, Others).
#    Shows P50 (median) and P95 bars per stage, aggregated per host pool.
#    Manual refresh only (no auto-refresh timer).
#
# DATA SOURCES
# -------------
# 1. Winlogon Stages (bar chart):
#    - Tables: WVDConnections + WVDCheckpoints (joined on CorrelationId)
#    - The "LogonDelay" checkpoint contains per-stage timing in its Parameters bag
#    - Each key = internal stage name, value = duration in milliseconds
#    - Stages are renamed to display labels:
#        frxsvc              -> FSLogix       (FSLogix profile load time)
#        GPClient            -> Group policy  (Group Policy processing time)
#        WinLogon_StartShell -> Shell         (Shell initialisation time)
#        AuthenticateUser    -> User Auth.    (User authentication time)
#        everything else     -> Others        (misc logon tasks)
#    - Aggregated as P50 (median) and P95 percentiles per stage
#    - Query adapted from the AVD Insights workbook "Winlogon stages" view
#
# 2. RTT by Gateway Region (data grid):
#    - Tables: WVDConnectionNetworkData + WVDConnections (joined on CorrelationId)
#    - WVDConnectionNetworkData provides EstRoundTripTimeInMs per sample
#    - WVDConnections provides GatewayRegion and UserName for grouping
#    - Aggregated per region: distinct users, median/P95/peak RTT, peak timestamp
#
# Both queries use the Log Analytics REST API (POST to /api/query) with bearer
# tokens from Get-ArmToken. Queries run synchronously on the UI thread since
# this is manual-refresh only (no background runspace needed).
# =============================================================================

# PSScriptAnalyzer flags $MonitoringTab_Xaml as "assigned but never used"
# because it cannot see across the dot-source boundary into the calling script.
# This suppression attribute silences that false positive.
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'MonitoringTab_Xaml',
    Justification = 'Exported to the calling script via dot-source')]
param()

# =============================================================================
# KQL query templates - loaded from external .kql files in data/kql/.
# These are read once at dot-source time and cached in $script: variables.
# At query time, placeholder tokens ({{TimeRange}}, {{HostPoolFilter}}) are
# replaced with actual values before sending to the LAW REST API.
# Keeping KQL in separate files makes them easy to edit, test in LAW directly,
# and maintain without touching PowerShell code.
# =============================================================================
$script:_kqlDir = Join-Path $PSScriptRoot '..\data\kql'
$script:_kqlWinlogonStages   = [System.IO.File]::ReadAllText((Join-Path $script:_kqlDir 'winlogon-stages.kql'))
$script:_kqlRttByGateway     = [System.IO.File]::ReadAllText((Join-Path $script:_kqlDir 'rtt-by-gateway.kql'))
$script:_kqlWinlogonHostPools = [System.IO.File]::ReadAllText((Join-Path $script:_kqlDir 'winlogon-hostpools.kql'))
$script:_kqlSessionHistory   = [System.IO.File]::ReadAllText((Join-Path $script:_kqlDir 'session-history.kql'))

# =============================================================================
# 1. XAML fragment
#
# The main script contains the placeholder comment <!-- TAB:MONITORING -->
# inside its TabControl. Before parsing the XAML it does a string replace:
#   [xml]$xaml = $rawXaml -replace '<!-- TAB:MONITORING -->', $MonitoringTab_Xaml
#
# Layout:
#   Top: AVD Insights portal button (centred, compact)
#   Middle: Winlogon Stages section with controls and bar chart canvas
#   Bottom: Status text
# =============================================================================

$MonitoringTab_Xaml = @'
<TabItem Header="Monitoring" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <DockPanel Margin="16">

        <!-- Top toolbar: portal button + controls + legend + refresh -->
        <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="MonitoringPortalButton" Grid.Column="0"
                    Content="Open AVD Insights in Azure Portal"
                    Background="#0078D4" Foreground="White"
                    BorderThickness="0" FontSize="12"
                    FontWeight="SemiBold" Cursor="Hand"
                    Padding="16,8" Margin="0,0,20,0">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#005A9E"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#003D6B"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <TextBlock Grid.Column="1" Text="Time Range:" FontSize="12" Foreground="#555"
                       VerticalAlignment="Center" Margin="0,0,6,0"/>
            <ComboBox x:Name="MonWinlogonTimeRange" Grid.Column="2" Width="140" FontSize="12"
                      SelectedIndex="5">
                <ComboBoxItem Content="Last 1 Hour"    Tag="1h"/>
                <ComboBoxItem Content="Last 4 Hours"   Tag="4h"/>
                <ComboBoxItem Content="Last 8 Hours"   Tag="8h"/>
                <ComboBoxItem Content="Last 12 Hours"  Tag="12h"/>
                <ComboBoxItem Content="Last 24 Hours"  Tag="24h"/>
                <ComboBoxItem Content="Last 48 Hours"  Tag="48h"/>
                <ComboBoxItem Content="Last 7 Days"    Tag="7d"/>
                <ComboBoxItem Content="Last 30 Days"   Tag="30d"/>
                <ComboBoxItem Content="Custom Range..." Tag="custom"/>
            </ComboBox>
            <TextBlock Grid.Column="3" Text="Host Pool:" FontSize="12" Foreground="#555"
                       VerticalAlignment="Center" Margin="16,0,6,0"/>
            <ComboBox x:Name="MonWinlogonHostPool" Grid.Column="4" Width="220" FontSize="12">
                <ComboBoxItem Content="All Host Pools" IsSelected="True"/>
            </ComboBox>
            <!-- Selected range display -->
            <TextBlock x:Name="MonRangeDisplay" Grid.Column="5" FontSize="11" Foreground="#555"
                       VerticalAlignment="Center" Margin="12,0,0,0" HorizontalAlignment="Left"/>
            <!-- Legend -->
            <StackPanel Grid.Column="6" Orientation="Horizontal" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="16,0,16,0">
                <Rectangle Width="14" Height="14" Fill="#E91E63" Margin="0,0,4,0" RadiusX="2" RadiusY="2"/>
                <TextBlock Text="P95" FontSize="11" Foreground="#333" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <Rectangle Width="14" Height="14" Fill="#B0BEC5" Margin="0,0,4,0" RadiusX="2" RadiusY="2"/>
                <TextBlock Text="P50" FontSize="11" Foreground="#333" VerticalAlignment="Center"/>
            </StackPanel>
            <Button x:Name="MonWinlogonRefreshBtn" Grid.Column="7"
                    Content="Refresh" Background="#4CAF50" Foreground="White"
                    BorderThickness="0" FontSize="12" FontWeight="SemiBold"
                    Cursor="Hand" Padding="16,8">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#388E3C"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#2E7D32"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </Grid>

        <!-- Status bar at bottom -->
        <TextBlock x:Name="MonWinlogonStatus" DockPanel.Dock="Bottom"
                   FontSize="11" Foreground="#777" Margin="0,6,0,0"/>

        <!-- Main content: scrollable so nothing gets clipped when window is small -->
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">

        <!-- Main content: Session History at top, Winlogon chart (left) and RTT grid (right) below -->
        <Grid>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="3*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="2*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="200"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="220"/>
            </Grid.RowDefinitions>

            <!-- Session History heading — full width at top -->
            <TextBlock Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="3"
                       Text="Session History" FontSize="16" FontWeight="SemiBold"
                       Foreground="#1A1A2E" Margin="0,0,0,6"/>

            <!-- Session History line chart canvas -->
            <Border Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="3"
                    Background="White" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="4">
                <Canvas x:Name="MonSessionHistoryCanvas" ClipToBounds="True"/>
            </Border>

            <!-- Session History status / legend line -->
            <StackPanel Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="3"
                        Orientation="Horizontal" Margin="0,4,0,0">
                <Rectangle Width="14" Height="14" Fill="#1976D2" Margin="0,0,4,0" RadiusX="2" RadiusY="2"/>
                <TextBlock Text="Active" FontSize="11" Foreground="#333" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <Rectangle Width="14" Height="14" Fill="#F57C00" Margin="0,0,4,0" RadiusX="2" RadiusY="2"/>
                <TextBlock Text="Disconnected" FontSize="11" Foreground="#333" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <TextBlock x:Name="MonSessionHistoryStatus" FontSize="11" Foreground="#777" VerticalAlignment="Center"/>
            </StackPanel>

            <!-- Section headings for Winlogon + RTT -->
            <TextBlock Grid.Row="3" Grid.Column="0" Text="Winlogon Stages" FontSize="16" FontWeight="SemiBold"
                       Foreground="#1A1A2E" Margin="0,16,0,6"/>
            <StackPanel Grid.Row="3" Grid.Column="2" Orientation="Horizontal" Margin="0,16,0,6">
                <TextBlock Text="RTT by Gateway Region" FontSize="16" FontWeight="SemiBold"
                           Foreground="#1A1A2E" VerticalAlignment="Center" Margin="0,0,16,0"/>
                <TextBlock x:Name="MonRttStatus" FontSize="11" Foreground="#777"
                           VerticalAlignment="Center"/>
            </StackPanel>

            <!-- Winlogon Stages bar chart (left panel) -->
            <Border Grid.Row="4" Grid.Column="0" Background="White" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="4">
                <Canvas x:Name="MonWinlogonCanvas" ClipToBounds="True"/>
            </Border>

            <!-- RTT by Gateway Region (right panel) -->
            <Border Grid.Row="4" Grid.Column="2" Background="White" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="4">
                <DataGrid x:Name="MonRttGrid"
                          AutoGenerateColumns="False"
                          IsReadOnly="True"
                          CanUserAddRows="False"
                          CanUserDeleteRows="False"
                          CanUserSortColumns="True"
                          HeadersVisibility="Column"
                          GridLinesVisibility="Horizontal"
                          HorizontalGridLinesBrush="#E8E8E8"
                          BorderThickness="0"
                          Background="White"
                          RowBackground="White"
                          AlternatingRowBackground="#F8F9FA"
                          FontSize="12"
                          ColumnHeaderHeight="32"
                          RowHeight="28">
                    <DataGrid.ColumnHeaderStyle>
                        <Style TargetType="DataGridColumnHeader">
                            <Setter Property="Background" Value="#1A5276"/>
                            <Setter Property="Foreground" Value="White"/>
                            <Setter Property="FontWeight" Value="SemiBold"/>
                            <Setter Property="FontSize" Value="12"/>
                            <Setter Property="Padding" Value="8,4"/>
                            <Setter Property="BorderThickness" Value="0,0,1,0"/>
                            <Setter Property="BorderBrush" Value="#2471A3"/>
                        </Style>
                    </DataGrid.ColumnHeaderStyle>
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Gateway Region" Binding="{Binding GatewayRegion}" Width="2*"/>
                        <DataGridTextColumn Header="Users" Binding="{Binding Users}" Width="*">
                            <DataGridTextColumn.ElementStyle>
                                <Style TargetType="TextBlock">
                                    <Setter Property="TextAlignment" Value="Center"/>
                                </Style>
                            </DataGridTextColumn.ElementStyle>
                        </DataGridTextColumn>
                        <DataGridTextColumn Header="Median" Binding="{Binding Median}" Width="1.2*">
                            <DataGridTextColumn.ElementStyle>
                                <Style TargetType="TextBlock">
                                    <Setter Property="TextAlignment" Value="Center"/>
                                </Style>
                            </DataGridTextColumn.ElementStyle>
                        </DataGridTextColumn>
                        <DataGridTextColumn Header="P95" Binding="{Binding P95}" Width="*">
                            <DataGridTextColumn.ElementStyle>
                                <Style TargetType="TextBlock">
                                    <Setter Property="TextAlignment" Value="Center"/>
                                </Style>
                            </DataGridTextColumn.ElementStyle>
                        </DataGridTextColumn>
                        <DataGridTextColumn Header="Peak" Binding="{Binding Peak}" Width="*">
                            <DataGridTextColumn.ElementStyle>
                                <Style TargetType="TextBlock">
                                    <Setter Property="TextAlignment" Value="Center"/>
                                </Style>
                            </DataGridTextColumn.ElementStyle>
                        </DataGridTextColumn>
                        <DataGridTextColumn Header="Peak Time" Binding="{Binding PeakTime}" Width="2*"/>
                    </DataGrid.Columns>
                </DataGrid>
            </Border>

        </Grid>
        </ScrollViewer>
    </DockPanel>
</TabItem>
'@

# =============================================================================
# 2. Winlogon Stages KQL query
#
# Queries Log Analytics for logon stage timing data, adapted from the AVD
# Insights workbook "Winlogon stages" view.
#
# RETURNS: Array of [PSCustomObject]@{ Stage; P50; P95; Samples }
#   Stage   = display label (e.g. "Group policy", "FSLogix", "Shell")
#   P50     = median duration in seconds across all connections
#   P95     = 95th percentile duration in seconds
#   Samples = number of connections sampled
#
# HOW THE KQL WORKS (step by step):
#   1. Start from WVDConnections where State == "Connected" in the time range
#   2. leftsemi join to WVDCheckpoints "RdpStackConnectionEstablished" to
#      exclude failed connections that never reached the host
#   3. leftsemi join to "LoadBalancedNewConnection" to filter to new sessions
#      (LoadBalanceOutcome == "NewSession") vs reconnections
#   4. inner join to the "LogonDelay" checkpoint - this is the key checkpoint
#      that contains per-stage timing in its Parameters bag:
#        Parameters = { "LogonType": "DirectSession", "WinLogonPid": 1234,
#                       "WinLogon_Logon_GPClient": 15000,
#                       "WinLogon_Logon_frxsvc": 3500, ... }
#   5. Remove non-timing keys (LogonType, WinLogonPid) from Parameters
#   6. mv-expand the Parameters bag into individual rows (one per stage)
#   7. Extract stage name and duration (ms -> seconds)
#   8. Rename internal stage names to friendly display labels using renameStage()
#   9. Aggregate per-stage: sum time per user/host, then percentile across users
#
# HOST POOL FILTER:
#   When a specific host pool is selected, a KQL where clause is injected
#   that filters WVDConnections by _ResourceId (the host pool ARM resource ID).
#   The host pool name is the 9th segment (index 8) of the ARM resource path.
# =============================================================================

function Invoke-WinlogonStagesQuery {
    param(
        [string]$TimeRange      = '48h',
        [string]$HostPoolFilter = '',   # empty = all host pools
        [string]$CustomFrom     = '',
        [string]$CustomTo       = ''
    )

    # Build host pool filter clause if a specific pool is selected.
    # Uses _ResourceId which contains the full ARM resource ID of the host pool.
    # We match the host pool name (last segment) case-insensitively.
    $hpFilter = ''
    if ($HostPoolFilter -and $HostPoolFilter -ne 'All Host Pools') {
        $escapedHp = $HostPoolFilter.Replace("'", "''").ToLower()
        $hpFilter = "| where tolower(tostring(split(_ResourceId, '/')[8])) == '$escapedHp'"
    }

    # KQL query adapted from the AVD Insights workbook "Winlogon stages" view.
    #
    # HOW IT WORKS:
    # The LogonDelay checkpoint in WVDCheckpoints contains per-stage timing data
    # in its Parameters bag. Each key is a stage name (e.g. "WinLogon_Logon_GPClient")
    # and the value is the duration in milliseconds.
    #
    # The query:
    #   1. Starts from WVDConnections (State == "Connected") for the time range
    #   2. Filters to connections that reached RdpStackConnectionEstablished (excludes failures)
    #   3. Filters to new sessions (LoadBalanceOutcome == "NewSession")
    #   4. Joins to the LogonDelay checkpoint which has per-stage timing
    #   5. Expands the Parameters bag into individual stage rows
    #   6. Renames internal stage names to display labels:
    #        frxsvc              -> FSLogix      (FSLogix profile load)
    #        GPClient            -> Group policy  (Group Policy processing)
    #        WinLogon_StartShell -> Shell         (Shell initialisation)
    #        AuthenticateUser    -> User Auth.    (User authentication)
    #        everything else     -> Others
    #   7. Aggregates P50 and P95 percentiles per stage
    #
    # STAGES OUTPUT: Others, User Auth., FSLogix, Shell, Group policy
    # Load KQL from external file and replace placeholder tokens with actual values.
    # See data/kql/winlogon-stages.kql for the full query with comments.
    # Build KQL — for custom range substitute absolute datetime expression
    if ($CustomFrom -and $CustomTo) {
        $kql = $script:_kqlWinlogonStages `
            -replace 'ago\(\{\{TimeRange\}\}\)', "datetime($CustomFrom)" `
            -replace '\{\{HostPoolFilter\}\}', $hpFilter
        # Add upper bound filter after the existing where clause
        $kql = $kql -replace "(where TimeGenerated > datetime\($([regex]::Escape($CustomFrom))\))", "`$1`n| where TimeGenerated < datetime($CustomTo)"
        $isoTimespan = 'P30D'
    } else {
        $kql = $script:_kqlWinlogonStages -replace '\{\{TimeRange\}\}', $TimeRange -replace '\{\{HostPoolFilter\}\}', $hpFilter
        $isoTimespan = switch ($TimeRange) {
            '1h'  { 'PT1H' }   '4h'  { 'PT4H' }
            '8h'  { 'PT8H' }   '12h' { 'PT12H' }
            '24h' { 'PT24H' }  '48h' { 'PT48H' }
            '7d'  { 'P7D' }    default { 'PT24H' }
        }
    }

    $tok  = Get-ArmToken
    $body = @{ query = $kql; timespan = $isoTimespan }
    $resp = Invoke-ArmRestMethod -Method POST `
                -Path "$($script:LawWorkspaceResourceId)/api/query" `
                -Token $tok `
                -ApiVersion '2020-08-01' `
                -Body $body `
                -FullResponse

    # Parse the columnar JSON response into a list of stage data objects
    $stages = [System.Collections.Generic.List[PSObject]]::new()

    if ($resp.tables -and $resp.tables[0].rows -and $resp.tables[0].rows.Count -gt 0) {
        # Resolve column indices (PS5.1 uses .ColumnName, PS7 uses .name)
        $cols = @($resp.tables[0].columns | ForEach-Object {
            $n = [string]$_.name
            if (-not $n) { $n = [string]$_.ColumnName }
            if (-not $n) { $n = [string]$_ }
            $n
        })
        $colsLower = @($cols | ForEach-Object { $_.ToLower() })
        $idxStage   = [array]::IndexOf($colsLower, 'stage')
        $idxP50     = [array]::IndexOf($colsLower, 'p50')
        $idxP95     = [array]::IndexOf($colsLower, 'p95')
        $idxSamples = [array]::IndexOf($colsLower, 'samples')

        if ($idxStage -ge 0 -and $idxP50 -ge 0 -and $idxP95 -ge 0) {
            foreach ($r in $resp.tables[0].rows) {
                $stages.Add([PSCustomObject]@{
                    Stage   = [string]$r[$idxStage]
                    P50     = [double]$r[$idxP50]
                    P95     = [double]$r[$idxP95]
                    Samples = if ($idxSamples -ge 0) { [int]$r[$idxSamples] } else { 0 }
                })
            }
        }
    }

    # Sort stages into a fixed display order matching AVD Insights:
    # Others, User Auth., FSLogix, Shell, Group policy
    # Any stages not in the map appear at the end.
    $stageOrder = @{
        'Others'       = 0
        'User Auth.'   = 1
        'Group policy' = 2
        'Shell'        = 3
        'FSLogix'      = 4
    }
    $sorted = @($stages | Sort-Object { if ($stageOrder.ContainsKey($_.Stage)) { $stageOrder[$_.Stage] } else { 99 } })
    return $sorted
}


# =============================================================================
# 3. Winlogon Stages host pool list query
#
# Queries WVDCheckpoints for distinct host pool names to populate the
# host pool filter ComboBox. Separate from the main query to keep it fast.
# =============================================================================

function Invoke-WinlogonHostPoolsQuery {
    # Load KQL from external file. No placeholders needed - always uses 7-day window.
    # See data/kql/winlogon-hostpools.kql for the full query with comments.
    $kql = $script:_kqlWinlogonHostPools

    $tok  = Get-ArmToken
    $body = @{ query = $kql; timespan = 'P7D' }
    $resp = Invoke-ArmRestMethod -Method POST `
                -Path "$($script:LawWorkspaceResourceId)/api/query" `
                -Token $tok `
                -ApiVersion '2020-08-01' `
                -Body $body `
                -FullResponse

    $pools = [System.Collections.Generic.List[string]]::new()
    if ($resp.tables -and $resp.tables[0].rows -and $resp.tables[0].rows.Count -gt 0) {
        foreach ($r in $resp.tables[0].rows) {
            $name = [string]$r[0]
            if ($name) { $pools.Add($name) }
        }
    }
    return @($pools)
}


# =============================================================================
# 4. Bar chart renderer
#
# Draws a grouped bar chart on a WPF Canvas using Rectangle primitives.
# Each stage gets two side-by-side vertical bars: P95 (magenta) and P50 (blue-grey).
# The Y-axis auto-scales to fit the tallest bar. Stage labels are drawn below
# the X-axis. Y-axis labels show duration in seconds.
#
# Colour scheme matches AVD Insights:
#   P95 = #E91E63 (magenta/pink) — the "worst case" metric
#   P50 = #B0BEC5 (light blue-grey) — the "typical" metric
#
# The chart includes:
#   - Light background (#FAFAFA)
#   - Horizontal gridlines at 25%, 50%, 75% of Y-max
#   - Y-axis labels (0s, Xs, Ys, Zs, Ws)
#   - Stage name labels below each bar group
#   - P95 total logon time as a summary stat
# =============================================================================

# =============================================================================
# 4b. Session History line chart renderer
#
# Draws a two-series line chart on a WPF Canvas using WPF Polyline primitives.
# No external charting libraries — everything is pure WPF drawing.
#
# SERIES:
#   Active       = #1976D2 (blue)   — users actively at the keyboard
#   Disconnected = #F57C00 (orange) — sessions alive but user has disconnected
#
# VISUAL LAYOUT:
#   Left margin  (50px) = Y-axis labels (session count)
#   Bottom margin (36px) = X-axis time labels (~6 evenly-spaced ticks)
#   Top margin   (16px) = padding above the top gridline
#   Right margin (16px) = padding to the right of the last data point
#   Chart area = canvas size minus the four margins above
#   Y-axis: 0 at bottom, auto-scaled to max value rounded up to a nice number
#   X-axis: proportional — each point placed by (time - tMin) / (tMax - tMin)
#
# ZERO-FILL:
#   KQL only returns rows for bins that contain data. If a bin has zero sessions
#   it is simply absent from the result set. Without zero-fill the Polyline
#   connects directly between the last real point before the gap and the first
#   real point after it, producing a misleading diagonal line. The renderer
#   generates every expected bin from tMin to tMax at $BinMinutes intervals and
#   inserts Value=0 for any bin not present in the result. See $drawSeries.
#
# HOVER:
#   A vertical crosshair, dot indicator, and tooltip are added once in
#   Initialize-MonitoringTab (they persist across redraws). After each draw the
#   canvas Tag is updated with the latest layout/data so the persistent
#   MouseMove handler always reads correct values without being re-wired.
# =============================================================================

function Update-SessionHistoryChart {
    param(
        [System.Windows.Controls.Canvas]$Canvas,
        [object[]]$SessionsData,              # @(@{ Time=[datetime]; Value=[double] }, ...) — active sessions per bin
        [object[]]$DisconnectedData = @(),    # @(@{ Time=[datetime]; Value=[double] }, ...) — disconnected sessions per bin
        [int]$BinMinutes = 60                 # bin width in minutes — used to generate the zero-fill step sequence
    )

    $Canvas.Children.Clear()

    $w = $Canvas.ActualWidth
    $h = $Canvas.ActualHeight
    if ($w -lt 100 -or $h -lt 80) { return }

    $ml = 50; $mr = 16; $mt = 16; $mb = 36
    $cw = $w - $ml - $mr
    $ch = $h - $mt - $mb

    $brushConv = New-Object System.Windows.Media.BrushConverter

    # ── Chart background ──────────────────────────────────────────────────
    $bg = New-Object System.Windows.Shapes.Rectangle
    $bg.Width = $cw; $bg.Height = $ch
    $bg.Fill = $brushConv.ConvertFromString('#FAFAFA')
    [System.Windows.Controls.Canvas]::SetLeft($bg, $ml)
    [System.Windows.Controls.Canvas]::SetTop($bg, $mt)
    [void]$Canvas.Children.Add($bg)

    # ── Helper: add a TextBlock ──────────────────────────────────────────
    $addText = {
        param($text, $x, $y, $fontSize, $color, $alignRight)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $tb.FontSize = if ($fontSize) { $fontSize } else { 10 }
        $tb.Foreground = $brushConv.ConvertFromString($(if ($color) { $color } else { '#666' }))
        if ($alignRight) {
            $tb.TextAlignment = [System.Windows.TextAlignment]::Right
            $tb.Width = $x
            [System.Windows.Controls.Canvas]::SetLeft($tb, 0)
        } else {
            [System.Windows.Controls.Canvas]::SetLeft($tb, $x)
        }
        [System.Windows.Controls.Canvas]::SetTop($tb, $y)
        [void]$Canvas.Children.Add($tb)
    }

    # ── Helper: add a Line ────────────────────────────────────────────────
    $addLine = {
        param($x1, $y1, $x2, $y2, $color, $thickness, $dashArray)
        $ln = New-Object System.Windows.Shapes.Line
        $ln.X1 = $x1; $ln.Y1 = $y1; $ln.X2 = $x2; $ln.Y2 = $y2
        $ln.Stroke = $brushConv.ConvertFromString($color)
        $ln.StrokeThickness = $thickness
        if ($dashArray) {
            $dc = New-Object System.Windows.Media.DoubleCollection
            foreach ($d in $dashArray) { $dc.Add([double]$d) }
            $ln.StrokeDashArray = $dc
        }
        [void]$Canvas.Children.Add($ln)
    }

    # No data — show placeholder message
    if (-not $SessionsData -or $SessionsData.Count -eq 0) {
        & $addText 'No session history data. Click Refresh to query.' ($w / 2 - 140) ($h / 2 - 8) 13 '#999' $false
        return
    }

    # ── Y-axis scale ──────────────────────────────────────────────────────
    # Scale to the maximum value across BOTH series so neither line is clipped.
    # Round up to a "nice" number so gridline labels are clean integers.
    $allValues = @($SessionsData | ForEach-Object { $_.Value })
    if ($DisconnectedData -and $DisconnectedData.Count -gt 0) { $allValues += $DisconnectedData | ForEach-Object { $_.Value } }
    $maxVal = ($allValues | Measure-Object -Maximum).Maximum
    $maxVal = [math]::Max(1, $maxVal)   # avoid div-by-zero on empty/all-zero data
    $yMax = if ($maxVal -le 5)           { [math]::Ceiling($maxVal) }
            elseif ($maxVal -le 20)      { [math]::Ceiling($maxVal / 2)   * 2   }
            elseif ($maxVal -le 100)     { [math]::Ceiling($maxVal / 10)  * 10  }
            elseif ($maxVal -le 500)     { [math]::Ceiling($maxVal / 50)  * 50  }
            else                         { [math]::Ceiling($maxVal / 100) * 100 }

    # ── Gridlines and Y-axis labels ───────────────────────────────────────
    foreach ($frac in @(0.25, 0.50, 0.75, 1.0)) {
        $y = $mt + $ch * (1 - $frac)
        & $addLine $ml $y ($ml + $cw) $y '#E0E0E0' 1 @(4, 4)
        & $addText ([math]::Round($yMax * $frac, 0).ToString()) ($ml - 4) ($y - 8) 10 '#666' $true
    }
    & $addText '0' ($ml - 4) ($mt + $ch - 8) 10 '#666' $true

    # ── Axes ──────────────────────────────────────────────────────────────
    & $addLine $ml $mt $ml ($mt + $ch) '#999' 1 $null
    & $addLine $ml ($mt + $ch) ($ml + $cw) ($mt + $ch) '#999' 1 $null

    # ── X-axis time labels (~6 evenly spaced) ─────────────────────────────
    # Labels are converted to local time for display (the data is stored as UTC
    # internally). For spans <= 24h we show HH:mm only; for longer spans we
    # prepend dd/MM so the date is visible when the chart spans multiple days.
    $timeSeries = $SessionsData
    $ptCount = $timeSeries.Count
    if ($ptCount -ge 2) {
        $tMin = $timeSeries[0].Time
        $tMax = $timeSeries[$ptCount - 1].Time
        $tSpan = ($tMax - $tMin).TotalSeconds
        $labelCount = [math]::Min(6, $ptCount)
        for ($li = 0; $li -lt $labelCount; $li++) {
            $frac = if ($labelCount -gt 1) { $li / ($labelCount - 1) } else { 0 }
            $lx = $ml + $frac * $cw - 24
            $lt = $tMin.AddSeconds($tSpan * $frac).ToLocalTime()
            $label = $lt.ToString('HH:mm')
            if ($tSpan -gt 86400) { $label = $lt.ToString('dd/MM HH:mm') }
            & $addText $label $lx ($mt + $ch + 5) 10 '#666' $false
        }
    }

    # ── Helper: draw a Polyline series with zero-fill for sparse bins ─────
    # KQL only returns rows for bins that have data. If a bin has zero sessions
    # it is absent from the result set entirely. Without zero-fill the Polyline
    # draws a diagonal line directly from the last real point to the next real
    # point, making a gap look like a gradual ramp. Zero-fill inserts explicit
    # Value=0 points so gaps show as a drop to zero.
    $drawSeries = {
        param($points, $color, $thickness)
        if (-not $points -or $points.Count -lt 2) { return }

        $tMin = $points[0].Time
        $tMax = $points[$points.Count - 1].Time

        # Key the lookup on UTC ticks (Int64) not DateTime objects.
        # DateTime.Kind affects hash equality: a UTC datetime and an Unspecified
        # datetime with the same wall-clock value have different hash codes and
        # will not match in a hashtable. Using .ToUniversalTime().Ticks removes
        # any Kind ambiguity and gives a stable integer key.
        $lookup = @{}
        foreach ($pt in $points) { $lookup[$pt.Time.ToUniversalTime().Ticks] = $pt.Value }

        # Walk every expected bin from tMin to tMax at $BinMinutes intervals.
        # AddSeconds(1) on the upper bound ensures the final bin is included
        # even if floating-point drift puts it just past tMax.
        $filled = [System.Collections.Generic.List[PSCustomObject]]::new()
        $t = $tMin
        while ($t -le $tMax.AddSeconds(1)) {
            $ticks = $t.ToUniversalTime().Ticks
            $v = if ($lookup.ContainsKey($ticks)) { $lookup[$ticks] } else { 0.0 }
            $filled.Add([PSCustomObject]@{ Time = $t; Value = $v })
            $t = $t.AddMinutes($BinMinutes)
        }

        $tSpanSec = ($tMax - $tMin).TotalSeconds
        if ($tSpanSec -le 0) { $tSpanSec = 1 }   # guard against single-point series

        # X position = proportional fraction of the total time span
        # Y position = inverted fraction of yMax (0 at bottom, yMax at top)
        $poly = New-Object System.Windows.Shapes.Polyline
        $poly.Stroke = $brushConv.ConvertFromString($color)
        $poly.StrokeThickness = $thickness
        $poly.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round

        $pts = New-Object System.Windows.Media.PointCollection
        foreach ($pt in $filled) {
            $xFrac = ($pt.Time - $tMin).TotalSeconds / $tSpanSec
            $px = $ml + $xFrac * $cw
            $py = $mt + $ch - ($pt.Value / $yMax) * $ch
            $pts.Add([System.Windows.Point]::new($px, $py))
        }
        $poly.Points = $pts
        [void]$Canvas.Children.Add($poly)

        # Stash the filled sequence so the caller can hand it to the hover handler.
        # The hover handler needs the zero-filled version (not raw $points) so
        # the crosshair snaps to the correct position even over gap regions.
        $script:_monSessionHistoryFilled = $filled
    }

    # Draw Disconnected (orange) first so Sessions (blue) renders on top
    & $drawSeries $DisconnectedData '#F57C00' 2
    $filledDisc     = $script:_monSessionHistoryFilled
    & $drawSeries $SessionsData     '#1976D2' 2
    $filledSessions = $script:_monSessionHistoryFilled

    # ── Update hover metadata on canvas Tag ──────────────────────────────
    # MouseMove and MouseLeave are wired once in Initialize-MonitoringTab and
    # never removed. This function only updates Canvas.Tag with the current
    # layout geometry and zero-filled data so the persistent handlers always
    # read up-to-date values after every redraw (time range change, resize, etc).
    # Storing it in Tag avoids script-level variables per-canvas and keeps the
    # handler self-contained.
    $Canvas.Tag = [PSCustomObject]@{
        SessionsPoints      = $filledSessions
        DisconnectedPoints  = $filledDisc
        ML                  = $ml; MR = $mr; MT = $mt; MB = $mb
        YMax                = $yMax
        TMin                = if ($filledSessions -and $filledSessions.Count -gt 0) { $filledSessions[0].Time } else { [datetime]::UtcNow }
        TMax                = if ($filledSessions -and $filledSessions.Count -gt 0) { $filledSessions[$filledSessions.Count - 1].Time } else { [datetime]::UtcNow }
    }

    # Re-add the persistent hover overlay elements.
    # Canvas.Children.Clear() at the top of this function removed them along with
    # everything else. They must be re-added on every redraw so they remain visible
    # on top of the newly drawn lines. The handlers themselves stay wired — only
    # the visual elements need to be put back into the canvas child collection.
    if ($script:_monShCrosshair) { [void]$Canvas.Children.Add($script:_monShCrosshair) }
    if ($script:_monShDot)       { [void]$Canvas.Children.Add($script:_monShDot) }
    if ($script:_monShTooltip)   { [void]$Canvas.Children.Add($script:_monShTooltip) }
}


# =============================================================================
# 3b. RTT by Gateway Region query
#
# Queries WVDConnections joined with WVDConnectionNetworkData to get
# round-trip time statistics grouped by Azure gateway region.
# Shows: Gateway Region, distinct user count, Median RTT, P95 RTT,
#        Peak RTT, and the timestamp of the peak.
#
# WVDConnections provides the GatewayRegion and UserName fields.
# WVDConnectionNetworkData provides EstRoundTripTimeInMs per sample.
# The two tables are joined on CorrelationId (one correlation per connection).
# =============================================================================

function Invoke-RttByGatewayQuery {
    param(
        [string]$TimeRange  = '48h',
        [string]$CustomFrom = '',
        [string]$CustomTo   = ''
    )

    # Load KQL and substitute time range
    if ($CustomFrom -and $CustomTo) {
        $kql = $script:_kqlRttByGateway `
            -replace 'ago\(\{\{TimeRange\}\}\)', "datetime($CustomFrom)"
        $kql = $kql -replace "(where TimeGenerated > datetime\($([regex]::Escape($CustomFrom))\))", "`$1`n    | where TimeGenerated < datetime($CustomTo)"
        $isoTimespan = 'P30D'
    } else {
        $kql = $script:_kqlRttByGateway -replace '\{\{TimeRange\}\}', $TimeRange
        $isoTimespan = switch ($TimeRange) {
            '1h'  { 'PT1H' }   '4h'  { 'PT4H' }
            '8h'  { 'PT8H' }   '12h' { 'PT12H' }
            '24h' { 'PT24H' }  '48h' { 'PT48H' }
            '7d'  { 'P7D' }    default { 'PT24H' }
        }
    }

    $tok  = Get-ArmToken
    $body = @{ query = $kql; timespan = $isoTimespan }
    $resp = Invoke-ArmRestMethod -Method POST `
                -Path "$($script:LawWorkspaceResourceId)/api/query" `
                -Token $tok `
                -ApiVersion '2020-08-01' `
                -Body $body `
                -FullResponse

    # ── Parse the LAW columnar JSON response ──────────────────────────────
    # The LAW REST API returns data in a columnar format:
    #   { tables: [{ columns: [{name:"GatewayRegion",...},...], rows: [["ukwest",51,12,35,...], ...] }] }
    # We resolve column indices by name (PS5.1 uses .ColumnName, PS7 uses .name)
    # then build PSCustomObject rows for WPF DataGrid binding.
    $rows = [System.Collections.Generic.List[PSObject]]::new()

    if ($resp.tables -and $resp.tables[0].rows -and $resp.tables[0].rows.Count -gt 0) {
        # Column name resolution: PS5.1 DataTable uses .ColumnName, PS7 uses .name
        $cols = @($resp.tables[0].columns | ForEach-Object {
            $n = [string]$_.name
            if (-not $n) { $n = [string]$_.ColumnName }
            if (-not $n) { $n = [string]$_ }
            $n
        })
        $colsLower = @($cols | ForEach-Object { $_.ToLower() })

        # Find the index of each expected column in the response
        $idxRegion  = [array]::IndexOf($colsLower, 'gatewayregion')
        $idxUsers   = [array]::IndexOf($colsLower, 'users')
        $idxMedian  = [array]::IndexOf($colsLower, 'median')
        $idxP95     = [array]::IndexOf($colsLower, 'p95')
        $idxPeak    = [array]::IndexOf($colsLower, 'peak')
        $idxPeakT   = [array]::IndexOf($colsLower, 'peaktime')

        if ($idxRegion -ge 0) {
            foreach ($r in $resp.tables[0].rows) {
                # Convert peak time from UTC to local time for display
                $peakTimeStr = ''
                if ($idxPeakT -ge 0 -and $r[$idxPeakT]) {
                    try { $peakTimeStr = ([datetime]$r[$idxPeakT]).ToLocalTime().ToString('dd/MM/yyyy, HH:mm:ss.fff') } catch { $peakTimeStr = [string]$r[$idxPeakT] }
                }
                # Build row object with formatted RTT values (append "ms" suffix)
                $rows.Add([PSCustomObject]@{
                    GatewayRegion = [string]$r[$idxRegion]
                    Users         = if ($idxUsers -ge 0)  { [int]$r[$idxUsers] }    else { 0 }
                    Median        = if ($idxMedian -ge 0) { "$([int]$r[$idxMedian])ms" } else { '-' }
                    P95           = if ($idxP95 -ge 0)    { "$([int]$r[$idxP95])ms" }    else { '-' }
                    Peak          = if ($idxPeak -ge 0)   { "$([int]$r[$idxPeak]) ms" }  else { '-' }
                    PeakTime      = $peakTimeStr
                })
            }
        }
    }

    return @($rows)
}


# =============================================================================
# 3c-helper. Session History cache TTL lookup
#
# Returns how many minutes a cached result for a given time range is considered
# fresh. Shorter presets (1h-12h) change fast so they get a short TTL.
# Longer presets (7d-30d) are stable so they get a longer TTL.
# The Refresh button always bypasses the cache regardless of TTL.
# =============================================================================

function Get-SessionHistoryCacheTtlMinutes {
    param([string]$TimeRange)
    switch ($TimeRange) {
        '1h'  { 5  }  '4h'  { 5  }
        '8h'  { 5  }  '12h' { 5  }
        '24h' { 10 }  '48h' { 10 }
        '7d'  { 20 }  '30d' { 20 }
        default { 10 }
    }
}


# =============================================================================
# 3c. Session History query
#
# Queries WVDAgentHealthStatus to produce a session history line chart with two
# series:
#   Active       - users actively at the keyboard (blue line)
#   Disconnected - sessions still alive but user has disconnected (orange line)
#
# This is the same data source the Azure Portal host pool overview uses, so the
# numbers match the Active/Disconnected/Total cards on the dashboard.
#
# WHY WVDAgentHealthStatus (not WVDConnections or WVDConnectionNetworkData):
#   - WVDConnections logs connect/disconnect events only, not concurrent counts.
#   - WVDConnectionNetworkData only captures sessions with active network traffic,
#     meaning idle disconnected sessions are invisible to it.
#   - WVDAgentHealthStatus is written by each AVD agent every ~30 seconds and
#     contains exact ActiveSessions and InactiveSessions counts per host.
#     This is the same feed the Azure Portal host pool overview reads from.
#
# AGGREGATION (two-stage - full details in data/kql/session-history.kql):
#   Stage 1: per host per bin — percentile(x, 100) returns the maximum value for
#            that host within the bin. This is equivalent to max() but avoids the
#            arg_max type confusion seen in this LAW workspace version where
#            arg_max returns the timestamp value for subsequent columns instead
#            of the actual field values.
#   Stage 2: sum across all hosts — fleet-wide total for each bin.
#   This correctly handles ~60 near-identical rows per host per bin without
#   inflating counts by summing all rows.
#
# BIN SIZE:
#   Smaller bins = more data points = more accurate per-hour representation.
#   Using 1h bins for 7d/30d (not 4h/1d) ensures we capture hourly variation
#   (e.g. peak load at 09:00 vs quiet at 03:00) rather than flattening it into
#   a single daily aggregate. The 30d view produces ~720 points; fine for a line
#   chart and consistent with the 48h view which uses 30m bins (~96 points).
#
#   1h   ->  5m  bins  (~12 pts)
#   4h   -> 15m  bins  (~16 pts)
#   8h   -> 30m  bins  (~16 pts)
#   12h  -> 30m  bins  (~24 pts)
#   24h  -> 30m  bins  (~48 pts)
#   48h  -> 30m  bins  (~96 pts)
#   7d   ->  1h  bins  (~168 pts)
#   30d  ->  1h  bins  (~720 pts)
#
# DST / TIMEZONE NOTE:
#   KQL returns TimeGenerated with the local UTC offset (+00:00 in GMT, +01:00
#   in BST). Comparing these as DateTime objects in the zero-fill lookup fails
#   after the clocks change because UTC and Unspecified Kind values with
#   different offsets do not hash equally. All timestamps are normalised to
#   UTC via .ToUniversalTime() immediately after parsing, and the zero-fill
#   lookup is keyed on UTC ticks (long integers) not DateTime objects.
#
# RETURNS:
#   @{
#     Sessions     = @(@{ Time=[datetime]; Value=[double] }, ...)  # Active, blue line
#     Disconnected = @(@{ Time=[datetime]; Value=[double] }, ...)  # Disconnected, orange line
#     BinMins      = [int]   # bin size in minutes, passed through to the chart renderer
#   }
# =============================================================================

function Invoke-SessionHistoryQuery {
    param(
        [string]$TimeRange    = '48h',
        [string]$HostPool     = '',    # empty = all host pools
        [string]$CustomFrom   = '',    # ISO datetime, used when TimeRange == 'custom'
        [string]$CustomTo     = ''     # ISO datetime, used when TimeRange == 'custom'
    )

    # ── Bin size selection ────────────────────────────────────────────────────
    # $binSize  : KQL bin() expression (e.g. '1h') — substituted into the query
    # $binMins  : same value in minutes — used by the chart renderer for zero-fill
    #
    # For custom date ranges the bin size is derived from the span so the chart
    # stays readable regardless of how wide the window is:
    #   <= 24h  -> 30m bins (same as the built-in 24h preset)
    #   > 24h   ->  1h bins (covers days/weeks without becoming too coarse)
    #
    # For fixed presets, 1h bins are used for 7d and 30d. This is intentional:
    # coarser bins (4h/1d) were tried but they caused Active and Disconnected to
    # track each other too closely because both series hit their daily peak at the
    # same time. Hourly bins show the genuine intra-day variation.
    if ($TimeRange -eq 'custom' -and $CustomFrom -and $CustomTo) {
        $spanHours = ([datetime]$CustomTo - [datetime]$CustomFrom).TotalHours
        if ($spanHours -le 24) { $binSize = '30m'; $binMins = 30 }
        else                   { $binSize = '1h';  $binMins = 60 }
    } else {
        $binSize = switch ($TimeRange) {
            '1h'  { '5m'  }  '4h'  { '15m' }
            '8h'  { '30m' }  '12h' { '30m' }
            '24h' { '30m' }  '48h' { '30m' }
            '7d'  { '1h'  }  '30d' { '1h'  }
            default { '30m' }
        }
        $binMins = switch ($TimeRange) {
            '1h'  { 5  }  '4h'  { 15 }
            '8h'  { 30 }  '12h' { 30 }
            '24h' { 30 }  '48h' { 30 }
            '7d'  { 60 }  '30d' { 60 }
            default { 30 }
        }
    }
    # Store bin size so the chart renderer knows the expected step interval for zero-fill
    $script:_monSessionHistoryBinMins = $binMins

    # ── Host pool filter ──────────────────────────────────────────────────────
    # WVDAgentHealthStatus._ResourceId is the full ARM path of the host pool, e.g.:
    #   /subscriptions/<id>/resourceGroups/<rg>/providers/.../hostPools/<name>/sessionHosts/<vm>
    # Split on '/' and take index 8 (zero-based) to get the host pool name.
    # Comparison is lower-cased on both sides to handle any case differences.
    # Single quotes in the host pool name are escaped for KQL string safety.
    $hpFilter = ''
    if ($HostPool -and $HostPool -ne 'All Host Pools') {
        $escapedHp = $HostPool.Replace("'", "''").ToLower()
        $hpFilter = "| where tolower(tostring(split(_ResourceId, '/')[8])) == '$escapedHp'"
    }

    # ── Cache lookup ─────────────────────────────────────────────────────────
    # Check whether a fresh result for this exact combination of parameters is
    # already in the in-memory cache. If the entry exists and is younger than
    # the TTL for the selected time range, return it immediately without hitting
    # Log Analytics. The Refresh button removes the entry before calling this
    # function so it always bypasses the cache on an explicit user refresh.
    $cacheKey = "$TimeRange|$HostPool|$CustomFrom|$CustomTo"
    $ttlMins  = Get-SessionHistoryCacheTtlMinutes -TimeRange $TimeRange
    if ($script:_monShCache -and $script:_monShCache.ContainsKey($cacheKey)) {
        $entry   = $script:_monShCache[$cacheKey]
        $ageMins = ([datetime]::UtcNow - $entry.FetchedAt).TotalMinutes
        if ($ageMins -lt $ttlMins) {
            Write-Log "[SessionHistory] Cache hit '$cacheKey' (age $([math]::Round($ageMins,1))m, TTL $ttlMins m)"
            return $entry.Data
        }
        Write-Log "[SessionHistory] Cache expired '$cacheKey' (age $([math]::Round($ageMins,1))m, TTL $ttlMins m) - re-querying"
    }

    # ── KQL placeholder substitution ─────────────────────────────────────────
    # The .kql file contains named placeholders ({{DisplayStart}}, {{DisplayEnd}},
    # {{BinSize}}, {{HostPoolFilter}}) that are replaced here before sending.
    # For custom ranges we pass explicit datetime() literals. For relative ranges
    # we use ago() / now() so KQL evaluates them at query execution time.
    # The REST body timespan is always 'P30D' (30 days) — it acts as a safety
    # cap; the actual window is controlled by the where clause in the KQL.
    if ($TimeRange -eq 'custom' -and $CustomFrom -and $CustomTo) {
        $displayStart = "datetime($CustomFrom)"
        $displayEnd   = "datetime($CustomTo)"
    } else {
        $displayStart = "ago($TimeRange)"
        $displayEnd   = "now()"
    }

    $kql = $script:_kqlSessionHistory `
        -replace '\{\{DisplayStart\}\}',   $displayStart `
        -replace '\{\{DisplayEnd\}\}',     $displayEnd `
        -replace '\{\{BinSize\}\}',        $binSize `
        -replace '\{\{HostPoolFilter\}\}', $hpFilter

    Write-Log "[SessionHistory] Querying LAW: range=$TimeRange binSize=$binSize hpFilter='$hpFilter' displayStart=$displayStart displayEnd=$displayEnd"

    # ── LAW REST API call ─────────────────────────────────────────────────────
    # POST to the Log Analytics workspace query endpoint. Response is columnar:
    #   { tables: [{ columns: [{name, type}, ...], rows: [[val, val, ...], ...] }] }
    # Column indices are resolved by name so order changes in LAW don't break parsing.
    $tok  = Get-ArmToken
    $body = @{ query = $kql; timespan = 'P30D' }
    $resp = Invoke-ArmRestMethod -Method POST `
                -Path "$($script:LawWorkspaceResourceId)/api/query" `
                -Token $tok `
                -ApiVersion '2020-08-01' `
                -Body $body `
                -FullResponse

    $activePts       = [System.Collections.Generic.List[PSCustomObject]]::new()
    $disconnectedPts = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($resp.tables -and $resp.tables[0].rows -and $resp.tables[0].rows.Count -gt 0) {
        $rowCount = $resp.tables[0].rows.Count
        Write-Log "[SessionHistory] LAW returned $rowCount rows"

        # Column name resolution: PS5.1 DataTable objects expose .ColumnName,
        # PS7 / JSON-deserialised objects expose .name. Try both and fall back
        # to casting the whole object as a string if neither property exists.
        $cols = @($resp.tables[0].columns | ForEach-Object {
            $n = [string]$_.name
            if (-not $n) { $n = [string]$_.ColumnName }
            if (-not $n) { $n = [string]$_ }
            $n.ToLower()
        })
        $iTime = [array]::IndexOf($cols, 'timegenerated')
        $iAct  = [array]::IndexOf($cols, 'active')
        $iDisc = [array]::IndexOf($cols, 'disconnected')
        Write-Log "[SessionHistory] Column indices: timegenerated=$iTime active=$iAct disconnected=$iDisc"

        if ($iTime -ge 0 -and $iAct -ge 0 -and $iDisc -ge 0) {
            foreach ($r in $resp.tables[0].rows) {
                # Normalise to UTC immediately after parsing.
                # KQL returns TimeGenerated with the local UTC offset embedded in the
                # string: +00:00 in GMT (winter) but +01:00 in BST (summer). After the
                # UK clocks change on 30/03 the offset switches, so two dates that are
                # actually consecutive UTC hours have different string representations.
                # Without .ToUniversalTime() the zero-fill lookup (keyed on ticks) fails
                # for all bins after the DST transition, producing a flat line at zero.
                $t = ([datetime]$r[$iTime]).ToUniversalTime()
                $activePts.Add([PSCustomObject]@{       Time = $t; Value = [double]$r[$iAct]  })
                $disconnectedPts.Add([PSCustomObject]@{ Time = $t; Value = [double]$r[$iDisc] })
            }
        } else {
            Write-Log "[SessionHistory] ERROR - expected columns not found. Available: $($cols -join ', ')"
        }
    } else {
        Write-Log "[SessionHistory] LAW returned no rows"
    }

    # ── Sort ascending for the chart ──────────────────────────────────────────
    # The KQL query uses 'order by TimeGenerated desc' so that within the LAW row
    # limit (default 10,000) we always get the most recent bins rather than the
    # oldest. The chart renderer expects data sorted oldest-first (left to right),
    # so we reverse here after parsing.
    $activePts       = [System.Collections.Generic.List[PSCustomObject]]($activePts       | Sort-Object Time)
    $disconnectedPts = [System.Collections.Generic.List[PSCustomObject]]($disconnectedPts | Sort-Object Time)

    Write-Log "[SessionHistory] Parsed $($activePts.Count) bins. binMins=$binMins"
    if ($activePts.Count -gt 0) {
        $first = $activePts[0]
        $last  = $activePts[$activePts.Count - 1]
        Write-Log "[SessionHistory] First bin: $($first.Time.ToString('o')) Active=$($first.Value)"
        Write-Log "[SessionHistory] Last  bin: $($last.Time.ToString('o'))  Active=$($last.Value)"
    }

    # ── Cache store ───────────────────────────────────────────────────────────
    # Store the result so repeat views of the same range don't re-query LAW.
    # The cache key covers all four query parameters so different ranges/host
    # pools are cached independently. TTL is enforced on the next read.
    $result = @{ Sessions = @($activePts); Disconnected = @($disconnectedPts); BinMins = $binMins }
    if ($null -ne $script:_monShCache) {
        $script:_monShCache[$cacheKey] = @{ Data = $result; FetchedAt = [datetime]::UtcNow }
        Write-Log "[SessionHistory] Cached '$cacheKey' ($($activePts.Count) bins, TTL $ttlMins m)"
    }
    return $result
}


# =============================================================================
# 4. Bar chart renderer
#
# Draws a grouped bar chart on a WPF Canvas using pure WPF drawing primitives
# (Rectangle, Line, TextBlock). No external charting libraries are used.
#
# VISUAL LAYOUT:
#   - Each logon stage gets a "slot" (equal-width column) across the X-axis
#   - Within each slot, two vertical bars are drawn side-by-side:
#       Left bar  = P95 (magenta #E91E63) — worst-case 95th percentile
#       Right bar = P50 (blue-grey #B0BEC5) — typical median experience
#   - Value labels appear above each bar showing the duration in seconds
#   - Stage names appear below the X-axis, centred under their bar pair
#   - Y-axis shows duration in seconds with auto-scaled nice numbers
#   - Horizontal dashed gridlines at 25%, 50%, 75% of Y-max
#   - P95 total logon time summary in the top-right corner
#
# COLOUR SCHEME (matches AVD Insights):
#   P95 = #E91E63 (magenta/pink) — the "worst case" metric
#   P50 = #B0BEC5 (light blue-grey) — the "typical" metric
#
# COORDINATE SYSTEM:
#   Left margin (55px) = Y-axis labels
#   Bottom margin (60px) = stage name labels (with text wrapping)
#   Top margin (20px) = padding + summary text
#   Right margin (20px) = padding
#   Chart area = total canvas minus margins
#   Y-axis: 0 at bottom to yMax at top (auto-scaled)
#   X-axis: stages evenly distributed across chart width
# =============================================================================

function Update-WinlogonChart {
    param(
        [System.Windows.Controls.Canvas]$Canvas,
        [object[]]$StageData    # Array of @{ Stage; P50; P95; Samples }
    )

    # Clear all previous chart elements from the canvas
    $Canvas.Children.Clear()

    # Get the actual rendered size of the canvas (set by WPF layout engine)
    $w = $Canvas.ActualWidth
    $h = $Canvas.ActualHeight
    if ($w -lt 200 -or $h -lt 150) { return }   # too small to draw anything meaningful

    # Chart margins define the space reserved for labels and padding around the chart area
    $ml = 55; $mr = 20; $mt = 36; $mb = 60
    $cw = $w - $ml - $mr    # chart area width
    $ch = $h - $mt - $mb    # chart area height

    $brushConv = New-Object System.Windows.Media.BrushConverter

    # ── Helper: add a Rectangle bar to the Canvas ──────────────────────────
    $addBar = {
        param($x, $y, $barW, $barH, $color)
        if ($barH -le 0) { return }
        $rect = New-Object System.Windows.Shapes.Rectangle
        $rect.Width  = $barW
        $rect.Height = $barH
        $rect.Fill   = $brushConv.ConvertFromString($color)
        $rect.RadiusX = 2; $rect.RadiusY = 2
        [System.Windows.Controls.Canvas]::SetLeft($rect, $x)
        [System.Windows.Controls.Canvas]::SetTop($rect, $y)
        [void]$Canvas.Children.Add($rect)
    }

    # ── Helper: add a Line to the Canvas ───────────────────────────────────
    $addLine = {
        param($x1, $y1, $x2, $y2, $color, $thickness, $dashArray)
        $ln = New-Object System.Windows.Shapes.Line
        $ln.X1 = $x1; $ln.Y1 = $y1; $ln.X2 = $x2; $ln.Y2 = $y2
        $ln.Stroke = $brushConv.ConvertFromString($color)
        $ln.StrokeThickness = $thickness
        if ($dashArray) {
            $dc = New-Object System.Windows.Media.DoubleCollection
            foreach ($d in $dashArray) { $dc.Add([double]$d) }
            $ln.StrokeDashArray = $dc
        }
        [void]$Canvas.Children.Add($ln)
    }

    # ── Helper: add a TextBlock to the Canvas ──────────────────────────────
    $addText = {
        param($text, $x, $y, $fontSize, $color, $hAlign)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $tb.FontSize = if ($fontSize) { $fontSize } else { 10 }
        $tb.Foreground = $brushConv.ConvertFromString($(if ($color) { $color } else { '#666' }))
        [System.Windows.Controls.Canvas]::SetLeft($tb, $x)
        [System.Windows.Controls.Canvas]::SetTop($tb, $y)
        if ($hAlign -eq 'Right') {
            $tb.TextAlignment = [System.Windows.TextAlignment]::Right
            $tb.Width = $x
            [System.Windows.Controls.Canvas]::SetLeft($tb, 0)
        }
        if ($hAlign -eq 'Center') {
            $tb.TextAlignment = [System.Windows.TextAlignment]::Center
        }
        [void]$Canvas.Children.Add($tb)
    }

    # If no data, show a message
    if (-not $StageData -or $StageData.Count -eq 0) {
        & $addText 'No winlogon stage data available. Click Refresh to query.' ($w / 2 - 150) ($h / 2 - 10) 13 '#999' $null
        return
    }

    # ── Chart background ───────────────────────────────────────────────────
    $bg = New-Object System.Windows.Shapes.Rectangle
    $bg.Width = $cw; $bg.Height = $ch
    $bg.Fill = $brushConv.ConvertFromString('#FAFAFA')
    [System.Windows.Controls.Canvas]::SetLeft($bg, $ml)
    [System.Windows.Controls.Canvas]::SetTop($bg, $mt)
    [void]$Canvas.Children.Add($bg)

    # ── Determine Y-axis scale ─────────────────────────────────────────────
    # Find the tallest bar value (could be P50 or P95) and round up to a "nice"
    # number for clean axis labels. E.g. if max is 27s, yMax becomes 30s.
    $maxVal = ($StageData | ForEach-Object { [math]::Max($_.P50, $_.P95) } | Measure-Object -Maximum).Maximum
    $maxVal = [math]::Max(1, $maxVal)
    # Round up to the nearest nice number based on magnitude
    $yMax = if ($maxVal -le 5) { [math]::Ceiling($maxVal) }
            elseif ($maxVal -le 10) { [math]::Ceiling($maxVal / 2) * 2 }
            elseif ($maxVal -le 30) { [math]::Ceiling($maxVal / 5) * 5 }
            elseif ($maxVal -le 60) { [math]::Ceiling($maxVal / 10) * 10 }
            else { [math]::Ceiling($maxVal / 20) * 20 }

    # ── Horizontal gridlines ───────────────────────────────────────────────
    foreach ($frac in @(0.25, 0.50, 0.75)) {
        $y = $mt + $ch * (1 - $frac)
        & $addLine $ml $y ($ml + $cw) $y '#E0E0E0' 1 @(4, 4)
    }

    # ── Y-axis labels (duration in seconds) ────────────────────────────────
    foreach ($frac in @(0, 0.25, 0.50, 0.75, 1.0)) {
        $y = $mt + $ch * (1 - $frac) - 7
        $label = [math]::Round($yMax * $frac, 0).ToString() + 's'
        & $addText $label ($ml - 5) $y 10 '#666' 'Right'
    }

    # ── Axes ───────────────────────────────────────────────────────────────
    & $addLine $ml $mt $ml ($mt + $ch) '#999' 1 $null              # Y-axis
    & $addLine $ml ($mt + $ch) ($ml + $cw) ($mt + $ch) '#999' 1 $null  # X-axis

    # ── Bar layout calculations ────────────────────────────────────────────
    # Each stage gets a "slot" with two bars (P95, P50) and padding between slots
    $stageCount = $StageData.Count
    $slotWidth  = $cw / $stageCount                # total width per stage slot
    $barWidth   = [math]::Min(40, ($slotWidth - 20) / 2)  # width of each individual bar
    $gapBetween = [math]::Max(4, $barWidth * 0.15)         # gap between P95 and P50 bars
    $pairWidth  = $barWidth * 2 + $gapBetween              # total width of the bar pair
    $p95Color   = '#E91E63'   # Magenta (matches AVD Insights P95 colour)
    $p50Color   = '#B0BEC5'   # Light blue-grey (matches AVD Insights P50 colour)

    # ── Draw bars and labels for each stage ────────────────────────────────
    for ($i = 0; $i -lt $stageCount; $i++) {
        $stage = $StageData[$i]
        $slotX = $ml + $i * $slotWidth              # left edge of this stage's slot
        $pairX = $slotX + ($slotWidth - $pairWidth) / 2  # centre the pair within the slot

        # P95 bar (left bar in the pair)
        # Minimum bar height of 3px so even tiny values (e.g. Shell at 0.1s) are visible
        $p95Height = [math]::Max(3, ($stage.P95 / $yMax) * $ch)
        $p95Y      = $mt + $ch - $p95Height
        & $addBar $pairX $p95Y $barWidth $p95Height $p95Color

        # P95 value label always shown above the bar
        & $addText "$($stage.P95)s" $pairX ($p95Y - 16) 10 '#E91E63' $null

        # P50 bar (right bar in the pair)
        $p50X      = $pairX + $barWidth + $gapBetween
        $p50Height = [math]::Max(3, ($stage.P50 / $yMax) * $ch)
        $p50Y      = $mt + $ch - $p50Height
        & $addBar $p50X $p50Y $barWidth $p50Height $p50Color

        # P50 value label always shown above the bar
        & $addText "$($stage.P50)s" $p50X ($p50Y - 16) 10 '#78909C' $null

        # Stage name label below X-axis (centred under the bar pair)
        # Each label has a tooltip explaining what the stage represents
        # Tooltip descriptions sourced from Microsoft documentation:
        # https://learn.microsoft.com/en-us/azure/virtual-desktop/insights-glossary
        # (Section: "Time to connect" > "Logon" sub-stages)
        $stageTooltips = @{
            'Group policy' = "The time it takes to apply Group Policy Objects to new sessions.`nA spike in this area is a sign that you have too many group policies,`nthe policies take too long to apply, or the session host is`nexperiencing resource issues. Make sure the domain controller is as`nclose to the session hosts as possible.`n`nSource: Microsoft AVD Insights Glossary"
            'FSLogix'      = "The time it takes to launch FSLogix (frxsvc) in new sessions.`nA long launch time may indicate issues with the shares used to host`nthe FSLogix user profiles. Make sure the shares are collocated with`nthe session hosts and appropriately scaled for the average number`nof users signing in. Large profile sizes can also slow down launch times.`n`nSource: Microsoft AVD Insights Glossary"
            'User Auth.'   = "The time it takes to authenticate the user's credentials during`nthe logon process. This is part of the overall logon stage between`nwhen a connection to a host is established and when the shell`nstarts to load.`n`nSource: Microsoft AVD Insights Glossary"
            'Shell'        = "The time it takes to launch the shell (usually explorer.exe).`nThis is the 'Shell Start' phase of the logon process. Delays in`nthe subsequent 'Shell Start to Shell Ready' phase can be caused`nby session host overload (high CPU, memory, or disk activity)`nor configuration issues.`n`nSource: Microsoft AVD Insights Glossary"
            'Others'       = "Aggregate of all other logon sub-tasks not individually categorised.`nThe logon stage includes several processes that can contribute to`nhigh connection times. This catch-all covers miscellaneous tasks`nthat occur between connection establishment and shell start.`n`nSource: Microsoft AVD Insights Glossary"
        }
        $labelX = $slotX + ($slotWidth / 2) - 25
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $stage.Stage
        $tb.FontSize = 11
        $tb.Foreground = $brushConv.ConvertFromString('#555')
        $tb.TextAlignment = [System.Windows.TextAlignment]::Center
        $tb.Width = 80
        $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
        # Add tooltip with stage explanation
        $tipText = $stageTooltips[$stage.Stage]
        if ($tipText) { $tb.ToolTip = $tipText }
        [System.Windows.Controls.Canvas]::SetLeft($tb, $labelX - 15)
        [System.Windows.Controls.Canvas]::SetTop($tb, $mt + $ch + 6)
        [void]$Canvas.Children.Add($tb)
    }

    # ── P95 total logon time summary (top-right corner, outside chart area) ──
    $totalP95 = [math]::Round(($StageData | ForEach-Object { $_.P95 } | Measure-Object -Sum).Sum, 1)
    $totalP50 = [math]::Round(($StageData | ForEach-Object { $_.P50 } | Measure-Object -Sum).Sum, 1)
    & $addText "P50: ${totalP50}s  |  P95: ${totalP95}s" ($w - 200) 2 12 '#E91E63' $null
}


# =============================================================================
# 5. Initialize-MonitoringTab
#
# Called once after $window has been loaded from XAML (from avd-live-dashboard.ps1
# line ~2094). Finds all named XAML controls and wires up event handlers.
#
# CONTROLS WIRED:
#   MonitoringPortalButton  - opens AVD Insights in Azure Portal
#   MonWinlogonCanvas       - WPF Canvas for the bar chart
#   MonWinlogonTimeRange    - ComboBox for time range selection (24h/48h/7d)
#   MonWinlogonHostPool     - ComboBox for host pool filter (populated on refresh)
#   MonWinlogonRefreshBtn   - single Refresh button that queries BOTH datasets
#   MonWinlogonStatus       - status text for winlogon stages
#   MonRttGrid              - DataGrid for RTT by Gateway Region
#   MonRttStatus            - status text for RTT data
#
# REFRESH FLOW (single button triggers both queries):
#   1. User clicks Refresh
#   2. Read selected time range from ComboBox
#   3. Read selected host pool from ComboBox (or "All Host Pools")
#   4. Query LAW for host pool list (refreshes dropdown on each click)
#   5. Query LAW for winlogon stage data -> render bar chart
#   6. Query LAW for RTT by gateway region -> populate DataGrid
#   7. Update both status bars with result counts
#
# NO AUTO-REFRESH: This tab uses manual refresh only. No DispatcherTimer,
# no background runspace, no periodic polling.
#
# LAW DEPENDENCY: If $script:LawWorkspaceResourceId is not configured,
# the Refresh button is disabled and a message is shown.
# =============================================================================

function Initialize-MonitoringTab {
    param(
        [Parameter(Mandatory)][System.Windows.Window]$Window
    )

    # ── AVD Insights portal button ─────────────────────────────────────────
    $script:MonitoringPortalButton = $Window.FindName('MonitoringPortalButton')
    $script:MonitoringPortalButton.Add_Click({
        Start-Process 'https://portal.azure.com/#view/Microsoft_Azure_WVD/WvdManagerMenuBlade/~/insights'
    })

    # ── Winlogon Stages chart controls ─────────────────────────────────────
    $script:monWinlogonCanvas   = $Window.FindName('MonWinlogonCanvas')
    $script:monWinlogonTimeRange = $Window.FindName('MonWinlogonTimeRange')
    $script:monWinlogonHostPool  = $Window.FindName('MonWinlogonHostPool')
    $script:monWinlogonRefreshBtn = $Window.FindName('MonWinlogonRefreshBtn')
    $script:monWinlogonStatus    = $Window.FindName('MonWinlogonStatus')

    # ── Session History chart controls ────────────────────────────────────
    $script:monSessionHistoryCanvas    = $Window.FindName('MonSessionHistoryCanvas')
    $script:monSessionHistoryStatus    = $Window.FindName('MonSessionHistoryStatus')
    $script:_monSessionHistoryData     = $null
    $script:_monSessionHistoryBinMins  = 60  # default 1h bins; updated by Invoke-SessionHistoryQuery
    $script:_monSessionHistoryFilled   = $null
    $script:_monShCache                = @{}  # cache: "$TimeRange|$HostPool|$CustomFrom|$CustomTo" -> @{ Data; FetchedAt }

    # Custom range display label and stored values (set by popup)
    $script:monRangeDisplay   = $Window.FindName('MonRangeDisplay')
    $script:_monCustomFrom    = [DateTime]::Today.AddDays(-7).ToString('dd/MM/yyyy 00:00')
    $script:_monCustomTo      = [DateTime]::Today.ToString('dd/MM/yyyy 23:59')
    $script:_monMainWindow    = $Window

    # ── Session History hover elements (created once, re-added after each redraw) ──
    $brushConvSh = New-Object System.Windows.Media.BrushConverter

    $script:_monShCrosshair = New-Object System.Windows.Shapes.Line
    $script:_monShCrosshair.Stroke = $brushConvSh.ConvertFromString('#888')
    $script:_monShCrosshair.StrokeThickness = 1
    $shDash = New-Object System.Windows.Media.DoubleCollection
    $shDash.Add(4); $shDash.Add(2)
    $script:_monShCrosshair.StrokeDashArray = $shDash
    $script:_monShCrosshair.Visibility = [System.Windows.Visibility]::Collapsed
    $script:_monShCrosshair.IsHitTestVisible = $false

    $script:_monShDot = New-Object System.Windows.Shapes.Ellipse
    $script:_monShDot.Width = 8; $script:_monShDot.Height = 8
    $script:_monShDot.Fill = $brushConvSh.ConvertFromString('#1976D2')
    $script:_monShDot.Stroke = $brushConvSh.ConvertFromString('White')
    $script:_monShDot.StrokeThickness = 1.5
    $script:_monShDot.Visibility = [System.Windows.Visibility]::Collapsed
    $script:_monShDot.IsHitTestVisible = $false

    $script:_monShTtText = New-Object System.Windows.Controls.TextBlock
    $script:_monShTtText.Foreground = $brushConvSh.ConvertFromString('White')
    $script:_monShTtText.FontSize = 11
    $script:_monShTooltip = New-Object System.Windows.Controls.Border
    $script:_monShTooltip.Background   = $brushConvSh.ConvertFromString('#DD1A1A2E')
    $script:_monShTooltip.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $script:_monShTooltip.Padding      = [System.Windows.Thickness]::new(8, 4, 8, 4)
    $script:_monShTooltip.Visibility   = [System.Windows.Visibility]::Collapsed
    $script:_monShTooltip.IsHitTestVisible = $false
    $script:_monShTooltip.Child = $script:_monShTtText

    # Wire MouseMove once — reads layout info from Canvas.Tag updated by each redraw
    $script:monSessionHistoryCanvas.Add_MouseMove({
        param($s, $e)
        $info = $s.Tag
        if (-not $info -or -not $info.SessionsPoints -or $info.SessionsPoints.Count -lt 2) { return }

        $pos  = $e.GetPosition($s)
        $cw2  = $s.ActualWidth  - $info.ML - $info.MR
        $ch2  = $s.ActualHeight - $info.MT - $info.MB
        $xRel = $pos.X - $info.ML

        if ($xRel -lt 0 -or $xRel -gt $cw2) {
            $script:_monShCrosshair.Visibility = [System.Windows.Visibility]::Collapsed
            $script:_monShDot.Visibility       = [System.Windows.Visibility]::Collapsed
            $script:_monShTooltip.Visibility   = [System.Windows.Visibility]::Collapsed
            return
        }

        $tSpanSec = ($info.TMax - $info.TMin).TotalSeconds
        if ($tSpanSec -le 0) { return }
        $hoverT = $info.TMin.AddSeconds(($xRel / $cw2) * $tSpanSec)

        # Find nearest Sessions point
        $nearest  = $null
        $bestDiff = [double]::MaxValue
        foreach ($pt in $info.SessionsPoints) {
            $diff = [math]::Abs(($pt.Time - $hoverT).TotalSeconds)
            if ($diff -lt $bestDiff) { $bestDiff = $diff; $nearest = $pt }
        }
        if (-not $nearest) { return }

        # Find matching Disconnected point at the same bin time
        $nearestDisc = $null
        if ($info.DisconnectedPoints -and $info.DisconnectedPoints.Count -gt 0) {
            $bestDiscDiff = [double]::MaxValue
            foreach ($pt in $info.DisconnectedPoints) {
                $diff = [math]::Abs(($pt.Time - $nearest.Time).TotalSeconds)
                if ($diff -lt $bestDiscDiff) { $bestDiscDiff = $diff; $nearestDisc = $pt }
            }
        }

        $ptXFrac = ($nearest.Time - $info.TMin).TotalSeconds / $tSpanSec
        $px = $info.ML + $ptXFrac * $cw2
        $py = $info.MT + $ch2 - ($nearest.Value / $info.YMax) * $ch2

        $script:_monShCrosshair.X1 = $px; $script:_monShCrosshair.Y1 = $info.MT
        $script:_monShCrosshair.X2 = $px; $script:_monShCrosshair.Y2 = $info.MT + $ch2
        $script:_monShCrosshair.Visibility = [System.Windows.Visibility]::Visible

        [System.Windows.Controls.Canvas]::SetLeft($script:_monShDot, $px - 4)
        [System.Windows.Controls.Canvas]::SetTop($script:_monShDot,  $py - 4)
        $script:_monShDot.Visibility = [System.Windows.Visibility]::Visible

        $tLocal  = $nearest.Time.ToLocalTime()
        $timeFmt = if ($tSpanSec -gt 86400) { $tLocal.ToString('dd/MM HH:mm') } else { $tLocal.ToString('HH:mm') }
        $discVal = if ($nearestDisc) { [int]$nearestDisc.Value } else { 0 }
        $script:_monShTtText.Text = "$timeFmt  |  Active: $([int]$nearest.Value)  |  Disconnected: $discVal"

        $s.UpdateLayout()
        $ttW = $script:_monShTooltip.ActualWidth
        $ttH = $script:_monShTooltip.ActualHeight
        $ttX = $px - ($ttW / 2)
        if ($ttX -lt $info.ML)                            { $ttX = $info.ML }
        if ($ttX + $ttW -gt $s.ActualWidth - $info.MR)   { $ttX = $s.ActualWidth - $info.MR - $ttW }
        $ttY = $py - $ttH - 10
        if ($ttY -lt 2) { $ttY = $py + 12 }

        [System.Windows.Controls.Canvas]::SetLeft($script:_monShTooltip, $ttX)
        [System.Windows.Controls.Canvas]::SetTop($script:_monShTooltip,  $ttY)
        $script:_monShTooltip.Visibility = [System.Windows.Visibility]::Visible
    })

    $script:monSessionHistoryCanvas.Add_MouseLeave({
        $script:_monShCrosshair.Visibility = [System.Windows.Visibility]::Collapsed
        $script:_monShDot.Visibility       = [System.Windows.Visibility]::Collapsed
        $script:_monShTooltip.Visibility   = [System.Windows.Visibility]::Collapsed
    })

    # Resize handler: redraw session history chart from cached data
    $script:monSessionHistoryCanvas.Add_SizeChanged({
        if ($script:_monSessionHistoryData) {
            Update-SessionHistoryChart -Canvas $script:monSessionHistoryCanvas `
                -SessionsData      $script:_monSessionHistoryData.Sessions `
                -DisconnectedData  $script:_monSessionHistoryData.Disconnected `
                -BinMinutes        $script:_monSessionHistoryBinMins
        }
    })

    # Disable chart controls if LAW is not configured
    if (-not $script:LawWorkspaceResourceId) {
        $script:monWinlogonRefreshBtn.IsEnabled = $false
        $script:monWinlogonStatus.Text = 'Log Analytics Workspace not configured - Winlogon Stages chart is unavailable.'
        return
    }

    # ── Helper: extract current time range selections from UI ─────────────
    # Returns @{ Range; CustomFrom; CustomTo; HpFilter }
    # Used by both the Refresh button and the host pool change timer.
    $script:_monGetRangeParams = {
        $selectedItem = $script:monWinlogonTimeRange.SelectedItem
        $rangeTag     = if ($selectedItem) { [string]$selectedItem.Tag } else { '48h' }
        $hpFilter     = ''
        $hpSelected   = $script:monWinlogonHostPool.SelectedItem
        if ($hpSelected -and $hpSelected.Content -ne 'All Host Pools') {
            $hpFilter = [string]$hpSelected.Content
        }
        $customFrom = ''; $customTo = ''
        if ($rangeTag -eq 'custom') {
            $formats = [string[]]@('dd/MM/yyyy HH:mm', 'dd/MM/yyyy H:mm', 'dd/MM/yyyy', 'yyyy-MM-dd HH:mm', 'yyyy-MM-dd')
            $dtFrom = [datetime]::MinValue; $dtTo = [datetime]::MinValue
            if ($script:_monCustomFrom) {
                [void][datetime]::TryParseExact($script:_monCustomFrom.Trim(), $formats,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None, [ref]$dtFrom)
            }
            if ($script:_monCustomTo) {
                [void][datetime]::TryParseExact($script:_monCustomTo.Trim(), $formats,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None, [ref]$dtTo)
            }
            if ($dtFrom -ne [datetime]::MinValue) { $customFrom = $dtFrom.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
            if ($dtTo   -ne [datetime]::MinValue) { $customTo   = $dtTo.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        }
        @{ Range = $rangeTag; CustomFrom = $customFrom; CustomTo = $customTo; HpFilter = $hpFilter }
    }

    # ── Refresh button click handler ───────────────────────────────────────
    # Runs the three LAW queries sequentially on the calling thread, then
    # renders results. Sequential is required because the query functions
    # are defined in this script scope and are not available in fresh runspaces.
    $script:monWinlogonRefreshBtn.Add_Click({
        if ($script:_monRefreshing) { return }
        $script:_monRefreshing = $true

        $script:monWinlogonStatus.Text       = 'Querying Log Analytics...'
        $script:monSessionHistoryStatus.Text = 'Querying session history...'
        $script:monWinlogonCanvas.Children.Clear()
        $script:monWinlogonCanvas.UpdateLayout()

        $params = & $script:_monGetRangeParams

        # Validate custom range before querying
        if ($params.Range -eq 'custom') {
            if (-not $params.CustomFrom -or -not $params.CustomTo) {
                $script:monWinlogonStatus.Text = 'Select a From and To date for custom range.'
                $script:_monRefreshing = $false; return
            }
            if ([datetime]$params.CustomFrom -gt [datetime]$params.CustomTo) {
                $script:monWinlogonStatus.Text = '"From" date must be before "To" date.'
                $script:_monRefreshing = $false; return
            }
        }

        try {
            # ── Step 1: Refresh host pool dropdown ─────────────────────────────
            try {
                $pools = Invoke-WinlogonHostPoolsQuery
                $hpSelected = $script:monWinlogonHostPool.SelectedItem
                $currentSelection = if ($hpSelected) { [string]$hpSelected.Content } else { 'All Host Pools' }
                $script:monWinlogonHostPool.Items.Clear()
                $allItem = New-Object System.Windows.Controls.ComboBoxItem
                $allItem.Content = 'All Host Pools'
                [void]$script:monWinlogonHostPool.Items.Add($allItem)
                $script:monWinlogonHostPool.SelectedIndex = 0
                foreach ($p in $pools) {
                    $item = New-Object System.Windows.Controls.ComboBoxItem
                    $item.Content = $p
                    [void]$script:monWinlogonHostPool.Items.Add($item)
                    if ($p -eq $currentSelection) { $script:monWinlogonHostPool.SelectedItem = $item }
                }
            } catch {}

            # ── Step 2: Run all three queries sequentially ─────────────────────
            $range      = $params.Range
            $customFrom = $params.CustomFrom
            $customTo   = $params.CustomTo
            $hpFilter   = $params.HpFilter

            $data = @()
            try {
                $data = @(Invoke-WinlogonStagesQuery -TimeRange $range -HostPoolFilter $hpFilter -CustomFrom $customFrom -CustomTo $customTo)
            } catch { $script:monWinlogonStatus.Text = "Winlogon query failed: $_" }

            $rttDataArr = @()
            try {
                $rttDataArr = @(Invoke-RttByGatewayQuery -TimeRange $range -CustomFrom $customFrom -CustomTo $customTo)
            } catch { $script:monRttStatus.Text = "RTT query failed: $_" }

            $shData = $null
            try {
                # Invalidate the cache for this specific key so the Refresh button
                # always fetches fresh data from LAW, ignoring any cached result.
                $shCacheKey = "$range|$hpFilter|$customFrom|$customTo"
                $script:_monShCache.Remove($shCacheKey)
                Write-Log "[SessionHistory] Manual refresh - cache invalidated for '$shCacheKey'"
                $shData = Invoke-SessionHistoryQuery -TimeRange $range -HostPool $hpFilter -CustomFrom $customFrom -CustomTo $customTo
            } catch { $script:monSessionHistoryStatus.Text = "Session History query failed: $_" }

            # ── Step 3: Render Winlogon chart ──────────────────────────────────
            $script:_monWinlogonData = $data
            Update-WinlogonChart -Canvas $script:monWinlogonCanvas -StageData $data
            if ($data.Count -gt 0) {
                $totalSamples = ($data | ForEach-Object { $_.Samples } | Measure-Object -Sum).Sum
                $totalP95     = [math]::Round(($data | ForEach-Object { $_.P95 } | Measure-Object -Sum).Sum, 1)
                $script:monWinlogonStatus.Text = "$($data.Count) stage(s), $totalSamples sample(s) - P95 total logon time: ${totalP95}s"
            } else {
                if (-not $script:monWinlogonStatus.Text.StartsWith('Winlogon query failed')) {
                    $script:monWinlogonStatus.Text = 'No winlogon stage data found for the selected time range.'
                }
            }

            # ── Step 4: Render RTT grid ────────────────────────────────────────
            $script:monRttGrid.ItemsSource = $rttDataArr
            if (-not $script:monRttStatus.Text.StartsWith('RTT query failed')) {
                $regionCount = $rttDataArr.Count
                $totalUsers  = ($rttDataArr | ForEach-Object { $_.Users } | Measure-Object -Sum).Sum
                $script:monRttStatus.Text = "$regionCount region(s), $totalUsers unique user(s)"
            }

            # ── Step 5: Render Session History chart ───────────────────────────
            if ($shData) {
                $script:_monSessionHistoryData    = $shData
                $script:_monSessionHistoryBinMins = if ($shData.BinMins) { $shData.BinMins } else { $script:_monSessionHistoryBinMins }
                Update-SessionHistoryChart -Canvas $script:monSessionHistoryCanvas `
                    -SessionsData     $shData.Sessions `
                    -DisconnectedData $shData.Disconnected `
                    -BinMinutes       $script:_monSessionHistoryBinMins
                $pts = if ($shData.Sessions) { $shData.Sessions.Count } else { 0 }
                if ($pts -gt 0) {
                    $maxSessions = [int](($shData.Sessions | Measure-Object Value -Maximum).Maximum)
                    $script:monSessionHistoryStatus.Text = "Peak Active: $maxSessions"
                } else {
                    if (-not $script:monSessionHistoryStatus.Text.StartsWith('Session History query failed')) {
                        $script:monSessionHistoryStatus.Text = 'No session history data found for the selected time range.'
                    }
                }
            }
        }
        catch { $script:monWinlogonStatus.Text = "Query failed: $_" }
        finally { $script:_monRefreshing = $false }
    })

    # ── Resize handler: redraw chart when canvas size changes ──────────────
    $script:_monWinlogonData = @()
    $script:monWinlogonCanvas.Add_SizeChanged({
        if ($script:_monWinlogonData.Count -gt 0) {
            Update-WinlogonChart -Canvas $script:monWinlogonCanvas -StageData $script:_monWinlogonData
        }
    })

    # ── Auto-refresh when time range or host pool selection changes ────────
    # Uses a one-shot DispatcherTimer (same pattern as the tab-selection refresh)
    # so the UI updates the ComboBox visually before the synchronous LAW query
    # starts. Without the delay, the UI freezes with the old selection still visible.
    #
    # Time range change: triggers full refresh (Winlogon + RTT)
    # Host pool change: triggers Winlogon-only refresh (RTT is not per-pool)
    #
    # $_monRefreshing flag prevents infinite recursion when the refresh handler
    # repopulates the host pool dropdown (which fires SelectionChanged again).
    $script:_monRefreshing = $false

    # Timer for time range changes (full refresh)
    $script:_monTimeRangeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:_monTimeRangeTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:_monTimeRangeTimer.Add_Tick({
        $script:_monTimeRangeTimer.Stop()
        if (-not $script:_monRefreshing) {
            $script:monWinlogonRefreshBtn.RaiseEvent(
                [System.Windows.RoutedEventArgs]::new(
                    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
    })
    # Helper: update the range display label
    $script:_monUpdateRangeDisplay = {
        if (-not $script:monRangeDisplay) { return }
        $sel = $script:monWinlogonTimeRange.SelectedItem
        if ($sel -and $sel.Tag -eq 'custom') {
            $script:monRangeDisplay.Text = "$script:_monCustomFrom  to  $script:_monCustomTo"
        } else {
            $script:monRangeDisplay.Text = if ($sel) { [string]$sel.Content } else { '' }
        }
    }

    # Popup for custom date range selection
    $script:_monShowCustomRangePopup = {
        [xml]$popXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Custom Date Range" Width="380" Height="240"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="12">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Height" Value="30"/>
            <Setter Property="Width" Value="80"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="3">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid Margin="20,20,20,24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="10"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="16"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="50"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <TextBlock Grid.Row="0" Grid.Column="0" Text="From:" VerticalAlignment="Center"/>
        <TextBox x:Name="PopFrom" Grid.Row="0" Grid.Column="1"
                 ToolTip="Format: dd/MM/yyyy HH:mm"
                 BorderBrush="#ABADB3" BorderThickness="1" Height="28"
                 VerticalContentAlignment="Center" Padding="4,0"/>

        <TextBlock Grid.Row="2" Grid.Column="0" Text="To:" VerticalAlignment="Center"/>
        <TextBox x:Name="PopTo" Grid.Row="2" Grid.Column="1"
                 ToolTip="Format: dd/MM/yyyy HH:mm"
                 BorderBrush="#ABADB3" BorderThickness="1" Height="28"
                 VerticalContentAlignment="Center" Padding="4,0"/>

        <TextBlock x:Name="PopError" Grid.Row="4" Grid.Column="0" Grid.ColumnSpan="2"
                   FontSize="11" Foreground="#D32F2F"/>

        <StackPanel Grid.Row="6" Grid.Column="0" Grid.ColumnSpan="2"
                    Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="PopCancel" Content="Cancel" Margin="0,0,8,0"
                    Background="#F0F0F0" Foreground="#333"
                    BorderBrush="#ABADB3" BorderThickness="1"
                    IsCancel="True"/>
            <Button x:Name="PopOk" Content="Apply"
                    Background="#0078D4" Foreground="White" BorderThickness="0"
                    IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
'@
        $popReader = New-Object System.Xml.XmlNodeReader $popXaml
        $popWin    = [System.Windows.Markup.XamlReader]::Load($popReader)
        $popWin.Owner = $script:_monMainWindow
        try { Set-WindowIcon -Window $popWin -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}

        $popFrom  = $popWin.FindName('PopFrom')
        $popTo    = $popWin.FindName('PopTo')
        $popError = $popWin.FindName('PopError')
        $popOk    = $popWin.FindName('PopOk')
        $popCancel = $popWin.FindName('PopCancel')

        $popFrom.Text = $script:_monCustomFrom
        $popTo.Text   = $script:_monCustomTo

        $popCancel.Add_Click({ $popWin.DialogResult = $false; $popWin.Close() })
        $popOk.Add_Click({
            $popError.Text = ''
            $formats = [string[]]@('dd/MM/yyyy HH:mm', 'dd/MM/yyyy H:mm', 'dd/MM/yyyy', 'yyyy-MM-dd HH:mm', 'yyyy-MM-dd')
            $dtFrom = [datetime]::MinValue; $dtTo = [datetime]::MinValue
            [void][datetime]::TryParseExact($popFrom.Text.Trim(), $formats,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$dtFrom)
            [void][datetime]::TryParseExact($popTo.Text.Trim(), $formats,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$dtTo)
            if ($dtFrom -eq [datetime]::MinValue -or $dtTo -eq [datetime]::MinValue) {
                $popError.Text = 'Use format: dd/MM/yyyy HH:mm'
                return
            }
            if ($dtFrom -ge $dtTo) {
                $popError.Text = '"From" must be before "To"'
                return
            }
            $popWin.Tag = @{ From = $popFrom.Text.Trim(); To = $popTo.Text.Trim() }
            $popWin.DialogResult = $true
            $popWin.Close()
        })

        if ($popWin.ShowDialog()) {
            $script:_monCustomFrom = $popWin.Tag.From
            $script:_monCustomTo   = $popWin.Tag.To
            & $script:_monUpdateRangeDisplay
            $script:monWinlogonStatus.Text = 'Loading...'
            $script:_monTimeRangeTimer.Start()
        } else {
            # User cancelled - revert combobox to previous non-custom selection
            $script:_monRevertingCustom = $true
            foreach ($item in $script:monWinlogonTimeRange.Items) {
                if ($item.Tag -eq '48h') { $script:monWinlogonTimeRange.SelectedItem = $item; break }
            }
            $script:_monRevertingCustom = $false
        }
    }

    $script:monWinlogonTimeRange.Add_SelectionChanged({
        if ($script:_monRefreshing -or $script:_monRevertingCustom) { return }
        $sel = $script:monWinlogonTimeRange.SelectedItem
        if ($sel -and $sel.Tag -eq 'custom') {
            if ($script:_monShowCustomRangePopup) { & $script:_monShowCustomRangePopup }
        } else {
            & $script:_monUpdateRangeDisplay
            $script:monWinlogonStatus.Text = 'Loading...'
            $script:_monTimeRangeTimer.Start()
        }
    })

    # Set initial range display text
    & $script:_monUpdateRangeDisplay

    # Timer for host pool changes (Winlogon chart only, not RTT)
    $script:_monHostPoolTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:_monHostPoolTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:_monHostPoolTimer.Add_Tick({
        $script:_monHostPoolTimer.Stop()
        if ($script:_monRefreshing) { return }
        $script:_monRefreshing = $true
        try {
            $params2 = & $script:_monGetRangeParams
            $data = @()
            try {
                $data = @(Invoke-WinlogonStagesQuery -TimeRange $params2.Range -HostPoolFilter $params2.HpFilter `
                              -CustomFrom $params2.CustomFrom -CustomTo $params2.CustomTo)
            } catch { $script:monWinlogonStatus.Text = "Winlogon query failed: $_" }

            $shData = $null
            try {
                $shData = Invoke-SessionHistoryQuery -TimeRange $params2.Range -HostPool $params2.HpFilter `
                              -CustomFrom $params2.CustomFrom -CustomTo $params2.CustomTo
            } catch { $script:monSessionHistoryStatus.Text = "Session History query failed: $_" }

            $script:_monWinlogonData = $data
            Update-WinlogonChart -Canvas $script:monWinlogonCanvas -StageData $data
            if ($data.Count -gt 0) {
                $totalSamples = ($data | ForEach-Object { $_.Samples } | Measure-Object -Sum).Sum
                $totalP95     = [math]::Round(($data | ForEach-Object { $_.P95 } | Measure-Object -Sum).Sum, 1)
                $script:monWinlogonStatus.Text = "$($data.Count) stage(s), $totalSamples sample(s) - P95 total logon time: ${totalP95}s"
            } else {
                $script:monWinlogonStatus.Text = 'No winlogon stage data found for the selected time range.'
            }

            if ($shData) {
                $script:_monSessionHistoryData = $shData
                $script:_monSessionHistoryBinMins = if ($shData.BinMins) { $shData.BinMins } else { $script:_monSessionHistoryBinMins }
                Update-SessionHistoryChart -Canvas $script:monSessionHistoryCanvas `
                    -SessionsData     $shData.Sessions `
                    -DisconnectedData $shData.Disconnected `
                    -BinMinutes       $script:_monSessionHistoryBinMins
                $pts = if ($shData.Sessions) { $shData.Sessions.Count } else { 0 }
                if ($pts -gt 0) {
                    $maxSessions = [int](($shData.Sessions | Measure-Object Value -Maximum).Maximum)
                    $script:monSessionHistoryStatus.Text = "Peak Active: $maxSessions"
                } else {
                    $script:monSessionHistoryStatus.Text = 'No session history data found.'
                }
            }
        } catch {
            $script:monWinlogonStatus.Text = "Query failed: $_"
        } finally {
            $script:_monRefreshing = $false
        }
    })
    $script:monWinlogonHostPool.Add_SelectionChanged({
        if (-not $script:_monRefreshing) {
            $script:monWinlogonStatus.Text = 'Loading...'
            $script:_monHostPoolTimer.Start()
        }
    })

    # ── RTT by Gateway Region controls ─────────────────────────────────────
    $script:monRttGrid   = $Window.FindName('MonRttGrid')
    $script:monRttStatus = $Window.FindName('MonRttStatus')

    # ── Auto-refresh when the Monitoring tab is selected ───────────────────
    # Uses a one-shot DispatcherTimer (100ms delay) so the tab renders first
    # before the synchronous LAW queries start. Without the delay, the UI
    # freezes before the tab content is visible.
    $script:_monTabItem = $Window.FindName('MainTabControl').Items | Where-Object { $_.Header -eq 'Monitoring' }
    $script:_monAutoRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:_monAutoRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:_monAutoRefreshTimer.Add_Tick({
        $script:_monAutoRefreshTimer.Stop()
        if (-not $script:_monRefreshing) {
            $script:monWinlogonRefreshBtn.RaiseEvent(
                [System.Windows.RoutedEventArgs]::new(
                    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        }
    })
    $Window.FindName('MainTabControl').Add_SelectionChanged({
        param($s, $e)
        if ($e.AddedItems.Count -gt 0 -and $e.AddedItems[0] -eq $script:_monTabItem) {
            if ($script:LawWorkspaceResourceId -and -not $script:_monRefreshing) {
                $script:monWinlogonStatus.Text = 'Loading...'
                $script:monRttStatus.Text = ''
                # Start one-shot timer - tab renders during the 100ms delay,
                # then the refresh runs on the next dispatcher tick
                $script:_monAutoRefreshTimer.Start()
            }
        }
    })
}
