# =============================================================================
# tab-images.ps1  -  Images tab module
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Encapsulates everything needed for the Images tab in one file so the main
# dashboard script stays clean. Dot-source this file BEFORE the XAML string is
# built; the main script injects $ImagesTab_Xaml into its XAML via a placeholder
# comment and calls the three public lifecycle functions:
#
#   Initialize-ImagesTab  - once, after $window is loaded
#   Invoke-ImagesTabTimer - every second from the master DispatcherTimer
#   Reset-ImagesTab       - on subscription switch (triggers immediate refresh)
#
# DATA FLOW
# ---------
# The tab runs a dedicated background refresh every 60 seconds using a single
# persistent runspace. All Azure calls use direct REST API via bearer token.
# Each refresh cycle:
#   1. Lists VMs in each configured resource group
#   2. Applies IncludePatterns filter (case-insensitive substring match)
#   3. Fetches instanceView per VM for power state
#   4. Resolves private IP via the first NIC resource
#   5. Returns VM Name, Resource Group, Region, Power State, OS Type, IP Address,
#      VM SKU and Availability Zone
#
# Config (config.psd1  Images section):
#   ResourceGroups  - RGs containing image VMs (required)
#   IncludePatterns - optional substring filter; blank = show all VMs in the RGs
#   RefreshIntervalSeconds - default 60
#
# POWER ACTIONS
# -------------
# Start / Deallocate / Restart run in a fresh throw-away runspace each time so
# the dedicated refresh runspace is never blocked. Progress is polled by
# Invoke-ImagesTabTimer every second; buttons are re-enabled on completion.
# =============================================================================

[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ImagesTab_Xaml',
    Justification = 'Exported to the calling script via dot-source')]
param()

# =============================================================================
# 1. XAML fragment
#
# Placeholder in avd-live-dashboard.ps1: <!-- TAB:IMAGES -->
#
# Layout (DockPanel, top-to-bottom):
#   Top border        - Filter text box + IMGStatusText + Refresh button + Export CSV
#   Bottom action bar - IMGActionStatus (left) + Start / Deallocate / Restart (right)
#   Centre fill       - Grid with two rows separated by a GridSplitter:
#                         Row 0 - IMGGrid (DataGrid, multi-select, auto-column)
#                         Splitter
#                         Row 1 - IMGConsolePanel (collapsed by default)
#                                   Header: "Image Creation Output" + Stop + Close Tab buttons
#                                   IMGConsoleTabControl: TabControl, one tab per run
# =============================================================================

$ImagesTab_Xaml = @'
<TabItem Header="Images"
         xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <DockPanel>
        <!-- Top bar: filter input, status text and manual refresh button -->
        <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.CostBar.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1"
                Padding="12,7">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="220"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Filter:"
                           VerticalAlignment="Center"
                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}"
                           Margin="0,0,8,0"/>
                <TextBox x:Name="IMGFilterBox" Grid.Column="1"
                         FontSize="12" Padding="8,4"
                         VerticalContentAlignment="Center"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" Foreground="{DynamicResource Avd.Fg.Label}"/>
                <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="8,0,0,0">
                <Button x:Name="IMGCleanSnapshotsButton"
                        Content="Clean Snapshots"
                        Background="#6B2D8B" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,5" Margin="0,0,6,0"
                        ToolTip="Delete all snapshots in the configured image resource groups">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdIMGCS" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="BdIMGCS" Property="Background" Value="#888"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdIMGCS" Property="Background" Value="#4E2169"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="IMGCleanImageVersionsButton"
                        Content="Clean Image Versions"
                        Background="#0E5A8A" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,5" Margin="0,0,0,0"
                        ToolTip="Delete oldest image versions from each gallery definition, keeping the newest N (configured in Settings)">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdIMGCV" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="BdIMGCV" Property="Background" Value="#888"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdIMGCV" Property="Background" Value="#0A3D5E"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                </StackPanel>
                <TextBlock x:Name="IMGStatusText" Grid.Column="4"
                           VerticalAlignment="Center"
                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Hint}"
                           Margin="0,0,12,0"
                           TextTrimming="CharacterEllipsis"/>
                <Button x:Name="IMGRefreshButton" Grid.Column="5"
                        Content="Refresh"
                        Background="{DynamicResource Avd.Btn.Accent.Bg}" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="12,3" Margin="0,0,6,0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdIMGR" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdIMGR" Property="Background" Value="#005A9E"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdIMGR" Property="Background" Value="#003D6B"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="IMGExportButton" Grid.Column="6"
                        Content="Export CSV"
                        Background="#005A9E" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,5"
                        IsEnabled="False">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdIMGEx" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="BdIMGEx" Property="Background" Value="#888"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdIMGEx" Property="Background" Value="#004F8C"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdIMGEx" Property="Background" Value="#003D6B"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>
        </Border>

        <!-- Bottom action bar: result label + power action buttons -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.CostBar.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,1,0,0"
                Height="38">
            <Grid Margin="12,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="IMGActionStatus" Grid.Column="0"
                           Foreground="{DynamicResource Avd.Fg.Secondary}" FontSize="12"
                           VerticalAlignment="Center"
                           TextTrimming="CharacterEllipsis"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal"
                            VerticalAlignment="Center">
                    <Button x:Name="IMGStartButton" Content="Start"
                            IsEnabled="False" Margin="0,4,6,4"
                            Background="#107C10" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Start the selected VM(s)">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdIMGS" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdIMGS" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdIMGS" Property="Background" Value="#0A5C0A"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <Button x:Name="IMGDeallocateButton" Content="Deallocate"
                            IsEnabled="False" Margin="0,4,6,4"
                            Background="#CA5010" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Stop and deallocate the selected VM(s)">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdIMGD" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdIMGD" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdIMGD" Property="Background" Value="#9A3C0A"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <Button x:Name="IMGRestartButton" Content="Restart"
                            IsEnabled="False" Margin="0,4,4,4"
                            Background="{DynamicResource Avd.Btn.Accent.Bg}" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Restart the selected VM(s)">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdIMGR2" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdIMGR2" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdIMGR2" Property="Background" Value="#005A9E"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Centre: DataGrid (top) + GridSplitter + Console panel (bottom) -->
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="*" MinHeight="60"/>
                <RowDefinition Height="Auto"/>
                <!-- Console panel row - zero height when collapsed, 220 when open -->
                <RowDefinition Height="0" MinHeight="0"/>
            </Grid.RowDefinitions>

            <!-- VM grid -->
            <DataGrid x:Name="IMGGrid" Grid.Row="0" Margin="0" ColumnWidth="Auto"
                      SelectionMode="Extended" SelectionUnit="FullRow"/>

            <!-- Drag handle - only interactive when console is visible -->
            <GridSplitter x:Name="IMGSplitter" Grid.Row="1"
                          Height="5" HorizontalAlignment="Stretch"
                          Background="{DynamicResource Avd.Border.Std}" Cursor="SizeNS"
                          Visibility="Collapsed"/>

            <!-- Console panel - multi-session tab strip -->
            <Border x:Name="IMGConsolePanel" Grid.Row="2"
                    Background="#1E1E1E" Visibility="Collapsed">
                <DockPanel>
                    <!-- Console header bar -->
                    <Border DockPanel.Dock="Top" Background="#2D2D2D" Padding="10,5">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0"
                                       Text="Image Creation Output"
                                       Foreground="#CCCCCC" FontSize="12"
                                       FontFamily="Consolas"
                                       VerticalAlignment="Center"/>
                            <Button x:Name="IMGConsoleStopButton" Grid.Column="1"
                                    Content="Stop" Margin="0,0,6,0"
                                    Background="#C42B1C" Foreground="White"
                                    BorderThickness="0" FontSize="11"
                                    FontWeight="SemiBold" Cursor="Hand"
                                    Padding="10,3" IsEnabled="False"
                                    ToolTip="Terminate the running image creation job">
                                <Button.Template>
                                    <ControlTemplate TargetType="Button">
                                        <Border x:Name="BdStop" Background="{TemplateBinding Background}"
                                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsEnabled" Value="False">
                                                <Setter TargetName="BdStop" Property="Background" Value="#555"/>
                                            </Trigger>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="BdStop" Property="Background" Value="#9B1F15"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>
                            <Button x:Name="IMGConsoleClearButton" Grid.Column="2"
                                    Content="Close Tab"
                                    Background="#444" Foreground="White"
                                    BorderThickness="0" FontSize="11"
                                    Cursor="Hand" Padding="10,3"
                                    ToolTip="Close the current output tab">
                                <Button.Template>
                                    <ControlTemplate TargetType="Button">
                                        <Border x:Name="BdClr" Background="{TemplateBinding Background}"
                                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="BdClr" Property="Background" Value="#666"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>
                        </Grid>
                    </Border>
                    <!-- Tab strip - one tab per image creation run -->
                    <TabControl x:Name="IMGConsoleTabControl"
                                Background="#1E1E1E"
                                BorderThickness="0">
                        <TabControl.Resources>
                            <Style TargetType="TabItem">
                                <Setter Property="Background" Value="#2D2D2D"/>
                                <Setter Property="Foreground" Value="#AAAAAA"/>
                                <Setter Property="BorderThickness" Value="0"/>
                                <Setter Property="Padding" Value="10,4"/>
                                <Setter Property="FontSize" Value="11"/>
                                <Setter Property="FontFamily" Value="Consolas"/>
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="TabItem">
                                            <Border x:Name="BdTab"
                                                    Background="{TemplateBinding Background}"
                                                    BorderBrush="#444" BorderThickness="1,1,1,0"
                                                    Margin="0,2,2,0" Padding="{TemplateBinding Padding}"
                                                    CornerRadius="3,3,0,0">
                                                <ContentPresenter x:Name="Cp" ContentSource="Header"
                                                                  HorizontalAlignment="Center"
                                                                  VerticalAlignment="Center"/>
                                            </Border>
                                            <ControlTemplate.Triggers>
                                                <Trigger Property="IsSelected" Value="True">
                                                    <Setter TargetName="BdTab" Property="Background" Value="#4D4D4D"/>
                                                    <Setter Property="Foreground" Value="#D4D4D4"/>
                                                </Trigger>
                                                <Trigger Property="IsMouseOver" Value="True">
                                                    <Setter TargetName="BdTab" Property="Background" Value="#383838"/>
                                                </Trigger>
                                            </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </TabControl.Resources>
                    </TabControl>
                </DockPanel>
            </Border>
        </Grid>
    </DockPanel>
</TabItem>
'@

# =============================================================================
# 2. Background data-collection script
#
# Runs inside $script:imgRefreshRunspace - a dedicated single-thread MTA
# runspace that stays alive for the session.
#
# Variables injected via SessionStateProxy before each BeginInvoke():
#   $ArmToken             - bearer token for Azure REST API calls
#   $SubId                - current Azure subscription ID
#   $RestHelperDef        - compact Invoke-Arm function definition (string)
#   $LogFile              - log file path
#   $ImgRGsCsv            - comma-separated resource groups to query
#   $ImgIncludePatternsCsv - comma-separated VM name include substrings (blank = all)
# =============================================================================

