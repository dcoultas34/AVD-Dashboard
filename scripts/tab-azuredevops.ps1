# =============================================================================
# tab-azuredevops.ps1  -  Azure DevOps Pipelines tab module
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Encapsulates everything needed for the Azure DevOps Pipelines tab in one file.
# Dot-source this file BEFORE the XAML string is built; the main script then
# injects $AzureDevOpsTab_Xaml into its XAML via a placeholder comment and calls
# the three public lifecycle functions:
#
#   Initialize-AzureDevOpsTab     - once, after $window is loaded
#   Invoke-AzureDevOpsTabTimer    - every second from the master DispatcherTimer
#   Reset-AzureDevOpsTab          - on subscription switch (triggers immediate refresh)
#
# AUTHENTICATION
# --------------
# Uses a Personal Access Token (PAT). The PAT is encrypted at rest using DPAPI
# via Export-Clixml and stored under:
#   %APPDATA%\AVDDashboard\ado-pat.xml
# The file is bound to the current Windows user/machine - no other user or
# machine can decrypt it. Enter the PAT via Settings > Azure DevOps PAT.
#
# DATA FLOW
# ---------
# The tab runs a dedicated background refresh (default 30 seconds) using a
# single persistent runspace. Each refresh cycle:
#   1. GET /_apis/pipelines - lists all pipeline definitions (id, name, folder)
#   2. GET /_apis/build/builds?$top=200 - lists recent pipeline runs
#   3. Merges run rows with pipeline metadata (folder, definition name)
#   Returns JSON string (PSCustomObject properties survive runspace boundary in PS5.1)
#
# UI LAYOUT
# ---------
# Left pane  - TreeView showing pipeline folders and definitions
# Right pane - DataGrid showing recent runs for the selected folder/pipeline
#              Columns: Pipeline, Run #, Status, Result, Branch, Queued, Duration,
#                       Triggered By
#
# ACTIONS (right-click context menu on runs grid / tree)
# -------
#   Run Pipeline  - opens a dialog: branch picker, parameters, stage checkboxes
#   Cancel Run    - PATCH /_apis/build/builds/{id}  body: {"status":"cancelling"}
#   Delete Run    - DELETE /_apis/build/builds/{id}
#   View Log      - GET /_apis/build/builds/{id}/logs, fetch each entry, show popup
#
# =============================================================================

# PSScriptAnalyzer flags $AzureDevOpsTab_Xaml as "assigned but never used"
# because it cannot see across the dot-source boundary into the calling script.
# This suppression attribute silences that false positive.
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'AzureDevOpsTab_Xaml',
    Justification = 'Exported to the calling script via dot-source')]
param()

# =============================================================================
# 1. XAML fragment
# =============================================================================

$AzureDevOpsTab_Xaml = @'
<TabItem Header="Azure DevOps"
         x:Name="AzureDevOpsTab"
         xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <DockPanel>

        <!-- Top bar -->
        <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.CostBar.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1" Padding="12,7">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>    <!-- 0: status text -->
                    <ColumnDefinition Width="Auto"/>    <!-- 1: Running tile -->
                    <ColumnDefinition Width="*"/>       <!-- 2: spacer -->
                    <ColumnDefinition Width="Auto"/>    <!-- 3: Set PAT button -->
                    <ColumnDefinition Width="Auto"/>    <!-- 4: Refresh button -->
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="ADOStatusText" Grid.Column="0"
                           VerticalAlignment="Center" FontSize="12" Foreground="#777"
                           Margin="0,0,12,0"/>

                <!-- Running Pipelines tile - sits immediately after the status text -->
                <Border x:Name="ADORunningTile" Grid.Column="1"
                        Background="{DynamicResource Avd.Card.Bg}" CornerRadius="4" Padding="8,3"
                        BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1"
                        Margin="0,0,0,0" VerticalAlignment="Center" Height="26">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock x:Name="ADORunningCount" Text="-"
                                   FontSize="14" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"
                                   VerticalAlignment="Center"/>
                        <TextBlock Text=" Running"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   VerticalAlignment="Center" Margin="4,0,0,0"/>
                    </StackPanel>
                </Border>

                <Button x:Name="ADOConfigurePATButton" Grid.Column="3"
                        Content="Set PAT"
                        Background="Transparent" BorderThickness="1" BorderBrush="{DynamicResource Avd.Border.Input}"
                        Foreground="{DynamicResource Avd.Fg.Secondary}" FontSize="11" Cursor="Hand" Padding="8,3" Margin="0,0,6,0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdPAT" Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}"
                                    CornerRadius="3" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdPAT" Property="Background" Value="#E8ECF0"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="ADORefreshButton" Grid.Column="4"
                        Content="Refresh"
                        Background="{DynamicResource Avd.Btn.Accent.Bg}" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand" Padding="12,3">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdAR" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdAR" Property="Background" Value="{DynamicResource Avd.Btn.Accent.Hover}"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdAR" Property="Background" Value="#003D6B"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>
        </Border>

        <!-- Bottom action bar -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.CostBar.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,1,0,0" Height="32">
            <TextBlock x:Name="ADOActionStatus"
                       Margin="12,0" FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}"
                       VerticalAlignment="Center" TextTrimming="CharacterEllipsis"
                       ToolTip="{Binding RelativeSource={RelativeSource Self}, Path=Text}"/>
        </Border>

        <!-- Main content: tree (left) + grid (right) -->
        <Grid>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="260" MinWidth="120"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Left: pipeline folder tree -->
            <Border Grid.Column="0" BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,1,0">
                <DockPanel>
                    <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.NearWhite.Bg}"
                            BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1" Padding="8,5">
                        <TextBox x:Name="ADOTreeFilter"
                                 FontSize="11" Padding="6,3"
                                 VerticalContentAlignment="Center"
                                 BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                                 Background="{DynamicResource Avd.Input.Bg}" Foreground="{DynamicResource Avd.Fg.Label}"
                                 ToolTip="Filter pipeline names"/>
                    </Border>
                    <TreeView x:Name="ADOFolderTree"
                              Background="{DynamicResource Avd.Card.Bg}" BorderThickness="0"
                              FontSize="12" Padding="4">
                        <TreeView.ItemContainerStyle>
                            <Style TargetType="TreeViewItem">
                                <Setter Property="IsExpanded" Value="True"/>
                                <Setter Property="Padding" Value="2,2"/>
                            </Style>
                        </TreeView.ItemContainerStyle>
                        <TreeView.ContextMenu>
                            <ContextMenu x:Name="ADOTreeContextMenu">
                                <MenuItem x:Name="ADOTreeMenuRun" Header="&#x25B6;  Run Pipeline"/>
                            </ContextMenu>
                        </TreeView.ContextMenu>
                    </TreeView>
                </DockPanel>
            </Border>

            <!-- Splitter -->
            <GridSplitter Grid.Column="1" Width="4"
                          HorizontalAlignment="Center" VerticalAlignment="Stretch"
                          Background="{DynamicResource Avd.Border.Std}" Cursor="SizeWE"/>

            <!-- Right: runs grid -->
            <DockPanel Grid.Column="2">
                <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.NearWhite.Bg}"
                        BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1" Padding="10,5">
                    <TextBlock x:Name="ADOSelectionLabel"
                               FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}"
                               Text="Select a pipeline or folder to view runs"
                               VerticalAlignment="Center"/>
                </Border>
                <DataGrid x:Name="ADORunsGrid"
                          AutoGenerateColumns="True" IsReadOnly="True"
                          SelectionMode="Single" SelectionUnit="FullRow"
                          GridLinesVisibility="Horizontal"
                          AlternationCount="2"
                          HeadersVisibility="Column"
                          CanUserReorderColumns="True" CanUserResizeColumns="True"
                          CanUserSortColumns="True" FontSize="12"
                          BorderThickness="0" Background="{DynamicResource Avd.Card.Bg}"
                          HorizontalScrollBarVisibility="Auto"
                          VerticalScrollBarVisibility="Auto">
                    <DataGrid.Resources>
                        <!-- Cell: replace ControlTemplate so Background=Transparent on selection works -->
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
                                    <Setter Property="Foreground" Value="#1F2937"/>
                                </Trigger>
                            </Style.Triggers>
                        </Style>
                        <!-- Row: alternating + hover + selection blue.
                             AlternatingRowBackground/RowBackground on the DataGrid use an
                             internal visual layer that overrides IsSelected triggers, so we
                             handle alternation here instead via AlternationIndex. -->
                        <Style TargetType="DataGridRow">
                            <Setter Property="Background" Value="{DynamicResource Avd.Card.Bg}"/>
                            <Style.Triggers>
                                <Trigger Property="ItemsControl.AlternationIndex" Value="1">
                                    <Setter Property="Background" Value="{DynamicResource Avd.NearWhite.Bg}"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter Property="Background" Value="{DynamicResource Avd.Hover.Bg}"/>
                                </Trigger>
                                <Trigger Property="IsSelected" Value="True">
                                    <Setter Property="Background" Value="#D0E7FA"/>
                                    <Setter Property="Foreground" Value="#1F2937"/>
                                </Trigger>
                            </Style.Triggers>
                        </Style>
                    </DataGrid.Resources>
                    <DataGrid.ColumnHeaderStyle>
                        <Style TargetType="DataGridColumnHeader">
                            <Setter Property="Background" Value="{DynamicResource Avd.ColHeader.Bg}"/>
                            <Setter Property="Foreground" Value="{DynamicResource Avd.ColHeader.Fg}"/>
                            <Setter Property="FontWeight" Value="SemiBold"/>
                            <Setter Property="FontSize" Value="12"/>
                            <Setter Property="Padding" Value="10,6"/>
                            <Setter Property="BorderBrush" Value="{DynamicResource Avd.ColHeader.Border}"/>
                            <Setter Property="BorderThickness" Value="0,0,1,1"/>
                        </Style>
                    </DataGrid.ColumnHeaderStyle>
                    <DataGrid.ContextMenu>
                        <ContextMenu x:Name="ADORunsContextMenu">
                            <MenuItem x:Name="ADOMenuRun"    Header="&#x25B6;  Run Pipeline"/>
                            <Separator/>
                            <MenuItem x:Name="ADOMenuCancel" Header="&#x23F9;  Cancel Run"/>
                            <MenuItem x:Name="ADOMenuDelete" Header="&#x1F5D1;  Delete Run"/>
                            <Separator/>
                            <MenuItem x:Name="ADOMenuLog"    Header="&#x1F4CB;  View Log"/>
                        </ContextMenu>
                    </DataGrid.ContextMenu>
                </DataGrid>
            </DockPanel>
        </Grid>
    </DockPanel>
</TabItem>
'@

# =============================================================================
# 2. PAT storage helpers (DPAPI via Export-Clixml)
#
# ─── How the PAT is stored ───────────────────────────────────────────────────
# The Personal Access Token is wrapped in a PSCredential object
# (username = 'ADO-PAT' as a label, password = the PAT as a SecureString).
# Export-Clixml serialises the SecureString using the Windows Data Protection
# API (DPAPI).  DPAPI binds the encryption to the current Windows user account
# AND the current machine - the resulting file:
#   • Cannot be decrypted by any other Windows user, even on the same machine.
#   • Cannot be copied to a different PC and decrypted there.
#   • Does NOT require the user to supply a separate password or key.
#   • Is as secure as the Windows user account itself.
#
# ─── File location ───────────────────────────────────────────────────────────
# The encrypted file is stored at:
#
#   %APPDATA%\AVDDashboard\ado-pat.xml
#
# On a typical Windows installation this resolves to:
#
#   C:\Users\<username>\AppData\Roaming\AVDDashboard\ado-pat.xml
#
# The directory is created automatically on first save if it does not exist.
# To revoke/reset the PAT, delete this file or clear the PAT via the
# "Set PAT" dialog (leave the PAT field blank and click Save).
#
# ─── How it is used for authentication ───────────────────────────────────────
# Azure DevOps REST API uses HTTP Basic Authentication.
# The Authorization header value is:  Basic <base64(':PAT')>
# Note the leading colon - ADO expects the format  username:password  where
# the username is intentionally empty and the password is the PAT.
# The PAT is loaded once at tab initialisation into $script:adoPat and rebuilt
# into a base64 header string each time an API call is made.
# =============================================================================

