<#
.SYNOPSIS
    WPF GUI editor for AVD Live Dashboard config.psd1.

.DESCRIPTION
    Opens a tabbed WPF window covering every section of config.psd1, plus a
    dedicated Run Commands tab for editing data\run-commands.psd1.

    On launch, looks for config.psd1 in the same folder as this script.
    If not found, prompts the user to browse for one.
    A "Browse / Open..." button in the header lets the user switch to any
    config file at any time. Save regenerates a clean, commented PSD1 and
    also saves run-commands.psd1.

    No Azure connection required - purely local file editing.

.NOTES
    Author        : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
    Version       : 2026-03-02
    Requires      : PowerShell 5.1 or PowerShell 7 (Windows)

    DISCLAIMER:
    This script is provided as-is with no warranty, guarantee, or support of any kind.
    Use at your own risk. The author accepts no responsibility for any issues,
    data loss, or damages arising from the use of this script in any environment.
    Always test in a non-production environment before deploying.

    Version History:
    2026-03-02
        - Initial release. Tabbed WPF editor for config.psd1 covering all dashboard
          settings. Save regenerates a clean, commented PSD1.
        - Browse/Open button to switch between config files.
        - Save confirmation: status bar flashes green for 2.5 seconds on successful save.
        - Custom window icon (data\avd-dashboard.ico). Separate taskbar entry.
        - Run Commands tab: edit data\run-commands.psd1 with command list,
          Name/Description/Script edit panel, Add/Remove/Move buttons.
        - New Config button creates a blank config with sensible defaults. Overwrite
          protection on Save.
    2026-03-07
        - Run Commands: ScriptFile support - file-based commands show path in read-only
          textbox with hint showing source file location.
        - Fix: replaced en-dash in Storage Warning hint text to avoid PS5.1 encoding garble.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Set a unique AppUserModelID so the window appears as its own taskbar entry
# (separate from the PowerShell group) and shows the custom window icon.
try {
    $null = Add-Type -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
'@ -Name 'Shell32CE' -Namespace 'Win32' -PassThru -ErrorAction Stop
    [Win32.Shell32CE]::SetCurrentProcessExplicitAppUserModelID('AVDConfigEditor') | Out-Null
} catch { <# non-critical - continue without custom taskbar grouping #> }

# =============================================================================
# Theme setup (standalone - reads registry directly)
# =============================================================================
$script:EditRegPath = 'HKCU:\Software\AVDDashboard'
$_editDark = $false
try {
    $_kv = Get-ItemProperty -Path $script:EditRegPath -Name 'DarkTheme' -ErrorAction Stop
    $_editDark = [bool][int]$_kv.DarkTheme
} catch {}
# =============================================================================
# Config file resolution
# =============================================================================

$script:currentConfigFile = Join-Path $PSScriptRoot '..\config\config.psd1'

if (-not (Test-Path $script:currentConfigFile)) {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title  = "Locate config.psd1"
    $dlg.Filter = "Config Files (*.psd1)|*.psd1|All Files (*.*)|*.*"
    $dlg.InitialDirectory = Join-Path $PSScriptRoot '..\config'

    if (-not $dlg.ShowDialog()) {
        [System.Windows.MessageBox]::Show(
            "No config file selected. The editor will exit.",
            "No Config Selected", "OK", "Information") | Out-Null
        exit 0
    }
    $script:currentConfigFile = $dlg.FileName
}

$script:lastConfigError = $null

function Import-ConfigFile {
    param([string]$Path)
    try {
        $result = & ([scriptblock]::Create([System.IO.File]::ReadAllText($Path)))
        $script:lastConfigError = $null
        return $result
    } catch {
        $script:lastConfigError = [string]$_
        return $null
    }
}

$script:cfg = Import-ConfigFile $script:currentConfigFile
# Do NOT exit on parse error - the window opens and shows an error panel instead.
$script:isNewConfig = $false
# Back-fill any keys added in newer versions so the UI always has valid values.
# Merge-ConfigDefaults is defined later in this file; it is called after the window
# loads in Initialize-Controls, at which point all functions are defined.


# =============================================================================
# PSD1 serialisation helpers
# =============================================================================

function Format-PsdString {
    param([string]$s)
    if ($null -eq $s) { $s = '' }
    "'$($s.Replace("'", "''"))'"
}

function Format-PsdArray {
    param([string[]]$arr)
    $clean = @($arr | Where-Object { $_ })
    if ($clean.Count -eq 0) { return '@()' }
    "@($( ($clean | ForEach-Object { Format-PsdString $_ }) -join ', ' ))"
}

function Format-PsdHashtable {
    param([hashtable]$ht)
    if (-not $ht -or $ht.Count -eq 0) { return '@{}' }
    $lines = $ht.GetEnumerator() | Sort-Object Key |
             ForEach-Object { "            $(Format-PsdString $_.Key) = $(Format-PsdString $_.Value)" }
    "@{`n$($lines -join "`n")`n        }"
}

# =============================================================================
# Parse helpers (TextBox text → typed values)
# =============================================================================

function ConvertFrom-Lines {
    param([string]$text)
    @($text -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function ConvertFrom-KvLines {
    # Parses "key = value" lines into a hashtable; skips blank/comment lines
    param([string]$text)
    $ht = @{}
    foreach ($line in ($text -split "\r?\n")) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }
        $k = $line.Substring(0, $idx).Trim()
        $v = $line.Substring($idx + 1).Trim()
        if ($k) { $ht[$k] = $v }
    }
    return $ht
}

function ConvertTo-KvText {
    param([hashtable]$ht)
    if (-not $ht -or $ht.Count -eq 0) { return '' }
    ($ht.GetEnumerator() | Sort-Object Key |
     ForEach-Object { "$($_.Key) = $($_.Value)" }) -join "`r`n"
}

# =============================================================================
# WPF window XAML
# =============================================================================

