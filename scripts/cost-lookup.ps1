# cost-lookup.ps1
# Session Hosts tab - PAYG cost lookup via the Azure Retail Prices API.
#
# Exposes one public function: Invoke-SessionHostsCostFetch
#
# ── Overview ──────────────────────────────────────────────────────────────────
# This script adds estimated monthly costs to each VM row in the Session Hosts
# tab. It works entirely without Azure authentication - it queries the public
# Azure Retail Prices REST API (prices.azure.com) which requires no credentials.
#
# The fetch runs in a background PowerShell runspace so the UI stays responsive
# while waiting for HTTP responses. A DispatcherTimer polls every 500ms on the
# WPF UI thread to check if the background work has finished, then applies the
# results to the grid.
#
# ── Columns populated ─────────────────────────────────────────────────────────
#   Compute GBP/mo  - Hourly VM compute rate x HoursPerMonth.
#                     Shows 0.00 for deallocated VMs (no compute charge when off).
#                     Shows '-' if no price was returned for that SKU/region.
#   Disk GBP/mo     - Fixed monthly managed disk price (LRS).
#                     The API returns this as a flat per-month figure, not hourly.
#   Txn GBP/10K     - Per 10,000 disk I/O transaction charge.
#                     Only applies to Standard SSD and Standard HDD - Premium SSD
#                     has no transaction cost so that column shows '-'.
#
# ── Caching ───────────────────────────────────────────────────────────────────
# After a successful fetch, prices are stored in $script:shCostCache (keyed by
# VM Name). Every time the grid refreshes (_SH_UpdateGrid), it checks this cache
# and re-stamps the cost values onto the new DataTable rows. This means costs
# survive auto-refresh without hitting the API again.
# Clicking "Load Costs" again clears and rebuilds the cache with fresh API data.
#
# ── Batching ──────────────────────────────────────────────────────────────────
# Rather than one API call per VM, the script collects all unique
# SKU+Region combinations across the entire fleet first, then fires one API
# call per unique pair. If you have 20 VMs all running Standard_B2s_v2 in
# uksouth, that is still only ONE compute API call and ONE disk API call.
# VMs in different regions each get their own call since pricing varies by region.

# ── Pricing configuration ──────────────────────────────────────────────────────
# Adjust these variables to match your billing currency, Azure country, and
# whether your VMs use Azure Hybrid Benefit (AHB).
#
# PricingCurrency:   ISO 4217 currency code used by prices.azure.com.
#                    e.g. GBP (British Pounds), USD (US Dollars), EUR (Euros)
#
# PricingCountryCode: ISO 3166-1 alpha-2 country code that scopes pricing to
#                    your Azure billing country.
#                    e.g. GB (United Kingdom), US (United States), DE (Germany)
#
# HoursPerMonth:     Used to convert the API's per-hour compute rate into a
#                    monthly estimate. 730 = 365 days x 24 hours / 12 months.
#
# UseAHBPricing:     Controls whether compute prices reflect Azure Hybrid Benefit.
#
#                    $false (default) - Standard Windows PAYG pricing.
#                    The API filter includes 'Windows' in the product name, so the
#                    returned price includes the Windows Server licence cost.
#                    Use this if your VMs do NOT have AHB enabled.
#
#                    $true - Azure Hybrid Benefit / Windows 10/11 multisession pricing.
#                    AHB lets you use existing Windows Server licences covered by
#                    Software Assurance, so Microsoft only charges the base compute
#                    rate (no Windows licence fee on top). The API filter excludes
#                    the Windows product name and returns the base/Linux compute
#                    rate, which is what Microsoft bills for AHB and Windows 10/11
#                    multisession AVD VMs (Windows licence is covered by M365).
#                    Use this for AHB VMs or Windows 10/11 multisession session hosts.
#
# This default is overridden by Costs.PricingWindowsLicence in config.psd1 at startup.
$script:PricingCurrency    = 'GBP'
$script:PricingCountryCode = 'GB'
$script:HoursPerMonth         = 730   # Full month (365 days x 24 hrs / 12 months) - used for column cost calculation
$script:SHUsageHoursPerMonth  = 416   # Session Hosts actual planned usage: 16 hrs/day x 6 days/week
$script:UseAHBPricing      = $false
# ──────────────────────────────────────────────────────────────────────────────

