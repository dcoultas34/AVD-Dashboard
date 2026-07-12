# =============================================================================
# tab-sessioninfo.ps1  -  Session History tab module
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Encapsulates the "Session History" tab in the main dashboard. Queries
# Log Analytics Workspace (LAW) for lock/unlock events (Security 4800/4801)
# and session lifecycle events (TerminalServices 21/23/24/25) across ALL
# users over the last 24 hours. No dependency on the session detail
# DataTable - this is the dashboard-level view of session history data.
# The session detail "Session History" button continues to provide
# user-filtered data independently.
#
# FEATURES
# --------
# - Auto-queries LAW on first tab selection (deferred to avoid slowing
#   initial dashboard load), then auto-refreshes on the global timer.
# - Unique Users tiles (24h / 7d) show counts and are clickable to open
#   a detail popup listing each user, their last logon, and session count.
# - Unique Users popup supports enrichment from:
#     - On-premises AD  (batched LDAP filter, chunks of 50 users)
#     - Entra ID / Microsoft Graph (batched compound 'or' filters in
#       3 passes: onPremisesSamAccountName, mailNickname, UPN startswith;
#       chunks of 15 users per batch to stay within URL limits)
#   Both enrichment buttons are re-clickable to refresh data.
# - AD Group Export button: prompts for an AD group name, recursively
#   enumerates members via Get-ADGroupMember, batch-fetches user details
#   using LDAP filter (chunks of 50), and exports to CSV.
# - Entra Group Export button: prompts for an Entra ID group name, uses
#   Get-MgGroup + Get-MgGroupMember to enumerate members, batch-fetches
#   user details via compound 'id eq' filters (chunks of 15), and
#   exports to CSV. Requires Microsoft.Graph.Groups and .Users modules.
# - Export CSV on both the main tab grid and the unique users popup.
# - Right-click context menu on the main grid reuses _AdvShowHistory and
#   _AdvShowSessionHistory from session-history.ps1 for drill-downs.
# - Filter box filters the main grid by User or Session Host.
#
# DEPENDENCIES (optional, for specific features)
# -----------------------------------------------
# - ActiveDirectory module (RSAT): AD enrichment + AD Group Export
# - Microsoft.Graph.Users module:  Entra ID enrichment
# - Microsoft.Graph.Groups module: Entra Group Export
# Both enrichment paths fall back gracefully if modules are not installed.
# The Entra enrichment also has a REST API fallback using Get-ArmToken
# (MSAL, scoped to https://graph.microsoft.com), though this may return
# 401 if the Azure PowerShell app registration lacks User.Read.All
# consent in the tenant.
#
# INTEGRATION
# -----------
# Dot-source this file BEFORE the XAML string is built; the main script
# then injects $SessionInfoTab_Xaml into its XAML via a placeholder comment
# (<!-- TAB:SESSION_INFO -->) and calls the public lifecycle functions:
#
#   Initialize-SessionInfoTab   - once, after $window is loaded
#   Invoke-SessionInfoTabTimer  - every second from masterTimer
#
# LOGGING
# -------
# All operations log to $script:LogFile (if set) using the standard
# dashboard pattern: [HH:mm:ss] [SessionInfo|UniqueUsers] message
# =============================================================================

# PSScriptAnalyzer flags $SessionInfoTab_Xaml as "assigned but never used"
# because it cannot see across the dot-source boundary into the calling script.
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'SessionInfoTab_Xaml',
    Justification = 'Exported to the calling script via dot-source')]
param()

# =============================================================================
# 1. XAML fragment
# =============================================================================

$SessionInfoTab_Xaml = @'
<TabItem x:Name="SessionInfoTab" Header="Session History"
         xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
         xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <DockPanel>
        <!-- ═══ Top bar: tiles, filter, status, countdown and buttons ═══ -->
        <Border DockPanel.Dock="Top" Background="{DynamicResource Avd.NearWhite.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,0,0,1"
                Padding="12,7" Height="41">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>   <!-- 0: "Filter:" label -->
                    <ColumnDefinition Width="140"/>    <!-- 1: filter text box -->
                    <ColumnDefinition Width="Auto"/>   <!-- 2: Unique Users 24h tile -->
                    <ColumnDefinition Width="Auto"/>   <!-- 3: Unique Users 7d tile -->
                    <ColumnDefinition Width="Auto"/>   <!-- 4: Unique Users 30d tile -->
                    <ColumnDefinition Width="Auto"/>   <!-- 5: AD Group Export -->
                    <ColumnDefinition Width="Auto"/>   <!-- 6: Entra ID Group Export -->
                    <ColumnDefinition Width="*"/>      <!-- 7: spacer / status -->
                    <ColumnDefinition Width="Auto"/>   <!-- 8: countdown -->
                    <ColumnDefinition Width="Auto"/>   <!-- 9: Refresh -->
                    <ColumnDefinition Width="Auto"/>   <!-- 10: Export CSV -->
                </Grid.ColumnDefinitions>
                <!-- Filter box first (matches Session Hosts layout) -->
                <TextBlock Grid.Column="0" Text="Filter:" VerticalAlignment="Center"
                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Secondary}" Margin="0,0,8,0"/>
                <TextBox x:Name="SI_FilterBox" Grid.Column="1"
                         FontSize="12" Padding="8,4"
                         VerticalContentAlignment="Center" VerticalAlignment="Center"
                         BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"
                         Background="{DynamicResource Avd.Input.Bg}" Foreground="{DynamicResource Avd.Fg.Label}"/>
                <!-- Unique User tiles (clickable) -->
                <Border x:Name="SI_Tile24h" Grid.Column="2" Background="{DynamicResource Avd.Card.Bg}" CornerRadius="4" Padding="8,3"
                        BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1" Margin="8,0,8,0"
                        VerticalAlignment="Center" Height="26" Cursor="Hand">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock x:Name="SI_Users24h" Text="-"
                                   FontSize="14" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"
                                   VerticalAlignment="Center"/>
                        <TextBlock Text=" Unique Users (24h)"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   VerticalAlignment="Center" Margin="4,0,0,0"/>
                    </StackPanel>
                </Border>
                <Border x:Name="SI_Tile7d" Grid.Column="3" Background="{DynamicResource Avd.Card.Bg}" CornerRadius="4" Padding="8,3"
                        BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1" Margin="0,0,8,0"
                        VerticalAlignment="Center" Height="26" Cursor="Hand">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock x:Name="SI_Users7d" Text="-"
                                   FontSize="14" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"
                                   VerticalAlignment="Center"/>
                        <TextBlock Text=" Unique Users (7d)"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   VerticalAlignment="Center" Margin="4,0,0,0"/>
                    </StackPanel>
                </Border>
                <Border x:Name="SI_Tile30d" Grid.Column="4" Background="{DynamicResource Avd.Card.Bg}" CornerRadius="4" Padding="8,3"
                        BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1" Margin="0,0,16,0"
                        VerticalAlignment="Center" Height="26" Cursor="Hand">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock x:Name="SI_Users30d" Text="-"
                                   FontSize="14" FontWeight="Bold" Foreground="{DynamicResource Avd.Fg.Accent}"
                                   VerticalAlignment="Center"/>
                        <TextBlock Text=" Unique Users (30d)"
                                   FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                                   VerticalAlignment="Center" Margin="4,0,0,0"/>
                    </StackPanel>
                </Border>
                <Button x:Name="SI_ADGroupExport" Grid.Column="5"
                        Content="AD Group Export" Background="#5B7A3A" Foreground="White"
                        BorderThickness="0" Padding="10,5" FontSize="11"
                        FontWeight="SemiBold" Cursor="Hand" VerticalAlignment="Center"
                        Margin="10,0,4,0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdADG" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdADG" Property="Background" Value="#4A6630"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="SI_EntraGroupExport" Grid.Column="6"
                        Content="Entra ID Group Export" Background="#6B4C9A" Foreground="White"
                        BorderThickness="0" Padding="10,5" FontSize="11"
                        FontWeight="SemiBold" Cursor="Hand" VerticalAlignment="Center"
                        Margin="0,0,4,0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdEGE" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdEGE" Property="Background" Value="#5A3D87"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <TextBlock Grid.Column="7" Text="Showing: last 24 hours"
                           VerticalAlignment="Center" HorizontalAlignment="Left"
                           FontSize="11" Foreground="{DynamicResource Avd.Fg.Hint}"
                           FontStyle="Italic" Margin="12,0,0,0"/>
                <TextBlock x:Name="SI_Countdown" Grid.Column="8"
                           VerticalAlignment="Center"
                           FontSize="12" Foreground="{DynamicResource Avd.Fg.Muted}"
                           Margin="0,0,12,0"/>
                <!-- SI_RefreshButton: triggers an immediate out-of-schedule refresh -->
                <Button x:Name="SI_RefreshButton" Grid.Column="9"
                        Content="Refresh"
                        Background="{DynamicResource Avd.Btn.Accent.Bg}" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="12,5" Margin="0,0,6,0"
                        VerticalAlignment="Center">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="BdRef" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="BdRef" Property="Background" Value="{DynamicResource Avd.Btn.Accent.Hover}"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdRef" Property="Background" Value="{DynamicResource Avd.Btn.Accent.Press}"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <!-- SI_ExportCsvButton: exports the current grid contents to CSV -->
                <Button x:Name="SI_ExportCsvButton" Grid.Column="10"
                        Content="Export CSV"
                        Background="{DynamicResource Avd.Btn.Std.Bg}" Foreground="White"
                        BorderThickness="0" FontSize="12"
                        FontWeight="SemiBold" Cursor="Hand"
                        Padding="14,5"
                        IsEnabled="False"
                        VerticalAlignment="Center">
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
                                    <Setter TargetName="BdEx" Property="Background" Value="{DynamicResource Avd.Btn.Std.Hover}"/>
                                </Trigger>
                                <Trigger Property="IsPressed" Value="True">
                                    <Setter TargetName="BdEx" Property="Background" Value="{DynamicResource Avd.Btn.Std.Press}"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </Grid>
        </Border>
        <!-- DataGrid with status overlay -->
        <Grid>
        <DataGrid x:Name="SI_Grid" AutoGenerateColumns="True" IsReadOnly="True"
                  CanUserSortColumns="True" CanUserReorderColumns="False"
                  HeadersVisibility="Column" GridLinesVisibility="None"
                  AlternatingRowBackground="{DynamicResource Avd.AltRow.Bg}" RowBackground="{DynamicResource Avd.Card.Bg}"
                  BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1"
                  ColumnHeaderHeight="32" RowHeight="28" FontSize="12"
                  SelectionMode="Single" SelectionUnit="FullRow"
                  RowHeaderWidth="0"
                  UseLayoutRounding="True"
                  HorizontalScrollBarVisibility="Auto"
                  VerticalScrollBarVisibility="Auto">
            <DataGrid.ColumnHeaderStyle>
                <Style TargetType="DataGridColumnHeader">
                    <Setter Property="Background"                 Value="{DynamicResource Avd.ColHeader.Bg}"/>
                    <Setter Property="Foreground"                 Value="White"/>
                    <Setter Property="FontWeight"                 Value="SemiBold"/>
                    <Setter Property="FontSize"                   Value="12"/>
                    <Setter Property="Padding"                    Value="8,0"/>
                    <Setter Property="HorizontalContentAlignment" Value="Center"/>
                    <Setter Property="BorderBrush"                Value="{DynamicResource Avd.ColHeader.Border}"/>
                    <Setter Property="BorderThickness"            Value="0,0,1,0"/>
                </Style>
            </DataGrid.ColumnHeaderStyle>
            <DataGrid.CellStyle>
                <Style TargetType="DataGridCell">
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="DataGridCell">
                                <Border Background="{TemplateBinding Background}"
                                        BorderBrush="{TemplateBinding BorderBrush}"
                                        BorderThickness="{TemplateBinding BorderThickness}">
                                    <ContentPresenter HorizontalAlignment="Center"
                                                      VerticalAlignment="Center"/>
                                </Border>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Style>
            </DataGrid.CellStyle>
        </DataGrid>
        <!-- Status overlay - shown in the white grid area when no data -->
        <TextBlock x:Name="SI_Status" Text="Waiting for first query..."
                   HorizontalAlignment="Center" VerticalAlignment="Top"
                   Margin="0,50,0,0" FontSize="14" Foreground="{DynamicResource Avd.Fg.Hint}"
                   IsHitTestVisible="False"/>
        </Grid>
    </DockPanel>
