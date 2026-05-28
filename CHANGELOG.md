# AVD Live Dashboard - Changelog

## 2026-05-27
- Session Hosts / Infrastructure tabs: fixed "no compute costs" regression — the Azure Retail Prices API does not reliably support the OData `not` operator, so `not contains(productName, 'Windows')` was returning 0 results for the Linux/base-rate filter in some regions. The API call now fetches all VM compute items for the SKU+Region without the `not` clause, and the Windows/Linux product selection is done client-side from the response (`productName -notlike '*Windows*'` for Linux rate, `-like '*Windows*'` for Windows Server PAYG).
- Session Hosts tab: compute pricing now detected per-VM — the VM's marketplace image offer (fetched from Resource Graph) determines whether to use the Linux/base rate or Windows Server PAYG rate. `windows-11-avd` / `windows-10-avd` → Linux rate; `WindowsServer` → Windows PAYG. Custom/gallery images fall back to `Costs.PricingWindowsLicence` in config.psd1. Mixed pools (e.g. some Windows Server, some W11 multisession) are priced correctly per host.
- Session Hosts / Infrastructure tabs: added `Costs.PricingWindowsLicence` config key. Set to `$false` (default) for Windows 10/11 multisession AVD hosts — Azure bills these at the Linux/base compute rate as the Windows licence is covered by M365. Set to `$true` only for Windows Server PAYG session hosts where the OS licence is billed per-VM. Previously the code always fetched Windows Server PAYG pricing regardless of session host OS type.
- Profile Tools: orphaned background processes fixed — `Start-Job` child processes spawned by Profile Sizes scan, Cleanup scan, and Cleanup delete are now tracked in `$script:_ptActiveJobs`; the `Add_Closed` handler stops and removes any jobs still running when the window is closed, preventing orphaned `powershell.exe` processes if the user closes mid-operation.
- Profile Tools: multi-config support added — matches the dashboard's config selection logic. When launched standalone with multiple `.psd1` files present, a themed picker appears at startup; a Switch Config button in the footer allows switching mid-session (hidden when launched from the dashboard). Shares the same `DefaultConfig` registry value as the dashboard so whichever tool runs first sets the default for both. "Clear saved default" link removes the saved choice so the picker appears on next launch.
- Dashboard: when launching Profile Tools, passes the active config file path via `-ConfigFile` so Profile Tools always opens with the same config the dashboard is using.
- Session Hosts tab: added diagnostic logging to the Phase 4 Log Analytics query — logs which VMs are sent to LAW, which are excluded (not Running) and why, and per-VM metric values returned (CPU/Mem/Disk/Input Delay) on the main thread after EndInvoke.

## 2026-05-26
- Session Hosts tab: when more than 3 users are on a host, shows first 2 names and "..." on the third line; tooltip shows all users. Reduced font and line spacing so 3 names fit within the standard row height.
- Images tab: added "sysprep only" option to the BIS-F / Sysprep dropdown; skips BIS-F and runs the Sysprep Run Command directly.
- Images tab: fixed blank Subnet dropdown on dialog open; initial subnets now fetched via a per-VNet ARM GET in the Loaded handler.
- Images tab: added diagnostic Write-Log calls throughout the Create Image dialog (enabled when -EnableLogging is passed to the dashboard).
- Images tab: "Other" VM count no longer shows negative when a refresh races with a VM state change.
- Azure Files tab: added Public Access column showing whether public blob access is allowed or denied on each storage account.
- Config editor: fixed "Empty path name is not legal" error on Browse / Open caused by a PowerShell parse failure in Initialize-Controls.