# ── Script-level DispatcherTimer ───────────────────────────────────────────────
# IMPORTANT: The timer and its tick handler MUST be defined here at script scope,
# not inside a function. DispatcherTimer callbacks created inside a function run
# in a restricted module-like scope where $script: variables and global functions
# are not accessible. Defining them here ensures full access to $script: state.
#
# How the timer works:
#   - Invoke-SessionHostsCostFetch starts a background runspace and then starts
#     this timer.
#   - Every 500ms the Tick handler fires on the WPF UI thread and checks whether
#     the background runspace has finished (shCostHandle.IsCompleted).
#   - Once complete, EndInvoke collects the results, the cache is built, and
#     _SH_UpdateGrid is called to repaint the grid with costs applied.
#   - A 30-second watchdog aborts the runspace if the API takes too long.
$script:shCostTimer          = New-Object System.Windows.Threading.DispatcherTimer
$script:shCostTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:shCostTimer.Add_Tick({

    # ── Watchdog: abort if the background fetch exceeds 30 seconds ─────────────
    # IsCompleted being $false means the runspace is still running. We check
    # elapsed time and kill it if it has been running too long - this prevents
    # the button from being stuck in 'Loading...' state if the API is unreachable.
    if (-not $script:shCostHandle -or -not $script:shCostHandle.IsCompleted) {
        if (([DateTime]::Now - $script:shCostStartTime).TotalSeconds -gt 30) {
            $script:shCostTimer.Stop()
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup] Timed out after 30s`r`n") } catch {} }
            try { $script:shCostPS.Stop() } catch {}
            try { $script:shCostPS.Runspace.Dispose() } catch {}
            try { $script:shCostPS.Dispose() } catch {}
            $script:shCostPS = $null; $script:shCostHandle = $null
            $script:SHLoadCostsButton.IsEnabled = $true
            $script:SHLoadCostsButton.Content   = 'Load Costs'
            [System.Windows.MessageBox]::Show("Cost fetch timed out.`n`nCheck that prices.azure.com is accessible from this machine.", 'Load Costs Timeout', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        }
        return  # Not done yet - timer will fire again in 500ms
    }

    # ── Background fetch is complete - collect results ─────────────────────────
    $script:shCostTimer.Stop()
    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup] Fetch completed - calling EndInvoke`r`n") } catch {} }

    try {
        # EndInvoke retrieves the return value from the background runspace.
        # The runspace returns a single PSCustomObject with three hashtables:
        #   ComputeMap  - keyed by "VmSku|Region|OsType",         value = hourly rate
        #   DiskMap     - keyed by "DiskTier|DiskSku|Region",   value = monthly rate
        #   TxnMap      - keyed by "DiskTier|DiskSku|Region",   value = per-10K rate
        $result = $script:shCostPS.EndInvoke($script:shCostHandle)
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup] EndInvoke returned $($result.Count) object(s)`r`n") } catch {} }

        if ($result -and $result.Count -gt 0) {
            $computeMap = $result[0].ComputeMap
            $diskMap    = $result[0].DiskMap
            $txnMap     = $result[0].TxnMap

            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup] Fetch complete - ComputeEntries: $($computeMap.Count) DiskEntries: $($diskMap.Count) TxnEntries: $($txnMap.Count)`r`n") } catch {} }

            # ── Build the cost cache keyed by VM Name ──────────────────────────
            # We walk the row snapshot (taken at fetch time) rather than the live
            # DataTable, because the table may have been refreshed while the API
            # calls were in flight. The snapshot guarantees we match the right VM
            # names to the right SKU/region pricing.
            #
            # Compute monthly cost:
            #   - Only 'Available' (running) VMs incur compute charges.
            #     Deallocated VMs have no compute charge so we store 0.
            #   - Multiply the API's per-hour rate by HoursPerMonth.
            #
            # Disk monthly cost:
            #   - Managed disk charges apply regardless of VM power state.
            #   - The API returns a flat per-month figure for the disk tier/region.
            #
            # Transaction cost:
            #   - Only Standard SSD and Standard HDD have a per-I/O charge.
            #   - Stored as a raw rate (GBP per 10,000 I/Os) for display.
            #   - Value of -1 means no transaction pricing for this disk type
            #     (i.e. Premium SSD), which the grid displays as '-'.
            $script:shCostCache = @{}
            foreach ($r in $script:shCostRowSnap) {
                # vmKey must include OsType to match the key used when the price was fetched.
                # Two VMs with the same SKU and region but different OS types have separate
                # entries in computeMap (e.g. 'Standard_D8as_v5|swedencentral|Linux' vs '...Windows').
                $vmKey   = "$($r.VmSku)|$($r.Region)|$($r.OsType)"
                $diskKey = "$($r.DiskTier)|$($r.DiskSku)|$($r.Region)"

                # Store the raw per-hour rate alongside the monthly cost so _SH_UpdateGrid can
                # recompute the monthly figure if the VM's power state changes between fetches.
                $cHr = if ($computeMap.ContainsKey($vmKey)) { $computeMap[$vmKey] } else { [double]0 }
                $cMo = if ($r.State -eq 'Running') { $cHr * $script:HoursPerMonth } else { [double]0 }
                $dMo = if ($diskMap.ContainsKey($diskKey)) { $diskMap[$diskKey] } else { [double]0 }
                $tPr = if ($txnMap.ContainsKey($diskKey))  { $txnMap[$diskKey]  } else { [double]-1 }

                $script:shCostCache[$r.VmName] = @{ Compute = $cMo; ComputeHr = $cHr; Disk = $dMo; Txn = $tPr }
            }

            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup] CacheBuilt: $($script:shCostCache.Count) entries. Calling _SH_UpdateGrid with $($script:shLastVmRows.Count) VmRows`r`n") } catch {} }

            # ── Update the status bar and repaint the grid ─────────────────────
            # Show a summary of how many prices came back so the user can tell
            # at a glance whether the API returned data or came back empty.
            $statusMsg = if ($computeMap.Count -gt 0 -or $diskMap.Count -gt 0) {
                "Estimated costs loaded: $($computeMap.Count) compute price(s), $($diskMap.Count) disk price(s) (estimated usage: $($script:SHUsageHoursPerMonth) hrs/mo)"
            } else {
                "Load Costs: no matching prices returned by the API - check VM SKU and region"
            }
            if ($script:SHActionStatus) { $script:SHActionStatus.Text = $statusMsg }

            # Rebuild the grid using the last known VM data. _SH_UpdateGrid will
            # convert the VM rows back into a DataTable and then stamp the cached
            # cost values onto each row before binding to the WPF DataGrid.
            _SH_UpdateGrid -VmRows $script:shLastVmRows -Timestamp $script:shLastTimestamp
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup] _SH_UpdateGrid completed`r`n") } catch {} }

            # ── Phase 5: Cost Management - 30-day actual disk transaction charges ───────────
            #
            # Why Cost Management instead of Azure Monitor?
            #   Azure Monitor "OS Disk Operations/Sec" is a rate metric sampled at 1-min
            #   intervals.  Multiplying the per-hour average by 3600 inflates the total for
            #   VMs that are deallocated or idle for part of each hour bucket - in testing
            #   this overestimated the actual bill by ~6x (e.g. £3.07 estimate vs £0.53 billed).
            #   The Cost Management Query API returns the amount Azure actually charged, so
            #   the dashboard value matches Cost Analysis in the portal exactly (subject to
            #   the usual 24-48 h billing lag).
            #
            # Which disks are included?
            #   Only Standard SSD and Standard HDD disks have a separate transaction meter.
            #   Premium SSD bundles operations into the disk price so Txn -gt 0 is never
            #   true for those VMs - they are silently excluded from txnRows here.
            #
            # Single POST for all VMs:
            #   We pass all OS disk resource IDs in one Cost Management query (filtered by
            #   ResourceId 'In' the list) and group by ResourceId + Meter so each row in the
            #   response is one meter type for one disk.  We then filter locally to keep only
            #   rows whose Meter name contains "Operations" (e.g. "E10 LRS Disk Operations"),
            #   discarding the storage capacity meter rows returned for the same resource IDs.
            #   This avoids per-VM API calls and stays within Cost Management rate limits.
            #
            # Required RBAC permission:
            #   Cost Management Reader at subscription scope (or any role that includes
            #   Microsoft.CostManagement/query/action).  Owner / Contributor also satisfy this.
            $txnRows = @(foreach ($r in $script:shCostRowSnap) {
                # Include only VMs where the Retail Prices API found a per-10K transaction rate
                # (Txn -gt 0).  Premium SSD returns no transaction meter so Txn stays 0 and
                # those VMs are excluded.  Also require a known OS disk resource ID - without it
                # the Cost Management filter cannot target the correct disk resource.
                if ($script:shCostCache.ContainsKey($r.VmName) -and $script:shCostCache[$r.VmName].Txn -gt 0 -and $r.OsDiskResourceId) {
                    [PSCustomObject]@{ VmName = $r.VmName; OsDiskResourceId = $r.OsDiskResourceId; TxnRate = $script:shCostCache[$r.VmName].Txn }
                }
            })
            if ($txnRows.Count -gt 0) {
                if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup] Starting Cost Management txn fetch for $($txnRows.Count) Standard SSD/HDD VM(s)`r`n") } catch {} }
                # Build the scriptblock as a string so $script:restHelperDef (Invoke-Arm helper)
                # is prepended before the here-string body - nested here-strings are not valid
                # in PowerShell so the concatenation approach is used throughout this file.
                $txnFetchScript = [scriptblock]::Create($script:restHelperDef + @'
                    $tok = $args[0]; $rows = $args[1]; $LogFile = $args[2]; $subId = $args[3]
                    $txnMoMap = @{}; $errors = [System.Collections.Generic.List[string]]::new()

                    # Rolling 30-day window ending now (UTC).  Cost Management 'Custom' timeframe
                    # requires dates in yyyy-MM-dd format - time components are not accepted.
                    $end  = [datetime]::UtcNow; $start = $end.AddDays(-30)
                    $from = $start.ToString('yyyy-MM-dd'); $to = $end.ToString('yyyy-MM-dd')

                    # Collect all OS disk resource IDs - lowercased by the Resource Graph query
                    # and stored in _OsDiskResourceId.  Cost Management returns ResourceId in
                    # lowercase so the comparison is case-insensitive by construction.
                    $diskIds = @($rows | ForEach-Object { $_.OsDiskResourceId })
                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost] Cost Management query: $($diskIds.Count) disk(s), $from to $to`r`n") } catch {} }
                    try {
                        # POST /subscriptions/{sub}/providers/Microsoft.CostManagement/query
                        # API version 2023-11-01 - stable release that supports ActualCost queries.
                        #
                        # filter: restrict to the exact OS disk resource IDs for this tab's VMs.
                        #   'In' is the only supported operator for Dimension filters - 'Contains'
                        #   and 'StartsWith' are not valid and will return a 400 BadRequest.
                        #
                        # grouping: ResourceId + Meter gives one row per disk per meter type.
                        #   We need Meter in the grouping (not a filter) because 'MeterName' is
                        #   not a valid filter dimension.  The local filter below keeps only rows
                        #   whose Meter value contains "Operations".
                        #
                        # aggregation: sum the Cost column (billed amount in the subscription's
                        #   billing currency - typically GBP for UK subscriptions).
                        $body = @{
                            type       = 'ActualCost'
                            timeframe  = 'Custom'
                            timePeriod = @{ from = $from; to = $to }
                            dataset    = @{
                                granularity = 'None'
                                filter      = @{ dimensions = @{ name = 'ResourceId'; operator = 'In'; values = $diskIds } }
                                grouping    = @(
                                    @{ type = 'Dimension'; name = 'ResourceId' }
                                    @{ type = 'Dimension'; name = 'Meter' }
                                )
                                aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
                            }
                        }
                        $resp = Invoke-Arm -Method POST -Path "/subscriptions/$subId/providers/Microsoft.CostManagement/query" -Token $tok -ApiVersion '2023-11-01' -Body $body -FullResponse

                        # Column order in the response is not guaranteed - find Cost, ResourceId
                        # and Meter indices by name before iterating over data rows.
                        $costIdx = -1; $ridIdx = -1; $meterIdx = -1
                        for ($i = 0; $i -lt $resp.properties.columns.Count; $i++) {
                            if ($resp.properties.columns[$i].name -eq 'Cost')       { $costIdx  = $i }
                            if ($resp.properties.columns[$i].name -eq 'ResourceId') { $ridIdx   = $i }
                            if ($resp.properties.columns[$i].name -eq 'Meter')      { $meterIdx = $i }
                        }
                        foreach ($dataRow in @($resp.properties.rows)) {
                            $meter = if ($meterIdx -ge 0) { [string]$dataRow[$meterIdx] } else { 'Operations' }
                            # Skip non-operations meters (e.g. "E10 LRS" storage capacity rows).
                            # Operations meters are named like "E10 LRS Disk Operations" or
                            # "S4 LRS Disk Operations" - the wildcard catches all tiers/sizes.
                            if ($meter -notlike '*Operations*') { continue }
                            $cost = [double]$dataRow[$costIdx]
                            $rid  = ([string]$dataRow[$ridIdx]).ToLower()
                            # Match the response ResourceId back to the VM name via the rows list.
                            $match = $rows | Where-Object { $_.OsDiskResourceId -eq $rid }
                            if ($match) {
                                # Accumulate - a single disk can have multiple operations meter rows
                                # if the billing period spans a tier change.
                                $txnMoMap[$match.VmName] = ($txnMoMap[$match.VmName] -as [double]) + $cost
                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost] $($match.VmName) [$meter]: +$([math]::Round($cost,4)) -> total=$([math]::Round($txnMoMap[$match.VmName],4))`r`n") } catch {} }
                            }
                        }
                        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost] Done: $($txnMoMap.Count) costed`r`n") } catch {} }
                    } catch {
                        $errors.Add("Cost Management query failed: $_")
                        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost] ERROR: $_`r`n") } catch {} }
                    }
                    return [PSCustomObject]@{ TxnMoMap = $txnMoMap; Errors = $errors.ToArray() }