</TabItem>
'@

# =============================================================================
# 2. Data refresh - queries LAW for all users' lock/session history
# =============================================================================

function script:_SIRefreshData {
    $script:StatusText.Text = "Session History: Querying Log Analytics..."

    # Force render so the user sees the status update before the blocking REST call
    try {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [System.Threading.ThreadStart]{ $frame.Continue = $false }
        )
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } catch {}

    try {
        $lawId = $script:LawWorkspaceResourceId

        if (-not $lawId) {
            $script:_siStatus.Text = "Log Analytics WorkspaceResourceId is not configured."
            $script:_siStatus.Visibility = 'Visible'
            $script:StatusText.Text = "Session History: Log Analytics not configured"
            return
        }

        Write-Log "[SessionInfo] Querying ALL users"

        # Combined KQL: Lock/Unlock + Session Lifecycle for ALL users (no user filter)
        # ── Lock State intelligence (applied after the fullouter join at the end of the KQL) ──
        # The raw LockState from lockData is based purely on which event (4800=lock vs
        # 4801=unlock) happened most recently. This is misleading in several scenarios:
        #   1. User logged off/disconnected after the lock - session is gone, lock state
        #      is stale and should show "-".
        #   2. User logged off then logged back on - the lock from the OLD session should
        #      not carry over to the new session. E.g. lock at 17:42, logoff at 18:00,
        #      new logon at 20:40 - the lock is from a previous session and irrelevant.
        # Three checks clear stale lock states after the join:
        #   Check 1: No lock data at all -> "-"
        #   Check 2: Session not active (last logoff/disconnect after last logon/reconnect) -> "-"
        #   Check 3: Lock event predates the current session start (from a previous session) -> "-"
        $kql = @"
let lockData = Event
| where TimeGenerated > ago(24h)
| where EventLog == "Security" and EventID in (4800, 4801)
| parse EventData with * '<Data Name="TargetUserName">' TargetUser '</Data>' *
| where TargetUser != "" and TargetUser !endswith "`$"

| extend SessionHost = tolower(split(Computer, '.')[0])
| summarize
    LastLock   = maxif(TimeGenerated, EventID == 4800),
    LastUnlock = maxif(TimeGenerated, EventID == 4801)
    by TargetUser, SessionHost
| extend LockState = case(
    isempty(LastLock) and isempty(LastUnlock), "-",
    LastLock > LastUnlock or isempty(LastUnlock), "Locked",
    "Unlocked")
| project User=TargetUser, SessionHost, LastLock, LastUnlock, LockState;
let ev = Event
| where TimeGenerated > ago(24h)
| where EventLog == "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"
      and EventID in (21, 23, 24, 25)
| parse EventData with * '<User>' SessionUser '</User>' *
| parse EventData with * '<SessionID>' SessId '</SessionID>' *
| where SessionUser != ""
| extend SessionUser = iff(SessionUser contains "\\",
           tostring(split(SessionUser, "\\")[1]), SessionUser)
| where SessionUser !endswith "`$"

| extend SessionHost = tolower(split(Computer, '.')[0]);
let reasons = Event
| where TimeGenerated > ago(24h)
| where EventLog == "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"
      and EventID == 40
| parse RenderedDescription with "Session " SessId40 " has been disconnected, reason code " ReasonCode
| extend SessionHost = tolower(split(Computer, '.')[0]);
let lastDiscReason = ev
| where EventID == 24
| join kind=leftouter reasons on SessionHost, `$left.SessId == `$right.SessId40
| where isnull(TimeGenerated1) or abs(datetime_diff('second', TimeGenerated, TimeGenerated1)) < 10
| summarize arg_max(TimeGenerated, ReasonCode) by SessionUser, SessionHost;
let sessionData = ev
| summarize
    LastLogon      = maxif(TimeGenerated, EventID == 21),
    LastLogoff     = maxif(TimeGenerated, EventID == 23),
    LastDisconnect = maxif(TimeGenerated, EventID == 24),
    LastReconnect  = maxif(TimeGenerated, EventID == 25)
    by SessionUser, SessionHost
| join kind=leftouter lastDiscReason on SessionUser, SessionHost
| project User=SessionUser, SessionHost, LastLogon, LastLogoff, LastDisconnect, LastReconnect, DisconnectReason=coalesce(ReasonCode, "");
lockData
| join kind=fullouter sessionData on User, SessionHost
| extend User=coalesce(User, User1), SessionHost=coalesce(SessionHost, SessionHost1)
| extend LastSessionStart = max_of(
    iff(isnotempty(LastLogon), LastLogon, datetime(null)),
    iff(isnotempty(LastReconnect), LastReconnect, datetime(null)))
| extend LastSessionEnd = max_of(
    iff(isnotempty(LastLogoff), LastLogoff, datetime(null)),
    iff(isnotempty(LastDisconnect), LastDisconnect, datetime(null)))
| extend SessionActive = isnotempty(LastSessionStart) and
    (isempty(LastSessionEnd) or LastSessionStart > LastSessionEnd)
| extend LastLockEvent = max_of(
    iff(isnotempty(LastLock), LastLock, datetime(null)),
    iff(isnotempty(LastUnlock), LastUnlock, datetime(null)))
| extend LockState = case(
    LockState == "-" or isempty(LockState), "-",
    not(SessionActive), "-",
    isnotempty(LastSessionStart) and isnotempty(LastLockEvent) and LastLockEvent < LastSessionStart, "-",
    LockState)
| project User, SessionHost,
          LastLock, LastUnlock, LockState, LastLogon, LastLogoff, LastDisconnect, LastReconnect, DisconnectReason
| order by tolower(User) asc, tolower(SessionHost) asc
"@

        $sw = $null; if ($script:LogFile) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }

        $resp = Invoke-LawQuery -Kql $kql -Timespan 'PT24H' `
            -WorkspaceResourceId $lawId -QueryBaseUrl $script:LawQueryBaseUrl
        if ($sw) { $sw.Stop() }

        # Unique User Stats Query (24h and 7d)
        try {
            $statsKql = @'
let ev = Event
| where EventLog == "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"
| where EventID == 21
| parse EventData with * '<User>' u '</User>' *
| where isnotempty(u) and u !endswith "$"
| extend ShortUser = tolower(iff(u contains "\\", tostring(split(u, "\\")[1]), u));
let u24h = ev | where TimeGenerated > ago(24h) | summarize dcount(ShortUser);
let u7d  = ev | where TimeGenerated > ago(7d)  | summarize dcount(ShortUser);
let u30d = ev | where TimeGenerated > ago(30d) | summarize dcount(ShortUser);
union (u24h | extend Period="24h"), (u7d | extend Period="7d"), (u30d | extend Period="30d")
| project Period, Count=dcount_ShortUser
'@
            $statsResp = Invoke-LawQuery -Kql $statsKql -Timespan 'P30D' `
                -WorkspaceResourceId $lawId -QueryBaseUrl $script:LawQueryBaseUrl

            if ($statsResp.tables -and $statsResp.tables[0].rows) {
                foreach ($r in $statsResp.tables[0].rows) {
                    if ($r[0] -eq '24h' -and $script:_siUsers24h)  { $script:_siUsers24h.Text  = [string]$r[1] }
                    if ($r[0] -eq '7d'  -and $script:_siUsers7d)   { $script:_siUsers7d.Text   = [string]$r[1] }
                    if ($r[0] -eq '30d' -and $script:_siUsers30d)  { $script:_siUsers30d.Text  = [string]$r[1] }
                }
            }
        } catch {}

        $rowCount = if ($resp.tables -and $resp.tables[0].rows) { $resp.tables[0].rows.Count } else { 0 }
        Write-Log "[SessionInfo] Query: $rowCount row(s) ($($sw.ElapsedMilliseconds)ms)"

        if ($rowCount -gt 0) {
            # Use the shared shToPoolMap (lowercase VM name → Host Pool) maintained by
            # tab-sessionhosts.ps1. It is rebuilt every time Session Hosts refreshes,
            # so it is always current and available even before the Session Hosts tab
            # has been opened (the background runspace populates it automatically).
            if (-not $script:shToPoolMap -or $script:shToPoolMap.Count -eq 0) {
                Write-Log "[SessionInfo] shToPoolMap empty - running lightweight host pool refresh"
                Invoke-ShToPoolMapRefresh
            }
            $shToPool = if ($script:shToPoolMap) { $script:shToPoolMap } else { @{} }

            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add("User")
            [void]$dt.Columns.Add("Host Pool")
            [void]$dt.Columns.Add("Session Host")
            [void]$dt.Columns.Add("Lock State")
            [void]$dt.Columns.Add("Last Lock")
            [void]$dt.Columns.Add("Last Unlock")
            [void]$dt.Columns.Add("Last Logon")
            [void]$dt.Columns.Add("Last Logoff")
            [void]$dt.Columns.Add("Last Disconnect")
            [void]$dt.Columns.Add("Disconnect Type")
            [void]$dt.Columns.Add("Last Reconnect")

            $findCol = {
                param($resp, $name)
                $c = @($resp.tables[0].columns | ForEach-Object {
                    $n = [string]$_.name; if (-not $n) { $n = [string]$_.ColumnName }; if (-not $n) { $n = [string]$_ }; $n.ToLower()
                })
                [array]::IndexOf($c, $name.ToLower())
            }

            $fmtTime = {
                param($row, $timeIdx)
                $ts = if ($timeIdx -ge 0 -and $row[$timeIdx]) { [string]$row[$timeIdx] } else { '' }
                if ($ts -and $ts -ne '') {
                    try { return ([DateTime]::Parse($ts)).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") } catch { return $ts }
                }
                return '-'
            }

            $reasonMap = @{
                '0'  = 'Normal'
                '1'  = 'User Initiated'
                '2'  = 'Admin Initiated'
                '5'  = 'Session Replaced'
                '11' = 'Idle Timeout'
                '12' = 'Logoff'
                '28' = 'Session Ended (28)'
            }
            $mapReason = {
                param($code)
                $c = [string]$code
                if (-not $c -or $c -eq '') { return '-' }
                if ($reasonMap.ContainsKey($c)) { return $reasonMap[$c] }
                return "Unknown ($c)"
            }

            $iUser    = & $findCol $resp 'user'
            $iHost    = & $findCol $resp 'sessionhost'
            $iLock    = & $findCol $resp 'lastlock'
            $iUnlck   = & $findCol $resp 'lastunlock'
            $iLS      = & $findCol $resp 'lockstate'
            $iLogon   = & $findCol $resp 'lastlogon'
            $iLogoff  = & $findCol $resp 'lastlogoff'
            $iDisc    = & $findCol $resp 'lastdisconnect'
            $iRecon   = & $findCol $resp 'lastreconnect'
            $iDReason = & $findCol $resp 'disconnectreason'

            foreach ($r in $resp.tables[0].rows) {
                $user_ = if ($iUser -ge 0) { [string]$r[$iUser] } else { '' }
                $host_ = if ($iHost -ge 0) { [string]$r[$iHost] } else { '' }
                $lockState = if ($iLS -ge 0 -and $r[$iLS]) { [string]$r[$iLS] } else { '-' }
                $reasonCode = if ($iDReason -ge 0 -and $r[$iDReason]) { [string]$r[$iDReason] } else { '' }
                $discType = & $mapReason $reasonCode

                $dr = $dt.NewRow()
                $dr["User"]            = $user_
                $dr["Host Pool"]       = if ($host_ -and $shToPool.ContainsKey($host_.ToLower())) { $shToPool[$host_.ToLower()] } else { '-' }
                $dr["Session Host"]    = $host_
                $dr["Lock State"]      = $lockState
                $dr["Last Lock"]       = (& $fmtTime $r $iLock)
                $dr["Last Unlock"]     = (& $fmtTime $r $iUnlck)
                $dr["Last Logon"]      = (& $fmtTime $r $iLogon)
                $dr["Last Logoff"]     = (& $fmtTime $r $iLogoff)
                $dr["Last Disconnect"] = (& $fmtTime $r $iDisc)
                $dr["Disconnect Type"] = $discType
                $dr["Last Reconnect"]  = (& $fmtTime $r $iRecon)
                [void]$dt.Rows.Add($dr)
            }

            # Preserve sort/filter state across refreshes
            $savedSort = @()
            if ($script:_siGrid.Items -and $script:_siGrid.Items.SortDescriptions.Count -gt 0) {
                foreach ($sd in $script:_siGrid.Items.SortDescriptions) {
                    $savedSort += [System.ComponentModel.SortDescription]::new($sd.PropertyName, $sd.Direction)
                }
            }

            $script:_siGrid.ItemsSource = $dt.DefaultView

            if ($savedSort.Count -gt 0) {
                $script:_siGrid.Items.SortDescriptions.Clear()
                foreach ($sd in $savedSort) { $script:_siGrid.Items.SortDescriptions.Add($sd) }
                foreach ($col in $script:_siGrid.Columns) {
                    $match = $savedSort | Where-Object { $_.PropertyName -eq $col.SortMemberPath }
                    if ($match) { $col.SortDirection = $match.Direction } else { $col.SortDirection = $null }
                }
            }

            # Restore text filter
            $filterText = if ($script:_siFilterBox) { $script:_siFilterBox.Text.Trim() } else { '' }
            if ($filterText -ne '') {
                $escaped = $filterText.Replace("'", "''").Replace("*", "[*]").Replace("%", "[%]")
                $script:_siGrid.ItemsSource.RowFilter = "User LIKE '%$escaped%' OR [Session Host] LIKE '%$escaped%' OR [Host Pool] LIKE '%$escaped%'"
            }

            $now = Get-Date -Format 'HH:mm:ss'
            $script:_siStatus.Visibility = 'Collapsed'
            $script:StatusText.Text = "Session History: $($dt.Rows.Count) row(s)  |  Updated: $now"
            $script:_siExportCsv.IsEnabled = $true
        } else {
            $script:_siStatus.Visibility = 'Collapsed'
            $script:StatusText.Text = "Session History: No events found"
            $script:_siExportCsv.IsEnabled = $false
        }
    } catch {
        $script:StatusText.Text = "Session History: Error - $_"
        Write-Log "[SessionInfo] ERROR: $_"
    }

    # No auto-refresh cycle - user must click Refresh manually
    $script:_siCountdown.Text = ''
}

