# =============================================================================
# tab-sessionhosts.ps1  -  Session Hosts tab module
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Encapsulates everything needed for the Session Hosts tab in one file so the
# main dashboard script stays clean. Dot-source this file BEFORE the XAML
# string is built; the main script then injects $SessionHostsTab_Xaml into its
# XAML via a placeholder comment and calls the three public lifecycle functions:
#
#   Initialize-SessionHostsTab     - once, after $window is loaded
#   Invoke-SessionHostsTabTimer    - every second from the master DispatcherTimer
#   Reset-SessionHostsTab          - on subscription switch (triggers immediate refresh)
#
# LOAD BEHAVIOUR
# --------------
# Data is fetched on demand - no load fires until the user first clicks the
# Session Hosts tab. Once visited, the 60-second cycle runs only while the tab
# is the active (visible) tab; switching away pauses the cycle. This matches
# the Infrastructure tab pattern (grid IsVisible gate).
#
# DATA FLOW - TWO-PASS DESIGN
# ----------------------------
# Each refresh cycle is split across two dedicated runspaces so the grid
# populates with core data immediately, then metric columns are backfilled
# in the background without clearing or flickering the grid.
#
# Pass 1 - Core  ($script:vmCoreScript in $script:vmRefreshRunspace)
# ─────────────────────────────────────────────────────────────────
#   Phase 1  - AVD Session Host REST API  (per host pool, in parallel via
#              $script:hpPool RunspacePool)
#              Lists session hosts from the DesktopVirtualization provider.
#
#   Phase 1b - AVD User Sessions REST API  (parallel alongside Phase 1)
#              Resolves logged-on user names per session host.
#
#   Phase 2  - Build row objects from Phase 1/1b results.
#              Fields: VM Name, Host Pool, Region, Status, Health State,
#              Sessions, User, Drain Mode, Last Heartbeat, Agent Version,
#              OS Version, _HealthTooltip (failed check names for tooltip).
#
#   Phase 3  - Azure Resource Graph enrichment  (batched KQL, single joined
#              query per 500 VMs replacing 3 serial calls)
#              Fields: IP Address, VM SKU, Disk SKU, Avail Zone, Power State,
#              Scaling Exclude (VM tag), _OsDiskResourceId, _DiskProvIOPS.
#
#   Returns: [PSCustomObject]@{ Pass='Core'; VmRows=...; Timestamp=...; Phase3Error=... }
#   Grid is populated immediately on the UI thread when this result arrives.
#
# Pass 2 - Metrics  ($script:vmMetricsScript in $script:vmMetricsRunspace)
# ─────────────────────────────────────────────────────────────────────────
#   Phase 4  - Log Analytics enrichment  (KQL against Perf table)
#              Fields: CPU %, Mem %, OS Disk % (with heat map colouring),
#              Input Delay Median, Input Delay P95.
#              Skipped if WorkspaceResourceId is blank or all metric columns
#              are hidden. Only queries Available VMs.
#
#   Phase 5  - Azure Monitor Metrics  (disk IOPS + queue depth)
#              Fields: OS Disk IOPS, OS Disk IOPS %, OS Disk Queue.
#              Uses the regional batch metrics endpoint where available;
#              falls back to per-VM calls via RunspacePool when the batch
#              endpoint is unreachable (e.g. Private Link environments).
#              Skipped if ShowDiskPerf is $false.
#
#   Phase 5b - CPU Credits Remaining  (B-series VMs only, Azure Monitor)
#              Pre-launched concurrently with Phase 5 to overlap API latency.
#              Non-B-series VMs are stamped 'N/A' from Phase 3 (Core pass).
#
#   Returns: [PSCustomObject]@{ Pass='Metrics'; MetricRows=...; Timestamp=...;
#                               Phase4Error=...; Phase5Error=...; Phase5Mode=... }
#   Metric columns are backfilled into existing DataTable rows via
#   _SH_BackfillMetrics - no table clear, no ItemsSource reset, scroll preserved.
#   The last MetricRows are cached in $script:shMetricsCache and reapplied by
#   _SH_UpdateGrid after every subsequent Core pass so metrics never blank out.
#
# POWER ACTIONS
# -------------
# Start / Deallocate / Restart / Run Command each run in a fresh throw-away
# runspace so the dedicated refresh runspaces are never blocked. Progress is
# polled by Invoke-SessionHostsTabTimer every second; buttons are re-enabled on
# completion and an audit log entry is written to logs/audit-YYYY-MM-DD.csv.
# =============================================================================

# PSScriptAnalyzer flags $SessionHostsTab_Xaml as "assigned but never used" because it
# cannot see across the dot-source boundary into the calling script.
# This suppression attribute silences that false positive.
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'SessionHostsTab_Xaml',
    Justification = 'Exported to the calling script via dot-source')]
param()

# ==============================================================================
# 1. XAML fragment
#
# The main script contains the placeholder comment <!-- TAB:SESSION_HOSTS -->
# inside its TabControl. Before parsing the XAML it does a string replace:
#   [xml]$xaml = $rawXaml -replace '<!-- TAB:SESSION_HOSTS -->', $SessionHostsTab_Xaml
#
# Layout (DockPanel, top-to-bottom):
#   Top border   - Filter text box + SHStatusText (countdown / summary) + Refresh button
#   Bottom border- SHActionStatus label (left) + Start / Deallocate / Restart buttons (right)
#   Centre fill  - SHGrid (DataGrid, multi-select, auto-column)
# ==============================================================================

$SessionHostsTab_Xaml = @'
<TabItem x:Name="SessionHostsTab" Header="Session Hosts"
         xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <DockPanel>
        <!-- ═══ Top bar: filter input, status text and manual refresh button ═══ -->
        <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.Header.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1"
                Padding="12,7">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>   <!-- "Filter:" label -->
                    <ColumnDefinition Width="220"/>    <!-- text box -->
                    <ColumnDefinition Width="Auto"/>   <!-- Clear Filters button -->
                    <ColumnDefinition Width="Auto"/>   <!-- Hide empty hosts checkbox -->
                    <ColumnDefinition Width="*"/>      <!-- spacer -->
                    <ColumnDefinition Width="Auto"/>   <!-- status / countdown -->
                    <ColumnDefinition Width="Auto"/>   <!-- Refresh button -->
                    <ColumnDefinition Width="Auto"/>   <!-- Export CSV button  -->
                    <ColumnDefinition Width="Auto"/>   <!-- Load Costs button  -->
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Filter:"
                           VerticalAlignment="Center"
                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}"
                           Margin="0,0,8,0"/>
                <!-- SHFilterBox: TextChanged fires a DataView.RowFilter update -->
                <TextBox x:Name="SHFilterBox" Grid.Column="1"
                         FontSize="12" Padding="8,4"
                         VerticalContentAlignment="Center"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" Foreground="{DynamicResource Avd.Fg.Label}"/>
                <!-- SHClearFiltersButton: resets text box and all column dropdowns to All -->
                <Button x:Name="SHClearFiltersButton" Grid.Column="2"
                        Content="Clear Filters"
                        Background="#888" Foreground="White"
                        BorderThickness="0" FontSize="11"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="10,3" Margin="8,0,0,0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdCF" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdCF" Property="Background" Value="#666"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdCF" Property="Background" Value="#444"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <!-- SHHideEmptyCheckBox: hides session hosts with zero active sessions -->
                <CheckBox x:Name="SHHideEmptyCheckBox" Grid.Column="3"
                          Content="Hide empty hosts"
                          VerticalAlignment="Center"
                          FontSize="11" Foreground="{DynamicResource Avd.Fg.Secondary}"
                          IsChecked="True"
                          Margin="12,0,0,0"/>
                <!-- SHStatusText: shows "Available: X  Other: Y | Updated: HH:mm:ss  Next in Ns" -->
                <TextBlock x:Name="SHStatusText" Grid.Column="5"
                           VerticalAlignment="Center"
                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Subtle}"
                           Margin="0,0,12,0"/>
                <!-- SHRefreshButton: triggers an immediate out-of-schedule refresh -->
                <Button x:Name="SHRefreshButton" Grid.Column="6"
                        Content="Refresh"
                        Background="{DynamicResource Avd.Btn.Accent.Bg}" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="12,3" Margin="0,0,6,0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdVR" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdVR" Property="Background" Value="{DynamicResource Avd.Btn.Accent.Hover}"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdVR" Property="Background" Value="#003D6B"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <!-- SHExportButton: exports the current grid contents to CSV -->
                <Button x:Name="SHExportButton" Grid.Column="7"
                        Content="Export CSV"
                        Background="{DynamicResource Avd.Btn.Std.Bg}" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,5"
                        IsEnabled="False">
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
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdEx" Property="Background" Value="#003D6B"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <!-- SHLoadCostsButton: fetches PAYG GBP pricing once from the Azure Retail Prices
                     API and caches it. Subsequent refreshes reuse the cache without re-fetching.
                     Button starts disabled; enabled after the first data load (like Export CSV). -->
                <Button x:Name="SHLoadCostsButton" Grid.Column="8"
                        Content="Load Costs"
                        Background="#107C10" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,5" Margin="6,0,0,0"
                        IsEnabled="False"
                        ToolTip="Fetch PAYG GBP hourly costs from Azure Retail Prices API (prices.azure.com). Prices are cached - click again to refresh.">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdLC" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="BdLC" Property="Background" Value="#888"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdLC" Property="Background" Value="#0A5C0A"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdLC" Property="Background" Value="#073D07"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>
        </Border>

        <!-- ═══ Cost totals bar - shown after Load Costs is clicked ═══ -->
        <Border x:Name="SHTotalsBar" DockPanel.Dock="Bottom" Background="{DynamicResource Avd.CostBar.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,1,0,0"
                Height="28" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Left"
                        VerticalAlignment="Center" Margin="12,0">
                <TextBlock Text="Totals:" FontSize="11" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,16,0" VerticalAlignment="Center"/>
                <TextBlock Text="Compute GBP/mo:" FontSize="11" Foreground="{DynamicResource Avd.Fg.Secondary}"
                           Margin="0,0,6,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="SHTotalCompute" FontSize="11" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" Margin="0,0,20,0" VerticalAlignment="Center"/>
                <TextBlock Text="Disk GBP/mo:" FontSize="11" Foreground="{DynamicResource Avd.Fg.Secondary}"
                           Margin="0,0,6,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="SHTotalDisk" FontSize="11" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" VerticalAlignment="Center"/>
                <TextBlock Text="Txn GBP/mo:" FontSize="11" Foreground="{DynamicResource Avd.Fg.Secondary}"
                           Margin="16,0,6,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="SHTotalTxn" FontSize="11" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" VerticalAlignment="Center"/>
            </StackPanel>
        </Border>

        <!-- ═══ Bottom action bar: result label + power action buttons ═══ -->
        <!-- Buttons start disabled; SelectionChanged in code enables them   -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.Header.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,1,0,0"
                Height="38">
            <Grid Margin="12,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>      <!-- action result text -->
                    <ColumnDefinition Width="Auto"/>   <!-- button group -->
                </Grid.ColumnDefinitions>
                <!-- SHActionStatus: displays in-progress and result messages for power actions.
                     TextTrimming shows '...' when the text is too long for the available
                     space (e.g. bulk deallocate listing many VM names). The self-bound
                     ToolTip lets the user hover to read the full message. -->
                <TextBlock x:Name="SHActionStatus" Grid.Column="0"
                           Foreground="{DynamicResource Avd.Fg.Secondary}" FontSize="12"
                           VerticalAlignment="Center"
                           TextTrimming="CharacterEllipsis"
                           ToolTip="{Binding RelativeSource={RelativeSource Self}, Path=Text}"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal"
                            VerticalAlignment="Center">
                    <!-- Enable Drain: purple - blocks new sessions on the selected host(s) -->
                    <Button x:Name="SHEnableDrainButton" Content="Enable Drain"
                            IsEnabled="False" Margin="0,4,6,4"
                            Background="#8764B8" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Enable drain mode on the selected host(s) - blocks new sessions">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdED" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdED" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdED" Property="Background" Value="#6B4FA0"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <!-- Disable Drain: teal - allows new sessions on the selected host(s) -->
                    <Button x:Name="SHDisableDrainButton" Content="Disable Drain"
                            IsEnabled="False" Margin="0,4,12,4"
                            Background="#038387" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Disable drain mode on the selected host(s) - allows new sessions">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdDD" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdDD" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdDD" Property="Background" Value="#026467"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <!-- Separator between drain controls and power actions -->
                    <Rectangle Width="1" Margin="0,6,12,6" Fill="{DynamicResource Avd.Border.Input}"/>
                    <!-- Start: green - brings a deallocated VM back online -->
                    <Button x:Name="SHStartButton" Content="Start"
                            IsEnabled="False" Margin="0,4,6,4"
                            Background="#107C10" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Start the selected VM(s)">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdS" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdS" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdS" Property="Background" Value="#0A5C0A"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <!-- Deallocate: amber - stops the VM AND releases the compute allocation -->
                    <!-- (saves cost vs. just stopping the OS - no compute billing when deallocated) -->
                    <Button x:Name="SHDeallocateButton" Content="Deallocate"
                            IsEnabled="False" Margin="0,4,6,4"
                            Background="#CA5010" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Stop and deallocate the selected VM(s) - releases compute billing">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdD" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdD" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdD" Property="Background" Value="#9A3C0A"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <!-- Restart: blue - reboots the OS while keeping the VM allocated -->
                    <Button x:Name="SHRestartButton" Content="Restart"
                            IsEnabled="False" Margin="0,4,6,4"
                            Background="{DynamicResource Avd.Btn.Accent.Bg}" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Restart the selected VM(s)">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdR" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdR" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdR" Property="Background" Value="{DynamicResource Avd.Btn.Accent.Hover}"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ═══ Main grid: fills remaining space between the two bars ═══ -->
        <!-- Columns are auto-generated from the PSCustomObject property names -->
        <!-- The _RG helper column is hidden via AutoGeneratingColumn in code  -->
        <DataGrid x:Name="SHGrid" Margin="0"
                  SelectionMode="Extended" SelectionUnit="FullRow"
                  RowHeaderWidth="0">
            <!-- Ctrl+MouseWheel zoom: LayoutTransform with ScaleTransform scales the
                 entire grid (headers, rows, text) uniformly. Wired to PreviewMouseWheel
                 in Initialize-SessionHostsTab code-behind.
                 Range: 60% (fit more rows on screen) to 150% (enlarge for readability). -->
            <DataGrid.LayoutTransform>
                <ScaleTransform x:Name="SHGridZoom" ScaleX="1" ScaleY="1"/>
            </DataGrid.LayoutTransform>
        </DataGrid>
    </DockPanel>
</TabItem>
'@

# =============================================================================
# Metric toggles - set to $false to skip querying and hide the column.
# =============================================================================
$script:ShowCPU        = $true   # CPU % from Perf table
$script:ShowMem        = $true   # Mem % from Perf table
$script:ShowDisk       = $true   # Disk % from Perf table
$script:ShowInputDelay = $true   # Input Delay from Perf table (User Input Delay per Process)

# =============================================================================
# Heat map thresholds for the CPU %, Mem %, and Disk % columns.
# Cells are coloured based on the latest value returned from Log Analytics.
# Edit these two values to adjust the colour bands:
#   Green  = below AmberPct
#   Amber  = AmberPct up to (but not including) RedPct
#   Red    = RedPct and above
# =============================================================================
$script:LawHeatMapAmberPct = 75   # >= this percentage -> amber
$script:LawHeatMapRedPct   = 90   # >= this percentage -> red

# Input Delay heat map thresholds (milliseconds) - applies to both Avg and P95 columns.
# Source: Perf table, ObjectName "User Input Delay per Process", CounterName "Max Input Delay".
# Data is queried over 1 hour for a more meaningful P95 value.
# Green  = below AmberMs (< 125ms)
# Amber  = AmberMs up to (but not including) RedMs (125-199ms)
# Red    = RedMs and above (>= 200ms)
$script:LawInputDelayAmberMs = 125   # >= this ms -> amber
$script:LawInputDelayRedMs   = 200   # >= this ms -> red

# OS Disk performance metric toggles (Azure Monitor Metrics API - no LAW required).
# When $true, Phase 5 queries each Available VM for OS Disk IOPS and Queue Depth.
$script:ShowDiskPerf = $true

# Disk Queue Depth heat map thresholds.
# Queue depth indicates disk I/O pressure. Standard thresholds:
#   Green  = below AmberVal (healthy)
#   Amber  = AmberVal up to (but not including) RedVal (moderate pressure)
#   Red    = RedVal and above (disk bottleneck)
$script:DiskQueueAmberVal = 2   # >= this -> amber
$script:DiskQueueRedVal   = 5   # >= this -> red

# Processes to exclude from Input Delay calculations.
# These are background/system processes that report input delay but do not
# represent real user interaction (e.g. LapsView.exe).
# Process names are matched against the InstanceName field which has the format
# "SessionId:PID <ProcessName>" - we use KQL 'has' for case-insensitive substring match.
# Configured via LogAnalytics.InputDelayExcludeProcesses in config.psd1.
# Default below only applies if the config key is missing.
if (-not $script:InputDelayExcludeProcesses) {
    $script:InputDelayExcludeProcesses = @('LapsView.exe')
}

# =============================================================================
# User column display format.
# When $false (default), the User column shows the short name only
#   (e.g. "awebber" stripped from "DOMAIN\awebber" or "awebber@domain.com").
# When $true, the full value from Azure is shown as-is
#   (e.g. "DOMAIN\awebber" or "awebber@domain.com").
# =============================================================================
$script:ShowFullUPN = $false

# =============================================================================
# 2a. Core background script (Pass 1 - fast render)
#
# Runs inside $script:vmRefreshRunspace. Collects AVD host/session data and
# Resource Graph metadata only (Phases 1, 1b, 2, 3). Returns immediately after
# Phase 3 so the grid can render with VM names, states, and sessions before the
# slow Azure Monitor / Log Analytics calls start.
#
# Variables injected via SessionStateProxy.SetVariable() before each BeginInvoke():
#   $ArmToken, $SubId, $AvdIncludeRGsCsv, $AvdExcludeRGsCsv, $ExcludedPoolsCsv,
#   $RgLocationCache, $HpPool, $RestHelperDef, $LogFile, $ScalingExcludeTag,
#   $ShowFullUPN, $PricingWindowsFallback
#
# Return: [PSCustomObject]@{ Pass='Core'; VmRows=...; Timestamp=...; Phase3Error=... }
# =============================================================================

$script:vmCoreScript = {

    # Variables injected via SessionStateProxy:
    # $ArmToken, $SubId, $ExcludedPoolsCsv, $AvdIncludeRGsCsv, $AvdExcludeRGsCsv,
    # $RgLocationCache, $HpPool, $RestHelperDef, $ScalingExcludeTag

    $avdApi = '2024-04-03'

    # Retrieve every host pool in the current subscription via REST.
    $allPools = Invoke-RestMethod -Method GET `
        -Uri "https://management.azure.com/subscriptions/$SubId/providers/Microsoft.DesktopVirtualization/hostPools?api-version=$avdApi" `
        -Headers @{ Authorization = "Bearer $ArmToken"; 'Content-Type' = 'application/json' } `
        -ErrorAction Stop
    $allPools = @($allPools.value)

    $ExcludedPools = @($ExcludedPoolsCsv -split ',' | Where-Object { $_ })
    $AvdIncludeRGs = @($AvdIncludeRGsCsv -split ',' | Where-Object { $_ })
    $AvdExcludeRGs = @($AvdExcludeRGsCsv -split ',' | Where-Object { $_ })

    $hostPools = $allPools
    if ($AvdIncludeRGs.Count -gt 0) { $hostPools = $hostPools | Where-Object { $_.id.Split('/')[4] -in $AvdIncludeRGs } }
    if ($AvdExcludeRGs.Count -gt 0) { $hostPools = $hostPools | Where-Object { $_.id.Split('/')[4] -notin $AvdExcludeRGs } }
    if ($ExcludedPools.Count  -gt 0) { $hostPools = $hostPools | Where-Object { $_.name -notin $ExcludedPools } }

    # ── Phase 1: Parallel session host queries (REST API) ─────────────────────
    $pool = $HpPool

    $shScript = [scriptblock]::Create($RestHelperDef + @'
        $tok = $args[0]; $subId = $args[1]; $rg = $args[2]; $name = $args[3]; $api = $args[4]; $LogFile = $args[5]
        Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.DesktopVirtualization/hostPools/$name/sessionHosts" -Token $tok -ApiVersion $api
'@)

    $handles = @(foreach ($hp in $hostPools) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($shScript).AddArgument($ArmToken).AddArgument($SubId).AddArgument($hp.id.Split('/')[4]).AddArgument($hp.name).AddArgument($avdApi).AddArgument($LogFile)
        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); HpName = $hp.name; HpRG = $hp.id.Split('/')[4] }
    })

    # Phase 1b: Fire parallel user-session queries (run concurrently while we collect session hosts)
    $usScript = [scriptblock]::Create($RestHelperDef + @'
        $tok = $args[0]; $subId = $args[1]; $rg = $args[2]; $name = $args[3]; $api = $args[4]
        try { Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.DesktopVirtualization/hostPools/$name/userSessions" -Token $tok -ApiVersion $api } catch { @() }
'@)

    $usHandles = @(foreach ($hp in $hostPools) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($usScript).AddArgument($ArmToken).AddArgument($SubId).AddArgument($hp.id.Split('/')[4]).AddArgument($hp.name).AddArgument($avdApi)
        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    })

    $rgCache   = if ($RgLocationCache) { $RgLocationCache } else { @{} }

    $rawHosts = [System.Collections.Generic.List[PSCustomObject]]::new()
    try {
        foreach ($h in $handles) {
            $hosts = $h.PS.EndInvoke($h.Handle); $h.PS.Dispose()
            foreach ($sh in $hosts) {
                if (-not $sh.properties.resourceId) { continue }
                $rgName = $sh.properties.resourceId.Split('/')[4]
                $rawHosts.Add([PSCustomObject]@{
                    SH     = $sh
                    HpName = $h.HpName
                    HpRG   = $h.HpRG
                    RGName = $rgName
                    VMName = ($sh.name.Split('/')[-1] -split '\.')[0]
                })
            }
        }
    } finally {
        # Safety net: dispose any PS instances not yet disposed (prevents zombie leaks
        # if EndInvoke() throws partway through the collection loop)
        foreach ($h in $handles) { try { $h.PS.Dispose() } catch {} }
    }

    # Collect user session results and build lookup: session host FQDN (lowercase) -> list of short usernames
    $userMap = @{}
    try {
        foreach ($uh in $usHandles) {
            $sessions = $uh.PS.EndInvoke($uh.Handle); $uh.PS.Dispose()
            foreach ($us in $sessions) {
                if (-not $us.name) { continue }
                $shFqdn = $us.name.Split('/')[-2].ToLower()
                $upn = if ($us.properties.activeDirectoryUserName) { $us.properties.activeDirectoryUserName } else { $us.properties.userPrincipalName }
                if (-not $upn) { continue }
                # Strip domain prefix (DOMAIN\user) or UPN suffix (user@domain) unless ShowFullUPN is set
                $short = if ($ShowFullUPN) { [string]$upn }
                         elseif ($upn -match '\\') { ($upn -split '\\')[-1] }
                         elseif ($upn -match '@') { ($upn -split '@')[0] }
                         else { $upn }
                if (-not $userMap.ContainsKey($shFqdn)) { $userMap[$shFqdn] = [System.Collections.Generic.List[string]]::new() }
                if ($short -notin $userMap[$shFqdn]) { $userMap[$shFqdn].Add($short) }
            }
        }
    } finally {
        foreach ($uh in $usHandles) { try { $uh.PS.Dispose() } catch {} }
    }

    # ── Phase 2: Build final session host row objects ─────────────────────────
    $vmRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($entry in $rawHosts) {
        $sh        = $entry.SH
        $rgName    = $entry.RGName
        $hpRG      = $entry.HpRG
        $vmName    = $entry.VMName
        $loc       = if ($rgCache.ContainsKey($rgName)) { $rgCache[$rgName] } else { 'unknown' }

        $heartbeat = if ($sh.properties.lastHeartBeat) {
                         try { ([DateTime]$sh.properties.lastHeartBeat).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { '' }
                     } else { '' }

        $healthChecks  = $sh.properties.sessionHostHealthCheckResults
        $failedChecks  = @($healthChecks | Where-Object { $_.healthCheckResult -ne 'HealthCheckSucceeded' })
        $healthState   = if (-not $healthChecks -or $healthChecks.Count -eq 0) { 'N/A' }
                         elseif ($failedChecks.Count -eq 0) { 'Healthy' }
                         else { "Unhealthy ($($failedChecks.Count))" }
        # Build tooltip text from the failed checks - one line per failure.
        # "Check" suffix and "HealthCheck" prefix are stripped for readability
        # (e.g. "DomainJoinedCheck: HealthCheckFailed" → "DomainJoined: Failed").
        # Empty string for healthy/N/A hosts so the DataTrigger can null the tooltip.
        $healthTooltip = if ($failedChecks.Count -gt 0) {
            ($failedChecks | ForEach-Object {
                $chkName   = ([string]$_.healthCheckName)   -replace 'Check$', ''
                $chkResult = ([string]$_.healthCheckResult) -replace '^HealthCheck', ''
                "$chkName`: $chkResult"
            }) -join "`n"
        } else { '' }

        # Build User display from the userSessions lookup (Phase 1b)
        # Multi-user display: up to 3 usernames shown stacked vertically. If there
        # are more than 3, the 3rd name gets "..." appended and the rest are hidden.
        # Hover tooltip (_UserTooltip) always shows the full list for 2+ users.
        $shFqdn  = $sh.name.Split('/')[-1].ToLower()
        $users   = @(if ($userMap.ContainsKey($shFqdn)) { $userMap[$shFqdn] } else { @() })
        $userTxt = if ($users.Count -eq 0) { '-' }
                   elseif ($users.Count -le 3) { $users -join "`n" }
                   else { ($users[0..1] -join "`n") + "`n$($users[2])..." }
        $userTip = if ($users.Count -gt 1) { $users -join "`n" } else { '' }

        # Fields from AVD Session Host REST API (DesktopVirtualization provider)
        # Fields marked "Resource Graph" are placeholders overwritten in Phase 3
        $vmRows.Add([PSCustomObject]@{
            'VM Name'         = $vmName                                                    # AVD: parsed from session host resource name
            'Host Pool'       = $entry.HpName                                              # AVD: parent host pool name
            'Region'          = $loc                                                       # Lookup: resource group -> Azure region cache
            'Status'          = [string]$sh.properties.status                              # AVD: session host status (Available/Shutdown/etc.)
            'Power State'     = '-'                                                        # Resource Graph: real VM power state (Phase 3)
            'Health State'    = $healthState                                                # AVD: computed from sessionHostHealthCheckResults
            '_HealthTooltip'  = $healthTooltip                                             # Internal: failed check names for Health State tooltip (empty when healthy)
            'Sessions'        = [int]$sh.properties.sessions                               # AVD: active session count
            'User'            = $userTxt                                                   # AVD: logged-on user(s) from userSessions API
            '_UserTooltip'    = $userTip                                                   # Internal: full user list for tooltip (2+ users)
            'CPU %'           = '-'                                                        # Log Analytics: latest avg CPU (Phase 4)
            'Mem %'           = '-'                                                        # Log Analytics: latest avg Memory (Phase 4)
            'OS Disk %'          = '-'                                                        # Log Analytics: latest C: used space % (Phase 4)
            '_CPUSort'        = [double]-1                                                 # Numeric sort key for CPU % column (Phase 4)
            '_MemSort'        = [double]-1                                                 # Numeric sort key for Mem % column (Phase 4)
            '_DiskSort'       = [double]-1                                                 # Numeric sort key for Disk % column (Phase 4)
            '_CPUColor'       = ''                                                         # Heat map hint for CPU % cell (Phase 4)
            '_MemColor'       = ''                                                         # Heat map hint for Mem % cell (Phase 4)
            '_DiskColor'      = ''                                                         # Heat map hint for Disk % cell (Phase 4)
            'Input Delay Median' = '-'                                                        # Log Analytics: median input delay ms (Phase 4)
            '_InputDelaySort' = [double]-1                                                 # Numeric sort key for Input Delay Median column (Phase 4)
            '_InputDelayColor'= ''                                                         # Heat map hint for Input Delay Median cell (Phase 4)
            'Input Delay P95' = '-'                                                        # Log Analytics: P95 input delay ms (Phase 4)
            '_InputDelayP95Sort' = [double]-1                                              # Numeric sort key for Input Delay P95 column (Phase 4)
            '_InputDelayP95Color'= ''                                                      # Heat map hint for Input Delay P95 cell (Phase 4)
            'OS Disk IOPS'       = '-'                                                        # Azure Monitor: OS Disk read+write ops/sec (Phase 5)
            '_DiskIOPSSort'   = [double]-1                                                 # Numeric sort key for Disk IOPS column (Phase 5)
            'OS Disk IOPS %'     = '-'                                                        # Phase 5: current IOPS / provisioned IOPS * 100
            '_DiskIOPSPctSort' = [double]-1                                                # Numeric sort key for Disk IOPS % column (Phase 5)
            '_DiskIOPSPctColor' = ''                                                       # Heat map hint for Disk IOPS % cell (Phase 5)
            'OS Disk Queue'      = '-'                                                        # Azure Monitor: OS Disk queue depth (Phase 5)
            '_DiskQueueSort'  = [double]-1                                                 # Numeric sort key for Disk Queue column (Phase 5)
            '_DiskQueueColor' = ''                                                         # Heat map hint for Disk Queue cell (Phase 5)
            'CPU Credits'        = '-'                                                        # Azure Monitor: remaining CPU burst credits (B-series VMs only, Phase 5)
            '_CPUCreditsSort' = [double]-1                                                 # Numeric sort key for CPU Credits column (Phase 5)
            '_CPUCreditsColor'= ''                                                         # Heat map hint for CPU Credits cell (Phase 5)
            '_DiskProvIOPS'   = [int]0                                                     # Internal: provisioned IOPS from disk tier (Phase 3)
            '_DiskTier'       = ''                                                         # Internal: disk tier name e.g. "P10" for pricing API (Phase 3)
            '_DiskSkuRaw'     = ''                                                         # Internal: raw disk SKU e.g. "Premium_LRS" for pricing API (Phase 3)
            '_VMResourceId'   = [string]$sh.properties.resourceId                          # Internal: full VM ARM resource ID for metrics API (Phase 5)
            'Drain Mode'      = if ($sh.properties.allowNewSession) { 'Off' } else { 'On' } # AVD: allowNewSession property
            'Scaling Exclude' = '-'                                                        # Resource Graph: VM tag (Phase 3)
            'Last Heartbeat'  = $heartbeat                                                 # AVD: lastHeartBeat property
            'Agent Version'   = [string]$sh.properties.agentVersion                        # AVD: agent version string
            'OS Version'      = [string]$sh.properties.osVersion                           # AVD: OS version string
            'IP Address'      = '-'                                                        # Resource Graph: NIC private IP (Phase 3)
            'Avail Zone'      = 'N/A'                                                      # Resource Graph: VM availability zone (Phase 3)
            'VM SKU'          = '-'                                                        # Resource Graph: VM hardwareProfile.vmSize (Phase 3)
            'Disk SKU'        = '-'                                                        # Resource Graph: OS disk storageAccountType (Phase 3)
            '_RG'             = $rgName                                                    # Internal: VM resource group for power actions
            '_HpRG'           = $hpRG                                                      # Internal: host pool resource group for drain mode API
            '_SHName'         = $sh.name.Split('/')[-1]                                    # Internal: full session host name for drain mode API
            'Compute GBP/mo'  = '-'                                                        # Retail Prices API: PAYG Windows hourly compute cost (cost button)
            '_ComputeCostSort'= [double]-1                                                 # Numeric sort key for Compute GBP/mo column
            'Disk GBP/mo'     = '-'                                                        # Retail Prices API: managed disk monthly price / 730 (cost button)
            '_DiskCostSort'   = [double]-1                                                 # Numeric sort key for Disk GBP/mo column
            'Txn GBP/10K'     = '-'                                                        # Retail Prices API: Standard SSD/HDD transaction price per 10K I/Os (cost button)
            '_TxnCostSort'    = [double]-1                                                 # Numeric sort key for Txn GBP/10K column
            'Txn GBP/mo'      = '-'                                                        # Cost Management: actual billed disk operation charge (load costs)
            '_TxnMoCostSort'  = [double]-1                                                 # Numeric sort key for Txn GBP/mo column
            '_OsDiskResourceId' = ''                                                       # Internal: OS disk ARM resource ID for Cost Management query
            # Internal: populated in Phase 3 from the VM's marketplace image offer.
            # Values: 'Linux' = fetch base/AHB compute rate (W10/W11 multisession, AHB VMs)
            #         'Windows' = fetch Windows Server PAYG rate (OS licence bundled in price)
            # Used by Invoke-SessionHostsCostFetch in cost-lookup.ps1 to select the correct
            # price tier from the Azure Retail Prices API.  Not shown in the grid.
            '_PricingOsType'    = ''
        })
    }

    # ── Phase 3: Enrich rows via Azure Resource Graph (data NOT in the AVD API) ──
    #
    # WHY RESOURCE GRAPH?
    # --------------------
    # The AVD session host REST API returns only AVD-level properties (session count,
    # health status, allow new sessions, etc.). It does NOT expose VM SKU, availability
    # zone, private IP address, OS disk SKU/size, or resource tags. All of those come
    # from the ARM resource layer and are fetched here via Resource Graph KQL.
    #
    # SINGLE JOINED QUERY - replacing 3 serial HTTP calls
    # ----------------------------------------------------
    # Previous implementation made 3 sequential Resource Graph calls:
    #   3a. VM metadata  → builds $vmInfoMap (nicId, osDiskName, vmSize, zone, tags)
    #   3b. NIC IPs      → needs nicIds from 3a - serial dependency
    #   3c. Disk SKUs    → needs osDiskNames from 3a - serial dependency on 3a only
    #
    # 3b and 3c are independent of each other but both waited for 3a. More importantly,
    # all three target the Resources table in Resource Graph and can be expressed as a
    # single KQL query using 'join kind=leftouter'. This eliminates 2 of the 3 HTTP
    # round trips (~600-1000 ms saving per refresh for a typical environment).
    #
    # 'leftouter' join semantics: every VM row appears in the result even if it has no
    # matching NIC or disk record (e.g. NIC deleted separately, unmanaged disk).
    # In those cases ip / diskSku come back null and we fall back to '-' - the same
    # graceful behaviour as the old code.
    #
    # BATCHING
    # ---------
    # Resource Graph imposes a limit on the size of the in() clause. Batch size is
    # capped at 500 VM names per call. The join is done server-side so there are no
    # separate NIC or disk batch loops - a single batch of N VM names returns all
    # three resource types' data in one response.
    # ──────────────────────────────────────────────────────────────────────────────
    $phase3Error = $null
    if ($vmRows.Count -gt 0) {
        try {
            # Dot-source the REST helper so Invoke-Arm is available in this scope.
            . ([scriptblock]::Create($RestHelperDef))

            # De-duplicate VM names (same VM can appear in multiple host pools).
            $nameKeys  = @(@($vmRows | ForEach-Object { $_.'VM Name'.ToLower() }) | Select-Object -Unique)
            $batchSize = 500

            # ── Disk tier lookup tables ──────────────────────────────────────────
            # Each entry is @(maxSizeGB, tierLabel, provisionedIOPS).
            # To resolve a disk's tier: find the first entry where maxSizeGB >= actual size.
            # The tables are ordered ascending by size so the first match is the correct tier.
            #
            # These are used to build the "Disk SKU" display string (e.g. "E10 (128 GB) 500 IOPS")
            # and to store _DiskProvIOPS / _DiskTier for the Load Costs feature.
            #
            # Source: https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types
            # Tuple: @(maxSizeGB, tierName, baselineIOPS, burstIOPS)
            # burstIOPS = 0 means no burst support (Standard HDD, large Standard SSD).
            # Premium P1-P20: credit-based burst to 3,500. P30+: on-demand burst to 30,000.
            # Standard SSD E1-E29: credit-based burst to 600. E30: burst to 1,000. E40+: no burst.
            $premiumTiers = @(
                @(4,'P1',120,3500), @(8,'P2',120,3500), @(16,'P3',120,3500), @(32,'P4',120,3500),
                @(64,'P6',240,3500), @(128,'P10',500,3500), @(256,'P15',1100,3500), @(512,'P20',2300,3500),
                @(1024,'P30',5000,30000), @(2048,'P40',7500,30000), @(4096,'P50',7500,30000),
                @(8192,'P60',16000,30000), @(16384,'P70',18000,30000), @(32767,'P80',20000,30000)
            )
            $standardSSDTiers = @(
                @(4,'E1',500,600), @(8,'E2',500,600), @(16,'E3',500,600), @(32,'E4',500,600),
                @(64,'E6',500,600), @(128,'E10',500,600), @(256,'E15',500,600), @(512,'E20',500,600),
                @(1024,'E30',500,1000), @(2048,'E40',500,0), @(4096,'E50',500,0),
                @(8192,'E60',2000,0), @(16384,'E70',4000,0), @(32767,'E80',6000,0)
            )
            $standardHDDTiers = @(
                @(32,'S4',500,0), @(64,'S6',500,0), @(128,'S10',500,0), @(256,'S15',500,0),
                @(512,'S20',500,0), @(1024,'S30',500,0), @(2048,'S40',500,0), @(4096,'S50',500,0),
                @(8192,'S60',1300,0), @(16384,'S70',2000,0), @(32767,'S80',2000,0)
            )

            # Accumulate enrichment data across all batches before merging into $vmRows.
            # Key = lowercase VM short-name; Value = hashtable of enrichment fields.
            $vmInfoMap = @{}

            for ($b = 0; $b -lt $nameKeys.Count; $b += $batchSize) {
                $slice    = @($nameKeys[$b .. ([Math]::Min($b + $batchSize - 1, $nameKeys.Count - 1))])
                # Format as a KQL in() list of single-quoted strings: 'vm001','vm002',...
                $nameList = ($slice | ForEach-Object { "'$_'" }) -join ','

                # ── Single joined KQL query ──────────────────────────────────────
                # The VM table is the left (driving) table. NICs and Disks are joined
                # server-side so one HTTP round trip returns all three resource types.
                #
                # Field notes:
                #   vmNicId        - the NIC ARM resource ID, used as the join key to
                #                    the NIC sub-query. Named 'vmNicId' (not 'nicId') to
                #                    avoid a column-name collision with nicId in the NIC
                #                    sub-query output; Resource Graph would drop one of
                #                    them silently if both were called 'nicId'.
                #   osDiskId       - full ARM resource ID of the managed disk, stored as
                #                    _OsDiskResourceId on the row for use by Load Costs.
                #   scalingExclude - reads the tag whose name is in $ScalingExcludeTag
                #                    (from config). iff(isnotnull(...)) returns 'Yes' if
                #                    the tag exists (any value), '' if absent.
                #   zone           - availability zone number (1/2/3) or '-' if the VM
                #                    is not zone-pinned (array_length(zones) == 0).
                #   ip             - private IP of the first NIC's first IP config.
                #                    Null if the NIC record is not found (leftouter join).
                #   diskSku        - e.g. "Premium_LRS", "StandardSSD_LRS", "Standard_LRS"
                #   diskSizeGB     - provisioned disk size in GiB.
                #
                # `$left / `$right are KQL join syntax tokens; the backtick-escaping prevents
                # PowerShell from treating them as variable expansions inside the here-string.
                $q = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| where tolower(name) in ($nameList)
| project
    vmName         = tolower(name),
    vmSize         = tostring(properties.hardwareProfile.vmSize),
    osDiskName     = tolower(tostring(properties.storageProfile.osDisk.name)),
    osDiskId       = tolower(tostring(properties.storageProfile.osDisk.managedDisk.id)),
    zone           = iff(array_length(zones) > 0, tostring(zones[0]), '-'),
    vmNicId        = tolower(tostring(properties.networkProfile.networkInterfaces[0].id)),
    scalingExclude = iff(isnotnull(tags['$ScalingExcludeTag']), 'Yes', ''),
    powerState     = tostring(properties.extended.instanceView.powerState.code),
    imageOffer     = tostring(properties.storageProfile.imageReference.offer)
| join kind=leftouter (
    Resources
    | where type =~ 'microsoft.network/networkinterfaces'
    | project nicId = tolower(id), ip = tostring(properties.ipConfigurations[0].properties.privateIPAddress)
) on `$left.vmNicId == `$right.nicId
| join kind=leftouter (
    Resources
    | where type =~ 'microsoft.compute/disks'
    | project diskName = tolower(name), diskSku = tostring(sku.name), diskSizeGB = toint(properties.diskSizeGB)
) on `$left.osDiskName == `$right.diskName
"@
                # POST to Resource Graph. 'subscriptions' scopes the query to this subscription only.
                $body = @{ subscriptions = @($SubId); query = $q }
                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase3] Querying Resource Graph for $($slice.Count) VM(s): $($slice -join ', ')`r`n") } catch {} }
                $resp = Invoke-Arm -Method POST -Path '/providers/Microsoft.ResourceGraph/resources' -Token $ArmToken -ApiVersion '2021-03-01' -Body $body -FullResponse
                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase3] Resource Graph returned $(@($resp.data).Count) row(s). resultTruncated=$($resp.resultTruncated)`r`n") } catch {} }

                foreach ($item in @($resp.data)) {
                    $vn = [string]$item.vmName
                    if (-not $vn) { continue }
                    $sku  = [string]$item.diskSku    # e.g. "Premium_LRS"
                    $size = [int]$item.diskSizeGB    # e.g. 128

                    # Resolve the disk tier label (e.g. "E10") and provisioned IOPS from the
                    # lookup table. The SKU prefix selects the table; iterate entries in ascending
                    # size order and take the first entry whose maxSizeGB >= actual disk size.
                    $tierTable = switch -Wildcard ($sku) {
                        'Premium*'     { $premiumTiers }
                        'StandardSSD*' { $standardSSDTiers }
                        'Standard*'    { $standardHDDTiers }
                        default        { @() }    # UltraSSD / unknown - no tier table available
                    }
                    $tierName = ''; $provIOPS = 0
                    foreach ($t in $tierTable) {
                        if ($size -le $t[0]) { $tierName = $t[1]; $provIOPS = $t[2]; break }
                    }

                    $vmInfoMap[$vn] = @{
                        vmSize         = [string]$item.vmSize
                        osDiskName     = [string]$item.osDiskName
                        osDiskId       = [string]$item.osDiskId       # ARM resource ID - used by Load Costs
                        zone           = [string]$item.zone
                        nicId          = [string]$item.vmNicId
                        scalingExclude = [string]$item.scalingExclude
                        ip             = [string]$item.ip
                        # Build the human-readable disk display string inline.
                        # If a tier was resolved: "E10 (128 GB) 500 IOPS"
                        # If no tier but size known: "StandardSSD_LRS (128 GB)"
                        # Fallback: just the raw SKU string.
                        diskDisplay    = if ($tierName) { "$tierName ($size GB) $provIOPS IOPS" } elseif ($size) { "$sku ($size GB)" } else { $sku }
                        diskProvIOPS   = $provIOPS         # stored as _DiskProvIOPS - used by IOPS utilisation column
                        diskTier       = $tierName         # e.g. "P10", "E10", "S10" - used by Load Costs pricing lookup
                        diskSkuRaw     = $sku              # e.g. "Premium_LRS" - used by Load Costs to skip txn query for Premium
                        powerState     = [string]$item.powerState  # e.g. "PowerState/running"
                        # Marketplace image offer - used to detect OS family for pricing.
                        # Examples: 'windows-11-avd', 'WindowsServer', 'Windows-10'.
                        # Empty for VMs built from custom/gallery images.
                        imageOffer     = [string]$item.imageOffer
                    }
                }
            }

            # ── Merge Resource Graph results into the row objects ────────────────
            # Walk every row and stamp the enrichment fields from $vmInfoMap.
            # Rows with no matching entry (VM name not returned by Resource Graph,
            # e.g. orphaned session host record) keep their default '-' values.
            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase3] vmInfoMap has $($vmInfoMap.Count) entries. Merging into $($vmRows.Count) row(s).`r`n") } catch {} }
            foreach ($row in $vmRows) {
                $vmLow = $row.'VM Name'.ToLower()
                if ($LogFile -and -not $vmInfoMap.ContainsKey($vmLow)) {
                    try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase3] MISS: '$($row.'VM Name')' (key='$vmLow') not found in Resource Graph results`r`n") } catch {}
                }
                if ($vmInfoMap.ContainsKey($vmLow)) {
                    $nfo = $vmInfoMap[$vmLow]
                    $row.'VM SKU'          = if ($nfo['vmSize']) { $nfo['vmSize'] } else { '-' }
                    if ($nfo['diskSkuRaw']) {
                        $row.'Disk SKU'      = $nfo['diskDisplay']
                        $row.'_DiskProvIOPS' = [int]$nfo['diskProvIOPS']  # numeric - used for IOPS % calculation in Phase 5
                        $row.'_DiskTier'     = $nfo['diskTier']           # e.g. "E10" - Load Costs pricing
                        $row.'_DiskSkuRaw'   = $nfo['diskSkuRaw']         # e.g. "Premium_LRS" - Load Costs skips txn query for Premium
                    }
                    $row.'_OsDiskResourceId' = if ($nfo['osDiskId']) { $nfo['osDiskId'] } else { '' }  # Load Costs Cost Management filter
                    $row.'Avail Zone'        = if ($nfo['zone'] -and $nfo['zone'] -ne '' -and $nfo['zone'] -ne '-') { $nfo['zone'] } else { 'N/A' }
                    $row.'Scaling Exclude'   = if ($nfo['scalingExclude']) { $nfo['scalingExclude'] } else { 'No' }
                    $row.'IP Address'        = if ($nfo['ip']) { $nfo['ip'] } else { '-' }

                    # Populate _PricingOsType — a hidden internal column (not shown in the grid)
                    # that tells Invoke-SessionHostsCostFetch in cost-lookup.ps1 which Azure
                    # Retail Prices API tier to use when the user clicks Load Costs.
                    #
                    # WHY THIS IS NEEDED:
                    #   Azure bills two very different compute rates for the same VM size:
                    #     - Linux/base rate:       no OS licence charge. Used for Windows 10/11
                    #                              multisession AVD hosts (licence covered by M365)
                    #                              and VMs with Azure Hybrid Benefit (SA licence).
                    #     - Windows Server PAYG:   includes the Windows Server licence cost on top
                    #                              of compute. Used only for Windows Server session
                    #                              hosts without AHB.
                    #   Without per-VM detection, a single global setting would mis-price mixed
                    #   pools containing both W10/W11 multisession and Windows Server hosts.
                    #
                    # HOW IT WORKS — imageReference.offer from Resource Graph:
                    #   'windows-11-avd' / 'windows-10-avd' / 'Windows-10' → 'Linux' (M365 covers licence)
                    #   'WindowsServer'  / 'WindowsServerHotpatching'       → 'Windows' (PAYG licence)
                    #   Empty string (custom or Shared Image Gallery image)  → fall back to the
                    #     config flag: Costs.PricingWindowsLicence in config.psd1 sets
                    #     $PricingWindowsFallback ($true = Windows PAYG, $false = Linux rate).
                    $_offer = $nfo['imageOffer']
                    $row.'_PricingOsType' = if     ($_offer -match 'Server')          { 'Windows' }
                                           elseif ($_offer -match 'avd|windows-1\d') { 'Linux'   }
                                           else   { if ($PricingWindowsFallback)      { 'Windows' } else { 'Linux' } }
                    $raw = $nfo['powerState']
                    $row.'Power State' = if ($raw -and $raw -ne 'PowerState/') {
                        $s = $raw -replace '^PowerState/', ''
                        $s.Substring(0,1).ToUpper() + $s.Substring(1)
                    } else { '-' }
                }
                # CPU Credits metric only exists for B-series burstable VMs.
                # Done outside the ContainsKey block so VMs not found in Resource Graph
                # (VM SKU stays '-') also get N/A rather than showing '-' indefinitely.
                if ($row.'VM SKU' -notlike 'Standard_B*') { $row.'CPU Credits' = 'N/A' }
            }
        } catch {
            $phase3Error = "Resource Graph enrichment failed: $_"
            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] ERROR [Phase3] $phase3Error`r`n") } catch {} }
        }
    }

    # ── Core return: emit Phase 1-3 data immediately ────────────────────────────
    # The grid renders as soon as this is returned to the UI thread. Phase 4 (Log
    # Analytics) and Phase 5 (Azure Monitor disk metrics) will backfill metric
    # columns a few seconds later via _SH_BackfillMetrics without clearing the table.
    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Core] Phases 1-3 complete. Returning $($vmRows.Count) row(s) to UI.`r`n") } catch {} }
    [PSCustomObject]@{
        Pass        = 'Core'
        VmRows      = @($vmRows | Sort-Object 'Host Pool', 'VM Name')
        Timestamp   = Get-Date
        Phase3Error = $phase3Error
    }
}