$script:imgRefreshScript = {

    . ([scriptblock]::Create($RestHelperDef))

    $imgRGs          = @($ImgRGsCsv            -split ',' | Where-Object { $_ })
    $includePatterns = @($ImgIncludePatternsCsv -split ',' | Where-Object { $_ })

    $vmRows = [System.Collections.Generic.List[PSCustomObject]]::new()



    foreach ($rg in $imgRGs) {
        $vms = @(Invoke-Arm -Path "/subscriptions/$SubId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines" -Token $ArmToken -ApiVersion '2024-07-01')
        if ($vms.Count -eq 0) { continue }

        foreach ($vm in $vms) {
            # Apply include filter: if patterns are configured, only show VMs that match
            # at least one pattern. If no patterns configured, show all VMs in the RG.
            if ($includePatterns.Count -gt 0) {
                $matched = $false
                foreach ($pattern in $includePatterns) {
                    if ($vm.name -like "*$pattern*") { $matched = $true; break }
                }
                if (-not $matched) { continue }
            }

            # Get power state via per-VM instanceView
            $powerState = 'Unknown'
            try {
                $iv = Invoke-Arm -Path "$($vm.id)/instanceView" -Token $ArmToken -ApiVersion '2024-07-01' -FullResponse
                if ($iv -and $iv.statuses) {
                    $psStat = @($iv.statuses | Where-Object { $_.code -like 'PowerState/*' })
                    if ($psStat.Count -gt 0) { $powerState = [string]$psStat[0].displayStatus }
                }
            } catch { }
            if ($powerState -like 'VM *') { $powerState = $powerState.Substring(3) }
            if ($powerState.Length -gt 0) {
                $powerState = $powerState.Substring(0,1).ToUpper() + $powerState.Substring(1)
            }
            $osName    = if ($iv -and $iv.osName)    { [string]$iv.osName }    else { '-' }
            $osVersion = if ($iv -and $iv.osVersion) { [string]$iv.osVersion } else { '-' }

            $vmSku      = [string]$vm.properties.hardwareProfile.vmSize
            $availZone  = if ($vm.zones -and $vm.zones.Count -gt 0) { [string]$vm.zones[0] } else { 'N/A' }
            $osDiskName = [string]$vm.properties.storageProfile.osDisk.name

            # Resolve private IP from the first NIC
            $ip = '-'
            try {
                $nicId = $vm.properties.networkProfile.networkInterfaces[0].id
                if ($nicId) {
                    $nic = Invoke-Arm -Path $nicId -Token $ArmToken -ApiVersion '2024-01-01' -FullResponse
                    if ($nic -and $nic.properties.ipConfigurations) {
                        $resolved = [string]$nic.properties.ipConfigurations[0].properties.privateIPAddress
                        if (-not [string]::IsNullOrWhiteSpace($resolved)) { $ip = $resolved }
                    }
                }
            } catch { }

            $vmRows.Add([PSCustomObject]@{
                'VM Name'        = $vm.name
                'Resource Group' = $rg
                'Region'         = $vm.location
                'Power State'    = $powerState
                'OS Name'        = $osName
                'OS Version'     = $osVersion
                'IP Address'     = $ip
                'Avail Zone'     = $availZone
                'VM SKU'         = $vmSku
                'Disk SKU'       = '-'
                '_OsDiskName'    = $osDiskName  # hidden - resolved to Disk SKU via Resource Graph below
                '_RG'            = $rg          # hidden - used by power action buttons
            })
        }
    }

    # Batch-resolve OS disk SKUs via Resource Graph (avoids per-VM REST calls).
    # Also fetches disk size to derive the billing tier name (P10, E10, S10 etc.).
    $allDiskNames = @($vmRows | ForEach-Object { $_.'_OsDiskName' } | Where-Object { $_ })
    if ($allDiskNames.Count -gt 0) {
        $premiumTiers = @(
            @(4,'P1',120), @(8,'P2',120), @(16,'P3',120), @(32,'P4',120),
            @(64,'P6',240), @(128,'P10',500), @(256,'P15',1100), @(512,'P20',2300),
            @(1024,'P30',5000), @(2048,'P40',7500), @(4096,'P50',7500),
            @(8192,'P60',16000), @(16384,'P70',18000), @(32767,'P80',20000)
        )
        $standardSSDTiers = @(
            @(4,'E1',500), @(8,'E2',500), @(16,'E3',500), @(32,'E4',500),
            @(64,'E6',500), @(128,'E10',500), @(256,'E15',500), @(512,'E20',500),
            @(1024,'E30',500), @(2048,'E40',500), @(4096,'E50',500),
            @(8192,'E60',2000), @(16384,'E70',4000), @(32767,'E80',6000)
        )
        $standardHDDTiers = @(
            @(32,'S4',500), @(64,'S6',500), @(128,'S10',500), @(256,'S15',500),
            @(512,'S20',500), @(1024,'S30',500), @(2048,'S40',500), @(4096,'S50',500),
            @(8192,'S60',1300), @(16384,'S70',2000), @(32767,'S80',2000)
        )

        $diskSkuMap = @{}
        $batchSize  = 50
        for ($b = 0; $b -lt $allDiskNames.Count; $b += $batchSize) {
            $slice    = @($allDiskNames[$b .. ([Math]::Min($b + $batchSize - 1, $allDiskNames.Count - 1))])
            $diskList = ($slice | ForEach-Object { "'$($_.ToLower())'" }) -join ','
            $q = "Resources | where type =~ 'microsoft.compute/disks' | where tolower(name) in ($diskList) | project diskName = tolower(name), diskSku = tostring(sku.name), diskSizeGB = toint(properties.diskSizeGB)"
            $body = @{ subscriptions = @($SubId); query = $q }
            try {
                $resp = Invoke-Arm -Method POST -Path '/providers/Microsoft.ResourceGraph/resources' -Token $ArmToken -ApiVersion '2021-03-01' -Body $body -FullResponse
                foreach ($item in @($resp.data)) {
                    $dn = [string]$item.diskName
                    if (-not $dn) { continue }
                    $sku  = [string]$item.diskSku
                    $size = [int]$item.diskSizeGB
                    $tierTable = switch -Wildcard ($sku) {
                        'Premium*'     { $premiumTiers }
                        'StandardSSD*' { $standardSSDTiers }
                        'Standard*'    { $standardHDDTiers }
                        default        { @() }
                    }
                    $tierName = ''; $provIOPS = 0
                    foreach ($t in $tierTable) {
                        if ($size -le $t[0]) { $tierName = $t[1]; $provIOPS = $t[2]; break }
                    }
                    $diskSkuMap[$dn] = if ($tierName) { "$tierName ($size GB) $provIOPS IOPS" } elseif ($size) { "$sku ($size GB)" } else { $sku }
                }
            } catch { }
        }
        foreach ($row in $vmRows) {
            $dn = [string]$row.'_OsDiskName'
            if ($dn -and $diskSkuMap.ContainsKey($dn.ToLower())) {
                $row.'Disk SKU' = $diskSkuMap[$dn.ToLower()]
            }
        }
    }

    [PSCustomObject]@{
        VmRows    = @($vmRows | Sort-Object 'Resource Group', 'VM Name')
        Timestamp = Get-Date
    }
}

# =============================================================================
# 3. One-time initialisation  -  call after $window is loaded
# =============================================================================

