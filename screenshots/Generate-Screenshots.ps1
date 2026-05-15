<#
.SYNOPSIS
    Generates screenshots of the AVD Live Dashboard, Profile Tools, and Log Viewer windows using WPF off-screen rendering.
.DESCRIPTION
    Extracts XAML from the dashboard and profile-tools scripts, loads each window off-screen
    with realistic mock data, renders to PNG via RenderTargetBitmap, and saves to the screenshots/ folder.
    No Azure connection is required.
.NOTES
    Run from the project root:  .\screenshots\Generate-Screenshots.ps1
    Requires Windows PowerShell 5.1 or PowerShell 7 on Windows (WPF).
#>

#Requires -Version 5.1

param(
    [switch]$ShowWindows   # For debugging: briefly show each window before capture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$outDir     = $PSScriptRoot
$scriptRoot = Split-Path $PSScriptRoot -Parent

# ─────────────────────────────────────────────────────────────────────────────
# Helper: extract a here-string XAML block from a script file
# Looks for:   $VariableName = @'  ...  '@
# ─────────────────────────────────────────────────────────────────────────────
function Get-XamlFromScript {
    param(
        [string]$Path,
        [string]$VariableName
    )
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    # Try single-quoted here-string first (@' ... '@), then double-quoted (@" ... "@)
    $startTag = "$VariableName = @'"
    $closeTag = "`n'@"
    $idx = $raw.IndexOf($startTag)
    if ($idx -lt 0) {
        $startTag = "$VariableName = @`""
        $closeTag = "`n`"@"
        $idx = $raw.IndexOf($startTag)
    }
    if ($idx -lt 0) { throw "Cannot find here-string for '$VariableName' in $Path" }
    $idx += $startTag.Length
    # Skip to the newline after @' or @"
    while ($idx -lt $raw.Length -and $raw[$idx] -ne "`n") { $idx++ }
    $idx++ # past the newline
    $endIdx = $raw.IndexOf($closeTag, $idx)
    if ($endIdx -lt 0) { $endIdx = $raw.IndexOf($closeTag.Replace("`n", "`r`n"), $idx) }
    if ($endIdx -lt 0) { throw "Cannot find closing here-string for $VariableName in $Path" }
    return $raw.Substring($idx, $endIdx - $idx)
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: strip event-handler attributes from XAML so it loads without code-behind
# ─────────────────────────────────────────────────────────────────────────────
function Remove-EventHandlers {
    param([string]$Xaml)
    $Xaml = $Xaml -replace '\s+(Click|MouseDoubleClick|MouseLeftButtonDown|SelectionChanged|PreviewKeyDown|TextChanged|Loaded|Checked|Unchecked|KeyDown|KeyUp|GotFocus|LostFocus|Drop|DragEnter|Closing|Closed|ContextMenuOpening)\s*=\s*"[^"]*"', ''
    return $Xaml
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: load XAML into a WPF window object
# ─────────────────────────────────────────────────────────────────────────────
function New-WpfWindow {
    param([string]$Xaml)
    $Xaml = Remove-EventHandlers $Xaml
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Xaml))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
    return $window
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: render a WPF window to a PNG file
# ─────────────────────────────────────────────────────────────────────────────
function Save-WindowScreenshot {
    param(
        [System.Windows.Window]$Window,
        [string]$OutputPath,
        [switch]$Show
    )
    $Window.WindowStartupLocation = 'Manual'
    $Window.Left   = -9999
    $Window.Top    = -9999
    $Window.ShowInTaskbar = $false

    if ($Show) {
        $Window.Left = 100
        $Window.Top  = 100
        $Window.ShowInTaskbar = $true
    }

    $Window.Show()
    $Window.UpdateLayout()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Render,
        [Action]{ }
    )
    Start-Sleep -Milliseconds 200

    $width  = [int]$Window.ActualWidth
    $height = [int]$Window.ActualHeight
    if ($width -le 0 -or $height -le 0) {
        $width  = [int]$Window.Width
        $height = [int]$Window.Height
    }

    $source = [System.Windows.PresentationSource]::FromVisual($Window)
    $dpiX = 96.0
    $dpiY = 96.0
    if ($source -and $source.CompositionTarget) {
        $dpiX = 96.0 * $source.CompositionTarget.TransformToDevice.M11
        $dpiY = 96.0 * $source.CompositionTarget.TransformToDevice.M22
    }

    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
        [int]($width * $dpiX / 96),
        [int]($height * $dpiY / 96),
        $dpiX, $dpiY,
        [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $rtb.Render($Window)

    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($OutputPath)
    $encoder.Save($fs)
    $fs.Close()

    if ($Show) { Start-Sleep -Seconds 2 }
    $Window.Close()
    Write-Host "  Saved: $OutputPath"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: add typed columns and bind mock data to a DataGrid
# ─────────────────────────────────────────────────────────────────────────────
function Set-GridData {
    param(
        [System.Windows.Controls.DataGrid]$Grid,
        [string[]]$Columns,
        [object[]]$Data
    )
    $Grid.AutoGenerateColumns = $false
    $Grid.ColumnWidth = [System.Windows.Controls.DataGridLength]::Auto
    foreach ($col in $Columns) {
        $dgc = New-Object System.Windows.Controls.DataGridTextColumn
        $dgc.Header  = $col
        $dgc.Binding = New-Object System.Windows.Data.Binding($col)
        $dgc.Width   = [System.Windows.Controls.DataGridLength]::Auto
        $Grid.Columns.Add($dgc)
    }
    $Grid.ItemsSource = $Data
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: apply heat map cell styles (green/amber/red backgrounds) to columns
# ─────────────────────────────────────────────────────────────────────────────
function Set-HeatMapStyle {
    param(
        [System.Windows.Controls.DataGrid]$Grid,
        [string]$ColumnName,
        [string]$ColorProperty
    )
    foreach ($col in $Grid.Columns) {
        if ($col.Header -eq $ColumnName) {
            $cellStyle = New-Object System.Windows.Style
            $cellStyle.TargetType = [System.Windows.Controls.DataGridCell]
            $brushConv = New-Object System.Windows.Media.BrushConverter
            foreach ($band in @(
                @{ Value = 'Green'; Hex = '#81C784' }
                @{ Value = 'Amber'; Hex = '#FFB74D' }
                @{ Value = 'Red';   Hex = '#E57373' }
            )) {
                $trigger = New-Object System.Windows.DataTrigger
                $binding = New-Object System.Windows.Data.Binding($ColorProperty)
                $trigger.Binding = $binding
                $trigger.Value   = $band.Value
                $setter = New-Object System.Windows.Setter
                $setter.Property = [System.Windows.Controls.Control]::BackgroundProperty
                $setter.Value    = $brushConv.ConvertFromString($band.Hex)
                [void]$trigger.Setters.Add($setter)
                [void]$cellStyle.Triggers.Add($trigger)
            }
            $col.CellStyle = $cellStyle
            break
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: apply the dark theme resource dictionary to a window
# ─────────────────────────────────────────────────────────────────────────────
function Apply-Theme {
    param([System.Windows.Window]$Window, [string]$ThemeFile)
    $tc = Get-Content -Raw -Path (Join-Path $scriptRoot "data\$ThemeFile-theme.xaml") -Encoding UTF8
    $rd = [System.Windows.Markup.XamlReader]::Parse(
        "<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' " +
        "xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>$tc</ResourceDictionary>")
    $Window.Resources.MergedDictionaries.Add($rd)
    $Window.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'Avd.Window.Bg')
    $Window.SetResourceReference([System.Windows.Window]::ForegroundProperty, 'Avd.Window.Fg')
}
function Apply-LightTheme { param([System.Windows.Window]$Window); Apply-Theme $Window 'light' }
function Apply-DarkTheme  { param([System.Windows.Window]$Window); Apply-Theme $Window 'dark'  }

# =============================================================================
# Read and assemble the main dashboard XAML
# =============================================================================
Write-Host "`nGenerating dashboard screenshots..." -ForegroundColor Cyan

$shTabXaml    = Get-XamlFromScript -Path (Join-Path $scriptRoot 'scripts\tab-sessionhosts.ps1')  -VariableName '$SessionHostsTab_Xaml'
$filesTabXaml = Get-XamlFromScript -Path (Join-Path $scriptRoot 'scripts\tab-azurefiles.ps1')    -VariableName '$AzureFilesTab_Xaml'
$monTabXaml   = Get-XamlFromScript -Path (Join-Path $scriptRoot 'scripts\tab-monitoring.ps1')     -VariableName '$MonitoringTab_Xaml'
$infraTabXaml = Get-XamlFromScript -Path (Join-Path $scriptRoot 'scripts\tab-infrastructure.ps1') -VariableName '$InfrastructureTab_Xaml'
$siTabXaml    = Get-XamlFromScript -Path (Join-Path $scriptRoot 'scripts\tab-sessioninfo.ps1')   -VariableName '$SessionInfoTab_Xaml'
$imgTabXaml   = Get-XamlFromScript -Path (Join-Path $scriptRoot 'scripts\tab-images.ps1')        -VariableName '$ImagesTab_Xaml'

$dashRaw = Get-XamlFromScript -Path (Join-Path $scriptRoot 'avd-live-dashboard.ps1') -VariableName '$rawXaml'

$dashFull = $dashRaw `
    -replace '<!-- TAB:SESSION_HOSTS -->', $shTabXaml `
    -replace '<!-- TAB:AZURE_FILES -->',   $filesTabXaml `
    -replace '<!-- TAB:MONITORING -->',    $monTabXaml `
    -replace '<!-- TAB:INFRASTRUCTURE -->', $infraTabXaml `
    -replace '<!-- TAB:SESSION_INFO -->',  $siTabXaml `
    -replace '<!-- TAB:IMAGES -->',        $imgTabXaml

$dashFull = $dashFull.Replace('<!-- THEME_SLOT -->', '')

# Clean up labels for screenshots
$dashFull = $dashFull -replace 'DEVELOPMENT BUILD', ''

# ─────────────────────────────────────────────────────────────────────────────
# Shared: populate summary cards and status bar on a dashboard window
# ─────────────────────────────────────────────────────────────────────────────
function Initialize-DashboardWindow {
    param([System.Windows.Window]$W, [int]$Width = 1200)
    $W.Width = $Width
    Apply-LightTheme $W
    $W.FindName("CardPools").Text   = "6"
    $W.FindName("CardVMs").Text     = "47"
    $W.FindName("CardOn").Text      = "32"
    $W.FindName("CardOff").Text     = "15"
    $W.FindName("CardActive").Text  = "128"
    $W.FindName("CardDisconn").Text = "12"
    $W.FindName("CardTotal").Text   = "140"
    $W.FindName("CardStorageIcon").Text       = [char]0x2714
    $W.FindName("CardStorageIcon").Foreground = [System.Windows.Media.Brushes]::Green
    $W.FindName("CardStorageText").Text       = "Storage OK"
    $W.FindName("ConnectedAsText").Text = "Connected as: admin@contoso.com  |  Subscription: Contoso Production"
    $W.FindName("StatusText").Text      = "Last updated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $W.FindName("CountdownText").Text   = "Next refresh in 28s"
}

function Select-Tab {
    param([System.Windows.Window]$W, [string]$Header)
    $tc = $W.FindName("MainTabControl")
    foreach ($tab in $tc.Items) {
        if ($tab.Header -eq $Header) { $tc.SelectedItem = $tab; break }
    }
}

# =============================================================================
# Mock data
# =============================================================================
$poolData = @(
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-001'; 'Workspace'='WS-GEN-UKS'; 'VM Region'='uksouth'; 'Image Version'='1.2.4'; 'Total VMs'=12; 'VMs On'=8; 'VMs Off'=4; 'Active Users'=34; 'Disconnected'=3; 'Total Sessions'=37; 'Scaling Plan'='Yes'; 'Host Pool RG'='AVDCORE-UKS-PROD-RG'; 'Scope'='Geographical'; 'HP Location'='uksouth' }
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-002'; 'Workspace'='WS-GEN-UKS'; 'VM Region'='uksouth'; 'Image Version'='1.2.4'; 'Total VMs'=8;  'VMs On'=6; 'VMs Off'=2; 'Active Users'=24; 'Disconnected'=2; 'Total Sessions'=26; 'Scaling Plan'='Yes'; 'Host Pool RG'='AVDCORE-UKS-PROD-RG'; 'Scope'='Geographical'; 'HP Location'='uksouth' }
    [PSCustomObject]@{ 'Host Pool'='HP-FIN-UKS-001'; 'Workspace'='WS-FIN-UKS'; 'VM Region'='uksouth'; 'Image Version'='1.2.3'; 'Total VMs'=6;  'VMs On'=4; 'VMs Off'=2; 'Active Users'=18; 'Disconnected'=1; 'Total Sessions'=19; 'Scaling Plan'='Yes'; 'Host Pool RG'='AVDCORE-UKS-PROD-RG'; 'Scope'='Regional';      'HP Location'='uksouth' }
    [PSCustomObject]@{ 'Host Pool'='HP-DEV-UKS-001'; 'Workspace'='WS-DEV-UKS'; 'VM Region'='uksouth'; 'Image Version'='1.2.4'; 'Total VMs'=4;  'VMs On'=3; 'VMs Off'=1; 'Active Users'=12; 'Disconnected'=0; 'Total Sessions'=12; 'Scaling Plan'='No';  'Host Pool RG'='AVDCORE-UKS-DEV-RG';  'Scope'='Geographical'; 'HP Location'='uksouth' }
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-FRC-001'; 'Workspace'='WS-GEN-FRC'; 'VM Region'='francecentral'; 'Image Version'='1.2.4'; 'Total VMs'=10; 'VMs On'=7; 'VMs Off'=3; 'Active Users'=28; 'Disconnected'=4; 'Total Sessions'=32; 'Scaling Plan'='Yes'; 'Host Pool RG'='AVDCORE-FRC-PROD-RG'; 'Scope'='Geographical'; 'HP Location'='francecentral' }
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-UAT'; 'Workspace'='WS-GEN-UAT'; 'VM Region'='uksouth'; 'Image Version'='1.3.0'; 'Total VMs'=7;  'VMs On'=4; 'VMs Off'=3; 'Active Users'=12; 'Disconnected'=2; 'Total Sessions'=14; 'Scaling Plan'='No';  'Host Pool RG'='AVDCORE-UKS-UAT-RG';  'Scope'='Geographical'; 'HP Location'='uksouth' }
)

$filesData = @(
    [PSCustomObject]@{ 'Storage Account'='saproduks01'; 'Resource Group'='RG-AVD-FILES-UKS'; 'Location'='uksouth'; 'Share'='fslogix'; 'Quota (GiB)'=5120; 'Used (GiB)'=3891; 'Free (GiB)'=1229; 'Used %'=76 }
    [PSCustomObject]@{ 'Storage Account'='saproduks02'; 'Resource Group'='RG-AVD-FILES-UKS'; 'Location'='uksouth'; 'Share'='fslogix'; 'Quota (GiB)'=5120; 'Used (GiB)'=2104; 'Free (GiB)'=3016; 'Used %'=41 }
    [PSCustomObject]@{ 'Storage Account'='saprodfrc01'; 'Resource Group'='RG-AVD-FILES-FRC'; 'Location'='francecentral'; 'Share'='fslogix'; 'Quota (GiB)'=2048; 'Used (GiB)'=1740; 'Free (GiB)'=308; 'Used %'=85 }
    [PSCustomObject]@{ 'Storage Account'='saprodukw01'; 'Resource Group'='RG-AVD-FILES-UKW'; 'Location'='ukwest'; 'Share'='msix'; 'Quota (GiB)'=1024; 'Used (GiB)'=412; 'Free (GiB)'=612; 'Used %'=40 }
)

$shData = @(
    [PSCustomObject]@{ 'VM Name'='AVDSH-UKS-001'; 'Host Pool'='HP-GEN-UKS-001'; 'Region'='uksouth'; 'Power State'='Available'; 'Health State'='Healthy'; 'Sessions'=5; 'CPU %'='34.2%'; 'Mem %'='61.8%'; 'Disk %'='45.3%'; 'Input Delay Median'='3ms'; 'Input Delay P95'='16ms'; '_CPUColor'='Green'; '_MemColor'='Green'; '_DiskColor'='Green'; '_InputDelayColor'='Green'; '_InputDelayP95Color'='Green'; 'OS Disk IOPS'='245'; 'OS Disk IOPS %'='12.3%'; '_DiskIOPSPctColor'='Green'; 'OS Disk Queue'='0.2'; '_DiskQueueColor'='Green'; 'Disk SKU'='P10 (128 GB) 500 IOPS'; 'Drain Mode'='Off'; 'Scaling Exclude'='-'; 'Last Heartbeat'=(Get-Date -Format 'HH:mm:ss'); 'Agent Version'='1.0.9750.400'; 'OS Version'='10.0.20348' }
    [PSCustomObject]@{ 'VM Name'='AVDSH-UKS-002'; 'Host Pool'='HP-GEN-UKS-001'; 'Region'='uksouth'; 'Power State'='Available'; 'Health State'='Healthy'; 'Sessions'=4; 'CPU %'='78.5%'; 'Mem %'='82.1%'; 'Disk %'='67.9%'; 'Input Delay Median'='18ms'; 'Input Delay P95'='62ms'; '_CPUColor'='Amber'; '_MemColor'='Amber'; '_DiskColor'='Green'; '_InputDelayColor'='Green'; '_InputDelayP95Color'='Amber'; 'OS Disk IOPS'='892'; 'OS Disk IOPS %'='44.6%'; '_DiskIOPSPctColor'='Green'; 'OS Disk Queue'='1.8'; '_DiskQueueColor'='Green'; 'Disk SKU'='P10 (128 GB) 500 IOPS'; 'Drain Mode'='Off'; 'Scaling Exclude'='-'; 'Last Heartbeat'=(Get-Date -Format 'HH:mm:ss'); 'Agent Version'='1.0.9750.400'; 'OS Version'='10.0.20348' }
    [PSCustomObject]@{ 'VM Name'='AVDSH-UKS-003'; 'Host Pool'='HP-GEN-UKS-001'; 'Region'='uksouth'; 'Power State'='Available'; 'Health State'='Healthy'; 'Sessions'=3; 'CPU %'='12.7%'; 'Mem %'='55.4%'; 'Disk %'='38.1%'; 'Input Delay Median'='5ms'; 'Input Delay P95'='16ms'; '_CPUColor'='Green'; '_MemColor'='Green'; '_DiskColor'='Green'; '_InputDelayColor'='Green'; '_InputDelayP95Color'='Green'; 'OS Disk IOPS'='156'; 'OS Disk IOPS %'='7.8%'; '_DiskIOPSPctColor'='Green'; 'OS Disk Queue'='0.1'; '_DiskQueueColor'='Green'; 'Disk SKU'='P10 (128 GB) 500 IOPS'; 'Drain Mode'='Off'; 'Scaling Exclude'='-'; 'Last Heartbeat'=(Get-Date -Format 'HH:mm:ss'); 'Agent Version'='1.0.9750.400'; 'OS Version'='10.0.20348' }
    [PSCustomObject]@{ 'VM Name'='AVDSH-UKS-004'; 'Host Pool'='HP-GEN-UKS-001'; 'Region'='uksouth'; 'Power State'='Shutdown'; 'Health State'='N/A'; 'Sessions'=0; 'CPU %'='-'; 'Mem %'='-'; 'Disk %'='-'; 'Input Delay Median'='-'; 'Input Delay P95'='-'; '_CPUColor'=''; '_MemColor'=''; '_DiskColor'=''; '_InputDelayColor'=''; '_InputDelayP95Color'=''; 'OS Disk IOPS'='-'; 'OS Disk IOPS %'='-'; '_DiskIOPSPctColor'=''; 'OS Disk Queue'='-'; '_DiskQueueColor'=''; 'Disk SKU'='P10 (128 GB) 500 IOPS'; 'Drain Mode'='Off'; 'Scaling Exclude'='-'; 'Last Heartbeat'='N/A'; 'Agent Version'='1.0.9750.400'; 'OS Version'='10.0.20348' }
    [PSCustomObject]@{ 'VM Name'='AVDSH-UKS-005'; 'Host Pool'='HP-GEN-UKS-002'; 'Region'='uksouth'; 'Power State'='Available'; 'Health State'='Healthy'; 'Sessions'=6; 'CPU %'='91.3%'; 'Mem %'='76.2%'; 'Disk %'='88.4%'; 'Input Delay Median'='200ms'; 'Input Delay P95'='141ms'; '_CPUColor'='Red'; '_MemColor'='Amber'; '_DiskColor'='Amber'; '_InputDelayColor'='Red'; '_InputDelayP95Color'='Red'; 'OS Disk IOPS'='1247'; 'OS Disk IOPS %'='87.4%'; '_DiskIOPSPctColor'='Amber'; 'OS Disk Queue'='3.9'; '_DiskQueueColor'='Amber'; 'Disk SKU'='P10 (128 GB) 500 IOPS'; 'Drain Mode'='Off'; 'Scaling Exclude'='-'; 'Last Heartbeat'=(Get-Date -Format 'HH:mm:ss'); 'Agent Version'='1.0.9750.400'; 'OS Version'='10.0.20348' }
    [PSCustomObject]@{ 'VM Name'='AVDSH-UKS-006'; 'Host Pool'='HP-GEN-UKS-002'; 'Region'='uksouth'; 'Power State'='Available'; 'Health State'='Unhealthy (1)'; 'Sessions'=2; 'CPU %'='45.8%'; 'Mem %'='93.4%'; 'Disk %'='71.2%'; 'Input Delay Median'='29ms'; 'Input Delay P95'='62ms'; '_CPUColor'='Green'; '_MemColor'='Red'; '_DiskColor'='Green'; '_InputDelayColor'='Green'; '_InputDelayP95Color'='Amber'; 'OS Disk IOPS'='78'; 'OS Disk IOPS %'='3.9%'; '_DiskIOPSPctColor'='Green'; 'OS Disk Queue'='0.1'; '_DiskQueueColor'='Green'; 'Disk SKU'='P10 (128 GB) 500 IOPS'; 'Drain Mode'='On'; 'Scaling Exclude'='Yes'; 'Last Heartbeat'=(Get-Date -Format 'HH:mm:ss'); 'Agent Version'='1.0.9630.200'; 'OS Version'='10.0.20348' }
    [PSCustomObject]@{ 'VM Name'='AVDSH-FRC-001'; 'Host Pool'='HP-GEN-FRC-001'; 'Region'='francecentral'; 'Power State'='Available'; 'Health State'='Healthy'; 'Sessions'=7; 'CPU %'='56.1%'; 'Mem %'='68.9%'; 'Disk %'='52.7%'; 'Input Delay Median'='10ms'; 'Input Delay P95'='31ms'; '_CPUColor'='Green'; '_MemColor'='Green'; '_DiskColor'='Green'; '_InputDelayColor'='Green'; '_InputDelayP95Color'='Green'; 'OS Disk IOPS'='312'; 'OS Disk IOPS %'='15.6%'; '_DiskIOPSPctColor'='Green'; 'OS Disk Queue'='0.3'; '_DiskQueueColor'='Green'; 'Disk SKU'='P10 (128 GB) 500 IOPS'; 'Drain Mode'='Off'; 'Scaling Exclude'='-'; 'Last Heartbeat'=(Get-Date -Format 'HH:mm:ss'); 'Agent Version'='1.0.9750.400'; 'OS Version'='10.0.20348' }
    [PSCustomObject]@{ 'VM Name'='AVDSH-FRC-002'; 'Host Pool'='HP-GEN-FRC-001'; 'Region'='francecentral'; 'Power State'='Shutdown'; 'Health State'='N/A'; 'Sessions'=0; 'CPU %'='-'; 'Mem %'='-'; 'Disk %'='-'; 'Input Delay Median'='-'; 'Input Delay P95'='-'; '_CPUColor'=''; '_MemColor'=''; '_DiskColor'=''; '_InputDelayColor'=''; '_InputDelayP95Color'=''; 'OS Disk IOPS'='-'; 'OS Disk IOPS %'='-'; '_DiskIOPSPctColor'=''; 'OS Disk Queue'='-'; '_DiskQueueColor'=''; 'Disk SKU'='P10 (128 GB) 500 IOPS'; 'Drain Mode'='Off'; 'Scaling Exclude'='-'; 'Last Heartbeat'='N/A'; 'Agent Version'='1.0.9750.400'; 'OS Version'='10.0.20348' }
)

$infraData = @(
    [PSCustomObject]@{ 'VM Name'='DC-UKS-001'; 'Resource Group'='RG-INFRA-UKS'; 'Region'='uksouth'; 'Power State'='VM running'; 'OS Type'='Windows'; 'IP Address'='10.0.1.4'; 'VM SKU'='Standard_D2s_v5'; 'Avail Zone'='1' }
    [PSCustomObject]@{ 'VM Name'='DC-UKS-002'; 'Resource Group'='RG-INFRA-UKS'; 'Region'='uksouth'; 'Power State'='VM running'; 'OS Type'='Windows'; 'IP Address'='10.0.1.5'; 'VM SKU'='Standard_D2s_v5'; 'Avail Zone'='2' }
    [PSCustomObject]@{ 'VM Name'='FS-UKS-001'; 'Resource Group'='RG-INFRA-UKS'; 'Region'='uksouth'; 'Power State'='VM running'; 'OS Type'='Windows'; 'IP Address'='10.0.1.10'; 'VM SKU'='Standard_D4s_v5'; 'Avail Zone'='1' }
    [PSCustomObject]@{ 'VM Name'='DC-FRC-001'; 'Resource Group'='RG-INFRA-FRC'; 'Region'='francecentral'; 'Power State'='VM running'; 'OS Type'='Windows'; 'IP Address'='10.1.1.4'; 'VM SKU'='Standard_D2s_v5'; 'Avail Zone'='1' }
    [PSCustomObject]@{ 'VM Name'='MGMT-UKS-001'; 'Resource Group'='RG-INFRA-UKS'; 'Region'='uksouth'; 'Power State'='VM deallocated'; 'OS Type'='Windows'; 'IP Address'='10.0.1.20'; 'VM SKU'='Standard_B2ms'; 'Avail Zone'='-' }
)

$imgData = @(
    [PSCustomObject]@{ 'VM Name'='IMG-UKS-001'; 'Resource Group'='RG-IMAGES-UKS'; 'Region'='uksouth'; 'Power State'='VM running'; 'OS Type'='Windows'; 'IP Address'='10.0.2.4'; 'VM SKU'='Standard_D4s_v5'; 'Avail Zone'='-' }
    [PSCustomObject]@{ 'VM Name'='IMG-UKS-002'; 'Resource Group'='RG-IMAGES-UKS'; 'Region'='uksouth'; 'Power State'='VM deallocated'; 'OS Type'='Windows'; 'IP Address'='10.0.2.5'; 'VM SKU'='Standard_D4s_v5'; 'Avail Zone'='-' }
    [PSCustomObject]@{ 'VM Name'='IMG-FRC-001'; 'Resource Group'='RG-IMAGES-FRC'; 'Region'='francecentral'; 'Power State'='VM deallocated'; 'OS Type'='Windows'; 'IP Address'='10.1.2.4'; 'VM SKU'='Standard_D4s_v5'; 'Avail Zone'='-' }
)

# =============================================================================
# 1. Per Host Pool tab
# =============================================================================
Write-Host "  [1/13] Per Host Pool tab..."
$w1 = New-WpfWindow -Xaml $dashFull
Initialize-DashboardWindow $w1
Set-GridData -Grid $w1.FindName("PoolGrid") `
    -Columns @('Host Pool','Workspace','VM Region','Image Version','Total VMs','VMs On','VMs Off','Active Users','Disconnected','Total Sessions','Scaling Plan','Host Pool RG','Scope','HP Location') `
    -Data $poolData
Select-Tab $w1 'Per Host Pool'
Save-WindowScreenshot -Window $w1 -OutputPath (Join-Path $outDir 'dashboard.png') -Show:$ShowWindows

# 1b. Dark mode - Per Host Pool tab
Write-Host "  [1b/14] Per Host Pool tab (dark mode)..."
$w1d = New-WpfWindow -Xaml $dashFull
Initialize-DashboardWindow $w1d
Set-GridData -Grid $w1d.FindName("PoolGrid") `
    -Columns @('Host Pool','Workspace','VM Region','Image Version','Total VMs','VMs On','VMs Off','Active Users','Disconnected','Total Sessions','Scaling Plan','Host Pool RG','Scope','HP Location') `
    -Data $poolData
Apply-DarkTheme $w1d
$w1d.FindName('DarkToggle').IsChecked = $true
Select-Tab $w1d 'Per Host Pool'
Save-WindowScreenshot -Window $w1d -OutputPath (Join-Path $outDir 'dashboard-dark.png') -Show:$ShowWindows

# =============================================================================
# 2. Azure Files tab
# =============================================================================
Write-Host "  [2/13] Azure Files tab..."
$w2 = New-WpfWindow -Xaml $dashFull
Initialize-DashboardWindow $w2
Set-GridData -Grid $w2.FindName("FilesGrid") `
    -Columns @('Storage Account','Resource Group','Location','Share','Quota (GiB)','Used (GiB)','Free (GiB)','Used %') `
    -Data $filesData
$w2.FindName("FilesStatus").Text = "4 share(s) - Last updated: $(Get-Date -Format 'HH:mm:ss') - Next refresh in 15min"
Select-Tab $w2 'Azure Files'
Save-WindowScreenshot -Window $w2 -OutputPath (Join-Path $outDir 'azure-files.png') -Show:$ShowWindows

# =============================================================================
# 3. Session Hosts tab
# =============================================================================
Write-Host "  [3/13] Session Hosts tab..."
$w3 = New-WpfWindow -Xaml $dashFull
Initialize-DashboardWindow $w3 -Width 1500
$shGrid = $w3.FindName("SHGrid")
if ($shGrid) {
    Set-GridData -Grid $shGrid `
        -Columns @('VM Name','Host Pool','Region','Power State','Health State','Sessions','CPU %','Mem %','Disk %','Input Delay Median','Input Delay P95','_CPUColor','_MemColor','_DiskColor','_InputDelayColor','_InputDelayP95Color','OS Disk IOPS','OS Disk IOPS %','_DiskIOPSPctColor','OS Disk Queue','_DiskQueueColor','Disk SKU','Drain Mode','Scaling Exclude','Last Heartbeat','Agent Version','OS Version') `
        -Data $shData
    # Hide the helper color columns
    foreach ($col in $shGrid.Columns) {
        if ($col.Header -in @('_CPUColor', '_MemColor', '_DiskColor', '_InputDelayColor', '_InputDelayP95Color', '_DiskIOPSPctColor', '_DiskQueueColor')) {
            $col.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }
    # Apply heat map cell styles
    Set-HeatMapStyle -Grid $shGrid -ColumnName 'CPU %'            -ColorProperty '_CPUColor'
    Set-HeatMapStyle -Grid $shGrid -ColumnName 'Mem %'            -ColorProperty '_MemColor'
    Set-HeatMapStyle -Grid $shGrid -ColumnName 'Disk %'           -ColorProperty '_DiskColor'
    Set-HeatMapStyle -Grid $shGrid -ColumnName 'Input Delay Median'  -ColorProperty '_InputDelayColor'
    Set-HeatMapStyle -Grid $shGrid -ColumnName 'Input Delay P95'    -ColorProperty '_InputDelayP95Color'
    Set-HeatMapStyle -Grid $shGrid -ColumnName 'OS Disk IOPS %'    -ColorProperty '_DiskIOPSPctColor'
    Set-HeatMapStyle -Grid $shGrid -ColumnName 'OS Disk Queue'     -ColorProperty '_DiskQueueColor'
}
$shStatus = $w3.FindName("SHStatusText")
if ($shStatus) { $shStatus.Text = "8 VM(s)  Available: 6  Other: 2  |  Updated: $(Get-Date -Format 'HH:mm:ss')   Next in 54s   Metrics: Batch" }
Select-Tab $w3 'Session Hosts'
Save-WindowScreenshot -Window $w3 -OutputPath (Join-Path $outDir 'session-hosts.png') -Show:$ShowWindows

# =============================================================================
# 4. Infrastructure tab
# =============================================================================
Write-Host "  [4/13] Infrastructure tab..."
$w4 = New-WpfWindow -Xaml $dashFull
Initialize-DashboardWindow $w4
$isGrid = $w4.FindName("ISGrid")
if ($isGrid) {
    Set-GridData -Grid $isGrid `
        -Columns @('VM Name','Resource Group','Region','Power State','OS Type','IP Address','VM SKU','Avail Zone') `
        -Data $infraData
}
$isStatus = $w4.FindName("ISStatusText")
if ($isStatus) { $isStatus.Text = "5 VMs (4 running, 1 deallocated) - Next refresh in 48s" }
Select-Tab $w4 'Infrastructure'
Save-WindowScreenshot -Window $w4 -OutputPath (Join-Path $outDir 'infrastructure.png') -Show:$ShowWindows

# =============================================================================
# 5. Images tab
# =============================================================================
Write-Host "  [5/13] Images tab..."
$wImg = New-WpfWindow -Xaml $dashFull
Initialize-DashboardWindow $wImg
$imgGrid = $wImg.FindName("IMGGrid")
if ($imgGrid) {
    Set-GridData -Grid $imgGrid `
        -Columns @('VM Name','Resource Group','Region','Power State','OS Type','IP Address','VM SKU','Avail Zone') `
        -Data $imgData
}
$imgStatus = $wImg.FindName("IMGStatusText")
if ($imgStatus) { $imgStatus.Text = "3 VMs (1 running, 2 deallocated) - Next refresh in 52s" }
Select-Tab $wImg 'Images'
Save-WindowScreenshot -Window $wImg -OutputPath (Join-Path $outDir 'images.png') -Show:$ShowWindows

# =============================================================================
# 6. Monitoring tab
# =============================================================================
Write-Host "  [6/14] Monitoring tab..."
$wMon = New-WpfWindow -Xaml $dashFull
Initialize-DashboardWindow $wMon
$monWinlogonStatus = $wMon.FindName('MonWinlogonStatus')
$monRttStatus      = $wMon.FindName('MonRttStatus')
$monRangeDisplay   = $wMon.FindName('MonRangeDisplay')
if ($monWinlogonStatus) { $monWinlogonStatus.Text = 'Log Analytics Workspace not configured.' }
if ($monRttStatus)      { $monRttStatus.Text      = 'Log Analytics Workspace not configured.' }
if ($monRangeDisplay)   { $monRangeDisplay.Text   = 'Last 48 Hours' }
Select-Tab $wMon 'Monitoring'
Save-WindowScreenshot -Window $wMon -OutputPath (Join-Path $outDir 'monitoring.png') -Show:$ShowWindows

# =============================================================================
# 7. Settings dialog
# =============================================================================
Write-Host "  [7/14] Settings dialog..."
$settingsXaml = (Get-XamlFromScript -Path (Join-Path $scriptRoot 'avd-live-dashboard.ps1') -VariableName '$_settingsXamlRaw').Replace('<!-- THEME_SLOT -->', '')
$ws = New-WpfWindow -Xaml $settingsXaml
Apply-LightTheme $ws
# Left column: Operational Settings
$ws.FindName("RefreshIntervalBox").Text     = "30"
$ws.FindName("FilesIntervalBox").Text       = "15"
$ws.FindName("StorageWarningPctBox").Text   = "90"
$ws.FindName("ShadowMstscRadio").IsChecked  = $true
$ws.FindName("ShadowDnsRadio").IsChecked    = $true
$ws.FindName("AvdIncludeRGsBox").Text       = "AVDCORE-UKS-PROD-RG`r`nAVDCORE-FRC-PROD-RG"
$ws.FindName("InfraRGsBox").Text            = "RG-INFRA-UKS`r`nRG-INFRA-FRC"

# Right column: Display & Filter Settings
$ws.FindName("SecondaryRegionHighlightCheck").IsChecked = $true
$ws.FindName("HTabInfrastructure").IsChecked = $true              # Infrastructure tab hidden
$ws.FindName("HColWorkspace").IsChecked      = $true              # Workspace column hidden
$ws.FindName("HColHostPoolRG").IsChecked     = $true              # Host Pool RG column hidden
$ws.FindName("LowPriorityPatternsBox").Text  = "-UAT`r`n-TEST"
$ws.FindName("SecondaryRegionsBox").Text     = "francecentral"
$ws.FindName("ScalingExcludeTagBox").Text    = "ExcludeFromScaling"
$ws.FindName("SAKindFileStorage").IsChecked  = $true
$ws.FindName("SAKindStorageV2").IsChecked    = $true
$ws.FindName("InfraExcludePatternsBox").Text = "-TEMP`r`n-OLD"
Save-WindowScreenshot -Window $ws -OutputPath (Join-Path $outDir 'settings.png') -Show:$ShowWindows

# =============================================================================
# 6. Profile Tools
# =============================================================================
Write-Host "  [8/13] Profile Tools..."
$ptXaml = (Get-XamlFromScript -Path (Join-Path $scriptRoot 'profile-tools.ps1') -VariableName '$_ptXamlRaw').Replace('<!-- THEME_SLOT -->', '')
$wp = New-WpfWindow -Xaml $ptXaml
Apply-LightTheme $wp
$subText = $wp.FindName("SubText")
if ($subText) { $subText.Text = "Connected as: admin@contoso.com  |  Subscription: Contoso Production" }
$statusBar = $wp.FindName("StatusBar")
if ($statusBar) { $statusBar.Text = "Ready." }
Save-WindowScreenshot -Window $wp -OutputPath (Join-Path $outDir 'profile-tools.png') -Show:$ShowWindows

# =============================================================================
# 7. Performance History popup
# =============================================================================
Write-Host "  [9/13] Performance History popup..."

# Generate mock CPU and Mem data over 1 hour with 1-minute bins (~60 points)
$baseTime = (Get-Date).AddHours(-1)
$rng = New-Object System.Random(42)
$mockCpu = @()
$mockMem = @()
$cpuBase = 42.0
$memBase = 64.0
for ($i = 0; $i -lt 60; $i++) {
    $t = $baseTime.AddMinutes($i)
    # CPU: oscillates with a spike around minute 35-42
    $cpuVal = $cpuBase + 12 * [Math]::Sin($i / 8.0) + $rng.NextDouble() * 6
    if ($i -ge 35 -and $i -le 42) { $cpuVal += 30 }  # spike to ~85-95%
    $cpuVal = [Math]::Round([Math]::Max(5, [Math]::Min(98, $cpuVal)), 1)

    # Mem: gradual rise with small fluctuations
    $memVal = $memBase + ($i * 0.15) + $rng.NextDouble() * 4 - 2
    $memVal = [Math]::Round([Math]::Max(40, [Math]::Min(95, $memVal)), 1)

    $mockCpu += [PSCustomObject]@{ Time = $t; Value = $cpuVal }
    $mockMem += [PSCustomObject]@{ Time = $t; Value = $memVal }
}

# Build the popup window XAML (matches the real Performance History dialog)
$perfWinXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Performance History - AVDSH-UKS-005"
        Height="450" Width="750"
        Background="#F4F6F9" FontFamily="Segoe UI">
    <DockPanel Margin="12">
        <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0" Text="Time Range:" VerticalAlignment="Center"
                       FontSize="12" Foreground="#333" Margin="0,0,8,0"/>
            <ComboBox x:Name="TimeRangeCombo" Grid.Column="1" Width="140"
                      FontSize="12" SelectedIndex="0">
                <ComboBoxItem Content="Last 1 Hour"   Tag="PT1H"/>
                <ComboBoxItem Content="Last 4 Hours"  Tag="PT4H"/>
                <ComboBoxItem Content="Last 12 Hours" Tag="PT12H"/>
                <ComboBoxItem Content="Last 24 Hours" Tag="PT24H"/>
            </ComboBox>
            <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
                <Rectangle Width="14" Height="14" Fill="#1976D2" Margin="0,0,4,0" RadiusX="2" RadiusY="2"/>
                <TextBlock Text="CPU %" FontSize="11" Foreground="#333" VerticalAlignment="Center" Margin="0,0,14,0"/>
                <Rectangle Width="14" Height="14" Fill="#FB8C00" Margin="0,0,4,0" RadiusX="2" RadiusY="2"/>
                <TextBlock Text="Mem %" FontSize="11" Foreground="#333" VerticalAlignment="Center"/>
            </StackPanel>
        </Grid>
        <TextBlock x:Name="PerfStatus" DockPanel.Dock="Bottom"
                   FontSize="11" Foreground="#777" Margin="0,6,0,0"
                   Text="60 data point(s) - CPU and Memory % (avg per interval)"/>
        <Border Background="White" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="4">
            <Canvas x:Name="ChartCanvas" ClipToBounds="True"/>
        </Border>
    </DockPanel>
</Window>
'@

$perfWin = New-WpfWindow -Xaml $perfWinXaml
$perfCanvas = $perfWin.FindName('ChartCanvas')

# Show window off-screen to measure Canvas, then render chart, then capture
$perfWin.WindowStartupLocation = 'Manual'
$perfWin.Left = -9999; $perfWin.Top = -9999; $perfWin.ShowInTaskbar = $false
$perfWin.Show()
$perfWin.UpdateLayout()
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
    [System.Windows.Threading.DispatcherPriority]::Render, [Action]{ })
Start-Sleep -Milliseconds 200

# ── Render the chart on the Canvas ──────────────────────────────────────
$cCanvas = $perfCanvas
$w = $cCanvas.ActualWidth
$h = $cCanvas.ActualHeight

if ($w -ge 100 -and $h -ge 80) {
    $ml = 55; $mr = 40; $mt = 15; $mb = 35
    $cw = $w - $ml - $mr
    $ch = $h - $mt - $mb
    $brushConv = New-Object System.Windows.Media.BrushConverter

    # Helper: add a Line
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
        [void]$cCanvas.Children.Add($ln)
    }

    # Helper: add a TextBlock
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
        [void]$cCanvas.Children.Add($tb)
    }

    # Chart background
    $bg = New-Object System.Windows.Shapes.Rectangle
    $bg.Width = $cw; $bg.Height = $ch
    $bg.Fill = $brushConv.ConvertFromString('#FAFAFA')
    [System.Windows.Controls.Canvas]::SetLeft($bg, $ml)
    [System.Windows.Controls.Canvas]::SetTop($bg, $mt)
    [void]$cCanvas.Children.Add($bg)

    # Horizontal gridlines at 25%, 50%, 75%
    foreach ($pct in @(25, 50, 75)) {
        $y = $mt + $ch * (1 - $pct / 100)
        & $addLine $ml $y ($ml + $cw) $y '#E0E0E0' 1 @(4, 4)
    }

    # Threshold lines (amber 75%, red 90%)
    $amberPct = 75; $redPct = 90
    $yAmber = $mt + $ch * (1 - $amberPct / 100)
    & $addLine $ml $yAmber ($ml + $cw) $yAmber '#FFB74D' 1 @(6, 3)
    & $addText "${amberPct}%" ($ml + $cw + 3) ($yAmber - 7) 9 '#FFB74D' $null
    $yRed = $mt + $ch * (1 - $redPct / 100)
    & $addLine $ml $yRed ($ml + $cw) $yRed '#E57373' 1 @(6, 3)
    & $addText "${redPct}%" ($ml + $cw + 3) ($yRed - 7) 9 '#E57373' $null

    # Y-axis labels
    foreach ($pct in @(0, 25, 50, 75, 100)) {
        $y = $mt + $ch * (1 - $pct / 100) - 7
        & $addText "$pct%" ($ml - 5) $y 10 '#666' 'Right'
    }

    # Axes
    & $addLine $ml $mt $ml ($mt + $ch) '#999' 1 $null
    & $addLine $ml ($mt + $ch) ($ml + $cw) ($mt + $ch) '#999' 1 $null

    # Time range from mock data
    $minTime = $mockCpu[0].Time
    $maxTime = $mockCpu[-1].Time
    $span = ($maxTime - $minTime).TotalSeconds
    if ($span -le 0) { $span = 1 }

    # X-axis time labels
    $labelCount = [Math]::Min(6, [Math]::Max(2, [int]($cw / 100)))
    for ($i = 0; $i -le $labelCount; $i++) {
        $frac = $i / $labelCount
        $t    = $minTime.AddSeconds($frac * $span)
        $x    = $ml + $frac * $cw
        $label = $t.ToLocalTime().ToString('HH:mm')
        & $addText $label ($x - 15) ($mt + $ch + 5) 10 '#666' $null
        if ($i -gt 0 -and $i -lt $labelCount) {
            & $addLine $x $mt $x ($mt + $ch) '#F0F0F0' 1 $null
        }
    }

    # Helper: build a Polyline
    $buildPolyline = {
        param($data, $color)
        if ($data.Count -lt 2) { return }
        $pl = New-Object System.Windows.Shapes.Polyline
        $pl.Stroke = $brushConv.ConvertFromString($color)
        $pl.StrokeThickness = 2
        $pl.StrokeLineJoin  = [System.Windows.Media.PenLineJoin]::Round
        $points = New-Object System.Windows.Media.PointCollection
        foreach ($pt in $data) {
            $xFrac = ($pt.Time - $minTime).TotalSeconds / $span
            $px    = $ml + $xFrac * $cw
            $py    = $mt + $ch * (1 - [Math]::Max(0, [Math]::Min(100, $pt.Value)) / 100)
            [void]$points.Add([System.Windows.Point]::new($px, $py))
        }
        $pl.Points = $points
        [void]$cCanvas.Children.Add($pl)
    }

    & $buildPolyline $mockCpu '#1976D2'   # CPU - blue
    & $buildPolyline $mockMem '#FB8C00'   # Mem - orange
}

# Force final render pass then capture
$perfWin.UpdateLayout()
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
    [System.Windows.Threading.DispatcherPriority]::Render, [Action]{ })
Start-Sleep -Milliseconds 200

$width  = [int]$perfWin.ActualWidth
$height = [int]$perfWin.ActualHeight
if ($width -le 0 -or $height -le 0) { $width = [int]$perfWin.Width; $height = [int]$perfWin.Height }
$source = [System.Windows.PresentationSource]::FromVisual($perfWin)
$dpiX = 96.0; $dpiY = 96.0
if ($source -and $source.CompositionTarget) {
    $dpiX = 96.0 * $source.CompositionTarget.TransformToDevice.M11
    $dpiY = 96.0 * $source.CompositionTarget.TransformToDevice.M22
}
$rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
    [int]($width * $dpiX / 96), [int]($height * $dpiY / 96),
    $dpiX, $dpiY, [System.Windows.Media.PixelFormats]::Pbgra32)
$rtb.Render($perfWin)
$encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
$perfOutPath = Join-Path $outDir 'performance-history.png'
$fs = [System.IO.File]::Create($perfOutPath)
$encoder.Save($fs)
$fs.Close()
$perfWin.Close()
Write-Host "  Saved: $perfOutPath"

# =============================================================================
# 8. Session Detail window
# =============================================================================
Write-Host "  [10/13] Session Detail window..."
$sdXaml = (Get-XamlFromScript -Path (Join-Path $scriptRoot 'scripts\session-detail.ps1') -VariableName '$sessionXaml').Replace('<!-- THEME_SLOT -->', '')
$sdWin  = New-WpfWindow -Xaml $sdXaml
Apply-LightTheme $sdWin
$sdWin.Width  = 1920
$sdWin.Height = 520

# Populate header and status bar
$sdWin.FindName("SessionTitle").Text    = "HP-GEN-UKS-001"
$sdWin.FindName("SessionSubtitle").Text = "uksouth - 37 session(s)"
$sdWin.FindName("SessionStatus").Text   = "37 session(s) (34 active, 3 disconnected)"
$sdWin.FindName("SessionCountdown").Text = "Next refresh in 24s"

# Mock session data with perf/connection quality columns
$sessionData = @(
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-001'; 'User'='john.smith'; 'ID'=1; 'Session Host'='AVDSH-UKS-001'; 'State'='Active'; 'Session Type'='Desktop'; 'Logon Time'=(Get-Date).AddHours(-3).ToString('yyyy-MM-dd HH:mm'); 'Connect Time'='4s'; 'Session Age'='3h 12m'; 'Avg RTT'='18ms'; 'P95 RTT'='32ms'; 'Avg BW'='2.4 Mbps'; 'P95 BW'='5.1 Mbps'; 'Transport'='Multipath_Direct_UDP'; 'Client IP'='192.168.1.45'; 'Client Type'='Windows App'; 'Client OS'='Windows 11'; 'Client Version'='1.2.5620'; 'Client Private Link'='No'; 'Host Private Link'='No'; 'Gateway Region'='UK South'; '_AvgRTTColor'='Green'; '_P95RTTColor'='Green' }
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-001'; 'User'='jane.doe'; 'ID'=2; 'Session Host'='AVDSH-UKS-001'; 'State'='Active'; 'Session Type'='Desktop'; 'Logon Time'=(Get-Date).AddHours(-5).ToString('yyyy-MM-dd HH:mm'); 'Connect Time'='6s'; 'Session Age'='5h 04m'; 'Avg RTT'='45ms'; 'P95 RTT'='88ms'; 'Avg BW'='1.8 Mbps'; 'P95 BW'='3.6 Mbps'; 'Transport'='Multipath_Relayed_UDP'; 'Client IP'='10.20.30.55'; 'Client Type'='Web Browser'; 'Client OS'='macOS'; 'Client Version'='-'; 'Client Private Link'='No'; 'Host Private Link'='No'; 'Gateway Region'='UK South'; '_AvgRTTColor'='Green'; '_P95RTTColor'='Green' }
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-001'; 'User'='bob.jones'; 'ID'=1; 'Session Host'='AVDSH-UKS-002'; 'State'='Active'; 'Session Type'='Desktop'; 'Logon Time'=(Get-Date).AddHours(-1).ToString('yyyy-MM-dd HH:mm'); 'Connect Time'='3s'; 'Session Age'='1h 18m'; 'Avg RTT'='12ms'; 'P95 RTT'='21ms'; 'Avg BW'='3.1 Mbps'; 'P95 BW'='6.8 Mbps'; 'Transport'='Multipath_Direct_UDP'; 'Client IP'='172.16.5.12'; 'Client Type'='Windows App'; 'Client OS'='Windows 11'; 'Client Version'='1.2.5620'; 'Client Private Link'='Yes'; 'Host Private Link'='Yes'; 'Gateway Region'='UK South'; '_AvgRTTColor'='Green'; '_P95RTTColor'='Green' }
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-001'; 'User'='alice.williams'; 'ID'=2; 'Session Host'='AVDSH-UKS-002'; 'State'='Active'; 'Session Type'='RemoteApp'; 'Logon Time'=(Get-Date).AddHours(-2).ToString('yyyy-MM-dd HH:mm'); 'Connect Time'='5s'; 'Session Age'='2h 41m'; 'Avg RTT'='105ms'; 'P95 RTT'='180ms'; 'Avg BW'='0.9 Mbps'; 'P95 BW'='2.1 Mbps'; 'Transport'='Multipath_Relayed_UDP'; 'Client IP'='192.168.10.8'; 'Client Type'='macOS App'; 'Client OS'='macOS'; 'Client Version'='10.9.8'; 'Client Private Link'='No'; 'Host Private Link'='No'; 'Gateway Region'='West Europe'; '_AvgRTTColor'='Amber'; '_P95RTTColor'='Amber' }
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-001'; 'User'='charlie.brown'; 'ID'=1; 'Session Host'='AVDSH-UKS-003'; 'State'='Active'; 'Session Type'='Desktop'; 'Logon Time'=(Get-Date).AddHours(-6).ToString('yyyy-MM-dd HH:mm'); 'Connect Time'='12s'; 'Session Age'='6h 33m'; 'Avg RTT'='210ms'; 'P95 RTT'='340ms'; 'Avg BW'='0.5 Mbps'; 'P95 BW'='1.2 Mbps'; 'Transport'='-'; 'Client IP'='10.0.0.102'; 'Client Type'='Web Browser'; 'Client OS'='Windows 10'; 'Client Version'='-'; 'Client Private Link'='No'; 'Host Private Link'='No'; 'Gateway Region'='East US'; '_AvgRTTColor'='Red'; '_P95RTTColor'='Red' }
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-001'; 'User'='david.martin'; 'ID'=2; 'Session Host'='AVDSH-UKS-003'; 'State'='Disconnected'; 'Session Type'='Desktop'; 'Logon Time'=(Get-Date).AddHours(-8).ToString('yyyy-MM-dd HH:mm'); 'Connect Time'='7s'; 'Session Age'='8h 17m'; 'Avg RTT'='55ms'; 'P95 RTT'='120ms'; 'Avg BW'='1.5 Mbps'; 'P95 BW'='3.2 Mbps'; 'Transport'='Multipath_Direct_UDP'; 'Client IP'='192.168.1.99'; 'Client Type'='Windows App'; 'Client OS'='Windows 11'; 'Client Version'='1.2.5620'; 'Client Private Link'='No'; 'Host Private Link'='Yes'; 'Gateway Region'='UK South'; '_AvgRTTColor'='Green'; '_P95RTTColor'='Amber' }
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-001'; 'User'='emma.wilson'; 'ID'=3; 'Session Host'='AVDSH-UKS-001'; 'State'='Active'; 'Session Type'='Desktop'; 'Logon Time'=(Get-Date).AddMinutes(-45).ToString('yyyy-MM-dd HH:mm'); 'Connect Time'='3s'; 'Session Age'='0h 45m'; 'Avg RTT'='9ms'; 'P95 RTT'='15ms'; 'Avg BW'='4.2 Mbps'; 'P95 BW'='8.5 Mbps'; 'Transport'='Multipath_Direct_UDP'; 'Client IP'='10.50.2.31'; 'Client Type'='Windows App'; 'Client OS'='Windows 11'; 'Client Version'='1.2.5620'; 'Client Private Link'='Yes'; 'Host Private Link'='Yes'; 'Gateway Region'='UK South'; '_AvgRTTColor'='Green'; '_P95RTTColor'='Green' }
    [PSCustomObject]@{ 'Host Pool'='HP-GEN-UKS-001'; 'User'='frank.taylor'; 'ID'=3; 'Session Host'='AVDSH-UKS-002'; 'State'='Disconnected'; 'Session Type'='Desktop'; 'Logon Time'=(Get-Date).AddHours(-4).ToString('yyyy-MM-dd HH:mm'); 'Connect Time'='5s'; 'Session Age'='4h 02m'; 'Avg RTT'='38ms'; 'P95 RTT'='72ms'; 'Avg BW'='2.0 Mbps'; 'P95 BW'='4.3 Mbps'; 'Transport'='Multipath_Relayed_UDP'; 'Client IP'='172.16.1.77'; 'Client Type'='Remote Desktop (MSRDCW)'; 'Client OS'='Windows 10'; 'Client Version'='1.2.5105'; 'Client Private Link'='No'; 'Host Private Link'='No'; 'Gateway Region'='UK South'; '_AvgRTTColor'='Green'; '_P95RTTColor'='Green' }
)
$sdGrid = $sdWin.FindName("SessionGrid")
Set-GridData -Grid $sdGrid `
    -Columns @('Host Pool','User','ID','Session Host','State','Session Type','Logon Time','Connect Time','Session Age','Avg RTT','P95 RTT','Avg BW','P95 BW','Transport','Client IP','Client Type','Client OS','Client Version','Client Private Link','Host Private Link','Gateway Region','_AvgRTTColor','_P95RTTColor') `
    -Data $sessionData
# Hide helper color columns
foreach ($col in $sdGrid.Columns) {
    if ($col.Header -in @('_AvgRTTColor', '_P95RTTColor')) {
        $col.Visibility = [System.Windows.Visibility]::Collapsed
    }
}
# Apply heat map styles for RTT columns
Set-HeatMapStyle -Grid $sdGrid -ColumnName 'Avg RTT' -ColorProperty '_AvgRTTColor'
Set-HeatMapStyle -Grid $sdGrid -ColumnName 'P95 RTT' -ColorProperty '_P95RTTColor'
Save-WindowScreenshot -Window $sdWin -OutputPath (Join-Path $outDir 'session-detail.png') -Show:$ShowWindows

# =============================================================================
# 9. Run Command picker
# =============================================================================
Write-Host "  [11/13] Run Command picker..."

# Build programmatically to match the real picker layout
$rcWin = New-Object System.Windows.Window
$rcWin.Title     = "Run Command - AVDSH-UKS-005"
$rcWin.Width     = 720
$rcWin.Height    = 570
$rcWin.MinHeight = 400
$rcWin.MinWidth  = 500
$rcWin.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
$rcWin.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#F4F6F9')

$rcOuter = New-Object System.Windows.Controls.DockPanel

# Button bar (bottom)
$rcBtnBar = New-Object System.Windows.Controls.DockPanel
$rcBtnBar.Margin = '12,8,12,12'
[System.Windows.Controls.DockPanel]::SetDock($rcBtnBar, 'Bottom')

$rcBtnReload = New-Object System.Windows.Controls.Button
$rcBtnReload.Content = 'Reload Commands'; $rcBtnReload.Width = 120; $rcBtnReload.Height = 28
$rcBtnReload.IsEnabled = $false
[System.Windows.Controls.DockPanel]::SetDock($rcBtnReload, 'Left')

$rcBtnPanel = New-Object System.Windows.Controls.StackPanel
$rcBtnPanel.Orientation = 'Horizontal'; $rcBtnPanel.HorizontalAlignment = 'Right'
[System.Windows.Controls.DockPanel]::SetDock($rcBtnPanel, 'Right')

$rcBtnClose = New-Object System.Windows.Controls.Button
$rcBtnClose.Content = 'Close'; $rcBtnClose.Width = 80; $rcBtnClose.Height = 28; $rcBtnClose.Margin = '0,0,8,0'
$rcBtnRun = New-Object System.Windows.Controls.Button
$rcBtnRun.Content = 'Run Command'; $rcBtnRun.Width = 110; $rcBtnRun.Height = 28
$rcBtnRun.IsEnabled = $false
$rcBtnRun.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#0078D4')
$rcBtnRun.Foreground = [System.Windows.Media.Brushes]::White

[void]$rcBtnPanel.Children.Add($rcBtnClose)
[void]$rcBtnPanel.Children.Add($rcBtnRun)
[void]$rcBtnBar.Children.Add($rcBtnReload)
[void]$rcBtnBar.Children.Add($rcBtnPanel)

# Content area
$rcContent = New-Object System.Windows.Controls.DockPanel
$rcContent.Margin = '12,12,12,0'
$rcContent.LastChildFill = $true

# Header
$rcHeader = New-Object System.Windows.Controls.TextBlock
$rcHeader.Text = 'Select a command to run on:  AVDSH-UKS-005'
$rcHeader.FontWeight = 'Bold'; $rcHeader.Margin = '0,0,0,8'
[System.Windows.Controls.DockPanel]::SetDock($rcHeader, 'Top')

# Command label
$rcCmdLabel = New-Object System.Windows.Controls.TextBlock
$rcCmdLabel.Text = 'Command:'; $rcCmdLabel.Margin = '0,0,0,4'
[System.Windows.Controls.DockPanel]::SetDock($rcCmdLabel, 'Top')

# ListBox
$rcList = New-Object System.Windows.Controls.ListBox
$rcList.Height = 110; $rcList.BorderBrush = [System.Windows.Media.Brushes]::LightGray
$commandNames = @('Top Processes by CPU/RAM','Top User Processes by CPU/RAM','Restart AVD Agent','Run GPUpdate','Check Disk Space','Check FSLogix Status','Get Logged-On Users','Check TCP Port Usage')
foreach ($name in $commandNames) { [void]$rcList.Items.Add($name) }
$rcList.SelectedIndex = 7  # Check TCP Port Usage
[System.Windows.Controls.DockPanel]::SetDock($rcList, 'Top')

# Description label
$rcDescLabel = New-Object System.Windows.Controls.TextBlock
$rcDescLabel.Text = 'Description:'; $rcDescLabel.Margin = '0,8,0,4'
[System.Windows.Controls.DockPanel]::SetDock($rcDescLabel, 'Top')

# Description box
$rcDescBox = New-Object System.Windows.Controls.TextBox
$rcDescBox.Height = 46; $rcDescBox.IsReadOnly = $true; $rcDescBox.TextWrapping = 'Wrap'
$rcDescBox.Background = [System.Windows.Media.Brushes]::WhiteSmoke
$rcDescBox.BorderBrush = [System.Windows.Media.Brushes]::LightGray
$rcDescBox.Text = 'Per-process TCP connection breakdown with port exhaustion risk assessment.'
[System.Windows.Controls.DockPanel]::SetDock($rcDescBox, 'Top')

# Status text (completed)
$rcStatus = New-Object System.Windows.Controls.TextBlock
$rcStatus.Text = "Completed 'Check TCP Port Usage' on AVDSH-UKS-005."
$rcStatus.FontWeight = 'SemiBold'; $rcStatus.Foreground = [System.Windows.Media.Brushes]::DarkGreen
$rcStatus.Margin = '0,10,0,4'; $rcStatus.TextWrapping = 'Wrap'
[System.Windows.Controls.DockPanel]::SetDock($rcStatus, 'Top')

# Output label
$rcOutLabel = New-Object System.Windows.Controls.TextBlock
$rcOutLabel.Text = 'Output:'; $rcOutLabel.Margin = '0,0,0,4'
[System.Windows.Controls.DockPanel]::SetDock($rcOutLabel, 'Top')

# Output box (fills remaining space)
$rcOutput = New-Object System.Windows.Controls.TextBox
$rcOutput.IsReadOnly = $true; $rcOutput.MinHeight = 100
$rcOutput.TextWrapping = 'NoWrap'
$rcOutput.VerticalScrollBarVisibility = 'Auto'
$rcOutput.HorizontalScrollBarVisibility = 'Auto'
$rcOutput.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
$rcOutput.FontSize = 11; $rcOutput.Background = [System.Windows.Media.Brushes]::WhiteSmoke
$rcOutput.BorderBrush = [System.Windows.Media.Brushes]::LightGray; $rcOutput.Padding = '6'
$rcOutput.Text = @"
=== Per-Process TCP Connections (top 15) ===

Process           Total Estab TimeWait CloseWait
-------           ----- ----- -------- ---------
chrome               42    38        0         4
svchost              26    20        6         0
System               19    12        7         0
Microsoft.AAD...      8     0        0         8
msedge                7     7        0         0
WaAppAgent            4     4        0         0
RDAgentBootL...       3     3        0         0
lsass                 2     0        0         0
MsMpEng               1     1        0         0

=== Connection State Summary ===

State        Count
-----        -----
ESTABLISHED     85
CLOSE_WAIT      12
TIME_WAIT       13
LISTENING       47

=== Ephemeral Port Usage ===
Dynamic range : 49152 - 65535 (16384 ports)
Ports in use  : 110 / 16384 (0.7%)
OK: Port usage is healthy
"@

# Assemble content
foreach ($ctrl in @($rcHeader, $rcCmdLabel, $rcList, $rcDescLabel, $rcDescBox, $rcStatus, $rcOutLabel)) {
    [void]$rcContent.Children.Add($ctrl)
}
[void]$rcContent.Children.Add($rcOutput)

[void]$rcOuter.Children.Add($rcBtnBar)
[void]$rcOuter.Children.Add($rcContent)
$rcWin.Content = $rcOuter

Save-WindowScreenshot -Window $rcWin -OutputPath (Join-Path $outDir 'run-command.png') -Show:$ShowWindows

# =============================================================================
# 10. Send Message dialog
# =============================================================================
Write-Host "  [12/13] Send Message dialog..."
$smXaml = (Get-XamlFromScript -Path (Join-Path $scriptRoot 'scripts\session-detail.ps1') -VariableName '$msgXaml').Replace('<!-- THEME_SLOT -->', '')
$smWin  = New-WpfWindow -Xaml $smXaml
Apply-LightTheme $smWin

$smWin.FindName("RecipientLabel").Text = "To: john.smith (AVDSH-UKS-001)"
$smWin.FindName("TitleBox").Text       = "IT Notice"
$smWin.FindName("BodyBox").Text        = "Please save your work. This session host will be restarted for maintenance in 15 minutes."

Save-WindowScreenshot -Window $smWin -OutputPath (Join-Path $outDir 'send-message.png') -Show:$ShowWindows

# =============================================================================
# 11. Session History tab
# =============================================================================
Write-Host "  [13/13] Session History tab..."
$wSI = New-WpfWindow -Xaml $dashFull
Initialize-DashboardWindow $wSI -Width 1600

# Populate Unique Users tiles
$siUsers24h = $wSI.FindName("SI_Users24h")
$siUsers7d  = $wSI.FindName("SI_Users7d")
$siUsers30d = $wSI.FindName("SI_Users30d")
if ($siUsers24h) { $siUsers24h.Text = "28" }
if ($siUsers7d)  { $siUsers7d.Text  = "51" }
if ($siUsers30d) { $siUsers30d.Text = "64" }

# Populate countdown
$siCountdown = $wSI.FindName("SI_Countdown")
if ($siCountdown) { $siCountdown.Text = "Next refresh in 45s" }

# Populate the grid with mock session history data
$siGrid = $wSI.FindName("SI_Grid")
if ($siGrid) {
    $siMockData = @(
        [PSCustomObject]@{ 'User'='john.smith';    'Host Pool'='HP-GEN-UKS-001'; 'Session Host'='AVDSH-UKS-001'; 'Lock State'='Unlocked'; 'Last Lock'='2026-03-16 09:15:22'; 'Last Unlock'='2026-03-16 09:18:45'; 'Last Logon'='2026-03-16 08:30:11'; 'Last Logoff'='-'; 'Last Disconnect'='-'; 'Disconnect Type'='-'; 'Last Reconnect'='-' }
        [PSCustomObject]@{ 'User'='jane.doe';      'Host Pool'='HP-GEN-UKS-001'; 'Session Host'='AVDSH-UKS-002'; 'Lock State'='Locked';   'Last Lock'='2026-03-16 10:42:18'; 'Last Unlock'='2026-03-16 09:30:05'; 'Last Logon'='2026-03-16 08:15:33'; 'Last Logoff'='-'; 'Last Disconnect'='-'; 'Disconnect Type'='-'; 'Last Reconnect'='-' }
        [PSCustomObject]@{ 'User'='bob.wilson';    'Host Pool'='HP-GEN-UKS-001'; 'Session Host'='AVDSH-UKS-003'; 'Lock State'='-';        'Last Lock'='-'; 'Last Unlock'='-'; 'Last Logon'='2026-03-16 09:45:02'; 'Last Logoff'='2026-03-16 17:30:15'; 'Last Disconnect'='2026-03-16 17:30:15'; 'Disconnect Type'='Logoff'; 'Last Reconnect'='-' }
        [PSCustomObject]@{ 'User'='alice.brown';   'Host Pool'='HP-GEN-UKS-002'; 'Session Host'='AVDSH-UKS-005'; 'Lock State'='-';        'Last Lock'='-'; 'Last Unlock'='-'; 'Last Logon'='2026-03-16 07:55:18'; 'Last Logoff'='-'; 'Last Disconnect'='2026-03-16 12:10:42'; 'Disconnect Type'='Idle Timeout'; 'Last Reconnect'='2026-03-16 13:05:11' }
        [PSCustomObject]@{ 'User'='charlie.green'; 'Host Pool'='HP-GEN-FRC-001'; 'Session Host'='AVDSH-FRC-001'; 'Lock State'='Unlocked'; 'Last Lock'='2026-03-16 11:20:33'; 'Last Unlock'='2026-03-16 11:25:10'; 'Last Logon'='2026-03-16 08:00:45'; 'Last Logoff'='-'; 'Last Disconnect'='-'; 'Disconnect Type'='-'; 'Last Reconnect'='-' }
        [PSCustomObject]@{ 'User'='david.taylor';  'Host Pool'='HP-GEN-UKS-002'; 'Session Host'='AVDSH-UKS-005'; 'Lock State'='-';        'Last Lock'='-'; 'Last Unlock'='-'; 'Last Logon'='2026-03-16 09:10:55'; 'Last Logoff'='2026-03-16 16:45:30'; 'Last Disconnect'='2026-03-16 16:45:30'; 'Disconnect Type'='User Initiated'; 'Last Reconnect'='-' }
        [PSCustomObject]@{ 'User'='emma.harris';   'Host Pool'='HP-GEN-UKS-001'; 'Session Host'='AVDSH-UKS-002'; 'Lock State'='Locked';   'Last Lock'='2026-03-16 14:30:22'; 'Last Unlock'='2026-03-16 13:15:08'; 'Last Logon'='2026-03-16 08:45:19'; 'Last Logoff'='-'; 'Last Disconnect'='-'; 'Disconnect Type'='-'; 'Last Reconnect'='-' }
        [PSCustomObject]@{ 'User'='frank.moore';   'Host Pool'='HP-GEN-FRC-001'; 'Session Host'='AVDSH-FRC-001'; 'Lock State'='-';        'Last Lock'='-'; 'Last Unlock'='-'; 'Last Logon'='2026-03-16 10:20:40'; 'Last Logoff'='-'; 'Last Disconnect'='2026-03-16 15:55:12'; 'Disconnect Type'='Session Replaced'; 'Last Reconnect'='-' }
    )
    Set-GridData -Grid $siGrid `
        -Columns @('User','Host Pool','Session Host','Lock State','Last Lock','Last Unlock','Last Logon','Last Logoff','Last Disconnect','Disconnect Type','Last Reconnect') `
        -Data $siMockData
}

# Hide the status overlay since we have data
$siStatus = $wSI.FindName("SI_Status")
if ($siStatus) { $siStatus.Visibility = [System.Windows.Visibility]::Collapsed }

# Update footer
$footerSI = $wSI.FindName("SIFooterText")
if ($footerSI) { $footerSI.Text = "Session History: 8 row(s)  |  Updated: $(Get-Date -Format 'HH:mm:ss')" }

Select-Tab $wSI 'Session History'
Save-WindowScreenshot -Window $wSI -OutputPath (Join-Path $outDir 'session-history.png') -Show:$ShowWindows

# =============================================================================
# 12. Log Viewer
# =============================================================================
Write-Host "  [13/13] Log Viewer..."
# Cannot use Get-XamlFromScript here because log-viewer.ps1 uses a double-quoted
# here-string with $_ variable interpolation (for the icon path) which produces
# a literal $ in the extracted XAML and causes XamlReader to throw.
# Instead we load a clean standalone XAML with no variable references.
$lvXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Log Viewer" Height="680" Width="1056"
        Background="#F4F6F9" FontFamily="Segoe UI"
        UseLayoutRounding="True">
    <Window.Resources>
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
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
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
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
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
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
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
        <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#1F2937"/>
        </Style>
        <Style TargetType="DataGridRow">
            <Setter Property="Height" Value="32"/>
        </Style>
    </Window.Resources>
    <DockPanel>
        <Border DockPanel.Dock="Bottom" Background="#0078D4" Height="32">
            <Grid Margin="14,0">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="StatusText" Text="Ready" Foreground="White" FontSize="12" VerticalAlignment="Center"/>
                <Button x:Name="RefreshBtn" Grid.Column="1" Content="Refresh Now"
                        Background="#005A9E" Foreground="White" BorderThickness="0"
                        Padding="14,5" FontSize="12" FontWeight="SemiBold" Cursor="Hand" VerticalAlignment="Center">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>
        </Border>
        <Border DockPanel.Dock="Top" Background="White" Padding="16,12">
            <Border.Effect>
                <DropShadowEffect BlurRadius="6" ShadowDepth="1" Opacity="0.10" Color="#000000"/>
            </Border.Effect>
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
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
                <StackPanel Grid.Row="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="Time Range:" FontSize="12" Foreground="#6B7280" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <ComboBox x:Name="TimeRangeCombo" Width="160" FontSize="12" SelectedIndex="1">
                        <ComboBoxItem Content="Last 15 Minutes" Tag="15"/>
                        <ComboBoxItem Content="Last Hour"       Tag="60"/>
                        <ComboBoxItem Content="Last 24 Hours"   Tag="1440"/>
                        <ComboBoxItem Content="All Files"       Tag="0"/>
                    </ComboBox>
                    <TextBlock Text="Filter:" FontSize="12" Foreground="#555" VerticalAlignment="Center" Margin="16,0,8,0"/>
                    <TextBox x:Name="FileFilterBox" Width="160" FontSize="12" Padding="8,4"
                             VerticalContentAlignment="Center" BorderBrush="#C8CDD3" BorderThickness="1"
                             Background="White" Foreground="#333"/>
                    <Button x:Name="DeleteOldBtn" Content="Delete Logs &gt; 7 Days"
                            Style="{StaticResource DangerBtn}" Margin="20,0,0,0"/>
                    <CheckBox x:Name="ErrorsOnlyCheck" Content="Errors Only"
                              FontSize="12" Foreground="#1F2937" VerticalAlignment="Center" Margin="16,0,0,0"/>
                    <CheckBox x:Name="AutoRefreshCheck" Content="Auto Refresh"
                              FontSize="12" Foreground="#1F2937" VerticalAlignment="Center" Margin="16,0,0,0"/>
                </StackPanel>
            </Grid>
        </Border>
        <Grid Margin="12,12,12,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="400" MinWidth="250"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*" MinWidth="300"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="White" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="6">
                <Border.Effect>
                    <DropShadowEffect BlurRadius="8" ShadowDepth="1" Opacity="0.08" Color="#000000"/>
                </Border.Effect>
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Text="Log Files" FontSize="13" FontWeight="SemiBold"
                               Foreground="#1F2937" Margin="12,10,12,8"/>
                    <DataGrid x:Name="FileGrid" AutoGenerateColumns="False" IsReadOnly="True"
                              CanUserSortColumns="True" SelectionMode="Single"
                              HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                              HorizontalGridLinesBrush="#E8EAED" BorderThickness="0"
                              Background="White" RowBackground="White" AlternatingRowBackground="#F7F9FC"
                              FontSize="12" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="File Name" Binding="{Binding Name}" Width="220"/>
                            <DataGridTextColumn Header="Modified" Binding="{Binding Modified}" Width="130"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding Size}" Width="60"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </Border>
            <GridSplitter Grid.Column="1" Width="6" Background="Transparent"
                          HorizontalAlignment="Center" VerticalAlignment="Stretch"
                          ResizeBehavior="PreviousAndNext" Cursor="SizeWE"/>
            <Border Grid.Column="2" Background="#1E2A38" BorderBrush="#DDE1E7" BorderThickness="1" CornerRadius="6">
                <Border.Effect>
                    <DropShadowEffect BlurRadius="8" ShadowDepth="1" Opacity="0.08" Color="#000000"/>
                </Border.Effect>
                <DockPanel>
                    <Border DockPanel.Dock="Top" Background="#263545" Padding="12,8" CornerRadius="6,6,0,0">
                        <TextBlock x:Name="LogTitle" Text="Select a file to view" FontSize="12"
                                   FontWeight="SemiBold" Foreground="#A8C4DE"/>
                    </Border>
                    <RichTextBox x:Name="LogViewer" Background="#1E2A38" Foreground="#A8C4DE"
                                 FontFamily="Consolas" FontSize="11" IsReadOnly="True"
                                 BorderThickness="0" VerticalScrollBarVisibility="Auto"
                                 HorizontalScrollBarVisibility="Auto" Padding="10,6">
                        <RichTextBox.Document>
                            <FlowDocument PageWidth="5000"/>
                        </RichTextBox.Document>
                    </RichTextBox>
                </DockPanel>
            </Border>
        </Grid>
    </DockPanel>
</Window>
'@
$lvWin = [Windows.Markup.XamlReader]::Parse($lvXaml)
$lvWin.Width  = 1100
$lvWin.Height = 600

# Populate path box
$lvPathBox = $lvWin.FindName("PathBox")
if ($lvPathBox) { $lvPathBox.Text = "\\fileserver01.contoso.com\profiles\logs" }

# Populate file grid with mock log files.
# The FileGrid has AutoGenerateColumns="False" with explicit column bindings,
# so we set ItemsSource directly — do NOT use Set-GridData which would add
# duplicate columns on top of the existing ones and cause layout problems.
$lvFileGrid = $lvWin.FindName("FileGrid")
if ($lvFileGrid) {
    $lvMockFiles = [System.Collections.ObjectModel.ObservableCollection[PSCustomObject]]::new()
    $lvMockFiles.Add([PSCustomObject]@{ Name='AVDSH-UKS-001_FSLogixApps_20260316.log';        Modified='2026-03-16 14:22'; Size='128 KB' })
    $lvMockFiles.Add([PSCustomObject]@{ Name='AVDSH-UKS-002_FSLogixApps_20260316.log';        Modified='2026-03-16 14:18'; Size='96 KB'  })
    $lvMockFiles.Add([PSCustomObject]@{ Name='AVDSH-UKS-003_AudioDeviceSettings_20260316.log';Modified='2026-03-16 13:45'; Size='12 KB'  })
    $lvMockFiles.Add([PSCustomObject]@{ Name='AVDSH-UKS-001_RegisterAudioTask_20260316.log';  Modified='2026-03-16 12:30'; Size='8 KB'   })
    $lvMockFiles.Add([PSCustomObject]@{ Name='AVDSH-FRC-001_FSLogixApps_20260316.log';        Modified='2026-03-16 11:55'; Size='204 KB' })
    $lvMockFiles.Add([PSCustomObject]@{ Name='AVDSH-UKS-005_AudioRegistryPerms_20260316.log'; Modified='2026-03-16 11:20'; Size='4 KB'   })
    $lvMockFiles.Add([PSCustomObject]@{ Name='AVDSH-UKS-002_FSLogixApps_20260315.log';        Modified='2026-03-15 17:45'; Size='312 KB' })
    $lvMockFiles.Add([PSCustomObject]@{ Name='AVDSH-FRC-001_AudioDeviceSettings_20260315.log';Modified='2026-03-15 16:30'; Size='18 KB'  })
    $lvFileGrid.ItemsSource = $lvMockFiles
}

# Populate log viewer with mock content showing a selected file with some error lines
$lvLogViewer = $lvWin.FindName("LogViewer")
if ($lvLogViewer) {
    $mockLogLines = @(
        '[14:22:01] [INFO ] FSLogix Apps - Starting profile attach for user CONTOSO\john.smith'
        '[14:22:01] [INFO ] Profile path: \\fileserver01\profiles\john.smith_S-1-5-21-123456789'
        '[14:22:02] [INFO ] VHD(x) found: john.smith_S-1-5-21-123456789.vhdx (4.2 GB)'
        '[14:22:02] [INFO ] Mounting profile VHD - drive letter: Z:'
        '[14:22:03] [INFO ] Profile mounted successfully in 1.2s'
        '[14:22:03] [INFO ] Redirecting AppData to profile container'
        '[14:22:04] [INFO ] FSLogix frxsvc - Service version 2.9.8884.27471'
        '[14:22:05] [ERROR] Failed to redirect folder: Access denied on \\fileserver01\profiles\temp'
        '[14:22:05] [INFO ] Retrying folder redirect (attempt 2 of 3)'
        '[14:22:06] [INFO ] Folder redirect succeeded on retry'
        '[14:22:07] [INFO ] Profile attach complete - elapsed: 5.8s'
        '[14:22:07] [INFO ] Session ready for user CONTOSO\john.smith'
    )
    $doc = $lvLogViewer.Document
    $doc.Blocks.Clear()
    $para = New-Object System.Windows.Documents.Paragraph
    $para.Margin = New-Object System.Windows.Thickness(0)
    foreach ($line in $mockLogLines) {
        $run = New-Object System.Windows.Documents.Run($line + "`n")
        if ($line -match '\[ERROR\]|\[FATAL\]|\[CRITICAL\]') {
            $run.Foreground = [System.Windows.Media.Brushes]::Tomato
        }
        $para.Inlines.Add($run)
    }
    $doc.Blocks.Add($para)
}

# Set status text
$lvStatus = $lvWin.FindName("StatusText")
if ($lvStatus) { $lvStatus.Text = "8 file(s) found  |  1 error(s)" }

# Set log title to show a selected file
$lvLogTitle = $lvWin.FindName("LogTitle")
if ($lvLogTitle) { $lvLogTitle.Text = "AVDSH-UKS-001_FSLogixApps_20260316.log  (128 KB  |  1 error)" }

Save-WindowScreenshot -Window $lvWin -OutputPath (Join-Path $outDir 'log-viewer.png') -Show:$ShowWindows

# =============================================================================
# Done
# =============================================================================
# =============================================================================
# 13. Audit Viewer
# =============================================================================
Write-Host "  [13/13] Audit Viewer..."
# Inline clean XAML — audit-viewer.ps1 uses a double-quoted here-string with
# $_icoAttr interpolation, same issue as log-viewer. Use a standalone XAML.
$avXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AVD Dashboard - Audit Viewer"
        Height="700" Width="1100"
        Background="#F4F6F9" FontFamily="Segoe UI" UseLayoutRounding="True">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Audit Log Viewer" FontSize="18" FontWeight="Bold"
                   Foreground="#0078D4" Margin="0,0,0,10"/>
        <Border Grid.Row="1" Background="#FFFFFF" CornerRadius="6" Padding="10"
                BorderBrush="#DDE1E7" BorderThickness="1" Margin="0,0,0,10">
            <WrapPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="Date From:" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <DatePicker x:Name="DateFrom" Width="130" Margin="0,0,12,0"/>
                <TextBlock Text="Date To:" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <DatePicker x:Name="DateTo" Width="130" Margin="0,0,12,0"/>
                <TextBlock Text="Action:" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <ComboBox x:Name="ActionFilter" Width="140" Margin="0,0,12,0">
                    <ComboBoxItem Content="All Actions" IsSelected="True"/>
                    <ComboBoxItem Content="DrainEnable"/>
                    <ComboBoxItem Content="DrainDisable"/>
                    <ComboBoxItem Content="VMStart"/>
                    <ComboBoxItem Content="VMDeallocate"/>
                    <ComboBoxItem Content="RunCommand"/>
                    <ComboBoxItem Content="Logoff"/>
                </ComboBox>
                <TextBlock Text="Search:" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <TextBox x:Name="SearchBox" Width="180" Margin="0,0,12,0"
                         VerticalContentAlignment="Center" Padding="4,2"/>
                <Button x:Name="RefreshBtn" Content="Refresh" Width="75" Height="28"
                        Background="#0078D4" Foreground="White" BorderThickness="0" Cursor="Hand" Margin="0,0,6,0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="ExportBtn" Content="Export CSV" Width="85" Height="28"
                        Background="#107C10" Foreground="White" BorderThickness="0" Cursor="Hand">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </WrapPanel>
        </Border>
        <DataGrid Grid.Row="2" x:Name="AuditGrid"
                  AutoGenerateColumns="False" IsReadOnly="True"
                  CanUserSortColumns="True" SelectionMode="Extended" SelectionUnit="FullRow"
                  HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                  HorizontalGridLinesBrush="#E8E8E8" AlternatingRowBackground="#F8F9FB"
                  BorderBrush="#DDE1E7" BorderThickness="1" FontSize="12.5">
            <DataGrid.ColumnHeaderStyle>
                <Style TargetType="DataGridColumnHeader">
                    <Setter Property="Background" Value="#0078D4"/>
                    <Setter Property="Foreground" Value="White"/>
                    <Setter Property="FontWeight" Value="SemiBold"/>
                    <Setter Property="Padding" Value="8,5"/>
                    <Setter Property="BorderBrush" Value="#005A9E"/>
                    <Setter Property="BorderThickness" Value="0,0,1,0"/>
                </Style>
            </DataGrid.ColumnHeaderStyle>
            <DataGrid.Columns>
                <DataGridTextColumn Header="Timestamp" Binding="{Binding Timestamp}" Width="150"/>
                <DataGridTextColumn Header="User"      Binding="{Binding User}"      Width="160"/>
                <DataGridTextColumn Header="Action"    Binding="{Binding Action}"    Width="110"/>
                <DataGridTextColumn Header="Target"    Binding="{Binding Target}"    Width="180"/>
                <DataGridTextColumn Header="Details"   Binding="{Binding Details}"   Width="300"/>
                <DataGridTextColumn Header="Result"    Binding="{Binding Result}"    Width="80"/>
            </DataGrid.Columns>
        </DataGrid>
        <Border Grid.Row="3" Background="#0078D4" CornerRadius="0,0,6,6" Padding="10,6" Margin="0,6,0,0">
            <Grid>
                <TextBlock x:Name="StatusText" Text="Loaded 42 entries from 7 file(s)" Foreground="White"
                           FontSize="12" HorizontalAlignment="Left" VerticalAlignment="Center"/>
                <TextBlock x:Name="CountText" Text="42 of 42 entries" Foreground="White"
                           FontSize="12" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@
$avWin = [Windows.Markup.XamlReader]::Parse($avXaml)

# Set date pickers
$avDateFrom = $avWin.FindName("DateFrom")
$avDateTo   = $avWin.FindName("DateTo")
if ($avDateFrom) { $avDateFrom.SelectedDate = (Get-Date).AddDays(-7) }
if ($avDateTo)   { $avDateTo.SelectedDate   = (Get-Date) }

# Populate grid with realistic mock audit entries
$avGrid = $avWin.FindName("AuditGrid")
if ($avGrid) {
    $avMock = [System.Collections.ObjectModel.ObservableCollection[PSCustomObject]]::new()
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-02 09:41:15'; User='awebber@contoso.com';   Action='DrainEnable';   Target='AVDSH-UKS-005'; Details='Drain enabled via dashboard'; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-02 09:41:15'; User='awebber@contoso.com';   Action='TagSet';        Target='AVDSH-UKS-005'; Details="Tag 'ExcludeFromScaling' set"; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-02 09:15:03'; User='awebber@contoso.com';   Action='RunCommand';    Target='AVDSH-UKS-003'; Details='GPUpdate /force'; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-02 08:52:44'; User='jsmith@contoso.com';    Action='Logoff';        Target='AVDSH-UKS-001'; Details='Session 3 - user jbristow'; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-02 08:30:11'; User='awebber@contoso.com';   Action='VMRestart';     Target='AVDSH-UKS-006'; Details='Restart initiated from Session Hosts tab'; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-01 17:45:22'; User='awebber@contoso.com';   Action='VMDeallocate';  Target='AVDSH-UKS-004'; Details='Deallocate initiated from Session Hosts tab'; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-01 16:10:05'; User='jsmith@contoso.com';    Action='SendMessage';   Target='AVDSH-UKS-002'; Details='Msg: System maintenance in 15 mins - please save work'; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-01 15:33:50'; User='awebber@contoso.com';   Action='DrainDisable';  Target='AVDSH-UKS-005'; Details='Drain disabled via dashboard'; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-01 15:33:50'; User='awebber@contoso.com';   Action='TagRemove';     Target='AVDSH-UKS-005'; Details="Tag 'ExcludeFromScaling' removed"; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-01 14:22:18'; User='awebber@contoso.com';   Action='RunCommand';    Target='AVDSH-FRC-001'; Details='Restart AVD Agent'; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-01 11:05:44'; User='jsmith@contoso.com';    Action='VMStart';       Target='AVDSH-UKS-004'; Details='Start initiated from Session Hosts tab'; Result='Success' })
    $avMock.Add([PSCustomObject]@{ Timestamp='2026-04-01 09:18:30'; User='awebber@contoso.com';   Action='ProfileDelete'; Target='jbristow_S-1-5-21-1234'; Details='Profile deleted from saproduks01\fslogix'; Result='Success' })
    $avGrid.ItemsSource = $avMock
}

Save-WindowScreenshot -Window $avWin -OutputPath (Join-Path $outDir 'audit-viewer.png') -Show:$ShowWindows

Write-Host "`nAll screenshots saved to: $outDir" -ForegroundColor Green
Write-Host "Files:"
Get-ChildItem $outDir -Filter '*.png' | ForEach-Object { Write-Host "  $($_.Name)" }
