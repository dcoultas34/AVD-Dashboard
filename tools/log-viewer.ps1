<#
.SYNOPSIS
    Log Viewer - browse and view log files from a file share with error highlighting.

.DESCRIPTION
    Standalone WPF tool for viewing log files on a file share or local path.
    Features:
      - Browse log files from UNC or local paths with configurable default path
      - Time-based filtering (15 minutes, 1 hour, 24 hours, all)
      - File name filter for real-time narrowing of file list
      - Error-only filter to show files containing error markers
      - Log content viewer with error lines highlighted in red
      - Live tail mode - auto-polls for new lines every 2 seconds
      - Delete old logs - bulk-remove files older than 7 days
      - Configurable file extensions and error markers
      - No Azure authentication required - pure file system access

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-03-16
    Requires      : PowerShell 5.1 or PowerShell 7 (Windows)

    DISCLAIMER:
    This script is provided as-is with no warranty, guarantee, or support of any kind.
    Use at your own risk. The author accepts no responsibility for any issues,
    data loss, or damages arising from the use of this script in any environment.
    Always test in a non-production environment before deploying.

    Version History:
    2026-03-16 - Initial release. File browsing, error highlighting, tail mode,
            file name filter, delete old logs, configurable extensions.

#>

# =============================================================================
# Configurable variables
# =============================================================================

# Patterns that indicate an error line in log files.
# Used by both the "Errors Only" file filter and the log content highlighter.
$ErrorMarkers = @('[ERROR]', '[FATAL]', '[CRITICAL]')

# File extensions to include when scanning a folder.
$LogExtensions = @('*.log', '*.txt', '*.csv', '*.etl')

# Default log path - set this to pre-populate the path field on launch.
# Leave empty to start with a blank path.
$DefaultLogPath = '\\cukavdukwprod01.file.core.windows.net\profiles\logs'

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