# =============================================================================
# 2b. Metrics background script (Pass 2 - backfill)
#
# Runs inside $script:vmMetricsRunspace (a second dedicated runspace).
# Launched by Invoke-SessionHostsMetricsRefresh immediately after the Core job
# completes. Receives $vmRows (already sorted) from the Core pass via
# SessionStateProxy.SetVariable() and stamps metric columns onto each row.
#
# Phases:
#   Phase 4  - Log Analytics: CPU %, Mem %, OS Disk %, Input Delay
#   Phase 5  - Azure Monitor: OS Disk IOPS, Queue Depth (batch or per-VM fallback)
#   Phase 5b - Azure Monitor: CPU Credits Remaining (B-series only, batch or per-VM)
#
# Variables injected via SessionStateProxy.SetVariable() before each BeginInvoke():
#   $vmRows                     - from Core pass (already sorted)
#   $ArmToken, $SubId           - auth / subscription
#   $HpPool                     - RunspacePool for parallel sub-calls
#   $RestHelperDef, $LogFile    - helper def + logging path
#   $LawWorkspaceResourceId     - LAW workspace ARM resource ID ('' = skip Phase 4)
#   $LawHeatMapAmberPct/RedPct  - heat map thresholds for CPU/Mem/Disk %
#   $ShowCPU, $ShowMem, $ShowDisk, $ShowInputDelay - which LAW columns to populate
#   $LawInputDelayAmberMs/RedMs - heat map thresholds for Input Delay
#   $InputDelayExcludeProcesses - process names to exclude from Input Delay KQL
#   $ShowDiskPerf               - whether Phase 5 runs at all
#   $DiskQueueAmberVal/RedVal   - heat map thresholds for Disk Queue column
#   $metricsRegionalBatchFailed - shared hashtable: region -> $true on DNS failure
#
# Return: [PSCustomObject]@{ Pass='Metrics'; MetricRows=...; Phase4Error=...;
#                             Phase5Error=...; Phase5Mode=...; Timestamp=... }
# =============================================================================

$script:vmMetricsScript = {

    # ── Phase 4 pre-launch: Log Analytics query ──────────────────────────────────
    # Fired immediately at the start of this script so it runs concurrently while
    # Phase 5 disk metrics batch calls are being built and dispatched below.
    # Phase 4's only input is a list of Available VM names - already in $vmRows
    # from the Core pass. By the time Phase 5 collects its batch results, Phase 4
    # is usually already done and EndInvoke returns immediately (zero extra wait).
    #
    # NOTE: The old overlap was Phase 4 concurrent with Phase 3. With the two-pass
    # split, Phase 3 runs before this script starts - but the win is still valid:
    # Phase 4 now overlaps with Phase 5's batch HTTP calls instead.
    # ──────────────────────────────────────────────────────────────────────────────
    #
    # HOW THE BACKGROUND SCRIPTBLOCK WORKS
    # --------------------------------------
    # $lawBgScript is injected with $RestHelperDef so it has access to Invoke-Arm.
    # It receives 4 args: ARM token, workspace resource ID, pre-built body hashtable,
    # and log file path. The KQL body is built here on the main thread (variable
    # expansion happens now via the here-string) so the background script only needs
    # to POST the already-complete JSON payload - no string interpolation in runspace.
    #
    # The background script returns [PSCustomObject]@{ LawMap = $lawMap; Error = '' }.
    # LawMap is a flat hashtable:  { 'vmshortname' -> { 'CPU' -> '42.3', ... } }
    # A flat hashtable serialises reliably across the runspace boundary. The raw
    # Invoke-Arm response (a nested deserialized PSObject) does NOT reliably round-
    # trip across runspace boundaries in PS5.1 - extracting just the values we need
    # into a plain hashtable avoids that pitfall entirely.
    # ──────────────────────────────────────────────────────────────────────────────
    $phase4Handle = $null; $phase4PS = $null; $phase4Error = $null

    # Collect Available VM short-names now (Phase 2 data is complete).
    # ToLower() ensures names match the KQL ComputerShort extend (which also lowercases).
    $availVmNamesEarly = @($vmRows | Where-Object { $_.'Power State' -eq 'Running' } |
        ForEach-Object { $_.'VM Name'.ToLower() })

    if ($LawWorkspaceResourceId -and $availVmNamesEarly.Count -gt 0 -and
        ($ShowCPU -or $ShowMem -or $ShowDisk -or $ShowInputDelay)) {
        if ($LogFile) {
            try {
                [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] Pre-launching alongside Phase 5: $($availVmNamesEarly.Count) Running VM(s): $($availVmNamesEarly -join ', ')`r`n")
                $excludedVms = @($vmRows | Where-Object { $_.'Power State' -ne 'Running' } | ForEach-Object { "$($_.'VM Name')[$($_.'Power State')]" })
                if ($excludedVms.Count -gt 0) {
                    [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] Excluded from LAW query (not Running): $($excludedVms -join ', ')`r`n")
                }
            } catch {}
        }

        # Build the VM name list as a KQL dynamic([...]) literal.
        # Names are single-quoted inside the array so KQL treats them as strings.
        $vmListKqlEarly = ($availVmNamesEarly | ForEach-Object { "'$_'" }) -join ','

        # Build the optional Input Delay process-exclusion filter.
        # InstanceName for Input Delay counters is "SessionId:PID <ProcessName>",
        # so 'has_any' is used for a case-insensitive substring match on the process name.
        # If the config list is empty this variable stays blank and the KQL line is a no-op.
        $inputDelayExcludeKqlEarly = ''
        if ($InputDelayExcludeProcesses -and $InputDelayExcludeProcesses.Count -gt 0) {
            $exList = ($InputDelayExcludeProcesses | ForEach-Object { "`"$_`"" }) -join ', '
            $inputDelayExcludeKqlEarly = "| where not(InstanceName has_any ($exList))"
        }

        # Build the full KQL query string here on the main thread.
        # All PowerShell variables ($vmListKqlEarly, $inputDelayExcludeKqlEarly) are
        # expanded now via the double-quoted here-string - the background runspace
        # receives only the final string so it needs no access to PS variables.
        #
        # KQL design notes:
        #   perfMetrics sub-query:
        #     - ObjectName covers both MMA ("Processor") and AMA ("Processor Information")
        #       agents so the query works regardless of which monitoring agent is deployed.
        #     - InstanceName "_Total" is the aggregate across all cores - the right value
        #       to display as a single CPU % figure.
        #     - arg_max(TimeGenerated, CounterValue) returns the LATEST single sample per
        #       counter per host, keeping the column consistent with "current state".
        #     - "% Free Space" is inverted to "% Used" in the background scriptblock
        #       (100 - freeSpace) so the column reads as disk utilisation, not free space.
        #
        #   inputDelay sub-query:
        #     - Uses a 1-hour window (vs 15 min for CPU/Mem/Disk) so there are enough
        #       samples to make the P95 percentile meaningful.
        #     - CounterValue capped at 10,000 ms to exclude measurement anomalies
        #       (e.g. LapsView.exe has been seen reporting 549,047 ms).
        #     - InstanceName !in ("Max","Average") excludes the synthetic aggregate rows
        #       that LAW inserts - we want the per-process raw samples only.
        $lawKqlEarly = @"
let vms = dynamic([$vmListKqlEarly]);
// CPU, Memory, Disk: most-recent single sample per counter per host
let perfMetrics = Perf
| where TimeGenerated > ago(15m)
| where (ObjectName in ("Processor", "Processor Information") and CounterName == "% Processor Time" and InstanceName == "_Total")
   or   (ObjectName == "Memory"       and CounterName == "% Committed Bytes In Use")
   or   (ObjectName == "LogicalDisk"  and CounterName == "% Free Space" and InstanceName == "C:")
| extend ComputerShort = tolower(split(Computer, '.')[0])
| where ComputerShort in (vms)
| summarize arg_max(TimeGenerated, CounterValue) by ComputerShort, CounterName
| project Computer = ComputerShort, CounterName, Value = round(CounterValue, 1);
// Input Delay: P50 median and P95 across all 30-second samples in the last hour
let inputDelay = Perf
| where TimeGenerated > ago(1h)
| where ObjectName == "User Input Delay per Process"
| where CounterName == "Max Input Delay"
| where InstanceName !in ("Max", "Average")
$inputDelayExcludeKqlEarly
| where CounterValue > 0 and CounterValue < 10000  // cap at 10s - anomalies (e.g. LapsView.exe) can report >500,000ms
| extend ComputerShort = tolower(split(Computer, '.')[0])
| where ComputerShort in (vms)
| summarize MedianDelay = round(percentile(CounterValue, 50), 0),
            P95Delay = round(percentile(CounterValue, 95), 0)
         by Computer = ComputerShort;
let inputDelayAvg = inputDelay | project Computer, CounterName = "Input Delay", Value = MedianDelay;
let inputDelayP95 = inputDelay | project Computer, CounterName = "Input Delay P95", Value = P95Delay;
// Union all metrics into a single table for one API call
perfMetrics | union (inputDelayAvg) | union (inputDelayP95)
"@
        # NOTE: the body hashtable is NOT pre-built here as a $lawBodyEarly variable.
        # Hashtables passed as arguments across runspace boundaries are deserialized as
        # PSObjects in the receiving runspace. ConvertTo-Json inside Invoke-Arm may not
        # produce the correct JSON from a deserialized hashtable in PS5.1.
        # Instead we pass the raw KQL string and let the scriptblock build the body
        # hashtable natively inside the pool runspace where it is a proper [hashtable].

        # Build the background scriptblock by prepending $RestHelperDef so the runspace
        # has access to the Invoke-Arm helper function (which is not imported by default).
        # Using [scriptblock]::Create() rather than a literal { } block allows the
        # $RestHelperDef string to be concatenated at runtime.
        #
        # The scriptblock receives 4 plain-string args: ARM token, workspace resource ID,
        # the KQL query string, and log file path. Strings survive runspace serialisation
        # perfectly. The body hashtable is built fresh inside the runspace.
        #
        # The scriptblock:
        #   1. Builds the POST body from the KQL string and POSTs to the LAW query API.
        #   2. Parses the columnar JSON response: { tables:[{ columns:[...], rows:[[...]] }] }
        #      Column indices are located by name (case-insensitive) so column-order changes
        #      in a future API version will not break the mapping.
        #   3. Builds $lawMap: { vmShortName -> { 'CPU'->'42.3', 'Mem'->'61.0', ... } }
        #      Note: % Free Space is converted to % Used (100 - val) so the UI shows
        #      disk utilisation rather than free space.
        #   4. Returns [PSCustomObject]@{ LawMap = $lawMap; Error = '' }
        #      A plain hashtable is used because nested deserialized PSObjects from
        #      Invoke-Arm do not reliably round-trip across runspace boundaries in PS5.1.
        $lawBgScript = [scriptblock]::Create($RestHelperDef + @'
            $tok = $args[0]; $wsId = $args[1]; $kql = $args[2]; $logFile = $args[3]
            $lawQueryBaseUrl = [string]$args[4]; $lawTok = [string]$args[5]
            # Build the body hashtable here (not passed as arg) so it is a proper
            # [hashtable] in this runspace - avoids PS5.1 deserialization issues.
            $body = @{ query = $kql; timespan = 'PT1H' }
            $lawMap = @{}
            try {
                if ($lawQueryBaseUrl -and $lawTok) {
                    $resp = Invoke-RestMethod -Method POST -Uri "$lawQueryBaseUrl/v1$wsId/query" `
                        -Body (ConvertTo-Json $body -Compress) `
                        -Headers @{ Authorization = "Bearer $lawTok"; 'Content-Type' = 'application/json' }
                } else {
                    $resp = Invoke-Arm -Method POST -Path "$wsId/api/query" -Token $tok -ApiVersion '2020-08-01' -Body $body -FullResponse
                }
                if ($resp -and $resp.tables -and $resp.tables[0].rows) {
                    # Locate columns by name - handles .name (PS7) and .ColumnName (PS5.1 DataTable)
                    $cols      = @($resp.tables[0].columns | ForEach-Object { $n = [string]$_.name; if (-not $n) { $n = [string]$_.ColumnName }; if (-not $n) { $n = [string]$_ }; $n })
                    $colsLower = @($cols | ForEach-Object { $_.ToLower() })
                    $idxComp   = [array]::IndexOf($colsLower, 'computer')
                    $idxCtr    = [array]::IndexOf($colsLower, 'countername')
                    $idxVal    = [array]::IndexOf($colsLower, 'value')
                    foreach ($r in $resp.tables[0].rows) {
                        $comp = [string]$r[$idxComp]; $ctr = [string]$r[$idxCtr]; $val = [string]$r[$idxVal]
                        if (-not $lawMap.ContainsKey($comp)) { $lawMap[$comp] = @{} }
                        # Match counter by substring so minor naming variants don't break the mapping
                        if     ($ctr -like '*Processor Time*')  { $lawMap[$comp]['CPU']          = $val }
                        elseif ($ctr -like '*Committed Bytes*') { $lawMap[$comp]['Mem']          = $val }
                        elseif ($ctr -like '*Free Space*')      { $lawMap[$comp]['Disk']         = [string][math]::Round(100 - [double]$val, 1) } # invert: free -> used
                        elseif ($ctr -eq   'Input Delay')       { $lawMap[$comp]['InputDelay']   = $val }
                        elseif ($ctr -eq   'Input Delay P95')   { $lawMap[$comp]['InputDelayP95']= $val }
                    }
                    if ($logFile) {
                        $rowCount    = $resp.tables[0].rows.Count
                        $sampleCtrs  = ($resp.tables[0].rows | ForEach-Object { [string]$_[$idxCtr] } | Sort-Object -Unique | Select-Object -First 8) -join ', '
                        $sampleComps = ($resp.tables[0].rows | ForEach-Object { [string]$_[$idxComp] } | Sort-Object -Unique | Select-Object -First 3) -join ', '
                        try { [IO.File]::AppendAllText($logFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] LAW rows=$rowCount matched=$($lawMap.Count) counters=[$sampleCtrs] computers=[$sampleComps]`r`n") } catch {}
                    }
                } else {
                    if ($logFile) { try { [IO.File]::AppendAllText($logFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] LAW returned 0 rows (no Perf data in workspace for queried VMs/timespan)`r`n") } catch {} }
                    # Probe: check if ANY Perf data exists in this workspace at all (no computer filter)
                    # This distinguishes "DCR not routing to this workspace" from "computer name mismatch"
                    try {
                        $probeKql = 'Perf | where TimeGenerated > ago(1h) | summarize Count=count() by Computer | order by Count desc | take 5'
                        $probeBody = @{ query = $probeKql; timespan = 'PT1H' }
                        $probeBodyJson = ConvertTo-Json $probeBody -Compress
                        if ($lawQueryBaseUrl -and $lawTok) {
                            $probeResp = Invoke-RestMethod -Method POST -Uri "$lawQueryBaseUrl/v1$wsId/query" `
                                -Body $probeBodyJson `
                                -Headers @{ Authorization = "Bearer $lawTok"; 'Content-Type' = 'application/json' }
                        } else {
                            $probeResp = Invoke-Arm -Method POST -Path "$wsId/api/query" -Token $tok -ApiVersion '2020-08-01' -Body $probeBody -FullResponse
                        }
                        if ($probeResp -and $probeResp.tables -and $probeResp.tables[0].rows -and $probeResp.tables[0].rows.Count -gt 0) {
                            $probeCols  = @($probeResp.tables[0].columns | ForEach-Object { $n = [string]$_.name; if (-not $n) { $n = [string]$_.ColumnName }; $n })
                            $idxPC      = [array]::IndexOf(($probeCols | ForEach-Object { $_.ToLower() }), 'computer')
                            $idxCount   = [array]::IndexOf(($probeCols | ForEach-Object { $_.ToLower() }), 'count')
                            $probeComps = ($probeResp.tables[0].rows | ForEach-Object { "$([string]$_[$idxPC])($([string]$_[$idxCount]))" }) -join ', '
                            if ($logFile) { try { [IO.File]::AppendAllText($logFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4-Probe] Workspace HAS Perf data - top computers: $probeComps`r`n") } catch {} }
                        } else {
                            if ($logFile) { try { [IO.File]::AppendAllText($logFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4-Probe] Workspace has NO Perf data at all in last 1h - DCR not routing counters to this workspace`r`n") } catch {} }
                        }
                    } catch {
                        if ($logFile) { try { [IO.File]::AppendAllText($logFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4-Probe] Probe query failed: $_`r`n") } catch {} }
                    }
                }
                if ($logFile) { try { [IO.File]::AppendAllText($logFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] LAW done in background: $($lawMap.Count) VM(s) matched`r`n") } catch {} }
            } catch {
                if ($logFile) { try { [IO.File]::AppendAllText($logFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] ERROR in background: $_`r`n") } catch {} }
                return [PSCustomObject]@{ LawMap = @{}; Error = [string]$_ }
            }
            return [PSCustomObject]@{ LawMap = $lawMap; Error = '' }
'@)
        # Create a new PowerShell instance and assign it to the shared runspace pool.
        # HpPool is a RunspacePool sized by $RunspaceMaxHpPool (default 10). Phase 5
        # also uses this pool for per-VM metrics calls, but those fire later, so there
        # is no contention risk from this single pre-launch call.
        $phase4PS = [System.Management.Automation.PowerShell]::Create()
        $phase4PS.RunspacePool = $HpPool
        $lawTokEarly = if ($LawQueryBaseUrl) { $LawToken } else { '' }
        [void]$phase4PS.AddScript($lawBgScript).AddArgument($ArmToken).AddArgument($LawWorkspaceResourceId).AddArgument($lawKqlEarly).AddArgument([string]$LogFile).AddArgument([string]$LawQueryBaseUrl).AddArgument($lawTokEarly)
        # BeginInvoke starts execution immediately and returns a handle.
        # The handle is passed to EndInvoke after Phase 3 completes (see Phase 4 collect below).
        $phase4Handle = $phase4PS.BeginInvoke()
    } elseif ($LawWorkspaceResourceId -and $availVmNamesEarly.Count -eq 0) {
        if ($LogFile) {
            $distinctStatuses = ($vmRows | ForEach-Object { $_.'Status' } | Sort-Object -Unique) -join ', '
            try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] Skipped - no Available VMs. Statuses in vmRows ($($vmRows.Count) rows): $distinctStatuses`r`n") } catch {}
        }
    } elseif ($LawWorkspaceResourceId -and -not ($ShowCPU -or $ShowMem -or $ShowDisk -or $ShowInputDelay)) {
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] Skipped - all LAW columns hidden`r`n") } catch {} }
    } else {
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] Skipped - no WorkspaceResourceId configured`r`n") } catch {} }
    }


    # ── Phase 4: Collect Log Analytics result (pre-launched at start of Metrics script) ──
    #
    # The Log Analytics query was fired as a non-blocking BeginInvoke at the top of
    # this script. Now that Phase 5's batch calls have been dispatched (and are in
    # flight), we collect the Phase 4 result via EndInvoke before the Phase 5 collect
    # loop - in most environments the LAW call has already completed by this point.
    #
    # EndInvoke semantics:
    #   - If the background job is still running: blocks until it finishes.
    #   - If the background job has already finished: returns immediately.
    #   In the common case the LAW call finishes while Phase 5 batches are running
    #   and EndInvoke returns in microseconds.
    #
    # $lawResult is the pipeline output of the background scriptblock - an array where
    # $lawResult[0] is the [PSCustomObject]@{ LawMap = ...; Error = '' } the script
    # returned. $lawResult[0].LawMap is a hashtable keyed by lowercase VM short-name:
    #   { 'vm001' -> { 'CPU' -> '42.3', 'Mem' -> '61.0', 'Disk' -> '44.2',
    #                  'InputDelay' -> '12', 'InputDelayP95' -> '87' } }
    # Not all keys are present in every inner hashtable - only counters that had data
    # in the LAW response are populated. The null checks below guard against this.
    #
    # $phase4Handle is $null when Phase 4 was skipped (no LAW workspace configured,
    # no Available VMs, or all LAW columns hidden) - the if block is a no-op in that case.
    # ──────────────────────────────────────────────────────────────────────────────
    if ($phase4Handle) {
        try {
            $lawResult = $phase4PS.EndInvoke($phase4Handle)
            $bgLawMap  = if ($lawResult -and $lawResult[0]) { $lawResult[0].LawMap } else { @{} }
            if ($LogFile) {
                try {
                    $bgErr = if ($lawResult -and $lawResult[0]) { [string]$lawResult[0].Error } else { '(no result)' }
                    [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] EndInvoke: mapCount=$($bgLawMap.Count) error='$bgErr'`r`n")
                    foreach ($vmKey in ($bgLawMap.Keys | Sort-Object)) {
                        $m    = $bgLawMap[$vmKey]
                        $vals = @()
                        if ($m -and $m['CPU'])          { $vals += "CPU=$($m['CPU'])%" }          else { $vals += 'CPU=-' }
                        if ($m -and $m['Mem'])          { $vals += "Mem=$($m['Mem'])%" }          else { $vals += 'Mem=-' }
                        if ($m -and $m['Disk'])         { $vals += "Disk=$($m['Disk'])%" }        else { $vals += 'Disk=-' }
                        if ($m -and $m['InputDelay'])   { $vals += "ID=$($m['InputDelay'])ms" }   else { $vals += 'ID=-' }
                        if ($m -and $m['InputDelayP95']){ $vals += "P95=$($m['InputDelayP95'])ms"} else { $vals += 'P95=-' }
                        [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4]   ${vmKey}: $($vals -join ' ')`r`n")
                    }
                } catch {}
            }

            # Surface any error reported by the background job (e.g. HTTP 403, bad workspace ID)
            if ($lawResult -and $lawResult[0].Error) {
                $phase4Error = $lawResult[0].Error
                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] ERROR [Phase4] $phase4Error`r`n") } catch {} }
            }

            if ($bgLawMap -and $bgLawMap.Count -gt 0) {
                # Stamp CPU %, Mem %, OS Disk %, and Input Delay onto matching rows.
                #
                # Hidden helper columns (_CPUColor, _MemColor, _DiskColor, _InputDelayColor):
                #   Written as 'Red', 'Amber', or 'Green'. The AutoGeneratingColumn handler
                #   wires up WPF CellStyle DataTriggers that read these columns to apply
                #   background colours without exposing the helper columns in the grid UI.
                #
                # Sort helper columns (_CPUSort, _MemSort, etc.):
                #   Store the raw numeric value so the DataGrid can sort the column
                #   numerically rather than lexicographically (e.g. "9%" sorts before "10%").
                #
                # $ShowCPU / $ShowMem / $ShowDisk / $ShowInputDelay come from config.
                # Columns that are hidden in config are not stamped - they stay at '-'.
                foreach ($row in $vmRows) {
                    $vn = $row.'VM Name'.ToLower()
                    if ($bgLawMap.ContainsKey($vn)) {
                        if ($ShowCPU -and $null -ne $bgLawMap[$vn]['CPU']) {
                            $cpuPct = [double]$bgLawMap[$vn]['CPU']
                            $row.'CPU %'     = "$($bgLawMap[$vn]['CPU'])%"
                            $row.'_CPUSort'  = $cpuPct
                            $row.'_CPUColor' = if ($cpuPct -ge $LawHeatMapRedPct) { 'Red' } elseif ($cpuPct -ge $LawHeatMapAmberPct) { 'Amber' } else { 'Green' }
                        }
                        if ($ShowMem -and $null -ne $bgLawMap[$vn]['Mem']) {
                            $memPct = [double]$bgLawMap[$vn]['Mem']
                            $row.'Mem %'     = "$($bgLawMap[$vn]['Mem'])%"
                            $row.'_MemSort'  = $memPct
                            $row.'_MemColor' = if ($memPct -ge $LawHeatMapRedPct) { 'Red' } elseif ($memPct -ge $LawHeatMapAmberPct) { 'Amber' } else { 'Green' }
                        }
                        if ($ShowDisk -and $null -ne $bgLawMap[$vn]['Disk']) {
                            # Disk value is already converted from % Free to % Used in the background scriptblock
                            $diskPct = [double]$bgLawMap[$vn]['Disk']
                            $row.'OS Disk %'  = "$($bgLawMap[$vn]['Disk'])%"
                            $row.'_DiskSort'  = $diskPct
                            $row.'_DiskColor' = if ($diskPct -ge $LawHeatMapRedPct) { 'Red' } elseif ($diskPct -ge $LawHeatMapAmberPct) { 'Amber' } else { 'Green' }
                        }
                        # Input Delay Median: P50 across all per-process samples on this host in the last 1 hour.
                        # Represents the typical worst-case keystroke delay experienced by users on this host.
                        if ($ShowInputDelay -and $null -ne $bgLawMap[$vn]['InputDelay']) {
                            $delayMs = [double]$bgLawMap[$vn]['InputDelay']
                            $row.'Input Delay Median'  = "${delayMs}ms"
                            $row.'_InputDelaySort'     = $delayMs
                            $row.'_InputDelayColor'    = if ($delayMs -ge $LawInputDelayRedMs) { 'Red' } elseif ($delayMs -ge $LawInputDelayAmberMs) { 'Amber' } else { 'Green' }
                        }
                        # Input Delay P95: 95th percentile - the worst-case delay experienced by the
                        # top 5% of samples. High P95 with low median indicates occasional severe spikes.
                        # Uses the same amber/red thresholds as the median column.
                        if ($ShowInputDelay -and $null -ne $bgLawMap[$vn]['InputDelayP95']) {
                            $delayP95 = [double]$bgLawMap[$vn]['InputDelayP95']
                            $row.'Input Delay P95'     = "${delayP95}ms"
                            $row.'_InputDelayP95Sort'  = $delayP95
                            $row.'_InputDelayP95Color' = if ($delayP95 -ge $LawInputDelayRedMs) { 'Red' } elseif ($delayP95 -ge $LawInputDelayAmberMs) { 'Amber' } else { 'Green' }
                        }
                    }
                }
                if ($LogFile) {
                    try {
                        $matched   = @($availVmNamesEarly | Where-Object { $bgLawMap.ContainsKey($_) })
                        $unmatched = @($availVmNamesEarly | Where-Object { -not $bgLawMap.ContainsKey($_) })
                        [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase4] VM match: $($matched.Count)/$($availVmNamesEarly.Count) matched. Unmatched: $(if ($unmatched.Count -eq 0) { 'none' } else { $unmatched -join ', ' })`r`n")
                    } catch {}
                }
            }
        } catch {
            # Catch-all: LAW failure must never prevent Phase 1-3 data from rendering.
            # $phase4Error is surfaced in the status bar but does not abort the refresh.
            $phase4Error = "Log Analytics enrichment failed: $_"
            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] ERROR [Phase4] $phase4Error`r`n") } catch {} }
        } finally {
            # Always dispose the PowerShell instance to release the runspace pool slot,
            # even if EndInvoke threw. Without this the pool thread leaks until GC runs.
            try { $phase4PS.Dispose() } catch {}
        }
    }

    # ── Phase 5: Azure Monitor Metrics enrichment (OS Disk IOPS + Queue Depth) ──
    #
    # PURPOSE
    # -------
    # Fetches OS Disk performance data for each Available session host VM from the
    # Azure Monitor Metrics REST API. This is a PLATFORM-LEVEL metric - it comes
    # from the Azure hypervisor, NOT from a guest agent (MMA/AMA) or Log Analytics.
    # This means it works on every VM regardless of LAW configuration.
    #
    # WHY THE VM RESOURCE (NOT THE DISK RESOURCE)?
    # ---------------------------------------------
    # Azure exposes disk metrics in two places:
    #   1. The Managed Disk resource  (Microsoft.Compute/disks)
    #      - Only has: Disk Read/Write Bytes/sec, Disk Read/Write Operations/sec
    #      - These are the metrics visible in Azure Portal > Disk > Monitoring
    #   2. The Virtual Machine resource  (Microsoft.Compute/virtualMachines)
    #      - Has "OS Disk" prefixed metrics that isolate the C: drive:
    #        OS Disk Read Operations/Sec, OS Disk Write Operations/Sec,
    #        OS Disk Queue Depth, OS Disk Bandwidth Consumed Percentage, etc.
    #      - These are visible in Azure Portal > VM > Monitoring > Metrics
    #
    # We query the VM resource (option 2) because:
    #   a) We already have the VM resource ID from the AVD session host properties
    #   b) It gives us OS Disk Queue Depth which is not available on the disk resource
    #   c) The "OS Disk" prefix isolates the C: drive from any data disks
    #
    # API ENDPOINT (Regional Batch)
    # ------------------------------
    # POST https://{region}.metrics.monitor.azure.com/subscriptions/{subId}/metrics:getBatch
    #      ?api-version=2024-02-01
    # Body: { "resourceids": [...VM ARM IDs (same region only)...],
    #         "metricnames": "OS Disk Read Operations/Sec,...",
    #         "timespan": "{startTime}/{endTime}",
    #         "interval": "PT1M", "aggregation": "Average" }
    # Max 50 resource IDs per call; all VMs must be in the same region.
    # Response top-level key is "values" (plural), unlike single-resource "value".
    #
    # METRICS EXPLAINED
    # -----------------
    # OS Disk Read Operations/Sec  - Number of read I/O operations per second on the OS disk.
    #                                 Sourced from the Azure hypervisor (platform metric).
    # OS Disk Write Operations/Sec - Number of write I/O operations per second on the OS disk.
    #                                 Sourced from the Azure hypervisor (platform metric).
    # OS Disk Queue Depth          - Number of I/O requests waiting to be processed by the OS disk.
    #                                 A sustained value > 1 indicates the disk may be saturated.
    #                                 Sourced from the Azure hypervisor (platform metric).
    #
    # HOW VALUES ARE CALCULATED
    # -------------------------
    # - We request a 5-minute window with 1-minute granularity (PT1M interval)
    # - Each 1-minute bucket contains the Average value over that minute
    # - We take the LATEST non-null data point (the most recent 1-minute average)
    # - Disk IOPS = Read Ops/Sec + Write Ops/Sec (combined into one number)
    # - Disk Queue = raw queue depth value (0 = healthy, 2+ = pressure, 5+ = bottleneck)
    #
    # PERFORMANCE - BATCH API
    # -----------------------
    # Azure Monitor exposes a Batch Metrics API that accepts up to 50 resource IDs per
    # POST call, returning metrics for all of them in one response. We use this instead
    # of one GET per VM, which dramatically reduces HTTP round-trips:
    #
    #   Batch API endpoint (regional - VMs must be grouped by region):
    #   POST https://{region}.metrics.monitor.azure.com/subscriptions/{subId}/metrics:getBatch
    #        ?api-version=2024-02-01
    #
    #   Body: { "resourceids": [...up to 50 VM ARM IDs...],
    #           "metricnames": "OS Disk Read Operations/Sec,...",
    #           "timespan": "{start}/{end}", "interval": "PT1M", "aggregation": "Average" }
    #
    #   Response: { "values": [ { "resourceid": "...", "values": [...metrics...] } ] }
    #   Note: outer key is "values" (plural), unlike the single-resource API's "value".
    #
    # With 50 VMs per batch call:
    #   50 VMs  =  1 HTTP call  (was 50)
    #  100 VMs  =  2 HTTP calls (was 100)
    #  500 VMs  = 10 HTTP calls (was 500)
    #
    # All batch calls are fired in parallel via $HpPool, so for 500 VMs we wait for
    # whichever of the 10 batch calls is slowest (~200-400ms each) rather than waiting
    # for 500 serial-per-thread calls. Total Phase 5 time drops from ~10s to ~1-2s.
    #
    # FAILURE HANDLING
    # ----------------
    # - Entire Phase 5 is wrapped in try/catch - failures never block Phases 1-4
    # - Individual batch failures silently skip those 50 VMs (rows stay as '-')
    # - Deallocated VMs are skipped entirely (no metrics available when not running)
    # =============================================================================
    $phase5Error           = $null
    $phase5BatchRegions    = [System.Collections.Generic.List[string]]::new()   # regions that used batch API successfully
    $phase5FallbackRegions = [System.Collections.Generic.List[string]]::new()   # regions that fell back to per-VM
    if ($ShowDiskPerf) {
        try {
            # Only query VMs that are actually running (Available) and have a resource ID.
            # Deallocated/stopped VMs have no platform metrics to report.
            $availRows = @($vmRows | Where-Object { $_.'Power State' -eq 'Running' -and $_.'_VMResourceId' })
            if ($availRows.Count -gt 0) {
                # Build ISO 8601 start/end times for the API query window.
                # The regional batch API uses separate starttime/endtime query params.
                # We look back 5 minutes to ensure at least a few 1-minute data points exist.
                $endDt     = [datetime]::UtcNow
                $startDt   = $endDt.AddMinutes(-5)
                $startTime = $startDt.ToString('yyyy-MM-ddTHH:mm:ssZ')
                $endTime   = $endDt.ToString('yyyy-MM-ddTHH:mm:ssZ')

                # ── Timespan variants ───────────────────────────────────────────────
                # Two formats are needed because the two API paths use different conventions:
                #
                #   Regional batch API  - separate starttime= and endtime= query params
                #                         (already in $startTime / $endTime above)
                #
                #   Single-resource API - combined "start/end" timespan query param
                #                         used by the per-VM fallback path below
                $combinedTs = "$startTime/$endTime"

                # URL-encoded metric name string for the single-resource per-VM API.
                # The single-resource API receives metric names as a query string parameter,
                # so spaces and slashes must be percent-encoded.
                # The batch API receives metric names in a JSON body field, so no encoding needed there
                # (it is hardcoded inside $batchScript).
                $metricNamesEncoded = [uri]::EscapeDataString('OS Disk Read Operations/Sec,OS Disk Write Operations/Sec,OS Disk Queue Depth')

                # Metric names and namespace are hardcoded inside $batchScript to avoid
                # PS5.1 cross-runspace deserialisation dropping trailing array arguments.

                # ── Scriptblock for each parallel BATCH query ───────────────────────
                # One instance of this runs per batch of up to 50 VMs (not per VM).
                # It prepends $RestHelperDef so Invoke-Arm is available inside the
                # RunspacePool thread. Because of the prepend pattern we CANNOT use
                # param() - must use $args[N] instead.
                #
                # The Batch API request body:
                #   {
                #     "resourceids": ["/subscriptions/.../virtualMachines/vm1", ...],
                #     "metricnames": "OS Disk Read Operations/Sec,...",
                #     "timespan":    "2024-01-01T00:00:00Z/2024-01-01T00:05:00Z",
                #     "interval":    "PT1M",
                #     "aggregation": "Average"
                #   }
                #
                # The Batch API response structure:
                #   {
                #     "values": [                          // NOTE: plural "values", not "value"
                #       {
                #         "resourceid": "/subscriptions/.../virtualMachines/vm1",  // lowercase
                #         "values": [                      // one entry per requested metric
                #           {
                #             "name": { "value": "OS Disk Read Operations/Sec" },
                #             "timeseries": [
                #               { "data": [ { "timeStamp": "...", "average": 42.5 }, ... ] }
                #             ]
                #           },
                #           ...
                #         ]
                #       },
                #       ...
                #     ]
                #   }
                #
                # Key difference vs single-resource API:
                #   Single: resp.value[].name.value   (outer key = "value", singular)
                #   Batch:  resp.values[].values[]    (outer key = "values", plural)
                #           resp.values[].resourceid  (lowercase, used to map back to rows)
                $batchScript = [scriptblock]::Create($RestHelperDef + @'
                    $tok = $args[0]; $url = $args[1]; $resourceIds = $args[2]
                    $startTime = $args[3]; $endTime = $args[4]; $LogFile = $args[5]
                    # Regional Batch API query parameters - NOT body fields:
                    #   metricnamespace, metricnames, starttime, endtime, interval, aggregation
                    # Only the resource IDs go in the POST body.
                    # Full URL is built here so Invoke-Arm passes it through unchanged.
                    $ns  = [uri]::EscapeDataString('Microsoft.Compute/virtualMachines')
                    $mn  = [uri]::EscapeDataString('OS Disk Read Operations/Sec,OS Disk Write Operations/Sec,OS Disk Queue Depth')
                    $fullUrl = "$url`?api-version=2023-10-01&metricnamespace=$ns&metricnames=$mn&starttime=$startTime&endtime=$endTime&interval=PT1M&aggregation=Average"

                    # Only resourceids belongs in the POST body for this API
                    $body = @{ resourceids = $resourceIds }
                    try {
                        # Pass full URL as Path - Invoke-Arm detects https:// prefix and skips
                        # prepending management.azure.com. No -ApiVersion needed (already in URL).
                        Invoke-Arm -Method POST -Path $fullUrl `
                            -Token $tok -Body $body -FullResponse
                    } catch {
                        # Invoke-Arm logged the HTTP status code. Also read the response body
                        # for the detailed Azure error message (e.g. which field is invalid).
                        if ($LogFile) {
                            try {
                                $errBody = $null
                                if ($_.Exception.Response) {
                                    $stream = $_.Exception.Response.GetResponseStream()
                                    $stream.Position = 0
                                    $errBody = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
                                }
                                if ($errBody) {
                                    [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] Batch error body: $errBody`r`n")
                                }
                            } catch {}
                        }
                        # Write to the PS error stream so the collect loop can inspect
                        # $bh.PS.HadErrors and $bh.PS.Streams.Error to detect DNS failures.
                        # Without this, swallowing the exception here means HadErrors stays
                        # false and the DNS fallback logic in the caller never fires.
                        Write-Error $_
                        $null
                    }
'@)

                # ── Scriptblock for per-VM fallback (used when batch DNS fails) ────────
                # WHY THIS EXISTS
                # ---------------
                # The regional batch endpoint (https://{region}.metrics.monitor.azure.com)
                # is NOT covered by Azure Monitor Private Link Scope (AMPLS). AMPLS creates
                # private DNS records for exactly 5 zones (privatelink.monitor.azure.com,
                # privatelink.oms.opinsights.azure.com, etc.) but none of them include
                # *.metrics.monitor.azure.com. This is documented at:
                #   https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns
                #
                # In Private Link environments the DNS query for
                # "{region}.metrics.monitor.azure.com" fails with NameResolutionFailure.
                # The single-resource GET API routes through management.azure.com which
                # DOES have a private endpoint in AMPLS-enabled environments, so it works.
                #
                # This scriptblock is identical in structure to the original Phase 5 per-VM
                # approach before the batch API was introduced. It is only fired for regions
                # where the batch DNS lookup failed. If Microsoft later adds AMPLS support
                # for the metrics batch endpoint, this fallback will simply never be used.
                #
                # API: GET {vmResourceId}/providers/microsoft.insights/metrics
                #          ?metricnames=...&timespan=start/end&interval=PT1M&aggregation=Average
                #          &api-version=2024-02-01
                #
                # Response: { "value": [ { "name": { "value": "metricName" },
                #                          "timeseries": [ { "data": [ { "average": N } ] } ] } ] }
                # Note: single-resource API uses "value" (singular), not "values" (plural).
                $vmScript = [scriptblock]::Create($RestHelperDef + @'
                    $tok = $args[0]; $vmId = $args[1]; $ts = $args[2]; $metricNames = $args[3]; $LogFile = $args[4]
                    # $ts is the combined "startTime/endTime" timespan string (single-resource API format)
                    # $metricNames is URL-encoded comma-separated metric names (query string format)
                    $qs = "metricnames=$metricNames&timespan=$ts&interval=PT1M&aggregation=Average"
                    try {
                        Invoke-Arm -Path "$vmId/providers/microsoft.insights/metrics?$qs" `
                            -Token $tok -ApiVersion '2024-02-01' -FullResponse
                    } catch { $null }
'@)

                # ── Group by region, then slice each region into batches of 50 ────────
                # The Batch Metrics API is region-scoped:
                #   POST https://{region}.metrics.monitor.azure.com/subscriptions/{subId}/metrics:getBatch
                # All VMs in one batch call must be in the same region.
                # The Region column (set from the RG location cache) contains the ARM region
                # code in lowercase (e.g. 'uksouth', 'eastus') - exactly what the hostname needs.
                # VMs with Region = 'unknown' are skipped (no regional endpoint can be built).
                $batchSize    = 50
                $regionGroups = @($availRows | Where-Object { $_.'Region' -and $_.'Region' -ne 'unknown' } |
                                Group-Object -Property 'Region')
                $skipped      = @($availRows | Where-Object { -not $_.'Region' -or $_.'Region' -eq 'unknown' })

                # Split regions: known DNS failures (cached from a prior refresh) go straight
                # to per-VM; untested regions (or ones that succeeded before) attempt the batch.
                $failedRegions  = @($regionGroups | Where-Object { $metricsRegionalBatchFailed[$_.Name] })
                $batchRegions   = @($regionGroups | Where-Object { -not $metricsRegionalBatchFailed[$_.Name] })

                # Per-VM fallback for regions whose batch endpoint is already known to fail DNS.
                # Identical to the DNS-fallback path below - just fires immediately without wasting
                # a batch round-trip that we already know will fail.
                foreach ($rg in $failedRegions) {
                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] Skipping batch for [$($rg.Name)] (DNS failure cached). Going per-VM for $($rg.Count) VM(s)`r`n") } catch {} }
                    [void]$phase5FallbackRegions.Add($rg.Name)   # count toward status bar mode string
                    $vmHandles = @(foreach ($row in @($rg.Group)) {
                        $ps = [System.Management.Automation.PowerShell]::Create()
                        $ps.RunspacePool = $HpPool
                        [void]$ps.AddScript($vmScript).AddArgument($ArmToken).AddArgument($row.'_VMResourceId').AddArgument($combinedTs).AddArgument($metricNamesEncoded).AddArgument($LogFile)
                        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Row = $row }
                    })
                    # ── Collect per-VM results (cached DNS-failure path) ──────────────────
                    # This region's batch endpoint is already known to fail DNS (cached from a
                    # prior refresh cycle), so we went straight to individual VM calls without
                    # attempting a batch first. Collect each runspace result here.
                    # Each $vh contains: PS (the runspace), Handle (async token), Row (the grid row).
                    try {
                        foreach ($vh in $vmHandles) {
                            try {
                                $vResult = $vh.PS.EndInvoke($vh.Handle)
                                $vh.PS.Dispose()

                                # An empty/null result means the API call returned no body.
                                # Possible causes: the VM has no recent metric data, the token
                                # lacked read access to this specific resource, or a transient
                                # platform issue caused an empty 200. Log so we can diagnose
                                # which VMs are affected and correlate with the access/platform logs.
                                if (-not $vResult -or $vResult.Count -eq 0) {
                                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] WARN: Per-VM fallback returned empty response for '$($vh.Row.'VM Name')' ($($vh.Row.'_VMResourceId'))`r`n") } catch {} }
                                    continue
                                }

                                # Single-resource API response shape:
                                #   { "value": [ { "name": { "value": "metricName" },
                                #                  "timeseries": [ { "data": [ { "average": N } ] } ] } ] }
                                # Note: uses "value" (singular), unlike the batch API's "values" (plural).
                                $readOps = $null; $writeOps = $null; $queueDepth = $null
                                foreach ($metric in @($vResult[0].value)) {
                                    $mName  = [string]$metric.name.value
                                    $latest = $null
                                    if ($metric.timeseries -and $metric.timeseries.Count -gt 0 -and $metric.timeseries[0].data) {
                                        # Filter out null averages (can occur if the hypervisor had no
                                        # data for a given minute) and take the most recent data point.
                                        $dataPoints = @($metric.timeseries[0].data | Where-Object { $null -ne $_.average })
                                        if ($dataPoints.Count -gt 0) { $latest = [double]$dataPoints[-1].average }
                                    }
                                    if ($null -eq $latest) { continue }
                                    if     ($mName -eq 'OS Disk Read Operations/Sec')  { $readOps    = $latest }
                                    elseif ($mName -eq 'OS Disk Write Operations/Sec') { $writeOps   = $latest }
                                    elseif ($mName -eq 'OS Disk Queue Depth')          { $queueDepth = $latest }
                                }

                                # ── Stamp disk IOPS onto the row ─────────────────────────────
                                # Total IOPS = Read + Write. Guard against both being null
                                # (unlikely but possible if Azure returned the metric entries
                                # with no valid data points).
                                if ($null -ne $readOps -or $null -ne $writeOps) {
                                    $totalIOPS = [math]::Round(([double]$readOps + [double]$writeOps), 0)
                                    $vh.Row.'OS Disk IOPS'  = $totalIOPS.ToString()
                                    $vh.Row.'_DiskIOPSSort' = [double]$totalIOPS
                                    # IOPS % = current / provisioned - only calculable when the disk
                                    # tier was resolved in Phase 3 (_DiskProvIOPS > 0).
                                    $provIOPS = [int]$vh.Row.'_DiskProvIOPS'
                                    if ($provIOPS -gt 0) {
                                        $iopsPct = [math]::Round($totalIOPS / $provIOPS * 100, 1)
                                        $vh.Row.'OS Disk IOPS %'    = "$iopsPct%"
                                        $vh.Row.'_DiskIOPSPctSort'  = [double]$iopsPct
                                        $vh.Row.'_DiskIOPSPctColor' = if ($iopsPct -ge $LawHeatMapRedPct) { 'Red' } elseif ($iopsPct -ge $LawHeatMapAmberPct) { 'Amber' } else { 'Green' }
                                    }
                                }

                                # ── Stamp disk queue depth onto the row ───────────────────────
                                if ($null -ne $queueDepth) {
                                    $qd = [math]::Round([double]$queueDepth, 1)
                                    $vh.Row.'OS Disk Queue'   = $qd.ToString()
                                    $vh.Row.'_DiskQueueSort'  = [double]$qd
                                    $vh.Row.'_DiskQueueColor' = if ($qd -ge $DiskQueueRedVal) { 'Red' } elseif ($qd -ge $DiskQueueAmberVal) { 'Amber' } else { 'Green' }
                                }
                            } catch {
                                # Catch any exception from EndInvoke or the parsing/stamping above.
                                # Common causes: 429 throttle that exhausted retries, auth failure,
                                # transient 5xx, or a malformed response. Log the full exception
                                # message so the root cause is visible in the log file - without
                                # this the row would silently stay as '-' with no trace.
                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] ERROR: Per-VM fallback failed for '$($vh.Row.'VM Name')': $_`r`n") } catch {} }
                                try { $vh.PS.Dispose() } catch {}
                            }
                        }
                    } catch {}
                }

                $totalBatches = ($batchRegions | ForEach-Object { [Math]::Ceiling($_.Count / $batchSize) } | Measure-Object -Sum).Sum
                if ($batchRegions.Count -gt 0) {
                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] Launching $totalBatches batch call(s) for $($batchRegions | ForEach-Object { $_.Count } | Measure-Object -Sum | Select-Object -ExpandProperty Sum) Available VM(s) across $($batchRegions.Count) region(s) (batch size=$batchSize)$(if ($skipped.Count) { ", $($skipped.Count) skipped (unknown region)" })$(if ($failedRegions.Count) { ", $($failedRegions.Count) region(s) using cached per-VM" })`r`n") } catch {} }
                }

                $batchHandles = @(foreach ($rg in $batchRegions) {
                    $region   = $rg.Name   # e.g. 'uksouth'
                    $rgRows   = @($rg.Group)
                    $endpoint = "https://$region.metrics.monitor.azure.com/subscriptions/$SubId/metrics:getBatch"

                    for ($b = 0; $b -lt $rgRows.Count; $b += $batchSize) {
                        $slice = @($rgRows[$b .. ([Math]::Min($b + $batchSize - 1, $rgRows.Count - 1))])
                        $ids   = @($slice | ForEach-Object { [string]$_.'_VMResourceId' })

                        $ps = [System.Management.Automation.PowerShell]::Create()
                        $ps.RunspacePool = $HpPool
                        # $args[0]=token, [1]=full regional URL, [2]=resourceId array,
                        # [3]=startTime string, [4]=endTime string, [5]=logFile path
                        [void]$ps.AddScript($batchScript).AddArgument($ArmToken).AddArgument($endpoint).AddArgument($ids).AddArgument($startTime).AddArgument($endTime).AddArgument($LogFile)
                        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Rows = $slice; Region = $region }
                    }
                })

                # ── Phase 5b pre-launch: fire CPU Credits batch calls concurrently ────
                #
                # WHY HERE (before the Phase 5 collect loop)?
                # ---------------------------------------------
                # Phase 5 (disk metrics) and Phase 5b (CPU credits) are independent -
                # different metric names, same regional batch endpoint. Previously Phase 5b
                # launched only after all Phase 5 EndInvoke() calls had completed, meaning
                # the two sets of HTTP round-trips ran sequentially. By pre-launching
                # Phase 5b now (immediately after Phase 5's BeginInvoke loop) both sets of
                # calls hit the Azure Monitor endpoint in parallel. After Phase 5's collect
                # loop finishes the Phase 5b results are usually already waiting, so
                # EndInvoke returns immediately. Savings: ~200–600 ms per refresh cycle.
                #
                # Variables set here are used in the Phase 5b collect block below:
                #   $creditHandles    - batch BeginInvoke handles (one per 50-VM slice per region)
                #   $cvmFallbackSets  - per-VM BeginInvoke handle lists for cached-DNS-fail regions
                #   $creditMetricEncoded, $creditScript, $bRows, $bRowGroups,
                #   $bFailedRegions, $bBatchRegions  - all set here for use in collect phase.
                $creditHandles   = @()
                $cvmFallbackSets = [System.Collections.Generic.List[PSCustomObject]]::new()
                $creditMetricEncoded = [uri]::EscapeDataString('CPU Credits Remaining')

                # Only B-series VMs support CPU credit bursting; non-B-series have no
                # 'CPU Credits Remaining' metric so querying them returns BadArgumentError.
                $bRows = @($availRows | Where-Object { ([string]$_.'VM SKU') -like 'Standard_B*' -and $_.'Region' -and $_.'Region' -ne 'unknown' })

                if ($bRows.Count -gt 0) {
                    $bRowGroups     = @($bRows | Group-Object 'Region')
                    # Split by cached DNS status - same shared flag as Phase 5 disk metrics
                    # since both use the same *.metrics.monitor.azure.com regional endpoint.
                    $bFailedRegions = @($bRowGroups | Where-Object {  $metricsRegionalBatchFailed[$_.Name] })
                    $bBatchRegions  = @($bRowGroups | Where-Object { -not $metricsRegionalBatchFailed[$_.Name] })

                    # Cached DNS-failed regions: fire per-VM calls NOW so they overlap Phase 5 collect.
                    # Store handle lists in $cvmFallbackSets for collection after Phase 5 finishes.
                    foreach ($rg in $bFailedRegions) {
                        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] Pre-launching per-VM (cached DNS failure) for $($rg.Count) B-series VM(s) in [$($rg.Name)] - running concurrently with Phase 5 collect`r`n") } catch {} }
                        $cvmH = @(foreach ($row in @($rg.Group)) {
                            $ps = [System.Management.Automation.PowerShell]::Create()
                            $ps.RunspacePool = $HpPool
                            [void]$ps.AddScript($vmScript).AddArgument($ArmToken).AddArgument($row.'_VMResourceId').AddArgument($combinedTs).AddArgument($creditMetricEncoded).AddArgument($LogFile)
                            [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Row = $row }
                        })
                        [void]$cvmFallbackSets.Add([PSCustomObject]@{ Region = $rg.Name; Handles = $cvmH })
                    }

                    # Batch regions: build $creditScript and fire batch BeginInvoke calls NOW.
                    # $creditHandles is empty if no batch regions - the collect block handles that.
                    if ($bBatchRegions.Count -gt 0) {
                        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] Pre-launching CPU Credits batch for $($bBatchRegions | ForEach-Object { $_.Count } | Measure-Object -Sum | Select-Object -ExpandProperty Sum) B-series VM(s) across $($bBatchRegions.Count) region(s) - running concurrently with Phase 5 collect$(if ($bFailedRegions.Count) { ' (' + $bFailedRegions.Count + ' region(s) using cached per-VM)' })`r`n") } catch {} }

                        # Separate scriptblock from Phase 5 $batchScript - CPU Credits Remaining
                        # cannot be batched with disk metrics (API rejects the request for VMs that
                        # don't support the metric). Same endpoint, different metricnames parameter.
                        $creditScript = [scriptblock]::Create($RestHelperDef + @'
                            $tok = $args[0]; $url = $args[1]; $resourceIds = $args[2]
                            $startTime = $args[3]; $endTime = $args[4]; $LogFile = $args[5]
                            $ns  = [uri]::EscapeDataString('Microsoft.Compute/virtualMachines')
                            $mn  = [uri]::EscapeDataString('CPU Credits Remaining')
                            $fullUrl = "$url`?api-version=2023-10-01&metricnamespace=$ns&metricnames=$mn&starttime=$startTime&endtime=$endTime&interval=PT1M&aggregation=Average"
                            $body = @{ resourceids = $resourceIds }
                            try {
                                Invoke-Arm -Method POST -Path $fullUrl -Token $tok -Body $body -FullResponse
                            } catch {
                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] Batch error: $_`r`n") } catch {} }
                                Write-Error $_
                                $null
                            }