$_rawXaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="AVD Live Dashboard Config Editor"
    Height="780" Width="1000"
    MinHeight="600" MinWidth="800"
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

    <!-- Label above each field -->
    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize"     Value="12"/>
      <Setter Property="FontWeight"   Value="SemiBold"/>
      <Setter Property="Foreground"   Value="{DynamicResource Avd.Fg.Label}"/>
      <Setter Property="Margin"       Value="0,12,0,4"/>
    </Style>

    <!-- Helper text below a field -->
    <Style x:Key="HintText" TargetType="TextBlock">
      <Setter Property="FontSize"   Value="11"/>
      <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Hint}"/>
      <Setter Property="Margin"     Value="0,2,0,0"/>
    </Style>

    <!-- Standard single-line TextBox -->
    <Style TargetType="TextBox">
      <Setter Property="Padding"          Value="6,5"/>
      <Setter Property="FontSize"         Value="13"/>
      <Setter Property="BorderBrush"      Value="{DynamicResource Avd.Border.Input}"/>
      <Setter Property="BorderThickness"  Value="1"/>
      <Setter Property="Background"       Value="{DynamicResource Avd.Input.Bg}"/>
      <Setter Property="Foreground"       Value="{DynamicResource Avd.Window.Fg}"/>
    </Style>

    <!-- Section divider label inside a tab -->
    <Style x:Key="SectionHeader" TargetType="TextBlock">
      <Setter Property="FontSize"     Value="13"/>
      <Setter Property="FontWeight"   Value="Bold"/>
      <Setter Property="Foreground"   Value="{DynamicResource Avd.Fg.Accent}"/>
      <Setter Property="Margin"       Value="0,20,0,6"/>
    </Style>

    <!-- Thin rule below section headers -->
    <Style x:Key="Rule" TargetType="Border">
      <Setter Property="BorderBrush"     Value="{DynamicResource Avd.Border.Std}"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Margin"          Value="0,0,0,10"/>
    </Style>

    <!-- Status-bar button (white outline on blue) -->
    <Style x:Key="StatusBtn" TargetType="Button">
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="Foreground"      Value="White"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush"     Value="White"/>
      <Setter Property="Padding"         Value="14,4"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#1A5FA8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Header action button (dark blue, rounded) -->
    <Style x:Key="ActionBtn" TargetType="Button">
      <Setter Property="Background"      Value="{DynamicResource Avd.Btn.Save.Hover}"/>
      <Setter Property="Foreground"      Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="14,6"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="{DynamicResource Avd.Btn.Save.Press}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Tab item style -->
    <Style TargetType="TabItem">
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding"    Value="14,7"/>
      <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Secondary}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="TabBorder" Background="Transparent"
                    BorderThickness="0,0,0,3" BorderBrush="Transparent"
                    Padding="{TemplateBinding Padding}" Margin="0,0,2,0" Cursor="Hand">
              <ContentPresenter ContentSource="Header"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="TabBorder" Property="BorderBrush" Value="{DynamicResource Avd.Fg.Accent}"/>
                <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Accent}"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="TabBorder" Property="Background" Value="{DynamicResource Avd.Hover.Bg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Small action button (blue) - used in Run Commands tab -->
    <Style x:Key="SmallActionBtn" TargetType="Button" BasedOn="{StaticResource ActionBtn}">
      <Setter Property="Padding"    Value="10,4"/>
      <Setter Property="FontSize"   Value="11"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>

    <!-- Default CheckBox foreground (WPF Fluent overrides inherited foreground without this) -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Avd.Window.Fg}"/>
    </Style>

    <!-- ListBox and items (Run Commands panel) -->
    <Style TargetType="ListBox">
      <Setter Property="Background"  Value="{DynamicResource Avd.Card.Bg}"/>
      <Setter Property="Foreground"  Value="{DynamicResource Avd.Window.Fg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Avd.Border.Input}"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding"    Value="8,5"/>
      <Setter Property="FontSize"   Value="12"/>
      <Setter Property="Foreground" Value="{DynamicResource Avd.Window.Fg}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Hover.Bg}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Selected.Bg}"/>
                <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Selected}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Small neutral button (gray) - used in Run Commands tab -->
    <Style x:Key="SmallNeutralBtn" TargetType="Button">
      <Setter Property="Background"      Value="{DynamicResource Avd.Btn.Cancel.Bg}"/>
      <Setter Property="Foreground"      Value="{DynamicResource Avd.Fg.Label}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="10,4"/>
      <Setter Property="FontSize"        Value="11"/>
      <Setter Property="Cursor"          Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="{DynamicResource Avd.Btn.Cancel.Hover}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Background" Value="{DynamicResource Avd.Btn.Cancel.Bg}"/>
                <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Hint}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

  </Window.Resources>

  <DockPanel>

    <!-- ===== Status bar ===== -->
    <Border x:Name="StatusBar" DockPanel.Dock="Bottom" Background="{DynamicResource Avd.StatusBar.Bg}" Height="36">
      <Grid Margin="12,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="StatusText" Grid.Column="0"
                   Foreground="White" FontSize="12" VerticalAlignment="Center"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="SaveButton"  Content="Save"  Style="{StaticResource StatusBtn}" Margin="0,0,8,0"/>
          <Button x:Name="CloseButton" Content="Close" Style="{StaticResource StatusBtn}"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ===== Header ===== -->
    <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.Header.Bg}" Padding="20,12,20,12">
      <Border.Effect>
        <DropShadowEffect BlurRadius="6" ShadowDepth="1" Opacity="0.10" Color="#000000"/>
      </Border.Effect>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" VerticalAlignment="Center">
          <TextBlock Text="AVD Live Dashboard Config Editor"
                     FontSize="18" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"/>
          <TextBlock x:Name="FilePathText"
                     FontSize="11" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,2,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
            <TextBlock Text="Dark" FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}"
                       VerticalAlignment="Center" Margin="0,0,6,0"/>
            <ToggleButton x:Name="DarkToggle" Style="{StaticResource ToggleSwitch}"/>
          </StackPanel>
          <Button x:Name="NewButton" Content="New" Style="{StaticResource ActionBtn}" Margin="0,0,8,0"/>
          <Button x:Name="BrowseButton" Content="Browse / Open..." Style="{StaticResource ActionBtn}"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ===== Config parse error panel ===================================================
         Shown instead of (and disabling) the tab control when config.psd1 cannot be
         parsed. Displays the PS exception message (which includes line/char info) and
         provides two actions: open the file in Notepad to fix it, then Validate and
         Reload to re-parse and restore the normal editor UI without restarting.
    =================================================================================== -->
    <Border x:Name="ErrorPanel" DockPanel.Dock="Top" Background="#FFF0F0"
            BorderBrush="#C42B1C" BorderThickness="0,0,0,3"
            Visibility="Collapsed" Padding="20,14,20,16">
      <DockPanel>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal"
                    VerticalAlignment="Top" Margin="16,0,0,0">
          <Button x:Name="OpenNotepadBtn" Content="Open in Notepad"
                  Padding="12,6" Margin="0,0,8,0" FontSize="12" Cursor="Hand"
                  Foreground="{DynamicResource Avd.Fg.Label}" BorderThickness="0">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border x:Name="Bd" Background="{DynamicResource Avd.Btn.Cancel.Bg}" CornerRadius="4"
                        Padding="{TemplateBinding Padding}">
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
          <Button x:Name="RevalidateBtn" Content="Validate and Reload"
                  Padding="12,6" FontSize="12" Cursor="Hand"
                  Foreground="White" BorderThickness="0">
            <Button.Template>
              <ControlTemplate TargetType="Button">
                <Border x:Name="Bd" Background="{DynamicResource Avd.Btn.Save.Bg}" CornerRadius="4"
                        Padding="{TemplateBinding Padding}">
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
        <StackPanel>
          <TextBlock Text="&#x26A0;&#xFE0F;  Config file has syntax errors and could not be loaded"
                     FontSize="13" FontWeight="SemiBold" Foreground="#C42B1C"/>
          <TextBlock Text="Fix the errors shown below (line and character numbers are included), then click Validate and Reload. You can also open the file directly in Notepad."
                     FontSize="11" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,4,0,8" TextWrapping="Wrap"/>
          <TextBlock x:Name="ErrorDetailText"
                     FontFamily="Consolas" FontSize="11" Foreground="#A01010"
                     TextWrapping="Wrap"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ===== Tab control ===== -->
    <TabControl x:Name="MainTabControl" Margin="0" Background="{DynamicResource Avd.Window.Bg}" BorderThickness="0">

      <!-- ── Azure / General ── -->
      <TabItem Header="Azure">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="General"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Configuration Name"/>
            <TextBox x:Name="ConfigNameBox"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Display name shown in the config picker when multiple configs are present. Defaults to the filename (without .psd1) if left blank."/>

            <TextBlock Style="{StaticResource SectionHeader}" Text="Azure Connection" Margin="0,16,0,0"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Tenant ID"/>
            <TextBox x:Name="TenantIdBox"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Leave blank to use the default tenant for the signing-in account."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Subscription ID"/>
            <TextBox x:Name="SubscriptionIdBox"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Leave blank to use whichever subscription the context defaults to."/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Dashboard ── -->
      <TabItem Header="Dashboard">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="Dashboard"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Hidden Tabs"/>
            <TextBlock Style="{StaticResource HintText}" Margin="0,0,0,8"
                       Text="Checked tabs are hidden from the tab strip. These are enforced at the deployment level - hidden tabs cannot be re-enabled via the Settings UI."/>
            <CheckBox x:Name="HideTabPerHostPool"  Content="Per Host Pool"  Margin="0,3"/>
            <CheckBox x:Name="HideTabByRegion"     Content="By Region"      Margin="0,3"/>
            <CheckBox x:Name="HideTabSessionHosts" Content="Session Hosts"  Margin="0,3"/>
            <CheckBox x:Name="HideTabAzureFiles"   Content="Azure Files"    Margin="0,3"/>
            <CheckBox x:Name="HideTabMonitoring"   Content="Monitoring"     Margin="0,3"/>
            <CheckBox x:Name="HideTabImages"       Content="Images"         Margin="0,3"/>
            <CheckBox x:Name="HideTabInfra"        Content="Infrastructure" Margin="0,3"/>
            <CheckBox x:Name="HideTabAzureDevOps"  Content="Azure DevOps"   Margin="0,3"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Feature Visibility" Margin="0,16,0,0"/>
            <Border Style="{StaticResource Rule}"/>
            <CheckBox x:Name="HideSessionHistory"
                      Content="Hide Session History button"
                      Margin="0,6,0,0"/>
            <TextBlock Style="{StaticResource HintText}" Margin="20,2,0,0"
                       Text="When checked, the Session History button is hidden from session detail windows."/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── AVD Host Pools ── -->
      <TabItem Header="AVD Host Pools">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="AVD Host Pools"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Include RGs"/>
            <TextBox x:Name="AvdIncludeRGsBox" Height="80" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="One resource group per line. Wildcards supported (e.g. AVDCORE-*, *-PROD-RG). Leave blank to query all RGs in the subscription."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Exclude RGs"/>
            <TextBox x:Name="AvdExcludeRGsBox" Height="60" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Applied after Include RGs. Wildcards supported (e.g. *-UAT-*, *-TEST-*). Leave blank to exclude nothing."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Excluded Host Pools"/>
            <TextBox x:Name="ExcludedPoolsBox" Height="80" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="One host pool name per line (case-insensitive exact match)."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Low Priority Patterns"/>
            <TextBox x:Name="LowPriorityPatternsBox" Height="60" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Substring patterns (e.g. -UAT). Host pools matching these are sorted to the bottom."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Secondary Regions"/>
            <TextBox x:Name="SecondaryRegionsBox" Height="60" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Azure region names (e.g. francecentral). Rows are highlighted red when sessions run here."/>

            <CheckBox x:Name="SecondaryHighlightCheck"
                      Content="Secondary Region Highlight Enabled"
                      Margin="0,12,0,0"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Hidden Columns (Per Host Pool grid)"/>
            <TextBlock Style="{StaticResource HintText}" Margin="0,0,0,8"
                       Text="Checked columns are hidden from the Per Host Pool tab."/>
            <CheckBox x:Name="HideColHostPool"      Content="Host Pool"      Margin="0,3"/>
            <CheckBox x:Name="HideColWorkspace"     Content="Workspace"      Margin="0,3"/>
            <CheckBox x:Name="HideColVMRegion"      Content="VM Region"      Margin="0,3"/>
            <CheckBox x:Name="HideColImageVersion"  Content="Image Version"  Margin="0,3"/>
            <CheckBox x:Name="HideColHostPoolRG"    Content="Host Pool RG"   Margin="0,3"/>
            <CheckBox x:Name="HideColTotalVMs"      Content="Total VMs"      Margin="0,3"/>
            <CheckBox x:Name="HideColVMsOn"         Content="VMs On"         Margin="0,3"/>
            <CheckBox x:Name="HideColVMsOff"        Content="VMs Off"        Margin="0,3"/>
            <CheckBox x:Name="HideColActiveUsers"   Content="Active Users"   Margin="0,3"/>
            <CheckBox x:Name="HideColDisconnected"  Content="Disconnected"   Margin="0,3"/>
            <CheckBox x:Name="HideColTotalSessions" Content="Total Sessions" Margin="0,3"/>
            <CheckBox x:Name="HideColScalingPlan"   Content="Scaling Plan"   Margin="0,3"/>
            <CheckBox x:Name="HideColScope"         Content="Scope"          Margin="0,3"/>
            <CheckBox x:Name="HideColHPLocation"    Content="HP Location"    Margin="0,3"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="RG VM Count" Margin="0,16,0,0"/>
            <Border Style="{StaticResource Rule}"/>
            <CheckBox x:Name="ShowRGVMCountCheck"
                      Content="Compare RG VM count with session host count"
                      Margin="0,6,0,0"/>
            <TextBlock Style="{StaticResource HintText}" Margin="20,2,0,0"
                       Text="When checked, an extra ARM call per VM resource group counts all VMs in the RG and highlights mismatches in the RG VMs column. Uncheck to skip these queries and hide the column."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Scaling Exclude Tag" Margin="0,16,0,0"/>
            <TextBox x:Name="ScalingExcludeTagBox" Width="260" HorizontalAlignment="Left"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Azure VM tag name checked by Query Details on the Session Hosts tab to show scaling exclusion (presence only, value ignored). Default: ExcludeFromScaling"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Azure Files ── -->
      <TabItem Header="Azure Files">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="Azure Files"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Files RGs"/>
            <TextBox x:Name="FilesRGsBox" Height="80" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="One resource group per line. Wildcards supported (e.g. *-FILES-*, RG-AVD-*). Leave blank to scan all matching accounts in the subscription."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Storage Warning Threshold (%)"/>
            <TextBox x:Name="StorageWarningPctBox" Width="100" HorizontalAlignment="Left"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Range 1-100. Amber warning card appears when any share exceeds this percentage."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Storage Account Kinds"/>
            <TextBlock Style="{StaticResource HintText}" Margin="0,0,0,8"
                       Text="Include storage accounts of these kinds."/>
            <CheckBox x:Name="KindFileStorage" Content="FileStorage (premium file share accounts)" Margin="0,3"/>
            <CheckBox x:Name="KindStorageV2"   Content="StorageV2 (general-purpose v2 accounts)"  Margin="0,3"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Shadow / RDP ── -->
      <TabItem Header="Shadow / RDP">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="Shadow &amp; RDP"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Shadow Method"/>
            <ComboBox x:Name="ShadowMethodCombo" Width="200" HorizontalAlignment="Left" Padding="6,5">
              <ComboBoxItem Content="MSTSC" Tag="MSTSC"/>
              <ComboBoxItem Content="MSRA"  Tag="MSRA"/>
            </ComboBox>
            <TextBlock Style="{StaticResource HintText}"
                       Text="MSTSC = mstsc.exe (Remote Desktop, recommended). MSRA = msra.exe (Remote Assistance)."/>

            <CheckBox x:Name="ShadowUseIPCheck"
                      Content="Use IP address for Shadow / RDP connections (instead of DNS hostname)"
                      Margin="0,14,0,0"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Messaging ── -->
      <TabItem Header="Messaging">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="Messaging"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Default Message Title"/>
            <TextBox x:Name="MsgTitleBox"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Pre-populated title in the Send Message dialog."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Default Message Body"/>
            <TextBox x:Name="MsgBodyBox" Height="100" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Pre-populated body in the Send Message dialog."/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Network Ranges ── -->
      <TabItem Header="Network Ranges">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="Network Ranges"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Named Ranges"/>
            <TextBox x:Name="NetworkRangesBox" Height="200" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"
                     FontFamily="Consolas" FontSize="12"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="One entry per line: Label = CIDR,CIDR,...  (e.g. VPN = 10.100.0.0/16, 10.200.0.0/16)"/>

            <TextBlock Margin="0,12,0,0" TextWrapping="Wrap" Foreground="{DynamicResource Avd.Fg.Hint}" FontSize="12"
                       Text="Checked top-to-bottom, first match wins. Any private IP (RFC 1918) not matched is labelled Office. Everything else is Public. Leave empty to just use Office / Public defaults."/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Infrastructure ── -->
      <TabItem Header="Infrastructure">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="Infrastructure Servers"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Resource Groups"/>
            <TextBox x:Name="InfraRGsBox" Height="100" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="One resource group per line. Wildcards supported (e.g. RG-INFRA-*, *-SERVERS-*). Leave blank for an empty Infrastructure tab."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Exclude Patterns"/>
            <TextBox x:Name="InfraExcludeBox" Height="80" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="VM name substrings to exclude (case-insensitive). One per line."/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Images ── -->
      <TabItem Header="Images">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">

            <!-- General -->
            <TextBlock Style="{StaticResource SectionHeader}" Text="General"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Resource Groups"/>
            <TextBox x:Name="ImgRGsBox" Height="80" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="One resource group per line. Leave blank for an empty Images tab. Example: rg-weu-avdimages-prod"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Include Patterns"/>
            <TextBox x:Name="ImgIncludePatternsBox" Height="60" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="VM name substrings to include (case-insensitive). One per line. Leave blank to show all VMs in the configured resource groups. Example: AVDGI"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Refresh Interval (seconds)"/>
            <TextBox x:Name="ImgRefreshIntervalBox" Width="100" HorizontalAlignment="Left"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="How often the Images tab auto-refreshes. Default: 60"/>

            <!-- Create Image -->
            <TextBlock Style="{StaticResource SectionHeader}" Text="Create Image" Margin="0,16,0,0"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Gallery Resource Groups"/>
            <TextBox x:Name="ImgGalleryRGsBox" Height="60" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Resource groups to search for Shared Image Galleries in the Create Image dialog. One per line. Leave blank to search the entire subscription."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Preparation VM Sizes"/>
            <TextBox x:Name="ImgPrepVMSizesBox" Height="80" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="VM sizes offered in the Preparation VM Size dropdown (Create Image dialog). One per line. Example: Standard_D4s_v5"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Preparation VM Size Default"/>
            <ComboBox x:Name="ImgPrepVMSizeDefaultBox"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Size pre-selected by default. Populated from the sizes list above."/>

            <!-- Maintenance -->
            <TextBlock Style="{StaticResource SectionHeader}" Text="Maintenance" Margin="0,16,0,0"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Image Versions to Keep"/>
            <TextBox x:Name="ImgVersionsToKeepBox" Width="80" HorizontalAlignment="Left"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Number of image versions to retain per definition when using Clean Image Versions. Newest N are kept; older ones are deleted. Default: 5"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="BIS-F Path" Margin="0,12,0,4"/>
            <TextBox x:Name="ImgBisFPathBox"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Path to BIS-F on the preparation VM (e.g. C:\_source\Bis-F). Used by Create Image to run sealing. Default: C:\_source\Bis-F"/>

            <TextBlock Style="{StaticResource SectionHeader}" Text="Replication" Margin="0,16,0,0"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Replication Region 1"/>
            <TextBlock Style="{StaticResource HintText}" Text="Primary gallery replication region (e.g. westeurope). Required."/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="70"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="ImgRegion1Box" Grid.Column="0"/>
                <StackPanel Grid.Column="2">
                    <TextBlock Style="{StaticResource HintText}" Text="Replicas" Margin="0,0,0,2"/>
                    <TextBox x:Name="ImgRegion1ReplicasBox"/>
                </StackPanel>
            </Grid>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Replication Region 2" Margin="0,10,0,4"/>
            <TextBlock Style="{StaticResource HintText}" Text="Optional second replication region. Leave blank to use one region only."/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="70"/>
                </Grid.ColumnDefinitions>
                <TextBox x:Name="ImgRegion2Box" Grid.Column="0"/>
                <StackPanel Grid.Column="2">
                    <TextBlock Style="{StaticResource HintText}" Text="Replicas" Margin="0,0,0,2"/>
                    <TextBox x:Name="ImgRegion2ReplicasBox"/>
                </StackPanel>
            </Grid>

          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Azure DevOps ── -->
      <TabItem Header="Azure DevOps">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="Azure DevOps Pipelines"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Organisation URL"/>
            <TextBox x:Name="AdoOrgUrlBox"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Full URL to your Azure DevOps organisation and project. Format: https://dev.azure.com/&lt;organisation&gt;/&lt;project&gt;. Leave blank to disable the tab."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Refresh Interval (seconds)"/>
            <TextBox x:Name="AdoRefreshBox" Width="100" HorizontalAlignment="Left"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="How often the pipeline list auto-refreshes. Default: 30"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Profile Tools ── -->
      <TabItem Header="Profile Tools">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="Profile Tools (FSLogix)"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="File Share Name"/>
            <TextBox x:Name="FileShareNameBox"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="The Azure File Share name (e.g. fslogix)."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="File Share Sub-Path"/>
            <TextBox x:Name="FileShareSubPathBox"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Sub-path within the share where profile folders live. Leave blank if profiles are at the share root."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Exclude Storage Accounts"/>
            <TextBox x:Name="ExcludeStorageBox" Height="60" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Storage account short names to exclude from profile tool tabs. One per line."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Storage Account Share Map"/>
            <TextBox x:Name="StorageShareMapBox" Height="100" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"
                     TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Format: accountname = \\server\share  (one entry per line)"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Region Labels"/>
            <TextBox x:Name="RegionLabelsBox" Height="80" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"
                     TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Format: substr = Label  (e.g. uks = UK South). One entry per line."/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Storage Account Pairs"/>
            <TextBox x:Name="StoragePairsBox" Height="80" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12"
                     TextWrapping="NoWrap"
                     ToolTip="Format: PairName = account1, account2  (one pair per line)"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Named pairs for one-click multi-account selection in Profile Tools. Format: PairName = account1, account2  (one pair per line)"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Log Analytics ── -->
      <TabItem Header="Log Analytics">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="Log Analytics"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Workspace Resource ID"/>
            <TextBox x:Name="LawWorkspaceIdBox"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Full ARM resource ID of the Log Analytics workspace that receives AVD session host performance data (CPU / Memory / Disk from the Perf table).&#x0a;Leave blank to disable the CPU %, Mem %, and Disk % columns in the Session Hosts tab.&#x0a;Example: /subscriptions/00000000-.../resourceGroups/RG-LOGS/providers/Microsoft.OperationalInsights/workspaces/my-law"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Permissions Checker ── -->
      <TabItem Header="Permissions">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="24,16,24,24">
            <TextBlock Style="{StaticResource SectionHeader}" Text="Permissions Checker"/>
            <Border Style="{StaticResource Rule}"/>

            <TextBlock Style="{StaticResource FieldLabel}" Text="Log Analytics RGs"/>
            <TextBox x:Name="LogAnalyticsRGsBox" Height="80" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
            <TextBlock Style="{StaticResource HintText}"
                       Text="Resource groups containing the Log Analytics workspaces used by AVD Insights. Wildcards supported (e.g. RG-LOG-*).&#x0a;Used by check-permissions.ps1 to scope the Log Analytics Reader role check.&#x0a;Leave blank to check all resource groups in the subscription."/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <!-- ── Run Commands ── -->
      <TabItem Header="Run Commands">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="220"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <!-- Left: command list + action buttons -->
          <Border Grid.Column="0" BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,1,0" Background="{DynamicResource Avd.Card.Bg}">
            <DockPanel Margin="12,16,12,12">
              <TextBlock DockPanel.Dock="Top" Text="Commands"
                         FontSize="13" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}" Margin="0,0,0,8"/>
              <StackPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
                <UniformGrid Columns="2" Margin="0,0,0,4">
                  <Button x:Name="RcAddBtn"    Content="Add"
                          Style="{StaticResource SmallActionBtn}" Margin="0,0,3,0"/>
                  <Button x:Name="RcRemoveBtn" Content="Remove"
                          Style="{StaticResource SmallNeutralBtn}"/>
                </UniformGrid>
                <UniformGrid Columns="2">
                  <Button x:Name="RcUpBtn"   Content="Move Up"
                          Style="{StaticResource SmallNeutralBtn}" Margin="0,0,3,0"/>
                  <Button x:Name="RcDownBtn" Content="Move Down"
                          Style="{StaticResource SmallNeutralBtn}"/>
                </UniformGrid>
              </StackPanel>
              <ListBox x:Name="RcList" BorderThickness="1" BorderBrush="{DynamicResource Avd.Border.Input}"
                       ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                       Padding="2"/>
            </DockPanel>
          </Border>

          <!-- Right: edit panel -->
          <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="RcEditPanel" Margin="24,16,24,24" IsEnabled="False">
              <TextBlock Style="{StaticResource SectionHeader}" Text="Edit Command"/>
              <Border Style="{StaticResource Rule}"/>

              <TextBlock Style="{StaticResource FieldLabel}" Text="Name"/>
              <TextBox x:Name="RcNameBox"/>
              <TextBlock Style="{StaticResource HintText}"
                         Text="Label shown in the right-click Run Command picker."/>

              <TextBlock Style="{StaticResource FieldLabel}" Text="Description"/>
              <TextBox x:Name="RcDescBox" Height="60" AcceptsReturn="True"
                       VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
              <TextBlock Style="{StaticResource HintText}"
                         Text="One-line explanation shown below the list when this command is selected."/>

              <TextBlock x:Name="RcScriptLabel" Style="{StaticResource FieldLabel}" Text="Script"/>
              <TextBox x:Name="RcScriptBox" Height="220" AcceptsReturn="True" AcceptsTab="True"
                       FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
              <TextBlock x:Name="RcScriptHint" Style="{StaticResource HintText}"
                         Text="PowerShell executed on the target VM via Invoke-AzVMRunCommand."/>
            </StackPanel>
          </ScrollViewer>
        </Grid>
      </TabItem>

    </TabControl>
  </DockPanel>
