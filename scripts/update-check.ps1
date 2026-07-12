<#
.SYNOPSIS
    Manifest-based auto-update for the AVD Dashboard and Profile Tools.
.DESCRIPTION
    Fetches update-manifest.json (path + sha256 + size per shipped file) from the public
    GitHub repo, diffs it against local file hashes, and - only for files that actually
    changed - downloads, validates, and applies the update. Designed to fail completely
    silently when the manifest is unreachable (private repo, offline, DNS failure, etc.):
    no message box, ever, from that path. See tools\New-UpdateManifest.ps1 for how the
    manifest is generated, and AUTO-UPDATE.md for the full design.

    Downloads are pinned to a single commit: the check first resolves the current HEAD sha
    of main via the GitHub API (which is not behind the raw-content CDN cache), then fetches
    the manifest and every file from immutable raw.githubusercontent.com/<repo>/<sha>/ URLs.
    This makes CDN caching harmless and guarantees the manifest and files all come from the
    same commit even if a push lands mid-update.
.NOTES
    Author : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
#>

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$script:DashboardUpdateRawRoot = 'https://raw.githubusercontent.com/virtualwebber/AVD-Dashboard'
$script:DashboardUpdateApiUrl  = 'https://api.github.com/repos/virtualwebber/AVD-Dashboard/commits/main'

function Get-DashboardRemoteCommitSha {
    <#
    .SYNOPSIS
        Resolves the current HEAD commit sha of main via the GitHub API.
        Returns $null on any failure - never throws.
    #>
    param([scriptblock]$LogCallback)
    function _Log([string]$m) { if ($LogCallback) { & $LogCallback $m } }

    try {
        $resp = Invoke-WebRequest -Uri $script:DashboardUpdateApiUrl -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop
        $sha = ("$($resp.Content)".TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop).sha
        if ($sha -match '^[0-9a-f]{40}$') { return $sha }
        _Log "Update check: API returned an unrecognised sha '$sha'"
        return $null
    } catch {
        # Rate-limited, blocked, or offline - callers fall back to the branch URL.
        _Log "Update check: commit sha lookup failed - $($_.Exception.Message)"
        return $null
    }
}

function Get-DashboardUpdateManifest {
    <#
    .SYNOPSIS
        Downloads and parses update-manifest.json. Returns $null on any failure - never throws.
    #>
    param(
        [Parameter(Mandatory)][string]$ManifestUrl,
        [scriptblock]$LogCallback
    )
    function _Log([string]$m) { if ($LogCallback) { & $LogCallback $m } }

    try {
        $resp = Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop
        # Strip a stray leading UTF-8 BOM character if present - ConvertFrom-Json rejects it
        # as an invalid JSON primitive rather than ignoring it.
        $rawContent = "$($resp.Content)".TrimStart([char]0xFEFF)
        $manifest = $rawContent | ConvertFrom-Json -ErrorAction Stop
        if (-not $manifest.files) {
            _Log "Update check: manifest has no 'files' entry - ignoring"
            return $null
        }
        return $manifest
    } catch {
        _Log "Update check: manifest unreachable - $($_.Exception.Message)"
        return $null
    }
}

