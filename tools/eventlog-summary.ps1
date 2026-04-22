<#
.SYNOPSIS
    EventLog Summary - unified view of errors and warnings across all Windows Event Logs.

.DESCRIPTION
    Standalone WPF tool that queries all registered Windows Event Log channels and
    displays errors, warnings, and critical events in a single sortable, filterable
    grid. Designed to give admins a quick overview of what's going wrong on a machine.

    Features:
      - Scans ALL event log channels (Application, System, Security, all
        Microsoft-Windows-* operational logs, vendor logs, etc.)
      - Time-based filtering (15 minutes, 1 hour, 4 hours, 12 hours, 24 hours)
      - Level filter (Errors & Warnings, Errors Only, Warnings Only, All)
      - Log source dropdown to narrow to a specific event log channel
      - Text search across Source, Event ID, and Message
      - Colour-coded rows: red for errors/critical, amber for warnings
      - Detail pane shows full event message when a row is selected
      - Export filtered view to CSV
      - Auto-refresh toggle (every 30 seconds)
      - No Azure authentication required - reads local event logs only

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-03-24
    Requires      : PowerShell 5.1 or PowerShell 7 (Windows)

    DISCLAIMER:
    This script is provided as-is with no warranty, guarantee, or support of any kind.
    Use at your own risk. The author accepts no responsibility for any issues,
    data loss, or damages arising from the use of this script in any environment.
    Always test in a non-production environment before deploying.

    Version History:
    2026-03-24 - Initial release. Unified event log viewer across all channels,
            colour-coded levels, time/level/source/text filters, detail pane, CSV export.

#>

# =============================================================================
# Configurable variables
# =============================================================================

# Auto-refresh interval in seconds (used when "Auto Refresh" checkbox is enabled).
$AutoRefreshIntervalSeconds = 30

# =============================================================================
# Language mode check - WPF requires Full Language Mode
# =============================================================================
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    $msg = "This tool requires PowerShell Full Language Mode to run.`n`n" +
           "Current mode: $($ExecutionContext.SessionState.LanguageMode)`n`n" +
           "This machine has a security policy (AppLocker/WDAC) that restricts PowerShell.`n" +
           "Please run this tool as Administrator."
    $wsh = New-Object -ComObject WScript.Shell
    $wsh.Popup($msg, 0, 'AVD Dashboard - Language Mode Restriction', 48) | Out-Null
    return
}