function _ADO_GetPatPath {
    # Returns the full path to the DPAPI-encrypted PAT credential file.
    # Location: %APPDATA%\AVDDashboard\ado-pat.xml
    # e.g.    : C:\Users\<username>\AppData\Roaming\AVDDashboard\ado-pat.xml
    # Uses AVDDashboard (no hyphen) - same folder as the SP credential stored
    # by avd-live-dashboard.ps1, so all credentials live in one place.
    Join-Path $env:APPDATA 'AVDDashboard\ado-pat.xml'
}

function _ADO_SavePat {
    # Encrypts the PAT using DPAPI and saves it to disk as a PSCredential XML.
    # The 'ADO-PAT' username is a human-readable label only - it is never sent
    # to Azure DevOps. Creates %APPDATA%\AVDDashboard\ if it does not exist.
    param([string]$Pat)
    $path = _ADO_GetPatPath
    $dir  = Split-Path $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $cred = [System.Management.Automation.PSCredential]::new(
        'ADO-PAT',
        (ConvertTo-SecureString $Pat -AsPlainText -Force)
    )
    $cred | Export-Clixml -Path $path -Force
}

function _ADO_LoadPat {
    # Loads and decrypts the stored PAT using DPAPI (via GetNetworkCredential).
    # Returns an empty string if the file does not exist or decryption fails
    # (e.g. the file was copied from a different machine or user profile).
    # Migration: if the old AVD-Dashboard\ado-pat.xml exists and the new path
    # does not, move the file silently so users are not re-prompted for their PAT.
    $path    = _ADO_GetPatPath
    $oldPath = Join-Path $env:APPDATA 'AVD-Dashboard\ado-pat.xml'
    if (-not (Test-Path $path) -and (Test-Path $oldPath)) {
        try {
            $dir = Split-Path $path
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Move-Item -Path $oldPath -Destination $path -Force
            Write-Log "[ADO] Migrated PAT from AVD-Dashboard to AVDDashboard folder"
        } catch {
            Write-Log "[ADO] WARN: Could not migrate PAT file: $_"
        }
    }
    if (-not (Test-Path $path)) { return '' }
    try {
        $cred = Import-Clixml -Path $path -ErrorAction Stop
        return $cred.GetNetworkCredential().Password
    } catch { return '' }
}

function _ADO_DeletePat {
    # Deletes the encrypted PAT file from disk, effectively clearing the stored token.
    # Called when the user leaves the PAT field blank and clicks Save in the
    # configuration dialog, or when they explicitly want to reset the credential.
    # To delete manually: remove %APPDATA%\AVDDashboard\ado-pat.xml
    $path = _ADO_GetPatPath
    if (Test-Path $path) { Remove-Item $path -Force }
}

function _ADO_GetAuthHeader {
    # Builds the HTTP Authorization header for Azure DevOps REST API calls.
    # Format: Basic <base64(':PAT')>  - colon prefix is mandatory (empty username).
    # Returns $null when no PAT is configured so callers can guard before API calls.
    # NOTE: Only used for on-thread calls (Run Pipeline dialog pre-flight fetches).
    #       Background runspace calls pass $b64 as a plain string and reconstruct
    #       the header inside the scriptblock to avoid hashtable serialisation issues
    #       across the PS5.1 runspace boundary (SessionStateProxy quirk).
    $pat = $script:adoPat
    if (-not $pat) { return $null }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    return @{ Authorization = "Basic $b64"; Accept = 'application/json' }
}

# =============================================================================
# 3. PAT configuration dialog
#
# Shown when the user clicks the "Set PAT" button in the tab toolbar.
# Collects three pieces of configuration in one place:
#   - Organisation URL  : the ADO org + project URL (persisted to registry)
#   - Personal Access Token : encrypted via DPAPI (see section 2)
#   - Auto-refresh interval : how often the pipeline list polls the ADO API
#
# On Save:
#   1. Interval is clamped to >= 10 s and written to HKCU registry.
#   2. If a PAT was entered, it is encrypted and saved; if blank, the stored
#      PAT is cleared (effectively disabling the tab).
#   3. If the URL changed, Reset-AzureDevOpsTab is called to clear state and
#      schedule an immediate re-fetch against the new org/project.
#   4. If both URL and PAT are now configured, Invoke-AzureDevOpsRefresh is
#      called immediately so the user sees data without waiting for the timer.
#
# Owner: $OwnerWindow must be the root WPF Window (not a TabItem or TabControl).
# Use [System.Windows.Window]::GetWindow($element) to get it from any child.
# =============================================================================

function Show-AdoRunningPopup {
    param([System.Windows.Window]$OwnerWindow)

    $running = @($script:adoLastRuns | Where-Object {
        [string]$_.'Status' -eq 'inProgress' -or [string]$_.'Status' -eq 'notStarted'
    })

    $dlg = New-Object System.Windows.Window
    $dlg.Title  = "Running Pipelines ($($running.Count))"
    $dlg.Width  = 780
    $dlg.Height = 420
    $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner  = $OwnerWindow
    $dlg.ResizeMode   = [System.Windows.ResizeMode]::CanResize
    $dlg.Background   = [System.Windows.Media.Brushes]::White
    try { Set-WindowIcon -Window $dlg -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}

    $sp = New-Object System.Windows.Controls.DockPanel
    $sp.LastChildFill = $true

    # Header
    $hdr = New-Object System.Windows.Controls.TextBlock
    $hdr.Text       = if ($running.Count -eq 0) { 'No pipelines currently running.' } else { "$($running.Count) pipeline(s) in progress" }
    $hdr.FontSize   = 13
    $hdr.FontWeight = [System.Windows.FontWeights]::SemiBold
    $hdr.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0,120,212)
    $hdr.Margin     = [System.Windows.Thickness]::new(16,14,16,10)
    [System.Windows.Controls.DockPanel]::SetDock($hdr, [System.Windows.Controls.Dock]::Top)
    [void]$sp.Children.Add($hdr)

    # Close button row
    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $btnRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $btnRow.Margin = [System.Windows.Thickness]::new(0,8,16,12)
    [System.Windows.Controls.DockPanel]::SetDock($btnRow, [System.Windows.Controls.Dock]::Bottom)
    $closeBtn = New-Object System.Windows.Controls.Button
    $closeBtn.Content = 'Close'; $closeBtn.Padding = [System.Windows.Thickness]::new(16,6,16,6)
    $closeBtn.FontSize = 12; $closeBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    $closeBtn.Add_Click({ $dlg.Close() })
    [void]$btnRow.Children.Add($closeBtn)
    [void]$sp.Children.Add($btnRow)

    if ($running.Count -gt 0) {
        $grid = New-Object System.Windows.Controls.DataGrid
        $grid.AutoGenerateColumns    = $false
        $grid.IsReadOnly             = $true
        $grid.CanUserSortColumns     = $true
        $grid.GridLinesVisibility    = [System.Windows.Controls.DataGridGridLinesVisibility]::Horizontal
        $grid.AlternationCount       = 2
        $grid.Margin                 = [System.Windows.Thickness]::new(8,0,8,0)
        $grid.FontSize               = 12
        $grid.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto

        foreach ($colDef in @(
            @{ Header = 'Pipeline';      Binding = 'Pipeline';      Width = 220 }
            @{ Header = 'Run #';         Binding = 'Run #';         Width = 60  }
            @{ Header = 'Status';        Binding = 'Status';        Width = 90  }
            @{ Header = 'Branch';        Binding = 'Branch';        Width = 130 }
            @{ Header = 'Queued';        Binding = 'Queued';        Width = 130 }
            @{ Header = 'Triggered By';  Binding = 'Triggered By';  Width = 140 }
        )) {
            $col = New-Object System.Windows.Controls.DataGridTextColumn
            $col.Header  = $colDef.Header
            $col.Binding = New-Object System.Windows.Data.Binding($colDef.Binding)
            $col.Width   = $colDef.Width
            [void]$grid.Columns.Add($col)
        }

        $dt = New-Object System.Data.DataTable
        foreach ($c in @('Pipeline','Run #','Status','Branch','Queued','Triggered By')) { [void]$dt.Columns.Add($c) }
        foreach ($r in $running) {
            $dr = $dt.NewRow()
            $dr['Pipeline']     = [string]$r.'Pipeline'
            $dr['Run #']        = [string]$r.'Run #'
            $dr['Status']       = [string]$r.'Status'
            $dr['Branch']       = [string]$r.'Branch'
            $dr['Queued']       = [string]$r.'Queued'
            $dr['Triggered By'] = [string]$r.'Triggered By'
            [void]$dt.Rows.Add($dr)
        }
        $grid.ItemsSource = $dt.DefaultView
        [void]$sp.Children.Add($grid)
    }

    $dlg.Content = $sp
    $dlg.ShowDialog() | Out-Null
}