</Window>
'@
$_rawXaml = $_rawXaml -replace '<!-- THEME_SLOT -->', ''
[xml]$xaml = $_rawXaml
$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [Windows.Markup.XamlReader]::Load($reader)

function Switch-EditorTheme {
    param([bool]$Dark)
    $_tf = if ($Dark) { 'dark' } else { 'light' }
    $_tc = Get-Content -Raw -Path (Join-Path $PSScriptRoot "..\data\$_tf-theme.xaml") -ErrorAction Stop
    $_rdXaml = "<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$_tc</ResourceDictionary>"
    $_rd = [Windows.Markup.XamlReader]::Parse($_rdXaml)
    $win.Resources.MergedDictionaries.Clear()
    $win.Resources.MergedDictionaries.Add($_rd)
}

Switch-EditorTheme $_editDark

# Named control references
$filePathText         = $win.FindName('FilePathText')
$statusText           = $win.FindName('StatusText')
$saveButton           = $win.FindName('SaveButton')
$closeButton          = $win.FindName('CloseButton')
$browseButton         = $win.FindName('BrowseButton')
$newButton            = $win.FindName('NewButton')
$statusBar            = $win.FindName('StatusBar')
$darkToggle           = $win.FindName('DarkToggle')

# General
$configNameBox        = $win.FindName('ConfigNameBox')