# =============================================================================
# 2b. _SIShowUniqueUsers  -  Unique Users detail popup
#
# Opens a modal popup listing unique users for the given period (24h/7d).
# Queries LAW for EventID 21 (logon) events, strips domain prefix, and
# shows User, First Name, Last Name, Department, Last Logon, Sessions.
#
# The First Name / Last Name / Department columns are initially blank.
# Two enrichment buttons populate them using batched queries:
#   - "Enrich from AD": batched LDAP filter query (chunks of 50 users).
#     Builds "(|(samAccountName=u1)(samAccountName=u2)...)" and resolves
#     all matches in a single LDAP round-trip per batch, then applies
#     results via hashtable lookup. Much faster than N individual calls.
#   - "Enrich from Entra ID": 3-pass batched lookup (chunks of 15 users).
#     Pass 1: onPremisesSamAccountName compound 'or' filter (AD-synced).
#     Pass 2: mailNickname compound 'or' filter (for unmatched users).
#     Pass 3: startswith(UPN) individual fallback (can't batch startswith).
#     Uses Microsoft.Graph module (Get-MgUser) if installed, otherwise
#     falls back to REST API with Get-ArmToken (MSAL, Graph-scoped).
#
# Both buttons are re-clickable (re-enabled after completion).
# Export CSV button exports the current grid state (with/without enrichment).
# Status messages appear in a footer bar at the bottom of the popup.
# All operations log to $script:LogFile under the [UniqueUsers] tag.
# =============================================================================

function _SIShowUniqueUsers {
    param([string]$Period)  # '24h' or '7d'

    $lawId = $script:LawWorkspaceResourceId
    if (-not $lawId) { return }

    $periodLabel = switch ($Period) { '24h' { 'Last 24 Hours' }; '7d' { 'Last 7 Days' }; '30d' { 'Last 30 Days' }; default { $Period } }

    $kql = @"
Event
| where EventLog == "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"
| where EventID == 21
| where TimeGenerated > ago($Period)
| parse EventData with * '<User>' u '</User>' *
| where isnotempty(u) and u !endswith "$"
| extend ShortUser = tolower(iff(u contains "\\", tostring(split(u, "\\")[1]), u))
| extend SessionHost = tolower(split(Computer, '.')[0])
| summarize LastLogon=max(TimeGenerated), SessionCount=count(), SessionHosts=make_set(SessionHost) by ShortUser
| order by LastLogon desc
| project User=ShortUser, LastLogon=format_datetime(LastLogon, 'yyyy-MM-dd HH:mm'), Sessions=SessionCount, SessionHosts
"@

    # Build popup window with Enrich buttons and Export CSV
    $popXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Unique Users - $periodLabel" Width="900" Height="560"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        Background="{DynamicResource Avd.Window.Bg}" Foreground="{DynamicResource Avd.Window.Fg}"
        FontFamily="Segoe UI">
    <Window.Resources><!-- THEME_SLOT --></Window.Resources>
    <DockPanel>
        <!-- Button bar -->
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" HorizontalAlignment="Right"
                    Margin="16,10,16,8">
            <Button x:Name="UU_EnrichAD" Content="Enrich from AD" IsEnabled="False"
                    Background="#005A9E" Foreground="White" BorderThickness="0"
                    Padding="12,5" FontSize="11" FontWeight="SemiBold" Cursor="Hand"
                    VerticalAlignment="Center" Margin="0,0,6,0">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd1" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd1" Property="Background" Value="#888"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd1" Property="Background" Value="#004F8C"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button x:Name="UU_EnrichEntra" Content="Enrich from Entra ID" IsEnabled="False"
                    Background="#005A9E" Foreground="White" BorderThickness="0"
                    Padding="12,5" FontSize="11" FontWeight="SemiBold" Cursor="Hand"
                    VerticalAlignment="Center" Margin="0,0,6,0">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd2" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd2" Property="Background" Value="#888"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd2" Property="Background" Value="#004F8C"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button x:Name="UU_ExportCsv" Content="Export CSV" IsEnabled="False"
                    Background="#0078D4" Foreground="White" BorderThickness="0"
                    Padding="12,5" FontSize="11" FontWeight="SemiBold" Cursor="Hand"
                    VerticalAlignment="Center">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd3" Background="{TemplateBinding Background}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd3" Property="Background" Value="#888"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd3" Property="Background" Value="#005A9E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>
        <!-- Footer status bar -->
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Avd.Header.Bg}"
                BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="0,1,0,0" Padding="12,6">
            <TextBlock x:Name="UU_Title" Text="Loading..." FontSize="11"
                       Foreground="{DynamicResource Avd.Fg.Secondary}"/>
        </Border>
        <!-- DataGrid fills remaining space -->
        <DataGrid x:Name="UU_Grid" AutoGenerateColumns="False" IsReadOnly="True"
                  Margin="16,0,16,0"
                  ColumnWidth="Auto"
                  CanUserSortColumns="True" CanUserReorderColumns="False"
                  HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                  HorizontalGridLinesBrush="{DynamicResource Avd.Border.Grid}"
                  AlternatingRowBackground="{DynamicResource Avd.AltRow.Bg}"
                  RowBackground="{DynamicResource Avd.Grid.Bg}"
                  Background="{DynamicResource Avd.Grid.Bg}"
                  BorderBrush="{DynamicResource Avd.Border.Std}" BorderThickness="1"
                  ColumnHeaderHeight="30" MinRowHeight="26" FontSize="12"
                  SelectionMode="Single" SelectionUnit="FullRow"
                  HorizontalScrollBarVisibility="Auto"
                  VerticalScrollBarVisibility="Auto">
            <DataGrid.ColumnHeaderStyle>
                <Style TargetType="DataGridColumnHeader">
                    <Setter Property="Background"                 Value="{DynamicResource Avd.ColHeader.Bg}"/>
                    <Setter Property="Foreground"                 Value="{DynamicResource Avd.ColHeader.Fg}"/>
                    <Setter Property="FontWeight"                 Value="SemiBold"/>
                    <Setter Property="FontSize"                   Value="12"/>
                    <Setter Property="Padding"                    Value="8,0"/>
                    <Setter Property="HorizontalContentAlignment" Value="Center"/>
                    <Setter Property="BorderBrush"                Value="{DynamicResource Avd.ColHeader.Border}"/>
                    <Setter Property="BorderThickness"            Value="0,0,1,0"/>
                </Style>
            </DataGrid.ColumnHeaderStyle>
            <DataGrid.CellStyle>
                <Style TargetType="DataGridCell">
                    <Setter Property="Foreground" Value="{DynamicResource Avd.Window.Fg}"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="DataGridCell">
                                <Border Background="{TemplateBinding Background}"
                                        BorderBrush="{TemplateBinding BorderBrush}"
                                        BorderThickness="{TemplateBinding BorderThickness}">
                                    <ContentPresenter HorizontalAlignment="Center"
                                                      VerticalAlignment="Center"/>
                                </Border>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Style>
            </DataGrid.CellStyle>
        </DataGrid>
    </DockPanel>
