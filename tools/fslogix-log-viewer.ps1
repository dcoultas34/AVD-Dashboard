<#
.SYNOPSIS
    FSLogix Logoff Diagnostics - profile detach and hang analysis tool.

.DESCRIPTION
    Standalone WPF tool for diagnosing FSLogix profile issues on AVD session hosts.
    Features:
      - Log File Diagnostics tab: scans FSLogix log files (C:\ProgramData\FSLogix\Logs)
        for errors, warnings, and key session lifecycle events (logon, logoff, attach,
        detach, lock acquisition/release). Filters out noise patterns to surface only
        significant entries. Configurable time window and optional username filter.
      - Event Log tab: queries Windows event logs for FSLogix-related entries across
        Microsoft-FSLogix-Apps/Operational, Microsoft-FSLogix-Apps/Admin,
        Microsoft-FSLogix-CloudCache/Operational, Microsoft-FSLogix-CloudCache/Admin,
        and FSLogix-related entries in Application and System logs.
      - Service status pills showing frxsvc, frxccds, frxdrv, frxdrvvt state.
      - Export diagnostic output to text file.
      - No Azure authentication required - runs locally on the session host.

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
    2026-04-20 - Remote machine support: Computer Name field auto-rewrites log
            path to UNC (\\host\C$\...), queries remote services and event logs.
            Requires TCP 445 (SMB) for log files; TCP 135 + RPC for services/events.
    2026-03-16 - Initial release. Log file diagnostics, event log viewer,
            service status pills, noise filtering with documented exclusions.

