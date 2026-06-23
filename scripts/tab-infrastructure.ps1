# =============================================================================
# tab-infrastructure.ps1  -  Infrastructure Servers tab module
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Encapsulates everything needed for the Infrastructure tab in one file so the
# main dashboard script stays clean. Dot-source this file BEFORE the XAML
# string is built; the main script then injects $InfrastructureTab_Xaml into
# its XAML via a placeholder comment and calls the three public lifecycle functions:
#
#   Initialize-InfrastructureTab  - once, after $window is loaded
#   Invoke-InfrastructureTabTimer - every second from the master DispatcherTimer
#   Reset-InfrastructureTab       - on subscription switch (triggers immediate refresh)
#
# DATA FLOW
# ---------
# The tab runs a dedicated background refresh every 60 seconds using a single
# persistent runspace. All Azure calls use direct REST API via bearer token.
# Each refresh cycle:
#   1. Lists VMs per resource group via REST, then fetches instanceView per VM for
#      power state ($expand=instanceView is only supported for VMSS, not regular VMs)
#   2. For each VM, resolves the private IP via REST GET on the first NIC resource ID
#   3. Returns VM Name, Resource Group, Region, Power State, OS Type, IP Address,
#      VM SKU and Availability Zone - all in a single pass, no on-demand button needed
#
# VMs whose names match any entry in InfrastructureServers.ExcludePatterns
# (case-insensitive substring match) are silently skipped.
#
# POWER ACTIONS
# -------------
# Start / Deallocate / Restart run in a fresh throw-away runspace each time so
# the dedicated refresh runspace is never blocked. Progress is polled by
# Invoke-InfrastructureTabTimer every second; buttons are re-enabled on completion.
# Drain mode is not applicable to infrastructure VMs and is therefore absent.
# =============================================================================

# PSScriptAnalyzer flags $InfrastructureTab_Xaml as "assigned but never used" because it
# cannot see across the dot-source boundary into the calling script.
# This suppression attribute silences that false positive.
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'InfrastructureTab_Xaml',
    Justification = 'Exported to the calling script via dot-source')]
param()

# =============================================================================
# 1. XAML fragment
#
# The main script contains the placeholder comment <!-- TAB:INFRASTRUCTURE -->
# inside its TabControl. Before parsing the XAML it does a string replace:
#   $rawXaml -replace '<!-- TAB:INFRASTRUCTURE -->', $InfrastructureTab_Xaml
#
# Layout (DockPanel, top-to-bottom):
#   Top border   - Filter text box + ISStatusText (countdown / summary) + Refresh button + Export CSV
#   Bottom border- ISActionStatus label (left) + Start / Deallocate / Restart buttons (right)
#   Centre fill  - ISGrid (DataGrid, multi-select, auto-column)
# =============================================================================