'@)
                $txnRs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
                $txnRs.ApartmentState = 'STA'; $txnRs.ThreadOptions = 'ReuseThread'; $txnRs.Open()
                $script:shTxnPS = [System.Management.Automation.PowerShell]::Create()
                $script:shTxnPS.Runspace = $txnRs
                [void]$script:shTxnPS.AddScript($txnFetchScript).AddArgument($script:armToken).AddArgument($txnRows).AddArgument([string]$script:LogFile).AddArgument([string]$script:vmSubId)
                $script:shTxnHandle    = $script:shTxnPS.BeginInvoke()
                $script:shTxnStartTime = [DateTime]::Now
                $script:shTxnCostTimer.Start()
                # Button re-enabled by shTxnCostTimer tick when Cost Management fetch completes
            } else {
                # No Standard SSD/HDD VMs - re-enable immediately
                if ($script:SHLoadCostsButton) { $script:SHLoadCostsButton.IsEnabled = $true; $script:SHLoadCostsButton.Content = 'Load Costs' }
            }
        }
    } catch {
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup] ERROR: $_`r`n") } catch {} }
        if ($script:SHActionStatus) { $script:SHActionStatus.Text = "Load Costs failed: $_" }
        [System.Windows.MessageBox]::Show(
            "Cost fetch failed:`n$_", 'Load Costs Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error) | Out-Null
        if ($script:SHLoadCostsButton) { $script:SHLoadCostsButton.IsEnabled = $true; $script:SHLoadCostsButton.Content = 'Load Costs' }
    } finally {
        try { $script:shCostPS.Runspace.Dispose() } catch {}
        try { $script:shCostPS.Dispose() } catch {}
        $script:shCostPS     = $null
        $script:shCostHandle = $null
    }
})

# DispatcherTimer that polls the Azure Monitor 30-day transaction cost runspace.
# Fires after the pricing fetch completes for Standard SSD/HDD VMs only.
$script:shTxnCostTimer          = New-Object System.Windows.Threading.DispatcherTimer
$script:shTxnCostTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:shTxnCostTimer.Add_Tick({
    if (-not $script:shTxnHandle -or -not $script:shTxnHandle.IsCompleted) {
        if (([DateTime]::Now - $script:shTxnStartTime).TotalSeconds -gt 60) {
            $script:shTxnCostTimer.Stop()
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost] Timed out after 60s`r`n") } catch {} }
            try { $script:shTxnPS.Stop() } catch {}
            try { $script:shTxnPS.Runspace.Dispose() } catch {}
            try { $script:shTxnPS.Dispose() } catch {}
            $script:shTxnPS = $null; $script:shTxnHandle = $null
            if ($script:SHLoadCostsButton) { $script:SHLoadCostsButton.IsEnabled = $true; $script:SHLoadCostsButton.Content = 'Load Costs' }
        }
        return
    }
    $script:shTxnCostTimer.Stop()
    try {
        $result = $script:shTxnPS.EndInvoke($script:shTxnHandle)
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost] Monitor fetch complete`r`n") } catch {} }
        # Surface any API errors from the scriptblock even when logging is off.
        # Cost Management returns BadRequest for unsupported subscription offer types
        # (e.g. MS-AZR-0036P internal/MSDN subs). In that case the retail price costs
        # still loaded fine - show a status bar warning only, not a blocking dialog.
        if ($result -and $result.Count -gt 0 -and $result[0].Errors -and $result[0].Errors.Count -gt 0) {
            $errDetail = $result[0].Errors -join "`n"
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost] Errors from scriptblock:`n$errDetail`r`n") } catch {} }
            $isOfferUnsupported = $errDetail -match 'offer.*not supported|Cost management data is unavailable'
            if ($isOfferUnsupported) {
                # Subscription offer type doesn't support Cost Management - suppress the
                # blocking dialog and just note it in the status bar.
                if ($script:SHActionStatus) { $script:SHActionStatus.Text = 'Txn costs unavailable: subscription offer type not supported by Cost Management' }
            } else {
                if ($script:SHActionStatus) { $script:SHActionStatus.Text = 'Txn cost fetch error - enable logging for details' }
                [System.Windows.MessageBox]::Show("Transaction cost fetch failed:`n$errDetail", 'Txn Cost Error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        }
        if ($result -and $result.Count -gt 0 -and $result[0].TxnMoMap) {
            # Persist into caches so _SH_UpdateGrid can reapply on every auto-refresh
            foreach ($kv in $result[0].TxnMoMap.GetEnumerator()) { $script:shTxnMoCache[$kv.Key] = $kv.Value }
            # Stamp onto live DataTable rows immediately
            foreach ($row in $script:vmDataTable.Rows) {
                $vm = [string]$row['VM Name']
                if ($script:shTxnMoCache.ContainsKey($vm)) {
                    $mo  = $script:shTxnMoCache[$vm]
                    $row['Txn GBP/mo']     = if ($mo -ge 0) { '{0:F2}' -f $mo } else { '-' }
                    $row['_TxnMoCostSort'] = $mo
                }
            }
            _SH_UpdateTotals
        }
    } catch {
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost] ERROR in tick handler: $_`r`n") } catch {} }
    } finally {
        try { $script:shTxnPS.Runspace.Dispose() } catch {}
        try { $script:shTxnPS.Dispose() } catch {}
        $script:shTxnPS = $null; $script:shTxnHandle = $null
        if ($script:SHLoadCostsButton) { $script:SHLoadCostsButton.IsEnabled = $true; $script:SHLoadCostsButton.Content = 'Load Costs' }
    }
})