function Show-AdoPatDialog {
    param([System.Windows.Window]$OwnerWindow)

    # Remember whether a PAT already exists so the blank-password-box logic
    # can distinguish "user left it blank intentionally" from "no PAT ever set".
    $hasCurrent = [bool]$script:adoPat

    $dlg = New-Object System.Windows.Window
    $dlg.Title  = 'Azure DevOps - Configuration'
    $dlg.Width  = 480
    $dlg.SizeToContent = [System.Windows.SizeToContent]::Height
    $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner  = $OwnerWindow
    $dlg.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dlg.Background = [System.Windows.Media.Brushes]::White
    try { Set-WindowIcon -Window $dlg -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text       = 'Azure DevOps Configuration'
    $title.FontSize   = 16
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    $title.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0, 120, 212)
    $title.Margin     = [System.Windows.Thickness]::new(0, 0, 0, 16)
    [void]$sp.Children.Add($title)

    # Organisation URL
    $urlLbl = New-Object System.Windows.Controls.TextBlock
    $urlLbl.Text     = 'Organisation URL'
    $urlLbl.FontSize = 12
    $urlLbl.FontWeight = [System.Windows.FontWeights]::SemiBold
    $urlLbl.Margin   = [System.Windows.Thickness]::new(0, 0, 0, 4)
    [void]$sp.Children.Add($urlLbl)

    $urlHint = New-Object System.Windows.Controls.TextBlock
    $urlHint.Text      = 'Full URL including organisation and project (e.g. https://dev.azure.com/contoso/MyProject).'
    $urlHint.FontSize  = 11
    $urlHint.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(140, 140, 140)
    $urlHint.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $urlHint.Margin    = [System.Windows.Thickness]::new(0, 0, 0, 6)
    [void]$sp.Children.Add($urlHint)

    $urlBox = New-Object System.Windows.Controls.TextBox
    $urlBox.Text         = $script:AdoOrgUrl
    $urlBox.FontSize     = 12
    $urlBox.Padding      = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $urlBox.BorderBrush  = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(200, 205, 211)
    $urlBox.BorderThickness = [System.Windows.Thickness]::new(1)
    $urlBox.Margin       = [System.Windows.Thickness]::new(0, 0, 0, 20)
    [void]$sp.Children.Add($urlBox)

    # Separator
    $sep = New-Object System.Windows.Controls.Separator
    $sep.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    [void]$sp.Children.Add($sep)

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text        = "Enter a Personal Access Token with at least Read permission on Build (Pipelines). The PAT is encrypted using your Windows account and stored locally - no one else can read it."
    $desc.FontSize    = 12
    $desc.Foreground  = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(80, 80, 80)
    $desc.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $desc.Margin      = [System.Windows.Thickness]::new(0, 0, 0, 16)
    [void]$sp.Children.Add($desc)

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text     = 'Personal Access Token'
    $lbl.FontSize = 12
    $lbl.FontWeight = [System.Windows.FontWeights]::SemiBold
    $lbl.Margin   = [System.Windows.Thickness]::new(0, 0, 0, 4)
    [void]$sp.Children.Add($lbl)

    $pwBox = New-Object System.Windows.Controls.PasswordBox
    $pwBox.FontSize         = 13
    $pwBox.Padding          = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $pwBox.BorderBrush      = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(200, 205, 211)
    $pwBox.BorderThickness  = [System.Windows.Thickness]::new(1)
    $pwBox.Margin           = [System.Windows.Thickness]::new(0, 0, 0, 4)
    if ($hasCurrent) { $pwBox.Password = $script:adoPat }
    [void]$sp.Children.Add($pwBox)

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text      = 'Leave blank and click Save to clear the stored PAT.'
    $hint.FontSize  = 11
    $hint.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(140, 140, 140)
    $hint.Margin    = [System.Windows.Thickness]::new(0, 0, 0, 20)
    [void]$sp.Children.Add($hint)

    # Refresh interval
    $sepR = New-Object System.Windows.Controls.Separator
    $sepR.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    [void]$sp.Children.Add($sepR)

    $intLbl = New-Object System.Windows.Controls.TextBlock
    $intLbl.Text     = 'Auto-refresh interval (seconds)'
    $intLbl.FontSize = 12
    $intLbl.FontWeight = [System.Windows.FontWeights]::SemiBold
    $intLbl.Margin   = [System.Windows.Thickness]::new(0, 0, 0, 4)
    [void]$sp.Children.Add($intLbl)

    $intBox = New-Object System.Windows.Controls.TextBox
    $intBox.Text         = [string]$script:AdoRefreshIntervalSeconds
    $intBox.FontSize     = 12
    $intBox.Padding      = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $intBox.Width        = 80
    $intBox.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $intBox.BorderBrush  = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(200, 205, 211)
    $intBox.BorderThickness = [System.Windows.Thickness]::new(1)
    $intBox.Margin       = [System.Windows.Thickness]::new(0, 0, 0, 4)
    [void]$sp.Children.Add($intBox)

    $intHint = New-Object System.Windows.Controls.TextBlock
    $intHint.Text      = 'Minimum 10 seconds. Default: 30.'
    $intHint.FontSize  = 11
    $intHint.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(140, 140, 140)
    $intHint.Margin    = [System.Windows.Thickness]::new(0, 0, 0, 16)
    [void]$sp.Children.Add($intHint)

    $errTxt = New-Object System.Windows.Controls.TextBlock
    $errTxt.FontSize   = 12
    $errTxt.Foreground = [System.Windows.Media.Brushes]::Red
    $errTxt.Margin     = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $errTxt.Visibility = [System.Windows.Visibility]::Collapsed
    [void]$sp.Children.Add($errTxt)

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation       = [System.Windows.Controls.Orientation]::Horizontal
    $btnRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right

    $cancelBtn = New-Object System.Windows.Controls.Button
    $cancelBtn.Content = 'Cancel'
    $cancelBtn.Padding = [System.Windows.Thickness]::new(16, 6, 16, 6)
    $cancelBtn.Margin  = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $cancelBtn.FontSize = 12
    $cancelBtn.Cursor  = [System.Windows.Input.Cursors]::Hand
    $cancelBtn.Add_Click({ $dlg.Close() })
    [void]$btnRow.Children.Add($cancelBtn)

    $saveBtn = New-Object System.Windows.Controls.Button
    $saveBtn.Content    = 'Save'
    $saveBtn.Padding    = [System.Windows.Thickness]::new(16, 6, 16, 6)
    $saveBtn.FontSize   = 12
    $saveBtn.Cursor     = [System.Windows.Input.Cursors]::Hand
    $saveBtn.Background = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0, 120, 212)
    $saveBtn.Foreground = [System.Windows.Media.Brushes]::White
    $saveBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    [void]$btnRow.Children.Add($saveBtn)
    [void]$sp.Children.Add($btnRow)

    $dlg.Content = $sp

    $saveBtn.Add_Click({
        $newUrl = $urlBox.Text.Trim()
        $pat    = $pwBox.Password.Trim()

        # Validate and apply refresh interval
        $newInterval = 30
        if ([int]::TryParse($intBox.Text.Trim(), [ref]$newInterval)) {
            if ($newInterval -lt 10) { $newInterval = 10 }
        } else { $newInterval = 30 }
        $script:AdoRefreshIntervalSeconds = $newInterval
        try {
            $regPath = 'HKCU:\Software\AVDDashboard'
            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
            Set-ItemProperty -Path $regPath -Name 'AdoRefreshInterval' -Value $newInterval
        } catch {}

        # Save PAT
        if ($pat) {
            try {
                _ADO_SavePat -Pat $pat
            } catch {
                $errTxt.Text = "Failed to save PAT: $_"
                $errTxt.Visibility = [System.Windows.Visibility]::Visible
                return
            }
            $script:adoPat = $pat
            $script:adoPipelineCache = @{}   # invalidate prefetch cache on PAT change
            Write-Log 'INFO [ADO] PAT saved and encrypted via DPAPI'
        } elseif (-not $hasCurrent) {
            # No PAT entered and none existed - that's fine, URL may still be updated
        } else {
            # Blank password box with existing PAT = clear it
            _ADO_DeletePat
            $script:adoPat = ''
            $script:adoPipelineCache = @{}   # invalidate prefetch cache on PAT clear
            Write-Log 'INFO [ADO] PAT cleared'
        }

        # Save and apply URL
        $urlChanged = ($newUrl -ne $script:AdoOrgUrl)
        $script:AdoOrgUrl = $newUrl
        if ($urlChanged) { $script:adoPipelineCache = @{} }
        try {
            $regPath = 'HKCU:\Software\AVDDashboard'
            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
            Set-ItemProperty -Path $regPath -Name 'AdoOrgUrl' -Value $newUrl
            Write-Log "INFO [ADO] Organisation URL saved: '$newUrl'"
        } catch {
            Write-Log "ERROR [ADO] Failed to save Organisation URL to registry: $_"
            $errTxt.Text = "Failed to save URL to registry: $_"
            $errTxt.Visibility = [System.Windows.Visibility]::Visible
        }

        # Trigger refresh
        if ($script:AdoOrgUrl -and $script:adoPat) {
            if ($script:ADOStatusText) { $script:ADOStatusText.Text = 'Configuration saved - refreshing...' }
            if ($urlChanged) { Reset-AzureDevOpsTab }
            Invoke-AzureDevOpsRefresh
        } elseif (-not $script:AdoOrgUrl) {
            if ($script:ADOStatusText) { $script:ADOStatusText.Text = 'Organisation URL not set' }
            if ($urlChanged) { Reset-AzureDevOpsTab }
        } else {
            if ($script:ADOStatusText) { $script:ADOStatusText.Text = 'PAT cleared - set a PAT to enable the tab' }
        }

        $dlg.Close()
    }.GetNewClosure())

    $dlg.ShowDialog() | Out-Null
}

# =============================================================================
# 4. Background refresh scriptblock
#
# Runs inside a persistent runspace (opened once in Initialize-AzureDevOpsTab,
# reused for every refresh cycle). Returning via BeginInvoke/EndInvoke.
#
# Variables injected via SessionStateProxy.SetVariable before each BeginInvoke:
#   AdoOrgUrl        - full org+project URL, e.g. 'https://dev.azure.com/org/project'
#   AdoAuthHeaderB64 - base64-encoded PAT string (":pat" encoded, no username)
#                      Passed as a plain string rather than a hashtable to avoid
#                      PS5.1 runspace boundary serialisation issues. The header
#                      hashtable is reconstructed inside the scriptblock.
#   AdoApiVersion    - ADO REST API version string, e.g. '7.1'
#   LogFile          - log file path (string), or $null when -EnableLogging not set
#
# Return value:
#   A JSON-compressed string containing:
#     Pipelines     - array of { Id, Name, Folder }
#     Runs          - array of run row objects (see column list in Step 2)
#     Timestamp     - ISO 8601 timestamp of the refresh
#     PipelineError - error message string from Step 1, or $null on success
#     RunError      - error message string from Step 2, or $null on success
#
# Why JSON? PSCustomObject properties are not reliably preserved across a PS5.1
# runspace boundary when returned from EndInvoke. Serialising to JSON and
# deserialising on the UI thread is the safe workaround.
#
# Error handling:
#   If Step 1 (pipeline definitions) fails, Step 2 (builds) is skipped entirely.
#   This prevents orphan run rows with no matching pipeline name (which would
#   appear as blank Pipeline cells and break the folder filter logic).
#   RunError is set to the same value as PipelineError so the timer's auth-error
#   detection works regardless of which field it checks.
# =============================================================================

$script:adoRefreshScript = {
    param()

    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ADO] Refresh started. OrgUrl=$AdoOrgUrl`r`n") } catch {} }

    # Ensure TLS 1.2 is active - required for all Azure REST API endpoints.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $apiVer    = $AdoApiVersion
    # Reconstruct the Authorization header inside the runspace. The base64 string
    # crosses the runspace boundary cleanly; a hashtable may not in PS5.1.
    $hdr       = @{ Authorization = "Basic $AdoAuthHeaderB64"; 'Content-Type' = 'application/json' }
    $pipelines = @()
    $runs      = @()
    $error1    = $null
    $error2    = $null

    # -- Step 1: Pipeline definitions -----------------------------------------
    # GET /_apis/pipelines returns the list of all pipeline definitions in the
    # project: id, name, and folder path. This is used to:
    #   a) Populate the TreeView (grouped by folder)
    #   b) Look up the friendly name + folder for each build run in Step 2
    try {
        $uri = "$AdoOrgUrl/_apis/pipelines?api-version=$apiVer"
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $raw = Invoke-WebRequest -Method GET -Uri $uri -Headers $hdr -UseBasicParsing -ErrorAction Stop
        $sw.Stop()
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] GET $uri -> $($raw.StatusCode) ($($sw.ElapsedMilliseconds)ms)`r`n") } catch {} }

        if ($raw.StatusCode -ge 400) { throw "HTTP $($raw.StatusCode)" }

        $resp      = $raw.Content | ConvertFrom-Json
        $pipeItems = @($resp.value)
        $pipelines = @($pipeItems | ForEach-Object {
            [PSCustomObject]@{
                Id     = [int]$_.id
                Name   = [string]$_.name
                Folder = if ([string]$_.folder -and [string]$_.folder -ne '\') {
                             ([string]$_.folder).TrimStart('\')
                         } else { '(root)' }
            }
        })
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ADO] Pipelines: $($pipelines.Count)`r`n") } catch {} }
    } catch {
        $error1 = "Pipeline list failed: $_"
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] ERROR [ADO] $error1`r`n") } catch {} }
    }

    # Build lookup: pipeline id -> definition
    $pipelineMap = @{}
    foreach ($p in $pipelines) { $pipelineMap[[int]$p.Id] = $p }

    # -- Step 2: Recent builds (skip if Step 1 failed - auth error etc) --------
    if ($error1) {
        $error2 = $error1   # propagate so timer detects 401 from either field
    }
    if (-not $error1) { try {  # skipped if Step 1 failed
        $uri = "$AdoOrgUrl/_apis/build/builds?`$top=200&api-version=$apiVer"
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $raw = Invoke-WebRequest -Method GET -Uri $uri -Headers $hdr -UseBasicParsing -ErrorAction Stop
        $sw.Stop()
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] GET $uri -> $($raw.StatusCode) ($($sw.ElapsedMilliseconds)ms)`r`n") } catch {} }

        if ($raw.StatusCode -ge 400) { throw "HTTP $($raw.StatusCode)" }

        $resp       = $raw.Content | ConvertFrom-Json
        $buildItems = @($resp.value)

        $runs = @($buildItems | ForEach-Object {
            $b       = $_
            $defId   = [int]$b.definition.id
            $defName = if ($pipelineMap.ContainsKey($defId)) { $pipelineMap[$defId].Name } else { [string]$b.definition.name }
            $folder  = if ($pipelineMap.ContainsKey($defId)) { $pipelineMap[$defId].Folder } else { '(root)' }

            $queued   = $null
            $duration = '-'
            if ($b.queueTime) {
                try {
                    $qt = [DateTime]$b.queueTime
                    $queued = $qt.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                    if ($b.finishTime) {
                        $ft   = [DateTime]$b.finishTime
                        $span = $ft - $qt
                        $duration = if ($span.TotalHours -ge 1) {
                            '{0}h {1}m' -f [int]$span.TotalHours, $span.Minutes
                        } else {
                            '{0}m {1}s' -f $span.Minutes, $span.Seconds
                        }
                    }
                } catch {}
            }

            [PSCustomObject]@{
                '_BuildId'     = [int]$b.id
                '_DefId'       = $defId
                '_Folder'      = $folder
                'Pipeline'     = $defName
                'Run #'        = [int]$b.id
                'Status'       = [string]$b.status
                'Result'       = if ($b.result) { [string]$b.result } else { '-' }
                'Branch'       = ([string]$b.sourceBranch) -replace '^refs/heads/', ''
                'Queued'       = if ($queued) { $queued } else { '-' }
                'Duration'     = $duration
                'Triggered By' = [string]$b.requestedFor.displayName
            }
        })
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [ADO] Builds: $($buildItems.Count)  Runs mapped: $($runs.Count)`r`n") } catch {} }
    } catch {
        $error2 = "Build list failed: $_"
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] ERROR [ADO] $error2`r`n") } catch {} }
    } }  # end if (-not $error1)

    # Serialize to JSON - PSCustomObject properties survive PS5.1 runspace boundary
    ConvertTo-Json -InputObject @{
        Pipelines     = $pipelines
        Runs          = $runs
        Timestamp     = (Get-Date).ToString('o')
        PipelineError = $error1
        RunError      = $error2
    } -Depth 5 -Compress
}