$InfrastructureTab_Xaml = @'
<TabItem Header="Infrastructure"
         xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <DockPanel>
        <!-- ═══ Top bar: filter input, status text and manual refresh button ═══ -->
        <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.CostBar.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1"
                Padding="12,7">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>   <!-- "Filter:" label -->
                    <ColumnDefinition Width="220"/>    <!-- text box -->
                    <ColumnDefinition Width="*"/>      <!-- spacer -->
                    <ColumnDefinition Width="Auto"/>   <!-- status / countdown -->
                    <ColumnDefinition Width="Auto"/>   <!-- Refresh button -->
                    <ColumnDefinition Width="Auto"/>   <!-- Export CSV button -->
                    <ColumnDefinition Width="Auto"/>   <!-- Load Costs button -->
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Filter:"
                           VerticalAlignment="Center"
                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}"
                           Margin="0,0,8,0"/>
                <!-- ISFilterBox: TextChanged fires a DataView.RowFilter update -->
                <TextBox x:Name="ISFilterBox" Grid.Column="1"
                         FontSize="12" Padding="8,4"
                         VerticalContentAlignment="Center"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" Foreground="{DynamicResource Avd.Fg.Label}"/>
                <!-- ISStatusText: shows "Running: X  Other: Y | Updated: HH:mm:ss  Next in Ns" -->
                <TextBlock x:Name="ISStatusText" Grid.Column="3"
                           VerticalAlignment="Center"
                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Hint}"
                           Margin="0,0,12,0"/>
                <!-- ISRefreshButton: triggers an immediate out-of-schedule refresh -->
                <Button x:Name="ISRefreshButton" Grid.Column="4"
                        Content="Refresh"
                        Background="{DynamicResource Avd.Btn.Accent.Bg}" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="12,3" Margin="0,0,6,0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdIR" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdIR" Property="Background" Value="{DynamicResource Avd.Btn.Accent.Hover}"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdIR" Property="Background" Value="#003D6B"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <!-- ISLoadCostsButton: fetches PAYG pricing from Azure Retail Prices API -->
                <Button x:Name="ISLoadCostsButton" Grid.Column="5"
                        Content="Load Costs"
                        Background="#0E7A0D" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,5" Margin="0,0,6,0"
                        IsEnabled="False"
                        ToolTip="Fetch estimated monthly costs from the Azure Retail Prices API (public, no auth required)">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdILC" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="BdILC" Property="Background" Value="#888"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdILC" Property="Background" Value="#0B5E0A"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdILC" Property="Background" Value="#084507"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <!-- ISExportButton: exports the current grid contents to CSV -->
                <Button x:Name="ISExportButton" Grid.Column="6"
                        Content="Export CSV"
                        Background="#005A9E" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,5"
                        IsEnabled="False">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdIEx" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="BdIEx" Property="Background" Value="#888"/>
                                </Trigger>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdIEx" Property="Background" Value="#004F8C"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdIEx" Property="Background" Value="#003D6B"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>
        </Border>

        <!-- ═══ Cost totals bar - shown after Load Costs is clicked ═══ -->
        <Border x:Name="ISTotalsBar" DockPanel.Dock="Bottom" Background="{DynamicResource Avd.CostBar.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,1,0,0"
                Height="28" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Left"
                        VerticalAlignment="Center" Margin="12,0">
                <TextBlock Text="Totals:" FontSize="11" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,16,0" VerticalAlignment="Center"/>
                <TextBlock Text="Compute GBP/mo:" FontSize="11" Foreground="{DynamicResource Avd.Fg.Secondary}"
                           Margin="0,0,6,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="ISTotalCompute" FontSize="11" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" Margin="0,0,20,0" VerticalAlignment="Center"/>
                <TextBlock Text="Disk GBP/mo:" FontSize="11" Foreground="{DynamicResource Avd.Fg.Secondary}"
                           Margin="0,0,6,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="ISTotalDisk" FontSize="11" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" VerticalAlignment="Center"/>
                <TextBlock Text="Txn GBP/mo:" FontSize="11" Foreground="{DynamicResource Avd.Fg.Secondary}"
                           Margin="16,0,6,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="ISTotalTxn" FontSize="11" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" VerticalAlignment="Center"/>
            </StackPanel>
        </Border>

        <!-- ═══ Bottom action bar: result label + power action buttons ═══ -->
        <!-- Drain mode is not applicable to infrastructure VMs - no drain buttons here -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.CostBar.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,1,0,0"
                Height="38">
            <Grid Margin="12,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>      <!-- action result text -->
                    <ColumnDefinition Width="Auto"/>   <!-- button group -->
                </Grid.ColumnDefinitions>
                <!-- ISActionStatus: displays in-progress and result messages for power actions -->
                <TextBlock x:Name="ISActionStatus" Grid.Column="0"
                           Foreground="{DynamicResource Avd.Fg.Secondary}" FontSize="12"
                           VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal"
                            VerticalAlignment="Center">
                    <!-- Start: green - brings a deallocated VM back online -->
                    <Button x:Name="ISStartButton" Content="Start"
                            IsEnabled="False" Margin="0,4,6,4"
                            Background="#107C10" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Start the selected VM(s)">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdIS" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdIS" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdIS" Property="Background" Value="#0A5C0A"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <!-- Deallocate: amber - stops the VM AND releases the compute allocation -->
                    <Button x:Name="ISDeallocateButton" Content="Deallocate"
                            IsEnabled="False" Margin="0,4,6,4"
                            Background="#CA5010" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Stop and deallocate the selected VM(s) - releases compute billing">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdID" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdID" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdID" Property="Background" Value="#9A3C0A"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <!-- Restart: blue - reboots the OS while keeping the VM allocated -->
                    <Button x:Name="ISRestartButton" Content="Restart"
                            IsEnabled="False" Margin="0,4,4,4"
                            Background="{DynamicResource Avd.Btn.Accent.Bg}" Foreground="White"
                            BorderThickness="0" FontSize="12"
                            FontWeight="SemiBold" Cursor="Hand"
                            Padding="14,4"
                            ToolTip="Restart the selected VM(s)">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="BdIR2" Background="{TemplateBinding Background}"
                                        CornerRadius="4" Padding="{TemplateBinding Padding}">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter TargetName="BdIR2" Property="Background" Value="#888"/>
                                    </Trigger>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="BdIR2" Property="Background" Value="{DynamicResource Avd.Btn.Accent.Hover}"/>
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
        <DataGrid x:Name="ISGrid" Margin="0" ColumnWidth="Auto"
                  SelectionMode="Extended" SelectionUnit="FullRow"/>
    </DockPanel>
</TabItem>
'@

# =============================================================================
# 2. Background data-collection script
#
# Runs inside $script:infraRefreshRunspace - a dedicated single-thread MTA
# runspace that stays alive for the session.
#
# Variables injected via SessionStateProxy.SetVariable() before each BeginInvoke():
#   $ArmToken                - bearer token for Azure REST API calls
#   $SubId                   - current Azure subscription ID
#   $RestHelperDef           - compact Invoke-Arm function definition (string)
#   $InfraRGsCsv             - comma-separated list of resource groups to query
#   $InfraExcludePatternsCsv - comma-separated VM name exclusion substrings
#
# Optimisation over the old Az cmdlet approach: a single REST call with
# $expand=instanceView per RG returns both VM properties AND power state,
# eliminating the N+1 Get-AzVM -Status calls.
#
# All data is returned in a single [PSCustomObject] so EndInvoke() retrieves it cleanly.
# =============================================================================