# Azure
$tenantIdBox          = $win.FindName('TenantIdBox')
$subscriptionIdBox    = $win.FindName('SubscriptionIdBox')

# Dashboard
$hideTabPerHostPool   = $win.FindName('HideTabPerHostPool')
$hideTabByRegion      = $win.FindName('HideTabByRegion')
$hideTabSessionHosts  = $win.FindName('HideTabSessionHosts')
$hideTabAzureFiles    = $win.FindName('HideTabAzureFiles')
$hideTabMonitoring    = $win.FindName('HideTabMonitoring')
$hideTabInfra         = $win.FindName('HideTabInfra')
$hideSessionHistory   = $win.FindName('HideSessionHistory')

# AVD Host Pools
$avdIncludeRGsBox     = $win.FindName('AvdIncludeRGsBox')
$avdExcludeRGsBox     = $win.FindName('AvdExcludeRGsBox')
$excludedPoolsBox     = $win.FindName('ExcludedPoolsBox')
$lowPriorityBox       = $win.FindName('LowPriorityPatternsBox')
$secondaryRegionsBox  = $win.FindName('SecondaryRegionsBox')
$secondaryHighlight   = $win.FindName('SecondaryHighlightCheck')
$hideColHostPool      = $win.FindName('HideColHostPool')
$hideColWorkspace     = $win.FindName('HideColWorkspace')
$hideColVMRegion      = $win.FindName('HideColVMRegion')
$hideColImageVersion  = $win.FindName('HideColImageVersion')
$hideColHostPoolRG    = $win.FindName('HideColHostPoolRG')
$hideColTotalVMs      = $win.FindName('HideColTotalVMs')
$hideColVMsOn         = $win.FindName('HideColVMsOn')
$hideColVMsOff        = $win.FindName('HideColVMsOff')
$hideColActiveUsers   = $win.FindName('HideColActiveUsers')
$hideColDisconnected  = $win.FindName('HideColDisconnected')
$hideColTotalSessions = $win.FindName('HideColTotalSessions')
$hideColScalingPlan   = $win.FindName('HideColScalingPlan')
$hideColScope         = $win.FindName('HideColScope')
$hideColHPLocation    = $win.FindName('HideColHPLocation')
$showRGVMCountCheck   = $win.FindName('ShowRGVMCountCheck')
$scalingExcludeTagBox = $win.FindName('ScalingExcludeTagBox')

# Azure Files
$filesRGsBox          = $win.FindName('FilesRGsBox')
$storageWarningPctBox = $win.FindName('StorageWarningPctBox')
$kindFileStorage      = $win.FindName('KindFileStorage')
$kindStorageV2        = $win.FindName('KindStorageV2')

# Shadow / RDP
$shadowMethodCombo    = $win.FindName('ShadowMethodCombo')
$shadowUseIPCheck     = $win.FindName('ShadowUseIPCheck')

# Messaging
$msgTitleBox          = $win.FindName('MsgTitleBox')
$msgBodyBox           = $win.FindName('MsgBodyBox')

# Network Ranges
$networkRangesBox     = $win.FindName('NetworkRangesBox')

# Infrastructure
$infraRGsBox          = $win.FindName('InfraRGsBox')
$infraExcludeBox      = $win.FindName('InfraExcludeBox')

# Images
$imgRGsBox              = $win.FindName('ImgRGsBox')
$imgIncludePatternsBox  = $win.FindName('ImgIncludePatternsBox')
$imgRefreshIntervalBox  = $win.FindName('ImgRefreshIntervalBox')
$imgGalleryRGsBox       = $win.FindName('ImgGalleryRGsBox')
$imgPrepVMSizesBox           = $win.FindName('ImgPrepVMSizesBox')
$imgPrepVMSizeDefaultBox     = $win.FindName('ImgPrepVMSizeDefaultBox')