</Window>
"@

    $popXaml = $popXaml -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\..\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    $popReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($popXaml))
    $popWin = [Windows.Markup.XamlReader]::Load($popReader)
    if ($script:DarkTheme) {
        $popWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($popWin)).Handle
            $v = 1
            [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    }
    # Use script-scope so click handlers can access these
    $script:_uuTitle       = $popWin.FindName('UU_Title')
    $script:_uuGrid        = $popWin.FindName('UU_Grid')

    # Build columns explicitly so order and widths are stable across enrichment rebinds.
    $uuGrid = $script:_uuGrid

    # Helper: plain text column
    $mkCol = {
        param($header, $binding, $width)
        $c = [System.Windows.Controls.DataGridTextColumn]::new()
        $c.Header  = $header
        $c.Binding = [System.Windows.Data.Binding]::new($binding)
        $c.Width   = [System.Windows.Controls.DataGridLength]::new($width)
        $c
    }

    # Col 0: User
    [void]$uuGrid.Columns.Add((& $mkCol 'User' 'User' 120))

    # Col 1: Host Pools - wrapping template column
    $factory = [System.Windows.FrameworkElementFactory]::new([System.Windows.Controls.TextBlock])
    $factory.SetValue([System.Windows.Controls.TextBlock]::TextWrappingProperty, [System.Windows.TextWrapping]::Wrap)
    $factory.SetValue([System.Windows.Controls.TextBlock]::TextAlignmentProperty, [System.Windows.TextAlignment]::Center)
    $factory.SetValue([System.Windows.Controls.TextBlock]::HorizontalAlignmentProperty, [System.Windows.HorizontalAlignment]::Stretch)
    $factory.SetValue([System.Windows.Controls.TextBlock]::MarginProperty, [System.Windows.Thickness]::new(6,4,6,4))
    $factory.SetBinding([System.Windows.Controls.TextBlock]::TextProperty, [System.Windows.Data.Binding]::new('Host Pools'))
    $tmpl = [System.Windows.DataTemplate]::new()
    $tmpl.VisualTree = $factory
    $hpCol = [System.Windows.Controls.DataGridTemplateColumn]::new()
    $hpCol.Header       = 'Host Pools'
    $hpCol.CellTemplate = $tmpl
    $hpCol.Width        = [System.Windows.Controls.DataGridLength]::new(160)
    [void]$uuGrid.Columns.Add($hpCol)

    # Remaining plain text columns
    [void]$uuGrid.Columns.Add((& $mkCol 'First Name'  'First Name'  90))
    [void]$uuGrid.Columns.Add((& $mkCol 'Last Name'   'Last Name'   90))
    [void]$uuGrid.Columns.Add((& $mkCol 'Department'  'Department'  180))
    [void]$uuGrid.Columns.Add((& $mkCol 'Last Logon'  'Last Logon'  140))
    [void]$uuGrid.Columns.Add((& $mkCol 'Sessions'    'Sessions'    70))
    $script:_uuEnrichAD    = $popWin.FindName('UU_EnrichAD')
    $script:_uuEnrichEntra = $popWin.FindName('UU_EnrichEntra')
    $script:_uuExportCsv   = $popWin.FindName('UU_ExportCsv')
    $script:_uuDataTable   = $null
    $script:_uuPeriodLabel = $periodLabel
    $script:_uuPeriod      = $Period

    if ($script:_siWindow) { $popWin.Owner = $script:_siWindow }
    if ($popWin.Owner -and $popWin.Owner.Icon) { $popWin.Icon = $popWin.Owner.Icon }

    # Force render before blocking REST call
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [Action]{ $frame.Continue = $false }
    ) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)

    $popWin.Show()

    # Force render the "Loading..." state
    $frame2 = [System.Windows.Threading.DispatcherFrame]::new()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [Action]{ $frame2.Continue = $false }
    ) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame2)

    try {
        # If the Session Hosts tab hasn't been visited yet, shToPoolMap will be empty
        # and all users would show "-" in the Host Pools column. Do a lightweight
        # refresh (just host pool names + session host names, no metrics) so the
        # column populates correctly regardless of tab visit order.
        if (-not $script:shToPoolMap -or $script:shToPoolMap.Count -eq 0) {
            Write-Log "[UniqueUsers] shToPoolMap empty - running lightweight host pool refresh"
            Invoke-ShToPoolMapRefresh
        }

        Write-Log "[UniqueUsers] Querying LAW for $Period unique users"

        $resp = Invoke-LawQuery -Kql $kql -WorkspaceResourceId $lawId `
            -Timespan $(switch ($Period) { '24h' { 'P1D' }; '7d' { 'P7D' }; '30d' { 'P30D' }; default { 'P7D' } }) `
            -QueryBaseUrl $script:LawQueryBaseUrl

        if ($resp.tables -and $resp.tables[0].rows -and $resp.tables[0].rows.Count -gt 0) {
            # Use the shared shToPoolMap - same map as the main grid, always current.
            # A user may have used session hosts in multiple host pools - we collect
            # all distinct pools from their SessionHosts list and join with ', '.
            $uuShToPool = if ($script:shToPoolMap) { $script:shToPoolMap } else { @{} }

            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('User')
            [void]$dt.Columns.Add('Host Pools')
            [void]$dt.Columns.Add('First Name')
            [void]$dt.Columns.Add('Last Name')
            [void]$dt.Columns.Add('Department')
            [void]$dt.Columns.Add('Last Logon')
            [void]$dt.Columns.Add('Sessions', [int])

            foreach ($r in $resp.tables[0].rows) {
                # r[3] = SessionHosts - KQL make_set() dynamic column.
                # The LAW REST API may return this as either:
                #   - A PS array (Object[]) when the response is deeply deserialised
                #   - A JSON string e.g. '["avd-vm-prod-1","avd-vm-prod-2"]' when not
                # Handle both by attempting JSON parse if it looks like a string.
                $rawHosts = $r[3]
                $sessionHosts = if ($rawHosts -is [string]) {
                    try { @(($rawHosts | ConvertFrom-Json)) } catch { @() }
                } else {
                    @($rawHosts)
                }
                $pools = @($sessionHosts | ForEach-Object {
                    $sh = [string]$_
                    if ($sh -and $uuShToPool.ContainsKey($sh.ToLower())) { $uuShToPool[$sh.ToLower()] }
                } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
                $hostPoolStr = if ($pools.Count -gt 0) { $pools -join "`n" } else { '-' }

                $dr = $dt.NewRow()
                $dr['User']       = [string]$r[0]
                $dr['Host Pools'] = $hostPoolStr
                $dr['First Name'] = ''
                $dr['Last Name']  = ''
                $dr['Department'] = ''
                $dr['Last Logon'] = [string]$r[1]
                $dr['Sessions']   = [int]$r[2]
                [void]$dt.Rows.Add($dr)
            }

            $script:_uuDataTable = $dt
            $script:_uuGrid.ItemsSource = $dt.DefaultView
            $script:_uuTitle.Text = "$($dt.Rows.Count) unique user(s) - $periodLabel"
            $script:_uuEnrichAD.IsEnabled    = $true
            $script:_uuEnrichEntra.IsEnabled = $true
            $script:_uuExportCsv.IsEnabled   = $true
            Write-Log "[UniqueUsers] Found $($dt.Rows.Count) unique user(s)"
        } else {
            $script:_uuTitle.Text = "No users found - $periodLabel"
            Write-Log "[UniqueUsers] No users found"
        }
    } catch {
        $script:_uuTitle.Text = "Query failed: $_"
        Write-Log "[UniqueUsers] ERROR: $_"
    }

    # ── Enrich from AD (on-premises Active Directory) ──
    $script:_uuEnrichAD.Add_Click({
        $dt = $script:_uuDataTable
        if (-not $dt) { return }
        $script:_uuTitle.Text = "Enriching from AD..."
        $script:_uuEnrichAD.IsEnabled = $false
        Write-Log "[UniqueUsers] AD enrichment started for $($dt.Rows.Count) user(s)"

        # Force UI update
        $f = [System.Windows.Threading.DispatcherFrame]::new()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{ $f.Continue = $false }
        ) | Out-Null
        [System.Windows.Threading.Dispatcher]::PushFrame($f)

        $enriched = 0
        $failed   = 0
        try {
            # Collect all SAM account names
            $sams = @($dt.Rows | ForEach-Object { [string]$_['User'] } | Where-Object { $_ })
            if ($sams.Count -eq 0) { throw 'No users to enrich.' }
            Write-Log "[UniqueUsers] Usernames to enrich ($($sams.Count)): $($sams -join ', ')"

            # Batch LDAP query (chunks of 50 to avoid filter length limits)
            $adLookup = @{}
            $batchSize = 50
            for ($i = 0; $i -lt $sams.Count; $i += $batchSize) {
                $batch = $sams[$i..([Math]::Min($i + $batchSize - 1, $sams.Count - 1))]
                $ldapParts = $batch | ForEach-Object { "(samAccountName=$_)" }
                $ldapFilter = "(|$($ldapParts -join ''))"
                Write-Log "[UniqueUsers] AD batch query: $($batch.Count) user(s) (batch $([Math]::Floor($i/$batchSize)+1))"
                try {
                    $results = Get-ADUser -LDAPFilter $ldapFilter -Properties GivenName, Surname, Department -ErrorAction Stop
                    if ($results) {
                        foreach ($u in $results) { $adLookup[$u.SamAccountName.ToLower()] = $u }
                    }
                } catch {
                    Write-Log "[UniqueUsers] AD batch query failed: $_"
                }
            }
            Write-Log "[UniqueUsers] AD batch lookup returned $($adLookup.Count) user(s)"

            # Apply results to DataTable rows
            foreach ($row in $dt.Rows) {
                $sam = [string]$row['User']
                if (-not $sam) { continue }
                $adUser = $adLookup[$sam.ToLower()]
                if ($adUser) {
                    $row['First Name'] = if ($adUser.GivenName) { $adUser.GivenName } else { '' }
                    $row['Last Name']  = if ($adUser.Surname)   { $adUser.Surname }   else { '' }
                    $row['Department'] = if ($adUser.Department) { $adUser.Department } else { '' }
                    $enriched++
                } else {
                    $failed++
                }
            }
            $dt.AcceptChanges()
            $script:_uuGrid.ItemsSource = $null
            $script:_uuGrid.ItemsSource = $dt.DefaultView
            $script:_uuTitle.Text = "$($dt.Rows.Count) unique user(s) - $($script:_uuPeriodLabel) (AD: $enriched enriched, $failed not found)"
            Write-Log "[UniqueUsers] AD enrichment complete: $enriched enriched, $failed not found"
        } catch {
            $script:_uuTitle.Text = "AD enrichment failed: $_"
            Write-Log "[UniqueUsers] AD enrichment ERROR: $_"
        }
        $script:_uuEnrichAD.IsEnabled = $true
    })

    # ── Enrich from Entra ID (Microsoft Graph) ──
    # Uses Microsoft.Graph module (Get-MgUser) if available - handles its own auth/consent.
    # Falls back to REST API with Get-ArmToken (MSAL, Graph-scoped) if module not installed.
    # The REST fallback may fail with 401 if the Azure PowerShell app registration
    # doesn't have User.Read.All consent in the tenant.
    $script:_uuEnrichEntra.Add_Click({
        $dt = $script:_uuDataTable
        if (-not $dt) { return }
        $script:_uuTitle.Text = "Enriching from Entra ID..."
        $script:_uuEnrichEntra.IsEnabled = $false
        Write-Log "[UniqueUsers] Entra ID enrichment started for $($dt.Rows.Count) user(s)"

        # Force UI update
        $f = [System.Windows.Threading.DispatcherFrame]::new()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{ $f.Continue = $false }
        ) | Out-Null
        [System.Windows.Threading.Dispatcher]::PushFrame($f)

        $enriched = 0
        $failed   = 0

        # Determine which method to use: Microsoft.Graph module or REST API
        $useMgGraph = $false
        if (Get-Module -ListAvailable -Name Microsoft.Graph.Users -ErrorAction SilentlyContinue) {
            $useMgGraph = $true
            Write-Log "[UniqueUsers] Microsoft.Graph.Users module found, using Get-MgUser"
        } else {
            Write-Log "[UniqueUsers] Microsoft.Graph.Users module not found, using REST API fallback"
        }

        try {
            # Collect all SAM account names
            $sams = @($dt.Rows | ForEach-Object { [string]$_['User'] } | Where-Object { $_ })
            if ($sams.Count -eq 0) { throw 'No users to enrich.' }
            Write-Log "[UniqueUsers] Usernames to enrich ($($sams.Count)): $($sams -join ', ')"

            if ($useMgGraph) {
                # ── Microsoft.Graph module approach (batched) ──
                Import-Module Microsoft.Graph.Users -ErrorAction Stop
                # Use the existing MSAL Graph token instead of the MgGraph module's own auth.
                # This avoids an interactive sign-in popup and ensures we query the correct tenant
                # (the one the dashboard is already authenticated against, not the admin's home tenant).
                $mgGraphToken = Get-ArmToken -ResourceUrl 'https://graph.microsoft.com'
                Write-Log "[UniqueUsers] Connecting MgGraph with existing Az token (tenant: $script:azTenantId)..."
                Connect-MgGraph -AccessToken ($mgGraphToken | ConvertTo-SecureString -AsPlainText -Force) -NoWelcome -ErrorAction Stop
                $mgCtx = Get-MgContext
                Write-Log "[UniqueUsers] MgGraph connected: TenantId=$($mgCtx.TenantId) Account=$($mgCtx.Account)"

                # Build lookup hashtable via batched queries (3 passes with fallback)
                $entraLookup = @{}
                $remaining   = [System.Collections.Generic.List[string]]::new()
                foreach ($s in $sams) { $remaining.Add($s) }
                $batchSize   = 15
                $props       = 'GivenName,Surname,Department,OnPremisesSamAccountName,MailNickname,UserPrincipalName'

                # Pass 1: onPremisesSamAccountName
                $still = [System.Collections.Generic.List[string]]::new()
                for ($i = 0; $i -lt $remaining.Count; $i += $batchSize) {
                    $batch = @($remaining[$i..([Math]::Min($i + $batchSize - 1, $remaining.Count - 1))])
                    $parts = $batch | ForEach-Object { "onPremisesSamAccountName eq '$_'" }
                    $batchFilter = $parts -join ' or '
                    Write-Log "[UniqueUsers] MgGraph Pass1-samAccount querying: $($batch -join ', ')"
                    Write-Log "[UniqueUsers] MgGraph Pass1-samAccount filter: $batchFilter"
                    try {
                        $results = Get-MgUser -Filter $batchFilter -Property $props -ConsistencyLevel eventual -CountVariable c -All -ErrorAction Stop
                        $resultCount = if ($results) { @($results).Count } else { 0 }
                        Write-Log "[UniqueUsers] MgGraph Pass1-samAccount returned $resultCount result(s) (CountVariable=$c)"
                        if ($results) {
                            foreach ($u in $results) {
                                $key = if ($u.OnPremisesSamAccountName) { $u.OnPremisesSamAccountName.ToLower() } else { $null }
                                if ($key) { $entraLookup[$key] = $u; Write-Log "[UniqueUsers]   matched '$key' → UPN=$($u.UserPrincipalName)" }
                            }
                        }
                    } catch {
                        Write-Log "[UniqueUsers] MgGraph Pass1-samAccount FAILED: $_"
                    }
                }
                foreach ($s in $remaining) { if (-not $entraLookup.ContainsKey($s.ToLower())) { $still.Add($s) } }
                $remaining = $still
                if ($remaining.Count -gt 0) { Write-Log "[UniqueUsers] MgGraph Pass1 unmatched ($($remaining.Count)): $($remaining -join ', ')" }

                # Pass 2: mailNickname (for unmatched)
                if ($remaining.Count -gt 0) {
                    $still = [System.Collections.Generic.List[string]]::new()
                    for ($i = 0; $i -lt $remaining.Count; $i += $batchSize) {
                        $batch = @($remaining[$i..([Math]::Min($i + $batchSize - 1, $remaining.Count - 1))])
                        $parts = $batch | ForEach-Object { "mailNickname eq '$_'" }
                        $batchFilter = $parts -join ' or '
                        Write-Log "[UniqueUsers] MgGraph Pass2-mailNickname querying: $($batch -join ', ')"
                        try {
                            # mailNickname 'or' filters also require advanced query (ConsistencyLevel eventual)
                            $results = Get-MgUser -Filter $batchFilter -Property $props -ConsistencyLevel eventual -CountVariable c -All -ErrorAction Stop
                            $resultCount = if ($results) { @($results).Count } else { 0 }
                            Write-Log "[UniqueUsers] MgGraph Pass2-mailNickname returned $resultCount result(s)"
                            if ($results) {
                                foreach ($u in $results) {
                                    $key = if ($u.MailNickname) { $u.MailNickname.ToLower() } else { $null }
                                    if ($key) { $entraLookup[$key] = $u; Write-Log "[UniqueUsers]   matched '$key' → UPN=$($u.UserPrincipalName)" }
                                }
                            }
                        } catch {
                            Write-Log "[UniqueUsers] MgGraph Pass2-mailNickname FAILED: $_"
                        }
                    }
                    foreach ($s in $remaining) { if (-not $entraLookup.ContainsKey($s.ToLower())) { $still.Add($s) } }
                    $remaining = $still
                    if ($remaining.Count -gt 0) { Write-Log "[UniqueUsers] MgGraph Pass2 unmatched ($($remaining.Count)): $($remaining -join ', ')" }
                }

                # Pass 3: UPN startswith (individual - no batch 'or' for startswith)
                if ($remaining.Count -gt 0) {
                    Write-Log "[UniqueUsers] MgGraph Pass3-UPN startswith for $($remaining.Count) user(s)"
                    foreach ($s in $remaining) {
                        try {
                            # startswith() is an advanced query function - requires ConsistencyLevel eventual
                            $u = Get-MgUser -Filter "startswith(userPrincipalName,'$($s)@')" -Property $props -ConsistencyLevel eventual -Top 1 -ErrorAction Stop
                            if ($u) {
                                $resolved = if ($u -is [array]) { $u[0] } else { $u }
                                $entraLookup[$s.ToLower()] = $resolved
                                Write-Log "[UniqueUsers] MgGraph Pass3-UPN '$s' → matched UPN=$($resolved.UserPrincipalName)"
                            } else {
                                Write-Log "[UniqueUsers] MgGraph Pass3-UPN '$s' → no match"
                            }
                        } catch {
                            Write-Log "[UniqueUsers] MgGraph Pass3-UPN '$s' FAILED: $_"
                        }
                    }
                }

                $notFound = @($sams | Where-Object { -not $entraLookup.ContainsKey($_.ToLower()) })
                Write-Log "[UniqueUsers] MgGraph resolved $($entraLookup.Count)/$($sams.Count). Not found: $(if ($notFound) { $notFound -join ', ' } else { 'none' })"

                # Apply results to DataTable
                foreach ($row in $dt.Rows) {
                    $sam = [string]$row['User']
                    if (-not $sam) { continue }
                    $u = $entraLookup[$sam.ToLower()]
                    if ($u) {
                        $row['First Name'] = if ($u.GivenName)  { $u.GivenName }  else { '' }
                        $row['Last Name']  = if ($u.Surname)    { $u.Surname }    else { '' }
                        $row['Department'] = if ($u.Department) { $u.Department } else { '' }
                        $enriched++
                    } else {
                        $failed++
                    }
                }
            } else {
                # ── REST API fallback (batched) ──
                Write-Log "[UniqueUsers] Acquiring Graph token via Get-ArmToken (target tenant: $script:azTenantId)..."
                $graphToken = Get-ArmToken -ResourceUrl 'https://graph.microsoft.com'
                Write-Log "[UniqueUsers] Graph token acquired, length=$($graphToken.Length). Token prefix: $($graphToken.Substring(0,[Math]::Min(40,$graphToken.Length)))..."
                $hdrs = @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json'; ConsistencyLevel = 'eventual' }
                $selFields = 'givenName,surname,department,userPrincipalName,mailNickname,onPremisesSamAccountName'

                $entraLookup = @{}
                $remaining   = [System.Collections.Generic.List[string]]::new()
                foreach ($s in $sams) { $remaining.Add($s) }
                $batchSize   = 15

                # Pass 1: onPremisesSamAccountName
                $still = [System.Collections.Generic.List[string]]::new()
                for ($i = 0; $i -lt $remaining.Count; $i += $batchSize) {
                    $batch = @($remaining[$i..([Math]::Min($i + $batchSize - 1, $remaining.Count - 1))])
                    $parts = $batch | ForEach-Object { "onPremisesSamAccountName eq '$([Uri]::EscapeDataString($_))'" }
                    $filterStr = [Uri]::EscapeDataString(($parts -join ' or '))
                    $uri = "https://graph.microsoft.com/v1.0/users?`$filter=$filterStr&`$select=$selFields&`$count=true"
                    Write-Log "[UniqueUsers] REST Pass1-samAccount querying: $($batch -join ', ')"
                    try {
                        $gResp = Invoke-RestMethod -Uri $uri -Headers $hdrs -Method GET -ErrorAction Stop
                        $resultCount = if ($gResp.value) { $gResp.value.Count } else { 0 }
                        Write-Log "[UniqueUsers] REST Pass1-samAccount returned $resultCount result(s) (odataCount=$($gResp.'@odata.count'))"
                        if ($gResp.value) {
                            foreach ($u in $gResp.value) {
                                $key = if ($u.onPremisesSamAccountName) { $u.onPremisesSamAccountName.ToLower() } else { $null }
                                if ($key) { $entraLookup[$key] = $u; Write-Log "[UniqueUsers]   matched '$key' → UPN=$($u.userPrincipalName)" }
                            }
                        } else {
                            Write-Log "[UniqueUsers] REST Pass1-samAccount: empty response - Graph returned no users matching these SAM names"
                        }
                    } catch {
                        Write-Log "[UniqueUsers] REST Pass1-samAccount FAILED: $_"
                    }
                }
                foreach ($s in $remaining) { if (-not $entraLookup.ContainsKey($s.ToLower())) { $still.Add($s) } }
                $remaining = $still
                if ($remaining.Count -gt 0) { Write-Log "[UniqueUsers] REST Pass1 unmatched ($($remaining.Count)): $($remaining -join ', ')" }

                # Pass 2: mailNickname
                if ($remaining.Count -gt 0) {
                    $still = [System.Collections.Generic.List[string]]::new()
                    for ($i = 0; $i -lt $remaining.Count; $i += $batchSize) {
                        $batch = @($remaining[$i..([Math]::Min($i + $batchSize - 1, $remaining.Count - 1))])
                        $parts = $batch | ForEach-Object { "mailNickname eq '$([Uri]::EscapeDataString($_))'" }
                        $filterStr = [Uri]::EscapeDataString(($parts -join ' or '))
                        # $count=true is required alongside ConsistencyLevel:eventual for advanced query filters
                        $uri = "https://graph.microsoft.com/v1.0/users?`$filter=$filterStr&`$select=$selFields&`$count=true"
                        Write-Log "[UniqueUsers] REST Pass2-mailNickname querying: $($batch -join ', ')"
                        try {
                            $gResp = Invoke-RestMethod -Uri $uri -Headers $hdrs -Method GET -ErrorAction Stop
                            $resultCount = if ($gResp.value) { $gResp.value.Count } else { 0 }
                            Write-Log "[UniqueUsers] REST Pass2-mailNickname returned $resultCount result(s)"
                            if ($gResp.value) {
                                foreach ($u in $gResp.value) {
                                    $key = if ($u.mailNickname) { $u.mailNickname.ToLower() } else { $null }
                                    if ($key) { $entraLookup[$key] = $u; Write-Log "[UniqueUsers]   matched '$key' → UPN=$($u.userPrincipalName)" }
                                }
                            } else {
                                Write-Log "[UniqueUsers] REST Pass2-mailNickname: empty response - no mailNickname match for these usernames"
                            }
                        } catch {
                            Write-Log "[UniqueUsers] REST Pass2-mailNickname FAILED: $_"
                        }
                    }
                    foreach ($s in $remaining) { if (-not $entraLookup.ContainsKey($s.ToLower())) { $still.Add($s) } }
                    $remaining = $still
                    if ($remaining.Count -gt 0) { Write-Log "[UniqueUsers] REST Pass2 unmatched ($($remaining.Count)): $($remaining -join ', ')" }
                }

                # Pass 3: UPN startswith (individual - can't batch startswith)
                if ($remaining.Count -gt 0) {
                    Write-Log "[UniqueUsers] REST Pass3-UPN startswith for $($remaining.Count) user(s)"
                    foreach ($s in $remaining) {
                        $upnFilter = [Uri]::EscapeDataString("startswith(userPrincipalName,'$($s)@')")
                        # startswith requires advanced query - $count=true is needed alongside ConsistencyLevel:eventual header
                        $uri = "https://graph.microsoft.com/v1.0/users?`$filter=$upnFilter&`$select=$selFields&`$count=true&`$top=1"
                        try {
                            $gResp = Invoke-RestMethod -Uri $uri -Headers $hdrs -Method GET -ErrorAction Stop
                            if ($gResp.value -and $gResp.value.Count -gt 0) {
                                $entraLookup[$s.ToLower()] = $gResp.value[0]
                                Write-Log "[UniqueUsers] REST Pass3-UPN '$s' → matched UPN=$($gResp.value[0].userPrincipalName)"
                            } else {
                                Write-Log "[UniqueUsers] REST Pass3-UPN '$s' → no match (no UPN starts with '$s@')"
                            }
                        } catch {
                            Write-Log "[UniqueUsers] REST Pass3-UPN '$s' FAILED: $_"
                        }
                    }
                }

                $notFound = @($sams | Where-Object { -not $entraLookup.ContainsKey($_.ToLower()) })
                Write-Log "[UniqueUsers] REST resolved $($entraLookup.Count)/$($sams.Count). Not found: $(if ($notFound) { $notFound -join ', ' } else { 'none' })"

                # Apply results to DataTable
                foreach ($row in $dt.Rows) {
                    $sam = [string]$row['User']
                    if (-not $sam) { continue }
                    $u = $entraLookup[$sam.ToLower()]
                    if ($u) {
                        $row['First Name'] = if ($u.givenName)  { $u.givenName }  else { '' }
                        $row['Last Name']  = if ($u.surname)    { $u.surname }    else { '' }
                        $row['Department'] = if ($u.department) { $u.department } else { '' }
                        $enriched++
                    } else {
                        $failed++
                    }
                }
            }

            $dt.AcceptChanges()
            $script:_uuGrid.ItemsSource = $null
            $script:_uuGrid.ItemsSource = $dt.DefaultView
            $script:_uuTitle.Text = "$($dt.Rows.Count) unique user(s) - $($script:_uuPeriodLabel) (Entra: $enriched enriched, $failed not found)"
            Write-Log "[UniqueUsers] Entra enrichment complete: $enriched enriched, $failed not found"
        } catch {
            $script:_uuTitle.Text = "Entra ID enrichment failed: $_"
            Write-Log "[UniqueUsers] Entra enrichment ERROR: $_"
        }
        $script:_uuEnrichEntra.IsEnabled = $true
    })

    # ── Export CSV ──
    $script:_uuExportCsv.Add_Click({
        $dt = $script:_uuDataTable
        if (-not $dt) { return }

        $dlg          = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter   = 'CSV files (*.csv)|*.csv'
        $dlg.FileName = "UniqueUsers_$($script:_uuPeriod)_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"

        if ($dlg.ShowDialog() -eq $true) {
            try {
                $dt.Rows |
                    ForEach-Object {
                        $row = $_
                        $obj = [ordered]@{}
                        foreach ($col in $dt.Columns) {
                            $obj[$col.ColumnName] = $row[$col.ColumnName]
                        }
                        [PSCustomObject]$obj
                    } |
                    Export-Csv -Path $dlg.FileName -NoTypeInformation -Force
                $script:_uuTitle.Text = "Exported $($dt.Rows.Count) row(s) to $($dlg.FileName)"
                Write-Log "[UniqueUsers] Exported $($dt.Rows.Count) row(s) to $($dlg.FileName)"
            } catch {
                Show-ThemedDialog -Message "Export failed:`n$_" -Title 'Export Error' -Icon Error | Out-Null
            }
        }
    })
}