# =============================================================================
# WPF assemblies
# =============================================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Set a unique AppUserModelID so the tool appears as its own taskbar entry
try {
    $null = Add-Type -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@ -Name 'Shell32Evt' -Namespace 'Win32Evt' -PassThru -ErrorAction Stop
    [Win32Evt.Shell32Evt]::SetCurrentProcessExplicitAppUserModelID('AVDEventLogSummary') | Out-Null
} catch { <# non-critical - type may already exist #> }

# =============================================================================
# XAML - Window definition
# =============================================================================
# Resolve icon path - $PSScriptRoot may be empty if script is pasted into a console
$_scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$_icoXaml = Join-Path $_scriptDir '..\data\avd-dashboard.ico'
# Use .ProviderPath for UNC-safe resolution (avoids FileSystem:: prefix)
$_icoAttr = if ($_icoXaml -and (Test-Path $_icoXaml -ErrorAction SilentlyContinue)) { " Icon=`"$((Resolve-Path $_icoXaml).ProviderPath)`"" } else { '' }
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="EventLog Summary - $($env:COMPUTERNAME)"
        Height="720" Width="1200"
        MinHeight="500" MinWidth="800"
        WindowStartupLocation="CenterScreen"$_icoAttr
        Background="#F4F6F9"
        FontFamily="Segoe UI"
        UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">
    <Window.Resources>
        <!-- Primary button style -->
        <Style x:Key="PrimaryBtn" TargetType="Button">
            <Setter Property="Background" Value="#0078D4"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="18,8"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#005A9E"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#003D6B"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Background" Value="#AAC8E8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Export button style (green) -->
        <Style x:Key="ExportBtn" TargetType="Button">
            <Setter Property="Background" Value="#107C10"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#0B5E0B"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#084508"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- DataGrid column header style -->
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#0078D4"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="10,0"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="BorderBrush" Value="#005A9E"/>
            <Setter Property="BorderThickness" Value="0,0,1,0"/>
            <Setter Property="Height" Value="34"/>
        </Style>
        <!-- DataGrid cell style -->
        <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#1F2937"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#CCE4F7"/>
                    <Setter Property="Foreground" Value="#1F2937"/>
                    <Setter Property="BorderBrush" Value="Transparent"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- DataGrid row style -->
        <Style TargetType="DataGridRow">
            <Setter Property="Height" Value="28"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#EEF4FC"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#D0E7FA"/>
                    <Setter Property="Foreground" Value="#1F2937"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <DockPanel>
        <!-- Status bar -->
        <Border DockPanel.Dock="Bottom" Background="#0078D4" Height="32">
            <Grid Margin="14,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusText" Text="Ready" Foreground="White"
                           FontSize="12" VerticalAlignment="Center"/>
                <Button x:Name="ExportBtn" Grid.Column="1" Content="Export CSV"
                        Style="{StaticResource ExportBtn}" Margin="0,0,8,0"
                        VerticalAlignment="Center"/>
                <Button x:Name="RefreshBtn" Grid.Column="2" Content="Refresh"
                        Background="#005A9E" Foreground="White" BorderThickness="0"
                        Padding="14,5" FontSize="12" FontWeight="SemiBold" Cursor="Hand"
                        VerticalAlignment="Center">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdRefresh" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdRefresh" Property="Background" Value="#004F8C"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdRefresh" Property="Background" Value="#003D6B"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>
        </Border>

        <!-- Top filter bar -->
        <Border DockPanel.Dock="Top" Background="White" Padding="16,12">
            <Border.Effect>
                <DropShadowEffect BlurRadius="6" ShadowDepth="1" Opacity="0.10" Color="#000000"/>
            </Border.Effect>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="Computer:" FontSize="12" FontWeight="SemiBold" Foreground="#1F2937"
                           VerticalAlignment="Center" Margin="0,0,6,0"/>
                <TextBox x:Name="ComputerBox" Width="150" FontSize="12" Padding="6,4"
                         BorderBrush="#C8CDD3" BorderThickness="1" VerticalContentAlignment="Center"
                         Margin="0,0,16,0" ToolTip="Leave blank for local machine. Enter hostname or IP for remote."/>

                <TextBlock Text="Time:" FontSize="12" FontWeight="SemiBold" Foreground="#1F2937"
                           VerticalAlignment="Center" Margin="0,0,6,0"/>
                <ComboBox x:Name="TimeRangeCombo" Width="120" FontSize="12" SelectedIndex="0" Margin="0,0,16,0">
                    <ComboBoxItem Content="Last 15 Minutes" Tag="15"/>
                    <ComboBoxItem Content="Last 1 Hour"     Tag="60"/>
                    <ComboBoxItem Content="Last 4 Hours"    Tag="240"/>
                    <ComboBoxItem Content="Last 12 Hours"   Tag="720"/>
                    <ComboBoxItem Content="Last 24 Hours"   Tag="1440"/>
                </ComboBox>

                <TextBlock Text="Level:" FontSize="12" FontWeight="SemiBold" Foreground="#1F2937"
                           VerticalAlignment="Center" Margin="0,0,6,0"/>
                <ComboBox x:Name="LevelCombo" Width="150" FontSize="12" SelectedIndex="0" Margin="0,0,16,0">
                    <ComboBoxItem Content="Errors &amp; Warnings" Tag="EW"/>
                    <ComboBoxItem Content="Errors Only"        Tag="E"/>
                    <ComboBoxItem Content="Warnings Only"      Tag="W"/>
                    <ComboBoxItem Content="All Levels"         Tag="A"/>
                </ComboBox>

                <TextBlock Text="Log:" FontSize="12" FontWeight="SemiBold" Foreground="#1F2937"
                           VerticalAlignment="Center" Margin="0,0,6,0"/>
                <ComboBox x:Name="LogSourceCombo" Width="250" FontSize="12" Margin="0,0,16,0">
                    <ComboBoxItem Content="All Logs" Tag="ALL" IsSelected="True"/>
                </ComboBox>

                <TextBlock Text="Search:" FontSize="12" FontWeight="SemiBold" Foreground="#1F2937"
                           VerticalAlignment="Center" Margin="0,0,6,0"/>
                <TextBox x:Name="SearchBox" Width="200" FontSize="12" Padding="6,4"
                         BorderBrush="#C8CDD3" BorderThickness="1" VerticalContentAlignment="Center"
                         Margin="0,0,16,0"/>

                <CheckBox x:Name="AutoRefreshCheck" Content="Auto Refresh" FontSize="12"
                          VerticalAlignment="Center" Margin="0,0,0,0"/>
            </StackPanel>
        </Border>

        <!-- Main content: grid + detail pane -->
        <Grid Margin="16,10,16,0">
            <Grid.RowDefinitions>
                <RowDefinition Height="3*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="1*" MinHeight="80"/>
            </Grid.RowDefinitions>

            <!-- Loading overlay - shown while scanning event logs -->
            <Border x:Name="LoadingOverlay" Grid.Row="0" Grid.RowSpan="3"
                    Background="#CC000000" Visibility="Collapsed" Panel.ZIndex="10">
                <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                    <TextBlock Text="Scanning event logs..." FontSize="18" FontWeight="SemiBold"
                               Foreground="White" HorizontalAlignment="Center" Margin="0,0,0,8"/>
                    <TextBlock Text="This may take a few seconds" FontSize="12"
                               Foreground="#AAA" HorizontalAlignment="Center"/>
                </StackPanel>
            </Border>

            <!-- Event grid -->
            <DataGrid x:Name="EventGrid" Grid.Row="0"
                      AutoGenerateColumns="False" IsReadOnly="True"
                      CanUserReorderColumns="False" CanUserAddRows="False"
                      SelectionMode="Single" SelectionUnit="FullRow"
                      GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#E5E7EB"
                      VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                      BorderBrush="#DDE1E7" BorderThickness="1"
                      Background="White" RowBackground="White" AlternatingRowBackground="#F9FAFB">
                <DataGrid.Columns>
                    <DataGridTextColumn Header="Time"     Binding="{Binding Time, StringFormat='{}{0:yyyy-MM-dd HH:mm:ss}'}" Width="155"/>
                    <DataGridTextColumn Header="Level"    Binding="{Binding Level}" Width="80"/>
                    <DataGridTextColumn Header="Source"   Binding="{Binding Source}" Width="200"/>
                    <DataGridTextColumn Header="Event ID" Binding="{Binding EventID}" Width="70"/>
                    <DataGridTextColumn Header="Log"      Binding="{Binding Log}" Width="200"/>
                    <DataGridTextColumn Header="Message"  Binding="{Binding MessageShort}" Width="*"/>
                </DataGrid.Columns>
            </DataGrid>

            <!-- Splitter -->
            <GridSplitter Grid.Row="1" Height="5" HorizontalAlignment="Stretch"
                          Background="#DDE1E7" ResizeBehavior="PreviousAndNext"/>

            <!-- Detail pane -->
            <Border Grid.Row="2" Background="#1E2A38" BorderBrush="#DDE1E7" BorderThickness="1"
                    CornerRadius="0,0,4,4">
                <RichTextBox x:Name="DetailBox" IsReadOnly="True" Background="#1E2A38"
                             Foreground="#A8C4DE" FontFamily="Consolas" FontSize="12"
                             BorderThickness="0" VerticalScrollBarVisibility="Auto"
                             Padding="10,8">
                    <FlowDocument>
                        <Paragraph>
                            <Run Text="Select an event to view details" Foreground="#5C7A94"/>
                        </Paragraph>
                    </FlowDocument>
                </RichTextBox>
            </Border>
        </Grid>
    </DockPanel>
</Window>
"@

# =============================================================================
# Load XAML and get named elements
# =============================================================================
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$computerBox      = $window.FindName('ComputerBox')
$timeRangeCombo   = $window.FindName('TimeRangeCombo')
$levelCombo       = $window.FindName('LevelCombo')
$logSourceCombo   = $window.FindName('LogSourceCombo')
$searchBox        = $window.FindName('SearchBox')
$autoRefreshCheck = $window.FindName('AutoRefreshCheck')
$eventGrid        = $window.FindName('EventGrid')
$detailBox        = $window.FindName('DetailBox')
$statusText       = $window.FindName('StatusText')
$refreshBtn       = $window.FindName('RefreshBtn')
$exportBtn        = $window.FindName('ExportBtn')
$loadingOverlay   = $window.FindName('LoadingOverlay')

# Store all events and the filtered subset for search/export
$script:allEvents      = @()
$script:filteredEvents = @()
$script:knownLogs      = @()

# =============================================================================
# Core functions
# =============================================================================

function Invoke-LoadEvents {
    <#
    .SYNOPSIS
        Queries all event log channels for errors/warnings within the selected time range.
    #>
    # Determine target computer (blank = local)
    $targetComputer = $computerBox.Text.Trim()
    $targetName = if ($targetComputer) { $targetComputer } else { $env:COMPUTERNAME }
    $window.Title = "EventLog Summary - $targetName"

    # Show loading overlay and force a UI render so it's visible during the blocking query
    $loadingOverlay.Visibility = [System.Windows.Visibility]::Visible
    $statusText.Text = "Scanning event logs on $targetName..."
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    # Time range from combo box
    $minutesTag = [int]$timeRangeCombo.SelectedItem.Tag
    $cutoff = (Get-Date).AddMinutes(-$minutesTag)

    # Level filter
    $levelTag = [string]$levelCombo.SelectedItem.Tag
    $levels = switch ($levelTag) {
        'E'  { @(1, 2) }        # Critical + Error
        'W'  { @(3) }           # Warning only
        'EW' { @(1, 2, 3) }    # Critical + Error + Warning
        'A'  { @(1, 2, 3, 4) } # All including Information
        default { @(1, 2, 3) }
    }

    # Build common parameters for Get-WinEvent (add -ComputerName for remote)
    $commonParams = @{ ErrorAction = 'SilentlyContinue' }
    if ($targetComputer) { $commonParams['ComputerName'] = $targetComputer }

    # Discover all log channels with records, then query them all in one call.
    # Using a single Get-WinEvent with all log names is much faster than looping
    # through each channel individually.
    $allLogNames = @(Get-WinEvent -ListLog * @commonParams |
        Where-Object { $_.RecordCount -gt 0 } |
        ForEach-Object { $_.LogName })

    $events = [System.Collections.Generic.List[PSObject]]::new()

    # Query all logs at once - FilterHashtable accepts an array of LogNames
    # Process in batches of 50 to avoid overly large queries
    $batchSize = 50
    for ($b = 0; $b -lt $allLogNames.Count; $b += $batchSize) {
        $batch = @($allLogNames[$b..([Math]::Min($b + $batchSize - 1, $allLogNames.Count - 1))])
        try {
            $evts = @(Get-WinEvent -FilterHashtable @{
                LogName   = $batch
                Level     = $levels
                StartTime = $cutoff
            } @commonParams)

            foreach ($e in $evts) {
                $levelName = switch ([int]$e.Level) {
                    1 { 'Critical' }
                    2 { 'Error' }
                    3 { 'Warning' }
                    4 { 'Information' }
                    default { "Level $($e.Level)" }
                }
                # Truncate message to first line for grid display
                $msg = if ($e.Message) { $e.Message } else { '(no message)' }
                $firstLine = ($msg -split "`n")[0].Trim()
                if ($firstLine.Length -gt 300) { $firstLine = $firstLine.Substring(0, 300) + '...' }

                $events.Add([PSCustomObject]@{
                    Time         = $e.TimeCreated
                    Level        = $levelName
                    LevelInt     = [int]$e.Level
                    Source       = $e.ProviderName
                    EventID      = $e.Id
                    Log          = $e.LogName
                    MessageShort = $firstLine
                    MessageFull  = $msg
                })
            }
        } catch {
            # Skip batches with inaccessible logs (e.g. Security without admin rights)
        }
    }

    # Sort by time descending (newest first)
    $script:allEvents = @($events | Sort-Object Time -Descending)

    # Update the Log Source dropdown with discovered log names
    $logNames = @($script:allEvents | ForEach-Object { $_.Log } | Sort-Object -Unique)
    if ($script:knownLogs -join ',' -ne ($logNames -join ',')) {
        $script:knownLogs = $logNames
        $currentSel = [string]$logSourceCombo.SelectedItem.Tag
        $logSourceCombo.Items.Clear()
        $allItem = New-Object System.Windows.Controls.ComboBoxItem
        $allItem.Content = "All Logs ($($logNames.Count) channels)"
        $allItem.Tag = 'ALL'
        [void]$logSourceCombo.Items.Add($allItem)
        foreach ($ln in $logNames) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $ln
            $item.Tag = $ln
            [void]$logSourceCombo.Items.Add($item)
        }
        # Restore selection
        $found = $false
        for ($i = 0; $i -lt $logSourceCombo.Items.Count; $i++) {
            if ([string]$logSourceCombo.Items[$i].Tag -eq $currentSel) {
                $logSourceCombo.SelectedIndex = $i
                $found = $true
                break
            }
        }
        if (-not $found) { $logSourceCombo.SelectedIndex = 0 }
    }

    # Apply filters and update grid
    Invoke-ApplyFilters

    # Hide loading overlay
    $loadingOverlay.Visibility = [System.Windows.Visibility]::Collapsed
}