# Refresh the default ComboBox whenever the sizes list is edited
$imgPrepVMSizesBox.Add_TextChanged({
    $sizes = @($imgPrepVMSizesBox.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($sizes.Count -eq 0) { $sizes = @('Standard_D2s_v5','Standard_D4s_v5','Standard_D8s_v5') }
    $prev = [string]$imgPrepVMSizeDefaultBox.SelectedItem
    $imgPrepVMSizeDefaultBox.ItemsSource  = $sizes
    $imgPrepVMSizeDefaultBox.SelectedItem = if ($prev -in $sizes) { $prev } else { $sizes | Select-Object -First 1 }
})
$imgVersionsToKeepBox        = $win.FindName('ImgVersionsToKeepBox')
$imgBisFPathBox              = $win.FindName('ImgBisFPathBox')
$imgRegion1Box               = $win.FindName('ImgRegion1Box')
$imgRegion1ReplicasBox       = $win.FindName('ImgRegion1ReplicasBox')
$imgRegion2Box               = $win.FindName('ImgRegion2Box')
$imgRegion2ReplicasBox       = $win.FindName('ImgRegion2ReplicasBox')

$hideTabImages        = $win.FindName('HideTabImages')

# Azure DevOps
$adoOrgUrlBox         = $win.FindName('AdoOrgUrlBox')
$adoRefreshBox        = $win.FindName('AdoRefreshBox')
$hideTabAzureDevOps   = $win.FindName('HideTabAzureDevOps')

# Profile Tools
$fileShareNameBox     = $win.FindName('FileShareNameBox')
$fileShareSubPathBox  = $win.FindName('FileShareSubPathBox')
$excludeStorageBox    = $win.FindName('ExcludeStorageBox')
$storageShareMapBox   = $win.FindName('StorageShareMapBox')
$regionLabelsBox      = $win.FindName('RegionLabelsBox')
$storagePairsBox      = $win.FindName('StoragePairsBox')

# Log Analytics
$lawWorkspaceIdBox    = $win.FindName('LawWorkspaceIdBox')

# Permissions Checker
$logAnalyticsRGsBox   = $win.FindName('LogAnalyticsRGsBox')

# Run Commands
$rcList               = $win.FindName('RcList')
$rcEditPanel          = $win.FindName('RcEditPanel')
$rcNameBox            = $win.FindName('RcNameBox')
$rcDescBox            = $win.FindName('RcDescBox')
$rcScriptBox          = $win.FindName('RcScriptBox')
$rcScriptLabel        = $win.FindName('RcScriptLabel')
$rcScriptHint         = $win.FindName('RcScriptHint')
$rcAddBtn             = $win.FindName('RcAddBtn')
$rcRemoveBtn          = $win.FindName('RcRemoveBtn')
$rcUpBtn              = $win.FindName('RcUpBtn')
$rcDownBtn            = $win.FindName('RcDownBtn')

# =============================================================================
# New-DefaultConfig  - returns a blank config hashtable with sensible defaults
# =============================================================================

function New-DefaultConfig {
    @{
        Name  = ''
        Azure = @{
            TenantId       = ''
            SubscriptionId = ''
        }
        Dashboard = @{
            HiddenTabs = @()
        }
        AzureFiles = @{
            FilesRGs            = @()
            StorageWarningPct   = 90
            StorageAccountKinds = @('FileStorage', 'StorageV2')
        }
        AVDHostPools = @{
            IncludeRGs                      = @()
            ExcludeRGs                      = @()
            LowPriorityPatterns             = @()
            SecondaryRegions                = @()
            SecondaryRegionHighlightEnabled = $true
            ExcludedHostPools               = @()
            HiddenColumns                   = @()
            ScalingExcludeTag               = 'ExcludeFromScaling'
        }
        ShadowRDP = @{
            ShadowMethod = 'MSTSC'
            ShadowUseIP  = $true
        }
        Messaging = @{
            DefaultTitle = 'Message from IT Support'
            DefaultBody  = 'Please save your work and log off when you are done.'
        }
        NetworkRanges = @{
            VPN = @()
        }
        ProfileTools = @{
            StorageAccountShareMap = @{}
            ExcludeStorage         = @()
            FileShareName          = 'fslogix'
            FileShareSubPath       = ''
            RegionLabels           = @{}
        }
        LogAnalytics = @{
            WorkspaceResourceId = ''
        }
        PermissionsChecker = @{
            LogAnalyticsRGs = @()
        }
        InfrastructureServers = @{
            ResourceGroups  = @()
            ExcludePatterns = @()
        }
        Images = @{
            ResourceGroups         = @()
            IncludePatterns        = @()
            RefreshIntervalSeconds = 60
            GalleryRGs             = @()
            PrepVMSizes            = @('Standard_D2s_v5', 'Standard_D4s_v5', 'Standard_D8s_v5')
            PrepVMSizeDefault      = 'Standard_D4s_v5'
            ImageVersionsToKeep    = 5
            BisFPath               = 'C:\_source\Bis-F'
            ReplicationRegion1         = 'westeurope'
            ReplicationRegion1Replicas = 1
            ReplicationRegion2         = ''
            ReplicationRegion2Replicas = 1
        }
        AzureDevOps = @{
            OrganisationUrl        = ''
            RefreshIntervalSeconds = 30
        }
    }
}

# Recursively merges $defaults into $config, adding any keys that are missing.
# Existing values in $config are never overwritten — only absent keys are filled in.
function Merge-ConfigDefaults {
    param([hashtable]$Config, [hashtable]$Defaults)
    foreach ($key in $Defaults.Keys) {
        if (-not $Config.Contains($key)) {
            $Config[$key] = $Defaults[$key]
        } elseif ($Config[$key] -is [hashtable] -and $Defaults[$key] -is [hashtable]) {
            Merge-ConfigDefaults -Config $Config[$key] -Defaults $Defaults[$key]
        }
    }
}

# =============================================================================
# Initialize-Controls  - fill all controls from a parsed config hashtable
# =============================================================================

function Set-CheckedState {
    param([System.Windows.Controls.CheckBox]$cb, [bool]$value)
    $cb.IsChecked = $value
}

function Initialize-Controls {
    param([hashtable]$c)

    # Header
    $filePathText.Text = $script:currentConfigFile

    # General
    $configNameBox.Text = if ($c.ContainsKey('Name')) { [string]$c.Name } else { '' }

    # Azure
    $tenantIdBox.Text       = [string]$c.Azure.TenantId
    $subscriptionIdBox.Text = [string]$c.Azure.SubscriptionId

    # Dashboard - HiddenTabs
    $hiddenTabs = @($c.Dashboard.HiddenTabs | Where-Object { $_ })
    Set-CheckedState $hideTabPerHostPool   ($hiddenTabs -contains 'Per Host Pool')
    Set-CheckedState $hideTabByRegion      ($hiddenTabs -contains 'By Region')
    Set-CheckedState $hideTabSessionHosts  ($hiddenTabs -contains 'Session Hosts')
    Set-CheckedState $hideTabAzureFiles    ($hiddenTabs -contains 'Azure Files')
    Set-CheckedState $hideTabMonitoring    ($hiddenTabs -contains 'Monitoring')
    Set-CheckedState $hideTabImages        ($hiddenTabs -contains 'Images')
    Set-CheckedState $hideTabInfra         ($hiddenTabs -contains 'Infrastructure')
    Set-CheckedState $hideTabAzureDevOps   ($hiddenTabs -contains 'Azure DevOps')

    # Dashboard - Feature Visibility
    Set-CheckedState $hideSessionHistory ([bool]$c.Dashboard.HideSessionHistory)

    # AVD Host Pools
    $avdIncludeRGsBox.Text    = (@($c.AVDHostPools.IncludeRGs       | Where-Object { $_ }) -join "`r`n")
    $avdExcludeRGsBox.Text    = (@($c.AVDHostPools.ExcludeRGs       | Where-Object { $_ }) -join "`r`n")
    $excludedPoolsBox.Text    = (@($c.AVDHostPools.ExcludedHostPools | Where-Object { $_ }) -join "`r`n")
    $lowPriorityBox.Text      = (@($c.AVDHostPools.LowPriorityPatterns | Where-Object { $_ }) -join "`r`n")
    $secondaryRegionsBox.Text = (@($c.AVDHostPools.SecondaryRegions  | Where-Object { $_ }) -join "`r`n")
    Set-CheckedState $secondaryHighlight ([bool]$c.AVDHostPools.SecondaryRegionHighlightEnabled)

    $hiddenCols = @($c.AVDHostPools.HiddenColumns | Where-Object { $_ })
    Set-CheckedState $hideColHostPool      ($hiddenCols -contains 'Host Pool')
    Set-CheckedState $hideColWorkspace     ($hiddenCols -contains 'Workspace')
    Set-CheckedState $hideColVMRegion      ($hiddenCols -contains 'VM Region')
    Set-CheckedState $hideColImageVersion  ($hiddenCols -contains 'Image Version')
    Set-CheckedState $hideColHostPoolRG    ($hiddenCols -contains 'Host Pool RG')
    Set-CheckedState $hideColTotalVMs      ($hiddenCols -contains 'Total VMs')
    Set-CheckedState $hideColVMsOn         ($hiddenCols -contains 'VMs On')
    Set-CheckedState $hideColVMsOff        ($hiddenCols -contains 'VMs Off')
    Set-CheckedState $hideColActiveUsers   ($hiddenCols -contains 'Active Users')
    Set-CheckedState $hideColDisconnected  ($hiddenCols -contains 'Disconnected')
    Set-CheckedState $hideColTotalSessions ($hiddenCols -contains 'Total Sessions')
    Set-CheckedState $hideColScalingPlan   ($hiddenCols -contains 'Scaling Plan')
    Set-CheckedState $hideColScope         ($hiddenCols -contains 'Scope')
    Set-CheckedState $hideColHPLocation    ($hiddenCols -contains 'HP Location')

    $_rgVmShow = if ($null -ne $c.AVDHostPools.ShowRGVMCount) { [bool]$c.AVDHostPools.ShowRGVMCount } else { $true }
    Set-CheckedState $showRGVMCountCheck $_rgVmShow
    $scalingExcludeTagBox.Text = if ($c.AVDHostPools.ScalingExcludeTag) { [string]$c.AVDHostPools.ScalingExcludeTag } else { 'ExcludeFromScaling' }

    # Azure Files
    $filesRGsBox.Text          = (@($c.AzureFiles.FilesRGs | Where-Object { $_ }) -join "`r`n")
    $storageWarningPctBox.Text = [string]$c.AzureFiles.StorageWarningPct
    $kinds = @($c.AzureFiles.StorageAccountKinds | Where-Object { $_ })
    Set-CheckedState $kindFileStorage ($kinds -contains 'FileStorage')
    Set-CheckedState $kindStorageV2   ($kinds -contains 'StorageV2')

    # Shadow / RDP
    $method = [string]$c.ShadowRDP.ShadowMethod
    $shadowMethodCombo.SelectedIndex = if ($method -eq 'MSRA') { 1 } else { 0 }
    Set-CheckedState $shadowUseIPCheck ([bool]$c.ShadowRDP.ShadowUseIP)

    # Messaging
    $msgTitleBox.Text = [string]$c.Messaging.DefaultTitle
    $msgBodyBox.Text  = [string]$c.Messaging.DefaultBody

    # Network Ranges - convert array of @{ Label; Ranges } to "Label = cidr, cidr" lines
    $networkRangesBox.Text = (@(
        foreach ($entry in @($c.NetworkRanges)) {
            if (-not $entry.Label -or -not $entry.Ranges) { continue }
            $cidrs = @($entry.Ranges | Where-Object { $_ }) -join ', '
            "$($entry.Label) = $cidrs"
        }
    ) -join "`r`n")

    # Infrastructure
    $infraRGsBox.Text     = (@($c.InfrastructureServers.ResourceGroups  | Where-Object { $_ }) -join "`r`n")
    $infraExcludeBox.Text = (@($c.InfrastructureServers.ExcludePatterns | Where-Object { $_ }) -join "`r`n")

    # Images
    $imgRGsBox.Text             = (@($c.Images.ResourceGroups  | Where-Object { $_ }) -join "`r`n")
    $imgIncludePatternsBox.Text = (@($c.Images.IncludePatterns | Where-Object { $_ }) -join "`r`n")
    $imgRefreshIntervalBox.Text = if ([int]$c.Images.RefreshIntervalSeconds -gt 0) { [string][int]$c.Images.RefreshIntervalSeconds } else { '60' }
    $imgGalleryRGsBox.Text         = (@($c.Images.GalleryRGs      | Where-Object { $_ }) -join "`r`n")
    $imgPrepVMSizesBox.Text        = (@($c.Images.PrepVMSizes     | Where-Object { $_ }) -join "`r`n")
    $sizes = @($imgPrepVMSizesBox.Text -split "`r`n|`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($sizes.Count -eq 0) { $sizes = @('Standard_D2s_v5','Standard_D4s_v5','Standard_D8s_v5') }
    $imgPrepVMSizeDefaultBox.ItemsSource  = $sizes
    $default = if ($c.Images.PrepVMSizeDefault) { [string]$c.Images.PrepVMSizeDefault } else { 'Standard_D4s_v5' }
    $imgPrepVMSizeDefaultBox.SelectedItem = if ($default -in $sizes) { $default } else { $sizes | Select-Object -First 1 }
    $imgVersionsToKeepBox.Text     = if ([int]$c.Images.ImageVersionsToKeep -gt 0) { [string][int]$c.Images.ImageVersionsToKeep } else { '5' }
    $imgBisFPathBox.Text           = if ($c.Images.BisFPath) { [string]$c.Images.BisFPath } else { 'C:\_source\Bis-F' }
    $imgRegion1Box.Text            = if ($c.Images.ReplicationRegion1) { [string]$c.Images.ReplicationRegion1 } else { '' }
    $imgRegion1ReplicasBox.Text    = if ([int]$c.Images.ReplicationRegion1Replicas -gt 0) { [string][int]$c.Images.ReplicationRegion1Replicas } else { '1' }
    $imgRegion2Box.Text            = if ($c.Images.ReplicationRegion2) { [string]$c.Images.ReplicationRegion2 } else { '' }
    $imgRegion2ReplicasBox.Text    = if ([int]$c.Images.ReplicationRegion2Replicas -gt 0) { [string][int]$c.Images.ReplicationRegion2Replicas } else { '1' }


    # Azure DevOps
    $adoOrgUrlBox.Text  = [string]$c.AzureDevOps.OrganisationUrl
    $adoRefreshBox.Text = if ([int]$c.AzureDevOps.RefreshIntervalSeconds -gt 0) {
        [string][int]$c.AzureDevOps.RefreshIntervalSeconds } else { '30' }

    # Profile Tools
    $fileShareNameBox.Text    = [string]$c.ProfileTools.FileShareName
    $fileShareSubPathBox.Text = [string]$c.ProfileTools.FileShareSubPath
    $excludeStorageBox.Text   = (@($c.ProfileTools.ExcludeStorage | Where-Object { $_ }) -join "`r`n")
    $storageShareMapBox.Text  = ConvertTo-KvText $c.ProfileTools.StorageAccountShareMap
    $regionLabelsBox.Text     = ConvertTo-KvText $c.ProfileTools.RegionLabels
    $storagePairsBox.Text     = if ($c.ProfileTools.StorageAccountPairs -and $c.ProfileTools.StorageAccountPairs.Count -gt 0) {
        ($c.ProfileTools.StorageAccountPairs.GetEnumerator() | ForEach-Object {
            "$($_.Key) = $($_.Value -join ', ')"
        }) -join "`r`n"
    } else { '' }

    # Log Analytics
    $lawWorkspaceIdBox.Text   = [string]$c.LogAnalytics.WorkspaceResourceId

    # Permissions Checker
    $logAnalyticsRGsBox.Text  = (@($c.PermissionsChecker.LogAnalyticsRGs | Where-Object { $_ }) -join "`r`n")
}

if ($script:cfg) {
    Merge-ConfigDefaults -Config $script:cfg -Defaults (New-DefaultConfig)
    Initialize-Controls $script:cfg
}

# Error panel controls
$errorPanel      = $win.FindName('ErrorPanel')
$errorDetailText = $win.FindName('ErrorDetailText')
$revalidateBtn   = $win.FindName('RevalidateBtn')
$openNotepadBtn  = $win.FindName('OpenNotepadBtn')
$mainTabControl  = $win.FindName('MainTabControl')

# Show error panel on startup if config failed to parse
if (-not $script:cfg) {
    $errorPanel.Visibility    = [System.Windows.Visibility]::Visible
    $errorDetailText.Text     = $script:lastConfigError
    $mainTabControl.IsEnabled = $false
    $saveButton.IsEnabled     = $false
    $filePathText.Text        = $script:currentConfigFile
}

# Re-parse the current file and restore the normal UI if successful
$revalidateBtn.Add_Click({
    $newCfg = Import-ConfigFile $script:currentConfigFile
    if ($newCfg) {
        $script:cfg = $newCfg
        $script:isNewConfig = $false
        Merge-ConfigDefaults -Config $script:cfg -Defaults (New-DefaultConfig)
        Initialize-Controls $script:cfg
        $errorPanel.Visibility    = [System.Windows.Visibility]::Collapsed
        $mainTabControl.IsEnabled = $true
        $saveButton.IsEnabled     = $true
        $statusText.Foreground    = [System.Windows.Media.Brushes]::White
        $statusText.Text          = "Config loaded successfully."
    } else {
        $errorDetailText.Text = $script:lastConfigError
    }
})

# Open the config file in Notepad so the user can fix syntax errors directly
$openNotepadBtn.Add_Click({
    Start-Process 'notepad.exe' -ArgumentList "`"$script:currentConfigFile`""
})

# =============================================================================
# Run Commands tab  -  edit data\run-commands.psd1
# =============================================================================

$script:rcFile     = Join-Path $PSScriptRoot '..\data\run-commands.psd1'
$script:rcCommands = New-Object System.Collections.ArrayList
$script:rcSelIdx   = -1
$script:rcLoading  = $false

function Import-RunCommands {
    if (-not (Test-Path $script:rcFile)) { return }
    try {
        $rc = & ([scriptblock]::Create([System.IO.File]::ReadAllText($script:rcFile)))
        $_scriptsDir = Join-Path (Split-Path $script:rcFile) 'runcommands'
        foreach ($cmd in $rc.Commands) {
            $_script = [string]$cmd.Script
            $_scriptFile = $null
            if ($cmd.ScriptFile) {
                $_scriptFile = [string]$cmd.ScriptFile
                $_path = Join-Path $_scriptsDir $cmd.ScriptFile
                if (Test-Path $_path) { $_script = [System.IO.File]::ReadAllText($_path) }
            }
            [void]$script:rcCommands.Add(@{
                Name        = [string]$cmd.Name
                Description = [string]$cmd.Description
                Script      = $_script
                ScriptFile  = $_scriptFile
            })
        }
    } catch { <# silently ignore parse errors #> }
}

function Sync-RcListBox {
    param([int]$SelectIndex = -1)
    $script:rcLoading = $true
    $rcList.Items.Clear()
    foreach ($cmd in $script:rcCommands) { [void]$rcList.Items.Add([string]$cmd.Name) }
    if ($SelectIndex -ge 0 -and $SelectIndex -lt $rcList.Items.Count) {
        $rcList.SelectedIndex = $SelectIndex
    }
    $script:rcLoading = $false
}

function Save-RcCurrentEdits {
    if ($script:rcSelIdx -lt 0 -or $script:rcSelIdx -ge $script:rcCommands.Count) { return }
    $script:rcCommands[$script:rcSelIdx].Name        = $rcNameBox.Text.Trim()
    $script:rcCommands[$script:rcSelIdx].Description = $rcDescBox.Text
    if (-not $script:rcCommands[$script:rcSelIdx].ScriptFile) {
        $script:rcCommands[$script:rcSelIdx].Script  = $rcScriptBox.Text
    }
}

function Set-RcEntry {
    param([int]$Index)
    $script:rcSelIdx = $Index
    if ($Index -lt 0 -or $Index -ge $script:rcCommands.Count) {
        $rcEditPanel.IsEnabled = $false
        $rcNameBox.Text   = ''
        $rcDescBox.Text   = ''
        $rcScriptBox.Text = ''
        $rcScriptBox.IsReadOnly = $false
        $rcScriptBox.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Avd.Input.Bg')
        $rcScriptLabel.Text = 'Script'
        $rcScriptHint.Text  = 'PowerShell executed on the target VM via Invoke-AzVMRunCommand.'
        return
    }
    $rcEditPanel.IsEnabled = $true
    $cmd = $script:rcCommands[$Index]
    $rcNameBox.Text   = $cmd.Name
    $rcDescBox.Text   = $cmd.Description
    if ($cmd.ScriptFile) {
        $rcScriptBox.Text       = $cmd.ScriptFile
        $rcScriptBox.IsReadOnly = $true
        $rcScriptBox.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Avd.AltRow.Bg')
        $rcScriptLabel.Text = 'Script File'
        $rcScriptHint.Text  = "Loaded from: data\runcommands\$($cmd.ScriptFile)"
    } else {
        $rcScriptBox.Text       = $cmd.Script
        $rcScriptBox.IsReadOnly = $false
        $rcScriptBox.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'Avd.Input.Bg')
        $rcScriptLabel.Text = 'Script'
        $rcScriptHint.Text  = 'PowerShell executed on the target VM via Invoke-AzVMRunCommand.'
    }
}

function Save-RunCommandsFile {
    if (-not (Test-Path ([System.IO.Path]::GetDirectoryName($script:rcFile)))) { return }
    Save-RcCurrentEdits
    $entries = @($script:rcCommands | ForEach-Object {
        $n = ([string]$_.Name)        -replace "'", "''"
        $d = ([string]$_.Description) -replace "'", "''"
        if ($_.ScriptFile) {
            $sf = ([string]$_.ScriptFile) -replace "'", "''"
            "        @{`r`n            Name        = '$n'`r`n            Description = '$d'`r`n            ScriptFile  = '$sf'`r`n        }"
        } else {
            $s = ([string]$_.Script)  -replace "'", "''"
            "        @{`r`n            Name        = '$n'`r`n            Description = '$d'`r`n            Script      = '$s'`r`n        }"
        }
    })
    $body = if ($entries.Count -gt 0) { $entries -join "`r`n" } else { '' }
    $out = @"
#
# run-commands.psd1  -  Predefined Run Commands for the Session Hosts tab
#
# Each entry in the Commands array appears as a selectable item in the
# right-click "Run Command..." picker on the Session Hosts grid.
#
# Fields (all required):
#   Name        - Display label shown in the picker list
#   Description - One-line explanation shown below the list when selected
#   Script      - PowerShell code executed on the target VM via Invoke-AzVMRunCommand
#   ScriptFile  - (optional) .ps1 filename in data\runcommands\ (overrides Script)
#
# Order is preserved - commands appear in the picker exactly as listed here.
# Add, remove, or reorder entries freely; no script changes are needed.
#

@{
    Commands = @(
$body
    )
}
"@
    [System.IO.File]::WriteAllText($script:rcFile, $out, [System.Text.Encoding]::UTF8)
}

# ── Event handlers ──

$rcList.Add_SelectionChanged({
    if ($script:rcLoading) { return }
    Save-RcCurrentEdits
    Set-RcEntry $rcList.SelectedIndex
})

# Update the ListBox item name in real-time as the user types in the Name field
$rcNameBox.Add_TextChanged({
    if ($script:rcLoading) { return }
    $idx = $script:rcSelIdx
    if ($idx -lt 0 -or $idx -ge $rcList.Items.Count) { return }
    $script:rcLoading = $true
    $rcList.Items.RemoveAt($idx)
    $rcList.Items.Insert($idx, $rcNameBox.Text)
    $rcList.SelectedIndex = $idx
    $script:rcLoading = $false
})

$rcAddBtn.Add_Click({
    Save-RcCurrentEdits
    [void]$script:rcCommands.Add(@{ Name = 'New Command'; Description = ''; Script = '' })
    $newIdx = $script:rcCommands.Count - 1
    Sync-RcListBox $newIdx
    Set-RcEntry $newIdx
    $rcNameBox.Focus() | Out-Null
    $rcNameBox.SelectAll()
})

$rcRemoveBtn.Add_Click({
    $idx = $script:rcSelIdx
    if ($idx -lt 0) { return }
    $script:rcCommands.RemoveAt($idx)
    $newIdx = [Math]::Min($idx, $script:rcCommands.Count - 1)
    Sync-RcListBox $newIdx
    Set-RcEntry $newIdx
})

$rcUpBtn.Add_Click({
    $idx = $script:rcSelIdx
    if ($idx -le 0) { return }
    Save-RcCurrentEdits
    $tmp = $script:rcCommands[$idx - 1]
    $script:rcCommands[$idx - 1] = $script:rcCommands[$idx]
    $script:rcCommands[$idx]     = $tmp
    Sync-RcListBox ($idx - 1)
    Set-RcEntry ($idx - 1)
})

$rcDownBtn.Add_Click({
    $idx = $script:rcSelIdx
    if ($idx -lt 0 -or $idx -ge ($script:rcCommands.Count - 1)) { return }
    Save-RcCurrentEdits
    $tmp = $script:rcCommands[$idx + 1]
    $script:rcCommands[$idx + 1] = $script:rcCommands[$idx]
    $script:rcCommands[$idx]     = $tmp
    Sync-RcListBox ($idx + 1)
    Set-RcEntry ($idx + 1)
})

# ── Initial load (after handlers registered so SelectionChanged fires correctly) ──

Import-RunCommands
Sync-RcListBox
if ($script:rcCommands.Count -gt 0) {
    $rcList.SelectedIndex = 0   # triggers SelectionChanged -> Set-RcEntry 0
} else {
    Set-RcEntry -1
}

# =============================================================================
# Save-Config  - read all controls, validate, write PSD1
# =============================================================================

function Save-Config {

    # Validate numeric fields
    $swp = 0
    if (-not [int]::TryParse($storageWarningPctBox.Text.Trim(), [ref]$swp) -or $swp -lt 1 -or $swp -gt 100) {
        $statusText.Foreground = [System.Windows.Media.Brushes]::Yellow
        $statusText.Text = "Storage Warning % must be a whole number between 1 and 100."
        return
    }

    # Validate text fields that are inserted into PSD1 single-quoted strings.
    # Characters like ' $ { } would break PSD1 syntax or cause unintended evaluation.
    $scalingTag = $scalingExcludeTagBox.Text.Trim()
    if ($scalingTag -match "['\$\{\}]") {
        $statusText.Foreground = [System.Windows.Media.Brushes]::Yellow
        $statusText.Text = "Scaling Exclude Tag cannot contain ' $ { } characters."
        return
    }

    # Collect arrays
    $hiddenTabs = @(
        if ($hideTabPerHostPool.IsChecked)  { 'Per Host Pool' }
        if ($hideTabByRegion.IsChecked)     { 'By Region' }
        if ($hideTabSessionHosts.IsChecked) { 'Session Hosts' }
        if ($hideTabAzureFiles.IsChecked)   { 'Azure Files' }
        if ($hideTabMonitoring.IsChecked)      { 'Monitoring' }
        if ($hideTabImages.IsChecked)          { 'Images' }
        if ($hideTabInfra.IsChecked)           { 'Infrastructure' }
        if ($hideTabAzureDevOps.IsChecked)     { 'Azure DevOps' }
    )

    # Feature visibility booleans
    $hideAdvSD      = ($hideSessionHistory.IsChecked -eq $true)
    $showRgVmCount  = ($showRGVMCountCheck.IsChecked -eq $true)

    $hiddenCols = @(
        if ($hideColHostPool.IsChecked)      { 'Host Pool' }
        if ($hideColWorkspace.IsChecked)     { 'Workspace' }
        if ($hideColVMRegion.IsChecked)      { 'VM Region' }
        if ($hideColImageVersion.IsChecked)  { 'Image Version' }
        if ($hideColHostPoolRG.IsChecked)    { 'Host Pool RG' }
        if ($hideColTotalVMs.IsChecked)      { 'Total VMs' }
        if ($hideColVMsOn.IsChecked)         { 'VMs On' }
        if ($hideColVMsOff.IsChecked)        { 'VMs Off' }
        if ($hideColActiveUsers.IsChecked)   { 'Active Users' }
        if ($hideColDisconnected.IsChecked)  { 'Disconnected' }
        if ($hideColTotalSessions.IsChecked) { 'Total Sessions' }
        if ($hideColScalingPlan.IsChecked)   { 'Scaling Plan' }
        if ($hideColScope.IsChecked)         { 'Scope' }
        if ($hideColHPLocation.IsChecked)    { 'HP Location' }
    )

    $kinds = @(
        if ($kindFileStorage.IsChecked) { 'FileStorage' }
        if ($kindStorageV2.IsChecked)   { 'StorageV2' }
    )

    $shadowMethod = if ($shadowMethodCombo.SelectedIndex -eq 1) { 'MSRA' } else { 'MSTSC' }
    $shadowUseIP  = ($shadowUseIPCheck.IsChecked -eq $true)
    $secHighlight = ($secondaryHighlight.IsChecked -eq $true)

    $saMap      = ConvertFrom-KvLines $storageShareMapBox.Text
    $regLabels  = ConvertFrom-KvLines $regionLabelsBox.Text

    $pairsHt = [ordered]@{}
    foreach ($line in ($storagePairsBox.Text -split "\r?\n")) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }
        $pairName = $line.Substring(0, $idx).Trim()
        $accounts  = ($line.Substring($idx + 1).Trim() -split '\s*,\s*') | Where-Object { $_ }
        if ($pairName -and $accounts.Count -ge 2) { $pairsHt[$pairName] = @($accounts) }
    }

    $adoOrgUrl  = $adoOrgUrlBox.Text.Trim()
    $adoRefresh = $adoRefreshBox.Text.Trim(); if (-not ($adoRefresh -match '^\d+$') -or [int]$adoRefresh -lt 1) { $adoRefresh = '30' }

    # Generate PSD1
    $psd1 = @"
#
# Environment configuration for AVD Live Dashboard and Profile Tools.
# Edit this file for each deployment - the scripts themselves do not need modification.
#
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
#

@{

    # Optional display name shown in the config picker when multiple configs are present.
    # Defaults to the filename (without .psd1) if omitted.
    Name = $(Format-PsdString $configNameBox.Text.Trim())

    # =========================================================================
    # Azure Connection - used by avd-live-dashboard.ps1
    # =========================================================================

    Azure = @{

        # Tenant ID to connect to on sign-in.
        # Leave as '' to use the default tenant for the signing-in account.
        TenantId = $(Format-PsdString $tenantIdBox.Text.Trim())

        # Subscription ID to set as active after sign-in.
        # Leave as '' to use whichever subscription the context defaults to.
        SubscriptionId = $(Format-PsdString $subscriptionIdBox.Text.Trim())
    }

    # =========================================================================
    # Dashboard - used by avd-live-dashboard.ps1
    # =========================================================================

    Dashboard = @{

        # Tabs to hide from the dashboard tab strip.
        # These are enforced at the deployment level - hidden tabs cannot be re-enabled via the Settings UI.
        # Valid names: 'Per Host Pool', 'By Region', 'Session Hosts', 'Azure Files', 'Monitoring', 'Images', 'Infrastructure', 'Azure DevOps'
        HiddenTabs = $(Format-PsdArray $hiddenTabs)

        # Hide the Session History button in Session Detail windows.
        # Set to `$true` to remove the button from the toolbar.
        HideSessionHistory = `$$([string]$hideAdvSD.ToString().ToLower())
    }

    # =========================================================================
    # Azure Files - used by avd-live-dashboard.ps1
    # =========================================================================

    AzureFiles = @{

        # Resource groups containing storage accounts to monitor.
        # Leave as @() to scan all matching accounts across the entire subscription.
        FilesRGs = $(Format-PsdArray (ConvertFrom-Lines $filesRGsBox.Text))

        # Percentage used at which the amber warning card appears on the dashboard.
        StorageWarningPct = $swp

        # Storage account kinds to include. FileStorage = premium, StorageV2 = general-purpose v2.
        StorageAccountKinds = $(Format-PsdArray $kinds)
    }

    # =========================================================================
    # AVD Host Pools - used by avd-live-dashboard.ps1
    # =========================================================================

    AVDHostPools = @{

        # Resource groups to INCLUDE when querying AVD host pools.
        # Leave as @() to query all resource groups in the subscription.
        IncludeRGs = $(Format-PsdArray (ConvertFrom-Lines $avdIncludeRGsBox.Text))

        # Resource groups to EXCLUDE from AVD queries. Applied after IncludeRGs.
        ExcludeRGs = $(Format-PsdArray (ConvertFrom-Lines $avdExcludeRGsBox.Text))

        # Host pool name patterns sorted to the bottom of the Per Host Pool tab.
        LowPriorityPatterns = $(Format-PsdArray (ConvertFrom-Lines $lowPriorityBox.Text))

        # Azure regions treated as secondary. Rows highlighted red when sessions run here.
        SecondaryRegions = $(Format-PsdArray (ConvertFrom-Lines $secondaryRegionsBox.Text))

        # Whether secondary region row highlighting is enabled by default.
        SecondaryRegionHighlightEnabled = `$$([string]$secHighlight.ToString().ToLower())

        # Host pools to exclude from all views and data queries.
        ExcludedHostPools = $(Format-PsdArray (ConvertFrom-Lines $excludedPoolsBox.Text))

        # Columns to hide in the Per Host Pool grid.
        # Valid names: 'Host Pool', 'Workspace', 'VM Region', 'Image Version',
        #              'Total VMs', 'VMs On', 'VMs Off', 'Active Users', 'Disconnected',
        #              'Total Sessions', 'Scaling Plan', 'Host Pool RG', 'Scope', 'HP Location'
        HiddenColumns = $(Format-PsdArray $hiddenCols)

        # Whether to query and display RG VM counts in the Per Host Pool tab.
        # Set to `$false to skip the RG VM count queries and hide the RG VMs column entirely.
        ShowRGVMCount = `$$([string]$showRgVmCount.ToString().ToLower())

        # Tag name checked on session host VMs to show scaling exclusion in the Session Hosts tab.
        # Query Details checks for this tag (presence only, value is ignored).
        ScalingExcludeTag = '$($scalingExcludeTagBox.Text.Trim())'
    }

    # =========================================================================
    # Shadow / RDP - used by avd-live-dashboard.ps1
    # =========================================================================

    ShadowRDP = @{

        # Shadow tool. 'MSTSC' = mstsc.exe (recommended). 'MSRA' = msra.exe.
        ShadowMethod = $(Format-PsdString $shadowMethod)

        # `$true = use VM private IP address. `$false = use DNS hostname.
        ShadowUseIP = `$$([string]$shadowUseIP.ToString().ToLower())
    }

    # =========================================================================
    # Messaging - used by avd-live-dashboard.ps1
    # =========================================================================

    Messaging = @{

        # Default title pre-populated in the Send Message dialog.
        DefaultTitle = $(Format-PsdString $msgTitleBox.Text)

        # Default body pre-populated in the Send Message dialog.
        DefaultBody = $(Format-PsdString $msgBodyBox.Text)
    }

    # =========================================================================
    # Network Ranges - used by avd-live-dashboard.ps1 (Session Detail)
    # =========================================================================

    # Named CIDR ranges - checked in order, first match wins.
    # Unmatched private IPs = Office, else Public.
    NetworkRanges = $(
        $nrLines = @(ConvertFrom-Lines $networkRangesBox.Text)
        $nrEntries = @(foreach ($nrl in $nrLines) {
            if ($nrl -match '^(.+?)\s*=\s*(.+)$') {
                $lbl = $Matches[1].Trim()
                $cidrs = @($Matches[2] -split '[,\s]+' | Where-Object { $_ })
                "@{ Label = $(Format-PsdString $lbl); Ranges = $(Format-PsdArray $cidrs) }"
            }
        })
        if ($nrEntries.Count -eq 0) { '@()' }
        else { "@(`n        $($nrEntries -join "`n        ")`n    )" }
    )

    # =========================================================================
    # FSLogix / Profile Tools - used by profile-tools.ps1
    # =========================================================================

    ProfileTools = @{

        # Storage accounts to check when searching for FSLogix profile folders.
        # Key = storage account short name, Value = full UNC path to the share.
        StorageAccountShareMap = $(Format-PsdHashtable $saMap)

        # Account names to exclude from profile tool tabs and scans.
        ExcludeStorage = $(Format-PsdArray (ConvertFrom-Lines $excludeStorageBox.Text))

        # Azure File Share name (must match the share name in the UNC paths above).
        FileShareName = $(Format-PsdString $fileShareNameBox.Text)

        # Sub-path within the file share where profile folders live.
        FileShareSubPath = $(Format-PsdString $fileShareSubPathBox.Text)

        # Maps a substring of a storage account name to a human-readable Azure region label.
        RegionLabels = $(Format-PsdHashtable $regLabels)

        # Named pairs of storage accounts for one-click multi-account selection in Profile Tools.
        # Key = display name shown on the pair button, Value = array of two storage account short names.
        # Leave as @{} to disable pair buttons.
        StorageAccountPairs = $(
            if ($pairsHt.Count -eq 0) { '@{}' }
            else {
                $pairLines = $pairsHt.GetEnumerator() | ForEach-Object {
                    $accArr = ($_.Value | ForEach-Object { "'$_'" }) -join ', '
                    "        '$($_.Key)' = @($accArr)"
                }
                "@{`n$($pairLines -join "`n")`n    }"
            }
        )
    }

    # =========================================================================
    # Log Analytics - used by avd-live-dashboard.ps1 (Session Hosts tab)
    # =========================================================================

    LogAnalytics = @{

        # Full ARM resource ID of the Log Analytics workspace that receives
        # AVD session host performance data (CPU / Memory / Disk from the Perf table).
        # Leave as '' to disable the CPU %, Mem %, and Disk % columns in the Session Hosts tab.
        WorkspaceResourceId = '$($lawWorkspaceIdBox.Text.Trim())'
    }

    # =========================================================================
    # Permissions Checker - used by scripts\check-permissions.ps1 only
    # =========================================================================

    PermissionsChecker = @{

        # Resource groups containing the Log Analytics workspaces used by AVD Insights.
        # Used only by check-permissions.ps1 to scope the Log Analytics Reader role check.
        # Leave as @() to check all resource groups in the subscription.
        LogAnalyticsRGs = $(Format-PsdArray (ConvertFrom-Lines $logAnalyticsRGsBox.Text))
    }

    # =========================================================================
    # Infrastructure Servers - used by avd-live-dashboard.ps1
    # =========================================================================

    InfrastructureServers = @{

        # Resource groups containing infrastructure VMs to display in the Infrastructure tab.
        # Leave as @() to show an empty tab.
        ResourceGroups = $(Format-PsdArray (ConvertFrom-Lines $infraRGsBox.Text))

        # VM name substrings to exclude from the Infrastructure tab (case-insensitive).
        # Leave as @() to include all VMs in the configured resource groups.
        ExcludePatterns = $(Format-PsdArray (ConvertFrom-Lines $infraExcludeBox.Text))
    }

    # =========================================================================
    # Images - used by scripts\tab-images.ps1 and scripts\create-image.ps1
    # =========================================================================

    Images = @{

        # Resource groups containing image VMs to display in the Images tab.
        ResourceGroups = $(Format-PsdArray (ConvertFrom-Lines $imgRGsBox.Text))

        # VM name substrings to include (case-insensitive). Leave as @() to show all VMs in the RGs.
        IncludePatterns = $(Format-PsdArray (ConvertFrom-Lines $imgIncludePatternsBox.Text))

        # How often the Images tab auto-refreshes (seconds). Default: 60
        RefreshIntervalSeconds = $(
            $imgRi = 0
            if ([int]::TryParse($imgRefreshIntervalBox.Text.Trim(), [ref]$imgRi) -and $imgRi -gt 0) { $imgRi } else { 60 }
        )

        # Resource groups to search for Shared Image Galleries in the Create Image dialog.
        GalleryRGs = $(Format-PsdArray (ConvertFrom-Lines $imgGalleryRGsBox.Text))

        # VM sizes offered in the Preparation VM Size dropdown in the Create Image dialog.
        PrepVMSizes = $(Format-PsdArray (ConvertFrom-Lines $imgPrepVMSizesBox.Text))

        # Size pre-selected by default. Default: 'Standard_D4s_v5'
        PrepVMSizeDefault = '$(([string]$imgPrepVMSizeDefaultBox.SelectedItem -replace "'","''"))'

        # Number of image versions to retain per definition when using Clean Image Versions.
        ImageVersionsToKeep = $(
            $imgVtk = 0
            if ([int]::TryParse($imgVersionsToKeepBox.Text.Trim(), [ref]$imgVtk) -and $imgVtk -gt 0) { $imgVtk } else { 5 }
        )

        # Full path to BIS-F on the preparation VM.
        BisFPath = '$(($imgBisFPathBox.Text.Trim() -replace "'","''"))'

        # Gallery image replication regions. Region2 is optional - leave blank to use one region only.
        ReplicationRegion1         = '$(($imgRegion1Box.Text.Trim() -replace "'","''"))'
        ReplicationRegion1Replicas = $(
            $r1c = 0
            if ([int]::TryParse($imgRegion1ReplicasBox.Text.Trim(), [ref]$r1c) -and $r1c -gt 0) { $r1c } else { 1 }
        )
        ReplicationRegion2         = '$(($imgRegion2Box.Text.Trim() -replace "'","''"))'
        ReplicationRegion2Replicas = $(
            $r2c = 0
            if ([int]::TryParse($imgRegion2ReplicasBox.Text.Trim(), [ref]$r2c) -and $r2c -gt 0) { $r2c } else { 1 }
        )

    }

    # =========================================================================
    # Azure DevOps - used by scripts\tab-azuredevops.ps1
    # =========================================================================

    AzureDevOps = @{

        # Full URL to your Azure DevOps organisation and project.
        # Format: 'https://dev.azure.com/<organisation>/<project>'
        # Leave as '' to disable the tab.
        OrganisationUrl = '$adoOrgUrl'

        # How often the pipeline list auto-refreshes (seconds). Default: 30
        RefreshIntervalSeconds = $adoRefresh
    }
}
"@

    # If this is a new config and the target file already exists, confirm or pick a new name
    if ($script:isNewConfig -and (Test-Path $script:currentConfigFile)) {
        $answer = [System.Windows.MessageBox]::Show(
            "The file '$($script:currentConfigFile)' already exists.`n`nOverwrite it?",
            'File Already Exists',
            'YesNoCancel', 'Warning')
        if ($answer -eq 'Cancel') { return }
        if ($answer -eq 'No') {
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Title            = "Save Config As"
            $dlg.Filter           = "Config Files (*.psd1)|*.psd1|All Files (*.*)|*.*"
            $dlg.DefaultExt       = '.psd1'
            $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($script:currentConfigFile)
            if (-not $dlg.ShowDialog() -or [string]::IsNullOrWhiteSpace($dlg.FileName)) { return }
            $script:currentConfigFile = $dlg.FileName
            $filePathText.Text = $script:currentConfigFile
        }
    }

    try {
        [System.IO.File]::WriteAllText($script:currentConfigFile, $psd1, [System.Text.Encoding]::UTF8)
        $script:isNewConfig = $false
        try { Save-RunCommandsFile } catch { <# non-critical - config.psd1 already saved #> }

        # Flash status bar green for 2.5 s then revert to blue
        $statusBar.Background  = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#107C10')
        $statusText.Foreground = [System.Windows.Media.Brushes]::White
        $statusText.Text       = "$([char]0x2713)  Saved  -  $($script:currentConfigFile)"

        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(2.5)
        $timer.Add_Tick({
            param($t, $e)
            $statusBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0078D4')
            $statusText.Text      = ''
            $t.Stop()
        })
        $timer.Start()
    } catch {
        $statusText.Foreground = [System.Windows.Media.Brushes]::Yellow
        $statusText.Text = "Save failed: $_"
    }
}

# =============================================================================
# Button handlers
# =============================================================================

$saveButton.Add_Click({ Save-Config })

$closeButton.Add_Click({ $win.Close() })

$darkToggle.IsChecked = $_editDark
$darkToggle.Add_Checked({
    try {
        if (-not (Test-Path $script:EditRegPath)) { New-Item $script:EditRegPath -Force | Out-Null }
        Set-ItemProperty -Path $script:EditRegPath -Name 'DarkTheme' -Value 1
    } catch {}
    Switch-EditorTheme $true
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        $v = 1; [void][Win32.DwmApiEC]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
    } catch {}
})
$darkToggle.Add_Unchecked({
    try {
        Set-ItemProperty -Path $script:EditRegPath -Name 'DarkTheme' -Value 0
    } catch {}
    Switch-EditorTheme $false
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        $v = 0; [void][Win32.DwmApiEC]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
    } catch {}
})