'@)
                        $creditHandles = @(foreach ($rg in $bBatchRegions) {
                            $region   = $rg.Name
                            $rgRows   = @($rg.Group)
                            $endpoint = "https://$region.metrics.monitor.azure.com/subscriptions/$SubId/metrics:getBatch"
                            for ($b = 0; $b -lt $rgRows.Count; $b += $batchSize) {
                                $slice = @($rgRows[$b .. ([Math]::Min($b + $batchSize - 1, $rgRows.Count - 1))])
                                $ids   = @($slice | ForEach-Object { [string]$_.'_VMResourceId' })
                                $ps    = [System.Management.Automation.PowerShell]::Create()
                                $ps.RunspacePool = $HpPool
                                [void]$ps.AddScript($creditScript).AddArgument($ArmToken).AddArgument($endpoint).AddArgument($ids).AddArgument($startTime).AddArgument($endTime).AddArgument($LogFile)
                                [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Rows = $slice; Region = $region }
                            }
                        })
                    }
                }
                # ── END Phase 5b pre-launch - HTTP calls now in flight ───────────────────

                # ── Collect Phase 5 disk batch results and populate row columns ────────
                # EndInvoke() blocks until each batch call finishes.
                # Phase 5b HTTP calls are already in flight (pre-launched above) and will
                # be collected after this loop.
                #
                # For each batch we first check whether it succeeded. If it failed we
                # inspect the error to distinguish two failure modes:
                #
                #   1. DNS / connection failure  (NameResolutionFailure, "remote name could
                #      not be resolved") - this happens in Azure Monitor Private Link
                #      environments because {region}.metrics.monitor.azure.com has no
                #      private endpoint. In this case we fall back to the original per-VM
                #      single-resource GET via management.azure.com, which IS accessible
                #      through AMPLS. The fallback fires all VMs in that batch in parallel
                #      on $HpPool, exactly as Phase 5 did before the batch API was added.
                #
                #   2. HTTP error (4xx/5xx) - a real API problem (bad request, auth issue,
                #      throttling etc.). We log the error and skip - no fallback, because
                #      the per-VM path would likely fail for the same reason.
                #
                # If Microsoft later adds AMPLS support for the regional metrics batch
                # endpoint, the DNS fallback will simply never trigger and can be removed.
                # Track: https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns
                # (currently no entry for *.metrics.monitor.azure.com in that table)
                try {
                    foreach ($bh in $batchHandles) {
                        try {
                            $bResult    = $bh.PS.EndInvoke($bh.Handle)
                            $batchEmpty = (-not $bResult -or $bResult.Count -eq 0)

                            # Detect DNS failure: check PS error stream before disposing
                            # PS.HadErrors is true if the scriptblock wrote to $Error / threw.
                            # We match on the .NET NameResolutionFailure message pattern which
                            # is consistent across PS 5.1 on all Windows versions.
                            $isDnsFail = $false
                            if ($batchEmpty -and $bh.PS.HadErrors) {
                                $firstErr  = [string]($bh.PS.Streams.Error | Select-Object -First 1)
                                $isDnsFail = $firstErr -match 'remote name could not be resolved|NameResolutionFailure|No such host'
                            }
                            $bh.PS.Dispose()

                            $resp = if (-not $batchEmpty) { $bResult[0] } else { $null }

                            # ── DNS failure: fall back to per-VM single-resource API ──────
                            if ($batchEmpty -and $isDnsFail) {
                                # Cache the failure so subsequent refreshes skip the batch attempt entirely
                                $metricsRegionalBatchFailed[$bh.Region] = $true
                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] DNS failure [$($bh.Region)] - regional batch endpoint not resolvable (likely Private Link env). Caching region; will use per-VM for all future refreshes. Falling back to per-VM for $($bh.Rows.Count) VM(s) this cycle`r`n") } catch {} }

                                # Fire one PS instance per VM in this batch, all in parallel on $HpPool.
                                # This is the same pattern as the original Phase 5 before the batch
                                # API was introduced. Uses management.azure.com which is reachable
                                # via AMPLS private endpoint.
                                $vmHandles = @(foreach ($row in $bh.Rows) {
                                    $ps = [System.Management.Automation.PowerShell]::Create()
                                    $ps.RunspacePool = $HpPool
                                    # $args: [0]=token, [1]=vmResourceId, [2]=combined timespan,
                                    #        [3]=URL-encoded metric names, [4]=log file path
                                    [void]$ps.AddScript($vmScript).AddArgument($ArmToken).AddArgument($row.'_VMResourceId').AddArgument($combinedTs).AddArgument($metricNamesEncoded).AddArgument($LogFile)
                                    [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Row = $row }
                                })

                                # ── Collect per-VM results (DNS-failure triggered this cycle) ─────
                                # The batch call just failed with a DNS error for the first time.
                                # We've now fired one PS instance per VM in this batch. Collect
                                # results sequentially (EndInvoke blocks until each runspace finishes).
                                # The RunspacePool cap means at most $RunspaceMaxHpPool run in
                                # parallel at any moment, so this is safe even for large batches.
                                try {
                                    foreach ($vh in $vmHandles) {
                                        try {
                                            $vResult = $vh.PS.EndInvoke($vh.Handle)
                                            $vh.PS.Dispose()

                                            # Empty/null result: API returned no body. This can happen
                                            # when the VM has no recent data, the principal lacks
                                            # Monitoring Reader on this specific resource, or a transient
                                            # platform gap occurred. Log it so we can identify which VMs
                                            # are affected and why - without this the row silently stays '-'.
                                            if (-not $vResult -or $vResult.Count -eq 0) {
                                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] WARN: Per-VM fallback returned empty response for '$($vh.Row.'VM Name')' ($($vh.Row.'_VMResourceId'))`r`n") } catch {} }
                                                continue
                                            }

                                            # Single-resource API response shape:
                                            #   { "value": [ { "name": { "value": "metricName" },
                                            #                  "timeseries": [ { "data": [ { "average": N } ] } ] } ] }
                                            # Note: uses "value" (singular), unlike the batch API's "values" (plural).
                                            $readOps = $null; $writeOps = $null; $queueDepth = $null
                                            foreach ($metric in @($vResult[0].value)) {
                                                $mName  = [string]$metric.name.value
                                                $latest = $null
                                                if ($metric.timeseries -and $metric.timeseries.Count -gt 0 -and $metric.timeseries[0].data) {
                                                    # Skip null averages (hypervisor gap for that minute) and
                                                    # take the most recent non-null data point in the window.
                                                    $dataPoints = @($metric.timeseries[0].data | Where-Object { $null -ne $_.average })
                                                    if ($dataPoints.Count -gt 0) { $latest = [double]$dataPoints[-1].average }
                                                }
                                                if ($null -eq $latest) { continue }
                                                if     ($mName -eq 'OS Disk Read Operations/Sec')  { $readOps    = $latest }
                                                elseif ($mName -eq 'OS Disk Write Operations/Sec') { $writeOps   = $latest }
                                                elseif ($mName -eq 'OS Disk Queue Depth')          { $queueDepth = $latest }
                                            }

                                            # Stamp the row - same logic as the batch success path below.
                                            # Using a hashtable ($m) keeps the stamping block identical
                                            # to that path so both stay in sync if thresholds change.
                                            $m = @{ ReadOps = $readOps; WriteOps = $writeOps; QueueDepth = $queueDepth }

                                            # ── Disk IOPS ────────────────────────────────────────────
                                            if ($null -ne $m.ReadOps -or $null -ne $m.WriteOps) {
                                                $totalIOPS = [math]::Round(([double]$m.ReadOps + [double]$m.WriteOps), 0)
                                                $vh.Row.'OS Disk IOPS'  = $totalIOPS.ToString()
                                                $vh.Row.'_DiskIOPSSort' = [double]$totalIOPS
                                                # IOPS % requires the provisioned IOPS from Phase 3's disk
                                                # tier lookup (_DiskProvIOPS). Skip if unavailable.
                                                $provIOPS = [int]$vh.Row.'_DiskProvIOPS'
                                                if ($provIOPS -gt 0) {
                                                    $iopsPct = [math]::Round($totalIOPS / $provIOPS * 100, 1)
                                                    $vh.Row.'OS Disk IOPS %'    = "$iopsPct%"
                                                    $vh.Row.'_DiskIOPSPctSort'  = [double]$iopsPct
                                                    $vh.Row.'_DiskIOPSPctColor' = if ($iopsPct -ge $LawHeatMapRedPct) { 'Red' } elseif ($iopsPct -ge $LawHeatMapAmberPct) { 'Amber' } else { 'Green' }
                                                }
                                            }

                                            # ── Disk queue depth ─────────────────────────────────────
                                            if ($null -ne $m.QueueDepth) {
                                                $qd = [math]::Round([double]$m.QueueDepth, 1)
                                                $vh.Row.'OS Disk Queue'    = $qd.ToString()
                                                $vh.Row.'_DiskQueueSort'   = [double]$qd
                                                $vh.Row.'_DiskQueueColor'  = if ($qd -ge $DiskQueueRedVal) { 'Red' } elseif ($qd -ge $DiskQueueAmberVal) { 'Amber' } else { 'Green' }
                                            }
                                        } catch {
                                            # Catch exceptions from EndInvoke or parsing/stamping.
                                            # Without logging here, failures (throttle, auth, 5xx)
                                            # are completely invisible - the row stays '-' with no trace.
                                            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] ERROR: Per-VM fallback failed for '$($vh.Row.'VM Name')': $_`r`n") } catch {} }
                                            try { $vh.PS.Dispose() } catch {}
                                        }
                                    }
                                } finally {
                                    # Safety net: dispose any runspaces that didn't get cleaned up
                                    # in the inner try/catch (e.g. if the outer loop itself threw).
                                    foreach ($vh in $vmHandles) { try { $vh.PS.Dispose() } catch {} }
                                }
                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] Per-VM fallback [$($bh.Region)] complete for $($bh.Rows.Count) VM(s)`r`n") } catch {} }
                                # Record this region as having used the per-VM fallback path
                                $phase5FallbackRegions.Add($bh.Region)
                                continue
                            }

                            # ── Non-DNS failure or empty response: log and skip ───────────
                            # Could be an HTTP 4xx/5xx (bad request, auth, throttle etc.).
                            # We do NOT fall back to per-VM here - if the batch API returned
                            # an HTTP error, the per-VM path would likely fail for the same reason.
                            if (-not $resp -or -not $resp.values) {
                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] WARN: Batch [$($bh.Region)] for $($bh.Rows.Count) VM(s) returned no data (resp.values was null/empty)`r`n") } catch {} }
                                continue
                            }

                            # ── Batch succeeded: parse response and stamp rows ────────────
                            # Debug: log first entry's structure when logging is enabled.
                            # Useful for diagnosing future API response format changes.
                            if ($LogFile) { try {
                                $dbgEntry  = $resp.values | Select-Object -First 1
                                $dbgMetric = if ($dbgEntry -and $dbgEntry.value) { @($dbgEntry.value)[0] } else { $null }
                                [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5][DEBUG] entry keys: $(($dbgEntry.PSObject.Properties.Name) -join ',')  |  metric name: '$($dbgMetric.name.value)'  |  timeseries data points: $(@($dbgMetric.timeseries[0].data).Count)`r`n")
                            } catch {} }

                            # Build a lookup: lowercase ARM resource ID -> metric values hashtable.
                            # The batch API returns "resourceid" in lowercase, so we normalise
                            # both sides to lowercase to guarantee a match regardless of ARM casing.
                            $metricsById = @{}
                            foreach ($entry in $resp.values) {
                                $rid = ([string]$entry.resourceid).ToLower()
                                $readOps = $null; $writeOps = $null; $queueDepth = $null

                                # entry.value (singular) is the array of metrics for this VM.
                                # Despite the outer response key being "values" (plural), each
                                # per-VM entry uses "value" (singular) for its metrics array.
                                # This was confirmed by inspecting the raw API response.
                                foreach ($metric in @($entry.value)) {
                                    $mName  = [string]$metric.name.value
                                    $latest = $null
                                    if ($metric.timeseries -and $metric.timeseries.Count -gt 0 -and $metric.timeseries[0].data) {
                                        $dataPoints = @($metric.timeseries[0].data | Where-Object { $null -ne $_.average })
                                        if ($dataPoints.Count -gt 0) { $latest = [double]$dataPoints[-1].average }
                                    }
                                    if ($null -eq $latest) { continue }
                                    if     ($mName -eq 'OS Disk Read Operations/Sec')  { $readOps    = $latest }
                                    elseif ($mName -eq 'OS Disk Write Operations/Sec') { $writeOps   = $latest }
                                    elseif ($mName -eq 'OS Disk Queue Depth')          { $queueDepth = $latest }
                                }
                                $metricsById[$rid] = @{ ReadOps = $readOps; WriteOps = $writeOps; QueueDepth = $queueDepth }
                            }

                            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] Batch OK [$($bh.Region)]: $($metricsById.Count)/$($bh.Rows.Count) VM(s) returned metrics`r`n") } catch {} }
                            # Record this region as having used the batch path successfully
                            if (-not $phase5BatchRegions.Contains($bh.Region)) { $phase5BatchRegions.Add($bh.Region) }

                            # Stamp metric values onto each row in this batch
                            foreach ($row in $bh.Rows) {
                                $rid = ([string]$row.'_VMResourceId').ToLower()
                                if (-not $metricsById.ContainsKey($rid)) {
                                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] WARN: No metrics returned for VM '$($row.'VM Name')' (resourceId: $rid)`r`n") } catch {} }
                                    continue
                                }
                                $m = $metricsById[$rid]

                                # ── Disk IOPS calculation ───────────────────────────────
                                # IOPS = Read Ops/Sec + Write Ops/Sec (total I/O operations)
                                # This is the same calculation Azure uses in VM Insights.
                                # We round to whole number since fractional IOPS aren't meaningful.
                                # Example: ReadOps=28.3 + WriteOps=42.7 = 71 total IOPS
                                if ($null -ne $m.ReadOps -or $null -ne $m.WriteOps) {
                                    $totalIOPS = [math]::Round(([double]$m.ReadOps + [double]$m.WriteOps), 0)
                                    $row.'OS Disk IOPS'     = $totalIOPS.ToString()
                                    $row.'_DiskIOPSSort'    = [double]$totalIOPS

                                    # ── Disk IOPS % = current IOPS / provisioned IOPS ──
                                    # _DiskProvIOPS is set in Phase 3 from the disk tier lookup.
                                    # Shows how close the disk is to its IOPS limit.
                                    $provIOPS = [int]$row.'_DiskProvIOPS'
                                    if ($provIOPS -gt 0) {
                                        $iopsPct = [math]::Round($totalIOPS / $provIOPS * 100, 1)
                                        $row.'OS Disk IOPS %'      = "$iopsPct%"
                                        $row.'_DiskIOPSPctSort'    = [double]$iopsPct
                                        $row.'_DiskIOPSPctColor'   = if ($iopsPct -ge $LawHeatMapRedPct) { 'Red' } elseif ($iopsPct -ge $LawHeatMapAmberPct) { 'Amber' } else { 'Green' }
                                    }
                                }

                                # ── Disk Queue Depth with heat map colouring ────────────
                                # Queue Depth = average number of pending I/O requests.
                                # This is a platform metric from the Azure hypervisor.
                                # Interpretation:
                                #   0-0.5  = Healthy, disk handling all I/O instantly
                                #   0.5-2  = Normal, some queuing under load
                                #   2-5    = Amber - moderate disk pressure, may affect performance
                                #   5+     = Red - disk is a bottleneck, I/O requests are backing up
                                # Rounded to 1 decimal place for readability (e.g. "0.1", "2.3").
                                if ($null -ne $m.QueueDepth) {
                                    $qd = [math]::Round([double]$m.QueueDepth, 1)
                                    $row.'OS Disk Queue'      = $qd.ToString()
                                    $row.'_DiskQueueSort'     = [double]$qd
                                    $row.'_DiskQueueColor'    = if ($qd -ge $DiskQueueRedVal) { 'Red' } elseif ($qd -ge $DiskQueueAmberVal) { 'Amber' } else { 'Green' }
                                }

                            }
                        } catch {
                            # Unexpected exception collecting this batch - log and skip
                            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] ERROR: Batch [$($bh.Region)] for $($bh.Rows.Count) VM(s) failed: $_`r`n") } catch {} }
                            try { $bh.PS.Dispose() } catch {}
                        }
                    }
                } finally {
                    # Safety net: dispose any PS instances not yet disposed
                    foreach ($bh in $batchHandles) { try { $bh.PS.Dispose() } catch {} }
                }

                if ($LogFile) {
                    try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5] Complete: $($availRows.Count - $skipped.Count) VM(s) queried in $totalBatches batch call(s) across $($regionGroups.Count) region(s) via regional Batch Metrics API`r`n") } catch {}
                }

                # ── Phase 5b collect: CPU Credits Remaining results ───────────────────
                #
                # The Phase 5b HTTP calls were pre-launched before the Phase 5 collect
                # loop above, so they ran concurrently. By the time we reach this point
                # the batch results are usually already available and EndInvoke returns
                # immediately - the cost is near-zero in the common case.
                #
                # Collect order:
                #   1. $cvmFallbackSets - cached-DNS-fail regions (per-VM handles, pre-launched)
                #   2. $creditHandles   - batch handles (pre-launched); DNS-fail-on-first-attempt
                #                        fires per-VM inline as before

                # ── 1. Collect pre-launched per-VM results for cached-DNS-fail regions ─
                foreach ($set in $cvmFallbackSets) {
                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] Collecting per-VM (cached DNS failure) results for [$($set.Region)]`r`n") } catch {} }
                    try {
                        foreach ($vh in $set.Handles) {
                            try {
                                $vRes = $vh.PS.EndInvoke($vh.Handle)
                                $vh.PS.Dispose()

                                # Empty/null: could be no credits data, access gap, or transient platform gap.
                                if (-not $vRes -or $vRes.Count -eq 0) {
                                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] WARN: Per-VM fallback returned empty response for '$($vh.Row.'VM Name')' ($($vh.Row.'_VMResourceId'))`r`n") } catch {} }
                                } elseif ($vRes) {
                                    # Single-resource API uses "value" (singular) for its metrics array.
                                    $m = $vRes[0].value | Where-Object { $_.name.value -eq 'CPU Credits Remaining' }
                                    if ($m) {
                                        $latest = ($m.timeseries[0].data | Where-Object { $null -ne $_.average } | Select-Object -Last 1).average
                                        if ($null -ne $latest) {
                                            $crRnd = [math]::Round($latest, 0)
                                            $vh.Row.'CPU Credits'      = $crRnd.ToString()
                                            $vh.Row.'_CPUCreditsSort'  = [double]$crRnd
                                            $vh.Row.'_CPUCreditsColor' = if ($crRnd -lt 10) { 'Red' } elseif ($crRnd -lt 30) { 'Amber' } else { 'Green' }
                                        }
                                    }
                                }
                            } catch {
                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] ERROR: Per-VM fallback failed for '$($vh.Row.'VM Name')': $_`r`n") } catch {} }
                                try { $vh.PS.Dispose() } catch {}
                            }
                        }
                    } finally {
                        foreach ($vh in $set.Handles) { try { $vh.PS.Dispose() } catch {} }
                    }
                }

                # ── 2. Collect pre-launched batch results ─────────────────────────────
                if ($creditHandles.Count -gt 0) {
                    try {
                        foreach ($ch in $creditHandles) {
                            try {
                                $cResult    = $ch.PS.EndInvoke($ch.Handle)
                                $batchEmpty = (-not $cResult -or $cResult.Count -eq 0)

                                # Detect DNS failure - same pattern as Phase 5 disk metrics.
                                # Phase 5b shares $metricsRegionalBatchFailed with Phase 5 since
                                # both use the same *.metrics.monitor.azure.com endpoint.
                                $isDnsFail = $false
                                if ($batchEmpty -and $ch.PS.HadErrors) {
                                    $firstErr  = [string]($ch.PS.Streams.Error | Select-Object -First 1)
                                    $isDnsFail = $firstErr -match 'remote name could not be resolved|NameResolutionFailure|No such host'
                                }
                                $ch.PS.Dispose()

                                # ── DNS failure on first attempt: fall back to per-VM ──────────
                                # Cache the region so next refresh skips straight to per-VM and
                                # the pre-launch block fires per-VM handles concurrently instead.
                                if ($batchEmpty -and $isDnsFail) {
                                    $metricsRegionalBatchFailed[$ch.Region] = $true
                                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] DNS failure [$($ch.Region)] - caching region. Falling back to per-VM for $($ch.Rows.Count) B-series VM(s)`r`n") } catch {} }

                                    $cvmHandles = @(foreach ($row in $ch.Rows) {
                                        $ps = [System.Management.Automation.PowerShell]::Create()
                                        $ps.RunspacePool = $HpPool
                                        [void]$ps.AddScript($vmScript).AddArgument($ArmToken).AddArgument($row.'_VMResourceId').AddArgument($combinedTs).AddArgument($creditMetricEncoded).AddArgument($LogFile)
                                        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Row = $row }
                                    })
                                    try {
                                        foreach ($vh in $cvmHandles) {
                                            try {
                                                $vResult = $vh.PS.EndInvoke($vh.Handle)
                                                $vh.PS.Dispose()

                                                if (-not $vResult -or $vResult.Count -eq 0) {
                                                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] WARN: Per-VM fallback returned empty response for '$($vh.Row.'VM Name')' ($($vh.Row.'_VMResourceId'))`r`n") } catch {} }
                                                    continue
                                                }
                                                $latest = $null
                                                foreach ($metric in @($vResult[0].value)) {
                                                    if ([string]$metric.name.value -eq 'CPU Credits Remaining') {
                                                        if ($metric.timeseries -and $metric.timeseries.Count -gt 0 -and $metric.timeseries[0].data) {
                                                            $pts = @($metric.timeseries[0].data | Where-Object { $null -ne $_.average })
                                                            if ($pts.Count -gt 0) { $latest = [double]$pts[-1].average }
                                                        }
                                                    }
                                                }
                                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] per-VM $($vh.Row.'VM Name') credits=$(if ($null -eq $latest) {'<null>'} else {$latest})`r`n") } catch {} }
                                                if ($null -ne $latest) {
                                                    $crRnd = [math]::Round($latest, 0)
                                                    $vh.Row.'CPU Credits'      = $crRnd.ToString()
                                                    $vh.Row.'_CPUCreditsSort'  = [double]$crRnd
                                                    $vh.Row.'_CPUCreditsColor' = if ($crRnd -lt 10) { 'Red' } elseif ($crRnd -lt 30) { 'Amber' } else { 'Green' }
                                                }
                                            } catch {
                                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] ERROR: Per-VM fallback failed for '$($vh.Row.'VM Name')': $_`r`n") } catch {} }
                                                try { $vh.PS.Dispose() } catch {}
                                            }
                                        }
                                    } finally {
                                        foreach ($vh in $cvmHandles) { try { $vh.PS.Dispose() } catch {} }
                                    }
                                    continue
                                }

                                if ($batchEmpty) { continue }

                                # ── Batch succeeded: parse and stamp rows ──────────────────────
                                $resp = $cResult[0]
                                if (-not $resp.values) { continue }

                                $creditById = @{}
                                foreach ($entry in $resp.values) {
                                    $rid    = ([string]$entry.resourceid).ToLower()
                                    $latest = $null
                                    foreach ($metric in @($entry.value)) {
                                        if ([string]$metric.name.value -eq 'CPU Credits Remaining') {
                                            if ($metric.timeseries -and $metric.timeseries.Count -gt 0 -and $metric.timeseries[0].data) {
                                                $pts = @($metric.timeseries[0].data | Where-Object { $null -ne $_.average })
                                                if ($pts.Count -gt 0) { $latest = [double]$pts[-1].average }
                                            }
                                        }
                                    }
                                    $creditById[$rid] = $latest
                                }

                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] Batch OK [$($ch.Region)]: $($creditById.Count)/$($ch.Rows.Count) B-series VM(s) returned credits`r`n") } catch {} }
                                foreach ($row in $ch.Rows) {
                                    $rid = ([string]$row.'_VMResourceId').ToLower()
                                    if (-not $creditById.ContainsKey($rid)) {
                                        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] WARN: No credits returned for VM '$($row.'VM Name')' (resourceId: $rid)`r`n") } catch {} }
                                        continue
                                    }
                                    $cr = $creditById[$rid]
                                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] $($row.'VM Name') credits=$(if ($null -eq $cr) {'<null>'} else {$cr})`r`n") } catch {} }
                                    if ($null -ne $cr) {
                                        $crRnd = [math]::Round($cr, 0)
                                        $row.'CPU Credits'      = $crRnd.ToString()
                                        $row.'_CPUCreditsSort'  = [double]$crRnd
                                        $row.'_CPUCreditsColor' = if ($crRnd -lt 10) { 'Red' } elseif ($crRnd -lt 30) { 'Amber' } else { 'Green' }
                                    }
                                }
                            } catch {
                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Phase5b] ERROR collecting batch: $_`r`n") } catch {} }
                                try { $ch.PS.Dispose() } catch {}
                            }
                        }
                    } finally {
                        foreach ($ch in $creditHandles) { try { $ch.PS.Dispose() } catch {} }
                    }
                }
            }
        } catch {
            $phase5Error = "Disk metrics enrichment failed: $_"
            if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] ERROR [Phase5] $phase5Error`r`n") } catch {} }
        }
    }

    # Build a human-readable disk metrics mode string for display in the status bar.
    # Shows which regions used the batch API and which fell back to per-VM, so the
    # user can see at a glance whether Private Link is affecting the batch endpoint.
    $phase5Mode = if (-not $ShowDiskPerf) {
        $null
    } elseif ($phase5FallbackRegions.Count -gt 0 -and $phase5BatchRegions.Count -gt 0) {
        # Mixed: some regions support batch, others fell back (e.g. multi-sub or partial Private Link)
        "Metrics: Batch ($($phase5BatchRegions -join ',')) + Per-VM ($($phase5FallbackRegions -join ','))"
    } elseif ($phase5FallbackRegions.Count -gt 0) {
        # All regions fell back to per-VM (typical in full Private Link environments)
        "Metrics: Per-VM"
    } elseif ($phase5BatchRegions.Count -gt 0) {
        # All regions used batch successfully
        "Metrics: Batch"
    } else {
        $null   # Phase 5 didn't run (no Available VMs, or ShowDiskPerf logic skipped)
    }

    # ── Metrics return ────────────────────────────────────────────────────────────
    # $vmRows already contains the enriched rows (Phase 4 + Phase 5 values stamped
    # in-place above). The UI thread's _SH_BackfillMetrics merges these into the
    # existing DataTable rows by VM Name key - no full table rebuild needed.
    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Metrics] Phases 4-5b complete. Returning $($vmRows.Count) row(s) with metric data.`r`n") } catch {} }
    [PSCustomObject]@{
        Pass        = 'Metrics'
        MetricRows  = $vmRows
        Timestamp   = Get-Date
        Phase4Error = $phase4Error
        Phase5Error = $phase5Error
        Phase5Mode  = $phase5Mode
    }
}