# =============================================================================
# 5. TreeView helpers
# =============================================================================

function _ADO_PopulateTree {
    param([object[]]$Pipelines, [string]$FilterText)

    # Capture which folders the user currently has open before wiping the tree.
    # This lets us restore the same expansion state after a data refresh so the
    # user does not lose their open folders every 30 seconds.
    # We only record folders that are explicitly expanded; all others default to
    # collapsed (the initial state when the tab first loads).
    if (-not $script:adoExpandedFolders) {
        $script:adoExpandedFolders = [System.Collections.Generic.HashSet[string]]::new()
    }
    foreach ($item in $script:ADOFolderTree.Items) {
        if ($item -is [System.Windows.Controls.TreeViewItem] -and $item.IsExpanded) {
            [void]$script:adoExpandedFolders.Add([string]$item.Header)
        } elseif ($item -is [System.Windows.Controls.TreeViewItem] -and -not $item.IsExpanded) {
            # Folder was explicitly collapsed by the user - remove from the set
            [void]$script:adoExpandedFolders.Remove([string]$item.Header)
        }
    }

    $script:ADOFolderTree.Items.Clear()
    if (-not $Pipelines -or $Pipelines.Count -eq 0) { return }

    $filter  = $FilterText.Trim().ToLower()
    $grouped = $Pipelines |
        Where-Object { -not $filter -or $_.Name.ToLower().Contains($filter) -or $_.Folder.ToLower().Contains($filter) } |
        Group-Object Folder |
        Sort-Object Name

    foreach ($grp in $grouped) {
        $folderName = $grp.Name

        $folderItem            = New-Object System.Windows.Controls.TreeViewItem
        $folderItem.Header     = $folderName
        $folderItem.Tag        = @{ Type = 'Folder'; Folder = $folderName }
        $folderItem.FontWeight = [System.Windows.FontWeights]::SemiBold
        # Restore expansion state: open if the user previously opened this folder,
        # collapsed by default on first load so the tree starts tidy.
        $folderItem.IsExpanded = $script:adoExpandedFolders.Contains($folderName)

        $folderItem.Add_Selected({
            param($s, $e)
            _ADO_OnTreeSelected -Tag $s.Tag
        })

        foreach ($pipe in ($grp.Group | Sort-Object Name)) {
            $pipeItem            = New-Object System.Windows.Controls.TreeViewItem
            $pipeItem.Header     = $pipe.Name
            $pipeItem.Tag        = @{ Type = 'Pipeline'; DefId = $pipe.Id; Name = $pipe.Name; Folder = $folderName }
            $pipeItem.FontWeight = [System.Windows.FontWeights]::Normal
            $pipeItem.Margin     = [System.Windows.Thickness]::new(4, 0, 0, 0)

            $pipeItem.Add_Selected({
                param($s, $e)
                _ADO_OnTreeSelected -Tag $s.Tag
            })

            [void]$folderItem.Items.Add($pipeItem)
        }

        [void]$script:ADOFolderTree.Items.Add($folderItem)
    }
}

function _ADO_OnTreeSelected {
    param([hashtable]$Tag)
    if (-not $Tag) { return }
    $script:adoSelectedTag = $Tag

    if ($Tag.Type -eq 'Folder') {
        $script:ADOSelectionLabel.Text = "Folder: $($Tag.Folder)"
        if ($script:adoRunsTable) {
            $folder = $Tag.Folder -replace "'", "''"
            $script:adoRunsTable.DefaultView.RowFilter = "[_Folder] = '$folder'"
        }
    } elseif ($Tag.Type -eq 'Pipeline') {
        $script:ADOSelectionLabel.Text = "Pipeline: $($Tag.Name)"
        if ($script:adoRunsTable) {
            # Use Convert() so the filter works regardless of whether _DefId is int/long/double/string
            $script:adoRunsTable.DefaultView.RowFilter = "Convert([_DefId], 'System.Int32') = $([int]$Tag.DefId)"
        }
    }
}

# =============================================================================
# 6. Runs grid helper
# =============================================================================

function _ADO_UpdateRunsGrid {
    param([object[]]$Runs)

    $newRows = @($Runs)

    if (-not $script:adoRunsTable -or $script:adoRunsTable.Columns.Count -eq 0) {
        $script:adoRunsTable = ConvertTo-DataTable -Objects $newRows
        $script:ADORunsGrid.ItemsSource = $script:adoRunsTable.DefaultView
    } else {
        $script:adoRunsTable.BeginLoadData()
        $script:adoRunsTable.Rows.Clear()
        foreach ($obj in $newRows) {
            $row = $script:adoRunsTable.NewRow()
            foreach ($prop in $obj.PSObject.Properties.Name) {
                if ($script:adoRunsTable.Columns.Contains($prop)) {
                    $v = $obj.$prop
                    $row[$prop] = if ($null -eq $v) { [DBNull]::Value } else { $v }
                }
            }
            $script:adoRunsTable.Rows.Add($row)
        }
        $script:adoRunsTable.EndLoadData()
    }

    if ($script:adoSelectedTag) { _ADO_OnTreeSelected -Tag $script:adoSelectedTag }
}

# =============================================================================
# 7. Run Pipeline dialog
#    Fetches branches, parameters and stages, then queues the run.
# =============================================================================