$browseButton.Add_Click({
    try {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title   = "Open Config File"
        $dlg.Filter  = "Config Files (*.psd1)|*.psd1|All Files (*.*)|*.*"
        $_initDir = try { [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($script:currentConfigFile)) } catch { '' }
        if (-not [string]::IsNullOrWhiteSpace($_initDir) -and (Test-Path -LiteralPath $_initDir)) {
            $dlg.InitialDirectory = $_initDir
        }

        $_shown = $false
        try { $_shown = $dlg.ShowDialog() } catch {
            $errorPanel.Visibility    = [System.Windows.Visibility]::Visible
            $errorDetailText.Text     = "Browse dialog error: $_"
            $mainTabControl.IsEnabled = $false
            $saveButton.IsEnabled     = $false
            return
        }
        if (-not $_shown) { return }

        $_path = [string]$dlg.FileName
        if ([string]::IsNullOrWhiteSpace($_path)) { return }

        $newCfg = Import-ConfigFile $_path
        $script:currentConfigFile = $_path
        $filePathText.Text = $script:currentConfigFile

        if (-not $newCfg) {
            $errorPanel.Visibility    = [System.Windows.Visibility]::Visible
            $errorDetailText.Text     = $script:lastConfigError
            $mainTabControl.IsEnabled = $false
            $saveButton.IsEnabled     = $false
            return
        }

        $script:isNewConfig = $false
        $script:cfg = $newCfg
        Merge-ConfigDefaults -Config $script:cfg -Defaults (New-DefaultConfig)
        Initialize-Controls $script:cfg
        $errorPanel.Visibility    = [System.Windows.Visibility]::Collapsed
        $mainTabControl.IsEnabled = $true
        $saveButton.IsEnabled     = $true
        $statusText.Foreground = [System.Windows.Media.Brushes]::White
        $statusText.Text = "Opened  -  $($script:currentConfigFile)"
    } catch {
        $errorPanel.Visibility    = [System.Windows.Visibility]::Visible
        $errorDetailText.Text     = "Unexpected error in Browse handler: $_`n$($_.ScriptStackTrace)"
        $mainTabControl.IsEnabled = $false
        $saveButton.IsEnabled     = $false
    }
})