function Initialize-ImagesTab {
    param(
        [System.Windows.Window]$Window,
        [string]$ContextFile,
        [string]$SubscriptionId
    )

    # Create the dedicated refresh runspace
    $script:imgRefreshRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:imgRefreshRunspace.ApartmentState = 'MTA'
    $script:imgRefreshRunspace.Open()

    # Bind named controls
    $script:IMGGrid               = $Window.FindName('IMGGrid')
    $script:IMGFilterBox          = $Window.FindName('IMGFilterBox')
    $script:IMGStatusText         = $Window.FindName('IMGStatusText')
    $script:IMGStartButton          = $Window.FindName('IMGStartButton')
    $script:IMGDeallocateButton     = $Window.FindName('IMGDeallocateButton')
    $script:IMGRestartButton        = $Window.FindName('IMGRestartButton')
    $script:IMGCleanSnapshotsButton     = $Window.FindName('IMGCleanSnapshotsButton')
    $script:IMGCleanImageVersionsButton = $Window.FindName('IMGCleanImageVersionsButton')
    $script:IMGActionStatus       = $Window.FindName('IMGActionStatus')
    $script:IMGRefreshButton      = $Window.FindName('IMGRefreshButton')
    $script:IMGExportButton       = $Window.FindName('IMGExportButton')
    $script:IMGConsolePanel        = $Window.FindName('IMGConsolePanel')
    $script:IMGConsoleSplitter     = $Window.FindName('IMGSplitter')
    $script:IMGConsoleTabControl   = $Window.FindName('IMGConsoleTabControl')
    $script:IMGConsoleStopButton   = $Window.FindName('IMGConsoleStopButton')
    $script:IMGConsoleClearButton  = $Window.FindName('IMGConsoleClearButton')

    # Initialise module-scope state variables
    $script:imgContextFile           = $ContextFile
    $script:imgSubId                 = $SubscriptionId
    $script:imgDataTable             = $null
    $script:imgLastVmRows            = @()
    $script:imgActionHandle          = $null
    $script:imgActionPS              = $null
    $script:imgActionRS              = $null
    $script:imgHandle                = $null
    $script:imgPS                    = $null
    $script:imgNextRefresh           = [DateTime]::Now   # fire immediately on first tick
    $script:imgLastRefreshTime       = $null
    $script:imgCountText             = ''
    $script:imgFilteredCountText     = $null
    $script:imgActionLabel           = ''
    $script:imgSkippedNote           = ''
    if (-not $script:ImgRefreshIntervalSeconds -or $script:ImgRefreshIntervalSeconds -lt 10) { $script:ImgRefreshIntervalSeconds = 60 }

    # Create-Image job state - list of active job slots (max 2 concurrent)
    # Each slot: @{ RS; PS; Handle; Queue; ConsoleBox }
    $script:imgJobs = [System.Collections.Generic.List[hashtable]]::new()

    # Hide internal helper columns
    $script:IMGGrid.Add_AutoGeneratingColumn({
        param($grid, $e)
        if ([string]$e.Column.Header -in @('_RG', '_OsDiskName')) { $e.Cancel = $true }
    })

    # Filter box: debounced DataView filtering
    $script:IMGFilterDebounce = New-Object System.Windows.Threading.DispatcherTimer
    $script:IMGFilterDebounce.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:IMGFilterDebounce.Add_Tick({
        $script:IMGFilterDebounce.Stop()
        if (-not $script:imgDataTable) { return }
        $text = $script:IMGFilterBox.Text.Trim()
        $script:imgDataTable.DefaultView.RowFilter = if ([string]::IsNullOrEmpty($text)) {
            ''
        } else {
            "([VM Name] LIKE '%$text%') OR ([Resource Group] LIKE '%$text%') OR ([Power State] LIKE '%$text%')"
        }
        if ([string]::IsNullOrEmpty($text)) {
            $script:imgFilteredCountText = $null
        } else {
            $view   = $script:imgDataTable.DefaultView
            $fTotal = $view.Count
            $fRun   = @($view | Where-Object { $_['Power State'] -eq 'Running' }).Count
            $script:imgFilteredCountText = "$fTotal VM(s)   Running: $fRun   Other: $($fTotal - $fRun)"
        }
    })
    $script:IMGFilterBox.Add_TextChanged({
        $script:IMGFilterDebounce.Stop()
        $script:IMGFilterDebounce.Start()
    })

    # Grid selection: enable/disable power action buttons
    $script:IMGGrid.Add_SelectionChanged({
        $has = $script:IMGGrid.SelectedItems.Count -gt 0
        $script:IMGStartButton.IsEnabled      = $has
        $script:IMGDeallocateButton.IsEnabled = $has
        $script:IMGRestartButton.IsEnabled    = $has
    })

    # Row hover / selected highlight style
    # Row highlighting uses the same theme resource keys as the Session Hosts tab so
    # hover and selection colours adapt correctly to dark and light mode.
    $imgRowStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridRow])
    [void]$imgRowStyle.Setters.Add((New-Object System.Windows.Setter(
        [System.Windows.Controls.DataGridRow]::ForegroundProperty, $Window.Resources['Avd.Window.Fg'])))

    $imgHoverTrigger = New-Object System.Windows.Trigger
    $imgHoverTrigger.Property = [System.Windows.Controls.DataGridRow]::IsMouseOverProperty
    $imgHoverTrigger.Value    = $true
    [void]$imgHoverTrigger.Setters.Add((New-Object System.Windows.Setter(
        [System.Windows.Controls.DataGridRow]::BackgroundProperty, $Window.Resources['Avd.Hover.Bg'])))

    $imgSelTrigger = New-Object System.Windows.Trigger
    $imgSelTrigger.Property = [System.Windows.Controls.DataGridRow]::IsSelectedProperty
    $imgSelTrigger.Value    = $true
    [void]$imgSelTrigger.Setters.Add((New-Object System.Windows.Setter(
        [System.Windows.Controls.DataGridRow]::BackgroundProperty, $Window.Resources['Avd.Selected.Bg'])))
    [void]$imgSelTrigger.Setters.Add((New-Object System.Windows.Setter(
        [System.Windows.Controls.DataGridRow]::ForegroundProperty, $Window.Resources['Avd.Fg.Selected'])))

    [void]$imgRowStyle.Triggers.Add($imgHoverTrigger)
    [void]$imgRowStyle.Triggers.Add($imgSelTrigger)
    $script:IMGGrid.RowStyle = $imgRowStyle

    # Button click handlers
    $script:IMGStartButton.Add_Click(          { Invoke-ImagesPowerAction -Action 'Start'      })
    $script:IMGDeallocateButton.Add_Click(     { Invoke-ImagesPowerAction -Action 'Deallocate' })
    $script:IMGRestartButton.Add_Click(        { Invoke-ImagesPowerAction -Action 'Restart'    })
    $script:IMGCleanSnapshotsButton.Add_Click(     { Invoke-ImagesCleanSnapshots })
    $script:IMGCleanImageVersionsButton.Add_Click( { Invoke-ImagesCleanImageVersions })
    $script:IMGRefreshButton.Add_Click(    { Invoke-ImagesTabRefresh })
    $script:IMGExportButton.Add_Click(     { Invoke-ImagesExport })

    # Console panel: Stop button kills the job whose tab is currently selected
    $script:IMGConsoleStopButton.Add_Click({
        _IMG_StopActiveTab -UserRequested $true
    })

    # Console panel: Close Tab button removes the currently selected tab.
    # If it was the active job tab, also stop the job.
    # Hide the panel when the last tab is closed.
    $script:IMGConsoleClearButton.Add_Click({
        $tc  = $script:IMGConsoleTabControl
        $sel = $tc.SelectedItem
        if (-not $sel) { return }
        # If closing the active running tab, stop the job first
        if ($sel.Tag -eq 'active') { _IMG_StopActiveTab -UserRequested $true }
        [void]$tc.Items.Remove($sel)
        if ($tc.Items.Count -eq 0) {
            $script:IMGConsolePanel.Visibility    = 'Collapsed'
            $script:IMGConsoleSplitter.Visibility = 'Collapsed'
            # Restore DataGrid row to fill all available space
            $grid = $script:IMGConsolePanel.Parent
            $grid.RowDefinitions[0].Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $grid.RowDefinitions[2].Height = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Pixel)
        }
    })

    # Right-click context menu: RDP to VM + Create Image + View Sysprep Log
    $imgCtxMenu             = New-Object System.Windows.Controls.ContextMenu
    $menuIMGRDP             = New-Object System.Windows.Controls.MenuItem
    $menuIMGRDP.Header      = "RDP to Server"
    [void]$imgCtxMenu.Items.Add($menuIMGRDP)
    [void]$imgCtxMenu.Items.Add((New-Object System.Windows.Controls.Separator))
    $menuIMGCreateImage             = New-Object System.Windows.Controls.MenuItem
    $menuIMGCreateImage.Header      = "Create Image..."
    $menuIMGCreateImage.FontWeight  = 'SemiBold'
    [void]$imgCtxMenu.Items.Add($menuIMGCreateImage)
    [void]$imgCtxMenu.Items.Add((New-Object System.Windows.Controls.Separator))
    $menuIMGSysprepLog          = New-Object System.Windows.Controls.MenuItem
    $menuIMGSysprepLog.Header   = "View Sysprep Log (setuperr.log)"
    [void]$imgCtxMenu.Items.Add($menuIMGSysprepLog)
    [void]$imgCtxMenu.Items.Add((New-Object System.Windows.Controls.Separator))
    $menuIMGOpenPortal         = New-Object System.Windows.Controls.MenuItem
    $menuIMGOpenPortal.Header  = "Open Resource Group in Portal"
    [void]$imgCtxMenu.Items.Add($menuIMGOpenPortal)
    # --- Experimental section ---
    [void]$imgCtxMenu.Items.Add((New-Object System.Windows.Controls.Separator))
    $menuIMGIntuneEnrol          = New-Object System.Windows.Controls.MenuItem
    $menuIMGIntuneEnrol.Header   = 'Intune Enrol [Experimental]'
    $menuIMGIntuneEnrol.IsEnabled = $false
    [void]$imgCtxMenu.Items.Add($menuIMGIntuneEnrol)

    $imgGrid = $script:IMGGrid

    $imgGrid.Add_PreviewMouseRightButtonDown({
        $node = $_.OriginalSource
        while ($null -ne $node -and $node -isnot [System.Windows.Controls.DataGridRow]) {
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        }
        if ($null -ne $node) { $node.IsSelected = $true }
    }.GetNewClosure())

    $imgGrid.Add_ContextMenuOpening({
        $sel = @($imgGrid.SelectedItems)
        $hasOne = ($sel.Count -eq 1 -and $null -ne $sel[0])
        $imgCtxMenu.Items[0].IsEnabled = $hasOne
        # Create Image disabled only when 2 jobs are already running
        $activeJobs = @($script:imgJobs | Where-Object { -not $_.Handle.IsCompleted }).Count
        $imgCtxMenu.Items[2].IsEnabled = $hasOne -and ($activeJobs -lt 2)
        $imgCtxMenu.Items[4].IsEnabled = $hasOne
        $imgCtxMenu.Items[6].IsEnabled = $hasOne
        $menuIMGIntuneEnrol.IsEnabled  = $hasOne
    }.GetNewClosure())

    $menuIMGRDP.Add_Click({
        try {
            $sel = @($imgGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            $row    = $sel[0]
            $vmName = [string]$row['VM Name']
            $ip     = [string]$row['IP Address']
            if ($ip -eq '-' -or [string]::IsNullOrWhiteSpace($ip)) { $ip = '' }
            Invoke-RDPToSessionHost -SessionHost $vmName -IPAddress $ip
        }
        catch {
            Show-ThemedDialog -Message "Failed to launch RDP: $_" -Title 'RDP Error' -Icon Error | Out-Null
        }
    }.GetNewClosure())

    $menuIMGCreateImage.Add_Click({
        $sel = @($imgGrid.SelectedItems)
        if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
        $vmName   = [string]$sel[0]['VM Name']
        $vmRG     = [string]$sel[0]['_RG']
        $vmRegion = [string]$sel[0]['Region']
        Invoke-ImagesCreateImageDialog -VMName $vmName -VMRG $vmRG -VMRegion $vmRegion
    }.GetNewClosure())

    $menuIMGSysprepLog.Add_Click({
        $sel = @($imgGrid.SelectedItems)
        if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
        $vmName     = [string]$sel[0]['VM Name']
        $vmRG       = [string]$sel[0]['_RG']
        $vmLocation = [string]$sel[0]['Region']
        $vmPowerState = [string]$sel[0]['Power State']
        $vmIP       = [string]$sel[0]['IP Address']
        Invoke-ImagesViewSysprepLog -VMName $vmName -VMRG $vmRG -VMLocation $vmLocation -PowerState $vmPowerState -IPAddress $vmIP
    }.GetNewClosure())

    $imgPortalSubId    = $SubscriptionId
    $imgPortalTenantId = $DefaultTenantId
    $menuIMGOpenPortal.Add_Click({
        $sel = @($imgGrid.SelectedItems)
        if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
        $rg  = [string]$sel[0]['_RG']
        $url = "https://portal.azure.com/#@$imgPortalTenantId/resource/subscriptions/$imgPortalSubId/resourceGroups/$rg/overview"
        Start-Process $url
    }.GetNewClosure())

    $menuIMGIntuneEnrol.Add_Click({
        $sel = @($imgGrid.SelectedItems)
        if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
        $vmName   = [string]$sel[0]['VM Name']
        $vmRG     = [string]$sel[0]['_RG']
        $vmRegion = [string]$sel[0]['Region']
        $confirm  = Show-ThemedDialog -Title 'Intune Enrol [Experimental]' `
            -Message "Assign system-managed identity and install AADLoginForWindows on:`n`n  $vmName`n`nThis is an experimental operation. Continue?" `
            -Buttons YesNo -Icon Warning
        if ($confirm -ne 'Yes') { return }
        Invoke-ImagesIntuneEnrol -VMName $vmName -RG $vmRG -Location $vmRegion
    }.GetNewClosure())

    $imgGrid.ContextMenu = $imgCtxMenu
}

# =============================================================================
# 4. Trigger a background data refresh
# =============================================================================

function Invoke-ImagesTabRefresh {
    if ($script:imgHandle -and -not $script:imgHandle.IsCompleted) { return }

    if ($script:ImgRGs.Count -eq 0) {
        $script:IMGStatusText.Text = 'No resource groups configured - add resource groups under Images in Settings'
        $script:imgNextRefresh     = [DateTime]::Now.AddSeconds($script:ImgRefreshIntervalSeconds)
        return
    }

    $script:IMGStatusText.Text = 'Refreshing...'
    $script:imgNextRefresh     = [DateTime]::Now.AddSeconds($script:ImgRefreshIntervalSeconds + 9999)

    $script:imgRefreshRunspace.SessionStateProxy.SetVariable('ArmToken',              (Get-ArmToken))
    $script:imgRefreshRunspace.SessionStateProxy.SetVariable('SubId',                $script:imgSubId)
    $script:imgRefreshRunspace.SessionStateProxy.SetVariable('RestHelperDef',        $script:restHelperDef)
    $script:imgRefreshRunspace.SessionStateProxy.SetVariable('LogFile',              $script:LogFile)
    $script:imgRefreshRunspace.SessionStateProxy.SetVariable('ImgRGsCsv',            ($script:ImgRGs -join ','))
    $script:imgRefreshRunspace.SessionStateProxy.SetVariable('ImgIncludePatternsCsv',($script:ImgIncludePatterns -join ','))

    $script:imgPS          = [System.Management.Automation.PowerShell]::Create()
    $script:imgPS.Runspace = $script:imgRefreshRunspace
    [void]$script:imgPS.AddScript($script:imgRefreshScript)
    $script:imgHandle      = $script:imgPS.BeginInvoke()
}

# =============================================================================
# 5a. Clean Snapshots
# =============================================================================

function Set-IMGActionStatus {
    param([string]$Text)
    $script:IMGActionStatus.Text    = $Text
    $script:IMGActionStatus.ToolTip = $Text
}

