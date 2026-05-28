# =============================================================================
# tab-azurefiles.ps1  -  Azure Files tab module
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Encapsulates everything needed for the Azure Files tab in one file so the
# main dashboard script stays clean. Dot-source this file BEFORE the XAML
# string is built; the main script then injects $AzureFilesTab_Xaml into its
# XAML via a placeholder comment and calls the public lifecycle functions:
#
#   Initialize-AzureFilesTab  - once, after $window is loaded
#   Invoke-AzureFilesTabTimer - every second from the master DispatcherTimer
#   Reset-AzureFilesTab       - on subscription switch (triggers immediate refresh)
#
# DATA FLOW
# ---------
# The tab runs a background refresh on its own interval (default 15 minutes),
# independent of the main 30-second AVD data refresh. Each cycle:
#   1. Queries all FileStorage and/or StorageV2 accounts in the target RGs
#   2. For each account, fetches per-share quota and FileCapacity metric from
#      Azure Monitor in parallel via a persistent RunspacePool ($script:saPool)
#   3. Returns a sorted list of share usage rows to the UI thread
#
# The dedicated single runspace ($script:filesRunspace) is created in the main
# script and kept alive for the dashboard lifetime. All Azure calls use direct
# REST API via bearer token - no Az modules are imported into runspaces.
# =============================================================================

# PSScriptAnalyzer flags $AzureFilesTab_Xaml as "assigned but never used"
# because it cannot see across the dot-source boundary into the calling script.
# This suppression attribute silences that false positive.
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'AzureFilesTab_Xaml',
    Justification = 'Exported to the calling script via dot-source')]
param()

# =============================================================================
# 1. XAML fragment
#
# The main script contains the placeholder comment <!-- TAB:AZURE_FILES -->
# inside its TabControl. Before parsing the XAML it does a string replace:
#   [xml]$xaml = $rawXaml -replace '<!-- TAB:AZURE_FILES -->', $AzureFilesTab_Xaml
#
# Layout (DockPanel):
#   Bottom bar - FilesStatus label (left) + Refresh + Profile Tools buttons (right)
#   Centre fill - FilesGrid (DataGrid, auto-column)
# =============================================================================

$AzureFilesTab_Xaml = @'
<TabItem x:Name="AzureFilesTab" Header="Azure Files"
         xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <DockPanel>
        <!-- ═══ Cost totals bar - shown after Load Costs is clicked ═══ -->
        <Border x:Name="AFTotalsBar" DockPanel.Dock="Bottom" Background="{DynamicResource Avd.CostBar.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,1,0,0"
                Height="28" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Left"
                        VerticalAlignment="Center" Margin="12,0">
                <TextBlock Text="Total Storage GBP/mo:" FontSize="11" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,8,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="AFTotalStorage" FontSize="11" FontWeight="SemiBold"
                           Foreground="{DynamicResource Avd.Fg.Accent}" VerticalAlignment="Center"/>
            </StackPanel>
        </Border>
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.CostBar.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,1,0,0"
                Height="34">
            <Grid Margin="12,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="FilesStatus" Grid.Column="0"
                           Foreground="{DynamicResource Avd.Fg.Secondary}" FontSize="12"
                           VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                <Button x:Name="FilesRefreshButton"
                        Content="Refresh" Margin="0,4,6,4"
                        Background="{DynamicResource Avd.Btn.Accent.Bg}" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,4">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="{DynamicResource Avd.Btn.Accent.Hover}"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="#003D6B"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="AFLoadCostsButton"
                        Content="Load Costs" Margin="0,4,4,4"
                        Background="#0E7A0D" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,4" IsEnabled="False"
                        ToolTip="Fetch estimated monthly storage costs from the Azure Retail Prices API (public, no auth required)">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="#0B5E0A"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="#084507"/>
                                </Trigger>
                                <Trigger Property="IsEnabled" Value="False">
                                    <Setter TargetName="Bd" Property="Background" Value="#A0A0A0"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="ToolsLaunchButton"
                        Content="Profile Tools" Margin="0,4,4,4"
                        Background="#5C2D91" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,4"
                        ToolTip="Open Profile Tools (FSLogix profile management)">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="#3E1A6E"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="#2B0F52"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="LogViewerLaunchButton"
                        Content="Log Viewer" Margin="0,4,4,4"
                        Background="#0E7A0D" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,4"
                        ToolTip="Open Log Viewer (browse and view log files)">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="#0B5E0A"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="Bd" Property="Background" Value="#084507"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                </StackPanel>
            </Grid>
        </Border>
        <DataGrid x:Name="FilesGrid" Margin="0"/>
    </DockPanel>