function Invoke-SessionHostsCostFetch {
    <#
    .SYNOPSIS
        Fetches estimated monthly costs for all Session Host VMs from the
        Azure Retail Prices API and updates the Session Hosts grid.

    .DESCRIPTION
        Called when the user clicks the "Load Costs" button on the Session Hosts tab.

        Execution flow:
          1. Snapshot  - Walk the current DataTable to collect all unique
                         VM SKU+Region and Disk Tier+SKU+Region combinations.
                         Using a HashSet means identical VMs share a single API call.

          2. Runspace  - Spin up a background PowerShell runspace and fire one
                         Invoke-RestMethod call per unique VM combo and per unique
                         disk combo against prices.azure.com. The UI thread is not
                         blocked during this phase.

          3. Timer     - A DispatcherTimer (defined at script scope above) polls
                         every 500ms on the UI thread to check if the runspace has
                         finished.

          4. Cache     - On completion, results are stored in $script:shCostCache
                         keyed by VM Name. The cache persists across grid refreshes
                         so costs are not lost when the auto-refresh timer fires.

          5. Repaint   - _SH_UpdateGrid is called with the last known VM rows,
                         which rebuilds the DataTable and stamps cached costs onto
                         each row before WPF re-binds.
    #>

    # Guard: the DataTable must have rows before we can work out which SKUs and
    # regions to query. This should never be empty if the button is only enabled
    # after data loads, but check defensively.
    if (-not $script:vmDataTable -or $script:vmDataTable.Rows.Count -eq 0) { return }

    $script:SHLoadCostsButton.IsEnabled = $false
    $script:SHLoadCostsButton.Content   = 'Loading...'
    if ($script:SHActionStatus) { $script:SHActionStatus.Text = 'Fetching prices from Azure Retail Prices API...' }
    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup] Starting price fetch - Currency: $script:PricingCurrency HoursPerMonth: $script:HoursPerMonth AHB: $script:UseAHBPricing`r`n") } catch {} }

    # ── Step 1: Snapshot unique pricing combos from the current DataTable ───────
    # We build two HashSets of unique key strings so that multiple VMs sharing
    # the same SKU and region result in only ONE API call.
    #
    # vmCombos   format: "VmSku|Region|OsType"     e.g. "Standard_B2s_v2|uksouth|Linux"
    # diskCombos format: "DiskTier|DiskSku|Region" e.g. "E10|StandardSSD_LRS|uksouth"
    #
    # We also save a full row snapshot ($shCostRowSnap) so the tick handler can
    # map API results back to individual VM names once the fetch completes.
    # The snapshot is taken NOW rather than inside the runspace because the
    # DataTable lives on the UI thread and is not safe to access from a background
    # thread. Passing plain PSCustomObjects to the runspace is safe.
    $vmCombos   = [System.Collections.Generic.HashSet[string]]::new()
    $diskCombos = [System.Collections.Generic.HashSet[string]]::new()
    $script:shCostRowSnap = @(foreach ($dr in $script:vmDataTable.Rows) {
        [PSCustomObject]@{
            VmName           = [string]$dr['VM Name']
            State            = [string]$dr['Power State']         # Used to zero out compute cost for deallocated VMs
            VmSku            = [string]$dr['VM SKU']
            Region           = [string]$dr['Region']
            DiskTier         = [string]$dr['_DiskTier']         # e.g. 'E10', 'P10', 'S10' - hidden column
            DiskSku          = [string]$dr['_DiskSkuRaw']       # e.g. 'StandardSSD_LRS'   - hidden column
            OsDiskResourceId = [string]$dr['_OsDiskResourceId'] # for Cost Management txn cost query
            # Per-VM OS type detected from the VM's marketplace image offer in Phase 3.
            # 'Linux'   = fetch Linux/base rate  (W10/W11 multisession, AHB)
            # 'Windows' = fetch Windows PAYG rate (Windows Server without AHB)
            # Embedded in the vmCombos key so two VMs with the same SKU and region
            # but different OS types each get the right price with one API call each.
            OsType           = [string]$dr['_PricingOsType']
        }
    })
    foreach ($r in $script:shCostRowSnap) {
        # vmCombos key format: "VmSku|Region|OsType"
        # The third segment drives which Azure Retail Prices API filter is used — see fetchScript.
        # Disk combos are OS-neutral (managed disk price is the same regardless of guest OS).
        if ($r.VmSku    -and $r.VmSku    -ne '-') { [void]$vmCombos.Add("$($r.VmSku)|$($r.Region)|$($r.OsType)") }
        if ($r.DiskTier -and $r.DiskTier -ne '')  { [void]$diskCombos.Add("$($r.DiskTier)|$($r.DiskSku)|$($r.Region)") }
    }

    # ── Step 2: Background runspace script block ─────────────────────────────
    # Everything inside $fetchScript runs in a separate thread with no access to
    # $script: variables or functions defined outside. All required data is passed
    # in via AddArgument() and received via the param() block.
    $fetchScript = {
        param(
            [string[]]$VmCombos,      # Unique "VmSku|Region|OsType" strings to price (OsType = 'Windows' or 'Linux')
            [string[]]$DiskCombos,    # Unique "DiskTier|DiskSku|Region" strings to price
            [string]$CurrencyCode,    # ISO 4217 currency code (e.g. 'GBP')
            [string]$CountryCode,     # ISO 3166 country code (e.g. 'GB') - unused in filter but available
            [int]$HoursPerMonth,      # Hours per month for compute cost calculation
            [string]$LogFile          # Path to log file, or empty string if logging is disabled
        )

        # Helper so log writes don't clutter the fetch logic
        function Write-CostLog { param($Msg) if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup] $Msg`r`n") } catch {} } }

        # PowerShell 5.1 defaults to TLS 1.0/1.1. prices.azure.com requires TLS 1.2,
        # so we must upgrade the security protocol before making any web requests.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        # Result hashtables - populated by the loops below and returned as a
        # single object at the end so EndInvoke only has one item to collect.
        $computeMap = @{}  # "VmSku|Region|OsType"    -> hourly rate (double)
        $diskMap    = @{}  # "DiskTier|DiskSku|Region" -> monthly rate (double)
        $txnMap     = @{}  # "DiskTier|DiskSku|Region" -> per-10K rate (double)

        # The base URL includes the currency code as a query parameter. The OData
        # $filter is appended (URL-encoded) for each individual request.
        $baseUrl = "https://prices.azure.com/api/retail/prices?currencyCode=$CurrencyCode&`$filter="
        Write-CostLog "TLS set to 1.2. VmCombos: $($VmCombos.Count) DiskCombos: $($DiskCombos.Count) Currency: $CurrencyCode Hours/mo: $HoursPerMonth"

        # ── VM compute prices (per-hour rate) ─────────────────────────────────
        # One API call per unique SKU+Region+OsType combination.
        #
        # The OsType segment in each combo key selects the correct price tier:
        #
        #   OsType='Linux'   - Selects products WITHOUT 'Windows' in the productName.
        #                      Returns the base/Linux compute rate for the SKU.
        #                      Use for: Windows 10/11 multisession AVD hosts (Windows
        #                      licence is covered by M365, not billed per-VM), and
        #                      VMs with Azure Hybrid Benefit (own Windows SA licence).
        #
        #   OsType='Windows' - Selects products WITH 'Windows' in the productName.
        #                      Returns the full Windows Server PAYG rate (compute +
        #                      Windows Server licence bundled in the hourly rate).
        #                      Use for: Windows Server session hosts without AHB.
        #
        # 'contains(productName, Virtual Machines)' ensures we only match VM compute
        # entries and not other Windows-related products (e.g. Windows Server licencing
        # items) that share the same armSkuName in some regions.
        #
        # IMPORTANT: The Windows/Linux split is done CLIENT-SIDE (not in the API filter)
        # because the OData 'not' operator is not reliably supported by prices.azure.com.
        # A single API call returns all VM items for the SKU+Region; the productName check
        # below selects either the Linux (base) or Windows (PAYG) item from the response.
        #
        # The API can return multiple items (e.g. Spot, Low Priority). We take only
        # the standard on-demand (Consumption) item with unitOfMeasure '1 Hour'.
        foreach ($combo in $VmCombos) {
            # combo format: "VmSku|Region|OsType"
            $parts = $combo.Split('|'); $vmSku = $parts[0]; $region = $parts[1]; $osType = $parts[2]
            # Use the Linux/base rate for Windows 10/11 multisession and AHB VMs;
            # use the Windows PAYG rate (with OS licence) for Windows Server PAYG VMs.
            $useLinuxRate = ($osType -ne 'Windows')
            try {
                # One API call per SKU+Region - fetch ALL Virtual Machines compute items for this
                # combination. Windows/Linux selection is done client-side from the response.
                $filter = "armSkuName eq '$vmSku' and armRegionName eq '$region' and priceType eq 'Consumption' and serviceFamily eq 'Compute' and contains(productName, 'Virtual Machines')"
                $url  = "$baseUrl$([Uri]::EscapeDataString($filter))"
                Write-CostLog "Compute GET (OsType=$osType useLinux=$useLinuxRate): $url"
                $resp = Invoke-RestMethod -Uri $url -Method GET -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                Write-CostLog "Compute response: $($resp.Count) item(s) - items: $(($resp.Items | ForEach-Object { "$($_.skuName) $($_.unitOfMeasure) $($_.retailPrice)" }) -join ' | ')"
                # Select the correct item client-side:
                #   - Exclude Spot and Low Priority (item order varies by region)
                #   - Exclude 'Windows' from productName for Linux rate; require it for Windows rate
                #   - Take the standard on-demand (Consumption) entry with unitOfMeasure '1 Hour'
                $candidates = @($resp.Items | Where-Object { $_.unitOfMeasure -eq '1 Hour' -and $_.skuName -notlike '*Spot*' -and $_.skuName -notlike '*Low Priority*' })
                $item = if ($useLinuxRate) {
                    $candidates | Where-Object { $_.productName -notlike '*Windows*' } | Select-Object -First 1
                } else {
                    $candidates | Where-Object { $_.productName -like '*Windows*' } | Select-Object -First 1
                }
                if ($item) { $computeMap[$combo] = [double]$item.retailPrice; Write-CostLog "Compute price for $combo = $($item.retailPrice)/hr (skuName='$($item.skuName)' productName='$($item.productName)') -> $([math]::Round($item.retailPrice * $HoursPerMonth,4))/mo" }
                else        { Write-CostLog "Compute WARN: no standard '1 Hour' item found for $combo (useLinux=$useLinuxRate candidates=$($candidates.Count))" }
            } catch { Write-CostLog "Compute ERROR for $combo : $_" }
        }

        # ── Disk storage prices (monthly rate + optional transaction rate) ─────
        # One API call per unique DiskTier+DiskSku+Region combination.
        #
        # The skuRaw value (e.g. 'StandardSSD_LRS', 'Premium_LRS') is used to
        # map to the correct Azure Storage product name for the API filter.
        #
        # Disk price (unitOfMeasure '1/Month'):
        #   The API returns the flat monthly charge for the disk tier directly.
        #   No hourly conversion needed - it is already per month.
        #
        # Transaction price (unitOfMeasure '10K'):
        #   Standard SSD and Standard HDD charge per 10,000 I/O operations.
        #   This item appears in the same API response as the disk price.
        #   Premium SSD has no transaction charge so we skip it for Premium*.
        foreach ($combo in $DiskCombos) {
            $parts = $combo.Split('|'); $tier = $parts[0]; $skuRaw = $parts[1]; $region = $parts[2]

            # Map the raw SKU name to the Azure Storage product name used in the API
            $productName = switch -Wildcard ($skuRaw) {
                'Premium*'     { 'Premium SSD Managed Disks';  break }
                'StandardSSD*' { 'Standard SSD Managed Disks'; break }
                'Standard*'    { 'Standard HDD Managed Disks'; break }
                default        { '' }
            }
            if (-not $productName) { Write-CostLog "Disk WARN: unknown SKU type '$skuRaw' for $combo - skipping"; continue }

            try {
                # The skuName filter uses the tier + 'LRS' (e.g. 'E10 LRS', 'P10 LRS', 'S10 LRS').
                # LRS = Locally Redundant Storage - the standard replication tier for managed disks.
                $filter = "skuName eq '$tier LRS' and armRegionName eq '$region' and serviceFamily eq 'Storage' and productName eq '$productName'"
                $url    = "$baseUrl$([Uri]::EscapeDataString($filter))"
                Write-CostLog "Disk GET: $url"
                $resp   = Invoke-RestMethod -Uri $url -Method GET -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                Write-CostLog "Disk response: $($resp.Count) item(s) - items: $(($resp.Items | ForEach-Object { "$($_.skuName) $($_.unitOfMeasure) $($_.retailPrice)" }) -join ' | ')"

                # Extract the monthly disk price and (if applicable) the transaction price
                # from the same response - both are returned together by the API.
                # The API returns two 1/Month items: the actual disk price (meterName "E10 LRS Disk")
                # and a Disk Mount charge (meterName "E10 LRS Disk Mount") used for shared disks.
                # We exclude Mount items so we always pick the base disk storage price.
                $item    = $resp.Items | Where-Object { $_.unitOfMeasure -eq '1/Month' -and $_.meterName -notlike '*Mount*' } | Select-Object -First 1
                $txnItem = if ($skuRaw -notlike 'Premium*') { $resp.Items | Where-Object { $_.unitOfMeasure -eq '10K' } | Select-Object -First 1 } else { $null }

                if ($item)    { $diskMap[$combo] = [double]$item.retailPrice;    Write-CostLog "Disk price for $combo = $($item.retailPrice)/mo (meterName='$($item.meterName)')" }
                else          { Write-CostLog "Disk WARN: no '1/Month' non-Mount item found for $combo" }
                if ($txnItem) { $txnMap[$combo]  = [double]$txnItem.retailPrice; Write-CostLog "Txn price for $combo = $($txnItem.retailPrice)/10K (from disk response)" }
            } catch { Write-CostLog "Disk ERROR for $combo : $_" }
        }

        Write-CostLog "Fetch done - computeMap: $($computeMap.Count) diskMap: $($diskMap.Count) txnMap: $($txnMap.Count)"

        # Return a single object containing all three result maps.
        # EndInvoke in the tick handler receives this as $result[0].
        return [PSCustomObject]@{ ComputeMap = $computeMap; DiskMap = $diskMap; TxnMap = $txnMap }
    }

    # ── Step 3: Create and open the background runspace ──────────────────────
    # STA apartment state is required for any runspace that may interact with
    # COM objects. ReuseThread keeps the thread alive for the duration of the
    # runspace rather than spinning a new one per pipeline invocation.
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    # Attach the fetch script to the runspace and pass all required parameters.
    # Arguments are positional and must match the param() block order exactly.
    $script:shCostPS = [System.Management.Automation.PowerShell]::Create()
    $script:shCostPS.Runspace = $rs
    # OsType is now embedded in each vmCombo key ("VmSku|Region|OsType") so the
    # fetchScript no longer needs a global UseAHB flag - it reads the type per combo.
    [void]$script:shCostPS.AddScript($fetchScript).AddArgument(@($vmCombos)).AddArgument(@($diskCombos)).AddArgument($script:PricingCurrency).AddArgument($script:PricingCountryCode).AddArgument($script:HoursPerMonth).AddArgument([string]$script:LogFile)

    # ── Step 4: Launch the runspace asynchronously and start the poll timer ───
    # BeginInvoke starts execution immediately on a background thread and returns
    # an IAsyncResult handle. The timer tick handler calls EndInvoke on that
    # handle once IsCompleted becomes $true.
    $script:shCostHandle    = $script:shCostPS.BeginInvoke()
    $script:shCostStartTime = [DateTime]::Now
    $script:shCostTimer.Start()
}