function Invoke-ImagesCleanSnapshots {
    if ($script:imgActionHandle -and -not $script:imgActionHandle.IsCompleted) {
        Show-ThemedDialog -Message 'An action is already in progress. Please wait.' -Title 'Busy' -Icon Information | Out-Null
        return
    }

    $tok   = Get-ArmToken
    $subId = if ($script:imgSubId) { $script:imgSubId } else { $subscriptionId }
    $rgs   = $script:ImgRGs

    # List all snapshots across all configured image RGs (fast synchronous call)
    $snapshots = [System.Collections.Generic.List[hashtable]]::new()
    $errors    = [System.Collections.Generic.List[string]]::new()
    foreach ($rg in $rgs) {
        try {
            $items = @(Get-ArmSnapshots -SubscriptionId $subId -ResourceGroup $rg -Token $tok)
            foreach ($s in $items) { $snapshots.Add(@{ Name = $s.name; RG = $rg }) }
        } catch {
            $errors.Add("$rg : $_")
            Write-Log "WARN [Images] Could not list snapshots in $rg : $_"
        }
    }

    if ($snapshots.Count -eq 0) {
        $msg = if ($errors.Count -gt 0) {
            "No snapshots found. Errors encountered:`n" + ($errors -join "`n")
        } else {
            "No snapshots found in:`n" + ($rgs -join "`n") + "`n`nSubscription: $subId"
        }
        Show-ThemedDialog -Message $msg -Title 'Clean Snapshots' -Icon Information | Out-Null
        return
    }

    $rgList  = ($rgs -join ', ')
    $names   = ($snapshots | ForEach-Object { $_.Name }) -join "`n  "
    $confirm = Show-ThemedDialog -Message "Delete $($snapshots.Count) snapshot(s) from: $rgList`n`n  $names`n`nThis cannot be undone." `
        -Title 'Clean Snapshots' -Buttons YesNo -Icon Warning
    if (-not $confirm) { return }

    Write-AuditLog -Action 'CleanSnapshots' -Target $rgList

    Set-IMGActionStatus "Deleting $($snapshots.Count) snapshot(s)..."
    $script:IMGCleanSnapshotsButton.IsEnabled = $false

    $snapshotsJson = ($snapshots | ForEach-Object { [PSCustomObject]$_ } | ConvertTo-Json -Compress)

    $deleteScript = [scriptblock]::Create($script:restHelperDef + @'
        $tok = $args[0]; $subId = $args[1]; $snapshotsJson = $args[2]
        $snapshots = $snapshotsJson | ConvertFrom-Json
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($s in $snapshots) {
            try {
                Invoke-Arm -Method DELETE -Path "/subscriptions/$subId/resourceGroups/$($s.RG)/providers/Microsoft.Compute/snapshots/$($s.Name)" -Token $tok -ApiVersion '2025-01-02' | Out-Null  # matches $script:ApiVersions.Snapshots
                $results.Add("Deleted: $($s.Name)")
            } catch {
                $results.Add("ERR: $($s.Name) - $_")
            }
        }
        $results -join ' | '
'@)

    $script:imgActionRS          = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:imgActionRS.Open()
    $script:imgActionPS          = [System.Management.Automation.PowerShell]::Create()
    $script:imgActionPS.Runspace = $script:imgActionRS
    [void]$script:imgActionPS.AddScript($deleteScript).AddArgument($tok).AddArgument($subId).AddArgument($snapshotsJson)
    $script:imgActionHandle      = $script:imgActionPS.BeginInvoke()
    $script:imgActionLabel       = 'CleanSnapshots'
}

# =============================================================================
# 5b. Clean Image Versions
# =============================================================================

function Invoke-ImagesCleanImageVersions {
    if ($script:imgActionHandle -and -not $script:imgActionHandle.IsCompleted) {
        Show-ThemedDialog -Message 'An action is already in progress. Please wait.' -Title 'Busy' -Icon Information | Out-Null
        return
    }

    $tok       = Get-ArmToken
    $subId     = if ($script:imgSubId) { $script:imgSubId } else { $subscriptionId }
    $keepCount = $script:ImgVersionsToKeep
    $galleryRGs = if ($script:ImgGalleryRGs -and $script:ImgGalleryRGs.Count -gt 0) {
        $script:ImgGalleryRGs
    } else {
        $script:ImgRGs
    }

    # Discover all galleries across configured RGs
    $galleries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($rg in $galleryRGs) {
        try {
            $gals = @(Get-ArmGalleries -SubscriptionId $subId -ResourceGroup $rg -Token $tok)
            foreach ($g in $gals) { $galleries.Add(@{ Name = $g.name; RG = $rg }) }
        } catch {
            Write-Log "WARN [Images] Could not list galleries in $rg : $_"
        }
    }

    if ($galleries.Count -eq 0) {
        Show-ThemedDialog -Message 'No Shared Image Galleries found in the configured resource groups.' -Title 'Clean Image Versions' -Icon Information | Out-Null
        return
    }

    # Build list of versions to delete across all galleries and definitions
    $toDelete = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($gal in $galleries) {
        try {
            $defs = @(Get-ArmGalleryImageDefinitions -SubscriptionId $subId -ResourceGroup $gal.RG -GalleryName $gal.Name -Token $tok)
            foreach ($def in $defs) {
                try {
                    $versions = @(Get-ArmGalleryImageVersions -SubscriptionId $subId -ResourceGroup $gal.RG -GalleryName $gal.Name -ImageDefinition $def.name -Token $tok)
                    # Sort descending by version name (semver: newest first), delete everything beyond $keepCount
                    $sorted = @($versions | Sort-Object { [version]$_.name } -Descending)
                    $excess = $sorted | Select-Object -Skip $keepCount
                    foreach ($v in $excess) {
                        $toDelete.Add(@{ Gallery = $gal.Name; RG = $gal.RG; Definition = $def.name; Version = $v.name })
                    }
                } catch {
                    Write-Log "WARN [Images] Could not list versions for $($def.name) in $($gal.Name): $_"
                }
            }
        } catch {
            Write-Log "WARN [Images] Could not list definitions in gallery $($gal.Name): $_"
        }
    }

    if ($toDelete.Count -eq 0) {
        Show-ThemedDialog -Message "No image versions to delete. Each definition already has $keepCount or fewer versions." -Title 'Clean Image Versions' -Icon Information | Out-Null
        return
    }

    $summary = ($toDelete | ForEach-Object { "  $($_.Definition)  v$($_.Version)  [$($_.Gallery)]" }) -join "`n"
    $confirm = Show-ThemedDialog -Message "Delete $($toDelete.Count) image version(s), keeping newest $keepCount per definition:`n`n$summary`n`nThis cannot be undone." `
        -Title 'Clean Image Versions' -Buttons YesNo -Icon Warning
    if (-not $confirm) { return }

    Write-AuditLog -Action 'CleanImageVersions' -Target "$($toDelete.Count) versions across $($galleries.Count) gallery/galleries (keep $keepCount)"

    Set-IMGActionStatus "Deleting $($toDelete.Count) image version(s)..."
    $script:IMGCleanImageVersionsButton.IsEnabled = $false

    $deleteJson = ($toDelete | ForEach-Object { [PSCustomObject]$_ } | ConvertTo-Json -Compress)

    $deleteScript = [scriptblock]::Create($script:restHelperDef + @'
        $tok = $args[0]; $subId = $args[1]; $deleteJson = $args[2]
        $items = $deleteJson | ConvertFrom-Json
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($item in $items) {
            try {
                Invoke-Arm -Method DELETE -Path "/subscriptions/$subId/resourceGroups/$($item.RG)/providers/Microsoft.Compute/galleries/$($item.Gallery)/images/$($item.Definition)/versions/$($item.Version)" -Token $tok -ApiVersion '2022-03-03' | Out-Null
                $results.Add("Deleted: $($item.Definition) v$($item.Version)")
            } catch {
                $results.Add("ERR: $($item.Definition) v$($item.Version) - $_")
            }
        }
        $results -join ' | '
'@)

    $script:imgActionRS          = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:imgActionRS.Open()
    $script:imgActionPS          = [System.Management.Automation.PowerShell]::Create()
    $script:imgActionPS.Runspace = $script:imgActionRS
    [void]$script:imgActionPS.AddScript($deleteScript).AddArgument($tok).AddArgument($subId).AddArgument($deleteJson)
    $script:imgActionHandle      = $script:imgActionPS.BeginInvoke()
    $script:imgActionLabel       = 'CleanImageVersions'
}

# =============================================================================
# 5. VM power actions (Start / Deallocate / Restart)
# =============================================================================

function Invoke-ImagesPowerAction {
    param([string]$Action)

    if ($script:imgActionHandle -and -not $script:imgActionHandle.IsCompleted) {
        Show-ThemedDialog -Message 'A power action is already in progress. Please wait for it to complete.' `
            -Title 'Action In Progress' -Icon Information | Out-Null
        return
    }

    $targets = @(foreach ($item in $script:IMGGrid.SelectedItems) {
        [PSCustomObject]@{ Name = [string]$item['VM Name']; RG = [string]$item['_RG']; PowerState = [string]$item['Power State'] }
    })
    if ($targets.Count -eq 0) { return }

    # Skip VMs already in the target state
    $skipped  = @()
    $original = $targets
    if ($Action -eq 'Deallocate' -or $Action -eq 'Restart') {
        $skipped = @($targets | Where-Object { $_.PowerState -in @('Deallocated', 'Stopped') })
        $targets = @($targets | Where-Object { $_.PowerState -notin @('Deallocated', 'Stopped') })
    } elseif ($Action -eq 'Start') {
        $skipped = @($targets | Where-Object { $_.PowerState -eq 'Running' })
        $targets = @($targets | Where-Object { $_.PowerState -ne 'Running' })
    }
    if ($targets.Count -eq 0) {
        $stateWord = if ($Action -eq 'Start') { 'running' } else { 'deallocated' }
        Set-IMGActionStatus "All $($original.Count) selected VM(s) are already $stateWord - nothing to do."
        return
    }
    $script:imgSkippedNote = ''
    if ($skipped.Count -gt 0) {
        $skippedNames = ($skipped | ForEach-Object { $_.Name }) -join ', '
        $script:imgSkippedNote = " | Skipped (already $( if ($Action -eq 'Start') { 'running' } else { 'deallocated' } )): $skippedNames"
    }

    $vmList = ($targets | ForEach-Object { $_.Name }) -join ', '

    if ($Action -in @('Deallocate', 'Restart')) {
        $icon    = if ($Action -eq 'Deallocate') { 'Warning' } else { 'Question' }
        $confirm = Show-ThemedDialog -Message "$Action the following VM(s)?`n`n$vmList" `
            -Title "Confirm $Action" -Buttons YesNo -Icon $icon
        if (-not $confirm) { return }
    }

    Write-AuditLog -Action "VM$Action" -Target ($vmList -replace ', ', '; ')

    Set-IMGActionStatus "$Action in progress: $vmList..."
    $script:IMGStartButton.IsEnabled      = $false
    $script:IMGDeallocateButton.IsEnabled = $false
    $script:IMGRestartButton.IsEnabled    = $false

    $restAction = switch ($Action) {
        'Start'      { 'start' }
        'Deallocate' { 'deallocate' }
        'Restart'    { 'restart' }
    }

    $actionScript = [scriptblock]::Create($script:restHelperDef + @'
        $tok = $args[0]; $subId = $args[1]; $targetsJson = $args[2]; $restAction = $args[3]
        $targets = $targetsJson | ConvertFrom-Json
        $results = [System.Collections.Generic.List[string]]::new()
        foreach ($t in $targets) {
            try {
                Invoke-Arm -Method POST -Path "/subscriptions/$subId/resourceGroups/$($t.RG)/providers/Microsoft.Compute/virtualMachines/$($t.Name)/$restAction" -Token $tok -ApiVersion '2024-07-01' -FullResponse | Out-Null
                $results.Add("OK: $($t.Name)")
            } catch {
                $results.Add("ERR: $($t.Name) - $_")
            }
        }
        $results -join ' | '
'@)

    $targetsJson = ($targets | ConvertTo-Json -Compress)
    $_subId = if ($script:imgSubId) { $script:imgSubId } else { $subscriptionId }

    $script:imgActionRS          = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:imgActionRS.Open()
    $script:imgActionPS          = [System.Management.Automation.PowerShell]::Create()
    $script:imgActionPS.Runspace = $script:imgActionRS
    [void]$script:imgActionPS.AddScript($actionScript).AddArgument((Get-ArmToken)).AddArgument($_subId).AddArgument($targetsJson).AddArgument($restAction)
    $script:imgActionHandle      = $script:imgActionPS.BeginInvoke()
    $script:imgActionLabel       = $Action
}

# =============================================================================
# 6. Per-second tick  -  called by the main DispatcherTimer every second
# =============================================================================

function Invoke-ImagesTabTimer {

    if (-not $script:IMGGrid.IsVisible) { return }

    # Trigger the scheduled refresh when due
    if ($script:imgNextRefresh -and [DateTime]::Now -ge $script:imgNextRefresh -and
        (-not $script:imgHandle -or $script:imgHandle.IsCompleted)) {
        Invoke-ImagesTabRefresh
    }

    # Collect completed refresh results
    if ($script:imgHandle -and $script:imgHandle.IsCompleted) {
        try {
            $imgData = $script:imgPS.EndInvoke($script:imgHandle)
            if ($imgData -and $imgData.VmRows) {
                _IMG_UpdateGrid -VmRows $imgData.VmRows -Timestamp $imgData.Timestamp
            }
            $script:imgNextRefresh = [DateTime]::Now.AddSeconds($script:ImgRefreshIntervalSeconds)
        } catch {
            $script:IMGStatusText.Text = "Images refresh error: $_"
            Write-Log "ERROR [Images] $_"
            $script:imgNextRefresh = [DateTime]::Now.AddSeconds($script:ImgRefreshIntervalSeconds)
        } finally {
            try { $script:imgPS.Dispose() } catch {}
            $script:imgHandle = $null
            $script:imgPS     = $null
        }
    }

    # Collect completed power action results
    if ($script:imgActionHandle -and $script:imgActionHandle.IsCompleted) {
        try {
            $rawResult = @($script:imgActionPS.EndInvoke($script:imgActionHandle))
            $result    = $rawResult -join ' | '
            Set-IMGActionStatus "$($script:imgActionLabel) initiated: $result$($script:imgSkippedNote)"
            if ($script:imgActionLabel -eq 'CleanSnapshots') {
                Write-AuditLog -Action 'CleanSnapshotsResult' -Details $result
            } elseif ($script:imgActionLabel -eq 'CleanImageVersions') {
                Write-AuditLog -Action 'CleanImageVersionsResult' -Details $result
            }
        } catch {
            Set-IMGActionStatus "$($script:imgActionLabel) error: $_"
            if ($script:imgActionLabel -in @('CleanSnapshots','CleanImageVersions')) {
                Write-AuditLog -Action "$($script:imgActionLabel)Error" -Result "$_"
            }
        } finally {
            try { $script:imgActionPS.Dispose() } catch {}
            try { $script:imgActionRS.Dispose() } catch {}
            $script:imgActionHandle = $null
            $script:imgActionPS     = $null
            $script:imgActionRS     = $null
            $has = $script:IMGGrid.SelectedItems.Count -gt 0
            $script:IMGStartButton.IsEnabled          = $has
            $script:IMGDeallocateButton.IsEnabled      = $has
            $script:IMGRestartButton.IsEnabled         = $has
            $script:IMGCleanSnapshotsButton.IsEnabled      = $true
            $script:IMGCleanImageVersionsButton.IsEnabled  = $true
        }
    }

    # Drain output queues and detect completion for all active jobs
    if ($script:imgJobs.Count -gt 0) {
        $completed = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($job in $script:imgJobs) {
            $line = $null
            $lines = [System.Collections.Generic.List[string]]::new()
            while ($job.Queue.TryDequeue([ref]$line)) { $lines.Add($line) }
            if ($lines.Count -gt 0) {
                $job.ConsoleBox.AppendText(($lines -join "`n") + "`n")
                $job.ConsoleBox.ScrollToEnd()
            }
            if ($job.Handle.IsCompleted) { $completed.Add($job) }
        }
        foreach ($job in $completed) { _IMG_StopJob -Job $job -UserRequested $false }
    }

    # Update live countdown / summary in the status bar
    if ($script:imgLastRefreshTime) {
        $remaining   = [Math]::Ceiling(($script:imgNextRefresh - [DateTime]::Now).TotalSeconds)
        $lastTs      = $script:imgLastRefreshTime.ToString('HH:mm:ss')
        $activeCount = if ($script:imgFilteredCountText) { $script:imgFilteredCountText } else { $script:imgCountText }
        $countStr    = if ($activeCount) { "$activeCount   |   " } else { '' }
        $script:IMGStatusText.Text = if ($script:imgHandle -and -not $script:imgHandle.IsCompleted) {
            "${countStr}Refreshing..."
        } else {
            "${countStr}Updated: $lastTs   Next in ${remaining}s"
        }
    }
}

# =============================================================================
# 7. Reset on subscription switch
# =============================================================================

function Reset-ImagesTab {
    $script:imgNextRefresh       = [DateTime]::Now
    $script:imgCachedGalleries   = $null
    $script:imgCachedDefs        = @{}
    $script:imgCachedVNets       = $null
    $script:imgCachedSubnets     = @{}
}

# =============================================================================
# 8. View Sysprep Log - fetches setuperr.log from VM via Run Command
# =============================================================================

function Invoke-ImagesViewSysprepLog {
    param([string]$VMName, [string]$VMRG, [string]$VMLocation, [string]$PowerState, [string]$IPAddress)

    $restHelperDef = $script:restHelperDef
    $subId         = $script:imgSubId
    $tok           = Get-ArmToken
    $location      = $VMLocation

    # Show a non-blocking popup immediately so the user sees something while fetching
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [xml]$logXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Sysprep Log" Height="520" Width="820"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip"
        Background="#1e1e1e">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="LogTitle" Grid.Row="0" Margin="0,0,0,6"
                   Foreground="#cccccc" FontSize="13" FontWeight="SemiBold"/>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto">
            <TextBox x:Name="LogBox" IsReadOnly="True" TextWrapping="NoWrap"
                     FontFamily="Consolas" FontSize="12" Background="#0d0d0d" Foreground="#d4d4d4"
                     BorderThickness="0" Padding="6" VerticalAlignment="Stretch"/>
        </ScrollViewer>
        <Button x:Name="CloseBtn" Grid.Row="2" Content="Close" Width="80" HorizontalAlignment="Right"
                Margin="0,8,0,0" Padding="0,4"/>
    </Grid>
</Window>
'@
    $logWin   = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $logXaml))
    $logTitle = $logWin.FindName('LogTitle')
    $logBox   = $logWin.FindName('LogBox')
    $closeBtn = $logWin.FindName('CloseBtn')

    try { Set-WindowIcon -Window $logWin -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}

    $logTitle.Text = "setuperr.log - $VMName"
    $closeBtn.Add_Click({ $logWin.Close() })

    $ipAddress  = $IPAddress
    $powerState = $PowerState

    # --- SMB path (always tried first if IP is available) ---
    $smbTarget = if ($ipAddress -and $ipAddress -ne '-') { $ipAddress } else { $VMName }
    $logPath   = "\\$smbTarget\C$\Windows\System32\Sysprep\Panther\setuperr.log"
    try {
        if (Test-Path $logPath -ErrorAction Stop) {
            $logBox.Text = Get-Content $logPath -Raw -ErrorAction Stop
            $logWin.ShowDialog() | Out-Null
            return
        }
    } catch {
        # SMB not reachable - fall through to Run Command
    }

    # --- Run Command fallback ---
    if ($powerState -ne 'Running') {
        $logBox.Text = "Cannot read log: SMB path '$logPath' was not reachable and VM '$VMName' is not running (Power State: $powerState).`nStart the VM or ensure SMB port 445 is accessible."
        $logWin.ShowDialog() | Out-Null
        return
    }

    $logBox.Text   = 'Fetching log via Run Command, please wait...'

    # Fetch the log in a background runspace; update the popup on the UI thread when done
    $fetchScript = [scriptblock]::Create($restHelperDef + @'
        $Tok = $args[0]; $SubId = $args[1]; $VMName = $args[2]; $VMRG = $args[3]; $Location = $args[4]
        $computeApi = '2024-03-01'
        $vmBase     = "/subscriptions/$SubId/resourceGroups/$VMRG/providers/Microsoft.Compute/virtualMachines"
        $readScript = '$p = "$env:SystemRoot\System32\Sysprep\Panther\setuperr.log"; if (Test-Path $p) { Get-Content $p -Raw } else { "File not found: $p" }'
        $body = @{
            location   = $Location
            properties = @{ source = @{ script = $readScript } }
        }
        $null = Invoke-Arm -Method PUT -Path "$vmBase/$VMName/runCommands/GetSysprepLog" -Token $Tok -ApiVersion $computeApi -Body $body -FullResponse
        $sw = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Seconds 5
            $status = Invoke-Arm -Path "$vmBase/$VMName/runCommands/GetSysprepLog" -Token $Tok -ApiVersion $computeApi -FullResponse
            $state  = $status.properties.provisioningState
        } while ($state -notin @('Succeeded','Failed') -and $sw.Elapsed.TotalSeconds -lt 60)

        if ($state -eq 'Succeeded') {
            $out = $status.properties.instanceView.output
            return $(if ($out) { $out } else { '(log was empty)' })
        } else {
            $err = $status.properties.instanceView.error
            return "Run Command state: $state`n$(if ($err) { $err })"
        }