function _ADO_ShowRunDialog {
    param([int]$DefId, [string]$PipelineName)

    if (-not $script:adoPat) {
        $script:ADOActionStatus.Text = 'No PAT configured - click "Set PAT" to add one.'
        return
    }

    # ── Build the dialog shell immediately so it appears without delay ─────────
    $dlg = New-Object System.Windows.Window
    $dlg.Title  = "Run Pipeline - $PipelineName"
    $dlg.Width  = 520
    $dlg.MaxHeight = 750
    $dlg.SizeToContent = [System.Windows.SizeToContent]::Height
    $dlg.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dlg.Owner  = [System.Windows.Window]::GetWindow($script:AzureDevOpsTab)
    $dlg.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dlg.Background = [System.Windows.Media.Brushes]::White
    try { Set-WindowIcon -Window $dlg -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)

    # Title
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = 'Run Pipeline'; $tb.FontSize = 16; $tb.FontWeight = [System.Windows.FontWeights]::SemiBold
    $tb.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0,120,212)
    $tb.Margin = [System.Windows.Thickness]::new(0,0,0,4)
    [void]$sp.Children.Add($tb)
    $nb = New-Object System.Windows.Controls.TextBlock
    $nb.Text = $PipelineName; $nb.FontSize = 13
    $nb.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(80,80,80)
    $nb.Margin = [System.Windows.Thickness]::new(0,0,0,16)
    [void]$sp.Children.Add($nb)

    # Loading indicator - replaced once the background fetch completes
    $loadingTb = New-Object System.Windows.Controls.TextBlock
    $loadingTb.Text       = 'Loading pipeline details...'
    $loadingTb.FontSize   = 12
    $loadingTb.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(100,100,100)
    $loadingTb.Margin     = [System.Windows.Thickness]::new(0,0,0,16)
    [void]$sp.Children.Add($loadingTb)

    # Content placeholder - populated by the background fetch callback
    $contentSP = New-Object System.Windows.Controls.StackPanel
    [void]$sp.Children.Add($contentSP)

    # Error status (shown if run fails)
    $statusTb = New-Object System.Windows.Controls.TextBlock
    $statusTb.FontSize = 12; $statusTb.Foreground = [System.Windows.Media.Brushes]::Red
    $statusTb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $statusTb.Margin = [System.Windows.Thickness]::new(0,6,0,0)
    $statusTb.Visibility = [System.Windows.Visibility]::Collapsed
    [void]$sp.Children.Add($statusTb)

    # Buttons
    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $btnRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $btnRow.Margin = [System.Windows.Thickness]::new(0,16,0,0)
    $cancelBtn = New-Object System.Windows.Controls.Button
    $cancelBtn.Content = 'Cancel'; $cancelBtn.Padding = [System.Windows.Thickness]::new(16,6,16,6)
    $cancelBtn.Margin = [System.Windows.Thickness]::new(0,0,8,0); $cancelBtn.FontSize = 12
    $cancelBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    $cancelBtn.Add_Click({ $dlg.Close() })
    [void]$btnRow.Children.Add($cancelBtn)
    $runBtn = New-Object System.Windows.Controls.Button
    $runBtn.Content = 'Run'; $runBtn.Padding = [System.Windows.Thickness]::new(16,6,16,6)
    $runBtn.FontSize = 12; $runBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    $runBtn.Background = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(0,120,212)
    $runBtn.Foreground = [System.Windows.Media.Brushes]::White
    $runBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    $runBtn.IsEnabled = $false   # disabled until fetch completes
    [void]$btnRow.Children.Add($runBtn)
    [void]$sp.Children.Add($btnRow)
    $scroll.Content = $sp; $dlg.Content = $scroll

    # These are populated by the fetch callback and referenced in the Run click handler
    $paramControls = @{}
    $stageChecks   = @{}
    $defaultBranch = 'master'

    # ── Background fetch: definition + branches + preview ─────────────────────
    # Results are cached per pipeline ID - subsequent opens of the same pipeline
    # are instant. Cache is invalidated when the PAT or OrgUrl changes.
    $cachedResult = if ($script:adoPipelineCache.ContainsKey($DefId)) {
        Write-Log "INFO [ADO] Run dialog: cache hit for pipeline $DefId"
        $loadingTb.Visibility = [System.Windows.Visibility]::Collapsed
        $script:adoPipelineCache[$DefId]
    } else { $null }

    $fetchB64     = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($script:adoPat)"))
    $fetchOrgUrl  = $script:AdoOrgUrl
    $fetchApiVer  = $script:ApiVersions.AzureDevOps
    $fetchLogFile = $script:LogFile
    $fetchDefId   = $DefId

    $fetchRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $fetchRS.ApartmentState = 'MTA'
    $fetchRS.Open()
    $fetchPS = [System.Management.Automation.PowerShell]::Create()
    $fetchPS.Runspace = $fetchRS

    [void]$fetchPS.AddScript({
        param($OrgUrl, $B64, $DefId, $ApiVer, $LogFile)
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        function WL($m) { if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] $m`r`n") } catch {} } }

        $hdr           = @{ Authorization = "Basic $B64"; Accept = 'application/json' }
        $branches      = @('main', 'master')
        $defaultBranch = 'master'
        $parameters    = [System.Collections.Generic.List[hashtable]]::new()
        $stages        = [System.Collections.Generic.List[string]]::new()
        $fetchError    = ''

        # -- Step 1: build definition (default branch, repo, queue-time vars) --
        try {
            $def = (Invoke-WebRequest -Method GET -Uri "$OrgUrl/_apis/build/definitions/$DefId`?api-version=$ApiVer" `
                        -Headers $hdr -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json

            if ($def.repository.defaultBranch) {
                $defaultBranch = $def.repository.defaultBranch -replace '^refs/heads/', ''
            }

            # Queue-time overridable variables (classic + YAML allowOverride=true)
            if ($def.variables) {
                $def.variables.PSObject.Properties | ForEach-Object {
                    if ($_.Value.allowOverride -eq $true) {
                        $parameters.Add(@{
                            Name          = $_.Name
                            DisplayName   = $_.Name
                            DefaultValue  = [string]$_.Value.value
                            Type          = 'string'
                            AllowedValues = @()
                        })
                    }
                }
            }

            # Classic pipeline process parameters
            if ($def.process.parameters) {
                foreach ($p in $def.process.parameters) {
                    if (-not ($parameters | Where-Object { $_['Name'] -eq [string]$p.name })) {
                        $parameters.Add(@{
                            Name          = [string]$p.name
                            DisplayName   = if ($p.displayName) { [string]$p.displayName } else { [string]$p.name }
                            DefaultValue  = [string]$p.defaultValue
                            Type          = if ($p.parameterType -eq 5) { 'boolean' } else { 'string' }
                            AllowedValues = @()
                        })
                    }
                }
            }

            # Branch list from Git repo
            if ([string]$def.repository.type -eq 'TfsGit') {
                try {
                    $brResp = (Invoke-WebRequest -Method GET `
                        -Uri "$OrgUrl/_apis/git/repositories/$($def.repository.id)/refs?filter=heads&api-version=$ApiVer" `
                        -Headers $hdr -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
                    $branches = @($brResp.value | ForEach-Object { [string]$_.name -replace '^refs/heads/','' } | Sort-Object)
                } catch { WL "INFO [ADO] Could not fetch branches: $_" }
            }
        } catch {
            WL "WARN [ADO] Could not fetch build definition $DefId : $_"
            $fetchError = "Could not load pipeline definition: $_"
        }

        # -- Step 2: preview run (YAML parameters + stage identifiers) ----------
        # Retries with dummy values when required parameters have no default.
        try {
            $prevParams    = @{}
            $prevResp      = $null
            $prevAttempts  = 0
            $prevMaxRetry  = 10
            $prevUris      = @(
                "$OrgUrl/_apis/pipelines/$DefId/preview?api-version=$ApiVer",
                "$OrgUrl/_apis/pipelines/$DefId/runs?api-version=$ApiVer"
            )

            while (-not $prevResp -and $prevAttempts -lt $prevMaxRetry) {
                $prevAttempts++
                $prevBodyObj = @{ previewRun = $true; resources = @{ repositories = @{ self = @{ refName = "refs/heads/$defaultBranch" } } } }
                if ($prevParams.Count -gt 0) { $prevBodyObj['templateParameters'] = $prevParams }
                $prevJson = $prevBodyObj | ConvertTo-Json -Depth 5 -Compress
                WL "INFO [ADO] Preview attempt $prevAttempts body: $prevJson"

                $done = $false
                foreach ($uri in $prevUris) {
                    try {
                        $raw      = Invoke-WebRequest -Method POST -Uri $uri -Headers $hdr -Body $prevJson -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
                        $prevResp = $raw.Content | ConvertFrom-Json
                        WL "INFO [ADO] Preview HTTP $($raw.StatusCode) via $uri"
                        $done = $true
                        break
                    } catch {
                        $errMsg = [string]$_
                        $sc     = $_.Exception.Response.StatusCode.value__
                        WL "WARN [ADO] Preview attempt $prevAttempts ($uri): StatusCode=$sc Msg=$errMsg"
                        if ($sc -eq 400 -and $errMsg -match "value for the '([^']+)' parameter") {
                            $mp = $Matches[1]
                            if (-not $prevParams.ContainsKey($mp)) {
                                WL "INFO [ADO] Adding dummy for required param '$mp'"
                                $prevParams[$mp] = '__placeholder__'
                                break   # retry outer while
                            } else {
                                WL "WARN [ADO] Already have dummy for '$mp', stopping retries"
                                $prevAttempts = $prevMaxRetry
                                break
                            }
                        }
                    }
                }
                if ($done) { break }
            }

            if ($prevResp -and $prevResp.finalYaml) {
                WL "INFO [ADO] finalYaml length: $($prevResp.finalYaml.Length)"
                try { [IO.File]::WriteAllText("$env:TEMP\ado-finalyaml-$DefId.txt", $prevResp.finalYaml) } catch {}

                # Parse YAML parameters block
                $yamlLines = $prevResp.finalYaml -split "`n"
                $inParams  = $false; $inValues = $false; $curParam = $null

                foreach ($line in $yamlLines) {
                    $t = $line.TrimEnd()
                    if (-not $t -or $t -match '^\s*#') { continue }

                    if ($t -match '^parameters\s*:') { $inParams = $true; $inValues = $false; continue }
                    if (-not $inParams) { continue }

                    if ($t -match '^\S' -and $t -notmatch '^\s*-') {
                        if ($curParam -and $curParam.Name) {
                            if (-not ($parameters | Where-Object { $_['Name'] -eq $curParam.Name })) {
                                $parameters.Add(@{ Name=$curParam.Name; DisplayName=if($curParam.DisplayName){$curParam.DisplayName}else{$curParam.Name}; DefaultValue=[string]$curParam.Default; Type=$curParam.Type; AllowedValues=@($curParam.Values) })
                            }
                        }
                        $curParam = $null; $inParams = $false; continue
                    }

                    if ($t -match '^\s*-\s*name\s*:\s*(.+)$') {
                        if ($curParam -and $curParam.Name) {
                            if (-not ($parameters | Where-Object { $_['Name'] -eq $curParam.Name })) {
                                $parameters.Add(@{ Name=$curParam.Name; DisplayName=if($curParam.DisplayName){$curParam.DisplayName}else{$curParam.Name}; DefaultValue=[string]$curParam.Default; Type=$curParam.Type; AllowedValues=@($curParam.Values) })
                            }
                        }
                        $curParam = @{ Name=$Matches[1].Trim().Trim('"').Trim("'"); DisplayName=''; Type='string'; Default=''; Values=[System.Collections.Generic.List[string]]::new() }
                        $inValues = $false; continue
                    }

                    if (-not $curParam) { continue }

                    if ($t -match '^\s+type\s*:\s*(.+)$') {
                        $ty = $Matches[1].Trim().Trim('"').Trim("'")
                        $curParam.Type = if ($ty -eq 'boolean' -or $ty -eq 'bool') { 'boolean' } else { 'string' }
                        $inValues = $false; continue
                    }
                    if ($t -match '^\s+default\s*:\s*(.*)$') { $curParam.Default = $Matches[1].Trim().Trim('"').Trim("'"); $inValues = $false; continue }
                    if ($t -match '^\s+displayName\s*:\s*(.+)$') { $curParam.DisplayName = $Matches[1].Trim().Trim('"').Trim("'"); $inValues = $false; continue }
                    if ($t -match '^\s+values\s*:\s*$') { $inValues = $true; continue }
                    if ($inValues -and $t -match '^\s+-\s*(.+)$') { [void]$curParam.Values.Add($Matches[1].Trim().Trim('"').Trim("'")); continue }
                    if ($t -match '^\s+\w+\s*:') { $inValues = $false }
                }
                if ($curParam -and $curParam.Name) {
                    if (-not ($parameters | Where-Object { $_['Name'] -eq $curParam.Name })) {
                        $parameters.Add(@{ Name=$curParam.Name; DisplayName=if($curParam.DisplayName){$curParam.DisplayName}else{$curParam.Name}; DefaultValue=[string]$curParam.Default; Type=$curParam.Type; AllowedValues=@($curParam.Values) })
                    }
                }

                # Parse stage identifiers
                foreach ($line in $yamlLines) {
                    if ($line -match '^\s*-?\s*stage\s*:\s*(.+)$') {
                        $sn = $Matches[1].Trim().Trim('"').Trim("'")
                        if ($sn -and $sn -ne '__default' -and $sn -ne '_default') { [void]$stages.Add($sn) }
                    }
                }

                WL "INFO [ADO] Parse complete: $($parameters.Count) params, $($stages.Count) stages"
            } else {
                WL "WARN [ADO] finalYaml missing or preview failed"
            }
        } catch {
            WL "WARN [ADO] Preview failed for $DefId : $_"
        }

        # Return result as JSON for Dispatcher.Invoke
        @{
            DefaultBranch = $defaultBranch
            Branches      = $branches
            Parameters    = @($parameters)
            Stages        = @($stages)
            Error         = $fetchError
        } | ConvertTo-Json -Depth 6 -Compress
    }).AddArgument($fetchOrgUrl).AddArgument($fetchB64).AddArgument($fetchDefId).AddArgument($fetchApiVer).AddArgument($fetchLogFile)

    $fetchHandle = if ($cachedResult) { $null } else { $fetchPS.BeginInvoke() }

    # ── Poll for fetch completion via DispatcherTimer ──────────────────────────
    # On a cache hit $fetchHandle is $null - the timer fires once and uses $cachedResult directly.
    $fetchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $fetchTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $fetchTimer.Add_Tick({
        if ($fetchHandle -and -not $fetchHandle.IsCompleted) { return }
        $fetchTimer.Stop()

        $result = $null
        if ($cachedResult) {
            # Cache hit - use stored result, no runspace to clean up
            $result = $cachedResult
        } else {
            # Fresh fetch - read from runspace and cache for next time
            $resultJson = $null
            try { $resultJson = $fetchPS.EndInvoke($fetchHandle) | Select-Object -Last 1 } catch {}
            $fetchPS.Dispose(); $fetchRS.Close(); $fetchRS.Dispose()
            if ($resultJson) {
                try { $result = $resultJson | ConvertFrom-Json } catch {}
                if ($result) { $script:adoPipelineCache[$fetchDefId] = $result }
            }
        }

        # Remove loading text
        $loadingTb.Visibility = [System.Windows.Visibility]::Collapsed

        if (-not $result) {
            $loadingTb.Text       = 'Could not load pipeline details.'
            $loadingTb.Foreground = [System.Windows.Media.Brushes]::Red
            $loadingTb.Visibility = [System.Windows.Visibility]::Visible
            $runBtn.IsEnabled     = $true
            return
        }

        $defaultBranch = [string]$result.DefaultBranch
        $branches      = @($result.Branches)
        $parameters    = @($result.Parameters)
        $stages        = @($result.Stages)

        # ── Populate branch combo ──
        $brComboCtrl = New-Object System.Windows.Controls.ComboBox
        $brComboCtrl.IsEditable = $true; $brComboCtrl.FontSize = 12
        $brComboCtrl.Padding = [System.Windows.Thickness]::new(8,5,8,5)
        $brComboCtrl.Margin  = [System.Windows.Thickness]::new(0,0,0,16)
        foreach ($b in $branches) { [void]$brComboCtrl.Items.Add($b) }
        $brComboCtrl.Text = $defaultBranch

        $brLbl = New-Object System.Windows.Controls.TextBlock
        $brLbl.Text = 'Branch'; $brLbl.FontSize = 12; $brLbl.FontWeight = [System.Windows.FontWeights]::SemiBold
        $brLbl.Margin = [System.Windows.Thickness]::new(0,0,0,4)
        [void]$contentSP.Children.Add($brLbl)
        [void]$contentSP.Children.Add($brComboCtrl)
        $script:_adoRunDlgBrCombo = $brComboCtrl   # expose to Run click via script scope

        # ── Populate parameters ──
        if ($parameters.Count -gt 0) {
            $plb = New-Object System.Windows.Controls.TextBlock
            $plb.Text = 'Parameters'; $plb.FontSize = 12; $plb.FontWeight = [System.Windows.FontWeights]::SemiBold
            $plb.Margin = [System.Windows.Thickness]::new(0,0,0,8)
            [void]$contentSP.Children.Add($plb)

            foreach ($p in $parameters) {
                $pName    = [string]$p.Name
                $pLabel   = if ($p.DisplayName) { [string]$p.DisplayName } else { $pName }
                $pDefault = [string]$p.DefaultValue
                $pType    = [string]$p.Type
                $pAllowed = @($p.AllowedValues)

                if ($pType -eq 'boolean') {
                    $ctrl = New-Object System.Windows.Controls.CheckBox
                    $ctrl.Content   = $pLabel
                    $ctrl.IsChecked = ($pDefault -ieq 'true')
                    $ctrl.FontSize  = 12
                    $ctrl.Margin    = [System.Windows.Thickness]::new(0,0,0,8)
                    [void]$contentSP.Children.Add($ctrl)
                    $paramControls[$pName] = @{ Control = $ctrl; Type = 'bool' }
                } else {
                    $nlb = New-Object System.Windows.Controls.TextBlock
                    $nlb.Text = $pLabel; $nlb.FontSize = 12
                    $nlb.Foreground  = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(80,80,80)
                    $nlb.TextWrapping = [System.Windows.TextWrapping]::Wrap
                    $nlb.Margin = [System.Windows.Thickness]::new(0,0,0,3)
                    [void]$contentSP.Children.Add($nlb)

                    if ($pAllowed.Count -gt 0) {
                        $ctrl = New-Object System.Windows.Controls.ComboBox
                        $ctrl.FontSize = 12; $ctrl.Padding = [System.Windows.Thickness]::new(6,4,6,4)
                        $ctrl.Margin = [System.Windows.Thickness]::new(0,0,0,10)
                        foreach ($av in $pAllowed) { [void]$ctrl.Items.Add($av) }
                        $ctrl.SelectedItem = if ($pDefault -and $ctrl.Items.Contains($pDefault)) { $pDefault } else { $ctrl.Items[0] }
                        [void]$contentSP.Children.Add($ctrl)
                        $paramControls[$pName] = @{ Control = $ctrl; Type = 'combo' }
                    } else {
                        $ctrl = New-Object System.Windows.Controls.TextBox
                        $ctrl.Text = $pDefault; $ctrl.FontSize = 12
                        $ctrl.Padding = [System.Windows.Thickness]::new(8,5,8,5)
                        $ctrl.Margin  = [System.Windows.Thickness]::new(0,0,0,10)
                        $ctrl.BorderBrush     = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(200,205,211)
                        $ctrl.BorderThickness = [System.Windows.Thickness]::new(1)
                        [void]$contentSP.Children.Add($ctrl)
                        $paramControls[$pName] = @{ Control = $ctrl; Type = 'string' }
                    }
                }
            }
        }

        # ── Populate stages ──
        if ($stages.Count -gt 0) {
            $sep2 = New-Object System.Windows.Controls.Separator
            $sep2.Margin = [System.Windows.Thickness]::new(0,4,0,8)
            [void]$contentSP.Children.Add($sep2)
            $stageExpander = New-Object System.Windows.Controls.Expander
            $stageExpander.Header     = 'Stages (uncheck to skip)'
            $stageExpander.IsExpanded = $false
            $stageExpander.FontSize   = 12
            $stageExpander.FontWeight = [System.Windows.FontWeights]::SemiBold
            $stageExpander.Margin     = [System.Windows.Thickness]::new(0,0,0,4)
            $stageSP = New-Object System.Windows.Controls.StackPanel
            $stageSP.Margin = [System.Windows.Thickness]::new(8,6,0,0)
            foreach ($stg in $stages) {
                $scb = New-Object System.Windows.Controls.CheckBox
                $scb.Content = $stg; $scb.IsChecked = $true
                $scb.FontSize = 12; $scb.FontWeight = [System.Windows.FontWeights]::Normal
                $scb.Margin = [System.Windows.Thickness]::new(0,0,0,4)
                [void]$stageSP.Children.Add($scb)
                $stageChecks[$stg] = $scb
            }
            $stageExpander.Content = $stageSP
            [void]$contentSP.Children.Add($stageExpander)
        }

        # Branch note
        $brNote = New-Object System.Windows.Controls.TextBlock
        $brNote.Text = "Branch: $defaultBranch"; $brNote.FontSize = 11
        $brNote.Foreground = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(140,140,140)
        $brNote.Margin = [System.Windows.Thickness]::new(0,8,0,0)
        [void]$contentSP.Children.Add($brNote)

        $runBtn.IsEnabled = $true
    }.GetNewClosure())

    # ── Run button click ───────────────────────────────────────────────────────
    $runBtn.Add_Click({
        $brCtrl = $script:_adoRunDlgBrCombo
        $branch = if ($brCtrl) { $brCtrl.Text.Trim() } else { $defaultBranch }
        if (-not $branch) { $branch = $defaultBranch }

        $params = @{}
        foreach ($kv in $paramControls.GetEnumerator()) {
            $ctrl = $kv.Value.Control
            $val  = switch ($kv.Value.Type) {
                'bool'  { if ($ctrl.IsChecked) { 'true' } else { 'false' } }
                'combo' { [string]$ctrl.SelectedItem }
                default { $ctrl.Text }
            }
            $params[$kv.Key] = $val
        }

        $stagesToSkip = @($stageChecks.GetEnumerator() |
            Where-Object { $_.Value.IsChecked -ne $true } |
            ForEach-Object { $_.Key })

        $runBtn.IsEnabled = $false
        $statusTb.Visibility = [System.Windows.Visibility]::Collapsed
        try {
            _ADO_QueueRun -DefId $DefId -Branch $branch -Params $params -StagesToSkip $stagesToSkip
            $dlg.Close()
        } catch {
            $statusTb.Text = "Error: $_"
            $statusTb.Visibility = [System.Windows.Visibility]::Visible
            $runBtn.IsEnabled = $true
        }
    }.GetNewClosure())

    $fetchTimer.Start()
    $dlg.ShowDialog() | Out-Null
    $fetchTimer.Stop()   # ensure stopped if dialog closed before fetch completes
}