#>

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

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Set a unique AppUserModelID so it appears as its own taskbar entry
try {
    $null = Add-Type -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@ -Name 'Shell32' -Namespace 'Win32' -PassThru -ErrorAction Stop
    [Win32.Shell32]::SetCurrentProcessExplicitAppUserModelID('AVDFSLogixDiag') | Out-Null
} catch { <# non-critical #> }

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FSLogix Logoff Diagnostics" Height="750" Width="1050"
        MinHeight="500" MinWidth="750"
        Background="#F4F6F9" WindowStartupLocation="CenterScreen"
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
                        <Border Background="{TemplateBinding Background}" CornerRadius="5"
                                Padding="{TemplateBinding Padding}">
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
                        <Border Background="{TemplateBinding Background}" CornerRadius="5"
                                Padding="{TemplateBinding Padding}">
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
    </Window.Resources>

    <DockPanel>
        <!-- Status bar -->
        <Border DockPanel.Dock="Bottom" Background="#0078D4" Height="32">
            <Grid Margin="14,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="txtStatus" Text="Ready" Foreground="White"
                           FontSize="12" VerticalAlignment="Center"/>
                <Button x:Name="btnExport" Grid.Column="1" Content="Export Log"
                        Style="{StaticResource SecondaryBtn}" Padding="12,4"
                        VerticalAlignment="Center"/>
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
                    <RowDefinition Height="10"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Row 0: Inputs + buttons -->
                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>  <!-- 0: Minutes label -->
                        <ColumnDefinition Width="80"/>    <!-- 1: Minutes input -->
                        <ColumnDefinition Width="16"/>    <!-- 2: spacer -->
                        <ColumnDefinition Width="Auto"/>  <!-- 3: User label -->
                        <ColumnDefinition Width="120"/>   <!-- 4: User input -->
                        <ColumnDefinition Width="16"/>    <!-- 5: spacer -->
                        <ColumnDefinition Width="Auto"/>  <!-- 6: Computer label -->
                        <ColumnDefinition Width="150"/>   <!-- 7: Computer input -->
                        <ColumnDefinition Width="16"/>    <!-- 8: spacer -->
                        <ColumnDefinition Width="Auto"/>  <!-- 9: Log Path label -->
                        <ColumnDefinition Width="*"/>     <!-- 10: Log Path input -->
                        <ColumnDefinition Width="16"/>    <!-- 11: spacer -->
                        <ColumnDefinition Width="Auto"/>  <!-- 12: Include Info checkbox -->
                        <ColumnDefinition Width="Auto"/>  <!-- 13: Run button -->
                        <ColumnDefinition Width="8"/>     <!-- 14: spacer -->
                        <ColumnDefinition Width="Auto"/>  <!-- 15: Clear button -->
                    </Grid.ColumnDefinitions>

                    <TextBlock Grid.Column="0" Text="Minutes:" FontSize="12" Foreground="#555"
                               VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBox x:Name="txtMinutes" Grid.Column="1" Text="15" FontSize="12"
                             Padding="8,6" BorderBrush="#C8CDD3" BorderThickness="1"
                             VerticalContentAlignment="Center"/>

                    <TextBlock Grid.Column="3" Text="User:" FontSize="12" Foreground="#555"
                               VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBox x:Name="txtUsername" Grid.Column="4" FontSize="12"
                             Padding="8,6" BorderBrush="#C8CDD3" BorderThickness="1"
                             VerticalContentAlignment="Center"/>

                    <TextBlock Grid.Column="6" Text="Computer:" FontSize="12" Foreground="#555"
                               VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBox x:Name="txtComputer" Grid.Column="7" FontSize="12"
                             Padding="8,6" BorderBrush="#C8CDD3" BorderThickness="1"
                             VerticalContentAlignment="Center"
                             ToolTip="Leave blank for local machine. Enter hostname or IP for remote.&#10;Requires: TCP 445 (log files), TCP 135 + RPC (services/events)."/>

                    <TextBlock Grid.Column="9" Text="Log Path:" FontSize="12" Foreground="#555"
                               VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBox x:Name="txtLogRoot" Grid.Column="10"
                             Text="C:\ProgramData\FSLogix\Logs" FontSize="12"
                             Padding="8,6" BorderBrush="#C8CDD3" BorderThickness="1"
                             VerticalContentAlignment="Center"/>

                    <CheckBox x:Name="chkIncludeInfo" Grid.Column="12"
                              Content="Include Info" FontSize="12" Foreground="#1F2937"
                              VerticalAlignment="Center" IsChecked="True"/>
                    <Button x:Name="btnRun" Grid.Column="13" Content="Run"
                            Style="{StaticResource PrimaryBtn}" Margin="12,0,0,0"/>
                    <Button x:Name="btnClear" Grid.Column="15" Content="Clear"
                            Style="{StaticResource SecondaryBtn}"/>
                </Grid>

                <!-- Row 2: Service pills + last run -->
                <Border Grid.Row="2" Background="#F4F6F9" BorderBrush="#DDE1E7"
                        BorderThickness="1" CornerRadius="4" Padding="10,6">
                    <DockPanel>
                        <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
                            <TextBlock Text="FSLogix Services:" FontSize="11" FontWeight="SemiBold"
                                       Foreground="#555" VerticalAlignment="Center" Margin="0,0,10,0"/>
                            <StackPanel x:Name="spServices" Orientation="Horizontal"/>
                        </StackPanel>
                        <TextBlock x:Name="txtLastRun" Text="" Foreground="#888"
                                   FontSize="11" VerticalAlignment="Center"
                                   HorizontalAlignment="Right" Margin="16,0,0,0"/>
                    </DockPanel>
                </Border>
            </Grid>
        </Border>

        <!-- Summary bar (hidden until first run) -->
        <Border DockPanel.Dock="Top" x:Name="borderSummary" Background="#F0F4FA"
                BorderBrush="#DDE1E7" BorderThickness="0,0,0,1" Padding="16,8"
                Visibility="Collapsed">
            <TextBlock x:Name="txtSummary" FontSize="12" FontWeight="SemiBold"/>
        </Border>

        <!-- Tabbed output area -->
        <TabControl Margin="12,12,12,0" x:Name="OutputTabs">
            <!-- Tab 1: Log File Diagnostics -->
            <TabItem Header="  Log File Diagnostics  ">
                <Border Background="#1E2A38" BorderBrush="#DDE1E7" BorderThickness="1">
                    <DockPanel>
                        <Border DockPanel.Dock="Top" Background="#263545" Padding="12,8">
                            <TextBlock Text="Diagnostic Output" FontSize="12"
                                       FontWeight="SemiBold" Foreground="#A8C4DE"/>
                        </Border>
                        <RichTextBox x:Name="rtbOutput"
                                     Background="#1E2A38"
                                     Foreground="#A8C4DE"
                                     FontFamily="Consolas"
                                     FontSize="11"
                                     IsReadOnly="True"
                                     BorderThickness="0"
                                     VerticalScrollBarVisibility="Auto"
                                     HorizontalScrollBarVisibility="Auto"
                                     Padding="14,8">
                            <RichTextBox.Document>
                                <FlowDocument PageWidth="5000"/>
                            </RichTextBox.Document>
                        </RichTextBox>
                    </DockPanel>
                </Border>
            </TabItem>

            <!-- Tab 2: Event Log -->
            <TabItem Header="  Event Log  ">
                <Border Background="#1E2A38" BorderBrush="#DDE1E7" BorderThickness="1">
                    <DockPanel>
                        <Border DockPanel.Dock="Top" Background="#263545" Padding="12,8">
                            <DockPanel>
                                <Button x:Name="btnEventRefresh" DockPanel.Dock="Right"
                                        Content="Refresh" Style="{StaticResource PrimaryBtn}"
                                        Padding="12,4" VerticalAlignment="Center"/>
                                <TextBlock Text="FSLogix Event Log Entries" FontSize="12"
                                           FontWeight="SemiBold" Foreground="#A8C4DE"
                                           VerticalAlignment="Center"/>
                            </DockPanel>
                        </Border>
                        <RichTextBox x:Name="rtbEventLog"
                                     Background="#1E2A38"
                                     Foreground="#A8C4DE"
                                     FontFamily="Consolas"
                                     FontSize="11"
                                     IsReadOnly="True"
                                     BorderThickness="0"
                                     VerticalScrollBarVisibility="Auto"
                                     HorizontalScrollBarVisibility="Auto"
                                     Padding="14,8">
                            <RichTextBox.Document>
                                <FlowDocument PageWidth="5000"/>
                            </RichTextBox.Document>
                        </RichTextBox>
                    </DockPanel>
                </Border>
            </TabItem>
        </TabControl>
    </DockPanel>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Get controls
$btnRun     = $window.FindName("btnRun")
$btnClear   = $window.FindName("btnClear")
$btnExport  = $window.FindName("btnExport")
$rtbOutput  = $window.FindName("rtbOutput")
$txtMinutes = $window.FindName("txtMinutes")
$txtUsername= $window.FindName("txtUsername")
$txtComputer= $window.FindName("txtComputer")
$txtLogRoot = $window.FindName("txtLogRoot")
$spServices = $window.FindName("spServices")
$txtStatus  = $window.FindName("txtStatus")
$txtLastRun = $window.FindName("txtLastRun")
$chkIncludeInfo = $window.FindName("chkIncludeInfo")
$borderSummary  = $window.FindName("borderSummary")
$txtSummary     = $window.FindName("txtSummary")
$rtbEventLog    = $window.FindName("rtbEventLog")
$btnEventRefresh = $window.FindName("btnEventRefresh")

# Window Icon
# Resolve icon path - $PSScriptRoot may be empty if script is pasted into a console
$_scriptDir2 = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$_iconPath = Join-Path $_scriptDir2 '..\data\avd-dashboard.ico'
if (Test-Path $_iconPath) {
    # Stream-based icon load to avoid locking the .ico file (BitmapCacheOption.OnLoad)
    try {
        # .ProviderPath for UNC-safe resolution (avoids FileSystem:: prefix)
        $iconStream = [System.IO.File]::OpenRead((Resolve-Path $_iconPath).ProviderPath)
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
            $iconStream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $iconStream.Close()
    } catch {}
}

# ---- Helper: Append coloured text to RichTextBox ----
function Write-RTB {
    param(
        [string]$Text,
        [string]$Color = "#A8C4DE",
        [bool]$Bold = $false,
        [bool]$NewLine = $true
    )
    $para = $rtbOutput.Document.Blocks | Select-Object -Last 1
    if (-not $para -or $NewLine) {
        $para = [System.Windows.Documents.Paragraph]::new()
        $para.Margin = [System.Windows.Thickness]::new(0)
        $para.Padding = [System.Windows.Thickness]::new(0)
        $rtbOutput.Document.Blocks.Add($para)
    }
    $run = [System.Windows.Documents.Run]::new($Text)
    $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    if ($Bold) { $run.FontWeight = [System.Windows.FontWeights]::Bold }
    $para.Inlines.Add($run)
}

function Write-Section {
    param([string]$Title)
    Write-RTB ""
    Write-RTB ("=" * 70) "#3B5A7A"
    Write-RTB "  $Title" "#00BFFF" $true
    Write-RTB ("=" * 70) "#3B5A7A"
}

function Write-Info  { param([string]$m) Write-RTB $m "#A8C4DE" }
function Write-Warn  { param([string]$m) Write-RTB $m "#FFB347" }
function Write-Error { param([string]$m) Write-RTB $m "#FF6B6B" }
function Write-Good  { param([string]$m) Write-RTB $m "#34D399" }
function Write-Dim   { param([string]$m) Write-RTB $m "#4A6070" }

# ---- Computer name -> auto-rewrite Log Path to UNC ----
# When a computer name is entered, rewrite "C:\..." to "\\host\C$\...".
# When cleared, revert UNC back to local path.
# The user can still manually edit Log Path at any time.
$txtComputer.Add_TextChanged({
    $comp    = $txtComputer.Text.Trim()
    $current = $txtLogRoot.Text.Trim()
    if ($comp) {
        # Only rewrite if it looks like a plain local path (e.g. C:\...)
        if ($current -match '^([A-Za-z]):\\(.*)$') {
            $txtLogRoot.Text = "\\$comp\$($Matches[1])$\$($Matches[2])"
        }
    } else {
        # Revert UNC path back to local if computer name is cleared
        if ($current -match '^\\\\[^\\]+\\([A-Za-z])\$\\(.*)$') {
            $txtLogRoot.Text = "$($Matches[1]):\$($Matches[2])"
        }
    }
})

# ---- Service Status Pills ----
function Update-ServicePills {
    param([string]$ComputerName = '')
    $spServices.Children.Clear()
    $services = @("frxsvc","frxccds","frxdrv","frxdrvvt")
    foreach ($svcName in $services) {
        $getArgs = @{ Name = $svcName; ErrorAction = 'SilentlyContinue' }
        if ($ComputerName) { $getArgs['ComputerName'] = $ComputerName }
        $svc = Get-Service @getArgs
        $border = [System.Windows.Controls.Border]::new()
        $border.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $border.Padding = [System.Windows.Thickness]::new(8,3,8,3)
        $border.Margin  = [System.Windows.Thickness]::new(0,0,6,0)
        $tb = [System.Windows.Controls.TextBlock]::new()
        $tb.FontSize = 11
        $conv = [System.Windows.Media.BrushConverter]::new()
        if ($svc -and $svc.Status -eq 'Running') {
            $border.Background = $conv.ConvertFromString("#E6F4EA")
            $tb.Foreground     = $conv.ConvertFromString("#1B7A3D")
            $tb.Text           = [char]0x25CF + " $svcName"
        } elseif ($svc) {
            $border.Background = $conv.ConvertFromString("#FDE8E8")
            $tb.Foreground     = $conv.ConvertFromString("#C42B1C")
            $tb.Text           = [char]0x25CF + " $svcName ($($svc.Status))"
        } else {
            $border.Background = $conv.ConvertFromString("#F0F0F0")
            $tb.Foreground     = $conv.ConvertFromString("#888")
            $tb.Text           = [char]0x25CB + " $svcName"
        }
        $border.Child = $tb
        $spServices.Children.Add($border) | Out-Null
    }
}

# ---- Main Diagnostic Runner ----
function Invoke-Diagnostics {
    $btnRun.IsEnabled = $false
    $txtStatus.Text   = "Running..."

    # Clear output
    $rtbOutput.Document.Blocks.Clear()

    $minutesBack  = 15
    [int]::TryParse($txtMinutes.Text, [ref]$minutesBack) | Out-Null
    $username     = $txtUsername.Text.Trim()
    $computerName = $txtComputer.Text.Trim()
    $logRoot      = $txtLogRoot.Text.Trim()
    $since        = (Get-Date).AddMinutes(-$minutesBack)
    $target       = if ($computerName) { $computerName } else { $env:COMPUTERNAME }

    $errorCount   = 0
    $warnCount    = 0
    $matchedFiles = 0

    Write-RTB "FSLogix Logoff Diagnostics - $target" "#00BFFF" $true
    Write-RTB "  Run at  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "#6B8A9E"
    Write-RTB "  Window  : Last $minutesBack minutes (since $($since.ToString('HH:mm:ss')))" "#6B8A9E"
    if ($username) { Write-RTB "  Filter  : $username" "#6B8A9E" }
    Write-RTB "  LogRoot : $logRoot" "#6B8A9E"

    # Folders that are pure noise - skip entirely
    $skipFolders = @('DriverInterface','Font','RuleCompilation','AdsComputerGroup')

    # Line patterns that are always noise - never show these.
    # "Failed to OpenProcess" / "Failed to query command-line" / "Invalid access to memory location":
    #   These are benign warnings from FSLogix's UsermodeModule. It enumerates all running processes
    #   per session and some system/protected processes (e.g. PID 4 = System) deny access. The error
    #   code 00000005 is Windows ERROR_ACCESS_DENIED. These are flagged [WARN] not [ERROR] by FSLogix.
    #   Common and expected on all session hosts - not indicative of profile mount/detach issues.
    #   Ref: https://techcommunity.microsoft.com/discussions/fslogix/fslogix--failed-to-openprocess-and-get-the-process-name-with-pid-xxxxx-access-is/3912522
    #   Ref: https://techcommunity.microsoft.com/t5/fslogix/fslogix-log-files-usermodemodule/td-p/2159697
    #   Ref: https://learn.microsoft.com/en-us/fslogix/troubleshooting-error-codes
    # NOTE: "Failed to OpenProcess" / "Failed to query command-line" / "Invalid access to memory location"
    # are benign warnings from FSLogix's UsermodeModule. It enumerates all running processes per session
    # and some system/protected processes (e.g. PID 4 = System) deny access (error 00000005 = ERROR_ACCESS_DENIED).
    # Flagged [WARN] not [ERROR]. Common on all session hosts - not indicative of profile mount/detach issues.
    # Left visible for awareness but can be safely ignored if profiles mount/detach correctly.
    # Ref: https://techcommunity.microsoft.com/discussions/fslogix/fslogix--failed-to-openprocess-and-get-the-process-name-with-pid-xxxxx-access-is/3912522
    # Ref: https://techcommunity.microsoft.com/t5/fslogix/fslogix-log-files-usermodemodule/td-p/2159697
    # Ref: https://learn.microsoft.com/en-us/fslogix/troubleshooting-error-codes
    $noisePatterns = @(
        'Thread waiting for signal',
        'OnWindowsSearchSetup',
        'Creating signal events',
        'Starting Module Thread',
        'Usermode Service Module started',
        'Begin Session: Usermode Service Module',
        'End Session: Usermode Service Module',
        'Configuration setting not found',
        'Session configuration wrote',
        'Session configuration read',
        'Shell notification disabled',
        'Shell notification enabled',
        'Shell refresh NOT requested',
        'Device cleanup queued',
        'Devices removed:',
        'Looking at the command line',
        'loaded components',
        'Setup completed',
        'Include group SID',
        'Exclude group SID',
        'User is a member',
        'Container refcount incremented',
        'Checking for WTS protocol info',
        'IP Address:',
        'Service Module .* started successfully',
        'Registering with SCM',
        'Registering service control handler',
        'Enabling process privileges',
        'Creating event',
        'Creating volume event',
        'Registering for volume notifications',
        'Checking FSLogix local groups',
        'Starting service modules',
        'Starting user session notifications',
        'Waiting for termination signal',
        'Enter main',
        'UserSessionsModule::Start',
        'Connect event for session',
        'Building user context',
        'SID: S-1-',
        'Username:',
        'Profile Path:',
        'Profile Version:',
        'Installed system RAM',
        'FSLogix Service Version',
        'FSLogix Kernel',
        'Origin:',
        'WinDir:',
        'User Profile:',
        'Computer Name:',
        'Windows 10\.',
        'Log file created',
        'UTC-',
        '^-+$',
        'ReAttachAttempted',
        'WindowsSessionID',
        'FrxshellErrorCode',
        'FrxshellStatus',
        'FrxshellReason',
        'CleanupRecycleBin',
        'IsDynamic',
        'RedirectType',
        'SizeInMBs',
        'VHDXSectorSize',
        'RefCount'
    )

    # Lines we always want to show (signal)
    $signalPatterns = @(
        'Begin Session: Logon',
        'End Session: Logon',
        'Begin Session: Logoff',
        'End Session: Logoff',
        'Begin Session: Pre Profiles Logoff',
        'Begin Session: Post Profiles Logon',
        'Begin Session: Attach',
        'End Session: Attach',
        'Begin Session: Detach',
        'End Session: Detach',
        'AcquireExclusiveLock',
        'ReleaseLock',
        'Acquired.*[Ll]ock',
        'Released lock',
        'Register.*vdisk',
        'UnRegister',
        'LogonStage',
        'loadProfile time',
        'unloadProfile time',
        'UnloadProfile successful',
        'Please wait',
        'timeout',
        'Timeout',
        '\[ERROR\]',
        '\[WARN\]',
        'failed to detach',
        'Failed to detach',
        'VHD.*fail',
        'dismount.*fail',
        'Cannot detach',
        'locked by another',
        'handle.*open',
        'Access.*denied',
        'Status set to [^0]',
        'Reason set to'
    )

    # Lines that are real errors
    $errorPatterns = @(
        'Please wait',
        '\[ERROR\]',
        'failed to detach',
        'Failed to detach',
        'Cannot detach',
        'VHD.*fail',
        'dismount.*fail',
        'locked by another',
        'Access.*denied',
        'Unhandled exception'
    )

    # Lines that are warnings
    $warnPatterns = @(
        'timeout',
        'Timeout',
        'handle.*open',
        'Status set to [^0]',
        '\[WARN\]',
        'Reason set to [^06]'
    )

    function Test-IsNoise {
        param([string]$line)
        foreach ($p in $noisePatterns) { if ($line -match $p) { return $true } }
        return $false
    }

    function Test-IsSignal {
        param([string]$line)
        foreach ($p in $signalPatterns) { if ($line -match $p) { return $true } }
        return $false
    }

    function Get-LineType {
        param([string]$line)
        foreach ($p in $errorPatterns) { if ($line -match $p) { return 'error' } }
        foreach ($p in $warnPatterns)  { if ($line -match $p) { return 'warn'  } }
        return 'info'
    }

    # ---- Event Log ----
    Write-Section "EVENT LOG"

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Application','System'
            StartTime = $since
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.ProviderName -like "*FSLogix*" -or
            $_.Message -like "*FSLogix*"      -or
            $_.Message -like "*Please wait*"  -or
            $_.Message -like "*frxsvc*"       -or
            $_.Message -like "*frxccds*"      -or
            $_.Message -like "*VHD*detach*"   -or
            $_.Message -like "*profile*dismount*" -or
            $_.Message -like "*failed to detach*"
        }

        if ($events) {
            foreach ($ev in $events) {
                $line = "[$($ev.TimeCreated.ToString('HH:mm:ss'))] [$($ev.LevelDisplayName.ToUpper())] $($ev.ProviderName)"
                $msg  = "  " + ($ev.Message -split "`n")[0].Trim()
                switch ($ev.Level) {
                    1 { Write-Error $line; $errorCount++ }
                    2 { Write-Error $line; $errorCount++ }
                    3 { Write-Warn  $line; $warnCount++  }
                    default { Write-Info $line }
                }
                Write-Dim $msg
            }
        } else {
            Write-Good "  No FSLogix events found in the last $minutesBack minutes"
        }
    } catch {
        Write-Warn "  Could not query event log: $_"
    }

    # ---- Log Files ----
    Write-Section "LOG FILES"

    if (-not (Test-Path $logRoot)) {
        Write-Error "  Log root not found: $logRoot"
    } else {
        $subFolders = Get-ChildItem -Path $logRoot -Directory -Recurse -ErrorAction SilentlyContinue
        Write-Dim "  Folders:"
        foreach ($sf in $subFolders) {
            $skip = $false
            foreach ($s in $skipFolders) { if ($sf.FullName -match [regex]::Escape($s)) { $skip = $true; break } }
            if ($skip) { Write-Dim "    [SKIP] $($sf.FullName)" }
            else        { Write-Dim "    [SCAN] $($sf.FullName)" }
        }
        Write-RTB ""

        $logFiles = Get-ChildItem -Path $logRoot -Filter "*.log" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $since } |
            Where-Object {
                $skip = $false
                foreach ($sf in $skipFolders) {
                    if ($_.FullName -match [regex]::Escape($sf)) { $skip = $true; break }
                }
                -not $skip
            }

        if ($username) {
            $logFiles = $logFiles | Where-Object { $_.Name -like "*$username*" }
        }

        if (-not $logFiles) {
            Write-Good "  No log files modified in the last $minutesBack minutes"
        } else {
            foreach ($file in $logFiles) {
                $matchedFiles++
                Write-RTB ""
                Write-RTB "  -- $($file.Name)" "#00BFFF" $true
                Write-Dim "     $($file.FullName)"
                Write-Dim "     Modified: $($file.LastWriteTime.ToString('HH:mm:ss'))"

                # FSLogix logs are UTF-16LE
                try {
                    $lines = [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::Unicode)
                } catch {
                    $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
                }

                # Whether to include informational lines or only errors/warnings
                $showInfo = $chkIncludeInfo.IsChecked

                $hitCount = 0
                foreach ($line in $lines) {
                    $line = $line.Trim()
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }

                    # ── Timestamp filter ──
                    # FSLogix log lines start with a timestamp like [HH:mm:ss.fff]
                    # Parse it and skip lines older than the configured time window.
                    if ($line -match '^\[(\d{2}:\d{2}:\d{2})') {
                        try {
                            $lineTime = [DateTime]::ParseExact($matches[1], 'HH:mm:ss', $null)
                            # Use today's date for comparison
                            $lineDateTime = (Get-Date).Date.Add($lineTime.TimeOfDay)
                            if ($lineDateTime -lt $since) { continue }
                        } catch { <# can't parse - keep the line #> }
                    }

                    # ── Noise filter - skip known benign patterns ──
                    if (Test-IsNoise $line) { continue }

                    # ── Signal filter - only show lines matching important patterns ──
                    if (-not (Test-IsSignal $line)) { continue }

                    # ── Classify the line as error, warning, or info ──
                    $lineType = Get-LineType $line

                    # If "Include Info" is unchecked, skip informational lines
                    if (-not $showInfo -and $lineType -eq 'info') { continue }

                    $hitCount++
                    switch ($lineType) {
                        'error' { Write-Error "     $line"; $errorCount++ }
                        'warn'  { Write-Warn  "     $line"; $warnCount++  }
                        default { Write-Info  "     $line" }
                    }
                }

                if ($hitCount -eq 0) { Write-Dim "     No significant entries" }
            }
        }
    }

    # ---- Service Status ----
    Write-Section "SERVICE STATUS"
    $services = @("frxsvc","frxccds","frxdrv","frxdrvvt")
    foreach ($svcName in $services) {
        $svcs = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svcs) {
            foreach ($s in $svcs) {
                $pad = $s.Name.PadRight(40)
                if ($s.Status -eq 'Running') {
                    Write-Good "  $([char]0x25CF) $pad RUNNING"
                } elseif ($s.Status -eq 'Stopped') {
                    Write-Info "  $([char]0x25CB) $pad STOPPED"
                } else {
                    Write-Warn "  $([char]0x25D0) $pad $($s.Status.ToString().ToUpper())"
                    $warnCount++
                }
            }
        } else {
            Write-Dim "  $([char]0x25CB) $($svcName.PadRight(40)) NOT FOUND"
        }
    }

    # ---- Summary ----
    Write-Section "SUMMARY"
    if ($errorCount -eq 0 -and $warnCount -eq 0) {
        Write-Good "  No errors or warnings found in the last $minutesBack minutes"
    } else {
        if ($errorCount -gt 0) { Write-Error "  $errorCount error(s) found" }
        if ($warnCount  -gt 0) { Write-Warn  "  $warnCount warning(s) found" }
    }
    Write-Info "  $matchedFiles log file(s) scanned"

    # Update summary bar
    $borderSummary.Visibility = "Visible"
    $summaryColor = if ($errorCount -gt 0) { "#C42B1C" } elseif ($warnCount -gt 0) { "#B8860B" } else { "#1B7A3D" }
    $conv = [System.Windows.Media.BrushConverter]::new()
    $txtSummary.Foreground = $conv.ConvertFromString($summaryColor)
    $txtSummary.Text = "$errorCount error(s)  |  $warnCount warning(s)  |  $matchedFiles file(s) scanned  |  Window: last $minutesBack mins"

    # Scroll to top
    $rtbOutput.ScrollToHome()

    Update-ServicePills -ComputerName $computerName
    $txtLastRun.Text  = "Last run: $(Get-Date -Format 'HH:mm:ss') ($target)"
    $txtStatus.Text   = "Done - $errorCount errors, $warnCount warnings"
    $btnRun.IsEnabled = $true
}