function Invoke-ApplyFilters {
    <#
    .SYNOPSIS
        Applies log source and text search filters to the loaded events and updates the grid.
    #>
    $filtered = $script:allEvents

    # Log source filter
    $logTag = [string]$logSourceCombo.SelectedItem.Tag
    if ($logTag -and $logTag -ne 'ALL') {
        $filtered = @($filtered | Where-Object { $_.Log -eq $logTag })
    }

    # Text search filter (matches Source, Event ID, or Message)
    $searchText = $searchBox.Text.Trim()
    if ($searchText) {
        $filtered = @($filtered | Where-Object {
            $_.Source       -like "*$searchText*" -or
            "$($_.EventID)" -like "*$searchText*" -or
            $_.MessageShort -like "*$searchText*" -or
            $_.Log          -like "*$searchText*"
        })
    }

    $script:filteredEvents = $filtered
    $eventGrid.ItemsSource = $filtered

    # Update status
    $totalCount = $script:allEvents.Count
    $shownCount = $filtered.Count
    $errorCount = @($filtered | Where-Object { $_.LevelInt -le 2 }).Count
    $warnCount  = @($filtered | Where-Object { $_.LevelInt -eq 3 }).Count
    $statusText.Text = "$shownCount of $totalCount events shown ($errorCount errors, $warnCount warnings) - Last refreshed: $(Get-Date -Format 'HH:mm:ss')"
}