# =============================================================================
# 8. Action helpers
# =============================================================================

function _ADO_QueueRun {
    param(
        [int]$DefId,
        [string]$Branch,
        [hashtable]$Params = @{},
        [string[]]$StagesToSkip = @()
    )

    if ($script:adoActionHandle -and -not $script:adoActionHandle.IsCompleted) {
        $script:ADOActionStatus.Text = 'Another action is already in progress.'
        return
    }

    $script:ADOActionStatus.Text        = "Queuing run for '$( ($script:adoLastPipelines | Where-Object { $_.Id -eq $DefId } | Select-Object -First 1).Name )'..."
    $script:ADORefreshButton.IsEnabled  = $false
    $b64     = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($script:adoPat)"))
    $orgUrl  = $script:AdoOrgUrl
    $apiVer  = $script:ApiVersions.AzureDevOps
    $logFile = $script:LogFile

    # Serialise params and stagesToSkip as JSON strings to survive runspace boundary
    $paramsJson      = if ($Params.Count -gt 0)        { $Params      | ConvertTo-Json -Compress } else { '{}' }
    $skipJson        = if ($StagesToSkip.Count -gt 0)  { $StagesToSkip | ConvertTo-Json -Compress } else { '[]' }

    $script:adoActionRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:adoActionRS.ApartmentState = 'MTA'
    $script:adoActionRS.Open()

    $script:adoActionPS          = [System.Management.Automation.PowerShell]::Create()
    $script:adoActionPS.Runspace = $script:adoActionRS
    [void]$script:adoActionPS.AddScript({
        param($OrgUrl, $B64, $Id, $Branch, $ParamsJson, $SkipJson, $ApiVer, $LogFile)
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $hdr    = @{ Authorization = "Basic $B64"; 'Content-Type' = 'application/json' }
        $params = $ParamsJson | ConvertFrom-Json
        $skip   = if ($SkipJson -and $SkipJson -ne '[]') { @($SkipJson | ConvertFrom-Json | ForEach-Object { [string]$_ }) } else { @() }

        $body = @{
            resources = @{ repositories = @{ self = @{ refName = "refs/heads/$Branch" } } }
        }

        # templateParameters covers both YAML parameters and classic queue-time variables
        if ($params.PSObject.Properties.Count -gt 0) {
            $templateParams = @{}
            $params.PSObject.Properties | ForEach-Object { $templateParams[$_.Name] = $_.Value }
            $body.templateParameters = $templateParams
        }

        if ($skip.Count -gt 0) { $body.stagesToSkip = $skip }

        $uri  = "$OrgUrl/_apis/pipelines/$Id/runs?api-version=$ApiVer"
        $json = $body | ConvertTo-Json -Depth 10 -Compress
        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] POST $uri body=$json`r`n") } catch {} }
        $resp = Invoke-WebRequest -Method POST -Uri $uri -Headers $hdr -Body $json -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop
        $obj  = $resp.Content | ConvertFrom-Json
        ConvertTo-Json -InputObject @{ Action = 'Run'; BuildId = [int]$obj.id; Status = [string]$obj.state } -Compress
    }).AddArgument($orgUrl).AddArgument($b64).AddArgument($DefId).AddArgument($Branch).AddArgument($paramsJson).AddArgument($skipJson).AddArgument($apiVer).AddArgument($logFile)

    $script:adoActionHandle = $script:adoActionPS.BeginInvoke()
    $script:adoActionType   = 'Run'
}

function _ADO_CancelRun {
    param([int]$BuildId)

    if ($script:adoActionHandle -and -not $script:adoActionHandle.IsCompleted) {
        $script:ADOActionStatus.Text = 'Another action is already in progress.'
        return
    }

    $script:ADOActionStatus.Text        = "Cancelling run #$BuildId..."
    $script:ADORefreshButton.IsEnabled  = $false
    $hdr     = _ADO_GetAuthHeader
    $orgUrl  = $script:AdoOrgUrl
    $apiVer  = $script:ApiVersions.AzureDevOps

    $script:adoActionRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:adoActionRS.ApartmentState = 'MTA'
    $script:adoActionRS.Open()

    $script:adoActionPS          = [System.Management.Automation.PowerShell]::Create()
    $script:adoActionPS.Runspace = $script:adoActionRS
    [void]$script:adoActionPS.AddScript({
        param($OrgUrl, $Hdr, $Id, $ApiVer)
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $uri  = "$OrgUrl/_apis/build/builds/$Id`?api-version=$ApiVer"
        $json = '{"status":"cancelling"}'
        Invoke-WebRequest -Method PATCH -Uri $uri -Headers $Hdr -Body $json -ContentType 'application/json' -UseBasicParsing -ErrorAction Stop | Out-Null
        ConvertTo-Json -InputObject @{ Action = 'Cancel'; BuildId = $Id } -Compress
    }).AddArgument($orgUrl).AddArgument($hdr).AddArgument($BuildId).AddArgument($apiVer)

    $script:adoActionHandle = $script:adoActionPS.BeginInvoke()
    $script:adoActionType   = 'Cancel'
}

function _ADO_DeleteRun {
    param([int]$BuildId)

    if ($script:adoActionHandle -and -not $script:adoActionHandle.IsCompleted) {
        $script:ADOActionStatus.Text = 'Another action is already in progress.'
        return
    }

    $script:ADOActionStatus.Text        = "Deleting run #$BuildId..."
    $script:ADORefreshButton.IsEnabled  = $false
    $hdr     = _ADO_GetAuthHeader
    $orgUrl  = $script:AdoOrgUrl
    $apiVer  = $script:ApiVersions.AzureDevOps

    $script:adoActionRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:adoActionRS.ApartmentState = 'MTA'
    $script:adoActionRS.Open()

    $script:adoActionPS          = [System.Management.Automation.PowerShell]::Create()
    $script:adoActionPS.Runspace = $script:adoActionRS
    [void]$script:adoActionPS.AddScript({
        param($OrgUrl, $Hdr, $Id, $ApiVer)
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $uri = "$OrgUrl/_apis/build/builds/$Id`?api-version=$ApiVer"
        Invoke-WebRequest -Method DELETE -Uri $uri -Headers $Hdr -UseBasicParsing -ErrorAction Stop | Out-Null
        ConvertTo-Json -InputObject @{ Action = 'Delete'; BuildId = $Id } -Compress
    }).AddArgument($orgUrl).AddArgument($hdr).AddArgument($BuildId).AddArgument($apiVer)

    $script:adoActionHandle = $script:adoActionPS.BeginInvoke()
    $script:adoActionType   = 'Delete'
}

# =============================================================================
# 9. View Log
# =============================================================================