# =============================================================================
# 3. Initialize-SessionInfoTab
#
# Called once after the main window is loaded. Wires up:
#   - Unique Users tile click handlers (open _SIShowUniqueUsers popup)
#   - Filter box TextChanged handler (DataView.RowFilter on User/Session Host)
#   - Right-click context menu (Lock/Unlock History, Session History)
#   - Refresh Now button
#   - Export CSV button
#   - AD Group Export button (prompts for group name, exports members to CSV)
#   - Entra ID Group Export button (prompts for group name, exports members to CSV)
# =============================================================================

function Initialize-SessionInfoTab {
    param(
        [Parameter(Mandatory)][System.Windows.Window]$Window
    )

    $script:_siGrid       = $Window.FindName('SI_Grid')
    $script:_siStatus     = $Window.FindName('SI_Status')
    $script:_siCountdown  = $Window.FindName('SI_Countdown')
    $script:_siUsers24h   = $Window.FindName('SI_Users24h')
    $script:_siUsers7d    = $Window.FindName('SI_Users7d')
    $script:_siUsers30d   = $Window.FindName('SI_Users30d')
    $script:_siFilterBox  = $Window.FindName('SI_FilterBox')
    $script:_siExportCsv  = $Window.FindName('SI_ExportCsvButton')
    $siRefreshBtn         = $Window.FindName('SI_RefreshButton')
    $siTile24h            = $Window.FindName('SI_Tile24h')
    $siTile7d             = $Window.FindName('SI_Tile7d')

    # ── Unique Users tile clicks ──
    $siTile24h.Add_MouseLeftButtonUp({ _SIShowUniqueUsers -Period '24h' })
    $siTile7d.Add_MouseLeftButtonUp({ _SIShowUniqueUsers -Period '7d' })
    $siTile30d = $Window.FindName('SI_Tile30d')
    $siTile30d.Add_MouseLeftButtonUp({ _SIShowUniqueUsers -Period '30d' })

    # Track whether first query has fired (deferred until tab is selected)
    $script:_siFirstLoad  = $false

    # Store window reference for right-click history popups (Owner)
    $script:_siWindow = $Window

    # ── Filter logic ──
    $script:_siFilterBox.Add_TextChanged({
        if (-not $script:_siGrid.ItemsSource) { return }
        $text = $script:_siFilterBox.Text.Trim()
        if ($text -eq '') {
            $script:_siGrid.ItemsSource.RowFilter = ''
            $script:_siGrid.Items.Refresh()
        } else {
            $escaped = $text.Replace("'", "''").Replace("*", "[*]").Replace("%", "[%]")
            $script:_siGrid.ItemsSource.RowFilter = "User LIKE '%$escaped%' OR [Session Host] LIKE '%$escaped%' OR [Host Pool] LIKE '%$escaped%'"
        }
    })

    # ── Right-click context menu ──
    $ctxMenu = New-Object System.Windows.Controls.ContextMenu

    $miTimeline = New-Object System.Windows.Controls.MenuItem
    $miTimeline.Header = "View User Timeline"
    $miTimeline.Add_Click({
        $sel = $script:_siGrid.SelectedItem
        if ($sel) {
            $usr = [string]$sel['User']
            if ($usr -and $usr -ne '-') {
                _AdvShowCombinedHistory -User $usr
            }
        }
    })
    [void]$ctxMenu.Items.Add($miTimeline)

    $script:_siGrid.ContextMenu = $ctxMenu

    # ── Refresh Now button ──
    $siRefreshBtn.Add_Click({
        Write-Log "[SessionInfo] Manual refresh triggered"
        _SIRefreshData
    })

    # ── Export CSV ──
    $script:_siExportCsv.Add_Click({
        $dv = $script:_siGrid.ItemsSource
        if (-not $dv) { return }
        $tbl = $dv.Table

        $dlg          = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter   = 'CSV files (*.csv)|*.csv'
        $dlg.FileName = "SessionInfo_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"

        if ($dlg.ShowDialog() -eq $true) {
            try {
                $tbl.Rows |
                    ForEach-Object {
                        $row = $_
                        $obj = [ordered]@{}
                        foreach ($col in $tbl.Columns) {
                            $obj[$col.ColumnName] = $row[$col.ColumnName]
                        }
                        [PSCustomObject]$obj
                    } |
                    Export-Csv -Path $dlg.FileName -NoTypeInformation -Force
                $script:StatusText.Text = "Session History: Exported $($tbl.Rows.Count) row(s) to $($dlg.FileName)"
            } catch {
                Show-ThemedDialog -Message "Export failed:`n$_" -Title 'Export Error' -Icon Error | Out-Null
            }
        }
    })

    # ── AD Group Export button ──
    $siADGroupBtn = $Window.FindName('SI_ADGroupExport')
    $siADGroupBtn.Add_Click({
        $groupName = _SISearchSelectGroup -Title 'AD Group Export' -Mode 'AD'
        if (-not $groupName) { return }
        $script:StatusText.Text = "Session History: Querying AD group '$groupName'..."
        # Force UI update
        try {
            $f = [System.Windows.Threading.DispatcherFrame]::new()
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action]{ $f.Continue = $false }) | Out-Null
            [System.Windows.Threading.Dispatcher]::PushFrame($f)
        } catch {}

        try {
            $members = Get-ADGroupMember -Identity $groupName -Recursive -ErrorAction Stop |
                Where-Object { $_.objectClass -eq 'user' }
            if (-not $members -or $members.Count -eq 0) {
                $script:StatusText.Text = "Session History: No user members found in AD group '$groupName'."
                return
            }
            # Batch-fetch user details using LDAP filter
            $sams = @($members | ForEach-Object { $_.SamAccountName })
            $allUsers = [System.Collections.Generic.List[object]]::new()
            $batchSize = 50
            for ($i = 0; $i -lt $sams.Count; $i += $batchSize) {
                $batch = $sams[$i..([Math]::Min($i + $batchSize - 1, $sams.Count - 1))]
                $ldapParts = $batch | ForEach-Object { "(samAccountName=$_)" }
                $ldapFilter = "(|$($ldapParts -join ''))"
                $results = Get-ADUser -LDAPFilter $ldapFilter -Properties GivenName, Surname, Department, EmailAddress, Title -ErrorAction SilentlyContinue
                if ($results) { foreach ($r in $results) { $allUsers.Add($r) } }
            }
            # Prompt save location
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Filter   = 'CSV files (*.csv)|*.csv'
            $dlg.FileName = "ADGroup_$($groupName -replace '[^\w]','_')_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
            if ($dlg.ShowDialog() -eq $true) {
                $allUsers |
                    Select-Object SamAccountName, GivenName, Surname, Department, EmailAddress, Title |
                    Export-Csv -Path $dlg.FileName -NoTypeInformation -Force
                $script:StatusText.Text = "Session History: Exported $($allUsers.Count) member(s) from AD group '$groupName' to $($dlg.FileName)"
                Write-Log "[SessionInfo] AD group export: $($allUsers.Count) member(s) from '$groupName'"
            } else {
                $script:StatusText.Text = "Session History: AD group export cancelled."
            }
        } catch {
            $script:StatusText.Text = "Session History: AD group query failed: $_"
            Write-Log "[SessionInfo] AD group export ERROR: $_"
        }
    })

    # ── Entra Group Export button ──
    $siEntraGroupBtn = $Window.FindName('SI_EntraGroupExport')
    $siEntraGroupBtn.Add_Click({
        try {
            # Ensure Microsoft.Graph modules are available before opening the search dialog
            if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Groups -ErrorAction SilentlyContinue)) {
                $script:StatusText.Text = "Session History: Microsoft.Graph.Groups module not installed. Run: Install-Module Microsoft.Graph.Groups -Scope CurrentUser"
                return
            }
            Import-Module Microsoft.Graph.Groups -ErrorAction Stop
            Import-Module Microsoft.Graph.Users  -ErrorAction Stop
            # Connect if not already connected
            $mgCtx = $null
            try { $mgCtx = Get-MgContext -ErrorAction SilentlyContinue } catch {}
            if (-not $mgCtx) {
                $script:StatusText.Text = "Session History: Connecting to Microsoft Graph..."
                try {
                    $f = [System.Windows.Threading.DispatcherFrame]::new()
                    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
                        [System.Windows.Threading.DispatcherPriority]::Background,
                        [Action]{ $f.Continue = $false }) | Out-Null
                    [System.Windows.Threading.Dispatcher]::PushFrame($f)
                } catch {}
                Connect-MgGraph -Scopes 'GroupMember.Read.All','User.Read.All' -NoWelcome -ErrorAction Stop
            }
        } catch {
            $script:StatusText.Text = "Session History: Graph connection failed: $_"
            return
        }

        $groupName = _SISearchSelectGroup -Title 'Entra Group Export' -Mode 'Entra'
        if (-not $groupName) { return }
        $script:StatusText.Text = "Session History: Querying Entra ID group '$groupName'..."
        try {
            $f2 = [System.Windows.Threading.DispatcherFrame]::new()
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action]{ $f2.Continue = $false }) | Out-Null
            [System.Windows.Threading.Dispatcher]::PushFrame($f2)
        } catch {}

        try {
            # Find the group by exact display name (user selected it from search results)
            $escapedName = $groupName.Replace("'","''")
            $group = Get-MgGroup -Filter "displayName eq '$escapedName'" -Top 1 -ErrorAction Stop
            if (-not $group) {
                $script:StatusText.Text = "Session History: Entra group '$groupName' not found."
                return
            }
            $groupId = if ($group -is [array]) { $group[0].Id } else { $group.Id }
            # Get members (users only)
            $members = Get-MgGroupMember -GroupId $groupId -All -ErrorAction Stop
            $userMembers = @($members | Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.user' })
            if ($userMembers.Count -eq 0) {
                $script:StatusText.Text = "Session History: No user members found in Entra group '$groupName'."
                return
            }
            # Fetch full user details in batches
            $allUsers = [System.Collections.Generic.List[object]]::new()
            $batchSize = 15
            $memberIds = @($userMembers | ForEach-Object { $_.Id })
            for ($i = 0; $i -lt $memberIds.Count; $i += $batchSize) {
                $batch = $memberIds[$i..([Math]::Min($i + $batchSize - 1, $memberIds.Count - 1))]
                $filterParts = $batch | ForEach-Object { "id eq '$_'" }
                $batchFilter = $filterParts -join ' or '
                try {
                    $users = Get-MgUser -Filter $batchFilter -Property 'DisplayName,GivenName,Surname,Department,JobTitle,Mail,UserPrincipalName' -All -ErrorAction Stop
                    if ($users) { foreach ($u in $users) { $allUsers.Add($u) } }
                } catch {
                    # Fallback: fetch individually
                    foreach ($uid in $batch) {
                        try {
                            $u = Get-MgUser -UserId $uid -Property 'DisplayName,GivenName,Surname,Department,JobTitle,Mail,UserPrincipalName' -ErrorAction Stop
                            if ($u) { $allUsers.Add($u) }
                        } catch {}
                    }
                }
            }
            # Prompt save location
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Filter   = 'CSV files (*.csv)|*.csv'
            $dlg.FileName = "EntraGroup_$($groupName -replace '[^\w]','_')_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
            if ($dlg.ShowDialog() -eq $true) {
                $allUsers |
                    Select-Object DisplayName, GivenName, Surname, Department, JobTitle, Mail, UserPrincipalName |
                    Export-Csv -Path $dlg.FileName -NoTypeInformation -Force
                $script:StatusText.Text = "Session History: Exported $($allUsers.Count) member(s) from Entra group '$groupName' to $($dlg.FileName)"
                Write-Log "[SessionInfo] Entra group export: $($allUsers.Count) member(s) from '$groupName'"
            } else {
                $script:StatusText.Text = "Session History: Entra group export cancelled."
            }
        } catch {
            $script:StatusText.Text = "Session History: Entra group query failed: $_"
            Write-Log "[SessionInfo] Entra group export ERROR: $_"
        }
    })
}