'@)

    $fetchRS = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $fetchRS.ApartmentState = 'MTA'
    $fetchRS.Open()
    $fetchPS = [System.Management.Automation.PowerShell]::Create()
    $fetchPS.Runspace = $fetchRS
    [void]$fetchPS.AddScript($fetchScript).AddArgument($tok).AddArgument($subId).AddArgument($VMName).AddArgument($VMRG).AddArgument($location)
    $fetchHandle = $fetchPS.BeginInvoke()

    # Poll on the dispatcher until the runspace finishes, then update the TextBox
    $pollTimer  = New-Object System.Windows.Threading.DispatcherTimer
    $pollTimer.Interval = [TimeSpan]::FromSeconds(2)
    $pollTimer.Add_Tick({
        if (-not $fetchHandle.IsCompleted) { return }
        $pollTimer.Stop()
        try {
            $result = $fetchPS.EndInvoke($fetchHandle) -join "`n"
            if ([string]::IsNullOrWhiteSpace($result)) { $result = '(no output returned)' }
        } catch {
            $result = "ERROR: $_"
        }
        $fetchPS.Dispose(); $fetchRS.Dispose()
        $logBox.Text = $result
        $sv = [System.Windows.Media.VisualTreeHelper]::GetParent($logBox)
        if ($sv -is [System.Windows.Controls.ScrollViewer]) { $sv.ScrollToEnd() }
    }.GetNewClosure())
    $pollTimer.Start()

    $logWin.ShowDialog() | Out-Null
    $pollTimer.Stop()
}

# =============================================================================
# 9. Create Image dialog - discovers resources from Azure, caches for session
# =============================================================================

# =============================================================================
# 8a. Intune Enrolment [Experimental]
# =============================================================================