function _ADO_ViewLog {
    param([int]$BuildId, [string]$PipelineName)

    $script:ADOActionStatus.Text = "Fetching log for run #$BuildId..."
    $hdr    = _ADO_GetAuthHeader
    $orgUrl = $script:AdoOrgUrl
    $apiVer = $script:ApiVersions.AzureDevOps

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()

    $ps          = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($OrgUrl, $Hdr, $Id, $ApiVer)
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        # Build a text-accept header by cloning the auth header and adding Accept
        $txtHdr = @{}
        foreach ($k in $Hdr.Keys) { $txtHdr[$k] = $Hdr[$k] }
        $txtHdr['Accept'] = 'text/plain'

        $logsUri = "$OrgUrl/_apis/build/builds/$Id/logs?api-version=$ApiVer"
        $raw     = Invoke-WebRequest -Method GET -Uri $logsUri -Headers $Hdr -UseBasicParsing -ErrorAction Stop
        $logList = ($raw.Content | ConvertFrom-Json).value
        $lines   = [System.Collections.Generic.List[string]]::new()
        $errors  = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in @($logList)) {
            try {
                $logUri  = "$OrgUrl/_apis/build/builds/$Id/logs/$([int]$entry.id)?api-version=$ApiVer&`$format=text"
                $content = (Invoke-WebRequest -Method GET -Uri $logUri -Headers $txtHdr -UseBasicParsing -ErrorAction Stop).Content
                foreach ($line in ($content -split "`r?`n")) { $lines.Add($line) }
            } catch {
                $errors.Add("  [log $($entry.id) error: $_]")
            }
        }
        if ($lines.Count -eq 0 -and $errors.Count -gt 0) {
            $errors.ToArray() -join "`n"
        } else {
            $lines.ToArray() -join "`n"
        }
    }).AddArgument($orgUrl).AddArgument($hdr).AddArgument($BuildId).AddArgument($apiVer)

    $handle  = $ps.BeginInvoke()
    $timeout = [DateTime]::Now.AddSeconds(30)
    while (-not $handle.IsCompleted -and [DateTime]::Now -lt $timeout) {
        [System.Windows.Application]::Current.Dispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [System.Action]{})
        Start-Sleep -Milliseconds 200
    }

    $logText = ''
    try {
        $result  = $ps.EndInvoke($handle)
        $logText = if ($result) { $result -join "`n" } else { '(no log content)' }
    } catch {
        $logText = "Error fetching log: $_"
    } finally {
        try { $ps.Dispose() } catch {}
        try { $rs.Close(); $rs.Dispose() } catch {}
    }
    $script:ADOActionStatus.Text = ''

    # Log viewer popup
    $logWin = New-Object System.Windows.Window
    $logWin.Title         = "Log - Run #$BuildId - $PipelineName"
    $logWin.Width         = 900
    $logWin.Height        = 650
    $logWin.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $logWin.Owner         = [System.Windows.Window]::GetWindow($script:AzureDevOpsTab)
    $logWin.Background    = [System.Windows.Media.Brushes]::White
    try { Set-WindowIcon -Window $logWin -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}

    $dock    = New-Object System.Windows.Controls.DockPanel
    $toolbar = New-Object System.Windows.Controls.Border
    $toolbar.SetValue([System.Windows.Controls.DockPanel]::DockProperty, [System.Windows.Controls.Dock]::Top)
    $toolbar.Background      = [System.Windows.Media.Brushes]::WhiteSmoke
    $toolbar.BorderBrush     = [System.Windows.Media.SolidColorBrush][System.Windows.Media.Color]::FromRgb(220, 220, 220)
    $toolbar.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $toolbar.Padding         = [System.Windows.Thickness]::new(8, 4, 8, 4)

    $copyBtn = New-Object System.Windows.Controls.Button
    $copyBtn.Content  = 'Copy to Clipboard'
    $copyBtn.Padding  = [System.Windows.Thickness]::new(10, 3, 10, 3)
    $copyBtn.FontSize = 12
    $copyBtn.Cursor   = [System.Windows.Input.Cursors]::Hand
    $copyBtn.Add_Click({ [System.Windows.Clipboard]::SetText($logTextBlock.Text) })
    $toolbar.Child = $copyBtn
    [void]$dock.Children.Add($toolbar)

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility   = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $scroll.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $scroll.Background = [System.Windows.Media.Brushes]::White

    $logTextBlock = New-Object System.Windows.Controls.TextBlock
    $logTextBlock.Text         = $logText
    $logTextBlock.FontFamily   = New-Object System.Windows.Media.FontFamily('Consolas, Courier New')
    $logTextBlock.FontSize     = 11
    $logTextBlock.Foreground   = [System.Windows.Media.Brushes]::Black
    $logTextBlock.TextWrapping = [System.Windows.TextWrapping]::NoWrap
    $logTextBlock.Margin       = [System.Windows.Thickness]::new(10)

    $scroll.Content = $logTextBlock
    [void]$dock.Children.Add($scroll)
    $logWin.Content = $dock

    $logWin.Add_ContentRendered({ $scroll.ScrollToBottom() })
    $logWin.ShowDialog() | Out-Null
}

# =============================================================================
# 10. Initialize-AzureDevOpsTab
# =============================================================================