# =============================================================================
# Azure Files cost fetch
#
# Follows the same DispatcherTimer + background runspace pattern as the Session
# Hosts cost fetch above. Pricing config ($script:PricingCurrency etc.) is shared.
#
# Pricing logic:
#   Premium file shares  (sku.name contains 'Premium'):
#     Billed on provisioned quota  -> cost = Quota(GiB) x rate/GiB
#     API product name: "Azure Premium Files"
#
#   Standard file shares (all other SKUs):
#     Billed on consumed (used) capacity -> cost = Used(GiB) x rate/GiB
#     Access tier "Cool"                 -> API product name: "Azure Files Cool"
#     All other tiers (TransactionOptimized, Hot, or blank)
#                                        -> API product name: "Azure Files"
#
#   Replication type (LRS / ZRS / GRS) is extracted from sku.name and used as
#   the skuName filter so pricing matches the storage account's replication config.
#
# Transaction costs (per-operation charges) are NOT included - they depend on
# actual I/O volume which is not available at this point.
# =============================================================================

# DispatcherTimer for Azure Files cost poll - MUST be at script scope (same reason
# as $script:shCostTimer above: tick callbacks need access to $script: variables).
$script:afCostTimer          = New-Object System.Windows.Threading.DispatcherTimer
$script:afCostTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:afCostTimer.Add_Tick({

    # Watchdog: abort if the fetch takes longer than 30 seconds
    if (-not $script:afCostHandle -or -not $script:afCostHandle.IsCompleted) {
        if (([DateTime]::Now - $script:afCostStartTime).TotalSeconds -gt 30) {
            $script:afCostTimer.Stop()
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Files] Timed out after 30s`r`n") } catch {} }
            try { $script:afCostPS.Stop() } catch {}
            try { $script:afCostPS.Runspace.Dispose() } catch {}
            try { $script:afCostPS.Dispose() } catch {}
            $script:afCostPS = $null; $script:afCostHandle = $null
            $script:AFLoadCostsButton.IsEnabled = $true
            $script:AFLoadCostsButton.Content   = 'Load Costs'
            [System.Windows.MessageBox]::Show("Cost fetch timed out.`n`nCheck that prices.azure.com is accessible from this machine.", 'Load Costs Timeout', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        }
        return
    }

    $script:afCostTimer.Stop()
    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Files] Fetch completed - calling EndInvoke`r`n") } catch {} }

    try {
        $result = $script:afCostPS.EndInvoke($script:afCostHandle)
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Files] EndInvoke returned $($result.Count) object(s)`r`n") } catch {} }

        if ($result -and $result.Count -gt 0) {
            $storageMap = $result[0].StorageMap
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Files] Fetch complete - StorageEntries: $($storageMap.Count)`r`n") } catch {} }

            # Build the cost cache keyed by "StorageAccount|Share".
            # For premium shares we use the provisioned quota; for standard shares
            # we use the consumed (used) capacity since that is what Azure bills.
            $script:afCostCache = @{}
            foreach ($r in $script:afCostRowSnap) {
                $comboKey = "$($r.ProductName)|$($r.Replication)|$($r.Region)"
                $rate     = if ($storageMap.ContainsKey($comboKey)) { $storageMap[$comboKey] } else { [double]0 }
                $gib      = if ($r.IsPremium) { $r.QuotaGiB } else { $r.UsedGiB }
                $cost     = if ($rate -gt 0 -and $gib -gt 0) { $rate * $gib } else { [double]0 }
                $script:afCostCache["$($r.StorageAccount)|$($r.Share)"] = @{ Storage = $cost }
            }

            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Files] CacheBuilt: $($script:afCostCache.Count) entries`r`n") } catch {} }

            # Stamp costs onto the live DataTable rows and rebind the grid
            if ($script:afDataTable) {
                foreach ($row in $script:afDataTable.Rows) {
                    $key = "$($row['Storage Account'])|$($row['Share'])"
                    if ($script:afCostCache.ContainsKey($key)) {
                        $c = $script:afCostCache[$key]
                        $row['Storage GBP/mo']   = if ($c.Storage -gt 0) { '{0:F2}' -f $c.Storage } else { '-' }
                        $row['_StorageCostSort'] = $c.Storage
                    }
                }
                $script:FilesGrid.ItemsSource = $script:afDataTable.DefaultView
                _AF_UpdateTotals
            }

            $statusMsg = if ($storageMap.Count -gt 0) {
                "Estimated costs loaded: $($storageMap.Count) storage price(s)"
            } else {
                "Load Costs: no matching prices returned by the API - check storage SKU and region"
            }
            if ($script:FilesStatus) { $script:FilesStatus.Text = $statusMsg }
        }
    } catch {
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Files] ERROR: $_`r`n") } catch {} }
        if ($script:FilesStatus) { $script:FilesStatus.Text = "Load Costs failed: $_" }
        [System.Windows.MessageBox]::Show(
            "Cost fetch failed:`n$_", 'Load Costs Error',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error) | Out-Null
    } finally {
        try { $script:afCostPS.Runspace.Dispose() } catch {}
        try { $script:afCostPS.Dispose() } catch {}
        $script:afCostPS     = $null
        $script:afCostHandle = $null
        $script:AFLoadCostsButton.IsEnabled = $true
        $script:AFLoadCostsButton.Content   = 'Load Costs'
    }
})