# =============================================================================
# Event handlers
# =============================================================================

# Colour-code rows based on event level
$eventGrid.Add_LoadingRow({
    param($s, $e)
    $item = $e.Row.Item
    if ($null -eq $item) { return }
    $level = $item.LevelInt
    if ($level -le 2) {
        # Critical or Error - red tint
        $e.Row.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FDE8E8')
        $e.Row.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#991B1B')
    } elseif ($level -eq 3) {
        # Warning - amber tint
        $e.Row.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FEF3CD')
        $e.Row.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#856404')
    }
}.GetNewClosure())

# Show full message in detail pane when row selected
$eventGrid.Add_SelectionChanged({
    $sel = $eventGrid.SelectedItem
    if ($null -eq $sel) { return }

    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.PagePadding = [System.Windows.Thickness]::new(0)
    $brushConv = [System.Windows.Media.BrushConverter]::new()

    # Header line: Level - Source - Event ID - Log
    $headerPara = New-Object System.Windows.Documents.Paragraph
    $headerPara.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $levelColor = switch ([int]$sel.LevelInt) {
        1 { '#FF6B6B' }
        2 { '#FF6B6B' }
        3 { '#FFB347' }
        default { '#A8C4DE' }
    }
    $levelRun = New-Object System.Windows.Documents.Run("[$($sel.Level)]")
    $levelRun.Foreground = $brushConv.ConvertFromString($levelColor)
    $levelRun.FontWeight = [System.Windows.FontWeights]::Bold
    [void]$headerPara.Inlines.Add($levelRun)

    $infoRun = New-Object System.Windows.Documents.Run("  Source: $($sel.Source)  |  Event ID: $($sel.EventID)  |  Log: $($sel.Log)  |  Time: $($sel.Time.ToString('yyyy-MM-dd HH:mm:ss'))")
    $infoRun.Foreground = $brushConv.ConvertFromString('#5C7A94')
    [void]$headerPara.Inlines.Add($infoRun)
    [void]$doc.Blocks.Add($headerPara)

    # Separator
    $sepPara = New-Object System.Windows.Documents.Paragraph
    $sepPara.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $sepRun = New-Object System.Windows.Documents.Run(([string]::new([char]0x2500, 80)))
    $sepRun.Foreground = $brushConv.ConvertFromString('#3B5A7A')
    [void]$sepPara.Inlines.Add($sepRun)
    [void]$doc.Blocks.Add($sepPara)

    # Full message
    $msgLines = $sel.MessageFull -split "`n"
    foreach ($line in $msgLines) {
        $para = New-Object System.Windows.Documents.Paragraph
        $para.Margin = [System.Windows.Thickness]::new(0)
        $run = New-Object System.Windows.Documents.Run($line.TrimEnd())
        $run.Foreground = $brushConv.ConvertFromString('#A8C4DE')
        [void]$para.Inlines.Add($run)
        [void]$doc.Blocks.Add($para)
    }

    $detailBox.Document = $doc
}.GetNewClosure())

