#
# Azure authentication helper - dot-sourced by avd-live-dashboard.ps1 and profile-tools.ps1.
# Provides Connect-AzureDashboard: a single function that handles all four auth modes.
#
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
#

function Connect-AzureDashboard {
    <#
    .SYNOPSIS
        Authenticates to Azure and returns an Az context object.

    .DESCRIPTION
        Wraps Connect-AzAccount with support for four authentication modes:
          - Interactive browser (default)
          - Device code flow       (-UseDeviceAuthentication)
          - Existing Az context    (-UseExistingContext)
          - Service principal      (-UseServicePrincipal)

        On success returns the Az context. On failure shows an error dialog and
        calls exit 1 so the calling script terminates cleanly.

    .PARAMETER TenantId
        Azure AD tenant ID to authenticate against. Pass '' to use the default.

    .PARAMETER SubscriptionId
        Subscription to activate after sign-in. Pass '' to use the default.

    .PARAMETER UseDeviceAuthentication
        Use device code flow instead of interactive browser.

    .PARAMETER UseExistingContext
        Skip Connect-AzAccount and reuse whatever Az context is already active.

    .PARAMETER UseServicePrincipal
        Authenticate non-interactively using a stored App ID + Client Secret.
        Requires TenantId. Credential is DPAPI-encrypted in AppData.

    .PARAMETER CredentialTag
        Suffix appended to the SP credential filename so each config file gets
        its own stored credential. Pass the config basename (e.g. 'prod').
        Default 'config' maps to sp-credential.xml (backward-compatible).

    .PARAMETER LogCallback
        Optional scriptblock called with a single string for log/trace output.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialTag',
        Justification = 'CredentialTag is a config file basename used to derive a filename, not a secret value.')]
    param(
        [string]  $TenantId                 = '',
        [string]  $SubscriptionId           = '',
        [switch]  $UseDeviceAuthentication,
        [switch]  $UseExistingContext,
        [switch]  $UseServicePrincipal,
        [string]  $CredentialTag            = 'config',
        [scriptblock] $LogCallback          = $null
    )

    function _Log { param([string]$m); if ($LogCallback) { & $LogCallback $m } }

    # -------------------------------------------------------------------------
    # Helper: SP credential prompt (WPF dialog)
    # -------------------------------------------------------------------------
    function Invoke-SPCredentialPrompt {
        $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Service Principal Credentials" Width="430" Height="260"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        ShowInTaskbar="False">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" TextWrapping="Wrap" Margin="0,0,0,10"
                   Text="Enter the App (Client) ID and Client Secret for the service principal. The credential is encrypted with your Windows account (DPAPI) and saved to AppData."/>
        <Label Grid.Row="1" Content="App (Client) ID:" FontWeight="SemiBold" Padding="0,0,0,2"/>
        <TextBox Grid.Row="2" Name="AppIdBox" Margin="0,0,0,8" Padding="4,3" FontFamily="Consolas"/>
        <Label Grid.Row="3" Content="Client Secret:" FontWeight="SemiBold" Padding="0,0,0,2"/>
        <PasswordBox Grid.Row="4" Name="SecretBox" Margin="0,0,0,4" Padding="4,3"/>
        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="OkBtn" Content="Save and Connect" Width="120" Height="28" Margin="0,0,8,0" IsDefault="True"/>
            <Button Name="CancelBtn" Content="Cancel" Width="70" Height="28" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
'@
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $_win   = [System.Windows.Markup.XamlReader]::Load($reader)

        $_win.FindName('OkBtn').Add_Click({
            $a = $_win.FindName('AppIdBox').Text.Trim()
            $s = $_win.FindName('SecretBox').Password
            if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($s)) {
                [System.Windows.MessageBox]::Show(
                    "Both App ID and Client Secret are required.",
                    "Missing Fields",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning) | Out-Null
                return
            }
            $script:_spPromptAppId  = $a
            $script:_spPromptSecret = $s
            $_win.DialogResult = $true
            $_win.Close()
        })

        if ($_win.ShowDialog()) {
            return [pscustomobject]@{ AppId = $script:_spPromptAppId; Secret = $script:_spPromptSecret }
        }
        return $null
    }

    # -------------------------------------------------------------------------
    # Mode: UseExistingContext
    # -------------------------------------------------------------------------
    if ($UseExistingContext) {
        _Log "[Auth] Mode: UseExistingContext"
        try   { $ctx = Get-AzContext -ErrorAction Stop } catch { $ctx = $null }

        if ($ctx -and $ctx.Account) {
            _Log "[Auth] Existing context: $($ctx.Account.Id) | Tenant: $($ctx.Tenant.Id)"

            if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
                _Log "[Auth] Switching to subscription: $SubscriptionId"
                try {
                    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
                    $ctx = Get-AzContext
                    _Log "[Auth] Switched to: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
                } catch {
                    _Log "[Auth] WARNING - subscription switch failed: $_"
                }
            }
            return $ctx
        }

        # Az token cache is per-process; child processes (e.g. Profile Tools launched
        # from the dashboard) may have no cached context even though the parent does.
        # Fall through to interactive browser auth rather than failing silently.
        _Log "[Auth] No existing context found - falling back to interactive browser auth"
    }

    # -------------------------------------------------------------------------
    # Mode: UseDeviceAuthentication
    # -------------------------------------------------------------------------
    if ($UseDeviceAuthentication) {
        _Log "[Auth] Mode: DeviceAuthentication | TenantId: $TenantId | SubId: $SubscriptionId"
        try {
            $_p = @{ UseDeviceAuthentication = $true; ErrorAction = 'Stop' }
            if (-not [string]::IsNullOrWhiteSpace($TenantId))      { $_p['TenantId']      = $TenantId      }
            if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) { $_p['SubscriptionId'] = $SubscriptionId }
            _Log "[Auth] Calling Connect-AzAccount (device code)..."
            $ctx = (Connect-AzAccount @_p).Context
            if (-not $ctx -or -not $ctx.Account) {
                _Log "[Auth] Connect-AzAccount returned no context"
                [System.Windows.MessageBox]::Show("Sign-in did not complete. Please try again.",
                    "Sign-In Failed", [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Error) | Out-Null
                exit 1
            }
            _Log "[Auth] Sign-in OK: $($ctx.Account.Id) | Sub: $($ctx.Subscription.Name)"
        } catch {
            _Log "[Auth] ERROR - device sign-in failed: $_"
            [System.Windows.MessageBox]::Show("Sign-in failed:`n`n$_", "Sign-In Failed",
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
            exit 1
        }
        return $ctx
    }

    # -------------------------------------------------------------------------
    # Mode: UseServicePrincipal
    # -------------------------------------------------------------------------
    if ($UseServicePrincipal) {
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            [System.Windows.MessageBox]::Show(
                "Azure.TenantId is not set in config.psd1.`n`nService Principal authentication requires a Tenant ID. Please add it and relaunch.",
                "Service Principal - Missing Tenant ID",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error) | Out-Null
            exit 1
        }

        $_credFile = if ($CredentialTag -eq 'config') { 'sp-credential.xml' } else { "sp-credential-$CredentialTag.xml" }
        $_credPath = Join-Path $env:APPDATA "AVDDashboard\$_credFile"

        $_spCred = $null
        if (Test-Path $_credPath) {
            try {
                $_spCred = Import-Clixml $_credPath -ErrorAction Stop
            } catch {
                _Log "[Auth] SP credential load failed from '$_credPath': $_"
                [System.Windows.MessageBox]::Show(
                    "The saved service principal credential could not be loaded:`n`n$_`n`nYou will be prompted to re-enter it.",
                    "Credential Load Failed",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning) | Out-Null
                $_spCred = $null
            }
        }

        if (-not $_spCred) {
            $_input = Invoke-SPCredentialPrompt
            if (-not $_input) { exit 0 }

            $_spCred = [System.Management.Automation.PSCredential]::new(
                $_input.AppId,
                (ConvertTo-SecureString $_input.Secret -AsPlainText -Force)
            )

            $_credDir = Split-Path $_credPath -Parent
            if (-not (Test-Path $_credDir)) { New-Item -ItemType Directory -Path $_credDir -Force | Out-Null }

            try {
                $_spCred | Export-Clixml $_credPath -Force -ErrorAction Stop
            } catch {
                _Log "[Auth] SP credential save failed to '$_credPath': $_"
                [System.Windows.MessageBox]::Show(
                    "Warning: Credential could not be saved:`n`n$_`n`nYou will be prompted again on next launch.",
                    "Credential Save Warning",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        }

        _Log "[Auth] Mode: ServicePrincipal | TenantId: $TenantId | AppId: $($_spCred.UserName)"
        try {
            $_p = @{
                ServicePrincipal = $true
                TenantId         = $TenantId
                Credential       = $_spCred
                ErrorAction      = 'Stop'
            }
            if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) { $_p['SubscriptionId'] = $SubscriptionId }
            _Log "[Auth] Calling Connect-AzAccount (service principal)..."
            $ctx = (Connect-AzAccount @_p).Context
            if (-not $ctx -or -not $ctx.Account) {
                _Log "[Auth] Connect-AzAccount returned no context"
                [System.Windows.MessageBox]::Show("Service principal sign-in did not complete. Please try again.",
                    "Sign-In Failed", [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Error) | Out-Null
                exit 1
            }
            _Log "[Auth] SP sign-in OK: $($ctx.Account.Id) | Sub: $($ctx.Subscription.Name)"
        } catch {
            _Log "[Auth] ERROR - SP sign-in failed: $_"
            $_retry = [System.Windows.MessageBox]::Show(
                "Service principal sign-in failed:`n`n$_`n`nWould you like to clear the saved credential so you can re-enter it on next launch?",
                "Sign-In Failed",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Error)
            if ($_retry -eq 'Yes' -and (Test-Path $_credPath)) {
                Remove-Item $_credPath -Force
                [System.Windows.MessageBox]::Show(
                    "Saved credential cleared. Relaunch to enter new credentials.",
                    "Credential Cleared",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information) | Out-Null
            }
            exit 1
        }
        return $ctx
    }

    # -------------------------------------------------------------------------
    # Mode: Interactive browser (default)
    # -------------------------------------------------------------------------
    _Log "[Auth] Mode: Interactive browser | TenantId: $TenantId | SubId: $SubscriptionId"
    try {
        $_p = @{ ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($TenantId))      { $_p['TenantId']      = $TenantId      }
        if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) { $_p['SubscriptionId'] = $SubscriptionId }
        _Log "[Auth] Calling Connect-AzAccount (interactive)..."
        $ctx = (Connect-AzAccount @_p).Context
        if (-not $ctx -or -not $ctx.Account) {
            _Log "[Auth] Connect-AzAccount returned no context"
            [System.Windows.MessageBox]::Show("Sign-in did not complete. Please try again.",
                "Sign-In Failed", [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error) | Out-Null
            exit 1
        }
        _Log "[Auth] Sign-in OK: $($ctx.Account.Id) | Sub: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
    } catch {
        _Log "[Auth] ERROR - interactive sign-in failed: $_"
        [System.Windows.MessageBox]::Show("Sign-in failed:`n`n$_", "Sign-In Failed",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        exit 1
    }
    return $ctx
}