# =============================================================================
# 3. One-time initialisation  -  call after $window is loaded
#
# Sets up the dedicated refresh runspace, binds all named controls, initialises
# state variables, and wires every UI event handler for this tab.
#
# Parameters (supplied by the main script after the window is shown):
#   $Window         - the loaded System.Windows.Window object
#   $ContextFile    - path to the saved Az context JSON file (for Az.Accounts)
#   $SubscriptionId - current Azure subscription ID for REST API calls
#   $HpPool         - persistent RunspacePool shared with the main refresh cycle
# =============================================================================


# =============================================================================
# Performance History - KQL query + WPF line chart
#
# Queries Log Analytics Workspace for historical CPU % and Mem % data for a
# single VM and renders the results as a line chart in a popup window.
#
# Components:
#   Invoke-PerfHistoryQuery  - sends a KQL time-series query to LAW via REST API
#   Update-PerfChart         - draws axes, gridlines, threshold lines and data
#                              polylines on a WPF Canvas
#   Show-PerformanceHistory  - creates the popup window, wires the time range
#                              ComboBox, and handles resize
#
# The KQL query uses summarize avg() with bin() to bucket performance samples
# into evenly-spaced intervals. Bin size scales with the selected time range
# so the chart always has a reasonable number of data points (~60-100).
#
# Chart rendering uses pure WPF drawing primitives (Canvas, Polyline, Line,
# Rectangle, TextBlock) - no external charting libraries required.
# =============================================================================

function Invoke-PerfHistoryQuery {
    <#
    .SYNOPSIS
        Queries LAW for historical CPU and Memory performance data for a single VM.
    .DESCRIPTION
        Sends a KQL query to the configured Log Analytics Workspace that returns
        time-bucketed average CPU % and Mem % values. The bin size scales with the
        requested time range to keep the number of data points manageable.
    .PARAMETER VmName
        Short VM name (e.g. "CUKHP01UKWB-108") - matched case-insensitively against
        the Computer column in the Perf table.
    .PARAMETER TimeRange
        ISO 8601 duration string: PT1H, PT4H, PT12H, or PT24H.
    .OUTPUTS
        Hashtable with keys 'CPU' and 'Mem', each containing an array of
        [PSCustomObject]@{ Time = [datetime]; Value = [double] } sorted by time.
        Returns $null if the query fails or returns no data.
    #>
    param(
        [string]$VmName,
        [string]$TimeRange = 'PT1H'
    )

    # Determine bin size based on the time range so charts have ~60-100 data points
    $binSize = switch ($TimeRange) {
        'PT1H'  { '1m'  }   # 1 hour  -> 1-minute bins  (~60 points)
        'PT4H'  { '5m'  }   # 4 hours -> 5-minute bins  (~48 points)
        'PT12H' { '10m' }   # 12 hours -> 10-minute bins (~72 points)
        'PT24H' { '15m' }   # 24 hours -> 15-minute bins (~96 points)
        default { '5m'  }
    }

    # KQL ago() duration string (lowercase, without the 'PT' prefix format)
    $agoDuration = switch ($TimeRange) {
        'PT1H'  { '1h'  }
        'PT4H'  { '4h'  }
        'PT12H' { '12h' }
        'PT24H' { '24h' }
        default { '1h'  }
    }

    $vmLower = $VmName.ToLower()
    $kql = @"
Perf
| where TimeGenerated > ago($agoDuration)
| where (ObjectName in ("Processor", "Processor Information") and CounterName == "% Processor Time" and InstanceName == "_Total")
   or   (ObjectName == "Memory" and CounterName == "% Committed Bytes In Use")
| extend ComputerShort = tolower(split(Computer, '.')[0])
| where ComputerShort == "$vmLower"
| summarize avg(CounterValue) by bin(TimeGenerated, $binSize), CounterName
| order by TimeGenerated asc
| project TimeGenerated, CounterName, Value = round(avg_CounterValue, 1)
"@

    $resp = Invoke-LawQuery -Kql $kql -Timespan $TimeRange `
                -WorkspaceResourceId $script:LawWorkspaceResourceId `
                -QueryBaseUrl $script:LawQueryBaseUrl

    # Parse the columnar JSON response into separate CPU and Mem arrays.
    # Response format: { tables: [{ columns: [...], rows: [[...],[...]] }] }
    $cpuData = [System.Collections.Generic.List[PSObject]]::new()
    $memData = [System.Collections.Generic.List[PSObject]]::new()

    if ($resp.tables -and $resp.tables[0].rows -and $resp.tables[0].rows.Count -gt 0) {
        # Resolve column indices (PS5.1 uses .ColumnName, PS7 uses .name)
        $cols = @($resp.tables[0].columns | ForEach-Object {
            $n = [string]$_.name
            if (-not $n) { $n = [string]$_.ColumnName }
            if (-not $n) { $n = [string]$_ }
            $n
        })
        $colsLower = @($cols | ForEach-Object { $_.ToLower() })
        $idxTime = [array]::IndexOf($colsLower, 'timegenerated')
        $idxCtr  = [array]::IndexOf($colsLower, 'countername')
        $idxVal  = [array]::IndexOf($colsLower, 'value')

        if ($idxTime -ge 0 -and $idxCtr -ge 0 -and $idxVal -ge 0) {
            foreach ($r in $resp.tables[0].rows) {
                $pt = [PSCustomObject]@{
                    Time  = [datetime]$r[$idxTime]
                    Value = [double]$r[$idxVal]
                }
                $ctr = [string]$r[$idxCtr]
                if ($ctr -like '*Processor Time*')      { $cpuData.Add($pt) }
                elseif ($ctr -like '*Committed Bytes*') { $memData.Add($pt) }
            }
        }
    }

    return @{
        CPU = @($cpuData)
        Mem = @($memData)
    }
}


function Invoke-DiskMetricsHistoryQuery {
    <#
    .SYNOPSIS
        Queries Azure Monitor Metrics API for historical OS Disk IOPS and Queue Depth.
    .DESCRIPTION
        Queries the Azure Monitor Metrics API for time-series disk performance data
        for a single VM. Returns separate arrays for IOPS (read+write combined) and
        Queue Depth, each with Time/Value pairs suitable for chart rendering.
    .PARAMETER VMResourceId
        Full ARM resource ID of the VM.
    .PARAMETER TimeRange
        ISO 8601 duration string: PT1H, PT4H, PT12H, or PT24H.
    .OUTPUTS
        Hashtable with keys 'IOPS' and 'QueueDepth', each containing an array of
        [PSCustomObject]@{ Time = [datetime]; Value = [double] } sorted by time.
        Returns $null if the query fails or returns no data.
    #>
    param(
        [string]$VMResourceId,
        [string]$TimeRange = 'PT1H'
    )

    # Map time range to Azure Monitor interval
    $interval = switch ($TimeRange) {
        'PT1H'  { 'PT1M'  }   # 1 hour  -> 1-minute intervals (~60 points)
        'PT4H'  { 'PT5M'  }   # 4 hours -> 5-minute intervals (~48 points)
        'PT12H' { 'PT15M' }   # 12 hours -> 15-minute intervals (~48 points)
        'PT24H' { 'PT1H'  }   # 24 hours -> 1-hour intervals (~24 points)
        default { 'PT5M'  }
    }

    # Map time range to timespan for the API call
    $hours = switch ($TimeRange) {
        'PT1H'  { 1 }
        'PT4H'  { 4 }
        'PT12H' { 12 }
        'PT24H' { 24 }
        default { 1 }
    }

    $endTime   = [datetime]::UtcNow
    $startTime = $endTime.AddHours(-$hours)
    $ts = "$($startTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($endTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    $metricNames = [uri]::EscapeDataString('OS Disk Read Operations/Sec,OS Disk Write Operations/Sec,OS Disk Queue Depth')

    $tok = Get-ArmToken
    $qs = "metricnames=$metricNames&timespan=$ts&interval=$interval&aggregation=Average"
    $resp = Invoke-ArmRestMethod `
                -Path "$VMResourceId/providers/microsoft.insights/metrics?$qs" `
                -Token $tok `
                -ApiVersion '2024-02-01' `
                -FullResponse

    # Parse response into separate IOPS and QueueDepth time-series
    $readData  = [System.Collections.Generic.Dictionary[datetime,double]]::new()
    $writeData = [System.Collections.Generic.Dictionary[datetime,double]]::new()
    $queueData = [System.Collections.Generic.List[PSObject]]::new()

    if ($resp.value) {
        foreach ($metric in @($resp.value)) {
            $mName = $metric.name.value
            if (-not $metric.timeseries -or $metric.timeseries.Count -eq 0) { continue }
            foreach ($dp in @($metric.timeseries[0].data)) {
                $t = [datetime]$dp.timeStamp
                if ($null -eq $dp.average) {
                    # Keep null buckets as gap markers (IsGap=$true) so the chart
                    # polyline builder can break the line at VM-off periods.
                    if ($mName -eq 'OS Disk Queue Depth') {
                        $queueData.Add([PSCustomObject]@{ Time = $t; Value = [double]::NaN; IsGap = $true })
                    } else {
                        # Read/Write go into a Dictionary - mark with NaN sentinel
                        if ($mName -eq 'OS Disk Read Operations/Sec')  { $readData[$t]  = [double]::NaN }
                        elseif ($mName -eq 'OS Disk Write Operations/Sec') { $writeData[$t] = [double]::NaN }
                    }
                    continue
                }
                $v = [double]$dp.average

                if ($mName -eq 'OS Disk Read Operations/Sec') {
                    $readData[$t] = $v
                }
                elseif ($mName -eq 'OS Disk Write Operations/Sec') {
                    $writeData[$t] = $v
                }
                elseif ($mName -eq 'OS Disk Queue Depth') {
                    $queueData.Add([PSCustomObject]@{ Time = $t; Value = [math]::Round($v, 2); IsGap = $false })
                }
            }
        }
    }

    # Combine read + write into total IOPS per time bucket
    $iopsData = [System.Collections.Generic.List[PSObject]]::new()
    $allTimes = [System.Collections.Generic.HashSet[datetime]]::new()
    foreach ($t in $readData.Keys)  { [void]$allTimes.Add($t) }
    foreach ($t in $writeData.Keys) { [void]$allTimes.Add($t) }
    foreach ($t in ($allTimes | Sort-Object)) {
        $r = if ($readData.ContainsKey($t))  { $readData[$t] }  else { 0 }
        $w = if ($writeData.ContainsKey($t)) { $writeData[$t] } else { 0 }
        # If either metric is a gap (NaN), mark the combined point as a gap too
        $isGap = [double]::IsNaN($r) -or [double]::IsNaN($w)
        $iopsData.Add([PSCustomObject]@{ Time = $t; Value = if ($isGap) { [double]::NaN } else { [math]::Round($r + $w, 1) }; IsGap = $isGap })
    }

    return @{
        IOPS       = @($iopsData)
        QueueDepth = @($queueData)
    }
}


