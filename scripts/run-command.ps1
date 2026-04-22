# =============================================================================
# run-command.ps1  -  Run Command engine
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
# =============================================================================
#
# PURPOSE
# -------
# Provides the Run Command picker dialog, background execution via the Azure
# VM Run Command REST API, output display, and a timer-based completion poller.
# Dot-sourced by avd-live-dashboard.ps1 alongside the other module scripts.
#
# ENTRY POINTS
# -------------
# The "Run Command..." context menu item exists in two places:
#   - Session Hosts tab   (tab-sessionhosts.ps1)  -> calls Show-RunCommandPicker
#   - Session Detail grid  (session-detail.ps1)    -> calls Show-RunCommandPicker
# Both pass a VM name and resource group; this module handles everything else.
#
# DATA FLOW
# ---------
# 1. Import-RunCommands loads data\run-commands.psd1 at startup (and on Reload).
#    Commands with a ScriptFile field are resolved from data\runcommands\*.ps1.
# 2. Show-RunCommandPicker presents a list; the user picks one and clicks Run.
# 3. Invoke-SessionHostRunCommand POSTs to the Azure Run Command REST API in a
#    throw-away runspace (non-blocking).
# 4. Invoke-RunCommandTimer is called every second by the master DispatcherTimer.
#    It polls the background job; on completion it updates the picker inline or
#    opens Show-RunCommandOutput if the picker was closed.
#
# FUNCTIONS
# ---------
#   Import-RunCommands              - loads run-commands.psd1 + ScriptFile resolution
#   Show-RunCommandPicker           - modal WPF dialog: choose a predefined command
#   Invoke-SessionHostRunCommand    - fires VM Run Command via REST API in a background runspace
#   Show-RunCommandOutput           - standalone scrollable output window (stdout / stderr)
#   Invoke-RunCommandTimer          - PUBLIC: polls for completion each master timer tick
#
# SHARED SCOPE
# -------------
# This file is dot-sourced, so all $script: variables are shared with the main
# dashboard. It reads $script:vmRgMap, $script:currentSubscriptionId, and calls
# Get-ArmToken (from rest-api-helpers.ps1).
# =============================================================================

# $script:SHRunCommands is an ordered hashtable: Name -> @{ Description; Script; ScriptFile }
# built from the Commands array in the data file, preserving file order.
# Edit data\run-commands.psd1 to add, remove, or reorder entries.

$script:SHRunCommands = [ordered]@{}
# $PSScriptRoot in a dot-sourced script is the scripts\ subdirectory.
# Go up one level to reach the repo root, then into data\.
$script:SHRunCommandsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'data\run-commands.psd1'

function script:Import-RunCommands {
    $script:SHRunCommands = [ordered]@{}
    if (Test-Path $script:SHRunCommandsFile) {
        try {
            $_rcData = & ([scriptblock]::Create([System.IO.File]::ReadAllText($script:SHRunCommandsFile)))
            $_scriptsDir = Join-Path (Split-Path $script:SHRunCommandsFile) 'runcommands'
            foreach ($_cmd in $_rcData.Commands) {
                $_script = $_cmd.Script
                $_scriptFile = $null
                if ($_cmd.ScriptFile) {
                    $_scriptFile = $_cmd.ScriptFile
                    $_path = Join-Path $_scriptsDir $_cmd.ScriptFile
                    if (Test-Path $_path) {
                        $_script = [System.IO.File]::ReadAllText($_path)
                    } else {
                        Write-Warning "run-command: script file not found - $_path"
                        continue
                    }
                }
                $script:SHRunCommands[$_cmd.Name] = @{
                    Description = $_cmd.Description
                    Script      = $_script
                    ScriptFile  = $_scriptFile
                }
            }
        } catch {
            Write-Warning "run-command: could not load run-commands.psd1 - $_"
            Write-Log "ERROR [RunCommand] Failed to load run-commands.psd1 - $_"
        }
    } else {
        Write-Warning "run-command: run-commands.psd1 not found at $($script:SHRunCommandsFile)"
        Write-Log "WARN [RunCommand] run-commands.psd1 not found at $($script:SHRunCommandsFile)"
    }
}
Import-RunCommands