function Invoke-ImagesIntuneEnrol {
    param([string]$VMName, [string]$RG, [string]$Location)

    $enrollScript = Join-Path $PSScriptRoot 'enrol-intune.ps1'
    if (-not (Test-Path $enrollScript)) {
        Show-ThemedDialog -Title 'Script Not Found' `
            -Message "Cannot find enrol-intune.ps1 at:`n$enrollScript" `
            -Buttons OK -Icon Error
        return
    }

    $envVars = @{
        VM_NAME         = $VMName
        RESOURCE_GROUP  = $RG
        LOCATION        = $Location
        ARM_TOKEN       = Get-ArmToken
        SUBSCRIPTION_ID = $script:imgSubId
        REST_HELPER_DEF = $script:restHelperDef
    }
    $envVarsJson = $envVars | ConvertTo-Json -Compress

    $consoleTab, $consoleBox = _IMG_AddConsoleTab -VMName $VMName -GalleryName '' -ImageDefName 'Intune Enrol'
    _IMG_ShowConsole
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $consoleBox.AppendText("[$stamp] Starting Intune enrolment for $VMName`n")
    $consoleBox.AppendText("  Resource Group : $RG`n")
    $consoleBox.AppendText("  Location       : $Location`n")
    $consoleBox.AppendText(('-' * 60) + "`n")

    $queue     = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $jobScript = {
        param($ScriptPath, $EnvVarsJson, $Queue)
        $envMap = $EnvVarsJson | ConvertFrom-Json
        foreach ($prop in $envMap.PSObject.Properties) {
            [System.Environment]::SetEnvironmentVariable($prop.Name, $prop.Value, 'Process')
        }
        try {
            & $ScriptPath *>&1 | ForEach-Object {
                $line = if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    "ERROR: $($_.ToString())"
                } elseif ($_ -is [System.Management.Automation.WarningRecord]) {
                    "WARN:  $($_.Message)"
                } else {
                    $_.ToString()
                }
                $Queue.Enqueue($line)
            }
            $Queue.Enqueue('--- Intune enrolment completed successfully ---')
        } catch {
            $Queue.Enqueue("FATAL: $_")
            $Queue.Enqueue('--- Intune enrolment terminated with error ---')
        }
    }

    $rs               = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $ps          = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($jobScript).AddArgument($enrollScript).AddArgument($envVarsJson).AddArgument($queue)

    $job = @{ RS = $rs; PS = $ps; Handle = $ps.BeginInvoke(); Queue = $queue; ConsoleBox = $consoleBox; Tab = $consoleTab; LogPath = $null }
    $script:imgJobs.Add($job)
    $script:IMGConsoleStopButton.IsEnabled = $true
}

# Session-scoped caches so repeated opens don't re-fetch
$script:imgCachedGalleries   = $null   # @{ RG = '...'; Name = '...' }[]
$script:imgCachedDefs        = @{}     # key = "RG/GalleryName", value = string[]
$script:imgCachedVNets       = $null   # @{ RG = '...'; Name = '...'; Location = '...' }[]
$script:imgCachedSubnets     = @{}     # key = "RG/VNetName", value = string[]