function Get-DashboardChangedFiles {
    <#
    .SYNOPSIS
        Returns the subset of manifest entries whose local file is missing or hashes differently.
    #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $changed = @()
    foreach ($entry in @($Manifest.files)) {
        if (-not $entry.path -or -not $entry.sha256) { continue }
        $localPath = Join-Path $RepoRoot $entry.path
        $localHash = $null
        if (Test-Path -LiteralPath $localPath -PathType Leaf) {
            try { $localHash = (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash } catch {}
        }
        if (-not $localHash -or $localHash -ne $entry.sha256) {
            $changed += $entry
        }
    }
    return @($changed)
}

function Complete-DashboardPendingUpdate {
    <#
    .SYNOPSIS
        Finishes an update whose files could not be overwritten while the previous process
        had them locked (in practice: lib\*.dll). The updater writes those as <file>.new;
        this swaps them into place. Must be called at startup BEFORE anything loads the
        lib DLLs (Add-Type), so the swap happens while nothing holds them open.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [scriptblock]$LogCallback
    )
    function _Log([string]$m) { if ($LogCallback) { & $LogCallback $m } }

    try {
        # Normalize (resolves 8.3 short names, relative paths, trailing slashes) so the
        # Substring below cuts the true relative path out of Get-ChildItem's long FullName.
        $RepoRoot = (Get-Item -LiteralPath $RepoRoot).FullName.TrimEnd('\', '/')
        $pending = Get-ChildItem -Path $RepoRoot -Recurse -Filter '*.new' -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -eq '.new' -and $_.FullName -notmatch '\\(\.git|logs|backup)\\' }
        foreach ($p in @($pending)) {
            $dest = $p.FullName.Substring(0, $p.FullName.Length - 4)
            try {
                if (Test-Path -LiteralPath $dest) {
                    # Same backup\<relative path> layout as Install-DashboardUpdate.
                    $bak = Join-Path (Join-Path $RepoRoot 'backup') ($dest.Substring($RepoRoot.Length).TrimStart('\', '/'))
                    $bakParent = Split-Path $bak -Parent
                    if (-not (Test-Path -LiteralPath $bakParent)) {
                        New-Item -ItemType Directory -Path $bakParent -Force | Out-Null
                    }
                    Move-Item -LiteralPath $dest -Destination $bak -Force -ErrorAction Stop
                }
                Move-Item -LiteralPath $p.FullName -Destination $dest -Force -ErrorAction Stop
                _Log "Update check: completed pending swap of $dest"
            } catch {
                _Log "Update check: pending swap of $dest failed - $($_.Exception.Message)"
            }
        }
    } catch {}
}

function Show-DashboardUpdatePrompt {
    <#
    .SYNOPSIS
        Modal prompt listing changed files with Update / Not now buttons. Returns $true/$false.
    .NOTES
        Deliberately styled with static colours rather than the dashboard's DynamicResource
        theme keys: this can be shown before the theme dictionary is loaded (the automatic
        startup check runs ahead of the main window), so it can't depend on it being ready.
    #>
    param(
        [Parameter(Mandatory)][string]$LocalVersion,
        [Parameter(Mandatory)][string]$RemoteVersion,
        [Parameter(Mandatory)]$ChangedFiles,
        [string]$Notes,
        [string]$IconPath,
        $OwnerWindow
    )

    $fileListText = (@($ChangedFiles) | ForEach-Object { $_.path } | Sort-Object) -join "`n"

    $xamlRaw = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Update Available"
    SizeToContent="Height" Width="460"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterScreen"
    Background="#FFFFFF"
    Foreground="#1F1F1F"
    FontFamily="Segoe UI">
    <DockPanel Margin="24,20,24,18">
        <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <TextBlock x:Name="UpdTitle" Text="An update is available" FontSize="16" FontWeight="Bold" Foreground="#0078D4"/>
            <TextBlock x:Name="UpdVersionText" FontSize="12" Foreground="#5F6368" Margin="0,4,0,0"/>
        </StackPanel>

        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="UpdSkipBtn" Content="Not now" Width="90" Height="32" Margin="0,0,8,0"
                    Background="Transparent" Foreground="#1F1F1F" BorderBrush="#C8C8C8" BorderThickness="1" Cursor="Hand"/>
            <Button x:Name="UpdApplyBtn" Content="Update" Width="90" Height="32"
                    Background="#0078D4" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
        </StackPanel>

        <TextBlock x:Name="UpdNotesLabel" DockPanel.Dock="Top" Text="What's new:" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,4"/>
        <Border x:Name="UpdNotesBorder" DockPanel.Dock="Top" Background="#F5F5F5" BorderBrush="#C8C8C8" BorderThickness="1" CornerRadius="6" Padding="10,8" MaxHeight="150" Margin="0,0,0,10">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="UpdNotes" FontSize="11" TextWrapping="Wrap" Foreground="#333333"/>
            </ScrollViewer>
        </Border>

        <TextBlock DockPanel.Dock="Top" Text="Changed files:" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,4"/>
        <Border Background="#F5F5F5" BorderBrush="#C8C8C8" BorderThickness="1" CornerRadius="6" Padding="10,8" MaxHeight="180">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="UpdFileList" FontSize="11" FontFamily="Consolas" TextWrapping="NoWrap" Foreground="#333333"/>
            </ScrollViewer>
        </Border>
    </DockPanel>
</Window>
'@

    [xml]$xamlDoc = $xamlRaw
    $reader = New-Object System.Xml.XmlNodeReader $xamlDoc
    $win = [System.Windows.Markup.XamlReader]::Load($reader)
    if ($OwnerWindow) { $win.Owner = $OwnerWindow }
    if ($IconPath -and (Test-Path -LiteralPath $IconPath) -and (Get-Command Set-WindowIcon -ErrorAction SilentlyContinue)) {
        try { Set-WindowIcon -Window $win -IconPath $IconPath } catch {}
    }

    # Same release version but different file hashes = a hotfix build pushed without a
    # version bump; word it so "Current: X  New: X" doesn't look like a bug.
    if ($LocalVersion -eq $RemoteVersion) {
        $win.FindName('UpdTitle').Text       = 'An updated build is available'
        $win.FindName('UpdVersionText').Text = "Updated build of $RemoteVersion (files changed since your copy)"
    } else {
        $win.FindName('UpdVersionText').Text = "Current: $LocalVersion   New: $RemoteVersion"
    }
    $win.FindName('UpdFileList').Text = $fileListText

    if ("$Notes".Trim()) {
        $win.FindName('UpdNotes').Text = "$Notes".Trim()
    } else {
        $win.FindName('UpdNotesLabel').Visibility  = 'Collapsed'
        $win.FindName('UpdNotesBorder').Visibility = 'Collapsed'
    }

    $script:_dashUpdChoice = $false
    $win.FindName('UpdApplyBtn').Add_Click({ $script:_dashUpdChoice = $true; $win.Close() })
    $win.FindName('UpdSkipBtn').Add_Click({ $script:_dashUpdChoice = $false; $win.Close() })
    $win.ShowDialog() | Out-Null
    return [bool]$script:_dashUpdChoice
}

function Show-DashboardUpdateProgress {
    <#
    .SYNOPSIS
        Small non-modal "Downloading update..." window. Returns the window (caller updates
        the UpdProgText TextBlock and closes it), or $null if it can't be shown.
    #>
    param([string]$IconPath)

    $xamlRaw = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Updating"
    SizeToContent="Height" Width="400"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterScreen"
    WindowStyle="ToolWindow"
    Background="#FFFFFF"
    Foreground="#1F1F1F"
    FontFamily="Segoe UI">
    <StackPanel Margin="24,20,24,20">
        <TextBlock Text="Downloading update" FontSize="14" FontWeight="Bold" Foreground="#0078D4"/>
        <TextBlock x:Name="UpdProgText" FontSize="12" Foreground="#5F6368" Margin="0,8,0,0" TextWrapping="Wrap"/>
    </StackPanel>
</Window>
'@

    try {
        [xml]$xamlDoc = $xamlRaw
        $reader = New-Object System.Xml.XmlNodeReader $xamlDoc
        $win = [System.Windows.Markup.XamlReader]::Load($reader)
        if ($IconPath -and (Test-Path -LiteralPath $IconPath) -and (Get-Command Set-WindowIcon -ErrorAction SilentlyContinue)) {
            try { Set-WindowIcon -Window $win -IconPath $IconPath } catch {}
        }
        $win.Show()
        return $win
    } catch {
        return $null
    }
}

function Invoke-DashboardApplyUpdate {
    <#
    .SYNOPSIS
        Downloads all changed files to a temp folder, validates every one, and only then
        replaces the live files, rolling back from the copies in backup\ if any replacement
        fails partway. Files locked by the running process (lib DLLs) are written as
        <file>.new for Complete-DashboardPendingUpdate to swap on the post-update relaunch.
        Returns $true/$false; on failure $script:_updApplyFailureDetail carries the reason.
    #>
    param(
        [Parameter(Mandatory)]$ChangedFiles,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BaseRawUrl,
        [string]$IconPath,
        [scriptblock]$LogCallback
    )
    function _Log([string]$m) { if ($LogCallback) { & $LogCallback $m } }

    $script:_updApplyFailureDetail = 'Nothing was changed - see the log for details.'
    $stageDir = Join-Path ([IO.Path]::GetTempPath()) ("avd-dashboard-update-$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    $staged  = @{}
    $applied = @()   # each: @{ Dest = <live path>; Bak = <backup path or $null (file was new)> }
    $pendingWritten = @()

    $prog = Show-DashboardUpdateProgress -IconPath $IconPath
    function _Prog([string]$t) {
        if ($prog) {
            try {
                $prog.FindName('UpdProgText').Text = $t
                $prog.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
            } catch {}
        }
    }

    try {
        # -- Stage: download + validate everything before touching a single live file ------
        $i = 0
        $total = @($ChangedFiles).Count
        foreach ($entry in @($ChangedFiles)) {
            $i++
            $relPath = $entry.path
            _Prog "File $i of ${total}:`n$relPath"
            $url = "$BaseRawUrl/$relPath"
            $stagePath = Join-Path $stageDir $relPath
            $stageParent = Split-Path $stagePath -Parent
            if ($stageParent -and -not (Test-Path -LiteralPath $stageParent)) {
                New-Item -ItemType Directory -Path $stageParent -Force | Out-Null
            }

            Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -OutFile $stagePath -ErrorAction Stop

            $info = Get-Item -LiteralPath $stagePath
            if ($info.Length -eq 0) { throw "downloaded '$relPath' is empty" }

            $ext = [IO.Path]::GetExtension($relPath).ToLowerInvariant()
            if ($ext -eq '.ps1' -or $ext -eq '.psd1') {
                $tokens = $null; $parseErrors = $null
                [System.Management.Automation.Language.Parser]::ParseFile($stagePath, [ref]$tokens, [ref]$parseErrors) | Out-Null
                if ($parseErrors -and $parseErrors.Count) {
                    throw "'$relPath' failed to parse: $($parseErrors[0].Message)"
                }
            } elseif ($ext -eq '.xaml') {
                try { [xml](Get-Content -LiteralPath $stagePath -Raw) | Out-Null }
                catch { throw "'$relPath' is not well-formed XML: $($_.Exception.Message)" }
            }

            $stagedHash = (Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash
            if ($stagedHash -ne $entry.sha256) {
                throw "'$relPath' hash mismatch after download (expected $($entry.sha256), got $stagedHash)"
            }

            $staged[$relPath] = $stagePath
        }

        # -- Apply: back up + replace, tracking what changed so a failure can roll back ----
        _Prog 'Applying files...'
        foreach ($relPath in $staged.Keys) {
            $destPath = Join-Path $RepoRoot $relPath
            $destParent = Split-Path $destPath -Parent
            if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
                New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            }

            $destExists = Test-Path -LiteralPath $destPath

            # Locked destination (a DLL the current process has loaded): stage next to it as
            # .new instead; Complete-DashboardPendingUpdate swaps it in on the relaunch,
            # before anything has loaded it.
            $locked = $false
            if ($destExists) {
                try {
                    $fs = [IO.File]::Open($destPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
                    $fs.Close()
                } catch { $locked = $true }
            }

            if ($locked) {
                Copy-Item -LiteralPath $staged[$relPath] -Destination "$destPath.new" -Force -ErrorAction Stop
                $pendingWritten += "$destPath.new"
                _Log "Update check: '$relPath' is in use - staged as .new for swap on relaunch"
                continue
            }

            $bakPath = $null
            if ($destExists) {
                # Backup must succeed before the overwrite, or rollback would be impossible.
                # Backups live under backup\<relative path> rather than as .bak files strewn
                # next to the live ones; each update overwrites the backup of the files it
                # changes, so the folder always holds the pre-update version of every file.
                $bakPath = Join-Path (Join-Path $RepoRoot 'backup') $relPath
                $bakParent = Split-Path $bakPath -Parent
                if (-not (Test-Path -LiteralPath $bakParent)) {
                    New-Item -ItemType Directory -Path $bakParent -Force | Out-Null
                }
                Copy-Item -LiteralPath $destPath -Destination $bakPath -Force -ErrorAction Stop
            }
            Copy-Item -LiteralPath $staged[$relPath] -Destination $destPath -Force -ErrorAction Stop
            $applied += @{ Dest = $destPath; Bak = $bakPath }
        }

        $doneMsg = "Update check: applied $(@($applied).Count) changed file(s)"
        if (@($pendingWritten).Count) { $doneMsg += " ($(@($pendingWritten).Count) pending swap on relaunch)" }
        _Log $doneMsg
        return $true
    } catch {
        _Log "Update check: aborted - $($_.Exception.Message)"

        # Roll back everything that was already replaced, and remove any .new files from
        # this run so a later launch can't half-apply an aborted update.
        $restoreFailed = @()
        foreach ($a in $applied) {
            try {
                if ($a.Bak) { Copy-Item -LiteralPath $a.Bak -Destination $a.Dest -Force -ErrorAction Stop }
                else        { Remove-Item -LiteralPath $a.Dest -Force -ErrorAction Stop }
            } catch { $restoreFailed += $a.Dest }
        }
        foreach ($p in $pendingWritten) {
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        }

        if (@($restoreFailed).Count) {
            $script:_updApplyFailureDetail = "Rollback could not restore these files - they may be inconsistent (a pre-update copy of each is in the 'backup' folder):`n" + ($restoreFailed -join "`n")
            _Log "Update check: rollback FAILED for $(@($restoreFailed).Count) file(s): $($restoreFailed -join ', ')"
        } elseif (@($applied).Count) {
            $script:_updApplyFailureDetail = 'Nothing was changed (all files were rolled back) - see the log for details.'
            _Log "Update check: rolled back $(@($applied).Count) file(s)"
        }
        return $false
    } finally {
        if ($prog) { try { $prog.Close() } catch {} }
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Restart-DashboardProcess {
    <#
    .SYNOPSIS
        Relaunches $ScriptPath via powershell.exe, re-passing the original bound parameters.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$BoundParameters = @{}
    )
    # -WindowStyle Hidden mirrors the .cmd launchers, which hide the console via a vbs shim;
    # without it an update applied from a hidden-console launch would pop a console window.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $ScriptPath + '"'))
    foreach ($key in $BoundParameters.Keys) {
        $val = $BoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter] -or $val -is [bool]) {
            if ([bool]$val) { $argList += "-$key" }
        } else {
            $argList += "-$key"
            $argList += ('"' + $val + '"')
        }
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList
}

function Show-DashboardMessageDialog {
    <#
    .SYNOPSIS
        General-purpose modal message dialog styled to match the update prompt (static
        colours, so it works before the host app's theme dictionary is loaded - e.g. during
        sign-in). Optional -Detail text goes in a scrollable monospace box for technical
        error content. Falls back to a native MessageBox if the WPF window can't be built.
    .OUTPUTS
        Buttons OK          -> nothing
        Buttons YesNo       -> [bool]   ($false on X/Esc)
        Buttons YesNoCancel -> 'Yes' | 'No' | 'Cancel'  ('Cancel' on X/Esc)
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Heading = '',
        [string]$Title = 'AVD Dashboard',
        [string]$Detail = '',
        [ValidateSet('Information', 'Warning', 'Error')][string]$Icon = 'Information',
        [ValidateSet('OK', 'YesNo', 'YesNoCancel')][string]$Buttons = 'OK',
        [string]$IconPath,
        $OwnerWindow
    )

    $xamlRaw = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="AVD Dashboard"
    SizeToContent="Height" Width="440"
    ResizeMode="NoResize"
    WindowStartupLocation="CenterScreen"
    Background="#FFFFFF"
    Foreground="#1F1F1F"
    FontFamily="Segoe UI">
    <DockPanel Margin="24,20,24,18">
        <TextBlock x:Name="MsgHeading" DockPanel.Dock="Top" FontSize="16" FontWeight="Bold" Foreground="#0078D4" TextWrapping="Wrap" Margin="0,0,0,10"/>
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
            <Button x:Name="MsgCancelBtn" Content="Cancel" Width="90" Height="32" Margin="0,0,8,0" Visibility="Collapsed"
                    Background="Transparent" Foreground="#1F1F1F" BorderBrush="#C8C8C8" BorderThickness="1" Cursor="Hand"/>
            <Button x:Name="MsgNoBtn" Content="No" Width="90" Height="32" Margin="0,0,8,0" Visibility="Collapsed"
                    Background="Transparent" Foreground="#1F1F1F" BorderBrush="#C8C8C8" BorderThickness="1" Cursor="Hand"/>
            <Button x:Name="MsgYesBtn" Content="Yes" Width="90" Height="32" Visibility="Collapsed"
                    Background="#0078D4" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
            <Button x:Name="MsgOkBtn" Content="OK" Width="90" Height="32" IsDefault="True" IsCancel="True"
                    Background="#0078D4" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
        </StackPanel>
        <Border x:Name="MsgDetailBorder" DockPanel.Dock="Bottom" Background="#F5F5F5" BorderBrush="#C8C8C8" BorderThickness="1" CornerRadius="6" Padding="10,8" MaxHeight="150" Margin="0,10,0,0">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="MsgDetail" FontSize="11" FontFamily="Consolas" TextWrapping="Wrap" Foreground="#333333"/>
            </ScrollViewer>
        </Border>
        <TextBlock x:Name="MsgBody" FontSize="12" TextWrapping="Wrap" Foreground="#333333"/>
    </DockPanel>
</Window>
'@

    try {
        [xml]$xamlDoc = $xamlRaw
        $reader = New-Object System.Xml.XmlNodeReader $xamlDoc
        $win = [System.Windows.Markup.XamlReader]::Load($reader)
        if ($OwnerWindow) { $win.Owner = $OwnerWindow }
        if ($IconPath -and (Test-Path -LiteralPath $IconPath) -and (Get-Command Set-WindowIcon -ErrorAction SilentlyContinue)) {
            try { Set-WindowIcon -Window $win -IconPath $IconPath } catch {}
        }

        $win.Title = $Title
        $headingColour = switch ($Icon) {
            'Error'   { '#C42B1C' }
            'Warning' { '#9D5D00' }
            default   { '#0078D4' }
        }
        $headingTb = $win.FindName('MsgHeading')
        $headingTb.Text = if ("$Heading".Trim()) { $Heading } else { $Title }
        $headingTb.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($headingColour))
        $win.FindName('MsgBody').Text = $Message

        if ("$Detail".Trim()) {
            $win.FindName('MsgDetail').Text = "$Detail".Trim()
        } else {
            $win.FindName('MsgDetailBorder').Visibility = 'Collapsed'
        }

        # Closing via X/Esc leaves the default: $false for YesNo, 'Cancel' for YesNoCancel.
        $script:_dashMsgChoice = if ($Buttons -eq 'YesNoCancel') { 'Cancel' } else { $false }
        if ($Buttons -eq 'OK') {
            $win.FindName('MsgOkBtn').Add_Click({ $win.Close() })
        } else {
            $okBtn  = $win.FindName('MsgOkBtn');  $okBtn.Visibility = 'Collapsed'; $okBtn.IsDefault = $false; $okBtn.IsCancel = $false
            $yesBtn = $win.FindName('MsgYesBtn'); $yesBtn.Visibility = 'Visible';  $yesBtn.IsDefault = $true
            $noBtn  = $win.FindName('MsgNoBtn');  $noBtn.Visibility  = 'Visible'
            $yesBtn.Add_Click({ $script:_dashMsgChoice = if ($Buttons -eq 'YesNo') { $true } else { 'Yes' }; $win.Close() })
            $noBtn.Add_Click({  $script:_dashMsgChoice = if ($Buttons -eq 'YesNo') { $false } else { 'No' }; $win.Close() })
            if ($Buttons -eq 'YesNoCancel') {
                $cancelBtn = $win.FindName('MsgCancelBtn'); $cancelBtn.Visibility = 'Visible'; $cancelBtn.IsCancel = $true
                $cancelBtn.Add_Click({ $script:_dashMsgChoice = 'Cancel'; $win.Close() })
            } else {
                $noBtn.IsCancel = $true   # Esc = No
            }
        }
        $win.ShowDialog() | Out-Null
        if ($Buttons -eq 'YesNo')       { return [bool]$script:_dashMsgChoice }
        if ($Buttons -eq 'YesNoCancel') { return [string]$script:_dashMsgChoice }
    } catch {
        $img = switch ($Icon) {
            'Error'   { [System.Windows.MessageBoxImage]::Error }
            'Warning' { [System.Windows.MessageBoxImage]::Warning }
            default   { [System.Windows.MessageBoxImage]::Information }
        }
        $btnEnum = switch ($Buttons) {
            'YesNo'       { [System.Windows.MessageBoxButton]::YesNo }
            'YesNoCancel' { [System.Windows.MessageBoxButton]::YesNoCancel }
            default       { [System.Windows.MessageBoxButton]::OK }
        }
        $full = if ("$Detail".Trim()) { "$Message`n`n$Detail" } else { $Message }
        $res = [System.Windows.MessageBox]::Show($full, $Title, $btnEnum, $img)
        if ($Buttons -eq 'YesNo')       { return ($res -eq [System.Windows.MessageBoxResult]::Yes) }
        if ($Buttons -eq 'YesNoCancel') {
            if ($res -eq [System.Windows.MessageBoxResult]::Yes) { return 'Yes' }
            if ($res -eq [System.Windows.MessageBoxResult]::No)  { return 'No' }
            return 'Cancel'
        }
    }
}

function Show-DashboardInfoDialog {
    <#
    .SYNOPSIS
        Shows an info/warning message using the host app's themed Show-ThemedDialog if it's
        been defined yet, falling back to a plain native MessageBox otherwise (e.g. the
        automatic pre-auth check runs before either script has reached its own definition).
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Information', 'Warning')][string]$Icon = 'Information',
        $OwnerWindow
    )
    $cmd = Get-Command Show-ThemedDialog -ErrorAction SilentlyContinue
    if ($cmd) {
        $params = @{ Message = $Message; Icon = $Icon }
        if ($OwnerWindow -and $cmd.Parameters.ContainsKey('Owner')) { $params['Owner'] = $OwnerWindow }
        Show-ThemedDialog @params | Out-Null
    } else {
        Show-DashboardMessageDialog -Message $Message -Icon $Icon -OwnerWindow $OwnerWindow
    }
}

function Invoke-DashboardUpdateCheck {
    <#
    .SYNOPSIS
        Orchestrates a full update check: resolve HEAD sha, fetch manifest, diff, prompt,
        apply, relaunch. Fails completely silently (log line only, no UI) whenever the
        manifest can't be reached - that's the routine case whenever the source repo is
        private - except for a -Manual check, which always gets a response.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$BoundParameters = @{},
        [switch]$SkipUpdateCheck,
        [switch]$Manual,
        [string]$IconPath,
        $OwnerWindow,
        [scriptblock]$LogCallback
    )
    function _Log([string]$m) { if ($LogCallback) { & $LogCallback $m } }

    if ($SkipUpdateCheck) {
        _Log 'Update check: skipped (-SkipUpdateCheck)'
        return
    }

    try {
        # Pin everything to one commit so the manifest and files can't disagree, and so the
        # raw CDN's ~5 minute branch-URL cache can't serve a stale mix after a push.
        $sha = Get-DashboardRemoteCommitSha -LogCallback $LogCallback
        $baseRawUrl = if ($sha) { "$script:DashboardUpdateRawRoot/$sha" } else { "$script:DashboardUpdateRawRoot/main" }

        $manifest = Get-DashboardUpdateManifest -ManifestUrl "$baseRawUrl/update-manifest.json" -LogCallback $LogCallback
        if (-not $manifest) {
            # Unreachable - private repo, offline, DNS failure, etc. The automatic startup
            # check stays completely silent (this is routine while the repo is private), but
            # a manual click always gets a response - otherwise the button looks broken.
            if ($Manual) {
                Show-DashboardInfoDialog -Message 'Could not check for updates right now.' -OwnerWindow $OwnerWindow
            }
            return
        }

        $changed = Get-DashboardChangedFiles -Manifest $manifest -RepoRoot $RepoRoot
        if (@($changed).Count -eq 0) {
            _Log "Update check: up to date (local $CurrentVersion, remote $($manifest.version))"
            if ($Manual) {
                Show-DashboardInfoDialog -Message "You're running the latest version ($CurrentVersion)." -OwnerWindow $OwnerWindow
            }
            return
        }

        _Log "Update check: $(@($changed).Count) changed file(s) available (local $CurrentVersion, remote $($manifest.version))"
        $accepted = Show-DashboardUpdatePrompt -LocalVersion $CurrentVersion -RemoteVersion $manifest.version -ChangedFiles $changed -Notes "$($manifest.notes)" -IconPath $IconPath -OwnerWindow $OwnerWindow
        if (-not $accepted) {
            _Log 'Update check: user chose Not now'
            return
        }

        $applied = Invoke-DashboardApplyUpdate -ChangedFiles $changed -RepoRoot $RepoRoot -BaseRawUrl $baseRawUrl -IconPath $IconPath -LogCallback $LogCallback
        if (-not $applied) {
            Show-DashboardInfoDialog -Message "The update could not be applied. $script:_updApplyFailureDetail" -Icon Warning -OwnerWindow $OwnerWindow
            return
        }

        _Log "Update check: updated to $($manifest.version) - relaunching"
        Restart-DashboardProcess -ScriptPath $ScriptPath -BoundParameters $BoundParameters
        exit 0
    } catch {
        _Log "Update check: skipped due to error - $($_.Exception.Message)"
    }
}