function Invoke-CPUCreditsHistoryQuery {
    <#
    .SYNOPSIS
        Queries Azure Monitor for CPU Credits Remaining history for a B-series VM.
    .PARAMETER VMResourceId
        Full ARM resource ID of the VM.
    .PARAMETER TimeRange
        ISO 8601 duration string: PT1H, PT4H, PT12H, or PT24H.
    #>
    param(
        [string]$VMResourceId,
        [string]$TimeRange = 'PT1H'
    )

    $interval = switch ($TimeRange) {
        'PT1H'  { 'PT1M'  }
        'PT4H'  { 'PT5M'  }
        'PT12H' { 'PT15M' }
        'PT24H' { 'PT1H'  }
        default { 'PT5M'  }
    }
    $hours = switch ($TimeRange) {
        'PT1H'  { 1  }
        'PT4H'  { 4  }
        'PT12H' { 12 }
        'PT24H' { 24 }
        default { 1  }
    }

    $endTime   = [datetime]::UtcNow
    $startTime = $endTime.AddHours(-$hours)
    $ts        = "$($startTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($endTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    $mn        = [uri]::EscapeDataString('CPU Credits Remaining')

    $tok  = Get-ArmToken
    $qs   = "metricnames=$mn&timespan=$ts&interval=$interval&aggregation=Average"
    $resp = Invoke-ArmRestMethod -Path "$VMResourceId/providers/microsoft.insights/metrics?$qs" `
                -Token $tok -ApiVersion '2024-02-01' -FullResponse

    $data = [System.Collections.Generic.List[PSObject]]::new()
    if ($resp.value) {
        foreach ($metric in @($resp.value)) {
            if ($metric.name.value -ne 'CPU Credits Remaining') { continue }
            if (-not $metric.timeseries -or $metric.timeseries.Count -eq 0) { continue }
            foreach ($dp in @($metric.timeseries[0].data)) {
                $t = [datetime]$dp.timeStamp
                if ($null -eq $dp.average) {
                    $data.Add([PSCustomObject]@{ Time = $t; Value = [double]::NaN; IsGap = $true })
                } else {
                    $data.Add([PSCustomObject]@{ Time = $t; Value = [math]::Round([double]$dp.average, 1); IsGap = $false })
                }
            }
        }
    }
    return @{ Credits = @($data) }
}


function Update-DiskChart {
    <#
    .SYNOPSIS
        Draws a Disk IOPS / Queue Depth line chart on a WPF Canvas.
    .DESCRIPTION
        Similar to Update-PerfChart but with auto-scaling Y-axis (not fixed 0-100%).
        Renders two series: IOPS (green) and Queue Depth (red/orange).
        The Y-axis scales to fit the maximum value in the data.
    .PARAMETER Canvas
        The WPF Canvas control to draw on.
    .PARAMETER IOPSData
        Array of [PSCustomObject]@{ Time; Value } for Disk IOPS.
    .PARAMETER QueueData
        Array of [PSCustomObject]@{ Time; Value } for Disk Queue Depth.
    #>
    param(
        [System.Windows.Controls.Canvas]$Canvas,
        [object[]]$IOPSData,
        [object[]]$QueueData
    )

    $Canvas.Children.Clear()

    $w = $Canvas.ActualWidth
    $h = $Canvas.ActualHeight
    if ($w -lt 100 -or $h -lt 80) { return }

    # Margins
    $ml = 55; $mr = 55; $mt = 15; $mb = 35
    $cw = $w - $ml - $mr
    $ch = $h - $mt - $mb

    $brushConv    = New-Object System.Windows.Media.BrushConverter
    $_chartBg     = if ($script:DarkTheme) { '#1E1E1E' } else { '#FAFAFA' }
    $_gridH       = if ($script:DarkTheme) { '#3F3F46' } else { '#E0E0E0' }
    $_gridV       = if ($script:DarkTheme) { '#2A2D2E' } else { '#F0F0F0' }
    $_axis        = if ($script:DarkTheme) { '#6A6A6A' } else { '#999999' }
    $_labelColor  = if ($script:DarkTheme) { '#9D9D9D' } else { '#666666' }

    # ── Helpers (same as Update-PerfChart) ──────────────────────────────────
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
    $addText = {
        param($text, $x, $y, $fontSize, $color, $hAlign)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $tb.FontSize = if ($fontSize) { $fontSize } else { 10 }
        $tb.Foreground = $brushConv.ConvertFromString($(if ($color) { $color } else { $_labelColor }))
        [System.Windows.Controls.Canvas]::SetLeft($tb, $x)
        [System.Windows.Controls.Canvas]::SetTop($tb, $y)
        if ($hAlign -eq 'Right') {
            $tb.TextAlignment = [System.Windows.TextAlignment]::Right
            $tb.Width = $x
            [System.Windows.Controls.Canvas]::SetLeft($tb, 0)
        }
        [void]$Canvas.Children.Add($tb)
    }

    # ── Chart background ───────────────────────────────────────────────────
    $bg = New-Object System.Windows.Shapes.Rectangle
    $bg.Width = $cw; $bg.Height = $ch
    $bg.Fill = $brushConv.ConvertFromString($_chartBg)
    [System.Windows.Controls.Canvas]::SetLeft($bg, $ml)
    [System.Windows.Controls.Canvas]::SetTop($bg, $mt)
    [void]$Canvas.Children.Add($bg)

    # ── Determine data ranges ──────────────────────────────────────────────
    $allTimes = @()
    if ($IOPSData.Count  -gt 0) { $allTimes += $IOPSData  | ForEach-Object { $_.Time } }
    if ($QueueData.Count -gt 0) { $allTimes += $QueueData | ForEach-Object { $_.Time } }
    if ($allTimes.Count -eq 0) { return }

    $minTime = ($allTimes | Measure-Object -Minimum).Minimum
    $maxTime = ($allTimes | Measure-Object -Maximum).Maximum
    $span    = ($maxTime - $minTime).TotalSeconds
    if ($span -le 0) { $span = 1 }

    # Auto-scale Y-axis for IOPS (left axis)
    $maxIOPS = 1
    if ($IOPSData.Count -gt 0) {
        $maxIOPS = [math]::Max(1, ($IOPSData | ForEach-Object { $_.Value } | Measure-Object -Maximum).Maximum)
    }
    # Round up to a nice number for axis labels
    $yMaxIOPS = if ($maxIOPS -le 10) { 10 }
                elseif ($maxIOPS -le 50) { [math]::Ceiling($maxIOPS / 10) * 10 }
                elseif ($maxIOPS -le 500) { [math]::Ceiling($maxIOPS / 50) * 50 }
                else { [math]::Ceiling($maxIOPS / 100) * 100 }

    # Auto-scale Y-axis for Queue Depth (right axis)
    $maxQueue = 1
    if ($QueueData.Count -gt 0) {
        $maxQueue = [math]::Max(1, ($QueueData | ForEach-Object { $_.Value } | Measure-Object -Maximum).Maximum)
    }
    $yMaxQueue = if ($maxQueue -le 5) { 5 }
                 elseif ($maxQueue -le 10) { 10 }
                 elseif ($maxQueue -le 20) { [math]::Ceiling($maxQueue / 5) * 5 }
                 else { [math]::Ceiling($maxQueue / 10) * 10 }

    # ── Gridlines (4 horizontal lines at 25%, 50%, 75%) ────────────────────
    foreach ($frac in @(0.25, 0.50, 0.75)) {
        $y = $mt + $ch * (1 - $frac)
        & $addLine $ml $y ($ml + $cw) $y $_gridH 1 @(4, 4)
    }

    # ── Y-axis labels - left (IOPS) ───────────────────────────────────────
    foreach ($frac in @(0, 0.25, 0.50, 0.75, 1.0)) {
        $y = $mt + $ch * (1 - $frac) - 7
        $label = [math]::Round($yMaxIOPS * $frac, 0).ToString()
        & $addText $label ($ml - 5) $y 10 '#2E7D32' 'Right'
    }

    # ── Y-axis labels - right (Queue Depth) ────────────────────────────────
    foreach ($frac in @(0, 0.25, 0.50, 0.75, 1.0)) {
        $y = $mt + $ch * (1 - $frac) - 7
        $label = [math]::Round($yMaxQueue * $frac, 1).ToString()
        & $addText $label ($ml + $cw + 5) $y 10 '#E65100' $null
    }

    # ── Axes ───────────────────────────────────────────────────────────────
    & $addLine $ml $mt $ml ($mt + $ch) '#2E7D32' 1 $null              # Left Y-axis (IOPS - green)
    & $addLine ($ml + $cw) $mt ($ml + $cw) ($mt + $ch) '#E65100' 1 $null  # Right Y-axis (Queue - orange)
    & $addLine $ml ($mt + $ch) ($ml + $cw) ($mt + $ch) $_axis 1 $null     # X-axis (bottom)

    # ── X-axis time labels ─────────────────────────────────────────────────
    $labelCount = [Math]::Min(6, [Math]::Max(2, [int]($cw / 100)))
    for ($i = 0; $i -le $labelCount; $i++) {
        $frac = $i / $labelCount
        $t    = $minTime.AddSeconds($frac * $span)
        $x    = $ml + $frac * $cw
        $label = $t.ToLocalTime().ToString('HH:mm')
        & $addText $label ($x - 15) ($mt + $ch + 5) 10 $null $null
        if ($i -gt 0 -and $i -lt $labelCount) {
            & $addLine $x $mt $x ($mt + $ch) $_gridV 1 $null
        }
    }

    # ── Helper: build segment-aware Polylines from data points ────────────
    # Azure Monitor returns a complete time series including null buckets for
    # periods when the VM was off. Points with IsGap=$true are used as explicit
    # segment breaks so the line is not drawn across VM-off periods.
    $buildPolyline = {
        param($data, $color, $yMax)
        if ($data.Count -lt 2 -or $yMax -le 0) { return }

        $pl = $null; $points = $null

        for ($i = 0; $i -lt $data.Count; $i++) {
            $pt = $data[$i]

            # Gap marker - flush current segment and skip this point
            if ($pt.IsGap) {
                if ($pl -and $points.Count -ge 2) { $pl.Points = $points; [void]$Canvas.Children.Add($pl) }
                $pl = $null; $points = $null
                continue
            }

            $xFrac = ($pt.Time - $minTime).TotalSeconds / $span
            $x     = $ml + $xFrac * $cw
            $y     = $mt + $ch * (1 - [Math]::Max(0, [Math]::Min($yMax, $pt.Value)) / $yMax)

            if ($null -eq $pl) {
                $pl = New-Object System.Windows.Shapes.Polyline
                $pl.Stroke          = $brushConv.ConvertFromString($color)
                $pl.StrokeThickness = 2
                $pl.StrokeLineJoin  = [System.Windows.Media.PenLineJoin]::Round
                $points = New-Object System.Windows.Media.PointCollection
            }
            [void]$points.Add([System.Windows.Point]::new($x, $y))
        }
        if ($pl -and $points.Count -ge 2) { $pl.Points = $points; [void]$Canvas.Children.Add($pl) }
    }

    # ── Draw data lines ────────────────────────────────────────────────────
    & $buildPolyline $IOPSData  '#2E7D32' $yMaxIOPS    # IOPS - green (left axis)
    & $buildPolyline $QueueData '#E65100' $yMaxQueue    # Queue Depth - orange (right axis)

}


function Update-CreditsChart {
    <#
    .SYNOPSIS
        Draws a CPU Credits Remaining line chart on a WPF Canvas for B-series VMs.
    .DESCRIPTION
        Renders a single series (CPU Credits Remaining) with an auto-scaled Y-axis.
        Gap-aware rendering: Azure Monitor returns a complete time series including null
        buckets for periods when the VM was deallocated. Points marked IsGap=$true act
        as explicit segment breaks so lines are not drawn across VM-off gaps.

        Threshold reference lines:
          - Amber dashed line at 30 credits  (matches the live column amber band)
          - Red dashed line at 10 credits    (matches the live column red band)

        Chart colour: purple (#7B1FA2) - visually distinct from CPU (blue),
        Mem (orange), and IOPS (green) in the Performance History popup.
    .PARAMETER Canvas
        The WPF Canvas control to draw on.
    .PARAMETER ChartPoints
        Array of [PSCustomObject]@{ Time; Value; IsGap } as returned by
        Invoke-CPUCreditsHistoryQuery. IsGap=$true points break the polyline.
    #>
    param(
        [System.Windows.Controls.Canvas]$Canvas,
        [object[]]$ChartPoints
    )

    # Always clear previous render before drawing new data
    $Canvas.Children.Clear()

    $w = $Canvas.ActualWidth
    $h = $Canvas.ActualHeight
    # Guard: canvas must be large enough to render meaningfully
    if ($w -lt 100 -or $h -lt 80) { return }

    # Chart margins - left is wider to fit Y-axis credit labels (e.g. "144.0")
    $ml = 55; $mr = 20; $mt = 15; $mb = 35
    $cw = $w - $ml - $mr   # chart plot width
    $ch = $h - $mt - $mb   # chart plot height

    $brushConv    = New-Object System.Windows.Media.BrushConverter
    $_chartBg     = if ($script:DarkTheme) { '#1E1E1E' } else { '#FAFAFA' }
    $_gridH       = if ($script:DarkTheme) { '#3F3F46' } else { '#E0E0E0' }
    $_gridV       = if ($script:DarkTheme) { '#2A2D2E' } else { '#F0F0F0' }
    $_axis        = if ($script:DarkTheme) { '#6A6A6A' } else { '#999999' }
    $_labelColor  = if ($script:DarkTheme) { '#9D9D9D' } else { '#666666' }

    # ── Helper: draw a line segment on the canvas ────────────────────────────
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

    # ── Helper: place a text label on the canvas ─────────────────────────────
    $addText = {
        param($text, $x, $y, $fontSize, $color, $hAlign)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $tb.FontSize = if ($fontSize) { $fontSize } else { 10 }
        $tb.Foreground = $brushConv.ConvertFromString($(if ($color) { $color } else { $_labelColor }))
        [System.Windows.Controls.Canvas]::SetLeft($tb, $x)
        [System.Windows.Controls.Canvas]::SetTop($tb, $y)
        if ($hAlign -eq 'Right') {
            $tb.TextAlignment = [System.Windows.TextAlignment]::Right
            $tb.Width = $x
            [System.Windows.Controls.Canvas]::SetLeft($tb, 0)
        }
        [void]$Canvas.Children.Add($tb)
    }

    # ── Chart background rectangle ───────────────────────────────────────────
    $bg = New-Object System.Windows.Shapes.Rectangle
    $bg.Width = $cw; $bg.Height = $ch
    $bg.Fill = $brushConv.ConvertFromString($_chartBg)
    [System.Windows.Controls.Canvas]::SetLeft($bg, $ml)
    [System.Windows.Controls.Canvas]::SetTop($bg, $mt)
    [void]$Canvas.Children.Add($bg)

    # ── Validate data ────────────────────────────────────────────────────────
    # Filter to non-gap points to determine the time span and max credit value
    $validPoints = @($ChartPoints | Where-Object { -not $_.IsGap })
    if ($validPoints.Count -eq 0) {
        # No data at all - show a "No data" label centred in the plot area
        & $addText 'No data available' ($ml + $cw / 2 - 45) ($mt + $ch / 2 - 8) 12 $null $null
        return
    }

    # Use ALL points (including gaps) to span the full time axis correctly
    $allTimes = @($ChartPoints | ForEach-Object { $_.Time })
    $minTime  = ($allTimes | Measure-Object -Minimum).Minimum
    $maxTime  = ($allTimes | Measure-Object -Maximum).Maximum
    $span     = ($maxTime - $minTime).TotalSeconds
    if ($span -le 0) { $span = 1 }

    # ── Auto-scale Y-axis ────────────────────────────────────────────────────
    # B-series VMs start with a fixed maximum credit balance (e.g. 144 for B2s).
    # Scale the axis to the highest observed value, rounded up to a nice number.
    $maxVal = [math]::Max(1, ($validPoints | ForEach-Object { $_.Value } | Measure-Object -Maximum).Maximum)
    $yMax   = if ($maxVal -le 10)   { 10 }
              elseif ($maxVal -le 50)  { [math]::Ceiling($maxVal / 10) * 10 }
              elseif ($maxVal -le 200) { [math]::Ceiling($maxVal / 20) * 20 }
              else                     { [math]::Ceiling($maxVal / 50) * 50 }

    # ── Gridlines (25%, 50%, 75%) ────────────────────────────────────────────
    foreach ($frac in @(0.25, 0.50, 0.75)) {
        $y = $mt + $ch * (1 - $frac)
        & $addLine $ml $y ($ml + $cw) $y $_gridH 1 @(4, 4)
    }

    # ── Y-axis labels (left, credit count) ───────────────────────────────────
    foreach ($frac in @(0, 0.25, 0.50, 0.75, 1.0)) {
        $y     = $mt + $ch * (1 - $frac) - 7
        $label = [math]::Round($yMax * $frac, 0).ToString()
        & $addText $label ($ml - 5) $y 10 '#7B1FA2' 'Right'
    }

    # ── Axes ─────────────────────────────────────────────────────────────────
    & $addLine $ml $mt $ml ($mt + $ch) '#7B1FA2' 1 $null           # Left Y-axis (purple)
    & $addLine $ml ($mt + $ch) ($ml + $cw) ($mt + $ch) $_axis 1 $null  # X-axis (bottom)

    # ── X-axis time labels ────────────────────────────────────────────────────
    $labelCount = [Math]::Min(6, [Math]::Max(2, [int]($cw / 100)))
    for ($i = 0; $i -le $labelCount; $i++) {
        $frac  = $i / $labelCount
        $t     = $minTime.AddSeconds($frac * $span)
        $x     = $ml + $frac * $cw
        $label = $t.ToLocalTime().ToString('HH:mm')
        & $addText $label ($x - 15) ($mt + $ch + 5) 10 $null $null
        # Thin vertical gridline at interior time ticks
        if ($i -gt 0 -and $i -lt $labelCount) {
            & $addLine $x $mt $x ($mt + $ch) $_gridV 1 $null
        }
    }

    # ── Threshold reference lines ─────────────────────────────────────────────
    # Amber at 30 credits - credits getting low, VM may start throttling
    if ($yMax -ge 10) {
        $yAmber = $mt + $ch * (1 - [math]::Min(1.0, 30.0 / $yMax))
        & $addLine $ml $yAmber ($ml + $cw) $yAmber '#FFA000' 1 @(6, 4)
        & $addText '30' ($ml + $cw + 3) ($yAmber - 7) 9 '#FFA000' $null
    }
    # Red at 10 credits - VM is being throttled now
    if ($yMax -ge 5) {
        $yRed = $mt + $ch * (1 - [math]::Min(1.0, 10.0 / $yMax))
        & $addLine $ml $yRed ($ml + $cw) $yRed '#D32F2F' 1 @(6, 4)
        & $addText '10' ($ml + $cw + 3) ($yRed - 7) 9 '#D32F2F' $null
    }

    # ── Helper: build segment-aware polylines from data points ───────────────
    # Azure Monitor returns a complete time series including null buckets for
    # periods when the VM was off / deallocated. Points with IsGap=$true act as
    # explicit segment breaks - when encountered the current polyline is flushed
    # and a new one started, so the line is never drawn across VM-off gaps.
    # This is the same pattern used by Update-DiskChart.
    $buildPolyline = {
        param($data, $color, $yMax)
        if ($data.Count -lt 2 -or $yMax -le 0) { return }

        $pl = $null; $points = $null

        for ($i = 0; $i -lt $data.Count; $i++) {
            $pt = $data[$i]

            # Gap marker - flush the current segment and skip this point
            if ($pt.IsGap) {
                if ($pl -and $points.Count -ge 2) { $pl.Points = $points; [void]$Canvas.Children.Add($pl) }
                $pl = $null; $points = $null
                continue
            }

            $xFrac = ($pt.Time - $minTime).TotalSeconds / $span
            $x     = $ml + $xFrac * $cw
            $y     = $mt + $ch * (1 - [Math]::Max(0, [Math]::Min($yMax, $pt.Value)) / $yMax)

            if ($null -eq $pl) {
                $pl = New-Object System.Windows.Shapes.Polyline
                $pl.Stroke          = $brushConv.ConvertFromString($color)
                $pl.StrokeThickness = 2
                $pl.StrokeLineJoin  = [System.Windows.Media.PenLineJoin]::Round
                $points = New-Object System.Windows.Media.PointCollection
            }
            [void]$points.Add([System.Windows.Point]::new($x, $y))
        }
        # Flush the final segment
        if ($pl -and $points.Count -ge 2) { $pl.Points = $points; [void]$Canvas.Children.Add($pl) }
    }

    # ── Draw the credits line (purple) ───────────────────────────────────────
    & $buildPolyline $ChartPoints '#7B1FA2' $yMax

}


function Update-PerfChart {
    <#
    .SYNOPSIS
        Draws a CPU/Mem line chart on a WPF Canvas.
    .DESCRIPTION
        Clears the Canvas and redraws all chart elements: background, gridlines,
        threshold lines (amber at 70%, red at 90%), axis labels, data polylines
        for CPU (blue) and Mem (orange), and a legend.

        The chart coordinate system:
          - Left margin (55px) for Y-axis percentage labels
          - Bottom margin (35px) for X-axis time labels
          - Top margin (15px) and right margin (15px) for padding
          - Y-axis: 0% at bottom to 100% at top (fixed scale)
          - X-axis: earliest to latest data point timestamp

        Data points are mapped to canvas coordinates:
          X = leftMargin + (time - minTime) / (maxTime - minTime) * chartWidth
          Y = topMargin  + (1 - value / 100) * chartHeight
    .PARAMETER Canvas
        The WPF Canvas control to draw on.
    .PARAMETER CpuData
        Array of [PSCustomObject]@{ Time; Value } for CPU %.
    .PARAMETER MemData
        Array of [PSCustomObject]@{ Time; Value } for Mem %.
    #>
    param(
        [System.Windows.Controls.Canvas]$Canvas,
        [object[]]$CpuData,
        [object[]]$MemData
    )

    $Canvas.Children.Clear()

    $w = $Canvas.ActualWidth
    $h = $Canvas.ActualHeight
    if ($w -lt 100 -or $h -lt 80) { return }   # too small to draw

    # Margins
    $ml = 55; $mr = 55; $mt = 15; $mb = 35
    $cw = $w - $ml - $mr    # chart area width
    $ch = $h - $mt - $mb    # chart area height

    $brushConv    = New-Object System.Windows.Media.BrushConverter
    $_chartBg     = if ($script:DarkTheme) { '#1E1E1E' } else { '#FAFAFA' }
    $_gridH       = if ($script:DarkTheme) { '#3F3F46' } else { '#E0E0E0' }
    $_gridV       = if ($script:DarkTheme) { '#2A2D2E' } else { '#F0F0F0' }
    $_axis        = if ($script:DarkTheme) { '#6A6A6A' } else { '#999999' }
    $_labelColor  = if ($script:DarkTheme) { '#9D9D9D' } else { '#666666' }

    # ── Helper: add a Line to the Canvas ─────────────────────────────────────
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

    # ── Helper: add a TextBlock to the Canvas at an absolute position ────────
    $addText = {
        param($text, $x, $y, $fontSize, $color, $hAlign)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $tb.FontSize = if ($fontSize) { $fontSize } else { 10 }
        $tb.Foreground = $brushConv.ConvertFromString($(if ($color) { $color } else { $_labelColor }))
        [System.Windows.Controls.Canvas]::SetLeft($tb, $x)
        [System.Windows.Controls.Canvas]::SetTop($tb, $y)
        if ($hAlign -eq 'Right') {
            $tb.TextAlignment = [System.Windows.TextAlignment]::Right
            $tb.Width = $x   # width = distance from left edge so right-aligned text ends at $x
            [System.Windows.Controls.Canvas]::SetLeft($tb, 0)
        }
        [void]$Canvas.Children.Add($tb)
    }

    # ── Chart background ─────────────────────────────────────────────────────
    $bg = New-Object System.Windows.Shapes.Rectangle
    $bg.Width = $cw; $bg.Height = $ch
    $bg.Fill = $brushConv.ConvertFromString($_chartBg)
    [System.Windows.Controls.Canvas]::SetLeft($bg, $ml)
    [System.Windows.Controls.Canvas]::SetTop($bg, $mt)
    [void]$Canvas.Children.Add($bg)

    # ── Horizontal gridlines at 25%, 50%, 75% ────────────────────────────────
    foreach ($pct in @(25, 50, 75)) {
        $y = $mt + $ch * (1 - $pct / 100)
        & $addLine $ml $y ($ml + $cw) $y $_gridH 1 @(4, 4)
    }

    # ── Threshold lines (match heat map thresholds from the grid) ────────────
    # Amber threshold at configured percentage (default 70%)
    $yAmber = $mt + $ch * (1 - $script:LawHeatMapAmberPct / 100)
    & $addLine $ml $yAmber ($ml + $cw) $yAmber '#FFB74D' 1 @(6, 3)
    & $addText "$([int]$script:LawHeatMapAmberPct)%" ($ml + $cw + 3) ($yAmber - 7) 9 '#FFB74D' $null
    # Red threshold at configured percentage (default 90%)
    $yRed = $mt + $ch * (1 - $script:LawHeatMapRedPct / 100)
    & $addLine $ml $yRed ($ml + $cw) $yRed '#E57373' 1 @(6, 3)
    & $addText "$([int]$script:LawHeatMapRedPct)%" ($ml + $cw + 3) ($yRed - 7) 9 '#E57373' $null

    # ── Y-axis labels (0%, 25%, 50%, 75%, 100%) ─────────────────────────────
    foreach ($pct in @(0, 25, 50, 75, 100)) {
        $y = $mt + $ch * (1 - $pct / 100) - 7
        & $addText "$pct%" ($ml - 5) $y 10 $null 'Right'
    }

    # ── Axes (solid border around chart area) ────────────────────────────────
    & $addLine $ml $mt $ml ($mt + $ch) $_axis 1 $null          # Y-axis (left)
    & $addLine $ml ($mt + $ch) ($ml + $cw) ($mt + $ch) $_axis 1 $null  # X-axis (bottom)

    # ── Determine time range from data ───────────────────────────────────────
    $allTimes = @()
    if ($CpuData.Count -gt 0) { $allTimes += $CpuData | ForEach-Object { $_.Time } }
    if ($MemData.Count -gt 0) { $allTimes += $MemData | ForEach-Object { $_.Time } }
    if ($allTimes.Count -eq 0) { return }

    $minTime = ($allTimes | Measure-Object -Minimum).Minimum
    $maxTime = ($allTimes | Measure-Object -Maximum).Maximum
    $span    = ($maxTime - $minTime).TotalSeconds
    if ($span -le 0) { $span = 1 }   # prevent division by zero

    # ── X-axis time labels (~6 evenly spaced) ────────────────────────────────
    $labelCount = [Math]::Min(6, [Math]::Max(2, [int]($cw / 100)))
    for ($i = 0; $i -le $labelCount; $i++) {
        $frac = $i / $labelCount
        $t    = $minTime.AddSeconds($frac * $span)
        $x    = $ml + $frac * $cw
        $label = $t.ToLocalTime().ToString('HH:mm')
        & $addText $label ($x - 15) ($mt + $ch + 5) 10 $null $null
        # Light vertical gridline
        if ($i -gt 0 -and $i -lt $labelCount) {
            & $addLine $x $mt $x ($mt + $ch) $_gridV 1 $null
        }
    }

    # ── Helper: build segment-aware Polylines from data points ─────────────
    # Splits into multiple Polylines wherever a gap > 2x the median interval
    # is detected, so the chart line breaks rather than drawing a misleading
    # diagonal across periods where the VM was off / not reporting.
    $buildPolyline = {
        param($data, $color)
        if ($data.Count -lt 2) { return }

        $intervals = for ($i = 1; $i -lt $data.Count; $i++) {
            ($data[$i].Time - $data[$i-1].Time).TotalSeconds
        }
        $sorted         = @($intervals | Sort-Object)
        $medianInterval = $sorted[[int]($sorted.Count / 2)]
        $gapThreshold   = $medianInterval * 2

        $newSeg = $true
        $pl = $null; $points = $null

        for ($i = 0; $i -lt $data.Count; $i++) {
            $pt    = $data[$i]
            $xFrac = ($pt.Time - $minTime).TotalSeconds / $span
            $x     = $ml + $xFrac * $cw
            $y     = $mt + $ch * (1 - [Math]::Max(0, [Math]::Min(100, $pt.Value)) / 100)

            if ($i -gt 0 -and ($pt.Time - $data[$i-1].Time).TotalSeconds -gt $gapThreshold) {
                $newSeg = $true
            }

            if ($newSeg) {
                if ($pl -and $points.Count -ge 2) { $pl.Points = $points; [void]$Canvas.Children.Add($pl) }
                $pl = New-Object System.Windows.Shapes.Polyline
                $pl.Stroke          = $brushConv.ConvertFromString($color)
                $pl.StrokeThickness = 2
                $pl.StrokeLineJoin  = [System.Windows.Media.PenLineJoin]::Round
                $points = New-Object System.Windows.Media.PointCollection
                $newSeg = $false
            }
            [void]$points.Add([System.Windows.Point]::new($x, $y))
        }
        if ($pl -and $points.Count -ge 2) { $pl.Points = $points; [void]$Canvas.Children.Add($pl) }
    }

    # ── Draw data lines ──────────────────────────────────────────────────────
    & $buildPolyline $CpuData '#1976D2'   # CPU - blue
    & $buildPolyline $MemData '#FB8C00'   # Mem - orange
}


function Show-PerformanceHistory {
    <#
    .SYNOPSIS
        Opens a popup window with line charts of CPU %, Mem %, Disk IOPS, and Queue Depth.
    .DESCRIPTION
        Called from the Session Hosts tab right-click context menu. Queries the
        configured Log Analytics Workspace for CPU/Mem data and the Azure Monitor
        Metrics API for Disk IOPS/Queue Depth. Renders two chart panels:
          - Top: CPU % and Mem % (fixed 0-100% Y-axis)
          - Bottom: Disk IOPS (left Y-axis, auto-scaled) and Queue Depth (right Y-axis)
        A ComboBox allows the user to select the time range (1h, 4h, 12h, 24h).
    .PARAMETER VmName
        The short VM name (from the 'VM Name' grid column).
    .PARAMETER VMResourceId
        Full ARM resource ID of the VM (for Azure Monitor Metrics API).
    #>
    param(
        [string]$VmName,
        [string]$VMResourceId
    )

    # Determine if disk metrics chart should be shown (need VMResourceId and ShowDiskPerf)
    $showDisk = $script:ShowDiskPerf -and $VMResourceId

    # Adjust window height based on whether disk chart is shown
    $winHeight = if ($showDisk) { '700' } else { '450' }

    $_perfWinBg    = if ($script:DarkTheme) { '#1E1E1E' } else { '#F4F6F9' }
    $_perfCardBg   = if ($script:DarkTheme) { '#2D2D30' } else { 'White' }
    $_perfBorderCl = if ($script:DarkTheme) { '#3F3F46' } else { '#DDE1E7' }
    $_perfLabelFg  = if ($script:DarkTheme) { '#D4D4D4' } else { '#333333' }
    $_perfHintFg   = if ($script:DarkTheme) { '#9D9D9D' } else { '#777777' }

    # Disk legend items injected into the unified top legend when disk chart is shown
    $diskLegendXaml = if ($showDisk) {
        "<Rectangle Width=`"14`" Height=`"14`" Fill=`"#2E7D32`" Margin=`"0,0,4,0`" RadiusX=`"2`" RadiusY=`"2`"/>" +
        "<TextBlock Text=`"Disk IOPS`" FontSize=`"11`" Foreground=`"$_perfLabelFg`" VerticalAlignment=`"Center`" Margin=`"0,0,14,0`"/>" +
        "<Rectangle Width=`"14`" Height=`"14`" Fill=`"#E65100`" Margin=`"0,0,4,0`" RadiusX=`"2`" RadiusY=`"2`"/>" +
        "<TextBlock Text=`"Queue Depth`" FontSize=`"11`" Foreground=`"$_perfLabelFg`" VerticalAlignment=`"Center`"/>"
    } else { '' }

    # ── Build the popup window XAML ──────────────────────────────────────────
    # When disk metrics are enabled, the window uses a Grid with two chart rows.
    $diskChartXaml = if ($showDisk) { @"
            <!-- Disk chart canvas -->
            <Border Grid.Row="1" Background="$_perfCardBg" BorderBrush="$_perfBorderCl" BorderThickness="1" CornerRadius="4" Margin="0,8,0,0">
                <Canvas x:Name="DiskChartCanvas" ClipToBounds="True"/>
            </Border>
"@ } else { '' }

    $diskRowDefs = if ($showDisk) {
        '<RowDefinition Height="*"/>'
    } else { '' }

    $_perfXamlStr = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Performance History - $([System.Security.SecurityElement]::Escape($VmName))"
        Height="$winHeight" Width="750"
        MinHeight="350" MinWidth="600"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize"
        Background="$_perfWinBg" FontFamily="Segoe UI">
    <Window.Resources>
        <!-- THEME_SLOT -->
    </Window.Resources>
    <DockPanel Margin="12">
        <!-- Top bar: time range selector + CPU/Mem legend -->
        <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Time Range:" VerticalAlignment="Center"
                       FontSize="12" Foreground="$_perfLabelFg" Margin="0,0,8,0"/>
            <ComboBox x:Name="TimeRangeCombo" Grid.Column="1" Width="140"
                      FontSize="12" SelectedIndex="0">
                <ComboBoxItem Content="Last 1 Hour"   Tag="PT1H"/>
                <ComboBoxItem Content="Last 4 Hours"  Tag="PT4H"/>
                <ComboBoxItem Content="Last 12 Hours" Tag="PT12H"/>
                <ComboBoxItem Content="Last 24 Hours" Tag="PT24H"/>
            </ComboBox>
            <!-- Legend -->
            <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
                <Rectangle Width="14" Height="14" Fill="#1976D2" Margin="0,0,4,0" RadiusX="2" RadiusY="2"/>
                <TextBlock Text="CPU %" FontSize="11" Foreground="$_perfLabelFg" VerticalAlignment="Center" Margin="0,0,14,0"/>
                <Rectangle Width="14" Height="14" Fill="#FB8C00" Margin="0,0,4,0" RadiusX="2" RadiusY="2"/>
                <TextBlock Text="Mem %" FontSize="11" Foreground="$_perfLabelFg" VerticalAlignment="Center" Margin="0,0,14,0"/>
                $diskLegendXaml
            </StackPanel>
        </Grid>
        <!-- Status bar at bottom -->
        <TextBlock x:Name="PerfStatus" DockPanel.Dock="Bottom"
                   FontSize="11" Foreground="$_perfHintFg" Margin="0,6,0,0"/>
        <!-- Chart panels -->
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>
                $diskRowDefs
            </Grid.RowDefinitions>
            <!-- CPU/Mem chart canvas -->
            <Border Grid.Row="0" Background="$_perfCardBg" BorderBrush="$_perfBorderCl" BorderThickness="1" CornerRadius="4">
                <Canvas x:Name="ChartCanvas" ClipToBounds="True"/>
            </Border>
            $diskChartXaml
        </Grid>
    </DockPanel>
</Window>
"@

    $_perfXamlStr = $_perfXamlStr -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\..\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    [xml]$_perfXml = $_perfXamlStr
    $perfWin = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $_perfXml))
    try { Set-WindowIcon -Window $perfWin -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}
    $perfWin.Owner = $window   # main dashboard window - enables CenterOwner
    if ($script:DarkTheme) {
        $perfWin.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
        $perfWin.Left = -32000
        $perfWin.Top  = -32000
        $perfWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($perfWin)).Handle
            $v = 1
            [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
        $perfWin.Add_ContentRendered(({
            $o = $perfWin.Owner
            if ($null -ne $o) {
                $perfWin.Left = $o.Left + ($o.Width  - $perfWin.ActualWidth)  / 2
                $perfWin.Top  = $o.Top  + ($o.Height - $perfWin.ActualHeight) / 2
            }
        }).GetNewClosure())
    }

    $chartCanvas  = $perfWin.FindName('ChartCanvas')
    $timeCombo    = $perfWin.FindName('TimeRangeCombo')
    $perfStatus   = $perfWin.FindName('PerfStatus')
    $diskCanvas   = if ($showDisk) { $perfWin.FindName('DiskChartCanvas') } else { $null }
    if ($script:DarkTheme) {
        $_darkCard = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0x2D,0x2D,0x30)
        $chartCanvas.Background = $_darkCard
        if ($diskCanvas) { $diskCanvas.Background = $_darkCard }
    }

    # ── Load and render chart data ───────────────────────────────────────────
    # This scriptblock is called on initial load and whenever the time range changes.
    # It runs synchronously on the UI thread (queries typically return in 1-2s).
    $script:_perfVmName      = $VmName
    $script:_perfVMResId     = $VMResourceId
    $script:_perfCanvas      = $chartCanvas
    $script:_perfDiskCanvas  = $diskCanvas
    $script:_perfStatus      = $perfStatus
    $script:_perfCpuData     = @()
    $script:_perfMemData     = @()
    $script:_perfIOPSData    = @()
    $script:_perfQueueData   = @()
    $script:_perfShowDisk    = $showDisk

    $loadChart = {
        param([string]$range)
        $script:_perfStatus.Text = 'Loading performance data...'
        $script:_perfCanvas.Children.Clear()
        if ($script:_perfDiskCanvas) { $script:_perfDiskCanvas.Children.Clear() }
        # Force a layout pass so the Canvas has its ActualWidth/Height set
        $script:_perfCanvas.UpdateLayout()
        if ($script:_perfDiskCanvas) { $script:_perfDiskCanvas.UpdateLayout() }

        try {
            # Query CPU/Mem from LAW
            $result = Invoke-PerfHistoryQuery -VmName $script:_perfVmName -TimeRange $range
            $script:_perfCpuData = $result.CPU
            $script:_perfMemData = $result.Mem

            if ($result.CPU.Count -gt 0 -or $result.Mem.Count -gt 0) {
                Update-PerfChart -Canvas $script:_perfCanvas `
                                 -CpuData $script:_perfCpuData `
                                 -MemData $script:_perfMemData
            }

            # Query Disk IOPS/Queue from Azure Monitor Metrics API
            $diskMsg = ''
            if ($script:_perfShowDisk -and $script:_perfDiskCanvas) {
                try {
                    $diskResult = Invoke-DiskMetricsHistoryQuery -VMResourceId $script:_perfVMResId -TimeRange $range
                    $script:_perfIOPSData  = $diskResult.IOPS
                    $script:_perfQueueData = $diskResult.QueueDepth

                    if ($diskResult.IOPS.Count -gt 0 -or $diskResult.QueueDepth.Count -gt 0) {
                        Update-DiskChart -Canvas $script:_perfDiskCanvas `
                                         -IOPSData $script:_perfIOPSData `
                                         -QueueData $script:_perfQueueData
                        $diskMsg = " | Disk: $([Math]::Max($diskResult.IOPS.Count, $diskResult.QueueDepth.Count)) point(s)"
                    } else {
                        $diskMsg = ' | No disk metrics available'
                    }
                } catch {
                    $diskMsg = " | Disk query failed: $_"
                }
            }

            $cpuMemCount = [Math]::Max($result.CPU.Count, $result.Mem.Count)
            if ($cpuMemCount -eq 0 -and -not $diskMsg) {
                $script:_perfStatus.Text = 'No performance data available for this time range.'
            } else {
                $script:_perfStatus.Text = "CPU/Mem: $cpuMemCount data point(s)$diskMsg"
            }
        }
        catch {
            $script:_perfStatus.Text = "Query failed: $_"
        }
    }

    # ── Time range ComboBox handler ──────────────────────────────────────────
    $timeCombo.Add_SelectionChanged({
        $sel = $timeCombo.SelectedItem
        if ($null -eq $sel) { return }
        $range = $sel.Tag
        & $loadChart $range
    }.GetNewClosure())

    # ── Resize handler: redraw charts when Canvas size changes ───────────────
    $chartCanvas.Add_SizeChanged({
        if ($script:_perfCpuData.Count -gt 0 -or $script:_perfMemData.Count -gt 0) {
            Update-PerfChart -Canvas $script:_perfCanvas `
                             -CpuData $script:_perfCpuData `
                             -MemData $script:_perfMemData
        }
    }.GetNewClosure())

    if ($diskCanvas) {
        $diskCanvas.Add_SizeChanged({
            if ($script:_perfIOPSData.Count -gt 0 -or $script:_perfQueueData.Count -gt 0) {
                Update-DiskChart -Canvas $script:_perfDiskCanvas `
                                 -IOPSData $script:_perfIOPSData `
                                 -QueueData $script:_perfQueueData
            }
        }.GetNewClosure())
    }

    # ── Initial load with default time range (1 hour) ────────────────────────
    # Use Loaded event so the Canvas has been measured and has ActualWidth/Height.
    $perfWin.Add_Loaded({
        & $loadChart 'PT1H'
    }.GetNewClosure())

    $perfWin.Show()
}


function Show-CPUCreditsHistory {
    <#
    .SYNOPSIS
        Opens a popup window showing a CPU Credits Remaining history chart for a B-series VM.
    .DESCRIPTION
        Called from the Session Hosts context menu when a B-series VM (Standard_B*) is selected.
        Only B-series VMs support CPU credit bursting, so the menu item is greyed out for all
        other VM SKUs.

        On open the function:
          1. Queries Azure Monitor for CPU Credits Remaining via Invoke-CPUCreditsHistoryQuery
          2. Renders the chart using Update-CreditsChart on a WPF Canvas
          3. Shows a status bar with the data point count and the query time range

        The window is resizable and the chart redraws on resize via SizeChanged event.
        A ComboBox lets the user switch time ranges (PT1H / PT4H / PT12H / PT24H)
        and automatically reloads the chart from Azure Monitor.

        Threshold reference lines at 30 credits (amber) and 10 credits (red) are drawn
        by Update-CreditsChart to match the colour bands used in the live grid column.

        Gap handling: Azure Monitor returns full time-series buckets, with null values
        for periods when the VM was deallocated. Null buckets become IsGap=$true markers
        so Update-CreditsChart never draws a line across a VM-off gap.
    .PARAMETER VmName
        Short display name for the window title (e.g. "CUKHP01UKWA-183").
    .PARAMETER VMResourceId
        Full ARM resource ID of the VM. Required by Invoke-CPUCreditsHistoryQuery.
    #>
    param(
        [string]$VmName,
        [string]$VMResourceId
    )

    # ── XAML layout: single canvas chart with time range selector ─────────────
    $escapedName  = [System.Security.SecurityElement]::Escape($VmName)
    $_credWinBg   = if ($script:DarkTheme) { '#1E1E1E' } else { '#F4F6F9' }
    $_credCardBg  = if ($script:DarkTheme) { '#2D2D30' } else { 'White' }
    $_credBorderCl = if ($script:DarkTheme) { '#3F3F46' } else { '#DDE1E7' }
    $_credLabelFg = if ($script:DarkTheme) { '#D4D4D4' } else { '#555555' }
    $_credHintFg  = if ($script:DarkTheme) { '#9D9D9D' } else { '#777777' }

    $_credXamlStr = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="CPU Credits History - $escapedName"
        Height="450" Width="750"
        MinHeight="320" MinWidth="500"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize"
        Background="$_credWinBg" FontFamily="Segoe UI">
    <Window.Resources>
        <!-- THEME_SLOT -->
    </Window.Resources>
    <DockPanel Margin="12">
        <!-- Top toolbar: time range selector, loading indicator, and legend -->
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <!-- Left: time range label + combo + loading text -->
            <StackPanel Orientation="Horizontal" DockPanel.Dock="Left" VerticalAlignment="Center">
                <TextBlock Text="Time range:" VerticalAlignment="Center" Margin="0,0,6,0"
                           FontSize="13" Foreground="$_credLabelFg"/>
                <ComboBox x:Name="TimeRangeCombo" Width="80" FontSize="13">
                    <ComboBoxItem Content="1 hour"  Tag="PT1H"  IsSelected="True"/>
                    <ComboBoxItem Content="4 hours" Tag="PT4H"/>
                    <ComboBoxItem Content="12 hours" Tag="PT12H"/>
                    <ComboBoxItem Content="24 hours" Tag="PT24H"/>
                </ComboBox>
                <TextBlock x:Name="LoadingText" Text="" VerticalAlignment="Center"
                           Margin="10,0,0,0" FontSize="12" Foreground="$_credHintFg" FontStyle="Italic"/>
            </StackPanel>
            <!-- Right: legend items pushed to the far right -->
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <Rectangle Width="12" Height="12" Fill="#7B1FA2" Margin="0,0,4,0" RadiusX="2" RadiusY="2"/>
                <TextBlock Text="CPU Credits Remaining" FontSize="11" Foreground="#7B1FA2" VerticalAlignment="Center"/>
                <Rectangle Width="20" Height="2" Fill="#FFA000" Margin="14,0,4,0"/>
                <TextBlock Text="30 (amber)" FontSize="11" Foreground="#FFA000" VerticalAlignment="Center"/>
                <Rectangle Width="20" Height="2" Fill="#D32F2F" Margin="14,0,4,0"/>
                <TextBlock Text="10 (red)" FontSize="11" Foreground="#D32F2F" VerticalAlignment="Center"/>
            </StackPanel>
        </DockPanel>
        <!-- Status bar at bottom: data point count / error messages -->
        <TextBlock x:Name="StatusText" DockPanel.Dock="Bottom"
                   FontSize="11" Foreground="$_credHintFg" Margin="0,6,0,0"/>
        <!-- Chart canvas fills the remaining space -->
        <Border Background="$_credCardBg" BorderBrush="$_credBorderCl" BorderThickness="1" CornerRadius="4">
            <Canvas x:Name="CreditsCanvas"/>
        </Border>
    </DockPanel>
</Window>
"@

    $_credXamlStr = $_credXamlStr -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\..\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    [xml]$_credXml = $_credXamlStr
    $credWin = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $_credXml))
    try { Set-WindowIcon -Window $credWin -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}
    $credWin.Owner = $window   # main dashboard window - enables CenterOwner
    if ($script:DarkTheme) {
        $credWin.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
        $credWin.Left = -32000
        $credWin.Top  = -32000
        $credWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($credWin)).Handle
            $v = 1
            [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
        $credWin.Add_ContentRendered(({
            $o = $credWin.Owner
            if ($null -ne $o) {
                $credWin.Left = $o.Left + ($o.Width  - $credWin.ActualWidth)  / 2
                $credWin.Top  = $o.Top  + ($o.Height - $credWin.ActualHeight) / 2
            }
        }).GetNewClosure())
    }

    $credCanvas      = $credWin.FindName('CreditsCanvas')
    $timeRangeCombo  = $credWin.FindName('TimeRangeCombo')
    $statusTb        = $credWin.FindName('StatusText')
    $loadingTb       = $credWin.FindName('LoadingText')
    if ($script:DarkTheme -and $credCanvas) {
        $credCanvas.Background = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0x2D,0x2D,0x30)
    }

    # ── Script-scope cache for chart data (used by SizeChanged redraw) ────────
    # Stored in $script: so the SizeChanged closure can access the last dataset
    # without making a new API call on every pixel resize.
    $script:_creditsData = @()

    # ── $loadChart: query Azure Monitor and redraw ────────────────────────────
    # Closure that captures $VMResourceId, $VmName, and the WPF controls.
    # Called on initial load (Loaded event) and whenever the time range changes.
    $loadChart = {
        param([string]$timeRange)

        # Guard: no resource ID means we can't query Azure Monitor
        if ([string]::IsNullOrWhiteSpace($VMResourceId)) {
            $statusTb.Text = 'No VM resource ID available - cannot query Azure Monitor.'
            Write-Verbose "[CPUCreditsHistory] VMResourceId is empty for $VmName, aborting query."
            return
        }

        $loadingTb.Text = 'Loading...'
        $statusTb.Text  = ''
        Write-Verbose "[CPUCreditsHistory] Querying credits history for $VmName, range=$timeRange"

        try {
            # Query Azure Monitor metrics API for CPU Credits Remaining
            $result = Invoke-CPUCreditsHistoryQuery -VMResourceId $VMResourceId -TimeRange $timeRange

            $creditsData = @($result.Credits)
            Write-Verbose "[CPUCreditsHistory] Received $($creditsData.Count) total buckets (including null/gap buckets)."

            # Cache the data for SizeChanged redraws (no re-query needed on resize)
            $script:_creditsData = $creditsData

            # Count non-gap points for the status bar
            $validPts = @($creditsData | Where-Object { -not $_.IsGap })
            Write-Verbose "[CPUCreditsHistory] Valid (non-gap) data points: $($validPts.Count)"

            # Render the chart
            Update-CreditsChart -Canvas $credCanvas -ChartPoints $creditsData

            if ($validPts.Count -gt 0) {
                $statusTb.Text = "$($validPts.Count) data points  |  $timeRange"
            } else {
                # This can happen if the VM was deallocated for the entire time range
                $statusTb.Text = "No CPU credits data found for the selected time range."
            }
        }
        catch {
            # Surface any API / parse errors in the status bar rather than a popup
            Write-Verbose "[CPUCreditsHistory] ERROR: $_"
            $statusTb.Text = "Error loading data: $_"
        }
        finally {
            $loadingTb.Text = ''
        }
    }.GetNewClosure()

    # ── Time range ComboBox changed: reload chart ─────────────────────────────
    $timeRangeCombo.Add_SelectionChanged({
        $item = $timeRangeCombo.SelectedItem
        if ($null -eq $item) { return }
        $tr = $item.Tag
        Write-Verbose "[CPUCreditsHistory] Time range changed to $tr for $VmName"
        & $loadChart $tr
    }.GetNewClosure())

    # ── Canvas resize: redraw from cached data (no API call) ──────────────────
    # SizeChanged fires whenever the window is resized. We redraw using the
    # already-fetched dataset so no extra API calls are made on resize.
    $credCanvas.Add_SizeChanged({
        if ($script:_creditsData.Count -gt 0) {
            Update-CreditsChart -Canvas $credCanvas -ChartPoints $script:_creditsData
        }
    }.GetNewClosure())

    # ── Initial data load on Loaded event ────────────────────────────────────
    # Loaded fires after XAML layout is complete, so ActualWidth/Height are valid.
    $credWin.Add_Loaded({
        & $loadChart 'PT1H'
    }.GetNewClosure())

    $credWin.Show()
}


function Show-InputDelayBreakdown {
    <#
    .SYNOPSIS
        Opens a popup showing the individual per-process input delay samples
        that make up the aggregated Median / P95 values in the Session Hosts grid.
    .DESCRIPTION
        Called from the Session Hosts tab right-click context menu. Queries the
        configured Log Analytics Workspace for the raw "User Input Delay per Process"
        counter samples over the last hour and displays them in a sortable DataGrid.
        A summary bar shows the total sample count, median, and P95.
    .PARAMETER VmName
        The short VM name (from the 'VM Name' grid column).
    #>
    param([string]$VmName)

    # ── Query LAW for per-process input delay samples ─────────────────────────
    $vmLower = $VmName.ToLower()

    # Build process exclusion filter (same list as the main grid query)
    $excludeKql = ''
    if ($script:InputDelayExcludeProcesses.Count -gt 0) {
        $exList = ($script:InputDelayExcludeProcesses | ForEach-Object { "`"$_`"" }) -join ', '
        $excludeKql = "| where not(InstanceName has_any ($exList))"
    }

    $kql = @"
Perf
| where TimeGenerated > ago(1h)
| where ObjectName == "User Input Delay per Process"
| where CounterName == "Max Input Delay"
| where InstanceName !in ("Max", "Average")
$excludeKql
| where CounterValue > 0 and CounterValue < 10000
| extend ComputerShort = tolower(split(Computer, '.')[0])
| where ComputerShort == "$vmLower"
| project TimeGenerated, Process = InstanceName, InputDelay = round(CounterValue, 0)
| order by InputDelay desc
"@

    $resp = Invoke-LawQuery -Kql $kql -Timespan 'PT1H' `
                -WorkspaceResourceId $script:LawWorkspaceResourceId `
                -QueryBaseUrl $script:LawQueryBaseUrl

    # ── Parse columnar JSON response into objects ─────────────────────────────
    $rows = [System.Collections.Generic.List[PSObject]]::new()

    if ($resp.tables -and $resp.tables[0].rows -and $resp.tables[0].rows.Count -gt 0) {
        $cols = @($resp.tables[0].columns | ForEach-Object {
            $n = [string]$_.name
            if (-not $n) { $n = [string]$_.ColumnName }
            if (-not $n) { $n = [string]$_ }
            $n
        })
        $colsLower = @($cols | ForEach-Object { $_.ToLower() })
        $idxTime    = [array]::IndexOf($colsLower, 'timegenerated')
        $idxProcess = [array]::IndexOf($colsLower, 'process')
        $idxDelay   = [array]::IndexOf($colsLower, 'inputdelay')

        foreach ($r in $resp.tables[0].rows) {
            $ts = if ($idxTime -ge 0) { try { [datetime]$r[$idxTime] } catch { $null } } else { $null }
            $rows.Add([PSCustomObject]@{
                'Time'            = if ($ts) { $ts.ToString('HH:mm:ss') } else { '-' }
                'Process'         = if ($idxProcess -ge 0) { [string]$r[$idxProcess] } else { '-' }
                'Input Delay (ms)' = if ($idxDelay -ge 0) { [double]$r[$idxDelay] } else { 0 }
            })
        }
    }

    # ── Compute summary statistics ────────────────────────────────────────────
    $sampleCount = $rows.Count
    $summaryText = "No input delay samples in the last hour."
    if ($sampleCount -gt 0) {
        $sorted = @($rows | Sort-Object 'Input Delay (ms)')
        $medianIdx = [math]::Floor($sampleCount / 2)
        $median = $sorted[$medianIdx].'Input Delay (ms)'
        $p95Idx = [math]::Floor($sampleCount * 0.95)
        if ($p95Idx -ge $sampleCount) { $p95Idx = $sampleCount - 1 }
        $p95 = $sorted[$p95Idx].'Input Delay (ms)'
        $summaryText = "$sampleCount samples  |  Median: ${median}ms  |  P95: ${p95}ms  |  Capped at 10,000ms"
    }

    # ── Build the popup window ────────────────────────────────────────────────
    $escapedName = [System.Security.SecurityElement]::Escape($VmName)
    [xml]$delayXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Input Delay Breakdown - $escapedName"
        Height="500" Width="620"
        MinHeight="350" MinWidth="500"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize"
        Background="#F4F6F9" FontFamily="Segoe UI">
    <DockPanel Margin="12">
        <!-- Summary bar -->
        <TextBlock x:Name="SummaryText" DockPanel.Dock="Top"
                   FontSize="13" FontWeight="SemiBold" Foreground="#333"
                   Margin="0,0,0,8"/>
        <!-- Status bar at bottom -->
        <TextBlock x:Name="StatusText" DockPanel.Dock="Bottom"
                   FontSize="11" Foreground="#777" Margin="0,6,0,0"/>
        <!-- DataGrid fills remaining space -->
        <Border Background="{DynamicResource Avd.Card.Bg}" BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1" CornerRadius="4">
            <DataGrid x:Name="DelayGrid"
                      AutoGenerateColumns="False"
                      IsReadOnly="True"
                      CanUserSortColumns="True"
                      HeadersVisibility="Column"
                      GridLinesVisibility="Horizontal"
                      BorderThickness="0"
                      FontSize="12"
                      RowHeight="26"
                      ColumnHeaderHeight="30"
                      AlternatingRowBackground="#F9FAFB"
                      HorizontalScrollBarVisibility="Auto"
                      VerticalScrollBarVisibility="Auto">
                <DataGrid.Columns>
                    <DataGridTextColumn Header="Time" Binding="{Binding Path='Time'}" Width="80"/>
                    <DataGridTextColumn Header="Process" Binding="{Binding Path='Process'}" Width="*"/>
                    <DataGridTextColumn Header="Input Delay (ms)" Binding="{Binding Path='Input Delay (ms)'}" Width="120">
                        <DataGridTextColumn.ElementStyle>
                            <Style TargetType="TextBlock">
                                <Setter Property="HorizontalAlignment" Value="Right"/>
                                <Setter Property="Padding" Value="0,0,8,0"/>
                            </Style>
                        </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                </DataGrid.Columns>
            </DataGrid>
        </Border>
    </DockPanel>