# ---- Event Log Query ----
function Write-EventRTB {
    param(
        [string]$Text,
        [string]$Color = "#A8C4DE",
        [bool]$Bold = $false
    )
    $para = [System.Windows.Documents.Paragraph]::new()
    $para.Margin = [System.Windows.Thickness]::new(0)
    $para.Padding = [System.Windows.Thickness]::new(0)
    $run = [System.Windows.Documents.Run]::new($Text)
    $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    if ($Bold) { $run.FontWeight = [System.Windows.FontWeights]::Bold }
    $para.Inlines.Add($run)
    $rtbEventLog.Document.Blocks.Add($para)
}

function Invoke-EventLogQuery {
    $btnEventRefresh.IsEnabled = $false
    $txtStatus.Text = "Querying event logs..."
    $rtbEventLog.Document.Blocks.Clear()

    $minutesBack  = 15
    [int]::TryParse($txtMinutes.Text, [ref]$minutesBack) | Out-Null
    $computerName = $txtComputer.Text.Trim()
    $since        = (Get-Date).AddMinutes(-$minutesBack)
    $target       = if ($computerName) { $computerName } else { $env:COMPUTERNAME }

    $errorCount = 0
    $warnCount  = 0
    $infoCount  = 0

    Write-EventRTB "FSLogix Event Log Query - $target" "#00BFFF" $true
    Write-EventRTB "  Time window: Last $minutesBack minutes (since $($since.ToString('HH:mm:ss')))" "#6B8A9E"
    Write-EventRTB ""

    # --- FSLogix-specific event logs ---
    $fslogixLogs = @(
        'Microsoft-FSLogix-Apps/Operational',
        'Microsoft-FSLogix-Apps/Admin',
        'Microsoft-FSLogix-CloudCache/Operational',
        'Microsoft-FSLogix-CloudCache/Admin'
    )

    foreach ($logName in $fslogixLogs) {
        Write-EventRTB ("=" * 70) "#3B5A7A"
        Write-EventRTB "  $logName" "#00BFFF" $true
        Write-EventRTB ("=" * 70) "#3B5A7A"

        try {
            # Get all events (errors, warnings, and info) from FSLogix logs
            $winEvtArgs = @{ FilterHashtable = @{ LogName = $logName; StartTime = $since }; MaxEvents = 200; ErrorAction = 'Stop' }
            if ($computerName) { $winEvtArgs['ComputerName'] = $computerName }
            $events = Get-WinEvent @winEvtArgs

            if ($events.Count -eq 0) {
                Write-EventRTB "  No events in the last $minutesBack minutes" "#34D399"
            } else {
                foreach ($ev in $events) {
                    $ts = $ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                    $lvl = switch ($ev.Level) {
                        1 { 'CRITICAL' }
                        2 { 'ERROR' }
                        3 { 'WARNING' }
                        4 { 'INFO' }
                        default { "L$($ev.Level)" }
                    }
                    $msg = ($ev.Message -replace "`r`n|`n", ' ' -replace '\s+', ' ').Trim()
                    if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }

                    $color = switch ($ev.Level) {
                        1 { "#FF6B6B" }
                        2 { "#FF6B6B" }
                        3 { "#FFB347" }
                        default { "#A8C4DE" }
                    }

                    Write-EventRTB "  [$ts] [$lvl] ID:$($ev.Id)  $msg" $color

                    switch ($ev.Level) {
                        1 { $errorCount++ }
                        2 { $errorCount++ }
                        3 { $warnCount++ }
                        default { $infoCount++ }
                    }
                }
            }
        } catch {
            if ($_.Exception.Message -match 'No events were found') {
                Write-EventRTB "  No events in the last $minutesBack minutes" "#34D399"
            } elseif ($_.Exception.Message -match 'not found|does not exist') {
                Write-EventRTB "  Log not available on $target" "#4A6070"
            } else {
                Write-EventRTB "  Error querying log: $_" "#FF6B6B"
            }
        }
        Write-EventRTB ""
    }

    # --- FSLogix-related entries in Application and System logs ---
    Write-EventRTB ("=" * 70) "#3B5A7A"
    Write-EventRTB "  Application + System (FSLogix-related)" "#00BFFF" $true
    Write-EventRTB ("=" * 70) "#3B5A7A"

    try {
        $sysEvtArgs = @{ FilterHashtable = @{ LogName = 'Application','System'; StartTime = $since }; MaxEvents = 5000; ErrorAction = 'SilentlyContinue' }
        if ($computerName) { $sysEvtArgs['ComputerName'] = $computerName }
        $sysEvents = Get-WinEvent @sysEvtArgs | Where-Object {
            $_.ProviderName -like "*FSLogix*" -or
            $_.ProviderName -like "*frx*" -or
            $_.Message -like "*FSLogix*" -or
            $_.Message -like "*frxsvc*" -or
            $_.Message -like "*frxccds*" -or
            $_.Message -like "*VHD*detach*" -or
            $_.Message -like "*profile*dismount*" -or
            $_.Message -like "*failed to detach*" -or
            $_.Message -like "*Please wait for the FSLogix*"
        }

        if ($sysEvents -and $sysEvents.Count -gt 0) {
            foreach ($ev in $sysEvents) {
                $ts = $ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                $lvl = switch ($ev.Level) {
                    1 { 'CRITICAL' }
                    2 { 'ERROR' }
                    3 { 'WARNING' }
                    4 { 'INFO' }
                    default { "L$($ev.Level)" }
                }
                $msg = ($ev.Message -replace "`r`n|`n", ' ' -replace '\s+', ' ').Trim()
                if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }

                $color = switch ($ev.Level) {
                    1 { "#FF6B6B" }
                    2 { "#FF6B6B" }
                    3 { "#FFB347" }
                    default { "#A8C4DE" }
                }

                Write-EventRTB "  [$ts] [$lvl] $($ev.ProviderName) ID:$($ev.Id)  $msg" $color

                switch ($ev.Level) {
                    1 { $errorCount++ }
                    2 { $errorCount++ }
                    3 { $warnCount++ }
                    default { $infoCount++ }
                }
            }
        } else {
            Write-EventRTB "  No FSLogix-related entries in the last $minutesBack minutes" "#34D399"
        }
    } catch {
        Write-EventRTB "  Error querying Application/System logs: $_" "#FF6B6B"
    }

    # Summary
    Write-EventRTB ""
    Write-EventRTB ("=" * 70) "#3B5A7A"
    Write-EventRTB "  SUMMARY" "#00BFFF" $true
    Write-EventRTB ("=" * 70) "#3B5A7A"
    if ($errorCount -eq 0 -and $warnCount -eq 0) {
        Write-EventRTB "  No errors or warnings found" "#34D399"
    } else {
        if ($errorCount -gt 0) { Write-EventRTB "  $errorCount error(s)" "#FF6B6B" }
        if ($warnCount  -gt 0) { Write-EventRTB "  $warnCount warning(s)" "#FFB347" }
    }
    Write-EventRTB "  $infoCount informational event(s)" "#A8C4DE"

    $rtbEventLog.ScrollToHome()
    $txtStatus.Text = "Event log query complete - $errorCount errors, $warnCount warnings, $infoCount info"
    $btnEventRefresh.IsEnabled = $true
}

$btnEventRefresh.Add_Click({ Invoke-EventLogQuery })

# ---- Button Events ----
$btnRun.Add_Click({ Invoke-Diagnostics })

$btnClear.Add_Click({
    $rtbOutput.Document.Blocks.Clear()
    $borderSummary.Visibility = "Collapsed"
    $txtStatus.Text = "Cleared"
})

$btnExport.Add_Click({
    $dlg = [Microsoft.Win32.SaveFileDialog]::new()
    $dlg.Filter   = "Text files (*.txt)|*.txt"
    $dlg.FileName = "FSLogix-Diag-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    if ($dlg.ShowDialog()) {
        $tr = [System.Windows.Documents.TextRange]::new(
            $rtbOutput.Document.ContentStart,
            $rtbOutput.Document.ContentEnd
        )
        [System.IO.File]::WriteAllText($dlg.FileName, $tr.Text)
        $txtStatus.Text = "Exported to $($dlg.FileName)"
    }
})

# ---- Init ----
Update-ServicePills
$window.ShowDialog() | Out-Null