function Invoke-AzureFilesCostFetch {
    <#
    .SYNOPSIS
        Fetches estimated monthly storage costs for all Azure File Shares from
        the Azure Retail Prices API and updates the Azure Files grid.

    .DESCRIPTION
        Called when the user clicks "Load Costs" on the Azure Files tab.
        Uses the same DispatcherTimer + background runspace pattern as
        Invoke-SessionHostsCostFetch. No Azure authentication required.

        Pricing is per GiB/month. Premium shares are billed on provisioned
        quota; standard shares are billed on consumed (used) capacity.
        Transaction costs are not included.
    #>

    if (-not $script:afDataTable -or $script:afDataTable.Rows.Count -eq 0) { return }

    $script:AFLoadCostsButton.IsEnabled = $false
    $script:AFLoadCostsButton.Content   = 'Loading...'
    if ($script:FilesStatus) { $script:FilesStatus.Text = 'Fetching storage prices from Azure Retail Prices API...' }
    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Files] Starting price fetch - Currency: $script:PricingCurrency`r`n") } catch {} }

    # Snapshot the unique pricing combos from the current DataTable.
    # combos HashSet: "ProductName|Replication|Region" - one API call per unique combo.
    # afCostRowSnap: full row snapshot so the tick handler can map prices back to shares.
    $combos = [System.Collections.Generic.HashSet[string]]::new()
    $script:afCostRowSnap = @(foreach ($dr in $script:afDataTable.Rows) {
        $skuName    = [string]$dr['_SkuName']       # e.g. "Standard_LRS", "Premium_LRS"
        $accessTier = [string]$dr['_AccessTier']    # e.g. "TransactionOptimized", "Hot", "Cool", "Premium"
        $region     = [string]$dr['Location']

        # Determine replication type from the SKU name (strip the tier prefix)
        $replication = if ($skuName -match '_(.+)$') { $Matches[1] } else { 'LRS' }

        # Map to Azure Retail Prices API product name
        $isPremium  = $skuName -like 'Premium*'
        $productName = if ($isPremium) {
            'Azure Premium Files'
        } elseif ($accessTier -eq 'Cool') {
            'Azure Files Cool'
        } else {
            'Azure Files'
        }

        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Files] Row: SA=$($dr['Storage Account']) Share=$($dr['Share']) _SkuName='$skuName' _AccessTier='$accessTier' Region='$region' -> Product='$productName' Replication='$replication'`r`n") } catch {} }

        [void]$combos.Add("$productName|$replication|$region")

        [PSCustomObject]@{
            StorageAccount = [string]$dr['Storage Account']
            Share          = [string]$dr['Share']
            QuotaGiB       = [double]$dr['Quota (GiB)']
            UsedGiB        = [double]$dr['Used (GiB)']
            Region         = $region
            Replication    = $replication
            ProductName    = $productName
            IsPremium      = $isPremium
        }
    })

    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Files] Snapshot complete - $($script:afCostRowSnap.Count) rows, $($combos.Count) unique combo(s): $(($combos | Sort-Object) -join ' | ')`r`n") } catch {} }
    if ($script:FilesStatus) { $script:FilesStatus.Text = "Fetching prices for $($combos.Count) combo(s)... (enable logging with -EnableLogging for detail)" }

    # Background runspace: one API call per unique ProductName|Replication|Region combo
    $fetchScript = {
        param([string[]]$Combos, [string]$CurrencyCode, [string]$LogFile)

        function Write-CostLog { param($Msg) if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Files] $Msg`r`n") } catch {} } }

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $storageMap = @{}  # "ProductName|Replication|Region" -> rate per GiB/month
        $baseUrl    = "https://prices.azure.com/api/retail/prices?currencyCode=$CurrencyCode&`$filter="

        Write-CostLog "TLS set to 1.2. Combos: $($Combos.Count) Currency: $CurrencyCode"

        foreach ($combo in $Combos) {
            $parts       = $combo.Split('|')
            $productName = $parts[0]   # e.g. "Azure Files", "Azure Premium Files", "Azure Files Cool"
            $replication = $parts[1]   # e.g. "LRS", "ZRS", "GRS"
            $region      = $parts[2]

            try {
                # Fetch all Azure Files capacity items for this region.
                # API product names are "Files v2", "Files", "Premium Files" (not "Azure Files").
                # Unit of measure is "1 GB/Month" (not "1 GiB/Month").
                # skuName format is "Standard LRS", "Premium LRS", "Cool LRS" etc.
                $filter = "contains(productName,'Files') and armRegionName eq '$region' and serviceFamily eq 'Storage' and priceType eq 'Consumption' and unitOfMeasure eq '1 GB/Month'"
                $url    = "$baseUrl$([Uri]::EscapeDataString($filter))"
                Write-CostLog "Storage GET: $url"
                $resp   = Invoke-RestMethod -Uri $url -Method GET -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                Write-CostLog "Storage response: $($resp.Items.Count) item(s)"
                foreach ($i in $resp.Items) { Write-CostLog "  item: productName='$($i.productName)' skuName='$($i.skuName)' price=$($i.retailPrice)" }

                # skuName in the API is "Standard LRS", "Premium LRS", "Cool LRS" etc.
                # Derive the tier prefix from $productName (passed in via the combo key):
                #   "Azure Premium Files" -> "Premium <replication>"
                #   "Azure Files Cool"    -> "Cool <replication>"
                #   "Azure Files"         -> "Standard <replication>"
                $skuTier    = if ($productName -like '*Premium*') { 'Premium' } elseif ($productName -like '*Cool*') { 'Cool' } else { 'Standard' }
                $targetSku  = "$skuTier $replication"   # e.g. "Standard LRS", "Premium LRS", "Cool ZRS"

                # Prefer "Files v2" over legacy "Files" as it is the current product.
                # Exclude Snapshots and Metadata meters - we want the capacity/provisioned rate only.
                # For premium shares the meterName is "Premium LRS Provisioned"; for standard it is
                # "LRS Data Stored", "Hot LRS Data Stored" etc. Snapshots come back first in some
                # regions and would otherwise be picked by Select-Object -First 1.
                $candidates = @($resp.Items | Where-Object { $_.skuName -eq $targetSku -and $_.meterName -notlike '*Snapshot*' -and $_.meterName -notlike '*Metadata*' })
                $item = $candidates | Where-Object { $_.productName -eq 'Files v2' }    | Select-Object -First 1
                if (-not $item) { $item = $candidates | Where-Object { $_.productName -eq 'Files' }       | Select-Object -First 1 }
                if (-not $item) { $item = $candidates                                                      | Select-Object -First 1 }
                if (-not $item) { $item = $resp.Items | Where-Object { $_.meterName -notlike '*Snapshot*' -and $_.meterName -notlike '*Metadata*' } | Select-Object -First 1 }

                if ($item) {
                    $storageMap[$combo] = [double]$item.retailPrice
                    Write-CostLog "Storage price for $combo = $($item.retailPrice)/GB/mo (productName='$($item.productName)' skuName='$($item.skuName)')"
                } else {
                    Write-CostLog "Storage WARN: no matching item found for $combo (targetSku='$targetSku')"
                }
            } catch { Write-CostLog "Storage ERROR for $combo : $_" }
        }

        Write-CostLog "Fetch done - storageMap: $($storageMap.Count)"
        return [PSCustomObject]@{ StorageMap = $storageMap }
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $script:afCostPS = [System.Management.Automation.PowerShell]::Create()
    $script:afCostPS.Runspace = $rs
    [void]$script:afCostPS.AddScript($fetchScript).AddArgument(@($combos)).AddArgument($script:PricingCurrency).AddArgument([string]$script:LogFile)

    $script:afCostHandle    = $script:afCostPS.BeginInvoke()
    $script:afCostStartTime = [DateTime]::Now
    $script:afCostTimer.Start()
}

# =============================================================================
# Infrastructure tab cost fetch
#
# Identical pattern to Invoke-SessionHostsCostFetch - same DispatcherTimer +
# background runspace, same Azure Retail Prices API, same pricing config.
#
# Columns populated:
#   Compute GBP/mo  - Hourly VM rate x HoursPerMonth (0.00 when deallocated)
#   Disk GBP/mo     - Flat monthly managed disk rate
#   Txn GBP/10K     - Per-10K I/O transaction charge (Standard SSD/HDD only)
# =============================================================================