# =============================================================================
# Helper: Simple WPF input dialog for group name prompt
# =============================================================================

function script:_SIPromptGroupName {
    param([string]$Title, [string]$Label)
    $inputXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="420" Height="185"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="{DynamicResource Avd.Window.Bg}" Foreground="{DynamicResource Avd.Window.Fg}"
        FontFamily="Segoe UI">
    <Window.Resources><!-- THEME_SLOT --></Window.Resources>
    <StackPanel Margin="20,18">
        <TextBlock Text="$Label" FontSize="13" Foreground="{DynamicResource Avd.Fg.Label}" Margin="0,0,0,10"/>
        <TextBox x:Name="InputBox" FontSize="13" Padding="6,5" Height="30"
                 Background="{DynamicResource Avd.Input.Bg}"
                 Foreground="{DynamicResource Avd.Fg.Label}"
                 BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="OkBtn" Content="OK" Width="80" Height="30"
                    Background="#0078D4" Foreground="White" BorderThickness="0"
                    FontSize="12" FontWeight="SemiBold" Cursor="Hand" Margin="0,0,6,0" IsDefault="True">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="BdOk" Background="{TemplateBinding Background}" CornerRadius="4" Padding="4,2">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BdOk" Property="Background" Value="#005A9E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button x:Name="CancelBtn" Content="Cancel" Width="80" Height="30"
                    Background="{DynamicResource Avd.Btn.Cancel.Bg}" Foreground="{DynamicResource Avd.Window.Fg}"
                    BorderThickness="0" FontSize="12" Cursor="Hand" IsCancel="True">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="BdCancel" Background="{TemplateBinding Background}" CornerRadius="4" Padding="4,2">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BdCancel" Property="Background" Value="{DynamicResource Avd.Btn.Cancel.Hover}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>
    </StackPanel>
</Window>
"@
    $inputXaml = $inputXaml -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\..\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($inputXaml))
    $dlgWin = [System.Windows.Markup.XamlReader]::Load($reader)
    if ($script:DarkTheme) {
        $dlgWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($dlgWin)).Handle
            $v = 1
            [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    }
    $inputBox  = $dlgWin.FindName('InputBox')
    $okBtn     = $dlgWin.FindName('OkBtn')
    $cancelBtn = $dlgWin.FindName('CancelBtn')
    $okBtn.Add_Click({ $dlgWin.Tag = $inputBox.Text.Trim(); $dlgWin.Close() })
    $cancelBtn.Add_Click({ $dlgWin.Tag = $null; $dlgWin.Close() })
    $dlgWin.Owner = $script:_siWindow
    if ($dlgWin.Owner -and $dlgWin.Owner.Icon) { $dlgWin.Icon = $dlgWin.Owner.Icon }
    $dlgWin.ShowDialog() | Out-Null
    return $dlgWin.Tag
}