$script:shRunCmdHandle     = $null    # IAsyncResult for a running Run Command job
$script:shRunCmdPS         = $null    # PowerShell instance for the Run Command job
$script:shRunCmdRS         = $null    # throw-away runspace for the Run Command job
$script:shRunCmdVmName     = ''       # VM display name - used in completion status text
$script:shRunCmdName       = ''       # command name   - used in completion status text
$script:shRunCmdPickerOpen       = $false  # $true while the picker window is open
$script:shRunCmdPickerStatusText = $null   # TextBlock ref in open picker (set on Run click)
$script:shRunCmdPickerOutputBox  = $null   # TextBox  ref in open picker (set on Run click)
$script:shRunCmdPickerWin        = $null   # Window   ref for open picker (set on Run click)
$script:rcDotCount               = 0      # animated dots counter for picker progress text


# =============================================================================
# Show-RunCommandPicker        - modal WPF dialog: choose a predefined command
# Invoke-SessionHostRunCommand - fires VM Run Command via REST API in a throw-away runspace
# Show-RunCommandOutput        - scrollable WPF window displaying stdout / stderr
# Invoke-RunCommandTimer       - PUBLIC: polls for completion each master timer tick
# =============================================================================

function Show-RunCommandPicker {
    param([string]$VmName, [string]$RG)

    # Callers may pass the host pool RG; resolve the actual VM RG from vmRgMap.
    # Done here (not in a closure) so $script:vmRgMap is always in scope.
    if ($script:vmRgMap -and $script:vmRgMap.ContainsKey($VmName.ToLower())) {
        $RG = $script:vmRgMap[$VmName.ToLower()]
    }

    # Guard: one Run Command at a time
    if ($script:shRunCmdHandle -and -not $script:shRunCmdHandle.IsCompleted) {
        [System.Windows.MessageBox]::Show(
            "A Run Command is already in progress on $($script:shRunCmdVmName). Please wait for it to complete.",
            'Run Command In Progress',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }

    $script:shRunCmdPickerOpen = $true

    $win = New-Object System.Windows.Window
    $win.Title                  = "Run Command - $VmName"
    $win.Width                  = 720
    $win.Height                 = 480
    $win.MinHeight              = 380
    $win.MinWidth               = 500
    $win.ResizeMode             = 'CanResize'
    $win.WindowStartupLocation  = 'CenterOwner'
    $win.Owner                  = [System.Windows.Application]::Current.MainWindow

    # Wrap in a single-element array so closures capture the reference object,
    # and Reload can swap .Value while all handlers see the update.
    $rcRef    = @{ Commands = $script:SHRunCommands }
    $rcFile   = $script:SHRunCommandsFile
    $outer = New-Object System.Windows.Controls.DockPanel

    # ── Button bar (bottom, docked) ──────────────────────────────────────────
    $btnBar        = New-Object System.Windows.Controls.DockPanel
    $btnBar.Margin = '12,8,12,12'
    [System.Windows.Controls.DockPanel]::SetDock($btnBar, 'Bottom')

    # Left-aligned: Reload button (re-reads run-commands.psd1)
    $btnReload           = New-Object System.Windows.Controls.Button
    $btnReload.Content   = 'Reload Commands'
    $btnReload.Width     = 120
    $btnReload.Height    = 28
    [System.Windows.Controls.DockPanel]::SetDock($btnReload, 'Left')

    # Right-aligned: Close + Run
    $rightBtns                     = New-Object System.Windows.Controls.StackPanel
    $rightBtns.Orientation         = 'Horizontal'
    $rightBtns.HorizontalAlignment = 'Right'

    $btnClose           = New-Object System.Windows.Controls.Button
    $btnClose.Content   = 'Cancel'
    $btnClose.Width     = 80
    $btnClose.Height    = 28
    $btnClose.Margin    = '0,0,8,0'
    $btnClose.IsCancel  = $true
    $btnClose.Add_Click({ $win.Close() })

    $btnRun           = New-Object System.Windows.Controls.Button
    $btnRun.Content   = 'Run Command'
    $btnRun.Width     = 110
    $btnRun.Height    = 28
    $btnRun.IsDefault = $true
    $btnRun.IsEnabled = $false

    [void]$rightBtns.Children.Add($btnClose)
    [void]$rightBtns.Children.Add($btnRun)
    [void]$btnBar.Children.Add($btnReload)
    [void]$btnBar.Children.Add($rightBtns)

    # ── Main content (DockPanel so the output box fills remaining space) ──────
    $content        = New-Object System.Windows.Controls.DockPanel
    $content.Margin = '12,12,12,0'
    $content.LastChildFill = $true

    $lblHeader             = New-Object System.Windows.Controls.TextBlock
    $lblHeader.Text        = "Select a command to run on:  $VmName"
    $lblHeader.FontWeight  = 'SemiBold'
    $lblHeader.Margin      = '0,0,0,2'

    $lblNote            = New-Object System.Windows.Controls.TextBlock
    $lblNote.Text       = 'Note: Commands run in the SYSTEM (computer) context, not as the logged-on user.'
    $lblNote.FontSize   = 11
    $lblNote.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#888')
    $lblNote.FontStyle  = 'Italic'
    $lblNote.Margin     = '0,0,0,10'

    $lblCmd        = New-Object System.Windows.Controls.TextBlock
    $lblCmd.Text   = 'Command:'
    $lblCmd.Margin = '0,0,0,4'

    $listBox                = New-Object System.Windows.Controls.ListBox
    $listBox.Height         = 110
    $listBox.Margin         = '0,0,0,8'
    $listBox.BorderBrush    = [System.Windows.Media.Brushes]::LightGray
    foreach ($name in $rcRef.Commands.Keys) { [void]$listBox.Items.Add($name) }

    $lblDesc        = New-Object System.Windows.Controls.TextBlock
    $lblDesc.Text   = 'Description:'
    $lblDesc.Margin = '0,0,0,4'

    $descBox              = New-Object System.Windows.Controls.TextBox
    $descBox.Height       = 46
    $descBox.IsReadOnly   = $true
    $descBox.TextWrapping = 'Wrap'
    $descBox.Background   = [System.Windows.Media.Brushes]::WhiteSmoke
    $descBox.BorderBrush  = [System.Windows.Media.Brushes]::LightGray
    $descBox.Padding      = '4'

    # ── Status text (shown while running) ────────────────────────────────────
    $statusText              = New-Object System.Windows.Controls.TextBlock
    $statusText.Margin       = '0,10,0,4'
    $statusText.FontWeight   = 'SemiBold'
    $statusText.Foreground   = [System.Windows.Media.Brushes]::DimGray
    $statusText.TextWrapping = 'Wrap'
    $statusText.Visibility   = 'Collapsed'

    # ── Output label + box (shown while running, scrollable) ─────────────────
    $lblOut        = New-Object System.Windows.Controls.TextBlock
    $lblOut.Text   = 'Output:'
    $lblOut.Margin = '0,0,0,4'
    $lblOut.Visibility = 'Collapsed'

    $outputBox                               = New-Object System.Windows.Controls.TextBox
    $outputBox.MinHeight                     = 100
    $outputBox.IsReadOnly                    = $true
    $outputBox.TextWrapping                  = 'NoWrap'
    $outputBox.VerticalScrollBarVisibility   = 'Auto'
    $outputBox.HorizontalScrollBarVisibility = 'Auto'
    $outputBox.FontFamily                    = New-Object System.Windows.Media.FontFamily('Consolas')
    $outputBox.FontSize                      = 11
    $outputBox.Background                    = [System.Windows.Media.Brushes]::WhiteSmoke
    $outputBox.BorderBrush                   = [System.Windows.Media.Brushes]::LightGray
    $outputBox.Padding                       = '6'
    $outputBox.Text                          = '(waiting for output...)'
    $outputBox.Visibility                    = 'Collapsed'

    # Dock all items to Top except outputBox (last child fills remaining space)
    foreach ($ctrl in @($lblHeader, $lblNote, $lblCmd, $listBox, $lblDesc, $descBox, $statusText, $lblOut)) {
        [System.Windows.Controls.DockPanel]::SetDock($ctrl, 'Top')
        [void]$content.Children.Add($ctrl)
    }
    [void]$content.Children.Add($outputBox)

    [void]$outer.Children.Add($btnBar)
    [void]$outer.Children.Add($content)

    $win.Content = $outer

    # When the picker closes, clear all script-scope refs so Invoke-RunCommandTimer
    # falls back to the standalone output window if the job is still running.
    $win.Add_Closed({
        $script:shRunCmdPickerOpen       = $false
        $script:shRunCmdPickerStatusText = $null
        $script:shRunCmdPickerOutputBox  = $null
        $script:shRunCmdPickerWin        = $null
        $script:shRunCmdPickerListBox    = $null
        $script:shRunCmdPickerRunBtn     = $null
        $script:shRunCmdPickerReloadBtn  = $null
    }.GetNewClosure())

    # Reload: re-read run-commands.psd1 and refresh the listbox
    $btnReload.Add_Click({
        $newCmds = [ordered]@{}
        if (Test-Path $rcFile) {
            try {
                $data = & ([scriptblock]::Create([System.IO.File]::ReadAllText($rcFile)))
                $_scriptsDir = Join-Path (Split-Path $rcFile) 'runcommands'
                foreach ($cmd in $data.Commands) {
                    $_script = $cmd.Script; $_sf = $null
                    if ($cmd.ScriptFile) {
                        $_sf = $cmd.ScriptFile
                        $_p = Join-Path $_scriptsDir $cmd.ScriptFile
                        if (Test-Path $_p) { $_script = [System.IO.File]::ReadAllText($_p) } else { continue }
                    }
                    $newCmds[$cmd.Name] = @{ Description = $cmd.Description; Script = $_script; ScriptFile = $_sf }
                }
            } catch {}
        }
        $rcRef.Commands = $newCmds
        $listBox.Items.Clear()
        foreach ($name in $rcRef.Commands.Keys) { [void]$listBox.Items.Add($name) }
        $descBox.Text     = ''
        $btnRun.IsEnabled = $false
        $win.Title        = "Run Command - $VmName  (reloaded)"
    }.GetNewClosure())

    # Update description + enable Run when a command is selected
    $listBox.Add_SelectionChanged({
        if ($listBox.SelectedItem) {
            $descBox.Text     = $rcRef.Commands[$listBox.SelectedItem].Description
            $btnRun.IsEnabled = $true
        } else {
            $descBox.Text     = ''
            $btnRun.IsEnabled = $false
        }
    }.GetNewClosure())

    # Run clicked: start command, expand window, show progress area
    $btnRun.Add_Click({
        $cmdName = $listBox.SelectedItem
        if (-not $cmdName) { return }

        # Disable selection controls
        $listBox.IsEnabled   = $false
        $descBox.IsEnabled   = $false
        $btnRun.IsEnabled    = $false
        $btnReload.IsEnabled = $false
        $btnClose.Content    = 'Close'
        $btnClose.IsCancel   = $true

        # Expand window to fit output area
        $win.Height    = 570
        $win.MinHeight = 400
        $win.ResizeMode = 'CanResize'

        # Show progress and output sections
        $statusText.Text       = "Running '$cmdName'...  (Azure VM Run Commands typically take 1-2 minutes)"
        $statusText.Visibility = 'Visible'
        $lblOut.Visibility     = 'Visible'
        $outputBox.Visibility  = 'Visible'

        # Start the background job
        Invoke-SessionHostRunCommand -VmName $VmName -RG $RG -CommandName $cmdName -Script $rcRef.Commands[$cmdName].Script

    }.GetNewClosure())

    # Set control references at function scope (not inside GetNewClosure) so
    # Invoke-RunCommandTimer can update them directly via the master DispatcherTimer.
    $script:shRunCmdPickerStatusText  = $statusText
    $script:shRunCmdPickerOutputBox   = $outputBox
    $script:shRunCmdPickerWin         = $win
    $script:shRunCmdPickerListBox     = $listBox
    $script:shRunCmdPickerRunBtn      = $btnRun
    $script:shRunCmdPickerReloadBtn   = $btnReload

    $win.ShowDialog() | Out-Null
}

function Invoke-SessionHostRunCommand {
    param([string]$VmName, [string]$RG, [string]$CommandName, [string]$Script)

    $script:shRunCmdVmName = $VmName
    $script:shRunCmdName   = $CommandName

    # REST API Run Command - POST to /runCommand endpoint.
    # The REST API is synchronous (blocks until the command completes and returns output).
    $_subId = if ($script:currentSubscriptionId) { $script:currentSubscriptionId } else { $subscriptionId }

    $runScript = [scriptblock]::Create(@'
        $tok = $args[0]; $subId = $args[1]; $rg = $args[2]; $vmName = $args[3]; $scriptContent = $args[4]
        $scriptLines = @($scriptContent -split "`n" | ForEach-Object { $_.TrimEnd("`r") })
        $bodyJson = ConvertTo-Json @{ commandId = 'RunPowerShellScript'; script = $scriptLines } -Depth 10 -Compress
        $uri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/$vmName/runCommand?api-version=2024-07-01"
        $hdr = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

        # POST returns 202 Accepted (LRO) - must poll the async operation URL for result
        $resp = Invoke-WebRequest -Method POST -Uri $uri -Headers $hdr -Body $bodyJson `
            -UseBasicParsing -ErrorAction Stop

        $result = $null
        if ($resp.StatusCode -eq 200) {
            $result = $resp.Content | ConvertFrom-Json
        }
        elseif ($resp.StatusCode -eq 202) {
            $pollUrl = $null
            if ($resp.Headers['Azure-AsyncOperation']) { $pollUrl = $resp.Headers['Azure-AsyncOperation'] }
            elseif ($resp.Headers['Location'])         { $pollUrl = $resp.Headers['Location'] }

            if ($pollUrl) {
                $pollHdr = @{ Authorization = "Bearer $tok" }
                do {
                    Start-Sleep -Seconds 3
                    $pollResp = Invoke-RestMethod -Uri $pollUrl -Headers $pollHdr -ErrorAction Stop
                } while ($pollResp.status -and $pollResp.status -notin @('Succeeded','Failed','Canceled','Cancelled'))

                if ($pollResp.status -eq 'Succeeded' -and $pollResp.properties.output.value) {
                    $result = $pollResp.properties.output
                } elseif ($pollResp.properties.output) {
                    $result = $pollResp.properties.output
                }
            }
        }

        $stdout = if ($result -and $result.value -and $result.value.Count -gt 0) { [string]$result.value[0].message } else { '' }
        $stderr = if ($result -and $result.value -and $result.value.Count -gt 1) { [string]$result.value[1].message } else { '' }
        [PSCustomObject]@{ Stdout = $stdout.Trim(); Stderr = $stderr.Trim() }
'@)

    $script:shRunCmdRS          = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:shRunCmdRS.Open()
    $script:shRunCmdPS          = [System.Management.Automation.PowerShell]::Create()
    $script:shRunCmdPS.Runspace = $script:shRunCmdRS
    [void]$script:shRunCmdPS.AddScript($runScript).AddArgument((Get-ArmToken)).AddArgument($_subId).AddArgument($RG).AddArgument($VmName).AddArgument($Script)
    $script:shRunCmdHandle      = $script:shRunCmdPS.BeginInvoke()

    # Audit log - record which command was run on which VM
    Write-AuditLog -Action 'RunCommand' -Target $VmName -Details $script:shRunCmdName
}

function Show-RunCommandOutput {
    param([string]$VmName, [string]$CommandName, [string]$Output, [string]$Errors)

    $win = New-Object System.Windows.Window
    $win.Title                 = "Run Command Output - $VmName"
    $win.Width                 = 780
    $win.Height                = 520
    $win.MinWidth              = 500
    $win.MinHeight             = 350
    $win.ResizeMode            = 'CanResizeWithGrip'
    $win.WindowStartupLocation = 'CenterScreen'
    $win.Owner                 = [System.Windows.Application]::Current.MainWindow

    $outer = New-Object System.Windows.Controls.DockPanel

    # ── Close button (bottom) ────────────────────────────────────────────────
    $btnClose                       = New-Object System.Windows.Controls.Button
    $btnClose.Content               = 'Close'
    $btnClose.Width                 = 80
    $btnClose.Height                = 28
    $btnClose.Margin                = '0,8,12,12'
    $btnClose.HorizontalAlignment   = 'Right'
    $btnClose.IsCancel              = $true
    [System.Windows.Controls.DockPanel]::SetDock($btnClose, 'Bottom')
    $btnClose.Add_Click({ $win.Close() })

    # ── Header (top) ─────────────────────────────────────────────────────────
    $header        = New-Object System.Windows.Controls.StackPanel
    $header.Margin = '12,12,12,6'
    [System.Windows.Controls.DockPanel]::SetDock($header, 'Top')

    $hdr1             = New-Object System.Windows.Controls.TextBlock
    $hdr1.Text        = "VM: $VmName"
    $hdr1.FontWeight  = 'SemiBold'
    $hdr1.Margin      = '0,0,0,2'

    $hdr2             = New-Object System.Windows.Controls.TextBlock
    $hdr2.Text        = "Command: $CommandName"
    $hdr2.Foreground  = [System.Windows.Media.Brushes]::DimGray

    [void]$header.Children.Add($hdr1)
    [void]$header.Children.Add($hdr2)

    # ── Output text box (fills remaining space) ──────────────────────────────
    $displayText = if ([string]::IsNullOrWhiteSpace($Output) -and [string]::IsNullOrWhiteSpace($Errors)) {
        '(No output returned)'
    } else {
        $parts = @()
        if (-not [string]::IsNullOrWhiteSpace($Output)) { $parts += $Output.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($Errors))  { $parts += "--- Errors ---`n$($Errors.Trim())" }
        $parts -join "`n`n"
    }

    $textBox                                  = New-Object System.Windows.Controls.TextBox
    $textBox.IsReadOnly                       = $true
    $textBox.TextWrapping                     = 'Wrap'
    $textBox.VerticalScrollBarVisibility      = 'Auto'
    $textBox.HorizontalScrollBarVisibility    = 'Disabled'
    $textBox.FontFamily                       = New-Object System.Windows.Media.FontFamily('Consolas')
    $textBox.FontSize                         = 11
    $textBox.Margin                           = '12,0,12,0'
    $textBox.Padding                          = '6'
    $textBox.Background                       = [System.Windows.Media.Brushes]::WhiteSmoke
    $textBox.BorderBrush                      = [System.Windows.Media.Brushes]::LightGray
    $textBox.Text                             = $displayText

    [void]$outer.Children.Add($header)
    [void]$outer.Children.Add($btnClose)
    [void]$outer.Children.Add($textBox)

    $win.Content = $outer
    $win.ShowDialog() | Out-Null
}

function Invoke-RunCommandTimer {
    # Polls the Run Command background job each master-timer tick (every second).
    # When the picker window is open, updates its controls directly.
    # When the picker is closed, shows the standalone output window.
    if (-not $script:shRunCmdHandle) { return }

    if (-not $script:shRunCmdHandle.IsCompleted) {
        # Still running — animate dots inside the output box; status text stays static
        if ($script:shRunCmdPickerOpen -and $script:shRunCmdPickerOutputBox) {
            $script:rcDotCount = (($script:rcDotCount + 1) % 4)
            $script:shRunCmdPickerOutputBox.Text = "(waiting for output...)`n$('.' * ($script:rcDotCount + 1))"
        }
        return
    }

    # Job completed — collect result then update UI
    try {
        $raw = @($script:shRunCmdPS.EndInvoke($script:shRunCmdHandle))
        $out = if ($raw.Count -gt 0 -and $null -ne $raw[0]) { [string]$raw[0].Stdout } else { '' }
        $err = if ($raw.Count -gt 0 -and $null -ne $raw[0]) { [string]$raw[0].Stderr } else { '' }

        $displayText = if ([string]::IsNullOrWhiteSpace($out) -and [string]::IsNullOrWhiteSpace($err)) {
            '(No output returned)'
        } else {
            $parts = @()
            if (-not [string]::IsNullOrWhiteSpace($out)) { $parts += $out.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($err))  { $parts += "--- Errors ---`n$($err.Trim())" }
            $parts -join "`n`n"
        }

        if ($script:shRunCmdPickerOpen -and $script:shRunCmdPickerOutputBox) {
            # Picker is open — update it inline and re-enable controls
            $script:shRunCmdPickerOutputBox.Text        = $displayText
            $script:shRunCmdPickerStatusText.Text       = "Completed '$($script:shRunCmdName)' on $($script:shRunCmdVmName)."
            $script:shRunCmdPickerStatusText.Foreground = [System.Windows.Media.Brushes]::DarkGreen
            $script:shRunCmdPickerWin.Title             = "Run Command - Done"
            # Re-enable list, Run and Reload buttons so the user can select another command
            $script:shRunCmdPickerListBox.IsEnabled   = $true
            $script:shRunCmdPickerRunBtn.IsEnabled    = ($null -ne $script:shRunCmdPickerListBox.SelectedItem)
            $script:shRunCmdPickerReloadBtn.IsEnabled = $true
        } else {
            # Picker closed — show standalone output window
            Show-RunCommandOutput -VmName $script:shRunCmdVmName -CommandName $script:shRunCmdName -Output $out -Errors $err
        }
    } catch {
        # Log the error to file for diagnostics, then update UI
        Write-Log "ERROR [RunCommand] '$($script:shRunCmdName)' on $($script:shRunCmdVmName) failed: $_"
        if ($script:shRunCmdPickerOpen -and $script:shRunCmdPickerStatusText) {
            $script:shRunCmdPickerOutputBox.Text        = "Error: $_"
            $script:shRunCmdPickerStatusText.Text       = "Error running '$($script:shRunCmdName)' on $($script:shRunCmdVmName)."
            $script:shRunCmdPickerStatusText.Foreground = [System.Windows.Media.Brushes]::DarkRed
            $script:shRunCmdPickerListBox.IsEnabled   = $true
            $script:shRunCmdPickerRunBtn.IsEnabled    = ($null -ne $script:shRunCmdPickerListBox.SelectedItem)
            $script:shRunCmdPickerReloadBtn.IsEnabled = $true
        }
    } finally {
        try { $script:shRunCmdPS.Dispose() } catch {}
        try { $script:shRunCmdRS.Dispose() } catch {}
        $script:shRunCmdHandle = $null
        $script:shRunCmdPS     = $null
        $script:shRunCmdRS     = $null
    }
}