$script:isCostTimer          = New-Object System.Windows.Threading.DispatcherTimer
$script:isCostTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:isCostTimer.Add_Tick({

    if (-not $script:isCostHandle -or -not $script:isCostHandle.IsCompleted) {
        if (([DateTime]::Now - $script:isCostStartTime).TotalSeconds -gt 30) {
            $script:isCostTimer.Stop()
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Infra] Timed out after 30s`r`n") } catch {} }
            try { $script:isCostPS.Stop() } catch {}
            try { $script:isCostPS.Runspace.Dispose() } catch {}
            try { $script:isCostPS.Dispose() } catch {}
            $script:isCostPS = $null; $script:isCostHandle = $null
            $script:ISLoadCostsButton.IsEnabled = $true
            $script:ISLoadCostsButton.Content   = 'Load Costs'
            [System.Windows.MessageBox]::Show("Cost fetch timed out.`n`nCheck that prices.azure.com is accessible from this machine.", 'Load Costs Timeout', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        }
        return
    }

    $script:isCostTimer.Stop()
    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Infra] Fetch completed - calling EndInvoke`r`n") } catch {} }

    try {
        $result = $script:isCostPS.EndInvoke($script:isCostHandle)
        if ($result -and $result.Count -gt 0) {
            $computeMap = $result[0].ComputeMap
            $diskMap    = $result[0].DiskMap
            $txnMap     = $result[0].TxnMap

            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Infra] Fetch complete - ComputeEntries: $($computeMap.Count) DiskEntries: $($diskMap.Count)`r`n") } catch {} }

            $script:isCostCache = @{}
            foreach ($r in $script:isCostRowSnap) {
                # vmKey includes OsType to match the key format used when the price was fetched.
                $vmKey   = "$($r.VmSku)|$($r.Region)|$($r.OsType)"
                $diskKey = "$($r.DiskTier)|$($r.DiskSku)|$($r.Region)"
                $cMo = if ($r.State -eq 'Running' -and $computeMap.ContainsKey($vmKey)) { $computeMap[$vmKey] * $script:HoursPerMonth } else { [double]0 }
                $dMo = if ($diskMap.ContainsKey($diskKey)) { $diskMap[$diskKey] } else { [double]0 }
                $tPr = if ($txnMap.ContainsKey($diskKey))  { $txnMap[$diskKey]  } else { [double]-1 }
                $script:isCostCache[$r.VmName] = @{ Compute = $cMo; Disk = $dMo; Txn = $tPr }
            }

            $statusMsg = if ($computeMap.Count -gt 0 -or $diskMap.Count -gt 0) {
                "Estimated costs loaded: $($computeMap.Count) compute price(s), $($diskMap.Count) disk price(s) (estimated usage: $($script:HoursPerMonth) hrs/mo)"
            } else {
                "Load Costs: no matching prices returned by the API - check VM SKU and region"
            }
            if ($script:ISActionStatus) { $script:ISActionStatus.Text = $statusMsg }

            _IS_UpdateGrid -VmRows $script:infraLastVmRows -Timestamp (Get-Date)

            # ── Phase 5 (Infra): Cost Management - 30-day actual disk transaction charges ──
            #
            # Identical approach to the Session Hosts tab - see that section for full
            # commentary on why Cost Management is used instead of Azure Monitor and how
            # the single-POST batch query works.
            #
            # Premium SSD disks are excluded (Txn stays -1 from the Retail Prices API so
            # Txn -gt 0 is never true for them).  Only Standard SSD and Standard HDD disks
            # have a separate "Disk Operations" billing meter.
            #
            # Required RBAC permission:
            #   Cost Management Reader at subscription scope (or any role that includes
            #   Microsoft.CostManagement/query/action).  Owner / Contributor also satisfy this.
            $isTxnRows = @(foreach ($r in $script:isCostRowSnap) {
                # Include only VMs where the Retail Prices API found a per-10K transaction rate.
                # Also require a known OS disk resource ID stored in _OsDiskResourceId.
                if ($script:isCostCache.ContainsKey($r.VmName) -and $script:isCostCache[$r.VmName].Txn -gt 0 -and $r.OsDiskResourceId) {
                    [PSCustomObject]@{ VmName = $r.VmName; OsDiskResourceId = $r.OsDiskResourceId; TxnRate = $script:isCostCache[$r.VmName].Txn }
                }
            })
            if ($isTxnRows.Count -gt 0) {
                if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Infra] Starting Cost Management txn fetch for $($isTxnRows.Count) Standard SSD/HDD VM(s)`r`n") } catch {} }
                $isTxnFetchScript = [scriptblock]::Create($script:restHelperDef + @'
                    $tok = $args[0]; $rows = $args[1]; $LogFile = $args[2]; $subId = $args[3]
                    $txnMoMap = @{}; $errors = [System.Collections.Generic.List[string]]::new()

                    # Rolling 30-day window ending now (UTC).  Cost Management 'Custom' timeframe
                    # requires dates in yyyy-MM-dd format - time components are not accepted.
                    $end  = [datetime]::UtcNow; $start = $end.AddDays(-30)
                    $from = $start.ToString('yyyy-MM-dd'); $to = $end.ToString('yyyy-MM-dd')

                    # Collect all OS disk resource IDs (already lowercased via .ToLower() in
                    # tab-infrastructure.ps1).  Cost Management returns ResourceId in lowercase
                    # so the comparison is case-insensitive by construction.
                    $diskIds = @($rows | ForEach-Object { $_.OsDiskResourceId })
                    if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost-Infra] Cost Management query: $($diskIds.Count) disk(s), $from to $to`r`n") } catch {} }
                    try {
                        # POST /subscriptions/{sub}/providers/Microsoft.CostManagement/query
                        # API version 2023-11-01.
                        #
                        # filter: restrict to the exact OS disk resource IDs for this tab's VMs.
                        #   'In' is the only supported operator for Dimension filters.
                        #
                        # grouping: ResourceId + Meter gives one row per disk per meter type so
                        #   we can distinguish storage capacity rows from operations rows locally.
                        #   'MeterName' is not a valid filter dimension so we cannot exclude
                        #   non-operations rows at the API level.
                        #
                        # aggregation: sum the Cost column (billed amount in billing currency).
                        $body = @{
                            type       = 'ActualCost'
                            timeframe  = 'Custom'
                            timePeriod = @{ from = $from; to = $to }
                            dataset    = @{
                                granularity = 'None'
                                filter      = @{ dimensions = @{ name = 'ResourceId'; operator = 'In'; values = $diskIds } }
                                grouping    = @(
                                    @{ type = 'Dimension'; name = 'ResourceId' }
                                    @{ type = 'Dimension'; name = 'Meter' }
                                )
                                aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
                            }
                        }
                        $resp = Invoke-Arm -Method POST -Path "/subscriptions/$subId/providers/Microsoft.CostManagement/query" -Token $tok -ApiVersion '2023-11-01' -Body $body -FullResponse

                        # Column order in the response is not guaranteed - find indices by name.
                        $costIdx = -1; $ridIdx = -1; $meterIdx = -1
                        for ($i = 0; $i -lt $resp.properties.columns.Count; $i++) {
                            if ($resp.properties.columns[$i].name -eq 'Cost')       { $costIdx  = $i }
                            if ($resp.properties.columns[$i].name -eq 'ResourceId') { $ridIdx   = $i }
                            if ($resp.properties.columns[$i].name -eq 'Meter')      { $meterIdx = $i }
                        }
                        foreach ($dataRow in @($resp.properties.rows)) {
                            $meter = if ($meterIdx -ge 0) { [string]$dataRow[$meterIdx] } else { 'Operations' }
                            # Skip non-operations meters (e.g. "E10 LRS" storage capacity rows).
                            # Operations meters are named like "E10 LRS Disk Operations".
                            if ($meter -notlike '*Operations*') { continue }
                            $cost = [double]$dataRow[$costIdx]
                            $rid  = ([string]$dataRow[$ridIdx]).ToLower()
                            # Match the response ResourceId back to the VM name.
                            $match = $rows | Where-Object { $_.OsDiskResourceId -eq $rid }
                            if ($match) {
                                # Accumulate in case a disk has multiple operations meter rows.
                                $txnMoMap[$match.VmName] = ($txnMoMap[$match.VmName] -as [double]) + $cost
                                if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost-Infra] $($match.VmName) [$meter]: +$([math]::Round($cost,4)) -> total=$([math]::Round($txnMoMap[$match.VmName],4))`r`n") } catch {} }
                            }
                        }
                        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost-Infra] Done: $($txnMoMap.Count) costed`r`n") } catch {} }
                    } catch {
                        $errors.Add("Cost Management query failed: $_")
                        if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost-Infra] ERROR: $_`r`n") } catch {} }
                    }
                    return [PSCustomObject]@{ TxnMoMap = $txnMoMap; Errors = $errors.ToArray() }
'@)
                $isTxnRs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
                $isTxnRs.ApartmentState = 'STA'; $isTxnRs.ThreadOptions = 'ReuseThread'; $isTxnRs.Open()
                $script:isTxnPS = [System.Management.Automation.PowerShell]::Create()
                $script:isTxnPS.Runspace = $isTxnRs
                [void]$script:isTxnPS.AddScript($isTxnFetchScript).AddArgument($script:armToken).AddArgument($isTxnRows).AddArgument([string]$script:LogFile).AddArgument([string]$script:vmSubId)
                $script:isTxnHandle    = $script:isTxnPS.BeginInvoke()
                $script:isTxnStartTime = [DateTime]::Now
                $script:isTxnCostTimer.Start()
                # Button re-enabled by isTxnCostTimer tick when Cost Management fetch completes
            } else {
                # No Standard SSD/HDD VMs - re-enable button immediately
                if ($script:ISLoadCostsButton) { $script:ISLoadCostsButton.IsEnabled = $true; $script:ISLoadCostsButton.Content = 'Load Costs' }
            }
        }
    } catch {
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Infra] ERROR: $_`r`n") } catch {} }
        if ($script:ISActionStatus) { $script:ISActionStatus.Text = "Load Costs failed: $_" }
        [System.Windows.MessageBox]::Show("Cost fetch failed:`n$_", 'Load Costs Error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        if ($script:ISLoadCostsButton) { $script:ISLoadCostsButton.IsEnabled = $true; $script:ISLoadCostsButton.Content = 'Load Costs' }
    } finally {
        try { $script:isCostPS.Runspace.Dispose() } catch {}
        try { $script:isCostPS.Dispose() } catch {}
        $script:isCostPS     = $null
        $script:isCostHandle = $null
    }
})

# Persistent cache for Infrastructure 30-day transaction cost data (actual billed GBP from Cost Management API).
# Populated by isTxnCostTimer tick handler. Survives auto-refresh cycles so Txn GBP/mo
# values are reapplied by _IS_UpdateGrid without re-querying Cost Management.
$script:isTxnMoCache  = @{}  # VmName -> monthly transaction cost (double)

# DispatcherTimer that polls the Azure Monitor 30-day transaction cost runspace for Infrastructure.
# Fires after the Infrastructure pricing fetch completes - only for Standard SSD/HDD VMs.
$script:isTxnCostTimer          = New-Object System.Windows.Threading.DispatcherTimer
$script:isTxnCostTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:isTxnCostTimer.Add_Tick({
    # ── Watchdog: abort if the Monitor fetch exceeds 60 seconds ──────────────────
    if (-not $script:isTxnHandle -or -not $script:isTxnHandle.IsCompleted) {
        if (([DateTime]::Now - $script:isTxnStartTime).TotalSeconds -gt 60) {
            $script:isTxnCostTimer.Stop()
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost-Infra] Timed out after 60s`r`n") } catch {} }
            try { $script:isTxnPS.Stop() } catch {}
            try { $script:isTxnPS.Runspace.Dispose() } catch {}
            try { $script:isTxnPS.Dispose() } catch {}
            $script:isTxnPS = $null; $script:isTxnHandle = $null
            if ($script:ISLoadCostsButton) { $script:ISLoadCostsButton.IsEnabled = $true; $script:ISLoadCostsButton.Content = 'Load Costs' }
        }
        return
    }

    # ── Monitor fetch complete - collect results and stamp grid ───────────────────
    $script:isTxnCostTimer.Stop()
    try {
        $result = $script:isTxnPS.EndInvoke($script:isTxnHandle)
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost-Infra] Monitor fetch complete - $($result[0].TxnMoMap.Count) VM(s) costed`r`n") } catch {} }
        # Surface any API errors from the scriptblock even when logging is off.
        # Cost Management returns BadRequest for unsupported subscription offer types
        # (e.g. MS-AZR-0036P internal/MSDN subs). In that case retail price costs
        # still loaded fine - show a status bar warning only, not a blocking dialog.
        if ($result -and $result.Count -gt 0 -and $result[0].Errors -and $result[0].Errors.Count -gt 0) {
            $errDetail = $result[0].Errors -join "`n"
            if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost-Infra] Errors from scriptblock:`n$errDetail`r`n") } catch {} }
            $isOfferUnsupported = $errDetail -match 'offer.*not supported|Cost management data is unavailable'
            if ($isOfferUnsupported) {
                # Subscription offer type doesn't support Cost Management - suppress the
                # blocking dialog and just note it in the status bar.
                if ($script:ISActionStatus) { $script:ISActionStatus.Text = 'Txn costs unavailable: subscription offer type not supported by Cost Management' }
            } else {
                if ($script:ISActionStatus) { $script:ISActionStatus.Text = 'Txn cost fetch error - enable logging for details' }
                [System.Windows.MessageBox]::Show("Transaction cost fetch failed:`n$errDetail", 'Txn Cost Error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        }
        if ($result -and $result.Count -gt 0 -and $result[0].TxnMoMap) {
            # Persist costs in cache so auto-refresh can reapply them
            foreach ($kv in $result[0].TxnMoMap.GetEnumerator()) { $script:isTxnMoCache[$kv.Key] = $kv.Value }
            # Stamp Txn GBP/mo and sort key onto the live DataTable rows
            foreach ($row in $script:infraDataTable.Rows) {
                $vm = [string]$row['VM Name']
                if ($script:isTxnMoCache.ContainsKey($vm)) {
                    $mo = $script:isTxnMoCache[$vm]
                    $row['Txn GBP/mo']     = if ($mo -ge 0) { '{0:F2}' -f $mo } else { '-' }
                    $row['_TxnMoCostSort'] = $mo
                }
            }
            # Refresh totals bar to include the new Txn GBP/mo values
            _IS_UpdateTotals
        }
    } catch {
        if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [TxnCost-Infra] ERROR in tick handler: $_`r`n") } catch {} }
    } finally {
        try { $script:isTxnPS.Runspace.Dispose() } catch {}
        try { $script:isTxnPS.Dispose() } catch {}
        $script:isTxnPS = $null; $script:isTxnHandle = $null
        if ($script:ISLoadCostsButton) { $script:ISLoadCostsButton.IsEnabled = $true; $script:ISLoadCostsButton.Content = 'Load Costs' }
    }
})