function Initialize-AzureDevOpsTab {
    param([System.Windows.Window]$Window)

    $script:AzureDevOpsTab         = $Window.FindName('AzureDevOpsTab')
    $script:ADOStatusText          = $Window.FindName('ADOStatusText')
    $script:ADORefreshButton       = $Window.FindName('ADORefreshButton')
    $script:ADOConfigurePATButton  = $Window.FindName('ADOConfigurePATButton')
    $script:ADOActionStatus        = $Window.FindName('ADOActionStatus')
    $script:ADORunningCount        = $Window.FindName('ADORunningCount')
    $script:ADOFolderTree          = $Window.FindName('ADOFolderTree')
    $script:ADORunsGrid            = $Window.FindName('ADORunsGrid')
    $script:ADOSelectionLabel      = $Window.FindName('ADOSelectionLabel')
    $script:ADOTreeFilter          = $Window.FindName('ADOTreeFilter')

    $script:adoRefreshRunspace  = $null
    $script:adoHandle           = $null
    $script:adoPS               = $null
    $script:adoRunsTable        = $null
    $script:adoLastPipelines    = @()
    $script:adoLastRuns         = @()
    $script:adoSelectedTag      = $null
    $script:adoActionHandle     = $null
    $script:adoActionPS         = $null
    $script:adoActionRS         = $null
    $script:adoNextRefresh      = [DateTime]::MaxValue
    $script:adoTabVisited       = $false
    # Tracks which folder nodes the user has manually expanded.
    # (root) is pre-seeded so the root folder starts open; all others start collapsed.
    # Updated on every tree rebuild to preserve the user's open/close choices.
    $script:adoExpandedFolders  = [System.Collections.Generic.HashSet[string]]::new()
    [void]$script:adoExpandedFolders.Add('(root)')

    # Cache for Run Pipeline dialog prefetch results (keyed by pipeline definition ID).
    # Populated after a successful background fetch; cleared when PAT or OrgUrl changes.
    $script:adoPipelineCache = @{}

    # Load PAT from DPAPI store
    $script:adoPat = _ADO_LoadPat
    if ($script:adoPat) {
        Write-Log 'INFO [ADO] PAT loaded from DPAPI store'
    } else {
        Write-Log 'INFO [ADO] No PAT stored - user must click Set PAT'
    }

    # Wire buttons before any early return so Set PAT works even when not yet configured
    $script:ADORefreshButton.Add_Click({ Invoke-AzureDevOpsRefresh })
    $script:ADOConfigurePATButton.Add_Click({
        Show-AdoPatDialog -OwnerWindow ([System.Windows.Window]::GetWindow($script:AzureDevOpsTab))
    })
    $Window.FindName('ADORunningTile').Cursor = [System.Windows.Input.Cursors]::Hand
    $Window.FindName('ADORunningTile').Add_MouseLeftButtonUp({
        Show-AdoRunningPopup -OwnerWindow ([System.Windows.Window]::GetWindow($script:AzureDevOpsTab))
    })

    if (-not $script:AdoOrgUrl) {
        $script:ADOStatusText.Text = 'Azure DevOps not configured - click Set PAT to configure'
        $script:ADORefreshButton.IsEnabled = $false
        Write-Log 'WARN [ADO] AzureDevOps.OrganisationUrl is not configured - tab disabled'
        return
    }

    # Persistent refresh runspace
    $script:adoRefreshRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:adoRefreshRunspace.ApartmentState = 'MTA'
    $script:adoRefreshRunspace.Open()

    # Tree filter debounce
    $script:adoTreeFilterDebounce = New-Object System.Windows.Threading.DispatcherTimer
    $script:adoTreeFilterDebounce.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:adoTreeFilterDebounce.Add_Tick({
        $script:adoTreeFilterDebounce.Stop()
        _ADO_PopulateTree -Pipelines $script:adoLastPipelines -FilterText $script:ADOTreeFilter.Text
    })
    $script:ADOTreeFilter.Add_TextChanged({ $script:adoTreeFilterDebounce.Stop(); $script:adoTreeFilterDebounce.Start() })

    # AutoGeneratingColumn - hide internal columns, colour-code Status/Result.
    $script:ADORunsGrid.Add_AutoGeneratingColumn({
        param($s, $e)
        $col = [string]$e.Column.Header
        if ($col.StartsWith('_')) { $e.Cancel = $true; return }

        # Helper: build a per-column CellStyle that tints the background by value
        # and goes transparent on selection so the row's blue shows through.
        # The implicit DataGridCell style in DataGrid.Resources handles the ControlTemplate.
        # Per-column CellStyles are explicit and override the implicit style, so we must
        # re-add the IsSelected=Transparent trigger here (last trigger wins in WPF).
        $makeCellStyle = {
            param([string]$BindPath, [object[]]$Bands)
            $ctXaml = '<ControlTemplate TargetType="DataGridCell"
                xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
                <Border Background="{TemplateBinding Background}"
                        BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}">
                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
            </ControlTemplate>'
            $cs = New-Object System.Windows.Style([System.Windows.Controls.DataGridCell])
            [void]$cs.Setters.Add((New-Object System.Windows.Setter(
                [System.Windows.Controls.Control]::TemplateProperty,
                [System.Windows.Markup.XamlReader]::Parse($ctXaml)
            )))
            foreach ($band in $Bands) {
                $dt  = New-Object System.Windows.DataTrigger
                $bnd = New-Object System.Windows.Data.Binding
                $bnd.Path = New-Object System.Windows.PropertyPath $BindPath
                $dt.Binding = $bnd
                $dt.Value   = $band.Value
                [void]$dt.Setters.Add((New-Object System.Windows.Setter(
                    [System.Windows.Controls.Control]::BackgroundProperty,
                    [System.Windows.Media.SolidColorBrush][System.Windows.Media.ColorConverter]::ConvertFromString($band.Hex)
                )))
                [void]$cs.Triggers.Add($dt)
            }
            # IsSelected=Transparent must come LAST so it wins over the colour triggers above
            $selTrigger = New-Object System.Windows.Trigger
            $selTrigger.Property = [System.Windows.Controls.DataGridCell]::IsSelectedProperty
            $selTrigger.Value    = $true
            [void]$selTrigger.Setters.Add((New-Object System.Windows.Setter(
                [System.Windows.Controls.Control]::BackgroundProperty,
                [System.Windows.Media.Brushes]::Transparent
            )))
            [void]$selTrigger.Setters.Add((New-Object System.Windows.Setter(
                [System.Windows.Controls.Control]::BorderBrushProperty,
                [System.Windows.Media.Brushes]::Transparent
            )))
            [void]$selTrigger.Setters.Add((New-Object System.Windows.Setter(
                [System.Windows.Controls.Control]::ForegroundProperty,
                [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x1F, 0x29, 0x37))
            )))
            [void]$cs.Triggers.Add($selTrigger)
            return $cs
        }

        # Status column: tint the cell background for active/cancelling states
        if ($col -eq 'Status') {
            $e.Column.CellStyle = & $makeCellStyle '[Status]' @(
                @{ Value = 'inProgress'; Hex = '#DDEEFF' }
                @{ Value = 'cancelling'; Hex = '#FFF0E6' }
                @{ Value = 'notStarted'; Hex = '#F5F5F5' }
            )
        }

        # Result column: tint the cell background by outcome
        if ($col -eq 'Result') {
            $e.Column.CellStyle = & $makeCellStyle '[Result]' @(
                @{ Value = 'succeeded';          Hex = '#E6F4EA' }
                @{ Value = 'failed';             Hex = '#FCE8E6' }
                @{ Value = 'canceled';           Hex = '#F5F5F5' }
                @{ Value = 'partiallySucceeded'; Hex = '#FFF3E0' }
            )
        }
    })

    # Runs grid context menu
    $Window.FindName('ADOMenuRun').Add_Click({
        $sel = $script:ADORunsGrid.SelectedItem
        if (-not $sel) { return }
        $defId = [int]$sel['_DefId']
        $name  = [string]$sel['Pipeline']
        _ADO_ShowRunDialog -DefId $defId -PipelineName $name
    })

    $Window.FindName('ADOMenuCancel').Add_Click({
        $sel = $script:ADORunsGrid.SelectedItem
        if (-not $sel) { return }
        _ADO_CancelRun -BuildId ([int]$sel['_BuildId'])
    })

    $Window.FindName('ADOMenuDelete').Add_Click({
        $sel = $script:ADORunsGrid.SelectedItem
        if (-not $sel) { return }
        $buildId = [int]$sel['_BuildId']
        $status  = [string]$sel['Status']
        if ($status -eq 'inProgress' -or $status -eq 'notStarted') {
            $script:ADOActionStatus.Text = "Cannot delete - run #$buildId is $status. Cancel it first."
            return
        }
        $conf = [System.Windows.MessageBox]::Show(
            "Delete run #$buildId from history? This cannot be undone.",
            'Confirm Delete', [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($conf -eq [System.Windows.MessageBoxResult]::Yes) {
            _ADO_DeleteRun -BuildId $buildId
        }
    })

    $Window.FindName('ADOMenuLog').Add_Click({
        $sel = $script:ADORunsGrid.SelectedItem
        if (-not $sel) { return }
        _ADO_ViewLog -BuildId ([int]$sel['_BuildId']) -PipelineName ([string]$sel['Pipeline'])
    })

    $Window.FindName('ADORunsContextMenu').Add_Opened({
        $sel       = $script:ADORunsGrid.SelectedItem
        $hasSel    = $null -ne $sel
        $status    = if ($hasSel) { [string]$sel['Status'] } else { '' }
        $canCancel = $hasSel -and ($status -eq 'inProgress' -or $status -eq 'notStarted')
        $canDelete = $hasSel -and ($status -eq 'completed')
        $Window.FindName('ADOMenuRun').IsEnabled    = $hasSel
        $Window.FindName('ADOMenuCancel').IsEnabled = $canCancel
        $Window.FindName('ADOMenuDelete').IsEnabled = $canDelete
        $Window.FindName('ADOMenuLog').IsEnabled    = $hasSel
    })

    # Tree context menu - "Run Pipeline" on a pipeline node
    $Window.FindName('ADOTreeMenuRun').Add_Click({
        $sel = $script:ADOFolderTree.SelectedItem
        if (-not $sel) { return }
        $tag = $sel.Tag
        if (-not $tag -or $tag.Type -ne 'Pipeline') {
            $script:ADOActionStatus.Text = 'Select a pipeline (not a folder) to run.'
            return
        }
        _ADO_ShowRunDialog -DefId ([int]$tag.DefId) -PipelineName ([string]$tag.Name)
    })

    $Window.FindName('ADOTreeContextMenu').Add_Opened({
        $sel = $script:ADOFolderTree.SelectedItem
        $isPipeline = $sel -and $sel.Tag -and $sel.Tag.Type -eq 'Pipeline'
        $Window.FindName('ADOTreeMenuRun').IsEnabled = $isPipeline
    })

    Write-Log 'INFO [ADO] Initialize-AzureDevOpsTab complete'
}

# =============================================================================
# 11. Invoke-AzureDevOpsRefresh
# =============================================================================

function Invoke-AzureDevOpsRefresh {
    if ($script:adoHandle -and -not $script:adoHandle.IsCompleted) { return }
    if (-not $script:AdoOrgUrl) { return }

    if (-not $script:adoPat) {
        $script:ADOStatusText.Text = 'No PAT - click "Set PAT" to configure authentication'
        $script:adoNextRefresh = [DateTime]::Now.AddSeconds(60)
        return
    }

    $script:ADORefreshButton.IsEnabled = $false
    $script:ADOStatusText.Text         = 'Refreshing...'

    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($script:adoPat)"))

    $script:adoRefreshRunspace.SessionStateProxy.SetVariable('AdoOrgUrl',        $script:AdoOrgUrl)
    $script:adoRefreshRunspace.SessionStateProxy.SetVariable('AdoAuthHeaderB64', $b64)
    $script:adoRefreshRunspace.SessionStateProxy.SetVariable('AdoApiVersion',    $script:ApiVersions.AzureDevOps)
    $script:adoRefreshRunspace.SessionStateProxy.SetVariable('LogFile',          $script:LogFile)

    $script:adoPS          = [System.Management.Automation.PowerShell]::Create()
    $script:adoPS.Runspace = $script:adoRefreshRunspace
    [void]$script:adoPS.AddScript($script:adoRefreshScript)
    $script:adoHandle      = $script:adoPS.BeginInvoke()
}

# =============================================================================
# 12. Invoke-AzureDevOpsTabTimer
# =============================================================================

function Invoke-AzureDevOpsTabTimer {

    if (-not $script:ADORunsGrid -or -not $script:ADORunsGrid.IsVisible) { return }
    if (-not $script:AdoOrgUrl) { return }

    # First-run gate - only trigger if PAT is configured
    if ($script:adoNextRefresh -eq [DateTime]::MaxValue -and $script:adoTabVisited) {
        if ($script:adoPat) {
            $script:adoNextRefresh = [DateTime]::Now
        } else {
            if ($script:ADOStatusText) { $script:ADOStatusText.Text = 'No PAT configured - click "Set PAT" to enable' }
        }
    }

    # (b) Collect completed refresh job
    if ($script:adoHandle -and $script:adoHandle.IsCompleted) {
        try {
            $rawResult = $script:adoPS.EndInvoke($script:adoHandle)
            $json      = if ($rawResult -is [array]) { $rawResult[0] } else { [string]$rawResult }
            $result    = if ($json) { $json | ConvertFrom-Json } else { $null }

            if ($result) {
                # Check for auth errors - stop auto-refresh if 401/403
                $authErr = @($result.PipelineError, $result.RunError) |
                    Where-Object { $_ -match '401|403|Unauthorized|Forbidden' } |
                    Select-Object -First 1

                if ($authErr) {
                    $script:ADOActionStatus.Text = "$authErr - auto-refresh stopped. Check your PAT."
                    Write-Log "ERROR [ADO] Auth error - stopping auto-refresh: $authErr"
                    $script:adoNextRefresh = [DateTime]::MaxValue
                } else {
                    if ($result.PipelineError) { $script:ADOActionStatus.Text = $result.PipelineError; Write-Log "ERROR [ADO] $($result.PipelineError)" }
                    if ($result.RunError)      { $script:ADOActionStatus.Text = $result.RunError;      Write-Log "ERROR [ADO] $($result.RunError)" }

                    if ($result.Pipelines) {
                        $script:adoLastPipelines = @($result.Pipelines)
                        _ADO_PopulateTree -Pipelines $script:adoLastPipelines -FilterText $script:ADOTreeFilter.Text
                    }
                    if ($null -ne $result.Runs) {
                        $script:adoLastRuns = @($result.Runs)
                        _ADO_UpdateRunsGrid -Runs $script:adoLastRuns

                        # Update Running tile: count inProgress + notStarted runs
                        $runningCount = @($script:adoLastRuns | Where-Object {
                            [string]$_.'Status' -eq 'inProgress' -or [string]$_.'Status' -eq 'notStarted'
                        }).Count
                        if ($script:ADORunningCount) { $script:ADORunningCount.Text = [string]$runningCount }
                    }

                    $ts = try { [datetime]::Parse($result.Timestamp).ToString('HH:mm:ss') } catch { (Get-Date).ToString('HH:mm:ss') }
                    $script:ADOStatusText.Text = "Updated: $ts"
                    Write-Log "INFO [ADO] UI updated. Pipelines=$($script:adoLastPipelines.Count) Runs=$($script:adoLastRuns.Count)"
                    $script:adoNextRefresh = [DateTime]::Now.AddSeconds($script:AdoRefreshIntervalSeconds)
                }
            } else {
                $script:adoNextRefresh = [DateTime]::Now.AddSeconds($script:AdoRefreshIntervalSeconds)
            }
        } catch {
            $script:ADOStatusText.Text = "Refresh error: $_"
            Write-Log "ERROR [ADO] Refresh collect failed: $_"
            $script:adoNextRefresh = [DateTime]::Now.AddSeconds($script:AdoRefreshIntervalSeconds)
        } finally {
            try { $script:adoPS.Dispose() } catch {}
            $script:adoHandle = $null
            $script:adoPS     = $null
            $script:ADORefreshButton.IsEnabled = $true
        }
    }

    # (a) Trigger scheduled refresh (only when PAT is set)
    $jobIdle = (-not $script:adoHandle -or $script:adoHandle.IsCompleted)
    if ($script:adoPat -and $script:adoNextRefresh -and [DateTime]::Now -ge $script:adoNextRefresh -and $jobIdle) {
        Invoke-AzureDevOpsRefresh
    }

    # (c) Collect completed action job
    if ($script:adoActionHandle -and $script:adoActionHandle.IsCompleted) {
        try {
            $rawRes = $script:adoActionPS.EndInvoke($script:adoActionHandle)
            $json   = if ($rawRes -is [array]) { $rawRes[0] } else { [string]$rawRes }
            $res    = if ($json) { $json | ConvertFrom-Json } else { $null }
            if ($res) {
                $act = [string]$res.Action
                $id  = [string]$res.BuildId
                $script:ADOActionStatus.Text = switch ($act) {
                    'Run'    { "Pipeline queued - new run #$id created" }
                    'Cancel' { "Run #$id cancellation requested" }
                    'Delete' { "Run #$id deleted" }
                    default  { "$act completed" }
                }
                Write-Log "INFO [ADO] Action '$act' completed. BuildId=$id"
                $script:adoNextRefresh = [DateTime]::Now
            }
        } catch {
            $script:ADOActionStatus.Text = "Action error: $_"
            Write-Log "ERROR [ADO] Action collect failed: $_"
        } finally {
            try { $script:adoActionPS.Dispose() } catch {}
            try { $script:adoActionRS.Close(); $script:adoActionRS.Dispose() } catch {}
            $script:adoActionHandle = $null
            $script:adoActionPS     = $null
            $script:adoActionRS     = $null
            $script:ADORefreshButton.IsEnabled = $true
        }
    }

    # (d) Countdown in status bar
    if ($script:adoNextRefresh -and $script:adoNextRefresh -ne [DateTime]::MaxValue) {
        $remaining = ($script:adoNextRefresh - [DateTime]::Now).TotalSeconds
        if ($remaining -gt 0 -and $script:ADOStatusText.Text -notlike 'Refreshing*' -and $script:ADOStatusText.Text -notlike 'No PAT*') {
            $base = if ($script:adoLastRuns.Count -gt 0) {
                "Pipelines: $($script:adoLastPipelines.Count)  Runs: $($script:adoLastRuns.Count)"
            } else { '' }
            $sep = if ($base) { '  |  ' } else { '' }
            $script:ADOStatusText.Text = "$base${sep}Next in $([Math]::Ceiling($remaining))s"
        }
    }
}

# =============================================================================
# 13. Reset-AzureDevOpsTab
# =============================================================================

function Reset-AzureDevOpsTab {
    if (-not $script:adoRefreshRunspace) { return }
    $script:adoNextRefresh = [DateTime]::Now
    Write-Log 'INFO [ADO] Reset-AzureDevOpsTab - immediate refresh scheduled'
}
