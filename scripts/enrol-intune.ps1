<#
.SYNOPSIS
    Experimental: Assigns a system-managed identity to an Azure VM and installs the
    AADLoginForWindows extension to enrol it with Microsoft Intune (multi-session).

.NOTES
    Invoked by the Images tab "Intune Enrol [Experimental]" right-click action.
    ARM token and REST helpers are passed via environment variables by the caller.
#>

$WarningPreference     = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# Load ARM helpers (passed as content by caller, or dot-sourced directly for standalone use)
$restHelperDef = $env:REST_HELPER_DEF
if ($restHelperDef) {
    . ([scriptblock]::Create($restHelperDef))
} else {
    . (Join-Path $PSScriptRoot 'rest-api-helpers.ps1')
}

$Token  = $env:ARM_TOKEN
if (-not $Token) { throw 'ARM_TOKEN environment variable is not set.' }
$SubId  = $env:SUBSCRIPTION_ID
if (-not $SubId) { throw 'SUBSCRIPTION_ID environment variable is not set.' }

$VMName     = $env:VM_NAME
$RG         = $env:RESOURCE_GROUP
$Location   = $env:LOCATION
$computeApi = '2024-07-01'
$vmBase     = "/subscriptions/$SubId/resourceGroups/$RG/providers/Microsoft.Compute/virtualMachines"

Write-Host "== Intune Enrolment [Experimental] - Multi Session: $VMName =="
Write-Host "   Resource Group : $RG"
Write-Host "   Location       : $Location"
Write-Host ('-' * 60)

# ==========================================
# Step 1 - Assign system-managed identity
# ==========================================
Write-Host
Write-Host "$(Get-Date -Format HH:mm:ss) Step 1: Assigning system-managed identity to $VMName..."
$idBody = @{ identity = @{ type = 'SystemAssigned' } }
$vm = Invoke-Arm -Method PATCH -Path "$vmBase/$VMName" -Token $Token -ApiVersion $computeApi -Body $idBody -FullResponse
Write-Host "$(Get-Date -Format HH:mm:ss) Identity assigned."
$principalId = $vm.identity.principalId
if ($principalId) { Write-Host "  Principal ID: $principalId" }

# ==========================================
# Step 2 - Install AADLoginForWindows extension (multi-session)
# ==========================================
Write-Host
Write-Host "$(Get-Date -Format HH:mm:ss) Step 2: Installing AADLoginForWindows extension (multi-session)..."
Write-Host "  Publisher         : Microsoft.Azure.ActiveDirectory"
Write-Host "  Version           : 2.2"
Write-Host "  mdmId             : 0000000a-0000-0000-c000-000000000000"
Write-Host "  multiSessionEnabled: true"
$Token   = Get-ArmToken
$extPath = "$vmBase/$VMName/extensions/AADLoginForWindows"
$extBody = @{
    location   = $Location
    properties = @{
        publisher               = 'Microsoft.Azure.ActiveDirectory'
        type                    = 'AADLoginForWindows'
        typeHandlerVersion      = '2.2'
        autoUpgradeMinorVersion = $true
        settings                = @{
            mdmId               = '0000000a-0000-0000-c000-000000000000'
            multiSessionEnabled = $true
        }
    }
}
Invoke-Arm -Method PUT -Path $extPath -Token $Token -ApiVersion $computeApi -Body $extBody -FullResponse | Out-Null
Write-Host "$(Get-Date -Format HH:mm:ss) Extension PUT submitted - polling for completion..."

$sw = [Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 15
    $Token = Get-ArmToken
    $ext   = Invoke-Arm -Path $extPath -Token $Token -ApiVersion $computeApi -FullResponse
    $state = $ext.properties.provisioningState
    Write-Host "$(Get-Date -Format HH:mm:ss) Extension state: $state  ($([math]::Round($sw.Elapsed.TotalMinutes, 1)) min elapsed)"
    if ($sw.Elapsed.TotalMinutes -gt 20) { throw "Extension install timed out after 20 minutes" }
} while ($state -notin @('Succeeded', 'Failed'))

if ($state -eq 'Failed') {
    $errMsg = ($ext.properties.instanceView.statuses |
                Where-Object { $_.code -like 'ProvisioningState/*' } |
                Select-Object -ExpandProperty message -ErrorAction SilentlyContinue) -join ' '
    throw "AADLoginForWindows extension install failed: $errMsg"
}

Write-Host
Write-Host "$(Get-Date -Format HH:mm:ss) Intune enrolment complete."