# =============================================================================
# Helper: Search-and-select group dialog (AD or Entra)
# =============================================================================

function script:_SISearchSelectGroup {
    param([string]$Title, [string]$Mode)  # Mode: 'AD' or 'Entra'

    $srchXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Width="480" Height="420"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        Background="{DynamicResource Avd.Window.Bg}" Foreground="{DynamicResource Avd.Window.Fg}"
        FontFamily="Segoe UI">
    <Window.Resources><!-- THEME_SLOT -->
        <Style TargetType="ListBox">
            <Setter Property="Background"    Value="{DynamicResource Avd.Input.Bg}"/>
            <Setter Property="Foreground"    Value="{DynamicResource Avd.Fg.Label}"/>
            <Setter Property="BorderBrush"   Value="{DynamicResource Avd.Border.Input}"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style TargetType="ListBoxItem">
            <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Label}"/>
            <Setter Property="Padding"    Value="10,6"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="{DynamicResource Avd.Hover.Bg}"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{DynamicResource Avd.Selected.Bg}"/>
                    <Setter Property="Foreground" Value="{DynamicResource Avd.Fg.Selected}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <DockPanel Margin="16,14">
        <!-- Search row -->
        <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="SearchBox" Grid.Column="0" FontSize="12" Padding="6,5" Height="30"
                     Background="{DynamicResource Avd.Input.Bg}"
                     Foreground="{DynamicResource Avd.Fg.Label}"
                     BorderBrush="{DynamicResource Avd.Border.Input}" BorderThickness="1"/>
            <Button x:Name="SearchBtn" Grid.Column="1" Content="Search" Width="80" Height="30"
                    Margin="8,0,0,0" Background="#0078D4" Foreground="White"
                    BorderThickness="0" FontSize="12" FontWeight="SemiBold" Cursor="Hand">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="BdS" Background="{TemplateBinding Background}" CornerRadius="4" Padding="4,2">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BdS" Property="Background" Value="#005A9E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </Grid>
        <!-- Status text -->
        <TextBlock x:Name="SrchStatus" DockPanel.Dock="Top" FontSize="11"
                   Foreground="{DynamicResource Avd.Fg.Hint}" Margin="0,0,0,8"
                   Text="Enter a search term and click Search"/>
        <!-- Button row -->
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal"
                    HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button x:Name="OkBtn" Content="Export" Width="80" Height="30" IsDefault="True"
                    IsEnabled="False" Background="#0078D4" Foreground="White"
                    BorderThickness="0" FontSize="12" FontWeight="SemiBold"
                    Cursor="Hand" Margin="0,0,6,0">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="BdOk" Background="{TemplateBinding Background}" CornerRadius="4" Padding="4,2">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BdOk" Property="Background" Value="#888"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BdOk" Property="Background" Value="#005A9E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
            <Button x:Name="CancelBtn" Content="Cancel" Width="80" Height="30" IsCancel="True"
                    Background="{DynamicResource Avd.Btn.Cancel.Bg}"
                    Foreground="{DynamicResource Avd.Window.Fg}"
                    BorderThickness="0" FontSize="12" Cursor="Hand">
                <Button.Template>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="BdC" Background="{TemplateBinding Background}" CornerRadius="4" Padding="4,2">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BdC" Property="Background" Value="{DynamicResource Avd.Btn.Cancel.Hover}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Button.Template>
            </Button>
        </StackPanel>
        <!-- Results list -->
        <ListBox x:Name="ResultsList" FontSize="12"/>
    </DockPanel>