function Invoke-InfrastructureCostFetch {
    <#
    .SYNOPSIS
        Fetches estimated monthly costs for all Infrastructure VMs from the
        Azure Retail Prices API and updates the Infrastructure grid.
    .DESCRIPTION
        Same pattern as Invoke-SessionHostsCostFetch. No Azure auth required.
        Compute costs use the same AHB/Windows filter as Session Hosts.
        Running state check: 'Running' (not 'Available' as in AVD session hosts).
    #>

    if (-not $script:infraDataTable -or $script:infraDataTable.Rows.Count -eq 0) { return }

    $script:ISLoadCostsButton.IsEnabled = $false
    $script:ISLoadCostsButton.Content   = 'Loading...'
    if ($script:ISActionStatus) { $script:ISActionStatus.Text = 'Fetching prices from Azure Retail Prices API...' }
    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Infra] Starting price fetch - Currency: $script:PricingCurrency AHB: $script:UseAHBPricing`r`n") } catch {} }

    $vmCombos   = [System.Collections.Generic.HashSet[string]]::new()
    $diskCombos = [System.Collections.Generic.HashSet[string]]::new()
    # Infrastructure VMs don't have per-VM OS detection (no imageOffer in infra grid).
    # Use the global config flag to determine OS type for all infra VMs uniformly.
    # $script:UseAHBPricing=$true (Linux rate) when PricingWindowsLicence=$false in config.
    $_infraOsType = if ($script:UseAHBPricing) { 'Linux' } else { 'Windows' }

    $script:isCostRowSnap = @(foreach ($dr in $script:infraDataTable.Rows) {
        [PSCustomObject]@{
            VmName           = [string]$dr['VM Name']
            State            = [string]$dr['Power State']
            VmSku            = [string]$dr['VM SKU']
            Region           = [string]$dr['Region']
            DiskTier         = [string]$dr['_DiskTier']
            DiskSku          = [string]$dr['_DiskSkuRaw']
            OsDiskResourceId = [string]$dr['_OsDiskResourceId']
            # Infrastructure tab uses the same global OS type for all VMs.
            OsType           = $_infraOsType
        }
    })
    foreach ($r in $script:isCostRowSnap) {
        # vmCombos key format mirrors Session Hosts: "VmSku|Region|OsType"
        if ($r.VmSku    -and $r.VmSku    -ne '-') { [void]$vmCombos.Add("$($r.VmSku)|$($r.Region)|$($r.OsType)") }
        if ($r.DiskTier -and $r.DiskTier -ne '')  { [void]$diskCombos.Add("$($r.DiskTier)|$($r.DiskSku)|$($r.Region)") }
    }

    # Infrastructure fetch scriptblock — same logic as Session Hosts.
    # vmCombos key format: "VmSku|Region|OsType" (OsType derived from global config for infra VMs).
    $fetchScript = {
        param([string[]]$VmCombos, [string[]]$DiskCombos, [string]$CurrencyCode, [string]$CountryCode, [int]$HoursPerMonth, [string]$LogFile)

        function Write-CostLog { param($Msg) if ($LogFile) { try { [IO.File]::AppendAllText($LogFile, "[$(Get-Date -Format 'HH:mm:ss')] [CostLookup-Infra] $Msg`r`n") } catch {} } }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $computeMap = @{}; $diskMap = @{}; $txnMap = @{}
        $baseUrl = "https://prices.azure.com/api/retail/prices?currencyCode=$CurrencyCode&`$filter="

        foreach ($combo in $VmCombos) {
            # combo format: "VmSku|Region|OsType" — OsType drives the pricing tier selection.
            # 'Linux' = base/Linux rate (no OS licence); 'Windows' = Windows Server PAYG rate.
            $parts = $combo.Split('|'); $vmSku = $parts[0]; $region = $parts[1]; $osType = $parts[2]
            $useLinuxRate = ($osType -ne 'Windows')
            try {
                # Fetch all VM compute items for this SKU+Region in one call.
                # Windows/Linux selection is done client-side to avoid relying on the 'not' OData
                # operator which is not reliably supported by prices.azure.com.
                $filter = "armSkuName eq '$vmSku' and armRegionName eq '$region' and priceType eq 'Consumption' and serviceFamily eq 'Compute' and contains(productName, 'Virtual Machines')"
                $url  = "$baseUrl$([Uri]::EscapeDataString($filter))"
                Write-CostLog "Compute GET (OsType=$osType): $url"
                $resp = Invoke-RestMethod -Uri $url -Method GET -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                $candidates = @($resp.Items | Where-Object { $_.unitOfMeasure -eq '1 Hour' -and $_.skuName -notlike '*Spot*' -and $_.skuName -notlike '*Low Priority*' })
                $item = if ($useLinuxRate) {
                    $candidates | Where-Object { $_.productName -notlike '*Windows*' } | Select-Object -First 1
                } else {
                    $candidates | Where-Object { $_.productName -like '*Windows*' } | Select-Object -First 1
                }
                if ($item) { $computeMap[$combo] = [double]$item.retailPrice; Write-CostLog "Compute $combo = $($item.retailPrice)/hr (productName='$($item.productName)')" }
                else        { Write-CostLog "Compute WARN: no '1 Hour' item for $combo (useLinux=$useLinuxRate candidates=$($candidates.Count))" }
            } catch { Write-CostLog "Compute ERROR $combo : $_" }
        }

        foreach ($combo in $DiskCombos) {
            $parts = $combo.Split('|'); $tier = $parts[0]; $skuRaw = $parts[1]; $region = $parts[2]
            $productName = switch -Wildcard ($skuRaw) {
                'Premium*'     { 'Premium SSD Managed Disks';  break }
                'StandardSSD*' { 'Standard SSD Managed Disks'; break }
                'Standard*'    { 'Standard HDD Managed Disks'; break }
                default        { '' }
            }
            if (-not $productName) { continue }
            try {
                $filter = "skuName eq '$tier LRS' and armRegionName eq '$region' and serviceFamily eq 'Storage' and productName eq '$productName'"
                $url    = "$baseUrl$([Uri]::EscapeDataString($filter))"
                Write-CostLog "Disk GET: $url"
                $resp   = Invoke-RestMethod -Uri $url -Method GET -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                $item    = $resp.Items | Where-Object { $_.unitOfMeasure -eq '1/Month' -and $_.meterName -notlike '*Mount*' } | Select-Object -First 1
                $txnItem = if ($skuRaw -notlike 'Premium*') { $resp.Items | Where-Object { $_.unitOfMeasure -eq '10K' } | Select-Object -First 1 } else { $null }
                if ($item)    { $diskMap[$combo] = [double]$item.retailPrice;    Write-CostLog "Disk $combo = $($item.retailPrice)/mo (meterName='$($item.meterName)')" }
                if ($txnItem) { $txnMap[$combo]  = [double]$txnItem.retailPrice; Write-CostLog "Txn $combo = $($txnItem.retailPrice)/10K" }
            } catch { Write-CostLog "Disk ERROR $combo : $_" }
        }

        return [PSCustomObject]@{ ComputeMap = $computeMap; DiskMap = $diskMap; TxnMap = $txnMap }
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()

    $script:isCostPS = [System.Management.Automation.PowerShell]::Create()
    $script:isCostPS.Runspace = $rs
    # OsType is embedded in each vmCombo key so no global UseAHB flag is needed.
    [void]$script:isCostPS.AddScript($fetchScript).AddArgument(@($vmCombos)).AddArgument(@($diskCombos)).AddArgument($script:PricingCurrency).AddArgument($script:PricingCountryCode).AddArgument($script:HoursPerMonth).AddArgument([string]$script:LogFile)

    $script:isCostHandle    = $script:isCostPS.BeginInvoke()
    $script:isCostStartTime = [DateTime]::Now
    $script:isCostTimer.Start()
}