</Window>
"@

    $delayReader = New-Object System.Xml.XmlNodeReader $delayXaml
    $delayWin    = [System.Windows.Markup.XamlReader]::Load($delayReader)
    $delayWin.Owner = $window   # main dashboard window - enables CenterOwner

    $delayGrid   = $delayWin.FindName('DelayGrid')
    $summaryTb   = $delayWin.FindName('SummaryText')
    $statusTb    = $delayWin.FindName('StatusText')

    $summaryTb.Text = $summaryText

    if ($sampleCount -gt 0) {
        $delayGrid.ItemsSource = $rows
        $statusTb.Text = "$sampleCount row(s) - sorted by input delay descending"
    } else {
        $statusTb.Text = "No data available."
    }

    $delayWin.ShowDialog() | Out-Null
}


# =============================================================================
# 2b. Lightweight host pool map refresh
#
# Populates $script:shToPoolMap (lowercase VM name to host pool name) without
# running the full Session Hosts tab refresh. Called by the Unique Users popup
# when the user hasn't visited the Session Hosts tab yet and the map is empty.
# Makes one host pools list REST call plus one session hosts call per pool.
# Sequential (no RunspacePool needed) - just names, no metrics.
# Defined here at dot-source time so it is available to all other tab scripts.
# =============================================================================

function Invoke-ShToPoolMapRefresh {
    # Use current subscription if switched, fall back to the initial subscription ID
    $subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }
    if (-not $subId) { Write-Log "[ShToPoolMap] Skipped - no subscription ID"; return }
    # Ensure the map exists even if Initialize-SessionHostsTab hasn't run yet
    if (-not $script:shToPoolMap) { $script:shToPoolMap = @{} }
    try {
        $tok    = Get-ArmToken
        $avdApi = '2024-04-03'
        $pools  = @(Invoke-ArmRestMethod -Method GET `
            -Path "/subscriptions/$subId/providers/Microsoft.DesktopVirtualization/hostPools" `
            -Token $tok -ApiVersion $avdApi)
        Write-Log "[ShToPoolMap] Found $($pools.Count) host pool(s)"
        foreach ($hp in $pools) {
            $rg   = $hp.id.Split('/')[4]
            $name = $hp.name
            $shs  = @(Invoke-ArmRestMethod -Method GET `
                -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.DesktopVirtualization/hostPools/$name/sessionHosts" `
                -Token $tok -ApiVersion $avdApi)
            foreach ($sh in $shs) {
                # Session host name format is "hostpoolname/VMNAME.domain" - extract short VM name
                $vmName = ($sh.name.Split('/')[-1] -split '\.')[0]
                if ($vmName) { $script:shToPoolMap[$vmName.ToLower()] = $name }
            }
        }
        Write-Log "[ShToPoolMap] Populated $($script:shToPoolMap.Count) entries from $($pools.Count) host pool(s)"
    } catch {
        Write-Log "[ShToPoolMap] ERROR: $_"
    }
}

# =============================================================================
# 3. Initialise all Session Hosts tab UI elements, event handlers and state
#
# Called once from the main script after the WPF window has been loaded.
# Parameters:

function Initialize-SessionHostsTab {
    param(
        [System.Windows.Window]$Window,
        [string]$ContextFile,
        [string]$SubscriptionId,
        $HpPool
    )

    # ── Create the dedicated session host refresh runspaces ──────────────────────
    #
    # TWO-PASS DESIGN:
    #   Pass 1 (Core)    - $script:vmCoreScript runs in $script:vmRefreshRunspace.
    #                      Handles Phases 1-3 (AVD host/session REST + Resource Graph).
    #                      Returns quickly so the grid renders with VM names/states/sessions
    #                      before the slow Azure Monitor / LAW calls start.
    #
    #   Pass 2 (Metrics) - $script:vmMetricsScript runs in $script:vmMetricsRunspace.
    #                      Handles Phases 4-5b (Log Analytics + Azure Monitor disk metrics
    #                      + CPU credits). Launched automatically after Pass 1 completes.
    #                      Results are merged into the existing DataTable rows via
    #                      _SH_BackfillMetrics without clearing the grid - scroll position
    #                      and sort order are preserved.
    #
    # Both runspaces stay alive for the entire session; no Az module loading cost is
    # paid after the first use. MTA apartment state is required for COM interop used
    # internally by some .NET HTTP classes on Windows (prevents rare hangs).
    $script:vmRefreshRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:vmRefreshRunspace.ApartmentState = 'MTA'
    $script:vmRefreshRunspace.Open()

    # Metrics runspace: separate from the Core runspace so Pass 2 can run while the
    # UI is already displaying Pass 1 data. Using a separate runspace (rather than
    # re-using vmRefreshRunspace) allows Pass 1 to start again on its 60-second cycle
    # without waiting for Pass 2 to finish.
    $script:vmMetricsRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:vmMetricsRunspace.ApartmentState = 'MTA'
    $script:vmMetricsRunspace.Open()

    # ── Bind named controls from the XAML ────────────────────────────────────
    # FindName() resolves x:Name="..." attributes after the window has been loaded.
    $script:SessionHostsTab    = $Window.FindName('SessionHostsTab')
    $script:SHGrid             = $Window.FindName('SHGrid')
    $script:SHGridZoom         = $Window.FindName('SHGridZoom')
    $script:SHFilterBox        = $Window.FindName('SHFilterBox')
    $script:SHStatusText       = $Window.FindName('SHStatusText')   # top-right status/countdown
    $script:SHStartButton      = $Window.FindName('SHStartButton')
    $script:SHDeallocateButton = $Window.FindName('SHDeallocateButton')
    $script:SHRestartButton    = $Window.FindName('SHRestartButton')
    $script:SHActionStatus       = $Window.FindName('SHActionStatus') # bottom-left action result
    $script:SHRefreshButton        = $Window.FindName('SHRefreshButton')
    $script:SHClearFiltersButton   = $Window.FindName('SHClearFiltersButton')
    $script:SHHideEmptyCheckBox    = $Window.FindName('SHHideEmptyCheckBox')
    $script:SHExportButton         = $Window.FindName('SHExportButton')
    $script:SHLoadCostsButton      = $Window.FindName('SHLoadCostsButton')
    $script:SHTotalsBar            = $Window.FindName('SHTotalsBar')
    $script:SHTotalCompute         = $Window.FindName('SHTotalCompute')
    $script:SHTotalDisk            = $Window.FindName('SHTotalDisk')
    $script:SHTotalTxn             = $Window.FindName('SHTotalTxn')
    $script:SHEnableDrainButton    = $Window.FindName('SHEnableDrainButton')
    $script:SHDisableDrainButton   = $Window.FindName('SHDisableDrainButton')

    # ── Ctrl+MouseWheel zoom ────────────────────────────────────────────────────
    # Hold Ctrl and scroll the mouse wheel to scale the grid between 60% and 150%
    # in 5% increments. Uses the XAML ScaleTransform (SHGridZoom) applied via
    # LayoutTransform so the grid resizes within its layout slot. PreviewMouseWheel
    # fires before the DataGrid's built-in scroll handler; setting Handled = $true
    # prevents the grid from scrolling while zooming.
    $script:SHGrid.Add_PreviewMouseWheel({
        if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) {
            $_.Handled = $true
            $delta = if ($_.Delta -gt 0) { 0.05 } else { -0.05 }
            $new = [Math]::Round($script:SHGridZoom.ScaleX + $delta, 2)
            $new = [Math]::Max(0.6, [Math]::Min(1.5, $new))
            $script:SHGridZoom.ScaleX = $new
            $script:SHGridZoom.ScaleY = $new
        }
    })

    # ── Initialise module-scope state variables ───────────────────────────────
    $script:vmContextFile            = $ContextFile   # stored for subscription switch (Az.Accounts)
    $script:vmSubId                  = $SubscriptionId # stored for REST API calls
    $script:vmHpPool                 = $HpPool        # stored so Invoke-SessionHostsTabRefresh can inject it
    $script:vmDataTable              = $null           # current DataTable bound to SHGrid
    $script:shToPoolMap              = @{}             # lowercase VM name → Host Pool name; shared with Session History tab
    $script:vmActionHandle           = $null           # IAsyncResult for the running power action
    $script:vmActionPS               = $null           # PowerShell instance for the power action
    $script:vmActionRS               = $null           # throw-away runspace for the power action
    $script:vmHandle                 = $null           # IAsyncResult for the running Core (Pass 1) job
    $script:vmPS                     = $null           # PowerShell instance for the Core (Pass 1) job
    $script:vmMetricsHandle          = $null           # IAsyncResult for the running Metrics (Pass 2) job
    $script:vmMetricsPS              = $null           # PowerShell instance for the Metrics (Pass 2) job
    # Hold the first refresh until the RG location cache is populated by the main
    # background refresh (which runs in parallel at startup). Both jobs start
    # simultaneously; if the session hosts job wins the race the RG locations
    # aren't available yet and every VM shows Region = 'unknown'.
    # Setting MaxValue here means the timer-gate below won't fire until
    # Invoke-SessionHostsTabTimer explicitly resets it to Now once the cache
    # has entries - at which point all RG lookups are guaranteed to succeed.
    $script:vmNextRefresh            = [DateTime]::MaxValue
    $script:vmTabVisited             = $false          # set to $true when the user first clicks the Session Hosts tab
    $script:vmLastRefreshTime        = $null           # timestamp of the most recently completed refresh
    $script:vmCountText              = ''              # "X VM(s)  Available: Y  Other: Z" summary string (total)
    $script:vmFilteredCountText     = $null           # same format but scoped to filtered rows; $null when no filter active
    $script:vmPhase5Mode          = $null           # "Metrics: Batch", "Metrics: Per-VM", or mixed - set after first Phase 5 completes
    $script:vmActionLabel            = ''              # "Start" / "Deallocate" / "Restart" for status text
    $script:vmActionType             = ''              # 'Power' / 'Drain' - controls timer completion handler
    $script:vmActionSkippedNote      = ''              # appended to completion message when VMs were skipped (already in target state)
    $script:vmRegionRetryCount           = 0               # rapid-retry counter for unknown-region VMs (max 3, then normal 60s cycle)
    $script:VmRefreshIntervalSeconds     = 60              # how often the dedicated refresh runs
    $script:metricsRegionalBatchFailed   = @{}             # region -> $true when batch DNS fails; skip batch on subsequent refreshes

    # ── Sort state ─────────────────────────────────────────────────────────────
    # Preserved across 60-second refresh cycles so user-chosen sort survives.
    # Cleared on subscription switch by Reset-SessionHostsTab.
    $script:shSortColumn    = $null   # column header text (e.g. 'CPU %')
    $script:shSortDirection = $null   # [System.ComponentModel.ListSortDirection]

    # ── Per-column dropdown filter state ──────────────────────────────────────
    # Selections survive across 60-second refresh cycles (AutoGeneratingColumn
    # restores them). Cleared on subscription switch by Reset-SessionHostsTab.
    $script:shDropdownSelections = @{}
    $script:shDropdownCombos    = @{}   # column name -> ComboBox reference (for Clear Filters)

    # ── Cost cache ──────────────────────────────────────────────────────────────
    # Populated once when the user clicks Load Costs. Keyed by VM Name.
    # _SH_UpdateGrid reapplies these values after each DataTable rebuild so costs
    # survive auto-refresh cycles without re-calling the Retail Prices API.
    $script:shCostCache     = @{}   # VM Name -> @{ Compute=[double]; Disk=[double]; Txn=[double] }
    $script:shTxnMoCache   = @{}   # VM Name -> actual billed monthly transaction cost (double) from Cost Management
    # Last MetricRows returned by the Metrics pass. _SH_UpdateGrid reapplies these
    # after each Core-pass DataTable rebuild so metric columns (CPU%, Disk IOPS, etc.)
    # are not blanked during a refresh cycle while the next Metrics pass is in-flight.
    $script:shMetricsCache  = @()  # array of PSCustomObject rows with Phase 4+5 fields stamped in
    $script:shLawErrorShown = $false  # show LAW access error popup at most once per session
    $script:shCostPS        = $null # PowerShell instance for the background pricing fetch
    $script:shCostHandle    = $null # IAsyncResult for the pricing fetch
    # NOTE: $script:shCostTimer is intentionally NOT reset here.
    # cost-lookup.ps1 creates and configures the DispatcherTimer (with its tick handler)
    # at dot-source time, before Initialize-SessionHostsTab is called. Overwriting it
    # with $null here would destroy the tick handler and break the cost fetch completion loop.
    $script:shLastVmRows    = @()   # Last VmRows passed to _SH_UpdateGrid (for cost refresh)
    $script:shLastTimestamp = ''    # Last Timestamp passed to _SH_UpdateGrid
    $script:shFilterableColumns = @(
        'Host Pool', 'Region', 'Status', 'Power State', 'Health State',
        'Drain Mode', 'Avail Zone', 'VM SKU', 'Disk SKU', 'Scaling Exclude'
    )

    # ── Column header setup ───────────────────────────────────────────────────
    # AutoGeneratingColumn fires for every column when ItemsSource is set.
    # Hidden columns (_RG, _SHName) are cancelled. Filterable columns get a
    # custom header with a ComboBox dropdown; all others keep plain text.

    $script:SHGrid.Add_AutoGeneratingColumn({
        param($s, $e)

        # Hide internal helper columns (including heat map colour hints)
        if ($e.Column.Header -in @('_RG', '_HpRG', '_SHName', '_CPUSort', '_MemSort', '_DiskSort', '_CPUColor', '_MemColor', '_DiskColor', '_InputDelaySort', '_InputDelayColor', '_InputDelayP95Sort', '_InputDelayP95Color', '_DiskIOPSSort', '_DiskIOPSPctSort', '_DiskIOPSPctColor', '_DiskQueueSort', '_DiskQueueColor', '_DiskProvIOPS', '_VMResourceId', '_UserTooltip', '_HealthTooltip', '_DiskTier', '_DiskSkuRaw', '_ComputeCostSort', '_DiskCostSort', '_TxnCostSort', '_TxnMoCostSort', '_OsDiskResourceId', '_CPUCreditsSort', '_CPUCreditsColor', '_PricingOsType')) { $e.Cancel = $true; return }

        # Hide disabled metric columns based on $Show* toggles
        $colName = [string]$e.Column.Header
        if ((-not $script:ShowCPU        -and $colName -eq 'CPU %') -or
            (-not $script:ShowMem        -and $colName -eq 'Mem %') -or
            (-not $script:ShowDisk       -and $colName -eq 'OS Disk %') -or
            (-not $script:ShowInputDelay -and $colName -in @('Input Delay Median', 'Input Delay P95')) -or
            (-not $script:ShowDiskPerf  -and $colName -in @('OS Disk IOPS', 'OS Disk IOPS %', 'OS Disk Queue'))) { $e.Cancel = $true; return }
        # Preserve click-to-sort when using a custom header element.
        # CPU %, Mem %, and Disk % sort by hidden numeric columns so 6.4% < 34%.
        $e.Column.SortMemberPath = switch ($colName) {
            'CPU %'              { '_CPUSort' }
            'Mem %'              { '_MemSort' }
            'OS Disk %'          { '_DiskSort' }
            'Input Delay Median' { '_InputDelaySort' }
            'Input Delay P95'    { '_InputDelayP95Sort' }
            'OS Disk IOPS'       { '_DiskIOPSSort' }
            'OS Disk IOPS %'     { '_DiskIOPSPctSort' }
            'OS Disk Queue'      { '_DiskQueueSort' }
            'CPU Credits'        { '_CPUCreditsSort' }
            'Compute GBP/mo'     { '_ComputeCostSort' }
            'Disk GBP/mo'        { '_DiskCostSort' }
            'Txn GBP/10K'        { '_TxnCostSort' }
            'Txn GBP/mo'         { '_TxnMoCostSort' }
            default              { $colName }
        }

        # Apply heat map CellStyle to CPU %, Mem %, and Disk % columns
        if ($colName -in @('CPU %', 'Mem %', 'OS Disk %', 'Input Delay Median', 'Input Delay P95', 'OS Disk IOPS %', 'OS Disk Queue', 'CPU Credits')) {
            $colorCol = switch ($colName) { 'CPU %' { '_CPUColor' } 'Mem %' { '_MemColor' } 'OS Disk %' { '_DiskColor' } 'Input Delay Median' { '_InputDelayColor' } 'Input Delay P95' { '_InputDelayP95Color' } 'OS Disk IOPS %' { '_DiskIOPSPctColor' } 'OS Disk Queue' { '_DiskQueueColor' } 'CPU Credits' { '_CPUCreditsColor' } }
            # BasedOn the global DataGridCell style so the centred ContentPresenter
            # template and the IsSelected -> Foreground=#1F2937 trigger are inherited.
            # Without BasedOn, the system HighlightTextBrush would make text white on selection.
            $baseStyle = $script:SHGrid.TryFindResource([System.Windows.Controls.DataGridCell])
            $cellStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridCell])
            if ($null -ne $baseStyle) { $cellStyle.BasedOn = $baseStyle }
            $brushConv = New-Object System.Windows.Media.BrushConverter
            $_green = if ($script:DarkTheme) { '#1E4620' } else { '#81C784' }
            $_amber = if ($script:DarkTheme) { '#5C3A00' } else { '#FFB74D' }
            $_red   = if ($script:DarkTheme) { '#5C1C1C' } else { '#E57373' }
            foreach ($band in @(
                @{ Value = 'Green'; Hex = $_green }
                @{ Value = 'Amber'; Hex = $_amber }
                @{ Value = 'Red';   Hex = $_red   }
            )) {
                $trigger = New-Object System.Windows.DataTrigger
                $binding = New-Object System.Windows.Data.Binding
                $binding.Path = New-Object System.Windows.PropertyPath "[$colorCol]"
                $trigger.Binding = $binding
                $trigger.Value = $band.Value
                $setter = New-Object System.Windows.Setter
                $setter.Property = [System.Windows.Controls.Control]::BackgroundProperty
                $setter.Value = $brushConv.ConvertFromString($band.Hex)
                [void]$trigger.Setters.Add($setter)
                [void]$cellStyle.Triggers.Add($trigger)
            }
            # Vertical-centre the cell content
            $vSetter = New-Object System.Windows.Setter
            $vSetter.Property = [System.Windows.Controls.Control]::VerticalContentAlignmentProperty
            $vSetter.Value    = [System.Windows.VerticalAlignment]::Center
            [void]$cellStyle.Setters.Add($vSetter)
            $e.Column.CellStyle = $cellStyle
            # Centre-align the text horizontally and vertically
            $cpuMemStyle = [System.Windows.Markup.XamlReader]::Parse(
                '<Style TargetType="TextBlock" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">' +
                '<Setter Property="TextAlignment" Value="Center"/>' +
                '<Setter Property="VerticalAlignment" Value="Center"/></Style>')
            $e.Column.ElementStyle = $cpuMemStyle
        }

        # Input Delay columns: use two-line header to keep column narrow
        if ($colName -eq 'Input Delay Median') { $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "Input Delay`nMedian"; $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb }
        if ($colName -eq 'Input Delay P95')    { $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "Input Delay`nP95";    $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb }
        if ($colName -eq 'OS Disk %')          { $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "OS`nDisk %";          $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb }
        if ($colName -eq 'OS Disk IOPS') {
            $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "OS Disk`nIOPS"; $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb
            # Centre-align the text (no heat map for IOPS - informational only).
            # BasedOn the global DataGridCell style to inherit the IsSelected ->
            # Foreground=#1F2937 trigger so text stays black when the row is selected.
            $iopsBaseStyle = $script:SHGrid.TryFindResource([System.Windows.Controls.DataGridCell])
            $iopsCellStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridCell])
            if ($null -ne $iopsBaseStyle) { $iopsCellStyle.BasedOn = $iopsBaseStyle }
            $vSetter = New-Object System.Windows.Setter
            $vSetter.Property = [System.Windows.Controls.Control]::VerticalContentAlignmentProperty
            $vSetter.Value    = [System.Windows.VerticalAlignment]::Center
            [void]$iopsCellStyle.Setters.Add($vSetter)
            $e.Column.CellStyle = $iopsCellStyle
            $iopsElStyle = [System.Windows.Markup.XamlReader]::Parse(
                '<Style TargetType="TextBlock" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">' +
                '<Setter Property="TextAlignment" Value="Center"/>' +
                '<Setter Property="VerticalAlignment" Value="Center"/></Style>')
            $e.Column.ElementStyle = $iopsElStyle
        }
        if ($colName -eq 'OS Disk IOPS %') { $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "OS Disk`nIOPS %"; $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb }
        if ($colName -eq 'OS Disk Queue')  { $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "OS Disk`nQueue";  $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb }
        if ($colName -eq 'CPU Credits') {
            $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "CPU`nCredits"; $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb
            # Static wrapped tooltip explaining the B-series credit model.
            # Uses a ToolTip element with a TextBlock so the text wraps at 280px
            # rather than rendering as one long single-line string.
            $credTtXaml = '<Style TargetType="TextBlock" ' +
                'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">' +
                '<Setter Property="TextAlignment" Value="Center"/>' +
                '<Setter Property="VerticalAlignment" Value="Center"/>' +
                '<Setter Property="ToolTip">' +
                '<Setter.Value>' +
                '<ToolTip>' +
                '<TextBlock MaxWidth="280" TextWrapping="Wrap">' +
                'Remaining CPU burst credits (B-series VMs only).' + '&#10;&#10;' +
                'Credits accumulate when CPU is below baseline and are consumed during bursts. ' +
                'When credits run out the VM is throttled to its baseline CPU (e.g. 40% / 1.6 vCPUs for B4s v2).' + '&#10;&#10;' +
                'B4s v2: 96 credits/hr earned, 2,304 max bank.' + '&#10;&#10;' +
                'Green = 30+ credits&#10;Amber = 10-29 (monitor)&#10;Red = under 10 (throttle risk)&#10;N/A = not a B-series VM' +
                '</TextBlock>' +
                '</ToolTip>' +
                '</Setter.Value>' +
                '</Setter>' +
                '</Style>'
            $e.Column.ElementStyle = [System.Windows.Markup.XamlReader]::Parse($credTtXaml)
        }
        if ($colName -eq 'Compute GBP/mo') {
            # '/' in the column name is misread as a path separator by WPF's PropertyPath
            # parser. Override the auto-generated binding with the indexer form so WPF
            # calls DataRowView["Compute GBP/mo"] directly instead of navigating a path.
            $e.Column.Binding = New-Object System.Windows.Data.Binding "[Compute GBP/mo]"
            $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "Compute`nGBP/mo"; $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb
        }
        if ($colName -eq 'Disk GBP/mo') {
            $e.Column.Binding = New-Object System.Windows.Data.Binding "[Disk GBP/mo]"
            $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "Disk`nGBP/mo"; $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb
        }
        if ($colName -eq 'Txn GBP/10K') {
            $e.Column.Binding = New-Object System.Windows.Data.Binding "[Txn GBP/10K]"
            $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "Txn`nGBP/10K"; $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb
        }
        if ($colName -eq 'Txn GBP/mo') {
            $e.Column.Binding = New-Object System.Windows.Data.Binding "[Txn GBP/mo]"
            $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "Txn`nGBP/mo"; $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb
        }
        if ($colName -eq 'Txn Ops (30d)') { $hdrTb = New-Object System.Windows.Controls.TextBlock; $hdrTb.Text = "Txn Ops`n(30d)"; $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center; $e.Column.Header = $hdrTb }

        # User column style - supports multi-line stacked display for multiple users.
        # The User text contains newline characters when 2+ users are on the host
        # (up to 3 names stacked, or 3 + "(+N more)" for 4+). TextWrapping="Wrap"
        # lets the TextBlock render those newlines as line breaks and the DataGrid
        # row auto-heights to fit the content. Font size is inherited from the grid
        # (same as all other columns) so single-user rows look consistent.
        #
        # Tooltip: _UserTooltip holds the full newline-separated user list (set for
        # 2+ users, empty string for 0-1). A DataTrigger nulls the ToolTip when
        # _UserTooltip is empty so single-user rows don't show a redundant tooltip.
        if ($colName -eq 'User') {
            # FontSize defaults to 11 (compact for multi-user stacked rows).
            # A DataTrigger on _UserTooltip="" restores 13 for single-user rows -
            # _UserTooltip is empty for 0-1 users and non-empty for 2+ users.
            # This way only multi-user rows get the smaller font.
            $ttXaml = '<Style TargetType="TextBlock" ' +
                'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" ' +
                'xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">' +
                '<Setter Property="TextAlignment" Value="Center"/>' +
                '<Setter Property="VerticalAlignment" Value="Center"/>' +
                '<Setter Property="TextWrapping" Value="NoWrap"/>' +
                '<Setter Property="FontSize" Value="9"/>' +
                '<Setter Property="LineHeight" Value="11"/>' +
                '<Setter Property="LineStackingStrategy" Value="BlockLineHeight"/>' +
                '<Setter Property="ToolTip" Value="{Binding [_UserTooltip]}"/>' +
                '<Style.Triggers>' +
                '<DataTrigger Binding="{Binding [_UserTooltip]}" Value="">' +
                '<Setter Property="FontSize" Value="13"/>' +
                '<Setter Property="LineHeight" Value="17"/>' +
                '<Setter Property="ToolTip" Value="{x:Null}"/>' +
                '</DataTrigger>' +
                '</Style.Triggers></Style>'
            $e.Column.ElementStyle = [System.Windows.Markup.XamlReader]::Parse($ttXaml)

            # Remove vertical cell padding so 3 stacked names fit without clipping.
            # BasedOn the global DataGridCell style to inherit the IsSelected highlight.
            $userBaseStyle = $script:SHGrid.TryFindResource([System.Windows.Controls.DataGridCell])
            $userCellStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridCell])
            if ($null -ne $userBaseStyle) { $userCellStyle.BasedOn = $userBaseStyle }
            [void]$userCellStyle.Setters.Add((New-Object System.Windows.Setter(
                [System.Windows.Controls.Control]::PaddingProperty,
                [System.Windows.Thickness]::new(2, 0, 2, 0))))
            $e.Column.CellStyle = $userCellStyle
        }

        # Health State tooltip: shows the failed check names when a host is unhealthy.
        # _HealthTooltip is populated in Phase 2 from sessionHostHealthCheckResults.
        # The DataTrigger nulls the tooltip for healthy/N/A rows (empty string).
        if ($colName -eq 'Health State') {
            $hsXaml = '<Style TargetType="TextBlock" ' +
                'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" ' +
                'xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">' +
                '<Setter Property="ToolTip" Value="{Binding [_HealthTooltip]}"/>' +
                '<Style.Triggers>' +
                '<DataTrigger Binding="{Binding [_HealthTooltip]}" Value="">' +
                '<Setter Property="ToolTip" Value="{x:Null}"/>' +
                '</DataTrigger>' +
                '</Style.Triggers></Style>'
            $e.Column.ElementStyle = [System.Windows.Markup.XamlReader]::Parse($hsXaml)
        }

        # Only add ComboBox dropdown to filterable columns
        if ($colName -notin $script:shFilterableColumns) { return }

        # ── Build the header: StackPanel with TextBlock + ComboBox ──
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = [System.Windows.Controls.Orientation]::Vertical

        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text       = $colName
        $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
        $tb.FontSize   = 12
        $tb.Margin     = [System.Windows.Thickness]::new(0,0,0,2)

        $cb = New-Object System.Windows.Controls.ComboBox
        $cb.Tag        = $colName
        $cb.FontSize   = 11
        $cb.Margin     = [System.Windows.Thickness]::new(0,0,0,0)
        $cb.IsEditable = $false

        # Populate with distinct values from the current DataTable
        _SH_PopulateHeaderComboBox -ComboBox $cb -ColumnName $colName

        # Restore saved selection BEFORE wiring the event so it does not
        # trigger _SH_ApplyFilters during column generation
        $savedVal = $script:shDropdownSelections[$colName]
        if ($savedVal -and $cb.Items.Contains($savedVal)) {
            $cb.SelectedItem = $savedVal
        } else {
            $cb.SelectedItem = 'All'
        }

        # Wire SelectionChanged AFTER initial selection is set
        $cb.Add_SelectionChanged({
            param($s, $eArgs)
            $col = $s.Tag
            $script:shDropdownSelections[$col] = $s.SelectedItem
            _SH_ApplyFilters
        })

        # Store reference so Clear Filters can reset the ComboBox visually
        $script:shDropdownCombos[$colName] = $cb

        [void]$sp.Children.Add($tb)
        [void]$sp.Children.Add($cb)
        $e.Column.Header = $sp

        # Filterable columns get a custom header (StackPanel+ComboBox) which
        # causes WPF to bypass the global DataGridCell IsSelected trigger,
        # leaving cell text white on row selection. Explicitly set a CellStyle
        # based on the global style so the Foreground=#1F2937 fix applies.
        $baseCellStyle = $script:SHGrid.TryFindResource([System.Windows.Controls.DataGridCell])
        $fcCellStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridCell])
        if ($null -ne $baseCellStyle) { $fcCellStyle.BasedOn = $baseCellStyle }
        $fcSelTrigger = New-Object System.Windows.Trigger
        $fcSelTrigger.Property = [System.Windows.Controls.DataGridCell]::IsSelectedProperty
        $fcSelTrigger.Value    = $true
        [void]$fcSelTrigger.Setters.Add(
            (New-Object System.Windows.Setter(
                [System.Windows.Controls.Control]::ForegroundProperty,
                $window.Resources['Avd.Fg.Selected']
            ))
        )
        [void]$fcCellStyle.Triggers.Add($fcSelTrigger)
        $e.Column.CellStyle = $fcCellStyle
    })

    # ── Filter box: debounced DataView filtering ──────────────────────────────
    # TextChanged fires on every keystroke but we defer the actual RowFilter
    # evaluation by 300 ms so rapid typing only triggers one filter pass rather
    # than one per character. With 1000+ rows this makes a noticeable difference.
    $script:SHFilterDebounce = New-Object System.Windows.Threading.DispatcherTimer
    $script:SHFilterDebounce.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:SHFilterDebounce.Add_Tick({
        $script:SHFilterDebounce.Stop()
        if (-not $script:vmDataTable) { return }
        _SH_ApplyFilters
    })
    $script:SHFilterBox.Add_TextChanged({
        # Reset the debounce timer on every keystroke; the filter fires 300 ms
        # after the user stops typing rather than on every individual character.
        $script:SHFilterDebounce.Stop()
        $script:SHFilterDebounce.Start()
    })

    # ── "Hide empty hosts" checkbox ─────────────────────────────────────────
    $script:SHHideEmptyCheckBox.Add_Checked({   _SH_ApplyFilters })
    $script:SHHideEmptyCheckBox.Add_Unchecked({ _SH_ApplyFilters })

    # ── Grid selection: enable/disable power action buttons ──────────────────
    # SelectionChanged fires whenever the user clicks a row (or Ctrl+clicks for
    # multi-select). Buttons stay greyed out unless at least one row is selected.
    $script:SHGrid.Add_SelectionChanged({
        $has = $script:SHGrid.SelectedItems.Count -gt 0
        $script:SHStartButton.IsEnabled          = $has
        $script:SHDeallocateButton.IsEnabled     = $has
        $script:SHRestartButton.IsEnabled        = $has
        $script:SHEnableDrainButton.IsEnabled    = $has
        $script:SHDisableDrainButton.IsEnabled   = $has
    })

    # ── Row hover / selected highlight style ─────────────────────────────────
    # WPF DataGrid does not expose simple hover/selected colours directly in XAML
    # without a full ControlTemplate override, so we build the Style in code.
    # IsMouseOver trigger -> light blue tint; IsSelected trigger -> darker blue.
    $vmRowStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridRow])
    [void]$vmRowStyle.Setters.Add((New-Object System.Windows.Setter(
        [System.Windows.Controls.DataGridRow]::ForegroundProperty, $window.Resources['Avd.Window.Fg'])))

    $vmHoverTrigger = New-Object System.Windows.Trigger
    $vmHoverTrigger.Property = [System.Windows.Controls.DataGridRow]::IsMouseOverProperty
    $vmHoverTrigger.Value    = $true
    [void]$vmHoverTrigger.Setters.Add((New-Object System.Windows.Setter(
        [System.Windows.Controls.DataGridRow]::BackgroundProperty, $window.Resources['Avd.Hover.Bg'])))

    $vmSelTrigger = New-Object System.Windows.Trigger
    $vmSelTrigger.Property = [System.Windows.Controls.DataGridRow]::IsSelectedProperty
    $vmSelTrigger.Value    = $true
    [void]$vmSelTrigger.Setters.Add((New-Object System.Windows.Setter(
        [System.Windows.Controls.DataGridRow]::BackgroundProperty, $window.Resources['Avd.Selected.Bg'])))
    [void]$vmSelTrigger.Setters.Add((New-Object System.Windows.Setter(
        [System.Windows.Controls.DataGridRow]::ForegroundProperty, $window.Resources['Avd.Fg.Selected'])))

    [void]$vmRowStyle.Triggers.Add($vmHoverTrigger)
    [void]$vmRowStyle.Triggers.Add($vmSelTrigger)
    $script:SHGrid.RowStyle = $vmRowStyle

    # Walk the visual tree on first load:
    # 1. Patch the internal ScrollViewer background (prevents white strip in dark mode)
    # 2. Find the DataGridColumnHeadersPresenter and force it to re-layout synchronously
    #    on every horizontal scroll — this keeps headers in sync with data rows in the
    #    same layout pass instead of one pass behind (which causes visible header lag).
    $script:SHGrid.Add_Loaded(({
        if ($script:_shSVPatched) { return }
        $presenterType = [System.Windows.Controls.Primitives.DataGridColumnHeadersPresenter]
        $sv = $null
        $script:_shHeaderPresenter = $null
        $queue = New-Object System.Collections.Generic.Queue[System.Windows.DependencyObject]
        $queue.Enqueue($script:SHGrid)
        while ($queue.Count -gt 0) {
            $el = $queue.Dequeue()
            if ($null -eq $el) { continue }
            if ($el -is [System.Windows.Controls.ScrollViewer] -and -not $sv) {
                $el.Background = $window.Resources['Avd.Grid.Bg']
                $sv = $el
            }
            if ($el -is $presenterType -and -not $script:_shHeaderPresenter) {
                $script:_shHeaderPresenter = $el
                $el.Background = $window.Resources['Avd.ColHeader.Bg']
            }
            $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el)
            for ($i = 0; $i -lt $count; $i++) {
                $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($el, $i))
            }
        }
        $script:_shSVPatched = $true

        if ($sv -and $script:_shHeaderPresenter) {
            # Apply a TranslateTransform to the header presenter that compensates for the
            # one-layout-pass lag between rapid scrollbar drag events and the layout pipeline.
            # On each scroll: shift headers by -HorizontalChange (same visual frame as data rows).
            # On LayoutUpdated once the header layout catches up: reset transform to zero.
            $tt = New-Object System.Windows.Media.TranslateTransform
            $script:_shHeaderPresenter.RenderTransform = $tt

            $sv.Add_ScrollChanged({
                param($s, $e)
                if ($e.HorizontalChange -eq 0) { return }
                $tt2 = $script:_shHeaderPresenter.RenderTransform -as [System.Windows.Media.TranslateTransform]
                if ($tt2) { $tt2.X = -$e.HorizontalChange }
            }.GetNewClosure())

            $script:_shHeaderPresenter.Add_LayoutUpdated({
                $hp = $script:_shHeaderPresenter
                if (-not $hp) { return }
                $tt2 = $hp.RenderTransform -as [System.Windows.Media.TranslateTransform]
                if (-not $tt2 -or $tt2.X -eq 0) { return }
                if ($hp.IsMeasureValid -and $hp.IsArrangeValid) { $tt2.X = 0 }
            })
        }
    }.GetNewClosure()))

    # ── Button click handlers ─────────────────────────────────────────────────
    $script:SHStartButton.Add_Click(      { Invoke-SessionHostsPowerAction -Action 'Start'      })
    $script:SHDeallocateButton.Add_Click( { Invoke-SessionHostsPowerAction -Action 'Deallocate' })
    $script:SHRestartButton.Add_Click(    { Invoke-SessionHostsPowerAction -Action 'Restart'    })
    $script:SHRefreshButton.Add_Click(      { Invoke-SessionHostsTabRefresh })
    $script:SHClearFiltersButton.Add_Click({
        # Reset the global text filter
        $script:SHFilterBox.Text = ''
        # Reset the "Hide empty hosts" checkbox
        $script:SHHideEmptyCheckBox.IsChecked = $false
        # Reset all per-column dropdown selections and ComboBox UI
        $script:shDropdownSelections = @{}
        foreach ($cb in $script:shDropdownCombos.Values) {
            if ($cb -and $cb.Items.Count -gt 0) { $cb.SelectedItem = 'All' }
        }
        # Re-apply (clears RowFilter)
        _SH_ApplyFilters
    })
    $script:SHExportButton.Add_Click(        { Invoke-SessionHostsExport })
    $script:SHLoadCostsButton.Add_Click(     { Invoke-SessionHostsCostFetch })

    # Double-click a session host row to open the Session Detail window filtered to
    # that host's sessions only. Passes the host pool name and RG so Show-SessionDetail
    # can fetch the correct AVD session list, plus the VM name as a host filter so
    # only that host's sessions are shown rather than the whole pool.
    $script:SHGrid.Add_MouseDoubleClick({
        $row = $script:SHGrid.SelectedItem
        if ($null -eq $row) { return }
        $hpName = [string]$row['Host Pool']
        $hpRG   = [string]$row['_HpRG']
        $vmName = [string]$row['VM Name']
        if ($hpName -and $hpRG -and $vmName) {
            Show-SessionDetail -HostPoolName $hpName -HostPoolRG $hpRG -HostNameFilter $vmName
        }
    })
    $script:SHEnableDrainButton.Add_Click(   { Invoke-SessionHostsDrainAction -EnableDrain $true  })
    $script:SHDisableDrainButton.Add_Click(  { Invoke-SessionHostsDrainAction -EnableDrain $false })

    # ── Right-click context menu ──────────────────────────────────────────────
    # The context menu provides quick actions when the user right-clicks a row
    # in the Session Hosts DataGrid. Menu items are added in display order and
    # referenced by index in the ContextMenuOpening handler for enable/disable
    # logic. Separators are included between logical groups.
    #
    # Menu layout:
    #   [0] Copy Hostname        - copies the 'VM Name' column value to clipboard
    #   [1] Copy IP Address      - copies the 'IP Address' column value to clipboard
    #   [2] Performance History  - opens a popup line chart of CPU/Mem % over time
    #   [3] ── separator ──
    #   [4] RDP to Session Host  - launches mstsc/msra to the session host
    #   [5] Open C$ Share        - opens \\<host>\C$ in Explorer (respects ShadowUseIP)
    #   [6] ── separator ──
    #   [7] Run Command...       - opens the Run Command picker dialog
    #   [8] ── separator ──
    #   [9] Input Delay Breakdown - per-process input delay samples from LAW
    #
    # Enable/disable rules (evaluated each time the menu opens):
    #   - Copy Hostname:      enabled when any row is selected
    #   - Copy IP Address:    enabled when a row is selected AND the IP Address
    #                         column has a resolved value (not '-' or empty).
    #                         IP is populated from NIC data in Phase 3 of the
    #                         refresh cycle; deallocated VMs may show '-'.
    #   - Perf History:       enabled when a row is selected AND Log Analytics
    #                         Workspace is configured ($script:LawWorkspaceResourceId)
    #   - RDP / Run Cmd:      enabled only when the VM's Power State is not
    #                         'Shutdown' (i.e. the VM is running)
    #   - Input Delay:        enabled when a row is selected AND Log Analytics
    #                         Workspace is configured
    #
    # Clipboard operations use [System.Windows.Clipboard]::SetText() which
    # requires the WPF PresentationCore assembly (already loaded for the UI).
    # ─────────────────────────────────────────────────────────────────────────

    $shCtxMenu           = New-Object System.Windows.Controls.ContextMenu

    # -- Clipboard copy items --
    $menuSHCopyHost        = New-Object System.Windows.Controls.MenuItem
    $menuSHCopyHost.Header = "Copy Hostname"
    $menuSHCopyIP          = New-Object System.Windows.Controls.MenuItem
    $menuSHCopyIP.Header   = "Copy IP Address"

    # -- Performance History: queries LAW for historical CPU/Mem and renders a line chart --
    $menuSHPerf            = New-Object System.Windows.Controls.MenuItem
    $menuSHPerf.Header     = "Performance History"

    $menuSHSep1            = New-Object System.Windows.Controls.Separator

    # -- Session host action items --
    $menuSHRDP           = New-Object System.Windows.Controls.MenuItem
    $menuSHRDP.Header    = "RDP to Session Host"
    $menuSHOpenC         = New-Object System.Windows.Controls.MenuItem
    $menuSHOpenC.Header  = "Open C$ Share"
    $menuSHEventVwr      = New-Object System.Windows.Controls.MenuItem
    $menuSHEventVwr.Header = "Open Event Viewer"
    $menuSHSep2          = New-Object System.Windows.Controls.Separator
    $menuSHRunCmd        = New-Object System.Windows.Controls.MenuItem
    $menuSHRunCmd.Header = "Run Command..."

    # -- Input Delay Breakdown: queries LAW for per-process input delay samples --
    $menuSHSep3              = New-Object System.Windows.Controls.Separator
    $menuSHInputDelay        = New-Object System.Windows.Controls.MenuItem
    $menuSHInputDelay.Header = "Input Delay Breakdown"

    # -- CPU Credits History: Azure Monitor metrics chart for B-series VMs only --
    # The menu item is added unconditionally here; IsEnabled is set in
    # ContextMenuOpening based on the selected VM's SKU (Standard_B* only).
    $menuSHSep4             = New-Object System.Windows.Controls.Separator
    $menuSHCredits          = New-Object System.Windows.Controls.MenuItem
    $menuSHCredits.Header   = "CPU Credits History"

    [void]$shCtxMenu.Items.Add($menuSHCopyHost)      # [0]
    [void]$shCtxMenu.Items.Add($menuSHCopyIP)         # [1]
    [void]$shCtxMenu.Items.Add($menuSHPerf)           # [2]
    [void]$shCtxMenu.Items.Add($menuSHSep1)           # [3]
    [void]$shCtxMenu.Items.Add($menuSHRDP)            # [4]
    [void]$shCtxMenu.Items.Add($menuSHOpenC)          # [5]
    [void]$shCtxMenu.Items.Add($menuSHEventVwr)       # [6]
    [void]$shCtxMenu.Items.Add($menuSHSep2)           # [7]
    [void]$shCtxMenu.Items.Add($menuSHRunCmd)         # [8]
    [void]$shCtxMenu.Items.Add($menuSHSep3)           # [9]
    [void]$shCtxMenu.Items.Add($menuSHInputDelay)     # [10]
    [void]$shCtxMenu.Items.Add($menuSHSep4)           # [11]
    [void]$shCtxMenu.Items.Add($menuSHCredits)        # [12]

    # Capture as a local variable so all closures below work exactly like
    # Add-SessionContextMenu in session-detail.ps1 does with its $Grid parameter.
    $shGrid = $script:SHGrid

    # PreviewMouseRightButtonDown: walk the visual tree up from the clicked
    # element to find the DataGridRow and select it, so SelectedItems is
    # populated before the context menu opens.
    $shGrid.Add_PreviewMouseRightButtonDown({
        $node = $_.OriginalSource
        while ($null -ne $node -and $node -isnot [System.Windows.Controls.DataGridRow]) {
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        }
        if ($null -ne $node -and -not $node.IsSelected) {
            $shGrid.SelectedItems.Clear()
            $node.IsSelected = $true
        }
    }.GetNewClosure())

    # ContextMenuOpening: runs each time the menu is about to show. Evaluates
    # the current selection and enables/disables items based on row state.
    # NOTE: $script: scope is NOT available inside .GetNewClosure() (it creates
    # a new dynamic module). Capture any script-scope values into locals first.
    $lawConfigured = -not [string]::IsNullOrWhiteSpace($script:LawWorkspaceResourceId)

    $shGrid.Add_ContextMenuOpening({
        $sel    = @($shGrid.SelectedItems)
        $hasOne = $sel.Count -gt 0 -and $null -ne $sel[0]
        # Both RDP and Run Command require the VM to be powered on.
        # Use the Power State column (real Azure VM power state from Resource Graph)
        # rather than Status (AVD agent status) - a deallocated VM shows Status as
        # 'Unavailable' not 'Shutdown', so checking Status alone allows RDP/commands
        # against VMs that are not actually running.
        $isRunning = $hasOne -and ([string]$sel[0]['Power State']) -eq 'Running'
        # IP Address is '-' when the NIC lookup didn't return a result (e.g.
        # the VM is deallocated and has no active NIC, or Resource Graph data
        # was unavailable). Disable "Copy IP Address" in that case.
        $hasIP     = $hasOne -and ([string]$sel[0]['IP Address']) -ne '-' -and -not [string]::IsNullOrWhiteSpace([string]$sel[0]['IP Address'])
        # Performance History requires LAW to be configured. $lawConfigured is
        # captured from $script:LawWorkspaceResourceId before the closure since
        # $script: is unavailable inside .GetNewClosure().
        $shCtxMenu.Items[0].IsEnabled  = $hasOne                         # Copy Hostname
        $shCtxMenu.Items[1].IsEnabled  = $hasIP                           # Copy IP Address
        $shCtxMenu.Items[2].IsEnabled  = $hasOne -and $lawConfigured      # Performance History
        $shCtxMenu.Items[4].IsEnabled  = $isRunning                       # RDP to Session Host
        $shCtxMenu.Items[5].IsEnabled  = $isRunning                       # Open C$ Share
        $shCtxMenu.Items[6].IsEnabled  = $isRunning                       # Open Event Viewer
        $shCtxMenu.Items[8].IsEnabled  = $isRunning                       # Run Command
        $shCtxMenu.Items[10].IsEnabled = $hasOne -and $lawConfigured      # Input Delay Breakdown
        # CPU Credits History: only valid for B-series VMs (Standard_B*).
        # These are the only SKUs that support CPU credit bursting in Azure.
        # All other SKU families (D, E, F, etc.) have no CPU credit concept.
        $shCtxMenu.Items[12].IsEnabled = $hasOne -and ([string]$sel[0]['VM SKU'] -like 'Standard_B*')
    }.GetNewClosure())

    # -- Copy Hostname handler --
    # Copies the short VM name (e.g. "CUKHP01UKWA-183") from the 'VM Name'
    # column to the Windows clipboard. This is the name shown in the grid,
    # not the full FQDN (which is stored in the hidden '_SHName' column).
    $menuSHCopyHost.Add_Click({
        try {
            $sel = @($shGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            [System.Windows.Clipboard]::SetText([string]$sel[0]['VM Name'])
        } catch {}
    }.GetNewClosure())

    # -- Copy IP Address handler --
    # Copies the private IP address (e.g. "10.143.16.2") from the 'IP Address'
    # column to the Windows clipboard. The IP is resolved during Phase 3 of the
    # refresh cycle via Azure Resource Graph NIC data. If the IP column shows '-'
    # (no IP available), the menu item is disabled so this handler won't fire.
    $menuSHCopyIP.Add_Click({
        try {
            $sel = @($shGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            $ip = [string]$sel[0]['IP Address']
            if ($ip -ne '-' -and -not [string]::IsNullOrWhiteSpace($ip)) {
                [System.Windows.Clipboard]::SetText($ip)
            }
        } catch {}
    }.GetNewClosure())

    # -- Performance History handler --
    # Opens a popup window with a line chart of CPU % and Mem % over time.
    # Data is queried on demand from the Log Analytics Workspace (same LAW used
    # for the point-in-time CPU/Mem columns). The menu item is disabled when
    # LAW is not configured. See Show-PerformanceHistory below for full details.
    $menuSHPerf.Add_Click({
        try {
            $sel = @($shGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            Show-PerformanceHistory -VmName ([string]$sel[0]['VM Name']) -VMResourceId ([string]$sel[0]['_VMResourceId'])
        }
        catch {
            [System.Windows.MessageBox]::Show("Failed to open Performance History: $_", "Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    $menuSHRDP.Add_Click({
        try {
            $sel = @($shGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            $row  = $sel[0]
            $fqdn = [string]$row['_SHName']
            $ip   = [string]$row['IP Address']
            if ($ip -eq '-' -or [string]::IsNullOrWhiteSpace($ip)) { $ip = '' }
            Invoke-RDPToSessionHost -SessionHost $fqdn -IPAddress $ip
        }
        catch {
            [System.Windows.MessageBox]::Show("Failed to launch RDP: $_", "RDP Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    # -- Open C$ Share handler --
    # Opens \\<target>\C$ in Windows Explorer using the built-in Windows admin share.
    #
    # Target resolution (same logic as RDP/Shadow):
    #   - ShadowUseIP = $true  (config.psd1 ShadowRDP.ShadowUseIP): uses the VM private
    #     IP address from the 'IP Address' column (resolved in Phase 3 via Resource Graph).
    #   - ShadowUseIP = $false : uses the short VM hostname (VM Name column value).
    #
    # Firewall requirements - the following ports must be open from the admin workstation
    # to the session host VM (inbound on the VM):
    #   TCP 445  - SMB (Server Message Block): required for all admin share access (C$).
    #   TCP 135  - RPC Endpoint Mapper: required for DCOM/WMI if used alongside the share.
    # Ensure NSG rules and Windows Firewall on the session host allow TCP 445 from your
    # admin subnet. Without this the Explorer window will immediately show an access error.
    $menuSHOpenC.Add_Click({
        try {
            $sel = @($shGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            $row    = $sel[0]
            $ip     = [string]$row['IP Address']
            $vmName = [string]$row['VM Name']
            # Respect ShadowUseIP - same logic as RDP/shadow connections.
            # Use IP if the setting is enabled and a valid IP was resolved in Phase 3.
            $useIP  = $script:ShadowUseIP -and $ip -ne '-' -and -not [string]::IsNullOrWhiteSpace($ip)
            $target = if ($useIP) { $ip } else { $vmName }
            Start-Process "explorer.exe" "\\$target\C$"
        }
        catch {
            [System.Windows.MessageBox]::Show("Failed to open C$ share: $_", "Error", "OK", "Error") | Out-Null
        }
    })

    # Firewall requirements for remote Event Viewer:
    #   TCP 135  - RPC Endpoint Mapper (required)
    #   TCP 445  - SMB named pipes (may be used by some RPC transports)
    #   TCP 49152-65535 - dynamic RPC ports (required unless restricted by policy)
    # Ensure NSG rules and Windows Firewall on the session host allow these from
    # your admin subnet. The Remote Event Log Management firewall rule group must
    # be enabled on the session host.
    $menuSHEventVwr.Add_Click({
        try {
            $sel = @($shGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            $row    = $sel[0]
            $ip     = [string]$row['IP Address']
            $vmName = [string]$row['VM Name']
            $useIP  = $script:ShadowUseIP -and $ip -ne '-' -and -not [string]::IsNullOrWhiteSpace($ip)
            $target = if ($useIP) { $ip } else { $vmName }
            Start-Process "eventvwr.exe" "/computer:$target"
        }
        catch {
            [System.Windows.MessageBox]::Show("Failed to open Event Viewer: $_", "Error", "OK", "Error") | Out-Null
        }
    })

    $menuSHRunCmd.Add_Click({
        try {
            $sel = @($shGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            $row    = $sel[0]
            $vmName = [string]$row['VM Name']
            $rg     = [string]$row['_RG']
            Show-RunCommandPicker -VmName $vmName -RG $rg
        }
        catch {
            [System.Windows.MessageBox]::Show("Failed to open Run Command dialog: $_", "Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    # -- Input Delay Breakdown handler --
    # Opens a popup showing per-process input delay samples from LAW for the
    # selected host. Helps investigate what processes contribute to the
    # aggregated Median / P95 values shown in the grid.
    $menuSHInputDelay.Add_Click({
        try {
            $sel = @($shGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            Show-InputDelayBreakdown -VmName ([string]$sel[0]['VM Name'])
        }
        catch {
            [System.Windows.MessageBox]::Show("Failed to open Input Delay Breakdown: $_", "Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    # -- CPU Credits History handler --
    # Opens Show-CPUCreditsHistory which queries Azure Monitor for the
    # 'CPU Credits Remaining' metric and renders it as a line chart.
    # The menu item is disabled in ContextMenuOpening for non-B-series VMs,
    # so this handler should only fire when VMResourceId and a B-series SKU exist.
    $menuSHCredits.Add_Click({
        try {
            $sel = @($shGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            Show-CPUCreditsHistory -VmName ([string]$sel[0]['VM Name']) `
                                   -VMResourceId ([string]$sel[0]['_VMResourceId'])
        }
        catch {
            [System.Windows.MessageBox]::Show("Failed to open CPU Credits History: $_", "Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    $shGrid.ContextMenu = $shCtxMenu

}

# =============================================================================
# 4a. Trigger a Core (Pass 1) background refresh - Phases 1-3
#
# Called by Invoke-SessionHostsTabTimer (scheduled) and SHRefreshButton (manual).
# Guards against double-fire: if a Core job is already running it returns immediately.
#
# Only injects the variables needed by $script:vmCoreScript (AVD REST + Resource
# Graph). Metric-related variables (LAW / Azure Monitor config) are injected later
# by Invoke-SessionHostsMetricsRefresh once the Core result is in hand.
# =============================================================================

function Invoke-SessionHostsTabRefresh {
    # Do not start a second Core job if one is still running.
    # A completed handle (IsCompleted = $true) is fine - it will be collected in
    # the timer's (b) branch. The guard only blocks a NEW job from firing.
    if ($script:vmHandle -and -not $script:vmHandle.IsCompleted) { return }

    $script:SHStatusText.Text = 'Refreshing...'

    # Push the next scheduled refresh far into the future so a slow query cannot
    # cause a second refresh to start before this one completes. The timer resets
    # this to Now + VmRefreshIntervalSeconds once the job finishes successfully.
    $script:vmNextRefresh = [DateTime]::Now.AddSeconds($script:VmRefreshIntervalSeconds + 9999)

    # ── Inject variables into the Core runspace ─────────────────────────────────
    # SessionStateProxy.SetVariable() is the only safe way to pass data across
    # the runspace boundary without serialisation overhead. Only the variables
    # consumed by $script:vmCoreScript (Phases 1-3) are injected here.
    # Metric-specific variables are injected by Invoke-SessionHostsMetricsRefresh.
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('ArmToken',         (Get-ArmToken))
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('SubId',            $script:vmSubId)
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('AvdIncludeRGsCsv', ($script:AvdIncludeRGs -join ','))
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('AvdExcludeRGsCsv', ($script:AvdExcludeRGs -join ','))
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('ExcludedPoolsCsv', ($script:ExcludedPools -join ','))
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('RgLocationCache',  $script:rgLocationCache)
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('HpPool',           $script:vmHpPool)
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('RestHelperDef',    $script:restHelperDef)
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('LogFile',          $script:LogFile)
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('ScalingExcludeTag',       $script:ScalingExcludeTag)
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('ShowFullUPN',             $script:ShowFullUPN)
    # PricingWindowsFallback is used when a VM's image offer cannot be identified
    # (e.g. custom/gallery images). $true = Windows PAYG; $false = Linux/base rate.
    # Derived from Costs.PricingWindowsLicence in config.psd1 (via $script:UseAHBPricing).
    $script:vmRefreshRunspace.SessionStateProxy.SetVariable('PricingWindowsFallback', (-not $script:UseAHBPricing))

    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Core-Init] Starting Core (Pass 1) refresh job`r`n") } catch {} }

    # Start the Core script asynchronously. BeginInvoke() returns immediately;
    # the result is collected in Invoke-SessionHostsTabTimer (branch b) when IsCompleted.
    $script:vmPS          = [System.Management.Automation.PowerShell]::Create()
    $script:vmPS.Runspace = $script:vmRefreshRunspace
    [void]$script:vmPS.AddScript($script:vmCoreScript)
    $script:vmHandle      = $script:vmPS.BeginInvoke()
}

# =============================================================================
# 4b. Trigger a Metrics (Pass 2) background refresh - Phases 4-5b
#
# Called automatically by Invoke-SessionHostsTabTimer immediately after the Core
# (Pass 1) job completes and the grid has been populated with Phase 1-3 data.
#
# Receives the sorted $vmRows array from the Core result so the Metrics script
# can stamp CPU%, Mem%, Disk IOPS etc. onto the same row objects. The UI thread
# then merges only the changed columns back into the DataTable via _SH_BackfillMetrics.
#
# If a Metrics job is already in progress (e.g. the Core pass ran early due to a
# manual refresh), the old job is abandoned - the new Core VmRows take precedence.
# =============================================================================

function Invoke-SessionHostsMetricsRefresh {
    param(
        # The sorted VmRows array returned by the Core job. The Metrics script
        # stamps metric values onto these objects in-place and returns them.
        [object[]]$CoreVmRows
    )

    # If a previous Metrics job is still running, let it finish - do not cancel it.
    # This avoids race conditions where an old job stamps stale values over new Core rows.
    # The timer's (c) branch will collect the old job first, then the next Core cycle
    # will launch a fresh Metrics job with up-to-date rows.
    if ($script:vmMetricsHandle -and -not $script:vmMetricsHandle.IsCompleted) {
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Metrics-Init] Previous Metrics job still running - skipping new launch`r`n") } catch {} }
        return
    }

    # ── Inject variables into the Metrics runspace ──────────────────────────────
    # $vmRows is the Core result - the Metrics script stamps Phase 4-5b values
    # onto these objects in-place and returns the enriched array as MetricRows.
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('vmRows',                      $CoreVmRows)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('ArmToken',                    (Get-ArmToken))
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('SubId',                       $script:vmSubId)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('HpPool',                      $script:vmHpPool)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('RestHelperDef',               $script:restHelperDef)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('LogFile',                     $script:LogFile)
    # Log Analytics (Phase 4)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('LawWorkspaceResourceId',      $script:LawWorkspaceResourceId)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('LawHeatMapAmberPct',          $script:LawHeatMapAmberPct)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('LawHeatMapRedPct',            $script:LawHeatMapRedPct)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('ShowCPU',                     $script:ShowCPU)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('ShowMem',                     $script:ShowMem)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('ShowDisk',                    $script:ShowDisk)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('ShowInputDelay',              $script:ShowInputDelay)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('LawInputDelayAmberMs',        $script:LawInputDelayAmberMs)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('LawInputDelayRedMs',          $script:LawInputDelayRedMs)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('InputDelayExcludeProcesses',  $script:InputDelayExcludeProcesses)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('LawQueryBaseUrl',             $script:LawQueryBaseUrl)
    $_lawTok = ''
    if ($script:LawQueryBaseUrl) {
        try {
            $_lawTok = Get-LawToken
        } catch {
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Metrics-Init] LawToken FAILED: $_`r`n") } catch {} }
        }
    }
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('LawToken',                   $_lawTok)
    # Azure Monitor Metrics (Phase 5 + 5b)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('ShowDiskPerf',                $script:ShowDiskPerf)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('DiskQueueAmberVal',           $script:DiskQueueAmberVal)
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('DiskQueueRedVal',             $script:DiskQueueRedVal)
    # Shared reference: the Metrics runspace reads and writes this hashtable directly.
    # Because hashtables are .NET reference types, SetVariable passes the reference
    # (not a copy) so mutations inside the runspace (DNS failure caching) are visible
    # immediately in the main script scope on subsequent refresh cycles.
    $script:vmMetricsRunspace.SessionStateProxy.SetVariable('metricsRegionalBatchFailed',  $script:metricsRegionalBatchFailed)

    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Metrics-Init] Starting Metrics (Pass 2) job for $($CoreVmRows.Count) row(s). LAW=$(if ($script:LawWorkspaceResourceId) {'configured'} else {'not configured'}), DiskPerf=$(if ($script:ShowDiskPerf) {'enabled'} else {'disabled'})`r`n") } catch {} }

    # Start the Metrics script asynchronously. BeginInvoke() returns immediately;
    # the result is collected in Invoke-SessionHostsTabTimer (branch c) when IsCompleted.
    $script:vmMetricsPS          = [System.Management.Automation.PowerShell]::Create()
    $script:vmMetricsPS.Runspace = $script:vmMetricsRunspace
    [void]$script:vmMetricsPS.AddScript($script:vmMetricsScript)
    $script:vmMetricsHandle      = $script:vmMetricsPS.BeginInvoke()
}

# =============================================================================
# 5. VM power actions (Start / Deallocate / Restart)
#
# Each action runs in a brand-new throw-away runspace so it never blocks the
# dedicated refresh runspace. A bearer token is passed as an argument; no Az
# modules are imported.
#
# Deallocate and Restart show a confirmation dialog before proceeding.
# All three actions use -NoWait so the call returns as soon as Azure has accepted
# the request rather than waiting for the operation to fully complete.
# Progress is tracked by Invoke-SessionHostsTabTimer polling $script:vmActionHandle.
# =============================================================================

function Invoke-SessionHostsPowerAction {
    param([string]$Action)

    # Guard: prevent starting a second action while one is already in flight
    if ($script:vmActionHandle -and -not $script:vmActionHandle.IsCompleted) {
        [System.Windows.MessageBox]::Show(
            'A power action is already in progress. Please wait for it to complete.',
            'Action In Progress',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }

    # Collect the selected VMs. Each DataRowView item is accessed like a hashtable
    # using column name as the key. _RG is the hidden resource group column.
    # Power State is also captured so we can skip VMs already in the target state.
    $targets = @(foreach ($item in $script:SHGrid.SelectedItems) {
        [PSCustomObject]@{ Name = [string]$item['VM Name']; RG = [string]$item['_RG']; PowerState = [string]$item['Power State'] }
    })
    if ($targets.Count -eq 0) { return }

    # Skip VMs that are already in the target state:
    #   - Deallocate: skip VMs with Power State 'Shutdown' (already stopped/deallocated)
    #   - Start:      skip VMs with Power State 'Available' (already running)
    # Restart applies to running VMs only, so skip Shutdown VMs as well.
    $skipped  = @()
    $original = $targets
    if ($Action -eq 'Deallocate' -or $Action -eq 'Restart') {
        $skipped = @($targets | Where-Object { $_.PowerState -in @('Deallocated','Stopped') })
        $targets = @($targets | Where-Object { $_.PowerState -notin @('Deallocated','Stopped') })
    }
    elseif ($Action -eq 'Start') {
        $skipped = @($targets | Where-Object { $_.PowerState -eq 'Running' })
        $targets = @($targets | Where-Object { $_.PowerState -ne 'Running' })
    }

    # If all selected VMs are already in the target state, inform the user and exit
    if ($targets.Count -eq 0) {
        $stateWord = if ($Action -eq 'Deallocate') { 'shut down' } elseif ($Action -eq 'Start') { 'running' } else { 'shut down' }
        $script:SHActionStatus.Text = "All $($original.Count) selected VM(s) are already $stateWord - nothing to do."
        return
    }

    # If some VMs were skipped, store the note at script scope so the timer
    # completion handler can append it to the result message.
    $script:vmActionSkippedNote = ''
    if ($skipped.Count -gt 0) {
        $skippedNames = ($skipped | ForEach-Object { $_.Name }) -join ', '
        $script:vmActionSkippedNote = " | Skipped (already $( if ($Action -eq 'Start') { 'running' } else { 'shut down' } )): $skippedNames"
    }

    $vmList = ($targets | ForEach-Object { $_.Name }) -join ', '

    # Deallocate and Restart are destructive/disruptive - require explicit confirmation.
    # Start is safe to fire without confirmation.
    if ($Action -in @('Deallocate', 'Restart')) {
        $icon    = if ($Action -eq 'Deallocate') { [System.Windows.MessageBoxImage]::Warning } else { [System.Windows.MessageBoxImage]::Question }
        $confirm = [System.Windows.MessageBox]::Show(
            "$Action the following VM(s)?`n`n$vmList",
            "Confirm $Action",
            [System.Windows.MessageBoxButton]::YesNo,
            $icon)
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    # Audit log - record each VM power action
    foreach ($t in $targets) { Write-AuditLog -Action "VM$Action" -Target $t.Name }

    # Update the status bar and disable all action buttons while the action is in flight
    $script:vmActionType                    = 'Power'
    $script:SHActionStatus.Text             = "$Action in progress: $vmList..."
    $script:SHStartButton.IsEnabled         = $false
    $script:SHDeallocateButton.IsEnabled    = $false
    $script:SHRestartButton.IsEnabled       = $false
    $script:SHEnableDrainButton.IsEnabled   = $false
    $script:SHDisableDrainButton.IsEnabled  = $false

    # The action scriptblock runs in a fresh runspace. Modules are imported fresh
    # each time (acceptable overhead since actions are infrequent).
    # $targetsJson passes the VM list via JSON so it survives serialisation across
    # the runspace boundary (PSCustomObject would be deserialized as a generic object).
    # REST API power actions - POST to start/deallocate/restart returns 202 Accepted (inherently async)
    $actionScript = [scriptblock]::Create($script:restHelperDef + @'
        $tok = $args[0]; $subId = $args[1]; $targetsJson = $args[2]; $action = $args[3]
        $targets = $targetsJson | ConvertFrom-Json
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $targets) {
            try {
                $vmAction = switch ($action) { 'Start'{'start'} 'Deallocate'{'deallocate'} 'Restart'{'restart'} }
                Invoke-Arm -Method POST -Path "/subscriptions/$subId/resourceGroups/$($t.RG)/providers/Microsoft.Compute/virtualMachines/$($t.Name)/$vmAction" -Token $tok -ApiVersion '2024-07-01' -FullResponse | Out-Null
                $results.Add("OK: $($t.Name)")
            } catch {
                $results.Add("ERR: $($t.Name) - $_")
            }
        }
        $results -join ' | '
'@)

    $targetsJson = ($targets | ConvertTo-Json -Compress)
    $_subId = if ($script:vmSubId) { $script:vmSubId } else { $subscriptionId }

    $script:vmActionRS            = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:vmActionRS.Open()
    $script:vmActionPS            = [System.Management.Automation.PowerShell]::Create()
    $script:vmActionPS.Runspace   = $script:vmActionRS
    [void]$script:vmActionPS.AddScript($actionScript).AddArgument((Get-ArmToken)).AddArgument($_subId).AddArgument($targetsJson).AddArgument($Action)
    $script:vmActionHandle        = $script:vmActionPS.BeginInvoke()
    $script:vmActionLabel         = $Action
}

# =============================================================================
# 5b. Drain mode actions (Enable / Disable Drain)
#
# Runs in a fresh throw-away runspace (same pattern as power actions) so it
# never blocks the dedicated refresh runspace. Uses REST API PATCH to toggle
# the allowNewSession property on session host resources.
#
# _SHName (hidden column) provides the full session host name required by the
# AVD API (e.g. "avd-vm-0.contoso.com"). _RG and Host Pool columns supply the
# resource group and host pool name needed to target the correct resource.
# Both Enable and Disable require explicit confirmation before proceeding.
#
# MFA / CONDITIONAL ACCESS:
#   The PATCH call uses Invoke-Arm which cannot handle claims challenges.
#   If the environment has Conditional Access policies requiring MFA for ARM
#   writes, the call will fail with 403 "RequestDisallowedByAzure".  The catch
#   block detects this and returns an MFA_CHALLENGE marker (same pattern as the
#   logoff scripts in session-detail.ps1).  The result handler in
#   Invoke-SessionHostsTabTimer section (c) checks for this marker and calls
#   Resolve-MfaChallenge (defined in rest-api-helpers.ps1), which:
#     - First time: prompts user, opens browser for MFA, child process executes
#       the PATCH via Invoke-AzRestMethod (which handles claims natively)
#     - Subsequent times: silently launches a child process that uses the shared
#       MSAL cache from disk - no dialog, no browser
#   The $_mfaEverDone flag is shared across logoff and drain, so authenticating
#   once for either operation covers both.
# =============================================================================

function Invoke-SessionHostsDrainAction {
    param([bool]$EnableDrain)

    # Guard: prevent starting a second action while one is already in flight
    if ($script:vmActionHandle -and -not $script:vmActionHandle.IsCompleted) {
        [System.Windows.MessageBox]::Show(
            'An action is already in progress. Please wait for it to complete.',
            'Action In Progress',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }

    # Collect selected rows. _SHName is the full AVD session host name ("vm.fqdn")
    # required by the AVD REST API. _RG and Host Pool provide targeting info.
    $targets = @(foreach ($item in $script:SHGrid.SelectedItems) {
        [PSCustomObject]@{
            Name   = [string]$item['VM Name']
            RG     = [string]$item['_HpRG']       # Host pool resource group (for AVD drain API)
            VMRG   = [string]$item['_RG']          # VM resource group (for Compute tag API)
            HP     = [string]$item['Host Pool']
            SHName = [string]$item['_SHName']
        }
    })
    if ($targets.Count -eq 0) { return }

    $vmList = ($targets | ForEach-Object { $_.Name }) -join ', '
    $label  = if ($EnableDrain) { 'Enable Drain' } else { 'Disable Drain' }
    $tip    = if ($EnableDrain) { 'New sessions will be blocked until drain mode is disabled.' } `
                                else { 'New sessions will be allowed on the selected host(s).' }
    # If the scaling tag toggle is enabled, mention it in the confirmation
    $tagTip = ''
    if ($script:DrainSetScalingTag) {
        $tagTip = if ($EnableDrain) { "`nScaling exclude tag '$($script:ScalingExcludeTag)' will also be set on the VM(s)." } `
                                    else { "`nScaling exclude tag '$($script:ScalingExcludeTag)' will also be removed from the VM(s)." }
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "$label on the following host(s)?`n$tip$tagTip`n`n$vmList",
        "Confirm $label",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    # Audit log - record drain mode change for each host
    $drainAction = if ($EnableDrain) { 'DrainEnable' } else { 'DrainDisable' }
    foreach ($t in $targets) { Write-AuditLog -Action $drainAction -Target $t.Name }
    # Audit log - record tag action if scaling tag toggle is enabled
    if ($script:DrainSetScalingTag) {
        $tagAction = if ($EnableDrain) { 'TagSet' } else { 'TagRemove' }
        foreach ($t in $targets) { Write-AuditLog -Action $tagAction -Target $t.Name -Details $script:ScalingExcludeTag }
    }

    # Disable all action buttons while the drain action is in flight
    $script:vmActionType                    = 'Drain'
    $script:SHActionStatus.Text             = "$label in progress: $vmList..."
    $script:SHStartButton.IsEnabled         = $false
    $script:SHDeallocateButton.IsEnabled    = $false
    $script:SHRestartButton.IsEnabled       = $false
    $script:SHEnableDrainButton.IsEnabled   = $false
    $script:SHDisableDrainButton.IsEnabled  = $false

    # AllowNewSession is the inverse of drain: EnableDrain=true -> AllowNewSession=false
    $allowNewStr = if ($EnableDrain) { 'False' } else { 'True' }
    $targetsJson = ($targets | ConvertTo-Json -Compress)

    # REST API drain mode - PATCH session host with allowNewSession property.
    # If DrainSetScalingTag is enabled, also set/remove the scaling exclude tag
    # on the VM resource using the Microsoft.Resources Tags API with Merge/Delete
    # operation (safe - does not overwrite existing VM tags).
    $actionScript = [scriptblock]::Create($script:restHelperDef + @'
        $tok = $args[0]; $subId = $args[1]; $targetsJson = $args[2]; $allowNewStr = $args[3]
        $setTag = $args[4]; $tagName = $args[5]
        [bool]$allowNew = [System.Convert]::ToBoolean($allowNewStr)
        [bool]$doTag    = [System.Convert]::ToBoolean($setTag)
        $targets = $targetsJson | ConvertFrom-Json
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $targets) {
            try {
                # Step 1: Set or remove the scaling exclude tag on the VM resource FIRST.
                # If this fails, we abort and do NOT change drain mode - the user needs
                # to know the tag couldn't be set before we block/allow new sessions.
                # Uses the Microsoft.Resources Tags API (api-version 2021-04-01):
                #   - "Merge" operation: adds/updates the tag without affecting other tags
                #   - "Delete" operation: removes only the specified tag key
                # The path targets the VM resource (using VMRG, not the host pool RG).
                if ($doTag -and $tagName) {
                    $vmTagPath = "/subscriptions/$subId/resourceGroups/$($t.VMRG)/providers/Microsoft.Compute/virtualMachines/$($t.Name)/providers/Microsoft.Resources/tags/default"
                    if (-not $allowNew) {
                        # Drain enabled -> set the scaling exclude tag
                        $tagBody = @{ operation = 'Merge'; properties = @{ tags = @{ $tagName = 'True' } } }
                    } else {
                        # Drain disabled -> remove the scaling exclude tag
                        $tagBody = @{ operation = 'Delete'; properties = @{ tags = @{ $tagName = '' } } }
                    }
                    Invoke-Arm -Method PATCH -Path $vmTagPath -Token $tok -ApiVersion '2021-04-01' -Body $tagBody -FullResponse | Out-Null
                }

                # Step 2: PATCH drain mode on the AVD session host resource.
                # Only reached if the tag step succeeded (or was skipped).
                $body = @{ properties = @{ allowNewSession = $allowNew } }
                Invoke-Arm -Method PATCH -Path "/subscriptions/$subId/resourceGroups/$($t.RG)/providers/Microsoft.DesktopVirtualization/hostPools/$($t.HP)/sessionHosts/$($t.SHName)" -Token $tok -ApiVersion '2024-04-03' -Body $body -FullResponse | Out-Null

                $results.Add("OK: $($t.Name)")
            } catch {
                $errText = $_.ToString()
                if ($errText -match 'RequestDisallowedByAzure') {
                    $mfaClaims = $null
                    try {
                        $wwwAuth = $_.Exception.Response.Headers['WWW-Authenticate']
                        if ($wwwAuth -match 'claims="([^"]+)"') { $mfaClaims = $Matches[1] }
                    } catch {}
                    if (-not $mfaClaims) {
                        $det = try { $_.ErrorDetails.Message } catch { $null }
                        if ($det -match '"claimsChallenge"\s*:\s*"([^"]+)"') { $mfaClaims = $Matches[1] }
                    }
                    if (-not $mfaClaims -and $errText -match '"claimsChallenge"\s*:\s*"([^"]+)"') {
                        $mfaClaims = $Matches[1]
                    }
                    $results.Add("MFA_CHALLENGE:$($mfaClaims):::$($t.Name)")
                } else {
                    $results.Add("ERR: $($t.Name) - $errText")
                }
            }
        }
        $results -join ' | '
'@)

    $_subId = if ($script:vmSubId) { $script:vmSubId } else { $subscriptionId }

    # Pre-compute ARM operations for MFA retry (child process executes PATCH directly)
    $bodyJson = (@{ properties = @{ allowNewSession = [System.Convert]::ToBoolean($allowNewStr) } } | ConvertTo-Json -Compress)
    $script:_mfaArmOps = @($targets | ForEach-Object {
        @{ Method = 'PATCH'; Path = "/subscriptions/$_subId/resourceGroups/$($_.RG)/providers/Microsoft.DesktopVirtualization/hostPools/$($_.HP)/sessionHosts/$($_.SHName)?api-version=2024-04-03"; Body = $bodyJson }
    })

    $script:vmActionRS            = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:vmActionRS.Open()
    $script:vmActionPS            = [System.Management.Automation.PowerShell]::Create()
    $script:vmActionPS.Runspace   = $script:vmActionRS
    [void]$script:vmActionPS.AddScript($actionScript).AddArgument((Get-ArmToken)).AddArgument($_subId).AddArgument($targetsJson).AddArgument($allowNewStr).AddArgument($script:DrainSetScalingTag.ToString()).AddArgument($script:ScalingExcludeTag)
    $script:vmActionHandle        = $script:vmActionPS.BeginInvoke()
    $script:vmActionLabel         = $label
}

# =============================================================================
# 6. Per-second tick  -  called by the main DispatcherTimer every second
#
# The master timer in avd-live-dashboard.ps1 calls this function once per second
# on the UI thread. It handles four independent concerns:
#
#   a) Scheduling and triggering the 60-second Core (Pass 1) refresh
#   b) Collecting the completed Core job result → updates the grid immediately,
#      then launches the Metrics (Pass 2) job for Phase 4/5/5b data
#   c) Collecting the completed Metrics job result → backfills metric columns
#      into the existing grid rows via _SH_BackfillMetrics (no grid flicker)
#   d) Collecting results from a completed power action job (drain/start/stop)
#   e) Updating the live countdown / summary text in the status bar
# =============================================================================

function Invoke-SessionHostsTabTimer {

    # ── Visibility gate - pause all activity when the tab is not active ──────
    # This matches the pattern used by the Infrastructure tab. When the user is
    # on a different tab there is no point firing API calls or updating the grid.
    # In-flight runspace jobs (Core / Metrics) are left running and their results
    # are collected on the next tick after the user returns to this tab.
    if (-not $script:SHGrid.IsVisible) { return }

    # ── First-run gate: wait for the RG location cache ───────────────────────
    # vmNextRefresh is initialised to DateTime::MaxValue so the Core refresh is
    # held until the main background refresh has populated $script:rgLocationCache.
    # Once the cache has at least one entry (Update-UI has run and merged the
    # RG locations returned by the background runspace) we release the gate by
    # setting vmNextRefresh to Now, which causes the (a) block below to fire
    # on the very next timer tick. This guarantees that every VM's RG is known
    # before the first session hosts job runs - no 'unknown' region, no retries.
    # Release the first-run gate only when BOTH conditions are true:
    #   1. The RG location cache is populated (background refresh has completed).
    #   2. The user has visited the Session Hosts tab at least once.
    # This prevents the data load from firing at startup before the tab is opened.
    # $script:vmTabVisited is set to $true by the MainTabControl SelectionChanged
    # handler wired in avd-live-dashboard.ps1.
    if ($script:vmNextRefresh -eq [DateTime]::MaxValue -and
        $script:rgLocationCache.Count -gt 0 -and
        $script:vmTabVisited) {
        $script:vmNextRefresh = [DateTime]::Now
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Timer] RG location cache populated ($($script:rgLocationCache.Count) entries) and tab visited - releasing first-run gate`r`n") } catch {} }
    }

    # ── (a) Trigger the scheduled Core refresh when due ──────────────────────
    # Only reached when the tab is visible (visibility gate above).
    # We block firing a new Core job if the Metrics job is still running -
    # the new Core rows would immediately be followed by a new Metrics launch, but
    # the old Metrics job would stamp stale values on top if it finished later.
    # Waiting for both jobs to complete before re-triggering is the safest approach.
    $coreJobIdle    = (-not $script:vmHandle    -or $script:vmHandle.IsCompleted)
    $metricsJobIdle = (-not $script:vmMetricsHandle -or $script:vmMetricsHandle.IsCompleted)
    if ($script:vmNextRefresh -and [DateTime]::Now -ge $script:vmNextRefresh -and
        $coreJobIdle -and $metricsJobIdle) {
        Invoke-SessionHostsTabRefresh
    }

    # ── (b) Collect completed Core (Pass 1) job result ───────────────────────
    # IsCompleted becomes true once the Core scriptblock has returned.
    # EndInvoke() retrieves the pipeline output ([PSCustomObject]@{Pass='Core';...})
    # and re-throws any terminating errors from inside the runspace.
    #
    # On success:
    #   1. Populate the grid immediately with Phase 1-3 data (VM names, sessions,
    #      states, Resource Graph metadata). The user can see the data right away.
    #   2. Launch the Metrics (Pass 2) job to begin Phases 4-5b in the background.
    #   3. Update the status bar to indicate the Metrics pass is in progress.
    if ($script:vmHandle -and $script:vmHandle.IsCompleted) {
        try {
            $coreData = $script:vmPS.EndInvoke($script:vmHandle)
            if ($coreData -and $coreData.VmRows) {
                if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Timer] Core job completed - $($coreData.VmRows.Count) row(s) received. Updating grid and launching Metrics job.`r`n") } catch {} }

                # Populate the grid with Core data immediately - this is the fast render.
                # The user sees VM names, sessions, states, IP, SKU, etc. right away.
                _SH_UpdateGrid -VmRows $coreData.VmRows -Timestamp $coreData.Timestamp

                # Surface any Resource Graph (Phase 3) error in the action status bar.
                # Phase 3 errors are non-fatal - the grid still shows AVD data.
                if ($coreData.Phase3Error) {
                    $script:SHActionStatus.Text = $coreData.Phase3Error
                    Write-Log "WARN [Session Hosts] Phase 3 (Resource Graph): $($coreData.Phase3Error)"
                }

                # ── Unknown region retry logic ────────────────────────��───────────
                # If VMs show 'unknown' region it means the RG location cache was
                # not yet fully populated when the Core job ran. Schedule a rapid
                # retry (15s) so the correct region appears without waiting 60s.
                # Up to 3 rapid retries, then accept the state and resume the normal
                # 60s cycle (the counter resets to 0 once all regions resolve).
                $hasUnknown = @($coreData.VmRows | Where-Object { $_.'Region' -eq 'unknown' })
                if ($hasUnknown.Count -gt 0 -and $script:rgLocationCache.Count -gt 0 -and $script:vmRegionRetryCount -lt 3) {
                    $script:vmRegionRetryCount++
                    Write-Log "[Session Hosts] $($hasUnknown.Count) VM(s) still have unknown region - retry $($script:vmRegionRetryCount)/3 in 15s"
                    $script:vmNextRefresh = [DateTime]::Now.AddSeconds(15)
                } else {
                    if ($hasUnknown.Count -gt 0 -and $script:vmRegionRetryCount -ge 3) {
                        Write-Log "[Session Hosts] $($hasUnknown.Count) VM(s) still have unknown region after 3 retries - resuming normal cycle"
                    }
                    $script:vmRegionRetryCount = 0   # reset so retries fire again if unknowns reappear
                    $script:vmNextRefresh = [DateTime]::Now.AddSeconds($script:VmRefreshIntervalSeconds)
                }

                # ── Launch the Metrics (Pass 2) job ──────────────────���─────────────
                # Phases 4-5b run in a separate runspace so the grid is not blocked.
                # The Metrics job receives the same sorted VmRows array - it stamps
                # metric values onto them in-place and returns the enriched rows.
                Invoke-SessionHostsMetricsRefresh -CoreVmRows $coreData.VmRows
            }
        } catch {
            $script:SHStatusText.Text = "Session Hosts refresh error: $_"
            Write-Log "ERROR [Session Hosts] Core job failed: $_"
            # Still reschedule so the tab keeps trying rather than stopping permanently
            $script:vmNextRefresh = [DateTime]::Now.AddSeconds($script:VmRefreshIntervalSeconds)
        } finally {
            # Always dispose the PowerShell instance; the runspace itself is kept alive.
            # The Metrics runspace ($script:vmMetricsRunspace) is a separate object -
            # disposing vmPS here does NOT affect the Metrics job.
            try { $script:vmPS.Dispose() } catch {}
            $script:vmHandle = $null
            $script:vmPS     = $null
        }
    }

    # ── (c) Collect completed Metrics (Pass 2) job result ────────────────────
    # The Metrics job (Phases 4-5b) runs concurrently after the Core job returns.
    # IsCompleted becomes true once Phase 5b has finished (or been skipped).
    # EndInvoke() retrieves [PSCustomObject]@{Pass='Metrics'; MetricRows=...;...}.
    #
    # On success: call _SH_BackfillMetrics to merge CPU%, Disk IOPS etc. into the
    # existing DataTable rows by VM Name key - no full grid rebuild, no flicker.
    if ($script:vmMetricsHandle -and $script:vmMetricsHandle.IsCompleted) {
        try {
            $metricsData = $script:vmMetricsPS.EndInvoke($script:vmMetricsHandle)
            if ($metricsData -and $metricsData.MetricRows) {
                if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [Timer] Metrics job completed - $($metricsData.MetricRows.Count) row(s) received. Backfilling metric columns.`r`n") } catch {} }

                # Merge metric columns into the existing DataTable rows.
                # Errors are surfaced to the status bar inside _SH_BackfillMetrics.
                _SH_BackfillMetrics -MetricRows  $metricsData.MetricRows `
                                    -Phase4Error $metricsData.Phase4Error `
                                    -Phase5Error $metricsData.Phase5Error `
                                    -Phase5Mode  $metricsData.Phase5Mode

                # Update the displayed last-refresh timestamp to the Metrics completion
                # time so the status bar reflects when ALL data (including metrics) was last
                # fully updated, not just when the Core (Phase 1-3) data arrived.
                $script:vmLastRefreshTime = $metricsData.Timestamp
            }
        } catch {
            Write-Log "ERROR [Session Hosts] Metrics job failed: $_"
        } finally {
            # Dispose the Metrics PS instance; the Metrics runspace is kept alive
            # for the next cycle just like the Core runspace.
            try { $script:vmMetricsPS.Dispose() } catch {}
            $script:vmMetricsHandle = $null
            $script:vmMetricsPS     = $null
        }
    }

    # ── (d) Collect completed action job results (power / drain) ────────────────
    # The action runs in a throw-away runspace; dispose both PS and runspace here.
    if ($script:vmActionHandle -and $script:vmActionHandle.IsCompleted) {
        try {
            $rawResult = @($script:vmActionPS.EndInvoke($script:vmActionHandle))
            $result = $rawResult -join ' | '
            # Check for MFA claims challenge in drain mode results.
            # The drain scriptblock returns MFA_CHALLENGE markers when Invoke-Arm
            # gets 403 RequestDisallowedByAzure. We split the pipe-separated result
            # string, extract any MFA markers, and pass them to Resolve-MfaChallenge
            # (session-detail.ps1) which handles the MFA flow. StatusText points to
            # the Session Hosts tab status bar; PauseTimer is $null since this tab
            # has no countdown timer to pause.
            $mfaMarkers = @($result -split '\s*\|\s*' | Where-Object { $_ -match '^MFA_CHALLENGE:' })
            if ($mfaMarkers.Count -gt 0 -and $script:_mfaArmOps) {
                if (Resolve-MfaChallenge -Errors $mfaMarkers -ArmOperations $script:_mfaArmOps -StatusText $script:SHActionStatus -PauseTimer $null) {
                    if ($script:_mfaRetryReady) {
                        $script:SHActionStatus.Text = "$($script:vmActionLabel) initiated after MFA."
                        $script:vmNextRefresh = [DateTime]::Now   # trigger immediate grid refresh
                    }
                } else {
                    $script:SHActionStatus.Text = "$($script:vmActionLabel) initiated: $result$($script:vmActionSkippedNote)"
                }
            } else {
                $script:SHActionStatus.Text = "$($script:vmActionLabel) initiated: $result$($script:vmActionSkippedNote)"
            }
        } catch {
            $script:SHActionStatus.Text = "$($script:vmActionLabel) error: $_"
        } finally {
            try { $script:vmActionPS.Dispose() } catch {}
            try { $script:vmActionRS.Dispose() } catch {}
            $script:vmActionHandle = $null
            $script:vmActionPS     = $null
            $script:vmActionRS     = $null
            # Re-enable selection-dependent action buttons if the user still has rows selected
            $has = $script:SHGrid.SelectedItems.Count -gt 0
            $script:SHStartButton.IsEnabled         = $has
            $script:SHDeallocateButton.IsEnabled    = $has
            $script:SHRestartButton.IsEnabled       = $has
            $script:SHEnableDrainButton.IsEnabled   = $has
            $script:SHDisableDrainButton.IsEnabled  = $has
        }
    }

    # ── (e) Update live countdown / summary in the status bar ────────────────
    # Only shown once at least one successful refresh has completed.
    # The status bar progresses through three states per cycle:
    #   "Refreshing..."         - Core (Pass 1) job is running
    #   "Updating metrics..."   - Core done, grid visible; Metrics (Pass 2) in progress
    #   "Updated: HH:mm:ss  Next in Ns  | Metrics: Batch/Per-VM"  - both passes done
    if ($script:vmLastRefreshTime) {
        $vmRemaining  = [Math]::Ceiling(($script:vmNextRefresh - [DateTime]::Now).TotalSeconds)
        $lastTs       = $script:vmLastRefreshTime.ToString('HH:mm:ss')
        $activeCount  = if ($script:vmFilteredCountText) { $script:vmFilteredCountText } else { $script:vmCountText }
        $countStr     = if ($activeCount) { "$activeCount   |   " } else { '' }
        # Append disk metrics mode if known (set after first Metrics pass completes).
        # Helps diagnose Private Link environments where batch endpoint is blocked.
        $diskModeStr  = if ($script:vmPhase5Mode) { "   |   $($script:vmPhase5Mode)" } else { '' }

        $coreRunning    = $script:vmHandle        -and -not $script:vmHandle.IsCompleted
        $metricsRunning = $script:vmMetricsHandle -and -not $script:vmMetricsHandle.IsCompleted

        $script:SHStatusText.Text = if ($coreRunning) {
            "${countStr}Refreshing..."
        } elseif ($metricsRunning) {
            # Grid is already populated with Core data; metrics are being fetched in the background.
            "${countStr}Updating metrics..."
        } else {
            "${countStr}Updated: $lastTs   Next in ${vmRemaining}s${diskModeStr}"
        }
    }
}

# =============================================================================
# 7. Reset on subscription switch  -  called from the subscription picker
#
# When the user switches Azure subscription the existing data is stale.
# Setting $vmNextRefresh to Now causes Invoke-SessionHostsTabTimer to trigger
# Invoke-SessionHostsTabRefresh on its very next tick, fetching data for the new subscription.
# =============================================================================

function Reset-SessionHostsTab {
    $script:vmNextRefresh                = [DateTime]::Now
    $script:vmRegionRetryCount           = 0        # allow rapid retries for the new subscription
    $script:metricsRegionalBatchFailed   = @{}      # clear DNS-failure cache for new subscription
    $script:shDropdownSelections         = @{}      # clear per-column dropdown filters
    $script:shSortColumn                 = $null    # clear sort state
    $script:shSortDirection              = $null
    $script:shLawErrorShown              = $false   # re-arm LAW error popup for new subscription
}

# =============================================================================
# 8. Export grid to CSV  -  called by SHExportButton click
#
# Opens a SaveFileDialog pre-named with today's date/time, then exports every
# row in the DataTable (unfiltered) to CSV - the filter box does not limit the
# export so the user always gets the full dataset. The hidden _RG helper column
# is excluded from the output since it is an internal implementation detail.
# =============================================================================

function Invoke-SessionHostsExport {
    if (-not $script:vmDataTable) { return }

    $dlg          = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = "SessionHosts_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"

    if ($dlg.ShowDialog() -eq $true) {
        try {
            # Export all rows from the DataTable (ignoring any active RowFilter)
            # and drop the internal helper columns (_RG, _SHName) from the output.
            $script:vmDataTable.Rows |
                ForEach-Object {
                    $row = $_
                    $obj = [ordered]@{}
                    foreach ($col in $script:vmDataTable.Columns) {
                        if ($col.ColumnName -notin @('_RG', '_HpRG', '_SHName', '_CPUSort', '_MemSort', '_DiskSort', '_CPUColor', '_MemColor', '_DiskColor', '_InputDelaySort', '_InputDelayColor', '_InputDelayP95Sort', '_InputDelayP95Color', '_DiskIOPSSort', '_DiskIOPSPctSort', '_DiskIOPSPctColor', '_DiskQueueSort', '_DiskQueueColor', '_DiskProvIOPS', '_VMResourceId', '_UserTooltip', '_DiskTier', '_DiskSkuRaw', '_ComputeCostSort', '_DiskCostSort', '_TxnCostSort', '_TxnMoCostSort', '_TxnOpsSort')) {
                            $obj[$col.ColumnName] = $row[$col.ColumnName]
                        }
                    }
                    [PSCustomObject]$obj
                } |
                Export-Csv -Path $dlg.FileName -NoTypeInformation -Force
            $script:SHStatusText.Text = "Exported $($script:vmDataTable.Rows.Count) row(s) to $($dlg.FileName)"
        } catch {
            [System.Windows.MessageBox]::Show(
                "Export failed:`n$_", 'Export Error',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error) | Out-Null
        }
    }
}

# =============================================================================
# Private helpers
# =============================================================================

# _SH_BackfillMetrics
# Merges Phase 4 (Log Analytics) and Phase 5/5b (Azure Monitor) metric values
# from the completed Metrics (Pass 2) job into the existing DataTable rows.
#
# WHY NOT CALL _SH_UpdateGrid AGAIN?
# -----------------------------------
# _SH_UpdateGrid does a full table clear + reload (BeginLoadData / Rows.Clear /
# Rows.Add / EndLoadData) and re-assigns ItemsSource on first call. Calling it
# a second time for the Metrics pass would:
#   - Reset the WPF DataGrid's scroll position (user loses their place)
#   - Re-fire AutoGeneratingColumn (column widths re-set)
#   - Briefly flash the grid empty then refill (visible flicker)
#
# _SH_BackfillMetrics avoids all of that by updating only the metric columns
# in-place on the existing DataRow objects. The DataView notifies WPF of the
# individual cell changes - no full column rebuild, no scroll reset.
#
# COLUMN LIST:
#   Phase 4 (Log Analytics): CPU %, Mem %, OS Disk %, Input Delay Median,
#                             Input Delay P95, and all associated _Sort/_Color helpers.
#   Phase 5 (Azure Monitor): OS Disk IOPS, OS Disk IOPS %, OS Disk Queue,
#                             and all associated _Sort/_Color helpers.
#   Phase 5b (CPU Credits):  CPU Credits, _CPUCreditsSort, _CPUCreditsColor.
#
# Rows not present in the DataTable (e.g. VMs removed between Core and Metrics
# passes) are silently skipped.
function _SH_BackfillMetrics {
    param(
        # Array of PSCustomObject rows returned by $script:vmMetricsScript.
        # Each object has the same shape as a VmRow - metric properties are
        # stamped in-place inside the Metrics runspace before returning.
        [object[]]$MetricRows,

        # Optional error strings from Phase 4 / Phase 5; surfaced in the status bar.
        [string]$Phase4Error,
        [string]$Phase5Error,

        # Human-readable metrics mode string: "Metrics: Batch", "Metrics: Per-VM",
        # "Metrics: Batch (...) + Per-VM (...)", or $null if Phase 5 was skipped.
        [string]$Phase5Mode
    )

    # Guard: nothing to merge if the DataTable has not been created yet (should
    # not normally happen since the Core pass runs first, but be safe).
    if (-not $script:vmDataTable -or $script:vmDataTable.Columns.Count -eq 0) {
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [BackfillMetrics] WARN: DataTable not yet initialised - skipping backfill`r`n") } catch {} }
        return
    }

    # Build a lookup table: lowercase VM Name -> DataRow.
    # This is O(n) to build but makes the per-row merge O(1) instead of O(n^2).
    $rowMap = @{}
    foreach ($dr in $script:vmDataTable.Rows) {
        $key = ([string]$dr['VM Name']).ToLower()
        if ($key) { $rowMap[$key] = $dr }
    }

    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [BackfillMetrics] Merging metric data into $($rowMap.Count) DataTable row(s) from $($MetricRows.Count) MetricRow(s)`r`n") } catch {} }

    # Suspend DataTable constraint checking and index rebuilding during the bulk
    # update. EndLoadData() re-enables them in a single pass at the end, which
    # is far cheaper than per-cell updates with constraint checks active.
    $script:vmDataTable.BeginLoadData()
    try {
        foreach ($mr in $MetricRows) {
            $key = ([string]$mr.'VM Name').ToLower()
            if (-not $rowMap.ContainsKey($key)) { continue }   # VM removed between passes - skip
            $dr = $rowMap[$key]

            # ── Phase 4 columns (Log Analytics: CPU %, Mem %, OS Disk %, Input Delay) ──
            # These are stamped by the Metrics script only if the value changed from '-'.
            # We always copy - even '-' - so that a VM that was Available in Core but lost
            # its LAW data clears back to '-' rather than showing stale values.
            $dr['CPU %']              = $mr.'CPU %'
            $dr['Mem %']              = $mr.'Mem %'
            $dr['OS Disk %']          = $mr.'OS Disk %'
            $dr['_CPUSort']           = $mr.'_CPUSort'
            $dr['_MemSort']           = $mr.'_MemSort'
            $dr['_DiskSort']          = $mr.'_DiskSort'
            $dr['_CPUColor']          = $mr.'_CPUColor'
            $dr['_MemColor']          = $mr.'_MemColor'
            $dr['_DiskColor']         = $mr.'_DiskColor'
            $dr['Input Delay Median'] = $mr.'Input Delay Median'
            $dr['_InputDelaySort']    = $mr.'_InputDelaySort'
            $dr['_InputDelayColor']   = $mr.'_InputDelayColor'
            $dr['Input Delay P95']    = $mr.'Input Delay P95'
            $dr['_InputDelayP95Sort'] = $mr.'_InputDelayP95Sort'
            $dr['_InputDelayP95Color']= $mr.'_InputDelayP95Color'

            # ── Phase 5 columns (Azure Monitor: OS Disk IOPS + Queue Depth) ───────────
            $dr['OS Disk IOPS']       = $mr.'OS Disk IOPS'
            $dr['_DiskIOPSSort']      = $mr.'_DiskIOPSSort'
            $dr['OS Disk IOPS %']     = $mr.'OS Disk IOPS %'
            $dr['_DiskIOPSPctSort']   = $mr.'_DiskIOPSPctSort'
            $dr['_DiskIOPSPctColor']  = $mr.'_DiskIOPSPctColor'
            $dr['OS Disk Queue']      = $mr.'OS Disk Queue'
            $dr['_DiskQueueSort']     = $mr.'_DiskQueueSort'
            $dr['_DiskQueueColor']    = $mr.'_DiskQueueColor'

            # ── Phase 5b columns (CPU Credits Remaining - B-series VMs only) ─────────
            # Non-B-series rows have 'N/A' stamped in Phase 3 (Core pass) and the
            # Metrics pass leaves them unchanged, so copying here is safe.
            $dr['CPU Credits']        = $mr.'CPU Credits'
            $dr['_CPUCreditsSort']    = $mr.'_CPUCreditsSort'
            $dr['_CPUCreditsColor']   = $mr.'_CPUCreditsColor'
        }
    } finally {
        # Always re-enable constraint checking even if an error occurred mid-merge.
        $script:vmDataTable.EndLoadData()
    }

    # ── Surface any errors from the Metrics phases ───────────────────────────────
    # Phase 3 errors are shown by the Core pass; Phase 4/5 errors shown here.
    if ($Phase4Error) {
        Write-Log "WARN [Session Hosts] Phase 4 (Log Analytics): $Phase4Error"
        if (-not $script:shLawErrorShown) {
            $script:shLawErrorShown = $true
            $errMsg = $Phase4Error
            $null = [System.Windows.MessageBox]::Show(
                "Log Analytics data could not be fetched.`n`nCPU %, Memory %, Disk % and Input Delay columns will be unavailable.`n`nThis is usually caused by the Log Analytics workspace being accessible only via a private endpoint from an Azure VM, and not from this machine.`n`nError detail:`n$errMsg",
                'Log Analytics Unavailable',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning)
        }
    }
    if ($Phase5Error) {
        Write-Log "WARN [Session Hosts] Phase 5 (Azure Monitor): $Phase5Error"
        # Phase 5 errors are actionable (e.g. Private Link blocking batch endpoint),
        # so surface them in the action status bar where the user will notice them.
        if ($script:SHActionStatus) { $script:SHActionStatus.Text = $Phase5Error }
    }

    # ── Store the Phase 5 metrics mode for the status bar ────────────────────────
    # "Metrics: Batch"     = regional batch API succeeded (no Private Link restriction)
    # "Metrics: Per-VM"    = fell back to per-VM (Private Link env; batch DNS unavailable)
    # "Metrics: Batch+PerVM" = mixed (some regions batch, others per-VM)
    # $null                = Phase 5 did not run (ShowDiskPerf disabled, or no Available VMs)
    $script:vmPhase5Mode = $Phase5Mode

    # Persist the MetricRows so _SH_UpdateGrid can reapply them after the next
    # Core-pass table rebuild. Without this, metric columns blank out on every
    # auto-refresh until the following Metrics pass completes (~10-60s later).
    $script:shMetricsCache = $MetricRows

    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [BackfillMetrics] Merge complete. Phase5Mode='$Phase5Mode'`r`n") } catch {} }
}

# _SH_UpdateGrid
# Converts the $VmRows array to a DataTable, binds the DataView to the grid,
# and re-applies any active dropdown + text filters via _SH_ApplyFilters.
#
# DataTable / DataView is used instead of binding directly to a PSCustomObject
# collection because WPF DataGrid supports DataView.RowFilter for live SQL-LIKE
# filtering, which is far simpler than implementing ICollectionView filtering.
function _SH_UpdateGrid {
    param($VmRows, $Timestamp)

    # Store last inputs so cost-lookup.ps1 can re-invoke this function after a price fetch
    $script:shLastVmRows    = $VmRows
    $script:shLastTimestamp = $Timestamp

    # Save sort state before rebinding (user click-sort survives refresh cycles)
    foreach ($col in $script:SHGrid.Columns) {
        if ($null -ne $col.SortDirection) {
            $script:shSortColumn    = [string]$col.SortMemberPath
            $script:shSortDirection = $col.SortDirection
            break
        }
    }

    # ── Build / refresh the DataTable ───────────────────────────────────────────
    # DataView.RowFilter is used for live filtering, which requires a DataTable.
    #
    # SCROLL POSITION STRATEGY - root cause fix
    # ------------------------------------------
    # The previous approach rebuilt $script:vmDataTable from scratch on every refresh
    # and re-assigned ItemsSource, which caused WPF to:
    #   1. Fire AutoGeneratingColumn for every column (full column rebuild)
    #   2. Reset the internal ScrollViewer to (0,0)
    # This produced visible flicker and required a DispatcherTimer workaround.
    #
    # The fix: keep the SAME DataTable instance across refreshes.
    #   - First call: create DataTable normally, set ItemsSource once.
    #   - Subsequent calls: use BeginLoadData/EndLoadData to clear rows and
    #     repopulate in-place. The DefaultView object stays the same, ItemsSource
    #     is never reassigned, AutoGeneratingColumn never re-fires, and the
    #     ScrollViewer is untouched - scroll position is naturally preserved.
    $newRows = @($VmRows)

    if (-not $script:vmDataTable -or $script:vmDataTable.Columns.Count -eq 0) {
        # First call - create the DataTable and set ItemsSource
        $script:vmDataTable = ConvertTo-DataTable -Objects $newRows
    } else {
        # Subsequent calls - update rows in-place without replacing the DataTable.
        # BeginLoadData suppresses constraint checks and index maintenance during the
        # bulk clear+reload, then EndLoadData re-enables them in one pass.
        $script:vmDataTable.BeginLoadData()
        $script:vmDataTable.Rows.Clear()
        foreach ($obj in $newRows) {
            $row = $script:vmDataTable.NewRow()
            foreach ($prop in $obj.PSObject.Properties.Name) {
                $v = $obj.$prop
                if ($script:vmDataTable.Columns.Contains($prop)) {
                    $row[$prop] = if ($null -eq $v) { [DBNull]::Value } else { $v }
                }
            }
            $script:vmDataTable.Rows.Add($row)
        }
        $script:vmDataTable.EndLoadData()
    }

    # Rebuild the shToPoolMap from the freshly populated DataTable.
    # This is a lightweight lowercase VM-name → Host Pool lookup used by the
    # Session History tab to resolve session host names to host pool names.
    # Rebuilt here (not on-demand) so it's always ready even if Session History
    # loads before the Session Hosts tab has been opened by the user.
    $script:shToPoolMap = @{}
    foreach ($row in $script:vmDataTable.Rows) {
        $vmName = [string]$row['VM Name']
        $hp     = [string]$row['Host Pool']
        if ($vmName -and $hp) { $script:shToPoolMap[$vmName.ToLower()] = $hp }
    }

    # Reapply cached costs so they survive the DataTable row refresh above.
    # Prices are fetched once when the user clicks Load Costs and stored in
    # $script:shCostCache. No pricing API calls are made here.
    if ($script:shCostCache -and $script:shCostCache.Count -gt 0) {
        foreach ($row in $script:vmDataTable.Rows) {
            $vm = [string]$row['VM Name']
            if (-not $script:shCostCache.ContainsKey($vm)) { continue }
            $c     = $script:shCostCache[$vm]
            $state = [string]$row['Power State']
            # Recompute monthly cost from the cached hourly rate using the current power state.
            # This ensures VMs that were deallocated when Load Costs was clicked will show the
            # correct cost once they come online, without needing another Load Costs click.
            $computeMo = if ($state -eq 'Running' -and $c.ComputeHr -gt 0) {
                $c.ComputeHr * $script:HoursPerMonth
            } else { $c.Compute }
            $row['Compute GBP/mo']   = if ($computeMo -gt 0) { '{0:F2}' -f $computeMo } elseif ($state -ne 'Running') { '0.00' } else { '-' }
            $row['_ComputeCostSort'] = $computeMo
            $row['Disk GBP/mo']      = if ($c.Disk -gt 0)     { '{0:F2}' -f $c.Disk    } else { '-' }
            $row['_DiskCostSort']    = $c.Disk
            # Txn -lt 0 means Premium SSD - no per-I/O billing, show N/A for both txn columns.
            $row['Txn GBP/10K']      = if ($c.Txn -ge 0) { '{0:F4}' -f $c.Txn } else { 'N/A' }
            $row['_TxnCostSort']     = $c.Txn
            if ($c.Txn -lt 0) { $row['Txn GBP/mo'] = 'N/A' }
        }
    }

    # Reapply Cost Management transaction costs so they survive the row refresh above.
    # Populated by shTxnCostTimer tick in cost-lookup.ps1 when Load Costs is clicked.
    if ($script:shTxnMoCache -and $script:shTxnMoCache.Count -gt 0) {
        foreach ($row in $script:vmDataTable.Rows) {
            $vm = [string]$row['VM Name']
            if ($script:shTxnMoCache.ContainsKey($vm)) {
                $mo = $script:shTxnMoCache[$vm]
                $row['Txn GBP/mo']     = if ($mo -ge 0) { '{0:F2}' -f $mo } else { '-' }
                $row['_TxnMoCostSort'] = $mo
            }
        }
    }

    # Reapply the last Metrics pass results so metric columns (CPU%, Mem%, Disk IOPS,
    # Input Delay, CPU Credits, etc.) survive the Core-pass row rebuild above.
    # Without this, metric columns blank out on every auto-refresh until the next
    # Metrics pass completes (~10-60s later). The cache is updated by _SH_BackfillMetrics
    # each time the Metrics pass finishes.
    if ($script:shMetricsCache -and $script:shMetricsCache.Count -gt 0) {
        $rowMap = @{}
        foreach ($dr in $script:vmDataTable.Rows) {
            $key = ([string]$dr['VM Name']).ToLower()
            if ($key) { $rowMap[$key] = $dr }
        }
        foreach ($mr in $script:shMetricsCache) {
            $key = ([string]$mr.'VM Name').ToLower()
            if (-not $rowMap.ContainsKey($key)) { continue }
            $dr = $rowMap[$key]
            $dr['CPU %']              = $mr.'CPU %'
            $dr['Mem %']              = $mr.'Mem %'
            $dr['OS Disk %']          = $mr.'OS Disk %'
            $dr['_CPUSort']           = $mr.'_CPUSort'
            $dr['_MemSort']           = $mr.'_MemSort'
            $dr['_DiskSort']          = $mr.'_DiskSort'
            $dr['_CPUColor']          = $mr.'_CPUColor'
            $dr['_MemColor']          = $mr.'_MemColor'
            $dr['_DiskColor']         = $mr.'_DiskColor'
            $dr['Input Delay Median'] = $mr.'Input Delay Median'
            $dr['_InputDelaySort']    = $mr.'_InputDelaySort'
            $dr['_InputDelayColor']   = $mr.'_InputDelayColor'
            $dr['Input Delay P95']    = $mr.'Input Delay P95'
            $dr['_InputDelayP95Sort'] = $mr.'_InputDelayP95Sort'
            $dr['_InputDelayP95Color']= $mr.'_InputDelayP95Color'
            $dr['OS Disk IOPS']       = $mr.'OS Disk IOPS'
            $dr['_DiskIOPSSort']      = $mr.'_DiskIOPSSort'
            $dr['OS Disk IOPS %']     = $mr.'OS Disk IOPS %'
            $dr['_DiskIOPSPctSort']   = $mr.'_DiskIOPSPctSort'
            $dr['_DiskIOPSPctColor']  = $mr.'_DiskIOPSPctColor'
            $dr['OS Disk Queue']      = $mr.'OS Disk Queue'
            $dr['_DiskQueueSort']     = $mr.'_DiskQueueSort'
            $dr['_DiskQueueColor']    = $mr.'_DiskQueueColor'
            $dr['CPU Credits']        = $mr.'CPU Credits'
            $dr['_CPUCreditsSort']    = $mr.'_CPUCreditsSort'
            $dr['_CPUCreditsColor']   = $mr.'_CPUCreditsColor'
        }
    }

    # Bind ItemsSource on the first call only. Subsequent refreshes reuse the same
    # DefaultView so WPF never rebuilds columns or resets scroll position.
    if ($script:SHGrid.ItemsSource -ne $script:vmDataTable.DefaultView) {
        $script:SHGrid.ItemsSource = $script:vmDataTable.DefaultView
    }

    # Rebuild dropdown filter options from the freshly-populated DataTable rows.
    # AutoGeneratingColumn fires only once (on the first ItemsSource assignment above),
    # so new distinct values (e.g. "NeedsAssistance", "Unhealthy (2)") that appear in
    # later refreshes would never show in the dropdowns without this explicit rebuild.
    # $script:shDropdownCombos is populated by AutoGeneratingColumn - keyed by column name.
    if ($script:shDropdownCombos -and $script:shDropdownCombos.Count -gt 0) {
        foreach ($kv in $script:shDropdownCombos.GetEnumerator()) {
            $colName = $kv.Key
            $cb      = $kv.Value
            $current = $cb.SelectedItem   # preserve any active filter selection
            _SH_PopulateHeaderComboBox -ComboBox $cb -ColumnName $colName
            # Restore the previous selection if the value still exists in the new data.
            # If it has disappeared (e.g. the last "NeedsAssistance" host recovered),
            # fall back to 'All' so the filter doesn't silently hide all rows.
            if ($current -and $cb.Items.Contains($current)) {
                $cb.SelectedItem = $current
            } else {
                $cb.SelectedItem = 'All'
                $script:shDropdownSelections[$colName] = 'All'
            }
        }
    }

    # Re-apply the combined filter (dropdown + text) after the new DataTable is bound.
    _SH_ApplyFilters

    # Restore sort state: apply DataView.Sort and mark the column header arrow
    if ($script:shSortColumn) {
        $dir = if ($script:shSortDirection -eq [System.ComponentModel.ListSortDirection]::Descending) { 'DESC' } else { 'ASC' }
        $script:vmDataTable.DefaultView.Sort = "[$($script:shSortColumn)] $dir"
        foreach ($col in $script:SHGrid.Columns) {
            if ($col.SortMemberPath -eq $script:shSortColumn) {
                $col.SortDirection = $script:shSortDirection
                break
            }
        }
    }

    # Enable the Export CSV and Load Costs buttons now that data is loaded.
    $script:SHExportButton.IsEnabled = $true
    if ($script:SHLoadCostsButton) { $script:SHLoadCostsButton.IsEnabled = $true }

    # Build the summary string shown in the status bar.
    # "Available" is the AVD session host status (accepting connections), from the Status column.
    $onCount               = @($VmRows | Where-Object { $_.'Status' -eq 'Available' }).Count
    $script:vmCountText    = "$($VmRows.Count) VM(s)   Available: $onCount   Other: $($VmRows.Count - $onCount)"
    $script:vmLastRefreshTime = $Timestamp
}

# _SH_PopulateHeaderComboBox
# Populates a ComboBox with "All" plus sorted distinct values from the given
# DataTable column. Empty strings are displayed as "(blank)".
function _SH_PopulateHeaderComboBox {
    param(
        [System.Windows.Controls.ComboBox]$ComboBox,
        [string]$ColumnName
    )
    $ComboBox.Items.Clear()
    [void]$ComboBox.Items.Add('All')

    if (-not $script:vmDataTable -or $script:vmDataTable.Rows.Count -eq 0) { return }

    $values = [System.Collections.Generic.SortedSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($row in $script:vmDataTable.Rows) {
        $val = [string]$row[$ColumnName]
        if ([string]::IsNullOrEmpty($val)) {
            [void]$values.Add('(blank)')
        } else {
            [void]$values.Add($val)
        }
    }
    foreach ($v in $values) { [void]$ComboBox.Items.Add($v) }
}

# _SH_ApplyFilters
# Builds a combined DataView.RowFilter from all active per-column dropdown
# selections (AND) and the global text filter (OR across 4 columns).
# Also updates $script:vmFilteredCountText for the status bar.
function _SH_ApplyFilters {
    if (-not $script:vmDataTable) { return }

    $parts = [System.Collections.Generic.List[string]]::new()

    # ── Per-column dropdown filters (AND between columns) ──
    foreach ($col in $script:shFilterableColumns) {
        $val = $script:shDropdownSelections[$col]
        if (-not $val -or $val -eq 'All') { continue }
        if ($val -eq '(blank)') {
            $parts.Add("([$col] = '' OR [$col] IS NULL)")
        } else {
            $escaped = $val.Replace("'", "''")
            $parts.Add("[$col] = '$escaped'")
        }
    }

    # ── "Hide empty hosts" checkbox ──
    if ($script:SHHideEmptyCheckBox.IsChecked) {
        $parts.Add("[Sessions] > 0")
    }

    # ── Global text filter (OR across 4 columns) ──
    $text = $script:SHFilterBox.Text.Trim()
    if (-not [string]::IsNullOrEmpty($text)) {
        $escapedText = $text.Replace("'", "''")
        $parts.Add("(([VM Name] LIKE '%$escapedText%') OR ([Host Pool] LIKE '%$escapedText%') OR ([IP Address] LIKE '%$escapedText%') OR ([User] LIKE '%$escapedText%'))")
    }

    # ── Apply combined filter ──
    $script:vmDataTable.DefaultView.RowFilter = if ($parts.Count -gt 0) {
        $parts -join ' AND '
    } else { '' }

    # ── Update filtered count in the status bar ──
    if ($parts.Count -gt 0) {
        $view   = $script:vmDataTable.DefaultView
        $fTotal = $view.Count
        $fAvail = @($view | Where-Object { $_['Status'] -eq 'Available' }).Count
        $script:vmFilteredCountText = "$fTotal VM(s)   Available: $fAvail   Other: $($fTotal - $fAvail)"
    } else {
        $script:vmFilteredCountText = $null
    }

    _SH_UpdateTotals
}

# _SH_UpdateTotals
# Sums _ComputeCostSort and _DiskCostSort from the current DefaultView (respects
# active filter) and updates the totals bar. Called from _SH_ApplyFilters so totals
# always reflect visible rows, and from _SH_UpdateGrid after cost cache is reapplied.
function _SH_UpdateTotals {
    if (-not $script:vmDataTable -or -not $script:SHTotalsBar) { return }
    $totalCompute = 0.0; $totalDisk = 0.0; $totalTxn = 0.0; $hasCosts = $false
    foreach ($row in $script:vmDataTable.DefaultView) {
        $c = $row['_ComputeCostSort']; if ($c -gt 0) { $totalCompute += $c; $hasCosts = $true }
        $d = $row['_DiskCostSort'];    if ($d -gt 0) { $totalDisk    += $d; $hasCosts = $true }
        $t = $row['_TxnMoCostSort'];   if ($t -gt 0) { $totalTxn     += $t }
    }
    if ($hasCosts) {
        $script:SHTotalCompute.Text    = '{0:F2}' -f $totalCompute
        $script:SHTotalDisk.Text       = '{0:F2}' -f $totalDisk
        if ($script:SHTotalTxn) { $script:SHTotalTxn.Text = '{0:F2}' -f $totalTxn }
        $script:SHTotalsBar.Visibility = 'Visible'
    }
}