## 2026-05-22
- Multi-config support: place multiple `.psd1` files in the `config\` folder. If more than one is found, a picker appears at launch; set a default to skip the prompt. Each config gets its own registry subkey for independent saved settings. A Switch Config button appears in the footer when multiple configs are present.

## 2026-05-19
- Theme toggle: fixed title bar changing colour before the window content when switching between light and dark mode. A `Dispatcher.Invoke` at `DispatcherPriority::Render` now flushes WPF's pending render pass before `DwmSetWindowAttribute` is called, ensuring both update in the same frame.

## 2026-05-15
- Monitoring tab: LAW queries (Winlogon Stages, RTT by Gateway, Session History) now run in a dedicated background runspace (`$script:monRunspace`) via `BeginInvoke()`. The UI remains fully responsive while queries execute; a 200ms poll timer applies results when the job completes.
- Screenshot script: fixed `<!-- THEME_SLOT -->` not being replaced in light-mode windows, causing the WPF window background/foreground to fall back to system defaults. All XAML windows now get the light theme via `Apply-LightTheme` (MergedDictionaries); dark screenshots add dark theme on top.
- Screenshot script: Dark Mode toggle now rendered as checked (on) in the dark mode screenshot.

## 2026-05-14
- Monitoring tab: Custom KQL Query panel — run arbitrary KQL against the configured Log Analytics workspace, view results in a dynamic table, and save/load named queries to AppData.

## 2026-05-06
- Dark theme: optional VS Code-style toggle in Settings (requires restart). Full coverage: window, header, cards, DataGrid, tabs, status bar, About dialog, Settings dialog. Title bar darkened via DwmSetWindowAttribute. Splash screen pre-themed before first paint.

## 2026-05-05
- Audit log: fixed PS5 compatibility (ternary operator removed); audit CSV now writes on dashboard launch.
- Audit log: SendMessage only logged on successful send; Logoff Target trimmed to short VM name; CleanSnapshots/CleanImageVersions result/error fields corrected.
- RDP audit: Target now always populated (vmName moved outside IP-resolution block).
- Per Host Pool tab: marketplace-based host pools show "N/A" in Image Version column instead of blank; disk API version corrected to 2024-03-02.

## 2026-04-30
- Images tab: BIS-F path config setting (default `C:\_source\Bis-F`); Create Image uses configured path.
- Images tab: gallery replication region config (Region 1 required, Region 2 optional) with replica counts per region.
- Images tab: "Open Resource Group in Portal" right-click menu item.
- Images tab: image creation output saved to `logs\image-creation\` per job.
- Images tab: Preparation VM Size Default changed to a dropdown.
- Infrastructure tab: "Open Resource Group in Portal" right-click menu item.
- Session hosts tab: "Idle Time" column showing time since last user input (Log Analytics Perf counter, 4h lookback; shows "4h+" beyond window).
- Shadow: documented port 445 requirement for MSTSC shadow mode in README; MSRA documented as alternative when 445 is blocked.
- Audit log: weekly rotation (one file per week, named by Monday's date).
- Config editor: loads missing config keys from defaults on open (Merge-ConfigDefaults).

## 2026-04-29
- Authentication: extracted shared auth logic into scripts/connect-azure.ps1
  (Connect-AzureDashboard). Supports interactive browser, device code, existing
  context, and service principal modes.
- Profile Tools: now supports -UseDeviceAuthentication, -UseExistingContext, and
  -UseServicePrincipal launch switches — matching the dashboard auth options.
  Previously required a pre-existing Az context; now authenticates independently on launch.
- Added Launch-Profile-Tools-Select.cmd quick-launch shortcut for auth mode selection.
- Scripts folder: renamed Check-Permissions.ps1, Create-DashboardRole.ps1, and
  Create-Image.ps1 to lowercase to match the rest of the scripts folder.

## 2026-04-28 (Images tab)
- Images tab: new tab — lists gold image VMs with power state, IP, SKU, region. Start /
  Deallocate / Restart power actions, filter box, Export CSV, configurable auto-refresh.
- Images tab: right-click — RDP, Create Image dialog (gallery, definition, VNet filtered
  to VM region, VM size from config), View Sysprep Log (SMB or Run Command fallback).
- Create-Image.ps1: rewritten to use ARM REST API (no Az.Compute/Az.Network required).
  BIS-F via Run Command v2; Sysprep via Run Command v1 (captures setuperr.log output).
  Gallery failure details logged. Token and helper passed as env vars from the dashboard.
- config.psd1: new Images fields — PrepVMSizes, PrepVMSizeDefault.
  HiddenTabs is now a hard deployment floor — config-hidden tabs cannot be re-enabled via
  Settings UI and their checkboxes are removed from the Settings panel.

## 2026-04-28
- Per Host Pool tab: added "Private Endpoints" right-click context menu item. Opens a popup
  listing the name and Azure region of each private endpoint connection for the selected host
  pool. PE names are read from the host pool ARM resource; regions are resolved via parallel
  GET calls against each PE resource (Microsoft.Network API) during the refresh cycle.
- Run Command: fixed GPUpdate command — changed from bare `gpupdate /force` to
  `& gpupdate.exe /force 2>&1 | Out-String` so output is captured and displayed correctly
  in the results window.
- Run Command: window now shows the AVD dashboard icon (avd-dashboard.ico) in the title bar.

## 2026-04-27
- Per Host Pool tab: added "HP Region" column (immediately after Host Pool name) showing
  the Azure region of the host pool resource itself.
- Per Host Pool tab: added "Private Endpoints" column showing the count of private endpoints
  configured for each host pool. Fetched in parallel with other metadata at startup.
- Per Host Pool tab: added "Enable/Disable Scaling Plan" single toggle right-click menu item.
  Label updates dynamically based on current state; greyed out when no scaling plan attached.
- Azure DevOps tab: clicking the "X Running" tile now opens a popup listing all in-progress
  and not-started pipeline runs.
- Azure DevOps tab: fixed pipeline Run action — stagesToSkip was serialised as a PowerShell
  object rather than a JSON array, causing ADO to return BuildId=0. Fixed by skipping
  ConvertFrom-Json on empty arrays.
- Azure DevOps tab: fixed Organisation URL not persisting to registry — registry path
  ($script:RegPath) was null inside the GetNewClosure handler; now uses hardcoded path.
  URL is now always written on save regardless of whether it changed.

## 2026-04-23
- Session Hosts tab: power action skip logic now uses the Azure `Power State` column
  (Running / Deallocated / Stopped from Resource Graph) instead of the AVD `Status`
  column. Start skips Running VMs; Deallocate/Restart skips Deallocated/Stopped VMs.

## 2026-04-22
- Per Host Pool tab: added "Enable Scaling Plan" / "Disable Scaling Plan" right-click
  menu items. Items are greyed out when the pool has no scaling plan attached. The
  correct item is enabled based on the current state (only Enable shown when disabled,
  only Disable shown when enabled). Calls ARM PATCH to update the scaling plan's
  hostPoolReferences array; grid cell updates immediately on success.

## 2026-04-20
- Per Host Pool tab: RG VMs red cell colour now preserved when the row is
  selected. Switched from a default-setter approach (overridden by the inherited
  IsSelected trigger) to DataTrigger-only colouring which has higher WPF
  precedence than property triggers.
- Session Hosts tab: column header refactor - repeated 4-line TextBlock blocks
  replaced with inlined single-line equivalents inside the AutoGeneratingColumn
  handler. Fixes "cannot call a method on a null-valued expression" error on
  ItemsSource assignment caused by a captured scriptblock variable being null
  when the event fired.
- Session Hosts tab: "Open C$ Share" added to right-click context menu.
  Respects ShadowUseIP config (uses IP or hostname). Requires TCP 445 (SMB).
- Session Hosts tab: RDP / Open C$ / Run Command context menu items now enable
  only when Power State = Running (previously used Status != Shutdown which
  did not correctly identify deallocated VMs).
- Infrastructure tab: power action status message now says "initiated" (matching
  Session Hosts tab). Skipped-VM tracking added - VMs already in the target
  power state are skipped and listed in the status message.
- Session History tab: username sort now case-insensitive (tolower() in KQL)
  so all-caps names no longer sort ahead of mixed-case names.
- Session History tab: Unique Users popup columns now have vertical separators
  matching the main Session History grid style.
- Scaling Plan History popup: fixed "stuck on Loading..." - switched from
  BeginInvoke async pattern to synchronous call after PushFrame UI flush.
- FSLogix Log Viewer: added Computer Name field for remote machine support.
  Auto-rewrites log path to UNC (\\host\C$\...). Queries remote FSLogix
  services and event logs via -ComputerName. Requires TCP 445 for log files,
  TCP 135 + RPC for services/events.
- Architecture diagram updated to reflect current file structure.
- Version history moved to CHANGELOG.md; README updated with AI attribution.
- AI assistance attribution removed from individual .ps1 script headers.

## 2026-04-16
- Session History tab: Host Pool column now populates correctly on first
  load without requiring a prior visit to the Session Hosts tab.
- Unique Users popup: widened to 900x560; Host Pools column replaced with
  a wrapping template column showing one pool per line; column order and
  widths stable across AD/Entra enrichment rebinds.
- Settings dialog: "Compare RG VM count" checkbox moved to its own
  "Per Host Pool: RG VM Count" section, separate from Scaling settings.
- Monitoring tab: Winlogon bar chart top margin increased so value labels
  above tall bars are no longer clipped; chart row given fixed height and
  wrapped in a ScrollViewer so content is accessible at smaller window sizes.
- Dashboard default window height increased from 748 to 820px.

## 2026-04-15
- Per Host Pool tab: added Network Access column showing each host pool's
  public network access setting (Public / Private / Hosts Only / Clients Only)
  sourced from properties.publicNetworkAccess in the existing ARM response -
  no extra API calls. Visible via Settings hidden columns toggle.
- Per Host Pool tab: added RG VM Count feature toggle (ShowRGVMCount in
  config.psd1 and Settings). When disabled, the ARM call per VM resource group
  is skipped entirely and the RG VMs column is hidden. Reduces API calls for
  environments where the comparison is not needed.
- Per Host Pool tab: Scaling Plan History popup - EvaluationTime timestamps
  now converted from UTC to local system time (BST/DST-aware) so the displayed
  times match the local clock rather than appearing 1h behind.
- Session Hosts tab: Avail Zone column now shows N/A (instead of -) for VMs
  not pinned to an availability zone, consistent with other N/A values.
- Session Hosts tab: User column font reduced to 11pt for multi-user rows
  so stacked names fit within the standard row height without overflowing.
- Session Hosts tab: filterable columns (Region, Status, Power State, Health
  State, Drain Mode, etc.) now correctly show black text when a row is
  selected - the ComboBox dropdown header was preventing the global
  DataGridCell IsSelected style from applying.
- Session Hosts tab: heat map columns (CPU %, Mem %, OS Disk %, etc.) and
  OS Disk IOPS column now BasedOn the global DataGridCell style so the
  IsSelected Foreground fix is inherited.
- Settings / Edit Config: RG VM Count toggle exposed in both the Settings
  dialog and the Edit Config editor (AVD Host Pools tab).
- Settings / Edit Config: RG VMs and Network Access columns added to
  hidden-columns checkboxes in both the Settings dialog and Edit Config.

## 2026-04-14
- Monitoring tab: Session History chart - new two-series line chart (Active
  blue, Disconnected orange) sourced from WVDAgentHealthStatus using a
  two-stage KQL aggregation (per-host peak per bin, summed across hosts).
  Matches Azure Portal host pool overview counts. Bin sizes: 5m/15m/30m for
  short ranges, 1h for 7d/30d. Hover crosshair with tooltip. Zero-fill for
  gap bins. DST-safe UTC normalisation.
- Monitoring tab: Session History result caching - results cached in memory
  per time range + host pool combination (TTL 5/10/20 min by range). Refresh
  button always bypasses cache. Cache cleared on dashboard close.
- Subscription error handling - InvalidSubscriptionId now shows a clear
  dialog with actionable guidance. AuthorizationFailed status bar message
  updated to direct to Switch Subscription. Both dialogs close the splash
  first so they render fully visible over the dashboard.

## 2026-04-12
- Azure DevOps Pipelines tab: new tab (scripts/tab-azuredevops.ps1) showing
  all pipelines and recent runs across a configured ADO organisation/project.
  Split-pane layout: left TreeView groups pipelines by folder; right DataGrid
  shows up to 200 recent runs with colour-coded Status and Result columns.
  Clicking a folder or pipeline filters the runs grid to that scope.
- Azure DevOps tab: PAT authentication using a Personal Access Token stored
  via DPAPI (Export-Clixml, Windows user/machine bound). Configured via a
  "Set PAT" dialog accessible from the tab toolbar. No PAT = no API calls;
  tab shows a prompt to configure. Auth errors (401/403) stop auto-refresh
  and show a clear message so stale/expired PATs are immediately obvious.
- Azure DevOps tab: Organisation URL configurable from the "Set PAT" dialog
  (no restart required). Auto-refresh interval also configurable there
  (minimum 10 s, default 30 s). Settings persisted to HKCU registry.
- Azure DevOps tab: Run Pipeline dialog fetches live data from three ADO
  endpoints: build definitions (default branch, available repo branches,
  queue-time variables), pipelines API (YAML templateParameters with types
  and allowed values for picklist rendering), and a preview-run POST
  (stage identifiers). Renders type-appropriate controls: CheckBox for
  boolean, ComboBox for picklist, TextBox for free-form string. Stage
  checkboxes all start checked; uncheck any to add it to stagesToSkip.
- Azure DevOps tab: right-click context menu on runs grid: Run Pipeline,
  Cancel Run (inProgress/notStarted only), Delete Run (completed only,
  confirmation dialog), View Log (fetches all log entries and displays
  them in a scrollable monospace popup with Copy to Clipboard button).
- Azure DevOps tab: tab only auto-refreshes when it is the active tab and
  a PAT is configured, preventing unnecessary background API calls.

## 2026-04-10
- Session Hosts tab: renamed 'Power State' column to 'Status' (AVD agent-level
  status: Available, Unavailable, Shutdown). Added new 'Power State' column
  showing the real Azure VM power state (Running, Deallocated, Stopped, etc.)
  sourced from the existing Phase 3 Resource Graph query - no additional API
  calls. 'Status' column gains a dropdown filter alongside 'Power State'.
- Session Hosts tab: compute cost (Compute GBP/mo) now based on real VM
  Power State = 'Running' rather than AVD Status = 'Available', so cost
  correctly reflects actual Azure billing state.
- Per Host Pool / By Region tabs: renamed 'VMs On' to 'VMs Available' and
  'VMs Off' to 'VMs Not Available'. Column headers split across two lines.
- Version history dates reformatted to YYYY-MM-DD across all scripts, tools,
  and README. Version field now uses date only (no version number).
- Session Hosts tab: added 'CPU Credits History' right-click option. Opens a
  chart popup showing CPU Credits Remaining over time (Azure Monitor metric).
  Only enabled for B-series VMs (Standard_B*); greyed out for all other SKUs.
  Gap-aware rendering: VM-off periods appear as breaks in the chart line, not
  connected. Threshold reference lines at 30 (amber) and 10 (red) credits.
- Session Hosts tab: Phase 5b (CPU Credits) now pre-launched concurrently with
  Phase 5 (disk metrics) instead of sequentially after it. Both sets of Azure
  Monitor batch calls run in parallel, saving ~200-600 ms per refresh cycle.

## 2026-03-31
- Session Hosts tab: added Azure Hybrid Benefit (AHB) pricing toggle in
  scripts/cost-lookup.ps1 ($script:UseAHBPricing). When set to $true the
  compute price is fetched as the base/Linux rate (no Windows Server licence
  fee), reflecting what Azure bills for VMs with AHB enabled via Software
  Assurance. Default is $false (standard Windows PAYG, licence included).
- Session Hosts tab: cost column display precision changed from 4 decimal
  places to 2 decimal places for Compute GBP/mo and Disk GBP/mo (e.g.
  56.06 and 7.80). Txn GBP/10K remains at 4 decimal places as the rate
  is a sub-penny figure.
- scripts/cost-lookup.ps1: comprehensive inline commenting added throughout
  - overview, column descriptions, caching/batching behaviour, AHB toggle
  explanation, DispatcherTimer/runspace pattern, API filter logic, and
  parameter documentation.
- Azure Files tab: added Storage GBP/mo cost column and green Load Costs button.
  Pricing is fetched from the Azure Retail Prices API (public, no auth) in a
  background runspace using the same DispatcherTimer pattern as Session Hosts.
  Premium file shares (Premium_LRS/ZRS) are billed on provisioned quota;
  standard shares (TransactionOptimized, Hot, Cool) are billed on consumed
  (used) capacity. Access tier "Cool" maps to the "Azure Files Cool" product;
  all other standard tiers map to "Azure Files". Replication type (LRS, ZRS,
  GRS) is derived from the storage account SKU name. One API call per unique
  product+replication+region combination - identical shares in the same account
  share a single call. Costs are cached and reapplied on every auto-refresh.
  Transaction costs (per-operation charges) are not included. Logic appended
  to scripts/cost-lookup.ps1 (no new file).
- Session Hosts tab: Avail Zone column moved before VM SKU.
- Infrastructure tab: added Compute GBP/mo, Disk GBP/mo, and Txn GBP/10K cost
  columns with a green Load Costs button, using the same DispatcherTimer +
  background runspace pattern as Session Hosts. Disk SKU column updated to show
  full tier detail (e.g. "E10 (127 GB) 500 IOPS") matching the Session Hosts tab.
- Azure Files tab: added Performance, Replication, and Account Kind columns
  (displayed after Quota (GiB)) derived from the storage account SKU and kind.
- scripts/cost-lookup.ps1: fixed compute price picking Spot or Low Priority rates
  in some regions where item order from the API varies - now explicitly excludes
  Spot and Low Priority skuName entries. Added contains(productName,'Virtual
  Machines') filter to prevent non-VM Windows products matching the same armSkuName.
- scripts/cost-lookup.ps1: fixed disk price picking the Disk Mount meter (~0.84)
  instead of the base disk storage meter (~7.80) in regions where the API returns
  Mount items first - now excludes meterName entries containing 'Mount'.
- scripts/cost-lookup.ps1: fixed Azure Files picking Snapshot or Metadata meters
  instead of the provisioned/data-stored rate - now excludes meterName entries
  containing 'Snapshot' or 'Metadata'.

## 2026-03-26
- Session Hosts tab: added OS Disk IOPS, IOPS %, and Queue Depth columns
  via Azure Monitor Metrics API (platform metrics, no LAW required). Parallel
  per-VM queries using RunspacePool. Queue Depth has heat map colouring.
  Disk SKU column now shows tier, size, and provisioned IOPS (e.g. P10 (128 GB) 500 IOPS).
- Performance History popup: added Disk IOPS and Queue Depth chart panel
  sourced from Azure Monitor Metrics API with auto-scaling dual Y-axis.
- Drain mode: option to automatically set/remove the scaling exclude tag
  on VMs when enabling/disabling drain mode. Controlled via Settings checkbox
  (enabled by default). Uses Microsoft.Resources Tags API (merge/delete).
- Fixed potential zombie PowerShell process leaks in parallel fan-out patterns
  by adding try/finally safety nets around all handle collection loops.
- Fixed session detail user filter not applying in real-time when typing
  (removed GetNewClosure from timer/TextChanged handlers).
- Monitoring tab: Winlogon Stages grouped bar chart breaking down logon
  time into stages (Group Policy, FSLogix, User Auth, Shell, Others) with
  P95 and P50 bars. Adapted from the AVD Insights workbook KQL. Host pool
  filter for per-pool analysis. Stage tooltips from MS documentation.
- Monitoring tab: RTT by Gateway Region data grid showing round-trip time
  statistics (Median, P95, Peak, Peak Time) per Azure gateway region.
- KQL queries externalised to data/kql/ files with placeholder tokens for
  easy editing and direct testing in Log Analytics.
- Fix: module installer now bootstraps the NuGet package provider before
  calling Install-Module, preventing failures on clean machines where NuGet
  is not registered.
- Fix: Session Age in User Sessions detail window showed negative values for
  users in UTC+ timezones. PowerShell's [DateTime] cast converts ISO 8601
  UTC strings to local time, so subtracting from [DateTime]::UtcNow produced
  a negative span. Fixed by calling .ToUniversalTime() on the parsed createTime
  before the subtraction in both fetch paths (session-detail.ps1).
- Session Hosts tab: added Compute GBP/mo, Disk GBP/mo, and Txn GBP/10K cost
  columns populated on demand via a new green "Load Costs" toolbar button.
  Pricing is fetched from the Azure Retail Prices API (prices.azure.com - public,
  no auth) in a background runspace: Windows PAYG hourly compute per VM
  SKU+region pair, managed disk monthly price, and per-10,000 transaction price
  for Standard SSD and Standard HDD disks (Premium SSD shows '-' as it has no
  transaction fees). Deallocated VMs show 0.0000 compute and the disk rate only.
  Identical SKUs in the same region are batched into a single API call. Prices
  are cached in $script:shCostCache and reapplied automatically on every
  subsequent refresh - no re-fetch until Load Costs is clicked again. Currency
  and country are configurable at the top of scripts/cost-lookup.ps1 (defaults:
  GBP / GB). Logic extracted to scripts/cost-lookup.ps1 for modularity.

## 2026-03-23
- Audit logging: records destructive actions (logoff, drain, power actions,
  run commands, profile delete/unlock, shadow/RDP, send message) to daily CSV
  files in the logs/ subfolder. Enabled by default via Dashboard.EnableAuditLog
  in config.psd1. Columns: Timestamp, User, Action, Target, Details, Result.
- Logging function renamed from Write-RestLog to Write-Log for clarity.
- UNC icon fix: .ProviderPath used instead of .Path for icon loading so
  icons display correctly when running from network shares.
- Permissions Checker: Storage File Data Privileged Contributor role now
  checked per individual storage account with per-account status display.
- Improved error logging: added Write-Log calls to catch blocks in
  run-command.ps1, profile-tools.ps1, and avd-live-dashboard.ps1 auth flow.

## 2026-03-19
- Per Host Pool tab: split Image Version into two columns - Image Version A
  and Image Version B. Configured via HostGroupPatterns in config.psd1, each
  pattern is a case-insensitive substring matched against VM short hostnames.
  When both patterns are set, the dashboard queries one VM from each group per
  host pool/region. If only one group exists, the other column shows "N/A".
  When patterns are empty, both columns show the same version (first VM found).

## 2026-03-11
- Session History: added Disconnect Type column that differentiates clean
  vs dirty disconnects using TerminalServices EventID 40 reason codes.
  Joins EventID 40 with EventID 24 (same session ID) to resolve the user.
  Reason labels: Normal, User Initiated, Admin Initiated, Logoff,
  Session Replaced, Idle Timeout, Unknown (code).
- Session History detail view (right-click View Session History): Disconnect
  events now show a Disconnect Type column with the reason for each event.
- Session Detail: fixed LAW enrichment not appearing for long-running sessions
  (connected more than 8 hours ago). WVDConnections and WVDCheckpoints queries
  now use a configurable lookback window (default 24h) so the original
  connection event and ShortpathEstablished checkpoint are still found.
  WVDConnectionNetworkData (RTT/BW) remains at 8h for current performance.
  Controlled by LawConnectionLookbackWindow / LawConnectionLookbackTimespan
  variables at the top of scripts/session-detail.ps1.
- Settings: added Reload Config button. Re-parses config.psd1 at runtime
  without restarting the script. Registry-saved settings still take priority
  over reloaded config defaults. Shows success/error inline in the Settings
  dialog and triggers an immediate dashboard refresh on success.
- Session History: added Unique Users summary tiles (24h and 7d) in the
  top bar showing how many distinct users logged on within each window
  across the whole environment. Counts are environment-wide (not filtered
  by the current session detail view) using KQL dcount() against
  TerminalServices EventID 21 (Logon only). Tiles update on every refresh
  cycle alongside the main grid query.
- Session Hosts tab: Input Delay KQL now caps samples at 10,000ms (10s).
  Samples above this threshold are measurement anomalies (e.g. LapsView.exe
  once reported 549,047ms) and are excluded from Median and P95 calculations.
- Session Hosts tab: added Input Delay Breakdown right-click option. Opens a
  popup showing per-process input delay samples from the last hour for the
  selected host. DataGrid columns: Time, Process, Input Delay (ms), sorted
  worst-first. Summary bar shows sample count, median, P95, and the 10s cap.

## 2026-03-07
- Run Commands: added ScriptFile support. Commands in data/run-commands.psd1 can
  now reference an external .ps1 file in data/runcommands/ instead of embedding
  the entire script inline. Complex commands (Top Processes, Check TCP Port Usage)
  moved to separate files for readability and easier editing.
- Edit Config: Run Commands tab shows file path (read-only) for ScriptFile-based
  commands, with a hint showing the source file location.
- Refactor: Run Command engine (picker, execution, output, timer) extracted from
  session-detail.ps1 into its own scripts/run-command.ps1 module.
- Fix: replaced en-dash in edit-config XAML hint text to avoid PS5.1 encoding garble.
- Session Hosts tab: Input Delay column headers now display as two lines
  ("Input Delay" / "Median" and "Input Delay" / "P95") to reduce column width.
- Session Hosts tab: Scaling Exclude column now shows "No" instead of blank
  when the VM does not have the scaling exclude tag.
- Session Hosts/Session Detail: removed fixed MinWidth on filter ComboBoxes
  so columns size to fit their content.
- Session Detail: fixed Avg RTT and P95 RTT column sorting (was alphabetical,
  now numeric).
- Launchers: updated cmd files to hide the PowerShell console window on
  Windows 11 where Windows Terminal ignores -WindowStyle Hidden.
- Session Detail: added Session History button. Opens a modal window
  querying Log Analytics for lock/unlock events (Security EventID 4800/4801)
  and session lifecycle events (TerminalServices EventID 21/23/24/25). Queries
  are user-centric - events are found across all session hosts, not just the
  current host. Each timestamp shows which device it occurred on. Right-click
  any row for "View Lock/Unlock History" or "View Session History" with a Host
  column and selectable time range (12h to 7 days). Auto-refreshes on the same
  interval as the main dashboard. Requires audit policy and TerminalServices
  log collection to LAW. Can be hidden via config.psd1.
- Edit Config: added HideSessionHistory checkbox under Feature Visibility
  in the Dashboard tab.
- Session History: added Export CSV button to export the session history
  grid data to a CSV file via Save dialog.

## 2026-03-03
- Session Hosts tab: added CPU %, Mem %, Disk %, Input Delay Median, and Input
  Delay P95 columns populated from Log Analytics Workspace at each refresh
  (Available VMs only). CPU/Mem/Disk use a 15-minute window; Input Delay uses a
  1-hour window for a more meaningful P95 (matches Microsoft Insights workbook).
  Heat map cell colouring on all columns: green below threshold, amber mid-range,
  red high. LAW workspace configured via LogAnalytics.WorkspaceResourceId in
  config.psd1.
- Session Hosts tab: added Performance History right-click option. Opens a popup
  line chart of CPU % and Mem % over time with selectable range (1h/4h/12h/24h)
  and amber/red threshold lines.
- Session Hosts tab: added Copy Hostname and Copy IP Address to the right-click
  context menu.
- Session Hosts tab: empty hosts (0 sessions) are now hidden by default; uncheck
  the filter to reveal them.
- Run Command: predefined commands loaded from data/run-commands.psd1 - add,
  remove, or reorder commands without modifying scripts. Includes Reload Commands
  button to pick up file changes without restarting. Built-in commands: Top
  Processes by CPU/RAM, Restart AVD Agent, Run GPUpdate, Check Disk Space, Check
  FSLogix Status, Get Logged-On Users, Check TCP Port Usage (per-process
  connection breakdown with port exhaustion risk assessment).
- Run Command output window is now resizable and expands with the picker window.
- Session detail windows are now non-modal - multiple can be open simultaneously.
- Power actions: Deallocate, Start, and Restart now skip VMs already in the
  target state. Skipped VMs are noted in the completion message.
- Session detail: added per-column dropdown filters on Location and State
  column headers (same pattern as Session Hosts tab). Combined with the existing
  user text filter via AND logic. Clear Filters button resets all filters.
- Session Hosts and Session Detail grids: Ctrl+MouseWheel zoom (60%-150%)
  to fit more or fewer rows on screen.
- Status bar: long messages now show a tooltip on hover instead of being clipped.
- Settings UI expanded to two-column layout: Operational Settings (left) and
  Display & Filter Settings (right). New display/filter settings override
  config.psd1 defaults via registry: Hidden Tabs, Hidden Columns, Low Priority
  Patterns, Secondary Regions, Scaling Exclude Tag, Storage Account Kinds,
  Infrastructure Exclude Patterns. Hidden Tabs and Columns use checkboxes;
  text lists use multiline input. Empty registry = config.psd1 default applies.
- New config.psd1 option: Dashboard.HideSettingsButton - when $true, the
  Settings button is hidden from the toolbar (config-only, not in registry).

## 2026-03-02
- Initial REST API release. Replaced all Az PowerShell module cmdlets with
  direct Azure REST API calls via Invoke-RestMethod and bearer tokens. Only
  Az.Accounts remains (for token acquisition). New scripts/rest-api-helpers.ps1
  provides Invoke-ArmRestMethod (core REST wrapper with pagination, retry,
  exponential backoff) plus resource-specific wrapper functions. RunspacePool
  threads use a compact Invoke-Arm helper injected via scriptblock string.
  Benefits: dramatically faster runspace startup, lower memory usage, single
  module dependency.

## 2026-02-23
- Initial release - PowerShell module based.