# Set a unique AppUserModelID so the log viewer appears as its own taskbar entry
# (separate from the PowerShell group) and shows the custom window icon.
try {
    $null = Add-Type -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@ -Name 'Shell32' -Namespace 'Win32' -PassThru -ErrorAction Stop
    [Win32.Shell32]::SetCurrentProcessExplicitAppUserModelID('AVDLogViewer') | Out-Null
} catch { <# non-critical #> }

# =============================================================================
# XAML - Window definition
# =============================================================================
# Resolve icon path - $PSScriptRoot may be empty if script is pasted into a console
$_scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$_icoXaml = Join-Path $_scriptDir '..\data\avd-dashboard.ico'
# Use .ProviderPath for UNC-safe resolution (avoids FileSystem:: prefix)
$_icoAttr = if (Test-Path $_icoXaml) { " Icon=`"$((Resolve-Path $_icoXaml).ProviderPath)`"" } else { '' }
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Log Viewer"
        Height="680" Width="1056"
        MinHeight="500" MinWidth="750"
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
        <!-- Danger button style (red) -->
        <Style x:Key="DangerBtn" TargetType="Button">
            <Setter Property="Background" Value="#C42B1C"/>
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
                                <Setter Property="Background" Value="#A21B0E"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#7A1409"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Background" Value="#D4A0A0"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Secondary button style -->
        <Style x:Key="SecondaryBtn" TargetType="Button">
            <Setter Property="Background" Value="#6B737C"/>
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
                                <Setter Property="Background" Value="#4F565D"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#3A4046"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- DataGrid column header style - centered text, blue background -->
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
            <Setter Property="Height" Value="32"/>
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
        <!-- Status bar with Refresh button on far right -->
        <Border DockPanel.Dock="Bottom" Background="#0078D4" Height="32">
            <Grid Margin="14,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusText" Text="Ready" Foreground="White"
                           FontSize="12" VerticalAlignment="Center"/>
                <Button x:Name="RefreshBtn" Grid.Column="1" Content="Refresh Now"
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
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Row 0: Path + Browse -->
                <Grid Grid.Row="0" Margin="0,0,0,10">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Log Path:" FontSize="13" FontWeight="SemiBold"
                               Foreground="#1F2937" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <TextBox x:Name="PathBox" Grid.Column="1" FontSize="12" Padding="8,6"
                             BorderBrush="#C8CDD3" BorderThickness="1" VerticalContentAlignment="Center"/>
                    <Button x:Name="BrowseBtn" Grid.Column="2" Content="Browse..."
                            Style="{StaticResource SecondaryBtn}" Margin="8,0,0,0"/>
                </Grid>

                <!-- Row 1: Filters + Refresh -->
                <StackPanel Grid.Row="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="Time Range:" FontSize="12" Foreground="#6B7280"
                               VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <ComboBox x:Name="TimeRangeCombo" Width="160" FontSize="12" SelectedIndex="1">
                        <ComboBoxItem Content="Last 15 Minutes" Tag="15"/>
                        <ComboBoxItem Content="Last Hour"       Tag="60"/>
                        <ComboBoxItem Content="Last 24 Hours"   Tag="1440"/>
                        <ComboBoxItem Content="All Files"       Tag="0"/>
                    </ComboBox>
                    <TextBlock Text="Filter:" FontSize="12" Foreground="#555"
                               VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBox x:Name="FileFilterBox" Width="160" FontSize="12"
                             Padding="8,4" VerticalContentAlignment="Center"
                             BorderBrush="#C8CDD3" BorderThickness="1"
                             Background="White" Foreground="#333"/>
                    <Button x:Name="DeleteOldBtn" Content="Delete Logs &gt; 7 Days"
                            Style="{StaticResource DangerBtn}" Margin="20,0,0,0"/>
                    <CheckBox x:Name="TailToggle" Content="Tail" IsEnabled="False"
                              FontSize="12" Foreground="#1F2937" VerticalAlignment="Center"
                              Margin="20,0,0,0"
                              ToolTip="Auto-tail the selected log file (polls every 2s)"/>
                    <CheckBox x:Name="ErrorsOnlyCheck" Content="Errors Only"
                              FontSize="12" Foreground="#1F2937" VerticalAlignment="Center"
                              Margin="16,0,0,0"/>
                    <CheckBox x:Name="AutoRefreshCheck" Content="Auto Refresh"
                              FontSize="12" Foreground="#1F2937" VerticalAlignment="Center"
                              Margin="16,0,0,0"
                              ToolTip="Automatically refresh the file list every 30 seconds"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Main content: file list (left) + log viewer (right) -->
        <Grid Margin="12,12,12,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="400" MinWidth="250"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*" MinWidth="300"/>
            </Grid.ColumnDefinitions>

            <!-- Left: File list -->
            <Border Grid.Column="0" Background="White" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="6">
                <Border.Effect>
                    <DropShadowEffect BlurRadius="8" ShadowDepth="1" Opacity="0.08" Color="#000000"/>
                </Border.Effect>
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Text="Log Files" FontSize="13" FontWeight="SemiBold"
                               Foreground="#1F2937" Margin="12,10,12,8"/>
                    <DataGrid x:Name="FileGrid"
                              AutoGenerateColumns="False"
                              IsReadOnly="True"
                              CanUserSortColumns="True"
                              SelectionMode="Single"
                              HeadersVisibility="Column"
                              GridLinesVisibility="Horizontal"
                              HorizontalGridLinesBrush="#E8EAED"
                              BorderThickness="0"
                              Background="White"
                              RowBackground="White"
                              AlternatingRowBackground="#F7F9FC"
                              FontSize="12"
                              HorizontalScrollBarVisibility="Auto"
                              VerticalScrollBarVisibility="Auto">
                        <DataGrid.Columns>
                            <!-- File Name - left aligned, takes remaining space -->
                            <DataGridTextColumn Header="File Name" Binding="{Binding Name}" Width="*"/>
                            <!-- Modified - centered, auto-size to fit content -->
                            <DataGridTextColumn Header="Modified" Binding="{Binding Modified}" Width="Auto">
                                <DataGridTextColumn.ElementStyle>
                                    <Style TargetType="TextBlock">
                                        <Setter Property="HorizontalAlignment" Value="Center"/>
                                        <Setter Property="Padding" Value="8,0"/>
                                    </Style>
                                </DataGridTextColumn.ElementStyle>
                            </DataGridTextColumn>
                            <!-- Size - centered, auto-size to fit content -->
                            <DataGridTextColumn Header="Size" Binding="{Binding Size}" Width="Auto">
                                <DataGridTextColumn.ElementStyle>
                                    <Style TargetType="TextBlock">
                                        <Setter Property="HorizontalAlignment" Value="Center"/>
                                    </Style>
                                </DataGridTextColumn.ElementStyle>
                            </DataGridTextColumn>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </Border>

            <!-- Splitter -->
            <GridSplitter Grid.Column="1" Width="6" Background="Transparent"
                          HorizontalAlignment="Center" VerticalAlignment="Stretch"
                          ResizeBehavior="PreviousAndNext" Cursor="SizeWE"/>

            <!-- Right: Log content viewer -->
            <Border Grid.Column="2" Background="#1E2A38" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="6">
                <Border.Effect>
                    <DropShadowEffect BlurRadius="8" ShadowDepth="1" Opacity="0.08" Color="#000000"/>
                </Border.Effect>
                <DockPanel>
                    <Border DockPanel.Dock="Top" Background="#263545" Padding="12,8" CornerRadius="6,6,0,0">
                        <TextBlock x:Name="LogTitle" Text="Select a file to view" FontSize="12"
                                   FontWeight="SemiBold" Foreground="#A8C4DE"/>
                    </Border>
                    <RichTextBox x:Name="LogViewer"
                                 Background="#1E2A38"
                                 Foreground="#A8C4DE"
                                 FontFamily="Consolas"
                                 FontSize="11"
                                 IsReadOnly="True"
                                 BorderThickness="0"
                                 VerticalScrollBarVisibility="Auto"
                                 HorizontalScrollBarVisibility="Auto"
                                 Padding="10,6">
                        <RichTextBox.Document>
                            <FlowDocument PageWidth="5000"/>
                        </RichTextBox.Document>
                    </RichTextBox>
                </DockPanel>
            </Border>
        </Grid>
    </DockPanel>
</Window>
"@

# =============================================================================
# Load window
# =============================================================================
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Get named elements
$pathBox         = $window.FindName('PathBox')
$browseBtn       = $window.FindName('BrowseBtn')
$timeRangeCombo  = $window.FindName('TimeRangeCombo')
$errorsOnlyCheck = $window.FindName('ErrorsOnlyCheck')
$refreshBtn      = $window.FindName('RefreshBtn')
$deleteOldBtn    = $window.FindName('DeleteOldBtn')
$fileFilterBox   = $window.FindName('FileFilterBox')
$fileGrid        = $window.FindName('FileGrid')
$logViewer       = $window.FindName('LogViewer')
$logTitle        = $window.FindName('LogTitle')
$tailToggle      = $window.FindName('TailToggle')
$autoRefreshCheck = $window.FindName('AutoRefreshCheck')
$statusText      = $window.FindName('StatusText')

# Set default path
if ($DefaultLogPath) { $pathBox.Text = $DefaultLogPath }

# =============================================================================
# Helper: format file size
# =============================================================================
function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -lt 1KB) { return "${Bytes} B" }
    if ($Bytes -lt 1MB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    if ($Bytes -lt 1GB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N1} GB' -f ($Bytes / 1GB)
}

# =============================================================================
# Helper: check if a file contains any error marker
# =============================================================================
function Test-FileHasErrors {
    param([string]$FilePath)
    # Build a regex pattern from error markers (escape special chars)
    $escapedMarkers = $ErrorMarkers | ForEach-Object { [regex]::Escape($_) }
    $pattern = $escapedMarkers -join '|'
    try {
        $match = Select-String -Path $FilePath -Pattern $pattern -Quiet -ErrorAction Stop
        return [bool]$match
    } catch {
        return $false
    }
}

# =============================================================================
# Core: scan files and populate the grid
# =============================================================================
function Invoke-RefreshFileList {
    $logPath = $pathBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($logPath)) {
        $statusText.Text = 'Enter a log path and click Refresh.'
        $fileGrid.ItemsSource = $null
        return
    }
    if (-not (Test-Path -LiteralPath $logPath -PathType Container)) {
        $statusText.Text = "Path not found: $logPath"
        $fileGrid.ItemsSource = $null
        return
    }

    $statusText.Text = 'Scanning files...'
    $window.Dispatcher.Invoke([action]{}, 'Render')

    # Get time filter
    $minutesTag = [int]$timeRangeCombo.SelectedItem.Tag
    $cutoff = if ($minutesTag -gt 0) { (Get-Date).AddMinutes(-$minutesTag) } else { [datetime]::MinValue }

    # Collect files matching extensions
    $allFiles = @()
    foreach ($ext in $LogExtensions) {
        $allFiles += @(Get-ChildItem -LiteralPath $logPath -Filter $ext -File -ErrorAction SilentlyContinue)
    }

    # Filter by time
    if ($minutesTag -gt 0) {
        $allFiles = @($allFiles | Where-Object { $_.LastWriteTime -ge $cutoff })
    }

    # Filter by errors if checked
    $errorsOnly = $errorsOnlyCheck.IsChecked
    if ($errorsOnly) {
        $statusText.Text = "Scanning $($allFiles.Count) file(s) for errors..."
        $window.Dispatcher.Invoke([action]{}, 'Render')
        $allFiles = @($allFiles | Where-Object { Test-FileHasErrors $_.FullName })
    }

    # Sort by last modified descending
    $allFiles = @($allFiles | Sort-Object LastWriteTime -Descending)

    # Build display objects
    $items = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($f in $allFiles) {
        $items.Add([PSCustomObject]@{
            Name     = $f.Name
            Modified = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            Size     = Format-FileSize $f.Length
            FullPath = $f.FullName
        })
    }

    # Apply file name filter if set
    $filterText = $fileFilterBox.Text.Trim()
    if ($filterText -ne '') {
        $items = [System.Collections.Generic.List[PSObject]]@($items | Where-Object { $_.Name -like "*$filterText*" })
        $fileGrid.ItemsSource = $items
        $statusText.Text = "$($items.Count) file(s) matching '$filterText'"
    } else {
        $fileGrid.ItemsSource = $items
        $statusText.Text = "$($items.Count) file(s) found"
    }
}

# =============================================================================
# Core: load and display a log file with error highlighting
# =============================================================================
function Show-LogContent {
    param([string]$FilePath)

    $logTitle.Text = [System.IO.Path]::GetFileName($FilePath)
    $statusText.Text = "Loading $($logTitle.Text)..."
    $window.Dispatcher.Invoke([action]{}, 'Render')

    # Build regex for error markers
    $escapedMarkers = $ErrorMarkers | ForEach-Object { [regex]::Escape($_) }
    $errorPattern = $escapedMarkers -join '|'

    # Read file content (FileShare.ReadWrite allows reading files still being written to)
    try {
        $fs = [System.IO.FileStream]::new($FilePath, 'Open', 'Read', [System.IO.FileShare]::ReadWrite)
        $sr = [System.IO.StreamReader]::new($fs)
        $lines = @()
        while ($null -ne ($l = $sr.ReadLine())) { $lines += $l }
        $sr.Close()
        $fs.Close()
    } catch {
        $logTitle.Text = "Error reading file"
        $statusText.Text = "Failed to read: $_"
        return
    }

    # Build FlowDocument with coloured lines
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.PageWidth = 5000
    $doc.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $doc.FontSize   = 11

    $normalBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#A8C4DE')
    $errorBrush  = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF6B6B')
    $errorBgBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#3D1F1F')

    $lineNum = 0
    $errorCount = 0

    foreach ($line in $lines) {
        $lineNum++
        $para = New-Object System.Windows.Documents.Paragraph
        $para.Margin = [System.Windows.Thickness]::new(0)
        $para.Padding = [System.Windows.Thickness]::new(0)

        $run = New-Object System.Windows.Documents.Run($line)

        if ($line -match $errorPattern) {
            $run.Foreground = $errorBrush
            $para.Background = $errorBgBrush
            $errorCount++
        } else {
            $run.Foreground = $normalBrush
        }

        [void]$para.Inlines.Add($run)
        [void]$doc.Blocks.Add($para)
    }

    $logViewer.Document = $doc
    $logViewer.ScrollToEnd()

    # Store state for tail mode
    $script:tailFilePath  = $FilePath
    $script:tailLineCount = $lineNum
    $script:tailErrorCount = $errorCount

    $statusText.Text = "$lineNum line(s) | $errorCount error line(s) | $($logTitle.Text)"
}

# =============================================================================
# Event handlers
# =============================================================================

# Browse button - opens modern Explorer-style folder picker
$browseBtn.Add_Click({
    $openDlg = New-Object Microsoft.Win32.OpenFileDialog
    $openDlg.Title            = 'Select log folder'
    $openDlg.ValidateNames    = $false
    $openDlg.CheckFileExists  = $false
    $openDlg.CheckPathExists  = $true
    $openDlg.FileName         = 'Select Folder'
    $openDlg.Filter           = 'Folders|no_files'
    if ($pathBox.Text.Trim() -and (Test-Path -LiteralPath $pathBox.Text.Trim() -PathType Container)) {
        $openDlg.InitialDirectory = $pathBox.Text.Trim()
    }
    if ($openDlg.ShowDialog()) {
        $picked = [System.IO.Path]::GetDirectoryName($openDlg.FileName)
        if ($picked) {
            $pathBox.Text = $picked
            Invoke-RefreshFileList
        }
    }
})

# Refresh button
$refreshBtn.Add_Click({
    Invoke-RefreshFileList
})

# Delete Old Logs button - removes files older than 7 days after confirmation
$deleteOldBtn.Add_Click({
    $logPath = $pathBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($logPath) -or -not (Test-Path -LiteralPath $logPath -PathType Container)) {
        $statusText.Text = 'Enter a valid log path first.'
        return
    }

    # Find files older than 7 days
    $cutoff = (Get-Date).AddDays(-7)
    $oldFiles = @()
    foreach ($ext in $LogExtensions) {
        $oldFiles += @(Get-ChildItem -LiteralPath $logPath -Filter $ext -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff })
    }

    if ($oldFiles.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No log files older than 7 days found.",
            "Delete Old Logs",
            'OK', 'Information')
        return
    }

    $result = [System.Windows.MessageBox]::Show(
        "Delete $($oldFiles.Count) log file(s) last modified before $($cutoff.ToString('yyyy-MM-dd HH:mm'))?`n`nThis cannot be undone.",
        "Delete Old Logs",
        'YesNo', 'Warning')

    if ($result -eq 'Yes') {
        $deleted = 0
        $failed  = 0
        foreach ($f in $oldFiles) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $deleted++
            } catch {
                $failed++
            }
        }
        $msg = "Deleted $deleted file(s)."
        if ($failed -gt 0) { $msg += " Failed to delete $failed file(s)." }
        $statusText.Text = $msg
        Invoke-RefreshFileList
    }
})

# Time range change - auto refresh
$timeRangeCombo.Add_SelectionChanged({
    if ($pathBox.Text.Trim()) { Invoke-RefreshFileList }
})

# Errors Only checkbox - auto refresh
$errorsOnlyCheck.Add_Checked({
    if ($pathBox.Text.Trim()) { Invoke-RefreshFileList }
})
$errorsOnlyCheck.Add_Unchecked({
    if ($pathBox.Text.Trim()) { Invoke-RefreshFileList }
})

# File name filter - filters the file grid as you type
$fileFilterBox.Add_TextChanged({
    $grid = $fileGrid
    if (-not $grid.ItemsSource) { return }
    $filterText = $fileFilterBox.Text.Trim()
    if ($filterText -eq '') {
        # Show all items - re-run refresh to restore full list
        Invoke-RefreshFileList
    } else {
        # Filter existing items by file name
        $filtered = @($grid.ItemsSource | Where-Object { $_.Name -like "*$filterText*" })
        $grid.ItemsSource = $filtered
        $statusText.Text = "$($filtered.Count) file(s) matching '$filterText'"
    }
})

# Tail mode - DispatcherTimer polls the file for new lines every 2 seconds
$script:tailFilePath   = $null
$script:tailLineCount  = 0
$script:tailErrorCount = 0

$script:tailTimer          = New-Object System.Windows.Threading.DispatcherTimer
$script:tailTimer.Interval = [TimeSpan]::FromSeconds(2)
# Pre-compute brushes and pattern for tail mode (avoids re-creating every tick)
$script:tailNormalBrush  = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#A8C4DE')
$script:tailErrorBrush   = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#FF6B6B')
$script:tailErrorBgBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#3D1F1F')
$script:tailErrorPattern = ($ErrorMarkers | ForEach-Object { [regex]::Escape($_) }) -join '|'

$script:tailTimer.Add_Tick({
    if (-not $script:tailFilePath -or -not (Test-Path -LiteralPath $script:tailFilePath)) { return }
    try {
        # Use FileShare.ReadWrite so we can read files still being written to
        $fs = [System.IO.FileStream]::new($script:tailFilePath, 'Open', 'Read', [System.IO.FileShare]::ReadWrite)
        $sr = [System.IO.StreamReader]::new($fs)
        $allLines = @()
        while ($null -ne ($l = $sr.ReadLine())) { $allLines += $l }
        $sr.Close()
        $fs.Close()

        $totalLines = $allLines.Count
        if ($totalLines -le $script:tailLineCount) { return }

        $errorPattern = $script:tailErrorPattern
        $normalBrush  = $script:tailNormalBrush
        $errorBrush   = $script:tailErrorBrush
        $errorBgBrush = $script:tailErrorBgBrush

        $doc = $logViewer.Document
        $newErrors = 0
        for ($i = $script:tailLineCount; $i -lt $totalLines; $i++) {
            $line = $allLines[$i]
            $para = New-Object System.Windows.Documents.Paragraph
            $para.Margin  = [System.Windows.Thickness]::new(0)
            $para.Padding = [System.Windows.Thickness]::new(0)
            $run = New-Object System.Windows.Documents.Run($line)
            if ($line -match $errorPattern) {
                $run.Foreground  = $errorBrush
                $para.Background = $errorBgBrush
                $newErrors++
            } else {
                $run.Foreground = $normalBrush
            }
            [void]$para.Inlines.Add($run)
            [void]$doc.Blocks.Add($para)
        }

        $script:tailLineCount  = $totalLines
        $script:tailErrorCount += $newErrors
        $logViewer.ScrollToEnd()
        $statusText.Text = "$totalLines line(s) | $($script:tailErrorCount) error line(s) | $($logTitle.Text) [Tailing]"
    } catch {
        $statusText.Text = "Tail error: $_"
    }
})

# Toggle tail on/off
$tailToggle.Add_Checked({
    if ($script:tailFilePath) {
        $script:tailTimer.Start()
        $statusText.Text = "$($script:tailLineCount) line(s) | $($script:tailErrorCount) error line(s) | $($logTitle.Text) [Tailing]"
    } else {
        $statusText.Text = "Tail enabled but no file selected"
    }
})
$tailToggle.Add_Unchecked({
    $script:tailTimer.Stop()
    if ($script:tailFilePath) {
        $statusText.Text = "$($script:tailLineCount) line(s) | $($script:tailErrorCount) error line(s) | $($logTitle.Text)"
    }
})

# File selection - load log content and auto-enable tail
$fileGrid.Add_SelectionChanged({
    $sel = $fileGrid.SelectedItem
    if ($null -eq $sel) { return }
    $filePath = $sel.FullPath
    if ($filePath -and (Test-Path -LiteralPath $filePath)) {
        # Stop any active tail before loading new file
        $script:tailTimer.Stop()
        Show-LogContent -FilePath $filePath
        $tailToggle.IsEnabled = $true
        # Auto-enable tail - uncheck first to ensure Checked event fires
        $tailToggle.IsChecked = $false
        $tailToggle.IsChecked = $true
    }
})

# Enter key in path box triggers refresh
$pathBox.Add_KeyDown({
    if ($_.Key -eq 'Return') { Invoke-RefreshFileList }
})

# Auto-refresh timer - refreshes the file list on a configurable interval
$script:autoRefreshTimer          = New-Object System.Windows.Threading.DispatcherTimer
$script:autoRefreshTimer.Interval = [TimeSpan]::FromSeconds($AutoRefreshIntervalSeconds)
$script:autoRefreshTimer.Add_Tick({
    if ($pathBox.Text.Trim()) { Invoke-RefreshFileList }
})

$autoRefreshCheck.Add_Checked({
    $script:autoRefreshTimer.Start()
    $statusText.Text = "Auto-refresh enabled (every ${AutoRefreshIntervalSeconds}s)"
})
$autoRefreshCheck.Add_Unchecked({
    $script:autoRefreshTimer.Stop()
    $statusText.Text = "Auto-refresh disabled"
})

# =============================================================================
# Show window
# =============================================================================
$statusText.Text = 'Enter a log path and click Refresh, or use Browse.'
$window.ShowDialog() | Out-Null