# Filter changes trigger re-filter (not re-query for search/log source)
$logSourceCombo.Add_SelectionChanged({
    if ($script:allEvents.Count -gt 0) { Invoke-ApplyFilters }
}.GetNewClosure())

$searchBox.Add_TextChanged({
    if ($script:allEvents.Count -gt 0) { Invoke-ApplyFilters }
}.GetNewClosure())

# Time range and level changes trigger full re-query
$timeRangeCombo.Add_SelectionChanged({
    Invoke-LoadEvents
}.GetNewClosure())

$levelCombo.Add_SelectionChanged({
    Invoke-LoadEvents
}.GetNewClosure())

# Refresh button
# Enter key in computer box triggers refresh
$computerBox.Add_KeyDown({
    if ($_.Key -eq 'Return') { Invoke-LoadEvents }
}.GetNewClosure())

$refreshBtn.Add_Click({
    Invoke-LoadEvents
}.GetNewClosure())

# Export CSV
$exportBtn.Add_Click({
    $saveDlg = New-Object Microsoft.Win32.SaveFileDialog
    $saveDlg.Title = 'Export Events to CSV'
    $saveDlg.Filter = 'CSV files (*.csv)|*.csv'
    $saveDlg.FileName = "eventlog-summary-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    if ($saveDlg.ShowDialog()) {
        try {
            $script:filteredEvents |
                Select-Object Time, Level, Source, EventID, Log, @{N='Message';E={$_.MessageFull}} |
                Export-Csv -Path $saveDlg.FileName -NoTypeInformation -Encoding UTF8
            $statusText.Text = "Exported $($script:filteredEvents.Count) events to $($saveDlg.FileName)"
        } catch {
            $statusText.Text = "Export failed: $_"
        }
    }
}.GetNewClosure())

# Auto-refresh timer
$script:autoRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:autoRefreshTimer.Interval = [TimeSpan]::FromSeconds($AutoRefreshIntervalSeconds)
$script:autoRefreshTimer.Add_Tick({
    Invoke-LoadEvents
}.GetNewClosure())

$autoRefreshCheck.Add_Checked({
    $script:autoRefreshTimer.Start()
    $statusText.Text = "Auto-refresh enabled (every ${AutoRefreshIntervalSeconds}s)"
}.GetNewClosure())

$autoRefreshCheck.Add_Unchecked({
    $script:autoRefreshTimer.Stop()
}.GetNewClosure())

# =============================================================================
# Initial load and show window
# =============================================================================
$window.Add_Loaded({
    Invoke-LoadEvents
}.GetNewClosure())

$window.ShowDialog() | Out-Null