function Invoke-ImagesCreateImageDialog {
    param([string]$VMName, [string]$VMRG, [string]$VMRegion)

    Write-Log "INFO [Images/CreateImage] Dialog opened - VM='$VMName' RG='$VMRG' Region='$VMRegion'"
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [xml]$dlgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Create Image" SizeToContent="Height" Width="520"
        ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        Background="#F4F6F9" FontFamily="Segoe UI">
    <StackPanel Margin="20,16,20,20">
        <TextBlock FontSize="15" FontWeight="SemiBold" Foreground="#0078D4"
                   Margin="0,0,0,16" x:Name="DlgTitle"/>

        <!-- Gallery -->
        <TextBlock Text="Gallery" FontSize="12" FontWeight="SemiBold" Foreground="#333" Margin="0,0,0,4"/>
        <ComboBox x:Name="GalleryCombo" Height="30" FontSize="12" IsEditable="False"/>

        <!-- Image Definition -->
        <TextBlock Text="Image Definition" FontSize="12" FontWeight="SemiBold" Foreground="#333" Margin="0,12,0,4"/>
        <ComboBox x:Name="DefCombo" Height="30" FontSize="12" IsEditable="False"/>

        <!-- VNet -->
        <TextBlock Text="Virtual Network" FontSize="12" FontWeight="SemiBold" Foreground="#333" Margin="0,12,0,4"/>
        <ComboBox x:Name="VNetCombo" Height="30" FontSize="12" IsEditable="False"/>

        <!-- Subnet -->
        <TextBlock Text="Subnet" FontSize="12" FontWeight="SemiBold" Foreground="#333" Margin="0,12,0,4"/>
        <ComboBox x:Name="SubnetCombo" Height="30" FontSize="12" IsEditable="False"/>

        <!-- VM Size -->
        <TextBlock Text="Preparation VM Size" FontSize="12" FontWeight="SemiBold" Foreground="#333" Margin="0,12,0,4"/>
        <ComboBox x:Name="VMSizeCombo" Height="30" FontSize="12" IsEditable="True"/>

        <!-- BIS-F Extension + Timeout on one row -->
        <Grid Margin="0,12,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="20"/>
                <ColumnDefinition Width="160"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <TextBlock Text="BIS-F / Sysprep Extension" FontSize="12" FontWeight="SemiBold" Foreground="#333" Margin="0,0,0,4"/>
                <ComboBox x:Name="ExtensionCombo" Height="30" FontSize="12" IsEditable="False">
                    <ComboBoxItem Content="true   (run BIS-F + Sysprep)"     Tag="true"/>
                    <ComboBoxItem Content="sysprep (skip BIS-F, Sysprep only)" Tag="sysprep"/>
                    <ComboBoxItem Content="false  (registry keys only)"      Tag="false"/>
                </ComboBox>
            </StackPanel>
            <StackPanel Grid.Column="2">
                <TextBlock Text="Timeout (minutes)" FontSize="12" FontWeight="SemiBold" Foreground="#333" Margin="0,0,0,4"/>
                <TextBox x:Name="TimeoutBox" Height="30" FontSize="12" Padding="8,4"
                         VerticalContentAlignment="Center" Text="35"/>
            </StackPanel>
        </Grid>

        <TextBlock x:Name="DlgStatus" FontSize="11" Foreground="#888"
                   Margin="0,10,0,0" TextWrapping="Wrap"/>

        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="DlgOK" Content="Create Image" Width="120" Height="30"
                    Background="#0078D4" Foreground="White" BorderThickness="0"
                    FontSize="12" FontWeight="SemiBold" Cursor="Hand" IsEnabled="False">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="BdOK" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BdOK" Property="Background" Value="#888"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BdOK" Property="Background" Value="#005A9E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button x:Name="DlgCancel" Content="Cancel" Width="80" Height="30"
                    Background="#E0E6ED" Foreground="#333" BorderThickness="0"
                    FontSize="12" Cursor="Hand" Margin="8,0,0,0">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="BdCx" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BdCx" Property="Background" Value="#C8D3DE"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>
    </StackPanel>
</Window>
'@

    $dlgReader  = New-Object System.Xml.XmlNodeReader $dlgXaml
    $dlg        = [System.Windows.Markup.XamlReader]::Load($dlgReader)
    $parentWin  = [System.Windows.Window]::GetWindow($script:IMGGrid)
    if ($parentWin) { $dlg.Owner = $parentWin }
    try { Set-WindowIcon -Window $dlg -IconPath (Join-Path $PSScriptRoot '..\data\avd-dashboard.ico') } catch {}

    $dlgTitle     = $dlg.FindName('DlgTitle')
    $galleryCombo = $dlg.FindName('GalleryCombo')
    $defCombo     = $dlg.FindName('DefCombo')
    $vnetCombo    = $dlg.FindName('VNetCombo')
    $subnetCombo  = $dlg.FindName('SubnetCombo')
    $vmSizeCombo  = $dlg.FindName('VMSizeCombo')
    $extCombo     = $dlg.FindName('ExtensionCombo')
    $timeoutBox   = $dlg.FindName('TimeoutBox')
    $dlgStatus    = $dlg.FindName('DlgStatus')
    $dlgOK        = $dlg.FindName('DlgOK')
    $dlgCancel    = $dlg.FindName('DlgCancel')

    $dlgTitle.Text = "Create image from: $VMName"
    $extCombo.SelectedIndex = 0   # default: run BIS-F + Sysprep

    # Populate VM size list and pre-select the configured default
    $prepSizes   = $script:ImgPrepVMSizes
    $prepDefault = $script:ImgPrepVMSizeDefault
    if (-not $prepSizes -or $prepSizes.Count -eq 0) { $prepSizes = @('Standard_D2s_v5','Standard_D4s_v5','Standard_D8s_v5') }
    if (-not $prepDefault) { $prepDefault = 'Standard_D4s_v5' }
    $vmSizeCombo.ItemsSource = $prepSizes
    $defaultIdx = [array]::IndexOf($prepSizes, $prepDefault)
    if ($defaultIdx -ge 0) { $vmSizeCombo.SelectedIndex = $defaultIdx } else { $vmSizeCombo.Text = $prepDefault }

    # Capture into locals so GetNewClosure() picks them up (script: scope not
    # accessible inside dynamic-module closures created by GetNewClosure).
    # Use a shared hashtable ($dlg_state) as a mutable container visible to all closures
    # - GetNewClosure() may create separate dynamic modules for each closure, making
    # $script: writes in one closure invisible to $script: reads in another.
    $restHelperDef = $script:restHelperDef
    $imgSubId      = $script:imgSubId
    $vmRegion      = $VMRegion

    $dlg_state = @{
        Galleries     = @()    # PSCustomObject[] populated in Add_Loaded
        FilteredVNets = @()    # region-filtered VNet PSCustomObject[] populated in Add_Loaded
        DefCache      = $script:imgCachedDefs     # shared hashtable: "RG/Gallery" -> string[]
    }

    # Helper: enable OK when all required fields are selected
    $checkReady = {
        $dlgOK.IsEnabled = (
            $galleryCombo.SelectedItem -and
            $defCombo.SelectedItem -and
            $vnetCombo.SelectedItem -and
            $subnetCombo.SelectedItem -and
            -not [string]::IsNullOrWhiteSpace([string]$vmSizeCombo.Text)
        )
    }

    # On load: fetch galleries and VNets (possibly from cache)
    $dlg.Add_Loaded({
        $dlgStatus.Text = 'Loading resources from Azure...'
        $galleryCombo.IsEnabled = $false
        $defCombo.IsEnabled     = $false
        $vnetCombo.IsEnabled    = $false
        $subnetCombo.IsEnabled  = $false

        try {
            . ([scriptblock]::Create($restHelperDef))
            $tok   = Get-ArmToken
            $subId = $imgSubId
            Write-Log "INFO [Images/CreateImage] Loaded handler - subId='$subId' region='$vmRegion'"

            # ---- Galleries: search across all configured Gallery RGs ----
            if (-not $script:imgCachedGalleries) {
                $found = [System.Collections.Generic.List[PSCustomObject]]::new()
                $galleryRGs = $script:ImgGalleryRGs
                if ($galleryRGs -and $galleryRGs.Count -gt 0) {
                    Write-Log "INFO [Images/CreateImage] Fetching galleries from $($galleryRGs.Count) configured RG(s): $($galleryRGs -join ', ')"
                    foreach ($rg in $galleryRGs) {
                        $gals = @(Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Compute/galleries" `
                                             -Token $tok -ApiVersion '2022-03-03')
                        Write-Log "INFO [Images/CreateImage] Gallery RG '$rg': $($gals.Count) gallery/galleries found"
                        foreach ($g in $gals) { $found.Add([PSCustomObject]@{ RG = $rg; Name = [string]$g.name }) }
                    }
                } else {
                    Write-Log "INFO [Images/CreateImage] No gallery RGs configured - fetching all galleries subscription-wide"
                    $allGals = @(Invoke-Arm -Path "/subscriptions/$subId/providers/Microsoft.Compute/galleries" `
                                             -Token $tok -ApiVersion '2022-03-03')
                    Write-Log "INFO [Images/CreateImage] Subscription-wide gallery fetch returned $($allGals.Count) result(s)"
                    foreach ($g in $allGals) {
                        $gRG = ($g.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                        $found.Add([PSCustomObject]@{ RG = $gRG; Name = [string]$g.name })
                    }
                }
                $script:imgCachedGalleries = @($found | Sort-Object Name)
            } else {
                Write-Log "INFO [Images/CreateImage] Using cached galleries ($($script:imgCachedGalleries.Count))"
            }
            # Store in dialog state so SelectionChanged closures can read it without $script: scope issues
            $dlg_state.Galleries = $script:imgCachedGalleries
            Write-Log "INFO [Images/CreateImage] Galleries available: $($dlg_state.Galleries.Count) - $($dlg_state.Galleries.Name -join ', ')"

            if ($dlg_state.Galleries.Count -eq 0) {
                Write-Log "WARN [Images/CreateImage] No galleries found - dialog will show error"
                $dlgStatus.Text = 'No Shared Image Galleries found in the subscription.'
            } else {
                $galleryCombo.ItemsSource = @($dlg_state.Galleries | ForEach-Object { "$($_.Name)  [$($_.RG)]" })
                $galleryCombo.IsEnabled = $true
                $galleryCombo.SelectedIndex = 0
            }

            # ---- VNets: subscription-wide, filtered to the VM's region ----
            if (-not $script:imgCachedVNets) {
                Write-Log "INFO [Images/CreateImage] Fetching VNets subscription-wide"
                $vnets = @(Invoke-Arm -Path "/subscriptions/$subId/providers/Microsoft.Network/virtualNetworks" `
                                       -Token $tok -ApiVersion '2023-05-01')
                Write-Log "INFO [Images/CreateImage] VNet list returned $($vnets.Count) VNet(s)"
                $script:imgCachedVNets = @($vnets | ForEach-Object {
                    $vRG      = ($_.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                    $vSubnets = @($_.properties.subnets | ForEach-Object { [string]$_.name } | Sort-Object)
                    [PSCustomObject]@{ RG = $vRG; Name = [string]$_.name; Location = [string]$_.location; Subnets = $vSubnets }
                } | Sort-Object Name)
            } else {
                Write-Log "INFO [Images/CreateImage] Using cached VNets ($($script:imgCachedVNets.Count))"
            }

            $filteredVNets = if ($vmRegion) {
                @($script:imgCachedVNets | Where-Object { $_.Location -eq $vmRegion })
            } else {
                @($script:imgCachedVNets)
            }
            $dlg_state.FilteredVNets = $filteredVNets
            Write-Log "INFO [Images/CreateImage] VNets after region filter ('$vmRegion'): $($filteredVNets.Count) - $($filteredVNets.Name -join ', ')"

            if ($filteredVNets.Count -eq 0) {
                $regionNote = if ($vmRegion) { " in region '$vmRegion'" } else { '' }
                Write-Log "WARN [Images/CreateImage] No VNets found${regionNote}"
                $dlgStatus.Text = "No virtual networks found${regionNote}."
            } else {
                $vnetCombo.ItemsSource = @($filteredVNets | ForEach-Object { "$($_.Name)  [$($_.RG)]" })
                $vnetCombo.IsEnabled = $true
                $vnetCombo.SelectedIndex = 0

                # Populate subnets for the default VNet here (in Loaded scope where
                # ARM functions are already dot-sourced and tok/subId are in scope).
                $firstVNet = $filteredVNets[0]
                Write-Log "INFO [Images/CreateImage] Fetching subnets for initial VNet '$($firstVNet.Name)' RG='$($firstVNet.RG)'"
                $vnetDetail = Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$($firstVNet.RG)/providers/Microsoft.Network/virtualNetworks/$($firstVNet.Name)" `
                                          -Token $tok -ApiVersion '2023-05-01' -FullResponse
                $initSubnets = @($vnetDetail.properties.subnets | ForEach-Object { [string]$_.name } | Where-Object { $_ -ine 'GatewaySubnet' } | Sort-Object)
                Write-Log "INFO [Images/CreateImage] Initial subnet fetch returned $($initSubnets.Count) subnet(s): $($initSubnets -join ', ')"
                if ($initSubnets.Count -gt 0) {
                    $subnetCombo.ItemsSource   = $initSubnets
                    $subnetCombo.SelectedIndex = 0
                    $subnetCombo.IsEnabled     = $true
                } else {
                    Write-Log "WARN [Images/CreateImage] No subnets returned for VNet '$($firstVNet.Name)' - subnet combo will remain disabled"
                }
            }

            if ($dlgStatus.Text -notlike 'No *') { $dlgStatus.Text = '' }
        } catch {
            Write-Log "ERROR [Images/CreateImage] Loaded handler exception: $_"
            $dlgStatus.Text = "Failed to load resources: $_"
        }
    }.GetNewClosure())

    # Gallery selection -> load image definitions
    $galleryCombo.Add_SelectionChanged({
        $idx = $galleryCombo.SelectedIndex
        $galleries = $dlg_state.Galleries
        if ($idx -lt 0 -or -not $galleries -or $idx -ge $galleries.Count) { return }
        $selGal   = $galleries[$idx]
        $cacheKey = "$($selGal.RG)/$($selGal.Name)"
        Write-Log "INFO [Images/CreateImage] Gallery selected: '$($selGal.Name)' RG='$($selGal.RG)'"

        $defCombo.ItemsSource = $null
        $defCombo.IsEnabled   = $false
        & $checkReady

        if ($dlg_state.DefCache.ContainsKey($cacheKey)) {
            $defNames = $dlg_state.DefCache[$cacheKey]
            Write-Log "INFO [Images/CreateImage] Image definitions from cache: $($defNames.Count)"
        } else {
            $dlgStatus.Text = 'Fetching image definitions...'
            try {
                . ([scriptblock]::Create($restHelperDef))
                $tok   = Get-ArmToken
                $subId = $imgSubId
                Write-Log "INFO [Images/CreateImage] Fetching image definitions for gallery '$($selGal.Name)'"
                $defs  = @(Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$($selGal.RG)/providers/Microsoft.Compute/galleries/$($selGal.Name)/images" `
                                       -Token $tok -ApiVersion '2022-03-03')
                $defNames = @($defs | ForEach-Object { [string]$_.name } | Sort-Object)
                Write-Log "INFO [Images/CreateImage] Image definitions fetched: $($defNames.Count) - $($defNames -join ', ')"
                $dlg_state.DefCache[$cacheKey] = $defNames
                $dlgStatus.Text = ''
            } catch {
                Write-Log "ERROR [Images/CreateImage] Failed to fetch image definitions: $_"
                $dlgStatus.Text = "Failed to load image definitions: $_"
                return
            }
        }

        if ($defNames.Count -eq 0) {
            Write-Log "WARN [Images/CreateImage] No image definitions found in gallery '$($selGal.Name)'"
            $dlgStatus.Text = "No image definitions found in gallery '$($selGal.Name)'."
        } else {
            $defCombo.ItemsSource   = $defNames
            $defCombo.SelectedIndex = 0
            $defCombo.IsEnabled     = $true
        }
        & $checkReady
    }.GetNewClosure())

    # VNet selection -> load subnets
    $vnetCombo.Add_SelectionChanged({
        $idx      = $vnetCombo.SelectedIndex
        $vnets    = $dlg_state.FilteredVNets
        if ($idx -lt 0 -or -not $vnets -or $idx -ge $vnets.Count) { return }
        $selVNet  = $vnets[$idx]
        Write-Log "INFO [Images/CreateImage] VNet selected: '$($selVNet.Name)' RG='$($selVNet.RG)' Location='$($selVNet.Location)'"

        $subnetCombo.ItemsSource = $null
        $subnetCombo.IsEnabled   = $false
        & $checkReady

        try {
            . ([scriptblock]::Create($restHelperDef))
            $tok     = Get-ArmToken
            $subId   = $imgSubId
            Write-Log "INFO [Images/CreateImage] Fetching subnets for VNet '$($selVNet.Name)' (subId='$subId')"
            $vnetDet = Invoke-Arm -Path "/subscriptions/$subId/resourceGroups/$($selVNet.RG)/providers/Microsoft.Network/virtualNetworks/$($selVNet.Name)" `
                                   -Token $tok -ApiVersion '2023-05-01' -FullResponse
            $subnetNames = @($vnetDet.properties.subnets | ForEach-Object { [string]$_.name } | Where-Object { $_ -ine 'GatewaySubnet' } | Sort-Object)
            Write-Log "INFO [Images/CreateImage] Subnet fetch returned $($subnetNames.Count) subnet(s): $($subnetNames -join ', ')"
        } catch {
            Write-Log "ERROR [Images/CreateImage] Subnet fetch failed for VNet '$($selVNet.Name)': $_"
            $dlgStatus.Text = "Failed to load subnets: $_"
            & $checkReady
            return
        }

        if ($subnetNames.Count -eq 0) {
            Write-Log "WARN [Images/CreateImage] No subnets found in VNet '$($selVNet.Name)'"
            $dlgStatus.Text = "No subnets found in VNet '$($selVNet.Name)'."
        } else {
            $subnetCombo.ItemsSource   = $subnetNames
            $subnetCombo.SelectedIndex = 0
            $subnetCombo.IsEnabled     = $true
            $dlgStatus.Text            = ''
        }
        & $checkReady
    }.GetNewClosure())

    $defCombo.Add_SelectionChanged(   { & $checkReady }.GetNewClosure())
    $subnetCombo.Add_SelectionChanged({ & $checkReady }.GetNewClosure())
    $vmSizeCombo.Add_SelectionChanged({ & $checkReady }.GetNewClosure())

    $dlgOK.Add_Click({
        $galIdx  = $galleryCombo.SelectedIndex
        $vnetIdx = $vnetCombo.SelectedIndex
        if ($galIdx -lt 0 -or $vnetIdx -lt 0) { return }
        $selGal  = $dlg_state.Galleries[$galIdx]
        $selVNet = $dlg_state.FilteredVNets[$vnetIdx]
        if (-not $selGal -or -not $selVNet) { return }
        $selDef    = [string]$defCombo.SelectedItem
        $selSubnet = [string]$subnetCombo.SelectedItem
        $selSize   = [string]$vmSizeCombo.Text
        if (-not $selDef -or -not $selSubnet -or -not $selSize) { return }

        # Read Extension tag value from the selected ComboBoxItem
        $extTag = [string]($extCombo.SelectedItem.Tag)
        if (-not $extTag) { $extTag = 'true' }

        $timeout = 35
        [int]::TryParse($timeoutBox.Text.Trim(), [ref]$timeout) | Out-Null
        if ($timeout -le 0) { $timeout = 35 }

        Write-Log "INFO [Images/CreateImage] User confirmed - Gallery='$($selGal.Name)' Def='$selDef' VNet='$($selVNet.Name)' Subnet='$selSubnet' Size='$selSize' Extension='$extTag' Timeout=${timeout}m"
        $dlg.Tag = [PSCustomObject]@{
            GalleryRG    = $selGal.RG
            GalleryName  = $selGal.Name
            ImageDefName = $selDef
            NetRGName    = $selVNet.RG
            VNetName     = $selVNet.Name
            SubnetName   = $selSubnet
            VMLocation   = $selVNet.Location
            PrepVMSize   = $selSize
            Extension    = $extTag
            Timeout      = $timeout
        }
        $dlg.DialogResult = $true
        $dlg.Close()
    }.GetNewClosure())
    $dlgCancel.Add_Click({ $dlg.Close() })

    $result = $dlg.ShowDialog()
    if ($result -ne $true) { return }

    $p = $dlg.Tag
    Invoke-ImagesCreateImage `
        -VMName      $VMName `
        -VMRG        $VMRG `
        -GalleryRG   $p.GalleryRG `
        -GalleryName $p.GalleryName `
        -ImageDefName $p.ImageDefName `
        -NetRGName   $p.NetRGName `
        -VNetName    $p.VNetName `
        -SubnetName  $p.SubnetName `
        -VMLocation  $p.VMLocation `
        -PrepVMSize  $p.PrepVMSize `
        -Extension   $p.Extension `
        -Timeout     $p.Timeout
}

# =============================================================================
# 10. Launch Create-Image.ps1 in a background runspace, stream output to a new console tab
# =============================================================================

function Invoke-ImagesCreateImage {
    param(
        [string]$VMName,
        [string]$VMRG,
        [string]$GalleryRG,
        [string]$GalleryName,
        [string]$ImageDefName,
        [string]$NetRGName,
        [string]$VNetName,
        [string]$SubnetName,
        [string]$VMLocation,
        [string]$PrepVMSize,
        [string]$Extension   = 'true',
        [int]   $Timeout     = 35
    )

    # Reject if 2 jobs are already running
    $activeCount = @($script:imgJobs | Where-Object { -not $_.Handle.IsCompleted }).Count
    if ($activeCount -ge 2) {
        Show-ThemedDialog -Message 'Two image creation jobs are already running. Stop one before starting another.' `
            -Title 'Max Jobs Running' -Icon Warning | Out-Null
        return
    }

    # Validate create-image.ps1 exists
    $createImageScript = Join-Path $PSScriptRoot 'create-image.ps1'
    if (-not (Test-Path $createImageScript)) {
        Show-ThemedDialog -Message "Cannot find create-image.ps1 at:`n$createImageScript" `
            -Title 'Script Not Found' -Icon Error | Out-Null
        return
    }

    Write-AuditLog -Action 'CreateImage' -Target $VMName

    # Build env var map entirely from dialog selections
    $envVars = @{
        IMAGE_VM_NAME    = $VMName
        IMAGE_RG_NAME    = $VMRG
        LOCATION         = $VMLocation
        NET_RG_NAME      = $NetRGName
        VNET_NAME        = $VNetName
        SUBNET_NAME      = $SubnetName
        GALLERY_NAME     = $GalleryName
        GALLERY_RG_NAME  = $GalleryRG
        IMAGE_DEF_NAME   = $ImageDefName
        PrepVMSize       = $PrepVMSize
        EXTENSION        = $Extension
        TIMEOUTINMINUTES = [string]$Timeout
        BISF_PATH              = $script:ImgBisFPath
        REPLICATION_REGION1         = $script:ImgRegion1
        REPLICATION_REGION1_REPLICAS = [string]$script:ImgRegion1Replicas
        REPLICATION_REGION2         = $script:ImgRegion2
        REPLICATION_REGION2_REPLICAS = [string]$script:ImgRegion2Replicas
        ARM_TOKEN        = Get-ArmToken
        SUBSCRIPTION_ID  = $script:imgSubId
        REST_HELPER_DEF  = $script:restHelperDef
    }

    # Create a new output tab for this run and make it active
    $consoleTab, $consoleBox = _IMG_AddConsoleTab -VMName $VMName -GalleryName $GalleryName -ImageDefName $ImageDefName
    _IMG_ShowConsole
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $consoleBox.AppendText("[$stamp] Starting image creation for $VMName`n")
    $consoleBox.AppendText("  Gallery   : $GalleryName`n")
    $consoleBox.AppendText("  Definition: $ImageDefName`n")
    $consoleBox.AppendText(("-" * 60) + "`n")

    $queue       = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $scriptPath  = $createImageScript
    $envVarsJson = $envVars | ConvertTo-Json -Compress

    $jobScript = {
        param($ScriptPath, $EnvVarsJson, $Queue)

        $envMap = $EnvVarsJson | ConvertFrom-Json
        foreach ($prop in $envMap.PSObject.Properties) {
            [System.Environment]::SetEnvironmentVariable($prop.Name, $prop.Value, 'Process')
        }

        try {
            & $ScriptPath *>&1 | ForEach-Object {
                $line = if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    "ERROR: $($_.ToString())"
                } elseif ($_ -is [System.Management.Automation.WarningRecord]) {
                    "WARN:  $($_.Message)"
                } else {
                    $_.ToString()
                }
                $Queue.Enqueue($line)
            }
            $Queue.Enqueue('--- Image creation completed successfully ---')
        } catch {
            $Queue.Enqueue("FATAL: $_")
            $Queue.Enqueue('--- Image creation terminated with error ---')
        }
    }

    $rs               = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()

    $ps           = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace  = $rs
    $null = $ps.AddScript($jobScript).AddArgument($scriptPath).AddArgument($envVarsJson).AddArgument($queue)

    $logDir     = Join-Path $script:AuditLogDir 'logs\image-creation'
    $logStamp   = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $logPath    = Join-Path $logDir "$($VMName)_$logStamp.log"

    $job = @{ RS = $rs; PS = $ps; Handle = $ps.BeginInvoke(); Queue = $queue; ConsoleBox = $consoleBox; Tab = $consoleTab; LogPath = $logPath }
    $script:imgJobs.Add($job)

    # Stop button enabled whenever any job is active
    $script:IMGConsoleStopButton.IsEnabled = $true
}

# =============================================================================
# 10. Show / hide the console panel
# =============================================================================

function _IMG_ShowConsole {
    $script:IMGConsolePanel.Visibility    = 'Visible'
    $script:IMGConsoleSplitter.Visibility = 'Visible'
    $grid = $script:IMGConsolePanel.Parent
    $rdGrid    = $grid.RowDefinitions[0]   # DataGrid row
    $rdConsole = $grid.RowDefinitions[2]   # Console row

    # Only set the split the first time (console row still collapsed at 0).
    # DataGrid row = Auto (sizes to content, no scrollbar), console row = * (fills the rest).
    # The GridSplitter lets the user adjust freely after the initial layout.
    if ($rdConsole.Height.Value -lt 1) {
        $rdGrid.Height    = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Auto)
        $rdConsole.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    }
}

# Creates a new tab in the console TabControl for one image creation run.
# Returns [TabItem, TextBox] so the caller can store both; the Tab ref is needed
# to update the header/background when the job finishes.
function _IMG_AddConsoleTab {
    param([string]$VMName, [string]$GalleryName, [string]$ImageDefName)

    $tc    = $script:IMGConsoleTabControl
    $stamp = Get-Date -Format 'HH:mm'

    $textBox = New-Object System.Windows.Controls.TextBox
    $textBox.Background                    = [System.Windows.Media.Brushes]::Transparent
    $textBox.Foreground                    = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xD4, 0xD4, 0xD4))
    $textBox.FontFamily                    = New-Object System.Windows.Media.FontFamily('Consolas')
    $textBox.FontSize                      = 12
    $textBox.IsReadOnly                    = $true
    $textBox.AcceptsReturn                 = $true
    $textBox.TextWrapping                  = [System.Windows.TextWrapping]::NoWrap
    $textBox.VerticalScrollBarVisibility   = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $textBox.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $textBox.BorderThickness               = [System.Windows.Thickness]::new(0)
    $textBox.Padding                       = [System.Windows.Thickness]::new(10, 6, 10, 6)
    $textBox.ToolTip                       = "Gallery: $GalleryName  |  Definition: $ImageDefName"

    $tab            = New-Object System.Windows.Controls.TabItem
    $tab.Header     = "$VMName  $stamp  [Running]"
    $tab.Tag        = 'active'     # marks as the running tab; cleared on completion
    $tab.Content    = $textBox

    [void]$tc.Items.Add($tab)
    $tc.SelectedItem = $tab

    return $tab, $textBox
}

# =============================================================================
# 11. Stop an image creation job (user-requested or on natural completion)
# =============================================================================

# Stops a single job slot and removes it from $script:imgJobs.
# $Job is the hashtable @{ RS; PS; Handle; Queue; ConsoleBox } from the jobs list.
function _IMG_StopJob {
    param([hashtable]$Job, [bool]$UserRequested = $false)

    if ($Job.Handle.IsCompleted) {
        try {
            $Job.PS.EndInvoke($Job.Handle) | Out-Null
            $errs = @($Job.PS.Streams.Error)
            foreach ($e in $errs) { $Job.Queue.Enqueue("STREAM ERROR: $($e.ToString())") }
        } catch {
            $Job.Queue.Enqueue("EndInvoke error: $_")
        }
    }

    if ($UserRequested -and -not $Job.Handle.IsCompleted) {
        $Job.Queue.Enqueue('--- Job stopped by user ---')
        try { $Job.PS.Stop() } catch {}
    }

    try { $Job.PS.Dispose() } catch {}
    try { $Job.RS.Dispose() } catch {}
    [void]$script:imgJobs.Remove($Job)

    # Update tab header and background to reflect completion status
    $tab = $Job.Tab
    if ($null -ne $tab) {
        $baseHeader     = [string]$tab.Header -replace '\s*\[Running\]', ''
        $tab.Tag        = 'done'
        $tab.Header     = if ($UserRequested) { "$baseHeader  [Stopped]" } else { "$baseHeader  [Done]" }
        $tab.Background = $null
    }

    # Save console output to log file
    if ($Job.LogPath -and $Job.ConsoleBox) {
        try {
            $logDir = Split-Path $Job.LogPath
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            [System.IO.File]::WriteAllText($Job.LogPath, $Job.ConsoleBox.Text)
        } catch {}
    }

    # Disable Stop button only when no jobs remain active
    $anyActive = @($script:imgJobs | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0
    $script:IMGConsoleStopButton.IsEnabled = $anyActive
}

# Stops the job whose output is currently selected in the tab strip.
# Called by the Stop button and by Close Tab on an active tab.
function _IMG_StopActiveTab {
    param([bool]$UserRequested = $true)
    $sel = $script:IMGConsoleTabControl.SelectedItem
    if (-not $sel) { return }
    $job = $script:imgJobs | Where-Object { $_.ConsoleBox -eq $sel.Content } | Select-Object -First 1
    if ($job) { _IMG_StopJob -Job $job -UserRequested $UserRequested }
}

# =============================================================================
# 12. Export grid to CSV
# =============================================================================

function Invoke-ImagesExport {
    if (-not $script:imgDataTable) { return }

    $dlg          = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = "Images_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"

    if ($dlg.ShowDialog() -eq $true) {
        try {
            $script:imgDataTable.Rows |
                ForEach-Object {
                    $row = $_
                    $obj = [ordered]@{}
                    foreach ($col in $script:imgDataTable.Columns) {
                        if ($col.ColumnName -notin @('_RG', '_OsDiskName')) {
                            $obj[$col.ColumnName] = $row[$col.ColumnName]
                        }
                    }
                    [PSCustomObject]$obj
                } |
                Export-Csv -Path $dlg.FileName -NoTypeInformation -Force
            $script:IMGStatusText.Text = "Exported $($script:imgDataTable.Rows.Count) row(s) to $($dlg.FileName)"
        } catch {
            Show-ThemedDialog -Message "Export failed:`n$_" -Title 'Export Error' -Icon Error | Out-Null
        }
    }
}

# =============================================================================
# Private helpers
# =============================================================================

function _IMG_UpdateGrid {
    param($VmRows, $Timestamp)

    $script:imgLastVmRows = @($VmRows)
    $script:imgDataTable  = ConvertTo-DataTable -Objects @($VmRows)

    $filter = $script:IMGFilterBox.Text.Trim()
    if (-not [string]::IsNullOrEmpty($filter)) {
        $script:imgDataTable.DefaultView.RowFilter = "([VM Name] LIKE '%$filter%') OR ([Resource Group] LIKE '%$filter%') OR ([Power State] LIKE '%$filter%')"
        $view   = $script:imgDataTable.DefaultView
        $fTotal = $view.Count
        $fRun   = @($view | Where-Object { $_['Power State'] -eq 'Running' }).Count
        $script:imgFilteredCountText = "$fTotal VM(s)   Running: $fRun   Other: $([Math]::Max(0, $fTotal - $fRun))"
    } else {
        $script:imgFilteredCountText = $null
    }

    $script:IMGGrid.ItemsSource        = $script:imgDataTable.DefaultView
    $script:IMGExportButton.IsEnabled  = $true

    $runCount              = @($VmRows | Where-Object { $_.'Power State' -eq 'Running' }).Count
    $script:imgCountText   = "$($VmRows.Count) VM(s)   Running: $runCount   Other: $([Math]::Max(0, $VmRows.Count - $runCount))"
    $script:imgLastRefreshTime = $Timestamp
}