</TabItem>
'@

# =============================================================================
# 2. Background fetch script
#
# Runs inside $script:filesRunspace (single, persistent runspace).
# Variables are injected via SessionStateProxy.SetVariable() before each
# BeginInvoke() call:
#   $ArmToken        - bearer token for Azure REST API calls
#   $SubId           - current Azure subscription ID
#   $RestHelperDef   - compact Invoke-Arm function definition (string)
#   $FilesRGsCsv     - comma-separated resource group whitelist (empty = all)
#   $StorageKindsCsv - comma-separated storage account kinds to query
#   $SaPool          - persistent RunspacePool for parallel per-account queries
# =============================================================================

$script:filesScript = {
    # Variables injected via SessionStateProxy:
    # $ArmToken, $SubId, $RestHelperDef, $FilesRGsCsv, $StorageKindsCsv, $SaPool

    # Define Invoke-Arm in this runspace from the injected string definition
    . ([scriptblock]::Create($RestHelperDef))

    $FilesRGs     = @($FilesRGsCsv     -split ',' | Where-Object { $_ })
    $StorageKinds = @($StorageKindsCsv -split ',' | Where-Object { $_ })
    if ($StorageKinds.Count -eq 0) { $StorageKinds = @('FileStorage', 'StorageV2') }

    # Expand any wildcard patterns (e.g. 'AVDCORE-*') to real RG names.
    # Only calls the REST API when at least one pattern contains * or ?.
    if ($FilesRGs.Count -gt 0 -and ($FilesRGs | Where-Object { $_ -match '\*|\?' })) {
        $allSubRGs = @((Invoke-Arm -Path "/subscriptions/$SubId/resourcegroups" -Token $ArmToken -ApiVersion '2024-03-01') | ForEach-Object { $_.name })
        $FilesRGs  = @($FilesRGs | ForEach-Object {
            $p = $_
            if ($p -match '\*|\?') { $allSubRGs | Where-Object { $_ -like $p } } else { $p }
        } | Select-Object -Unique)
    }

    # Get storage accounts via REST API
    if ($FilesRGs.Count -gt 0) {
        $storageAccounts = @(foreach ($rg in $FilesRGs) {
            @(Invoke-Arm -Path "/subscriptions/$SubId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts" -Token $ArmToken -ApiVersion '2023-05-01') |
                Where-Object { $StorageKinds -contains $_.kind }
        })
    } else {
        $storageAccounts = @(
            @(Invoke-Arm -Path "/subscriptions/$SubId/providers/Microsoft.Storage/storageAccounts" -Token $ArmToken -ApiVersion '2023-05-01') |
                Where-Object { $StorageKinds -contains $_.kind }
        )
    }
    if (-not $storageAccounts -or $storageAccounts.Count -eq 0) { return @() }

    $now = [DateTime]::UtcNow
    $ago = $now.AddHours(-4)
    $nowStr = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $agoStr = $ago.ToString('yyyy-MM-ddTHH:mm:ssZ')

    # Per-account scriptblock - runs in parallel via RunspacePool.
    # Uses REST API via Invoke-Arm injected from $RestHelperDef.
    # ARM share endpoint does not return snapshots, so no IsSnapshot filter needed.
    # FileCapacity metric is queried once per storage account (not per share).
    $saScript = [scriptblock]::Create($RestHelperDef + @'
        $tok = $args[0]; $saName = $args[1]; $saRG = $args[2]; $saLocation = $args[3]; $saId = $args[4]; $agoStr = $args[5]; $nowStr = $args[6]; $LogFile = $args[7]; $saSkuName = $args[8]; $saKind = $args[9]; $saPublicAccessRaw = $args[10]
        $saPublicAccess = if ($saPublicAccessRaw -eq 'False') { 'Denied' } else { 'Allowed' }

        # Derive human-readable Performance, Replication and Account Kind from sku.name and kind
        $skuParts    = $saSkuName -split '_'
        $performance = $skuParts[0]   # "Standard" or "Premium"
        $replication = if ($skuParts.Count -gt 1) { $skuParts[1] } else { '' }  # "LRS", "ZRS", "GRS" etc.
        $accountKind = switch ($saKind) {
            'FileStorage' { 'FileStorage (premium)' }
            'StorageV2'   { 'StorageV2 (general purpose v2)' }
            'Storage'     { 'Storage (general purpose v1)' }
            default       { $saKind }
        }

        # Get file shares via ARM management plane (no storage key required)
        $shares = @(Invoke-Arm -Path "$saId/fileServices/default/shares" -Token $tok -ApiVersion '2023-05-01')
        if ($shares.Count -eq 0) { return }

        # Get FileCapacity metric once for the whole file service
        $usedBytes = 0
        try {
            $qs = "metricnames=FileCapacity&timespan=$agoStr/$nowStr&interval=PT1H&aggregation=Average"
            $metricResp = Invoke-Arm -Path "$saId/fileServices/default/providers/microsoft.insights/metrics?$qs" -Token $tok -ApiVersion '2024-02-01' -FullResponse
            if ($metricResp -and $metricResp.value -and $metricResp.value[0].timeseries) {
                $tsData = @($metricResp.value[0].timeseries[0].data | Where-Object { $null -ne $_.average })
                if ($tsData.Count -gt 0) { $usedBytes = $tsData[-1].average }
            }
        } catch { $usedBytes = 0 }

        foreach ($share in $shares) {
            $quotaGiB = if ($share.properties.shareQuota) { $share.properties.shareQuota } else { 0 }

            $usedGiB = [Math]::Round($usedBytes / 1GB, 2)
            $freeGiB = [Math]::Round($quotaGiB - $usedGiB, 2)
            $usedPct = if ($quotaGiB -gt 0) { [Math]::Round(($usedGiB / $quotaGiB) * 100, 1) } else { 0 }

            [PSCustomObject]@{
                "Storage Account"  = $saName
                "Resource Group"   = $saRG
                "Location"         = $saLocation
                "Share"            = $share.name
                "Quota (GiB)"      = $quotaGiB
                "Performance"      = $performance
                "Replication"      = $replication
                "Account Kind"     = $accountKind
                "Used (GiB)"       = $usedGiB
                "Free (GiB)"       = $freeGiB
                "Used %"           = $usedPct
                "Public Access"    = $saPublicAccess
                "Storage GBP/mo"   = '-'
                "_StorageCostSort" = [double]-1
                "_SkuName"         = [string]$saSkuName
                "_AccessTier"      = [string]$share.properties.accessTier
            }
        }
'@)

    # Use the persistent pool injected at startup - no module loading overhead.
    $saPool = $SaPool

    $handles = @(foreach ($sa in $storageAccounts) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $saPool
        [void]$ps.AddScript($saScript).AddArgument($ArmToken).AddArgument($sa.name).AddArgument($sa.id.Split('/')[4]).AddArgument($sa.location).AddArgument($sa.id).AddArgument($agoStr).AddArgument($nowStr).AddArgument($LogFile).AddArgument([string]$sa.sku.name).AddArgument([string]$sa.kind).AddArgument([string]$sa.properties.allowBlobPublicAccess)
        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    })

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($h in $handles) {
        try {
            $out = $h.PS.EndInvoke($h.Handle)
            if ($out) { foreach ($r in $out) { $rows.Add($r) } }
        } catch { <# individual SA query failed - skip it #> }
        finally { $h.PS.Dispose() }
    }
    # Note: $saPool is persistent - do NOT close or dispose it here

    return @($rows | Sort-Object "Storage Account", "Share")
}

# =============================================================================
# 3. Invoke-FilesRefresh  (internal)
#
# Kicks off the Azure Files background job in $script:filesRunspace.
# No-ops if a job is already running. Called by:
#   - Invoke-AzureFilesTabTimer  (auto-refresh when interval elapses)
#   - FilesRefreshButton click handler
# =============================================================================

function Invoke-FilesRefresh {
    if ($script:filesHandle -and -not $script:filesHandle.IsCompleted) { return }  # already running
    $script:FilesStatus.Text = "Loading Azure Files data..."
    $script:filesNextRefresh = [DateTime]::Now.AddSeconds($script:FilesRefreshIntervalSeconds + 9999)
    $script:filesRunspace.SessionStateProxy.SetVariable("ArmToken",        (Get-ArmToken))
    $script:filesRunspace.SessionStateProxy.SetVariable("SubId",           $script:filesSubId)
    $script:filesRunspace.SessionStateProxy.SetVariable("RestHelperDef",   $script:restHelperDef)
    $script:filesRunspace.SessionStateProxy.SetVariable("FilesRGsCsv",     ($script:FilesRGs -join ','))
    $script:filesRunspace.SessionStateProxy.SetVariable("StorageKindsCsv", ($script:StorageAccountKinds -join ','))
    $script:filesRunspace.SessionStateProxy.SetVariable("LogFile",         $script:LogFile)
    $script:filesRunspace.SessionStateProxy.SetVariable("SaPool",          $script:saPool)
    $script:filesPS          = [System.Management.Automation.PowerShell]::Create()
    $script:filesPS.Runspace = $script:filesRunspace
    [void]$script:filesPS.AddScript($script:filesScript)
    $script:filesHandle      = $script:filesPS.BeginInvoke()
}

# =============================================================================
# 4. Initialize-AzureFilesTab
#
# Call once after $window has been loaded from XAML.
# Finds named controls, stores the context file path, and wires event handlers.
#
# Parameters:
#   $Window         - the loaded System.Windows.Window object
#   $ContextFile    - path to the saved Az context JSON file (for Az.Accounts)
#   $SubscriptionId - current Azure subscription ID for REST API calls
# =============================================================================

function Initialize-AzureFilesTab {
    param(
        [Parameter(Mandatory)][System.Windows.Window]$Window,
        [Parameter(Mandatory)][string]$ContextFile,
        [string]$SubscriptionId
    )

    # Store parameters so Invoke-FilesRefresh can access them from its function scope.
    $script:filesContextFile = $ContextFile
    $script:filesSubId       = $SubscriptionId

    # Resolve control references
    $script:FilesGrid          = $Window.FindName('FilesGrid')
    $script:FilesStatus        = $Window.FindName('FilesStatus')
    $script:FilesRefreshButton = $Window.FindName('FilesRefreshButton')
    $script:AFLoadCostsButton  = $Window.FindName('AFLoadCostsButton')
    $script:AFTotalsBar        = $Window.FindName('AFTotalsBar')
    $script:AFTotalStorage     = $Window.FindName('AFTotalStorage')
    $script:ToolsLaunchButton  = $Window.FindName('ToolsLaunchButton')
    $script:AzureFilesTab      = $Window.FindName('AzureFilesTab')

    # Initialise background job state; trigger an immediate refresh on first load
    $script:filesHandle      = $null
    $script:filesPS          = $null
    $script:filesNextRefresh = [DateTime]::Now
    $script:afCostCache      = @{}
    $script:afDataTable      = $null

    # Wire up the manual Refresh button
    $script:FilesRefreshButton.Add_Click({ Invoke-FilesRefresh })

    # Wire up the Load Costs button
    $script:AFLoadCostsButton.Add_Click({ Invoke-AzureFilesCostFetch })

    # AutoGeneratingColumn: hide internal _ columns and fix the Storage GBP/mo binding.
    # WPF's PropertyPath parser treats '/' as a path separator, so "Storage GBP/mo"
    # must use indexer form "[Storage GBP/mo]" to bind correctly - same fix as the
    # Session Hosts cost columns.
    $script:FilesGrid.Add_AutoGeneratingColumn({
        param($grid, $e)
        $colName = [string]$e.Column.Header
        if ($colName -in @('_SkuName', '_AccessTier', '_StorageCostSort')) { $e.Cancel = $true; return }
        if ($colName -eq 'Storage GBP/mo') {
            $e.Column.Binding = New-Object System.Windows.Data.Binding "[Storage GBP/mo]"
            $hdrTb = New-Object System.Windows.Controls.TextBlock
            $hdrTb.Text = "Storage`nGBP/mo"
            $hdrTb.TextAlignment = [System.Windows.TextAlignment]::Center
            $e.Column.Header = $hdrTb
        }
    })

    # Wire up the Log Viewer launch button
    $script:LogViewerLaunchButton = $Window.FindName('LogViewerLaunchButton')
    $script:LogViewerLaunchButton.Add_Click({
        $lvBtn    = $script:LogViewerLaunchButton
        $lvScript = Join-Path $script:dashboardDir 'tools\log-viewer.ps1'
        if (-not (Test-Path $lvScript)) {
            [System.Windows.MessageBox]::Show(
                "log-viewer.ps1 was not found.`n`nExpected location:`n$lvScript",
                "Script Not Found", "OK", "Warning") | Out-Null
            return
        }
        $lvBtn.IsEnabled = $false
        $lvBtn.Content   = "Log Viewer (Running)"
        $script:lvProc   = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -File `"$lvScript`"" -PassThru
        $localLvProc     = $script:lvProc

        $lvTimer          = New-Object System.Windows.Threading.DispatcherTimer
        $lvTimer.Interval = [TimeSpan]::FromSeconds(2)
        $lvTimer.Add_Tick({
            if ($localLvProc -and $localLvProc.HasExited) {
                $lvTimer.Stop()
                $script:lvProc   = $null
                $lvBtn.IsEnabled = $true
                $lvBtn.Content   = "Log Viewer"
            }
        }.GetNewClosure())
        $lvTimer.Start()
    })

    # Wire up the Profile Tools launch button
    $script:ToolsLaunchButton.Add_Click({
        $toolsBtn    = $script:ToolsLaunchButton
        $toolsScript = Join-Path $script:dashboardDir 'profile-tools.ps1'
        if (-not (Test-Path $toolsScript)) {
            [System.Windows.MessageBox]::Show(
                "profile-tools.ps1 was not found in the same folder as this dashboard.`n`nExpected location:`n$toolsScript",
                "Script Not Found", "OK", "Warning") | Out-Null
            return
        }
        $toolsBtn.IsEnabled = $false
        $toolsBtn.Content   = "Profile Tools (Running)"
        $_ptThemeArg = [int]$script:DarkTheme
        $_ptCfgArg = if ($script:_configFile) { " -ConfigFile `"$($script:_configFile)`"" } else { '' }
        $script:toolsProc   = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-ExecutionPolicy Bypass -File `"$toolsScript`" -UseExistingContext -DashboardTheme $_ptThemeArg$_ptCfgArg" -PassThru
        $localToolsProc     = $script:toolsProc   # local ref captured by GetNewClosure()

        # Re-enable the button once the Profile Tools window is closed.
        # $script: scope is unreliable inside GetNewClosure() closures, so use
        # the locally-captured Process reference to call HasExited directly.
        $toolsTimer          = New-Object System.Windows.Threading.DispatcherTimer
        $toolsTimer.Interval = [TimeSpan]::FromSeconds(2)
        $toolsTimer.Add_Tick({
            if ($localToolsProc -and $localToolsProc.HasExited) {
                $toolsTimer.Stop()
                $script:toolsProc   = $null
                $toolsBtn.IsEnabled = $true
                $toolsBtn.Content   = "Profile Tools"
            }
        }.GetNewClosure())
        $toolsTimer.Start()
    })
}

# =============================================================================
# 5. Invoke-AzureFilesTabTimer
#
# Called every second from the master DispatcherTimer tick handler.
# Handles:
#   - Auto-triggering a new background refresh when the interval elapses
#   - Processing completed jobs: populating FilesGrid and updating the
#     storage summary card in the dashboard header bar
# =============================================================================

function Invoke-AzureFilesTabTimer {

    # NOTE: No IsVisible guard here. The Azure Files background job must always run
    # so the Storage summary card in the dashboard header stays current regardless of
    # which tab is selected. The 15-minute refresh interval keeps the overhead negligible.

    # Auto-refresh when the interval has elapsed and no job is running
    if ($script:filesNextRefresh -and [DateTime]::Now -ge $script:filesNextRefresh -and
        (-not $script:filesHandle -or $script:filesHandle.IsCompleted)) {
        Invoke-FilesRefresh
    }

    # Process a completed job
    if ($script:filesHandle -and $script:filesHandle.IsCompleted) {
        try {
            $rows = $script:filesPS.EndInvoke($script:filesHandle)
            if ($rows -and $rows.Count -gt 0) {
                # Build the DataTable and reapply any cached costs from a previous Load Costs fetch.
                # Costs survive auto-refresh without re-calling the API - same pattern as Session Hosts.
                $script:afDataTable = ConvertTo-DataTable -Objects @($rows)

                if ($script:afCostCache -and $script:afCostCache.Count -gt 0) {
                    foreach ($row in $script:afDataTable.Rows) {
                        $key = "$($row['Storage Account'])|$($row['Share'])"
                        if ($script:afCostCache.ContainsKey($key)) {
                            $c = $script:afCostCache[$key]
                            $row['Storage GBP/mo']   = if ($c.Storage -gt 0) { '{0:F2}' -f $c.Storage } else { '-' }
                            $row['_StorageCostSort'] = $c.Storage
                        }
                    }
                }
                $script:FilesGrid.ItemsSource = $script:afDataTable.DefaultView
                if ($script:AFLoadCostsButton) { $script:AFLoadCostsButton.IsEnabled = $true }
                _AF_UpdateTotals
                $script:filesNextRefresh = [DateTime]::Now.AddSeconds($script:FilesRefreshIntervalSeconds)
                $script:FilesStatus.Text = "$($rows.Count) share(s) - Last updated: $(Get-Date -Format 'HH:mm:ss') - Next refresh in $([Math]::Round($script:FilesRefreshIntervalSeconds/60,0))min"

                # Update storage summary card - green tick if all OK, amber warning if any share exceeds threshold
                $lowShares = @($rows | Where-Object { $_."Quota (GiB)" -gt 0 -and $_."Used %" -ge $script:StorageWarningPct })
                if ($lowShares.Count -gt 0) {
                    $worst = $lowShares | Sort-Object "Used %" -Descending | Select-Object -First 1
                    $script:CardStorageIcon.Text          = "!"
                    $script:CardStorageIcon.Foreground    = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xC1,0x7F,0x00))
                    $script:CardStorageText.Text          = "$($worst."Share") $($worst."Used %")% used"
                    $script:CardStorageText.Foreground    = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x7D,0x52,0x00))
                    if ($script:DarkTheme) {
                        $script:CardStorageBorder.Background  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x2A,0x22,0x10))
                        $script:CardStorageBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xF7,0xB9,0x00))
                    } else {
                        $script:CardStorageBorder.Background  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xFF,0xF4,0xCE))
                        $script:CardStorageBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xF7,0xB9,0x00))
                    }
                } else {
                    $script:CardStorageIcon.Text          = [char]0x2714  # checkmark
                    if ($script:DarkTheme) {
                        $script:CardStorageIcon.Foreground    = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x4C,0xAF,0x50))
                        $script:CardStorageText.Foreground    = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x9D,0x9D,0x9D))
                        $script:CardStorageBorder.Background  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x2D,0x2D,0x30))
                        $script:CardStorageBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x3F,0x3F,0x46))
                    } else {
                        $script:CardStorageIcon.Foreground    = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x10,0x7C,0x10))
                        $script:CardStorageText.Foreground    = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x55,0x55,0x55))
                        $script:CardStorageBorder.Background  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xF7,0xF9,0xFC))
                        $script:CardStorageBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xDD,0xE1,0xE7))
                    }
                    $script:CardStorageText.Text = "Storage OK"
                }
            } else {
                $script:filesNextRefresh = [DateTime]::Now.AddSeconds($script:FilesRefreshIntervalSeconds)
                $script:FilesStatus.Text = "No FileStorage accounts found in this subscription."
            }
        } catch {
            $script:FilesStatus.Text = "Error loading files data: $_"
            Write-Log "ERROR [Azure Files] $_"
        } finally {
            try { $script:filesPS.Dispose() } catch {}
            $script:filesHandle = $null
            $script:filesPS     = $null
        }
    }
}