$newButton.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title            = "Create New Config File"
    $dlg.Filter           = "Config Files (*.psd1)|*.psd1|All Files (*.*)|*.*"
    $dlg.DefaultExt       = '.psd1'
    $dlg.FileName         = 'config.psd1'
    $dlg.OverwritePrompt  = $false   # file doesn't exist yet, overwrite check is on Save
    $dlg.InitialDirectory = [System.IO.Path]::GetDirectoryName($script:currentConfigFile)

    if (-not $dlg.ShowDialog() -or [string]::IsNullOrWhiteSpace($dlg.FileName)) { return }

    $script:currentConfigFile = $dlg.FileName
    $script:isNewConfig = $true
    $script:cfg = New-DefaultConfig
    Initialize-Controls $script:cfg
    $statusText.Foreground = [System.Windows.Media.Brushes]::White
    $statusText.Text = "New config  -  $($script:currentConfigFile)  (not yet saved)"
})

# =============================================================================
# Window icon and dark title bar
# =============================================================================

try {
    $_iconPath = Join-Path $PSScriptRoot '..\data\avd-dashboard.ico'
    if (Test-Path $_iconPath) {
        $stream = [System.IO.File]::OpenRead((Resolve-Path $_iconPath).ProviderPath)
        $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create(
            $stream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $stream.Close()
    }
} catch {}

try {
    Add-Type -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);' -Name 'DwmApiEC' -Namespace 'Win32' -ErrorAction Stop
} catch {}
if ($_editDark) {
    $win.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
            $v = 1
            [void][Win32.DwmApiEC]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        } catch {}
    })
}

# =============================================================================
# Show window
# =============================================================================

$win.ShowDialog() | Out-Null