</Window>
"@

    $srchXaml   = $srchXaml -replace '<!-- THEME_SLOT -->', (Get-Content -Raw -Path "$PSScriptRoot\..\data\$script:_themeFile-theme.xaml" -ErrorAction Stop)
    $srchReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($srchXaml))
    $srchWin    = [Windows.Markup.XamlReader]::Load($srchReader)
    if ($script:DarkTheme) {
        $srchWin.Add_SourceInitialized({
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($srchWin)).Handle
            $v = 1
            [void][DwmApiHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
        })
    }

    $srchBox     = $srchWin.FindName('SearchBox')
    $srchBtn     = $srchWin.FindName('SearchBtn')
    $srchStatus  = $srchWin.FindName('SrchStatus')
    $resultsList = $srchWin.FindName('ResultsList')
    $okBtn       = $srchWin.FindName('OkBtn')
    $cancelBtn   = $srchWin.FindName('CancelBtn')

    $doSearch = {
        $term = $srchBox.Text.Trim()
        if (-not $term) { $srchStatus.Text = 'Enter a search term first.'; return }
        $srchStatus.Text = 'Searching...'
        $resultsList.Items.Clear()
        $okBtn.IsEnabled = $false
        try {
            $f = [System.Windows.Threading.DispatcherFrame]::new()
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
                [System.Windows.Threading.DispatcherPriority]::Background,
                [Action]{ $f.Continue = $false }) | Out-Null
            [System.Windows.Threading.Dispatcher]::PushFrame($f)
        } catch {}
        try {
            if ($Mode -eq 'AD') {
                $groups = @(Get-ADGroup -Filter "Name -like '*$term*'" -ErrorAction Stop |
                    Select-Object -ExpandProperty Name | Sort-Object)
            } else {
                $groups = @(Get-MgGroup -Search "displayName:$term" -ConsistencyLevel eventual `
                    -Top 50 -ErrorAction Stop |
                    Select-Object -ExpandProperty DisplayName | Sort-Object)
            }
            if ($groups.Count -gt 0) {
                foreach ($g in $groups) { [void]$resultsList.Items.Add($g) }
                $srchStatus.Text = "$($groups.Count) group(s) found - select one then click Export"
            } else {
                $srchStatus.Text = 'No groups found matching that term.'
            }
        } catch {
            $srchStatus.Text = "Search failed: $_"
        }
    }.GetNewClosure()

    $srchBtn.Add_Click($doSearch)
    $srchBox.Add_KeyDown({
        if ($_.Key -eq [System.Windows.Input.Key]::Return) { & $doSearch }
    }.GetNewClosure())
    $resultsList.Add_SelectionChanged({
        $okBtn.IsEnabled = ($null -ne $resultsList.SelectedItem)
    }.GetNewClosure())
    $resultsList.Add_MouseDoubleClick({
        if ($resultsList.SelectedItem) { $srchWin.Tag = $resultsList.SelectedItem; $srchWin.Close() }
    }.GetNewClosure())
    $okBtn.Add_Click({
        if ($resultsList.SelectedItem) { $srchWin.Tag = $resultsList.SelectedItem; $srchWin.Close() }
    }.GetNewClosure())
    $cancelBtn.Add_Click({ $srchWin.Tag = $null; $srchWin.Close() })

    $srchWin.Owner = $script:_siWindow
    if ($srchWin.Owner -and $srchWin.Owner.Icon) { $srchWin.Icon = $srchWin.Owner.Icon }
    $srchWin.ShowDialog() | Out-Null
    return $srchWin.Tag
}

# =============================================================================
# 4. Invoke-SessionInfoTabTimer  (called every second by masterTimer)
# =============================================================================

function Invoke-SessionInfoTabTimer {
    # Only run when the tab has been initialised and LAW is configured
    if (-not $script:_siCountdown -or -not $script:LawWorkspaceResourceId) { return }

    # Refresh once when the Session History tab is first selected, then stop.
    # Subsequent refreshes are manual only (via the Refresh button).
    if (-not $script:_siFirstLoad) {
        $siTab = $script:MainTabControl.Items | Where-Object { $_.Header -eq 'Session History' }
        if (-not $siTab -or -not $siTab.IsSelected) { return }
        $script:_siFirstLoad = $true
        $script:_siCountdown.Text = ''
        _SIRefreshData
    }
}