$script:infraRefreshScript = {

    # Define Invoke-Arm in this runspace from the injected string definition
    . ([scriptblock]::Create($RestHelperDef))

    $infraRGs        = @($InfraRGsCsv           -split ',' | Where-Object { $_ })
    $excludePatterns = @($InfraExcludePatternsCsv -split ',' | Where-Object { $_ })

    # Expand any wildcard patterns (e.g. '*-INFRA-*') to real RG names.
    # Only calls the REST API when at least one pattern contains * or ?.
    if ($infraRGs.Count -gt 0 -and ($infraRGs | Where-Object { $_ -match '\*|\?' })) {
        $allSubRGs = @((Invoke-Arm -Path "/subscriptions/$SubId/resourcegroups" -Token $ArmToken -ApiVersion '2024-03-01') | ForEach-Object { $_.name })
        $infraRGs  = @($infraRGs | ForEach-Object {
            $p = $_
            if ($p -match '\*|\?') { $allSubRGs | Where-Object { $_ -like $p } } else { $p }
        } | Select-Object -Unique)
    }

    $vmRows = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($rg in $infraRGs) {
        # List VMs in RG (no $expand - instanceView expand only works for VMSS).
        $vms = @(Invoke-Arm -Path "/subscriptions/$SubId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines" -Token $ArmToken -ApiVersion '2024-07-01')
        if ($vms.Count -eq 0) { continue }

        foreach ($vm in $vms) {
            # Skip VMs that match any exclusion pattern (case-insensitive substring)
            $excluded = $false
            foreach ($pattern in $excludePatterns) {
                if ($vm.name -like "*$pattern*") { $excluded = $true; break }
            }
            if ($excluded) { continue }

            # Get power state via per-VM instanceView call (same as old Get-AzVM -Status pattern)
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

            $vmSku           = [string]$vm.properties.hardwareProfile.vmSize
            # Disk SKU is resolved in a batch after the VM loop (Resource Graph query)
            $osDiskName      = [string]$vm.properties.storageProfile.osDisk.name
            $osDiskResourceId = ([string]$vm.properties.storageProfile.osDisk.managedDisk.id).ToLower()
            $availZone = if ($vm.zones -and $vm.zones.Count -gt 0) { [string]$vm.zones[0] } else { 'N/A' }
            $osType    = [string]$vm.properties.storageProfile.osDisk.osType

            # Resolve private IP from the first NIC via REST
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
                'VM Name'          = $vm.name
                'Resource Group'   = $rg
                'Region'           = $vm.location
                'Power State'      = $powerState
                'OS Type'          = $osType
                'IP Address'       = $ip
                'Avail Zone'       = $availZone
                'VM SKU'           = $vmSku
                'Disk SKU'         = '-'
                'Compute GBP/mo'   = '-'
                'Disk GBP/mo'      = '-'
                'Txn GBP/10K'      = '-'
                '_DiskTier'        = ''        # hidden - disk tier e.g. "P10" for pricing API
                '_DiskSkuRaw'      = ''        # hidden - raw SKU e.g. "Premium_LRS" for pricing API
                '_ComputeCostSort' = [double]-1
                '_DiskCostSort'    = [double]-1
                '_TxnCostSort'     = [double]-1
                'Txn GBP/mo'          = '-'
                '_TxnMoCostSort'      = [double]-1
                '_OsDiskName'         = $osDiskName
                '_OsDiskResourceId'   = $osDiskResourceId
                '_RG'              = $rg       # hidden - used by power action buttons
            })
        }
    }

    # Batch-resolve OS disk SKUs via Resource Graph (avoids per-VM REST calls).
    # Also fetches disk size so we can derive the billing tier (P10, E10, S10 etc.)
    # for the cost lookup - same tier tables as the Session Hosts tab.
    $allDiskNames = @($vmRows | ForEach-Object { $_.'_OsDiskName' } | Where-Object { $_ })
    if ($allDiskNames.Count -gt 0) {
        # Tier lookup tables: [maxSizeGB, tierName, provisionedIOPS]
        # First entry where maxSizeGB >= diskSizeGB gives the billing tier.
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
                    $diskSkuMap[$dn] = @{
                        Display  = if ($tierName) { "$tierName ($size GB) $provIOPS IOPS" } elseif ($size) { "$sku ($size GB)" } else { $sku }
                        Tier     = $tierName
                        SkuRaw   = $sku
                    }
                }
            } catch { }
        }
        foreach ($row in $vmRows) {
            $dn = [string]$row.'_OsDiskName'
            if ($dn -and $diskSkuMap.ContainsKey($dn.ToLower())) {
                $d = $diskSkuMap[$dn.ToLower()]
                $row.'Disk SKU'    = $d.Display
                $row.'_DiskTier'   = $d.Tier
                $row.'_DiskSkuRaw' = $d.SkuRaw
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
#
# Creates the dedicated refresh runspace, binds all named controls, initialises
# state variables, and wires every UI event handler for this tab.
#
# Parameters (supplied by the main script after the window is shown):
#   $Window         - the loaded System.Windows.Window object
#   $ContextFile    - path to the saved Az context JSON file (for Az.Accounts)
#   $SubscriptionId - current Azure subscription ID for REST API calls
# =============================================================================

function Initialize-InfrastructureTab {
    param(
        [System.Windows.Window]$Window,
        [string]$ContextFile,
        [string]$SubscriptionId
    )

    # ── Create the dedicated infrastructure refresh runspace ──────────────────
    # No module imports needed - all Azure calls use direct REST API via bearer token.
    $script:infraRefreshRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:infraRefreshRunspace.ApartmentState = 'MTA'
    $script:infraRefreshRunspace.Open()

    # ── Bind named controls from the XAML ────────────────────────────────────
    $script:ISGrid              = $Window.FindName('ISGrid')
    $script:ISFilterBox         = $Window.FindName('ISFilterBox')
    $script:ISStatusText        = $Window.FindName('ISStatusText')
    $script:ISStartButton       = $Window.FindName('ISStartButton')
    $script:ISDeallocateButton  = $Window.FindName('ISDeallocateButton')
    $script:ISRestartButton     = $Window.FindName('ISRestartButton')
    $script:ISActionStatus      = $Window.FindName('ISActionStatus')
    $script:ISRefreshButton     = $Window.FindName('ISRefreshButton')
    $script:ISExportButton      = $Window.FindName('ISExportButton')
    $script:ISLoadCostsButton   = $Window.FindName('ISLoadCostsButton')
    $script:ISTotalsBar         = $Window.FindName('ISTotalsBar')
    $script:ISTotalCompute      = $Window.FindName('ISTotalCompute')
    $script:ISTotalDisk         = $Window.FindName('ISTotalDisk')
    $script:ISTotalTxn          = $Window.FindName('ISTotalTxn')

    # ── Initialise module-scope state variables ───────────────────────────────
    $script:infraContextFile         = $ContextFile
    $script:infraSubId               = $SubscriptionId
    $script:infraDataTable           = $null
    $script:isCostCache              = @{}
    $script:infraLastVmRows          = @()
    $script:infraActionHandle        = $null
    $script:infraActionPS            = $null
    $script:infraActionRS            = $null
    $script:infraHandle              = $null
    $script:infraPS                  = $null
    $script:infraNextRefresh         = [DateTime]::Now   # fire immediately on first tick
    $script:infraLastRefreshTime     = $null
    $script:infraCountText           = ''
    $script:infraFilteredCountText   = $null
    $script:infraActionLabel         = ''
    $script:infraSkippedNote         = ''
    $script:InfraRefreshIntervalSeconds = 60

    # ── Hide internal helper columns; fix '/' binding for cost columns ───────
    # WPF's PropertyPath parser treats '/' as a path separator, so column names
    # containing '/' must use the indexer form "[Column Name]" to bind correctly.
    $script:ISGrid.Add_AutoGeneratingColumn({
        param($grid, $e)
        $col = [string]$e.Column.Header
        if ($col -in @('_RG', '_OsDiskName', '_OsDiskResourceId', '_DiskTier', '_DiskSkuRaw', '_ComputeCostSort', '_DiskCostSort', '_TxnCostSort', '_TxnMoCostSort')) {
            $e.Cancel = $true; return
        }
        if ($col -in @('Compute GBP/mo', 'Disk GBP/mo', 'Txn GBP/10K')) {
            $e.Column.Binding = New-Object System.Windows.Data.Binding "[$col]"
        }
        if ($col -eq 'Txn GBP/mo') {
            $e.Column.Binding = New-Object System.Windows.Data.Binding "[Txn GBP/mo]"
            $hdrTb = New-Object System.Windows.Controls.TextBlock
            $hdrTb.Text = "Txn`nGBP/mo"; $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center
            $e.Column.Header = $hdrTb
            $e.Column.SortMemberPath = '_TxnMoCostSort'
        }
    })

    # ── Wire Load Costs button ────────────────────────────────────────────────
    $script:ISLoadCostsButton.Add_Click({ Invoke-InfrastructureCostFetch })

    # ── Filter box: debounced DataView filtering ──────────────────────────────
    $script:ISFilterDebounce = New-Object System.Windows.Threading.DispatcherTimer
    $script:ISFilterDebounce.Interval = [TimeSpan]::FromMilliseconds(300)
    $script:ISFilterDebounce.Add_Tick({
        $script:ISFilterDebounce.Stop()
        if (-not $script:infraDataTable) { return }
        $text = $script:ISFilterBox.Text.Trim()
        $script:infraDataTable.DefaultView.RowFilter = if ([string]::IsNullOrEmpty($text)) {
            ''
        } else {
            "([VM Name] LIKE '%$text%') OR ([Resource Group] LIKE '%$text%') OR ([Power State] LIKE '%$text%') OR ([OS Type] LIKE '%$text%')"
        }
        if ([string]::IsNullOrEmpty($text)) {
            $script:infraFilteredCountText = $null
        } else {
            $view   = $script:infraDataTable.DefaultView
            $fTotal = $view.Count
            $fRun   = @($view | Where-Object { $_['Power State'] -eq 'Running' }).Count
            $script:infraFilteredCountText = "$fTotal VM(s)   Running: $fRun   Other: $($fTotal - $fRun)"
        }
        _IS_UpdateTotals
    })
    $script:ISFilterBox.Add_TextChanged({
        $script:ISFilterDebounce.Stop()
        $script:ISFilterDebounce.Start()
    })

    # ── Grid selection: enable/disable power action buttons ──────────────────
    $script:ISGrid.Add_SelectionChanged({
        $has = $script:ISGrid.SelectedItems.Count -gt 0
        $script:ISStartButton.IsEnabled      = $has
        $script:ISDeallocateButton.IsEnabled = $has
        $script:ISRestartButton.IsEnabled    = $has
    })

    # ── Row hover / selected highlight style ─────────────────────────────────
    $isRowStyle = New-Object System.Windows.Style([System.Windows.Controls.DataGridRow])

    $isHoverTrigger = New-Object System.Windows.Trigger
    $isHoverTrigger.Property = [System.Windows.Controls.DataGridRow]::IsMouseOverProperty
    $isHoverTrigger.Value    = $true
    [void]$isHoverTrigger.Setters.Add(
        (New-Object System.Windows.Setter(
            [System.Windows.Controls.DataGridRow]::BackgroundProperty,
            [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xEE, 0xF4, 0xFC))
        ))
    )

    $isSelTrigger = New-Object System.Windows.Trigger
    $isSelTrigger.Property = [System.Windows.Controls.DataGridRow]::IsSelectedProperty
    $isSelTrigger.Value    = $true
    [void]$isSelTrigger.Setters.Add(
        (New-Object System.Windows.Setter(
            [System.Windows.Controls.DataGridRow]::BackgroundProperty,
            [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xD0, 0xE7, 0xFA))
        ))
    )
    [void]$isSelTrigger.Setters.Add(
        (New-Object System.Windows.Setter(
            [System.Windows.Controls.DataGridRow]::ForegroundProperty,
            [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x1F, 0x29, 0x37))
        ))
    )

    [void]$isRowStyle.Triggers.Add($isHoverTrigger)
    [void]$isRowStyle.Triggers.Add($isSelTrigger)
    $script:ISGrid.RowStyle = $isRowStyle

    # ── Button click handlers ─────────────────────────────────────────────────
    $script:ISStartButton.Add_Click(      { Invoke-InfrastructurePowerAction -Action 'Start'      })
    $script:ISDeallocateButton.Add_Click( { Invoke-InfrastructurePowerAction -Action 'Deallocate' })
    $script:ISRestartButton.Add_Click(    { Invoke-InfrastructurePowerAction -Action 'Restart'    })
    $script:ISRefreshButton.Add_Click(    { Invoke-InfrastructureTabRefresh })
    $script:ISExportButton.Add_Click(     { Invoke-InfrastructureExport })

    # ── Right-click context menu: RDP to VM ───────────────────────────────────
    # Uses the shared Invoke-RDPToSessionHost from session-detail.ps1.
    # Passes the IP Address column (already populated on every refresh) so no
    # additional API call is required.
    $isCtxMenu        = New-Object System.Windows.Controls.ContextMenu
    $menuISRDP        = New-Object System.Windows.Controls.MenuItem
    $menuISRDP.Header = "RDP to Server"
    [void]$isCtxMenu.Items.Add($menuISRDP)
    [void]$isCtxMenu.Items.Add((New-Object System.Windows.Controls.Separator))
    $menuISOpenPortal        = New-Object System.Windows.Controls.MenuItem
    $menuISOpenPortal.Header = "Open Resource Group in Portal"
    [void]$isCtxMenu.Items.Add($menuISOpenPortal)

    $isGrid = $script:ISGrid

    $isGrid.Add_PreviewMouseRightButtonDown({
        $node = $_.OriginalSource
        while ($null -ne $node -and $node -isnot [System.Windows.Controls.DataGridRow]) {
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        }
        if ($null -ne $node) { $node.IsSelected = $true }
    }.GetNewClosure())

    $isGrid.Add_ContextMenuOpening({
        $sel = @($isGrid.SelectedItems)
        $hasOne = $sel.Count -gt 0 -and $null -ne $sel[0]
        $isCtxMenu.Items[0].IsEnabled = $hasOne   # RDP to Server
        $isCtxMenu.Items[2].IsEnabled = $hasOne   # Open Resource Group in Portal
    }.GetNewClosure())

    $menuISRDP.Add_Click({
        try {
            $sel = @($isGrid.SelectedItems)
            if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
            $row    = $sel[0]
            $vmName = [string]$row['VM Name']
            $ip     = [string]$row['IP Address']
            if ($ip -eq '-' -or [string]::IsNullOrWhiteSpace($ip)) { $ip = '' }
            Invoke-RDPToSessionHost -SessionHost $vmName -IPAddress $ip
        }
        catch {
            [System.Windows.MessageBox]::Show("Failed to launch RDP: $_", "RDP Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    $isPortalSubId    = $SubscriptionId
    $isPortalTenantId = $DefaultTenantId
    $menuISOpenPortal.Add_Click({
        $sel = @($isGrid.SelectedItems)
        if ($sel.Count -eq 0 -or $null -eq $sel[0]) { return }
        $rg  = [string]$sel[0]['_RG']
        $url = "https://portal.azure.com/#@$isPortalTenantId/resource/subscriptions/$isPortalSubId/resourceGroups/$rg/overview"
        Start-Process $url
    }.GetNewClosure())

    $isGrid.ContextMenu = $isCtxMenu
}

# =============================================================================
# 4. Trigger a background infrastructure data refresh
#
# Called by Invoke-InfrastructureTabTimer (scheduled) and ISRefreshButton (manual).
# Guards against double-fire: returns immediately if a job is already running.
# =============================================================================

function Invoke-InfrastructureTabRefresh {
    if ($script:infraHandle -and -not $script:infraHandle.IsCompleted) { return }

    # Guard: no point querying Azure if no resource groups are configured
    if ($script:InfraRGs.Count -eq 0) {
        $script:ISStatusText.Text = 'No resource groups configured - open Settings and add resource groups under Infrastructure Resource Groups'
        $script:infraNextRefresh  = [DateTime]::Now.AddSeconds($script:InfraRefreshIntervalSeconds)
        return
    }

    $script:ISStatusText.Text = 'Refreshing...'
    $script:infraNextRefresh  = [DateTime]::Now.AddSeconds($script:InfraRefreshIntervalSeconds + 9999)

    $script:infraRefreshRunspace.SessionStateProxy.SetVariable('ArmToken',                (Get-ArmToken))
    $script:infraRefreshRunspace.SessionStateProxy.SetVariable('SubId',                  $script:infraSubId)
    $script:infraRefreshRunspace.SessionStateProxy.SetVariable('RestHelperDef',          $script:restHelperDef)
    $script:infraRefreshRunspace.SessionStateProxy.SetVariable('LogFile',                 $script:LogFile)
    $script:infraRefreshRunspace.SessionStateProxy.SetVariable('InfraRGsCsv',             ($script:InfraRGs -join ','))
    $script:infraRefreshRunspace.SessionStateProxy.SetVariable('InfraExcludePatternsCsv', ($script:InfraExcludePatterns -join ','))

    $script:infraPS          = [System.Management.Automation.PowerShell]::Create()
    $script:infraPS.Runspace = $script:infraRefreshRunspace
    [void]$script:infraPS.AddScript($script:infraRefreshScript)
    $script:infraHandle      = $script:infraPS.BeginInvoke()
}

# =============================================================================
# 5. VM power actions (Start / Deallocate / Restart)
#
# Identical pattern to tab-sessionhosts.ps1: fresh throw-away runspace per action,
# REST POST is inherently async (returns 202 Accepted), polled by Invoke-InfrastructureTabTimer.
# Deallocate and Restart require confirmation; Start does not.
# =============================================================================

function Invoke-InfrastructurePowerAction {
    param([string]$Action)

    if ($script:infraActionHandle -and -not $script:infraActionHandle.IsCompleted) {
        [System.Windows.MessageBox]::Show(
            'A power action is already in progress. Please wait for it to complete.',
            'Action In Progress',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }

    $targets = @(foreach ($item in $script:ISGrid.SelectedItems) {
        [PSCustomObject]@{ Name = [string]$item['VM Name']; RG = [string]$item['_RG']; PowerState = [string]$item['Power State'] }
    })
    if ($targets.Count -eq 0) { return }

    # Skip VMs already in the target state (same pattern as tab-sessionhosts.ps1).
    # Power State values from Resource Graph: 'Running', 'Deallocated', 'Stopped', etc.
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
        $script:ISActionStatus.Text = "All $($original.Count) selected VM(s) are already $stateWord - nothing to do."
        return
    }
    $script:infraSkippedNote = ''
    if ($skipped.Count -gt 0) {
        $skippedNames = ($skipped | ForEach-Object { $_.Name }) -join ', '
        $script:infraSkippedNote = " | Skipped (already $( if ($Action -eq 'Start') { 'running' } else { 'deallocated' } )): $skippedNames"
    }

    $vmList = ($targets | ForEach-Object { $_.Name }) -join ', '

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
    foreach ($t in $targets) {
        Write-AuditLog -Action "VM$Action" -Target $t.Name
    }

    $script:ISActionStatus.Text          = "$Action in progress: $vmList..."
    $script:ISStartButton.IsEnabled      = $false
    $script:ISDeallocateButton.IsEnabled = $false
    $script:ISRestartButton.IsEnabled    = $false

    # REST API power action - POST to start/deallocate/restart endpoint.
    # No Az modules needed - uses Invoke-Arm helper injected via $restHelperDef.
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
    $_subId = if ($script:infraSubId) { $script:infraSubId } else { $subscriptionId }

    $script:infraActionRS          = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:infraActionRS.Open()
    $script:infraActionPS          = [System.Management.Automation.PowerShell]::Create()
    $script:infraActionPS.Runspace = $script:infraActionRS
    [void]$script:infraActionPS.AddScript($actionScript).AddArgument((Get-ArmToken)).AddArgument($_subId).AddArgument($targetsJson).AddArgument($restAction)
    $script:infraActionHandle      = $script:infraActionPS.BeginInvoke()
    $script:infraActionLabel       = $Action
}

# =============================================================================
# 6. Per-second tick  -  called by the main DispatcherTimer every second
#
# Handles three concerns:
#   a) Scheduling / triggering the 60-second refresh
#   b) Collecting results from a completed refresh and updating the grid
#   c) Collecting results from a completed power action and re-enabling buttons
#   d) Updating the live countdown / summary text in the status bar
# =============================================================================

function Invoke-InfrastructureTabTimer {

    if (-not $script:ISGrid.IsVisible) { return }

    # ── (a) Trigger the 60-second refresh when due ───────────────────────────
    if ($script:infraNextRefresh -and [DateTime]::Now -ge $script:infraNextRefresh -and
        (-not $script:infraHandle -or $script:infraHandle.IsCompleted)) {
        Invoke-InfrastructureTabRefresh
    }

    # ── (b) Collect completed refresh results ────────────────────────────────
    if ($script:infraHandle -and $script:infraHandle.IsCompleted) {
        try {
            $infraData = $script:infraPS.EndInvoke($script:infraHandle)
            # EndInvoke returns a PSDataCollection - use [0] to get the actual result object.
            # Always call _IS_UpdateGrid even with 0 VMs so the status text and timestamp update.
            if ($null -ne $infraData -and $null -ne $infraData[0]) {
                _IS_UpdateGrid -VmRows @($infraData[0].VmRows) -Timestamp $infraData[0].Timestamp
            }
            $script:infraNextRefresh = [DateTime]::Now.AddSeconds($script:InfraRefreshIntervalSeconds)
        } catch {
            $script:ISStatusText.Text = "Infrastructure refresh error: $_"
            Write-Log "ERROR [Infrastructure] $_"
            $script:infraNextRefresh  = [DateTime]::Now.AddSeconds($script:InfraRefreshIntervalSeconds)
        } finally {
            try { $script:infraPS.Dispose() } catch {}
            $script:infraHandle = $null
            $script:infraPS     = $null
        }
    }

    # ── (c) Collect completed power action results ───────────────────────────
    if ($script:infraActionHandle -and $script:infraActionHandle.IsCompleted) {
        try {
            $rawResult = @($script:infraActionPS.EndInvoke($script:infraActionHandle))
            $result    = $rawResult -join ' | '
            $script:ISActionStatus.Text = "$($script:infraActionLabel) initiated: $result$($script:infraSkippedNote)"
        } catch {
            $script:ISActionStatus.Text = "$($script:infraActionLabel) error: $_"
        } finally {
            try { $script:infraActionPS.Dispose() } catch {}
            try { $script:infraActionRS.Dispose() } catch {}
            $script:infraActionHandle = $null
            $script:infraActionPS     = $null
            $script:infraActionRS     = $null
            $has = $script:ISGrid.SelectedItems.Count -gt 0
            $script:ISStartButton.IsEnabled      = $has
            $script:ISDeallocateButton.IsEnabled = $has
            $script:ISRestartButton.IsEnabled    = $has
        }
    }

    # ── (d) Update live countdown / summary in the status bar ────────────────
    if ($script:infraLastRefreshTime) {
        $remaining   = [Math]::Ceiling(($script:infraNextRefresh - [DateTime]::Now).TotalSeconds)
        $lastTs      = $script:infraLastRefreshTime.ToString('HH:mm:ss')
        $activeCount = if ($script:infraFilteredCountText) { $script:infraFilteredCountText } else { $script:infraCountText }
        $countStr    = if ($activeCount) { "$activeCount   |   " } else { '' }
        $script:ISStatusText.Text = if ($script:infraHandle -and -not $script:infraHandle.IsCompleted) {
            "${countStr}Refreshing..."
        } else {
            "${countStr}Updated: $lastTs   Next in ${remaining}s"
        }
    }
}

# =============================================================================
# 7. Reset on subscription switch  -  called from the subscription picker
# =============================================================================

function Reset-InfrastructureTab {
    $script:infraNextRefresh = [DateTime]::Now
}

# =============================================================================
# 8. Export grid to CSV  -  called by ISExportButton click
# =============================================================================

function Invoke-InfrastructureExport {
    if (-not $script:infraDataTable) { return }

    $dlg          = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter   = 'CSV files (*.csv)|*.csv'
    $dlg.FileName = "Infrastructure_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"

    if ($dlg.ShowDialog() -eq $true) {
        try {
            $script:infraDataTable.Rows |
                ForEach-Object {
                    $row = $_
                    $obj = [ordered]@{}
                    foreach ($col in $script:infraDataTable.Columns) {
                        if ($col.ColumnName -notin @('_RG', '_OsDiskName', '_OsDiskResourceId', '_DiskTier', '_DiskSkuRaw', '_ComputeCostSort', '_DiskCostSort', '_TxnCostSort', '_TxnMoCostSort')) {
                            $obj[$col.ColumnName] = $row[$col.ColumnName]
                        }
                    }
                    [PSCustomObject]$obj
                } |
                Export-Csv -Path $dlg.FileName -NoTypeInformation -Force
            $script:ISStatusText.Text = "Exported $($script:infraDataTable.Rows.Count) row(s) to $($dlg.FileName)"
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

# _IS_UpdateGrid
# Converts the $VmRows array to a DataTable, applies any active filter, binds
# the DataView to the grid, and updates the summary count text.
function _IS_UpdateGrid {
    param($VmRows, $Timestamp)

    $script:infraLastVmRows = @($VmRows)
    Write-Log "DEBUG [Infra] _IS_UpdateGrid - VmRows.Count=$(@($VmRows).Count)"
    $script:infraDataTable  = ConvertTo-DataTable -Objects @($VmRows)
    Write-Log "DEBUG [Infra] DataTable rows=$($script:infraDataTable.Rows.Count)  cols=$($script:infraDataTable.Columns.Count)"

    # Reapply any cached costs so they survive the auto-refresh cycle
    if ($script:isCostCache -and $script:isCostCache.Count -gt 0) {
        foreach ($row in $script:infraDataTable.Rows) {
            $key = [string]$row['VM Name']
            if ($script:isCostCache.ContainsKey($key)) {
                $c     = $script:isCostCache[$key]
                $state = [string]$row['Power State']
                $row['Compute GBP/mo']   = if ($c.Compute -gt 0)  { '{0:F2}' -f $c.Compute } elseif ($state -ne 'Running') { '0.00' } else { '-' }
                $row['Disk GBP/mo']      = if ($c.Disk -gt 0)     { '{0:F2}' -f $c.Disk    } else { '-' }
                # Txn -lt 0 means Premium SSD - no per-I/O billing, show N/A for both txn columns.
                $row['Txn GBP/10K']      = if ($c.Txn -ge 0) { '{0:F4}' -f $c.Txn } else { 'N/A' }
                $row['_ComputeCostSort'] = $c.Compute
                $row['_DiskCostSort']    = $c.Disk
                $row['_TxnCostSort']     = $c.Txn
                if ($c.Txn -lt 0) { $row['Txn GBP/mo'] = 'N/A' }
                # Reapply Cost Management transaction cost from cache (persists across auto-refresh)
                if ($c.Txn -ge 0 -and $script:isTxnMoCache -and $script:isTxnMoCache.ContainsKey($key)) {
                    $mo = $script:isTxnMoCache[$key]
                    $row['Txn GBP/mo']     = if ($mo -ge 0) { '{0:F2}' -f $mo } else { '-' }
                    $row['_TxnMoCostSort'] = $mo
                }
            }
        }
    }

    if ($script:ISLoadCostsButton) { $script:ISLoadCostsButton.IsEnabled = $true }

    $filter = $script:ISFilterBox.Text.Trim()
    if (-not [string]::IsNullOrEmpty($filter)) {
        $script:infraDataTable.DefaultView.RowFilter = "([VM Name] LIKE '%$filter%') OR ([Resource Group] LIKE '%$filter%') OR ([Power State] LIKE '%$filter%') OR ([OS Type] LIKE '%$filter%')"
        $view   = $script:infraDataTable.DefaultView
        $fTotal = $view.Count
        $fRun   = @($view | Where-Object { $_['Power State'] -eq 'Running' }).Count
        $script:infraFilteredCountText = "$fTotal VM(s)   Running: $fRun   Other: $($fTotal - $fRun)"
    } else {
        $script:infraFilteredCountText = $null
    }

    $script:ISGrid.ItemsSource       = $script:infraDataTable.DefaultView
    $script:ISExportButton.IsEnabled = $true

    $runCount               = @($VmRows | Where-Object { $_.'Power State' -eq 'Running' }).Count
    $script:infraCountText  = "$($VmRows.Count) VM(s)   Running: $runCount   Other: $($VmRows.Count - $runCount)"
    $script:infraLastRefreshTime = $Timestamp

    _IS_UpdateTotals
}

# Recalculates and displays the cost totals bar from the current DefaultView.
# Called after grid bind and after filter changes so totals always reflect visible rows.
function _IS_UpdateTotals {
    if (-not $script:infraDataTable -or -not $script:ISTotalsBar) { return }
    $totalCompute = 0.0; $totalDisk = 0.0; $totalTxn = 0.0
    $hasCosts = $false
    foreach ($row in $script:infraDataTable.DefaultView) {
        $c = $row['_ComputeCostSort']; if ($c -gt 0) { $totalCompute += $c; $hasCosts = $true }
        $d = $row['_DiskCostSort'];    if ($d -gt 0) { $totalDisk    += $d; $hasCosts = $true }
        $t = $row['_TxnMoCostSort'];   if ($t -gt 0) { $totalTxn     += $t }
    }
    if ($hasCosts) {
        $script:ISTotalCompute.Text    = '{0:F2}' -f $totalCompute
        $script:ISTotalDisk.Text       = '{0:F2}' -f $totalDisk
        if ($script:ISTotalTxn) { $script:ISTotalTxn.Text = '{0:F2}' -f $totalTxn }
        $script:ISTotalsBar.Visibility = 'Visible'
    }
}