# =============================================================================
# 6. Reset-AzureFilesTab
#
# Called when the user switches subscriptions. Cancels any in-flight background
# job, clears the grid and status bar, resets the storage summary card to its
# neutral state, and schedules an immediate refresh for the new subscription.
# =============================================================================

function Reset-AzureFilesTab {
    # Cancel any in-flight files job
    if ($script:filesHandle -and -not $script:filesHandle.IsCompleted) {
        try { $script:filesPS.Stop() } catch {}
    }
    try { $script:filesPS.Dispose() } catch {}
    $script:filesHandle = $null
    $script:filesPS     = $null

    # Clear the grid and update status
    $script:FilesGrid.ItemsSource = $null
    $script:FilesStatus.Text      = "Switching subscription - loading..."

    # Reset storage summary card to neutral state
    $script:CardStorageIcon.Text       = "-"
    $script:CardStorageIcon.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x88,0x88,0x88))
    $script:CardStorageText.Text       = "Storage"
    if ($script:DarkTheme) {
        $script:CardStorageBorder.Background  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x2D,0x2D,0x30))
        $script:CardStorageBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x3F,0x3F,0x46))
    } else {
        $script:CardStorageBorder.Background  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xF7,0xF9,0xFC))
        $script:CardStorageBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xDD,0xE1,0xE7))
    }

    # Schedule an immediate refresh for the new subscription
    $script:filesNextRefresh = [DateTime]::Now

    # Hide totals bar on subscription switch
    if ($script:AFTotalsBar) { $script:AFTotalsBar.Visibility = 'Collapsed' }
}

# _AF_UpdateTotals
# Sums _StorageCostSort from the current DataTable and updates the totals bar.
# Called after grid bind and after Load Costs completes.
function _AF_UpdateTotals {
    if (-not $script:afDataTable -or -not $script:AFTotalsBar) { return }
    $totalStorage = 0.0; $hasCosts = $false
    foreach ($row in $script:afDataTable.Rows) {
        $s = $row['_StorageCostSort']; if ($s -gt 0) { $totalStorage += $s; $hasCosts = $true }
    }
    if ($hasCosts) {
        $script:AFTotalStorage.Text     = '{0:F2}' -f $totalStorage
        $script:AFTotalsBar.Visibility  = 'Visible'
    }
}
