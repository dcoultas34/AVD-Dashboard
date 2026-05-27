<#
.SYNOPSIS
    Create-Image.ps1 - Builds and seals an AVD preparation VM, publishes it to the
    Shared Image Gallery, monitors gallery replication, and cleans up afterwards.

.DESCRIPTION
    Full AVD gold image pipeline using direct ARM REST API (no Az PowerShell required).
    Authentication token is passed via the ARM_TOKEN environment variable by the caller
    (avd-live-dashboard.ps1). All Azure operations use Invoke-Arm from rest-api-helpers.ps1.

    Stage 1 - Preparation VM Build
      - Stops the gold image VM
      - Takes a snapshot backup
      - Removes any existing preparation VM (with retry logic for disk/NIC cleanup)
      - Creates a new preparation VM from the snapshot
      - Runs BIS-F sealing and Sysprep (if extension enabled)
      - Waits for the VM to shut down and deallocate

    Stage 2 - Generalise and Gallery
      - Generalises the VM
      - Submits a new image version to the Shared Image Gallery
      - Polls until ProvisioningState = Succeeded

    Stage 3 - Cleanup
      - Removes the preparation VM, OS disk, NIC, and snapshot

.NOTES
    Version : 2026-04-30
    Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
#>

$WarningPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# ==========================================
# Inject Invoke-Arm helper (passed as env var by the dashboard)
# ==========================================
$restHelperDef = $env:REST_HELPER_DEF
if ($restHelperDef) {
    . ([scriptblock]::Create($restHelperDef))
} else {
    # Fallback: dot-source rest-api-helpers.ps1 directly (standalone use)
    . (Join-Path $PSScriptRoot 'rest-api-helpers.ps1')
}

# ==========================================
# Auth token
# ==========================================
$Token = $env:ARM_TOKEN
if (-not $Token) { throw 'ARM_TOKEN environment variable is not set. Cannot authenticate to Azure REST API.' }

$SubId = $env:SUBSCRIPTION_ID
if (-not $SubId) { throw 'SUBSCRIPTION_ID environment variable is not set.' }

# ==========================================
# Default Variables
# ==========================================
$ImageStorageAccountType = 'Standard_LRS'
$ImageReplicaCount       = 1
$BisfTimeoutMinutes      = 15
$SysprepTimeoutMinutes   = if ($env:TIMEOUTINMINUTES) { [int]$env:TIMEOUTINMINUTES } else { 35 }

# ==========================================
# Job Variables
# ==========================================
Write-Host '== Setting Variables =='

$extension                  = $env:EXTENSION
Write-Host "BIS-F Extension: $extension"
$ResourceGroupName          = $env:IMAGE_RG_NAME
Write-Host "ResourceGroupName: $ResourceGroupName"
$Location                   = $env:LOCATION
Write-Host "Location: $Location"
$NicResourceGroupName       = $env:NET_RG_NAME
Write-Host "NicResourceGroupName: $NicResourceGroupName"
$vNetName                   = $env:VNET_NAME
Write-Host "vNetName: $vNetName"
$SubnetName                 = $env:SUBNET_NAME
$GoldVM                   = $env:IMAGE_VM_NAME
Write-Host "GoldVM: $GoldVM"
$galleryName                = $env:GALLERY_NAME
Write-Host "GalleryName: $galleryName"
$galleryRG                  = $env:GALLERY_RG_NAME
Write-Host "GalleryRG: $galleryRG"
$galleryImageDefinitionName = $env:IMAGE_DEF_NAME
Write-Host "GalleryImageDefinitionName: $galleryImageDefinitionName"
$PrepVMSize                 = $env:PrepVMSize
Write-Host "PrepVMSize: $PrepVMSize"
$BisFPath                   = if ($env:BISF_PATH) { $env:BISF_PATH } else { 'C:\_source\Bis-F' }
Write-Host "BisFPath: $BisFPath"

$PrepVmName   = $GoldVM + '_Prep'
$Now          = Get-Date -UFormat '%Y%m%d_%H%M'
$snapshotName = $GoldVM + "_$Now"
Write-Host "SnapshotName: $snapshotName"

# ARM path prefixes
$vmBase       = "/subscriptions/$SubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines"
$diskBase     = "/subscriptions/$SubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/disks"
$snapBase     = "/subscriptions/$SubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/snapshots"
$galleryBase  = "/subscriptions/$SubId/resourceGroups/$galleryRG/providers/Microsoft.Compute/galleries/$galleryName"

$computeApi = '2024-03-01'
$diskApi    = '2023-10-02'
$netApi     = '2023-09-01'
$galleryApi = '2023-07-03'

# Target replica regions for the gallery image version - built from config via env vars
$arrLocations = @()
$r1 = $env:REPLICATION_REGION1; $r1c = if ($env:REPLICATION_REGION1_REPLICAS) { [int]$env:REPLICATION_REGION1_REPLICAS } else { 1 }
$r2 = $env:REPLICATION_REGION2; $r2c = if ($env:REPLICATION_REGION2_REPLICAS) { [int]$env:REPLICATION_REGION2_REPLICAS } else { 1 }
if ($r1) { $arrLocations += @{ name = $r1; regionalReplicaCount = $r1c; storageAccountType = 'Standard_LRS' } }
if ($r2) { $arrLocations += @{ name = $r2; regionalReplicaCount = $r2c; storageAccountType = 'Standard_LRS' } }
if ($arrLocations.Count -eq 0) { throw 'No replication regions configured. Set ReplicationRegion1 in config.' }


# ==========================================
# STAGE 1 - Stop Gold VM and Snapshot
# ==========================================

Write-Host
Write-Host "$(Get-Date -Format HH:mm:ss) Stopping and deallocating gold image VM: $GoldVM"
$null = Invoke-Arm -Method POST -Path "$vmBase/$GoldVM/deallocate" -Token $Token -ApiVersion $computeApi -FullResponse
Wait-VMPowerState -SubscriptionId $SubId -ResourceGroup $ResourceGroupName -VMName $GoldVM -Expected 'PowerState/deallocated' -Token $Token -TimeoutSeconds 300

# Get gold VM to find OS disk ID
$goldVmObj  = Invoke-Arm -Path "$vmBase/$GoldVM" -Token $Token -ApiVersion $computeApi -FullResponse
$osDiskId     = $goldVmObj.properties.storageProfile.osDisk.managedDisk.id

Write-Host
Write-Host "$(Get-Date -Format HH:mm:ss) Taking snapshot backup: $snapshotName"
$snapBody = @{
    location = $Location
    properties = @{
        creationData = @{
            createOption     = 'Copy'
            sourceResourceId = $osDiskId
        }
        encryptionSettingsCollection = @{ enabled = $false }
    }
}
$null = Invoke-Arm -Method PUT -Path "$snapBase/$snapshotName" -Token $Token -ApiVersion $diskApi -Body $snapBody -FullResponse
# Poll snapshot until provisioned
$sw = [Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 10
    $snap = Invoke-Arm -Path "$snapBase/$snapshotName" -Token $Token -ApiVersion $diskApi -FullResponse
    Write-Host "  Snapshot state: $($snap.properties.provisioningState) ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
} while ($snap.properties.provisioningState -ne 'Succeeded' -and $sw.Elapsed.TotalSeconds -lt 300)
if ($snap.properties.provisioningState -ne 'Succeeded') { throw "Snapshot $snapshotName did not provision in time" }
$snapshotId = $snap.id

# ==========================================
# Remove existing Prep VM if present
# ==========================================

$existingPrepVM = $null
try { $existingPrepVM = Invoke-Arm -Path "$vmBase/$PrepVmName" -Token $Token -ApiVersion $computeApi -FullResponse } catch {}

if ($existingPrepVM) {
    Write-Host "$(Get-Date -Format HH:mm:ss) Removing existing preparation VM: $PrepVmName"

    $exDiskName = $existingPrepVM.properties.storageProfile.osDisk.name
    $exNicId    = $existingPrepVM.properties.networkProfile.networkInterfaces[0].id
    $exNicName  = $exNicId -split '/' | Select-Object -Last 1

    Write-Host "  Deleting VM"
    Invoke-Arm -Method DELETE -Path "$vmBase/$PrepVmName" -Token $Token -ApiVersion $computeApi -FullResponse | Out-Null

    # Wait for VM to disappear
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 10
        $check = $null
        try { $check = Invoke-Arm -Path "$vmBase/$PrepVmName" -Token $Token -ApiVersion $computeApi -FullResponse } catch {}
        Write-Host "  Waiting for VM deletion... ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
    } while ($check -and $sw.Elapsed.TotalSeconds -lt 180)
    if ($check) { throw "VM $PrepVmName still exists after 3 minutes" }

    # Remove OS disk with retry
    Write-Host "  Removing OS disk: $exDiskName"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-Arm -Method DELETE -Path "$diskBase/$exDiskName" -Token $Token -ApiVersion $diskApi -FullResponse | Out-Null
            Write-Host "  Disk removed"
            break
        } catch {
            Write-Host "  Disk removal attempt $attempt failed: $_"
            if ($attempt -eq 3) { throw "Failed to remove disk $exDiskName after 3 attempts" }
            Start-Sleep -Seconds 15
        }
    }

    # Remove NIC with retry
    Write-Host "  Removing NIC: $exNicName"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-Arm -Method DELETE -Path "/subscriptions/$SubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/networkInterfaces/$exNicName" -Token $Token -ApiVersion $netApi -FullResponse | Out-Null
            Write-Host "  NIC removed"
            break
        } catch {
            Write-Host "  NIC removal attempt $attempt failed: $_"
            if ($attempt -eq 3) { throw "Failed to remove NIC $exNicName after 3 attempts" }
            Start-Sleep -Seconds 15
        }
    }
}

# ==========================================
# Create new Prep VM from snapshot
# ==========================================

Write-Host
Write-Host "$(Get-Date -Format HH:mm:ss) Creating preparation VM: $PrepVmName"

# Remove orphaned OS disk if it exists (e.g. from a previous failed run that left no VM)
$diskName   = $PrepVmName + '_OSdisk'
$orphanDisk = $null
try { $orphanDisk = Invoke-Arm -Path "$diskBase/$diskName" -Token $Token -ApiVersion $diskApi -FullResponse } catch {}
if ($orphanDisk) {
    Write-Host "  Removing orphaned OS disk: $diskName"
    Invoke-Arm -Method DELETE -Path "$diskBase/$diskName" -Token $Token -ApiVersion $diskApi -FullResponse | Out-Null
    Start-Sleep -Seconds 10
}

Write-Host "  Creating OS disk from snapshot"
$diskBody   = @{
    location   = $Location
    sku        = @{ name = 'Premium_LRS' }
    properties = @{
        creationData = @{
            createOption     = 'Copy'
            sourceResourceId = $snapshotId
        }
    }
}
$newDisk = Invoke-Arm -Method PUT -Path "$diskBase/$diskName" -Token $Token -ApiVersion $diskApi -Body $diskBody -FullResponse
$sw = [Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 10
    $newDisk = Invoke-Arm -Path "$diskBase/$diskName" -Token $Token -ApiVersion $diskApi -FullResponse
    Write-Host "  Disk state: $($newDisk.properties.provisioningState) ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
} while ($newDisk.properties.provisioningState -ne 'Succeeded' -and $sw.Elapsed.TotalSeconds -lt 300)
if ($newDisk.properties.provisioningState -ne 'Succeeded') { throw "OS disk $diskName did not provision in time" }

Write-Host "  Creating NIC"
$subnetObj  = Invoke-Arm -Path "/subscriptions/$SubId/resourceGroups/$NicResourceGroupName/providers/Microsoft.Network/virtualNetworks/$vNetName/subnets/$SubnetName" -Token $Token -ApiVersion $netApi -FullResponse
$nicName    = $PrepVmName + '-nic'
$nicBody    = @{
    location   = $Location
    properties = @{
        enableAcceleratedNetworking = $true
        ipConfigurations = @(@{
            name       = 'ipconfig1'
            properties = @{
                privateIPAllocationMethod = 'Dynamic'
                subnet = @{ id = $subnetObj.id }
            }
        })
    }
}
$newNic = Invoke-Arm -Method PUT -Path "/subscriptions/$SubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/networkInterfaces/$nicName" -Token $Token -ApiVersion $netApi -Body $nicBody -FullResponse
$sw = [Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 5
    $newNic = Invoke-Arm -Path "/subscriptions/$SubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/networkInterfaces/$nicName" -Token $Token -ApiVersion $netApi -FullResponse
    Write-Host "  NIC state: $($newNic.properties.provisioningState) ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
} while ($newNic.properties.provisioningState -ne 'Succeeded' -and $sw.Elapsed.TotalSeconds -lt 120)

Write-Host "  Deploying preparation VM"
$vmBody = @{
    location   = $Location
    tags       = @{}
    properties = @{
        hardwareProfile = @{ vmSize = $PrepVMSize }
        storageProfile  = @{
            osDisk = @{
                osType        = 'Windows'
                createOption  = 'Attach'
                managedDisk   = @{ id = $newDisk.id }
            }
        }
        networkProfile  = @{
            networkInterfaces = @(@{ id = $newNic.id })
        }
        diagnosticsProfile = @{
            bootDiagnostics = @{ enabled = $false }
        }
        securityProfile = @{
            securityType = 'TrustedLaunch'
            uefiSettings = @{ secureBootEnabled = $true; vTpmEnabled = $true }
        }
    }
}
$newVM = Invoke-Arm -Method PUT -Path "$vmBase/$PrepVmName" -Token $Token -ApiVersion $computeApi -Body $vmBody -FullResponse
$sw = [Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 15
    $newVM = Invoke-Arm -Path "$vmBase/$PrepVmName" -Token $Token -ApiVersion $computeApi -FullResponse
    Write-Host "  VM provisioning: $($newVM.properties.provisioningState) ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
} while ($newVM.properties.provisioningState -notin @('Succeeded','Failed') -and $sw.Elapsed.TotalSeconds -lt 600)
if ($newVM.properties.provisioningState -ne 'Succeeded') { throw "VM $PrepVmName failed to provision: $($newVM.properties.provisioningState)" }

# Get IP address
$nicDetail  = Invoke-Arm -Path "/subscriptions/$SubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/networkInterfaces/$nicName" -Token $Token -ApiVersion $netApi -FullResponse
$ipAddress  = $nicDetail.properties.ipConfigurations[0].properties.privateIPAddress

Write-Host
Write-Host '=========================================='
Write-Host "Preparation VM: $PrepVmName"
Write-Host "IP Address:     $ipAddress"
Write-Host '=========================================='

# ==========================================
# STAGE 2 - BIS-F / Sysprep via Run Command
# ==========================================

# $extension is "true" (BIS-F + Sysprep), "sysprep" (Sysprep only), or "false" (registry keys only)

if ($extension -eq 'true') {
    Write-Host
    Write-Host "$(Get-Date -Format HH:mm:ss) Running BIS-F sealing on $PrepVmName"

    $bisfBody = @{
        location   = $Location
        properties = @{
            source = @{ script = "& `"$BisFPath\Framework\PrepBISF_Start.ps1`"" }
        }
    }
    $null = Invoke-Arm -Method PUT -Path "$vmBase/$PrepVmName/runCommands/BisF" -Token $Token -ApiVersion $computeApi -Body $bisfBody -FullResponse

    $bisfSw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 60
        $bisfStatus = Invoke-Arm -Path "$vmBase/$PrepVmName/runCommands/BisF" -Token $Token -ApiVersion $computeApi -FullResponse
        $bisfState  = $bisfStatus.properties.provisioningState
        Write-Host "$(Get-Date -Format HH:mm:ss) BIS-F state: $bisfState ($([math]::Round($bisfSw.Elapsed.TotalMinutes, 1)) min / $BisfTimeoutMinutes min timeout)"
        if ($bisfSw.Elapsed.TotalMinutes -gt $BisfTimeoutMinutes) { throw "BIS-F timed out after $BisfTimeoutMinutes minutes on $PrepVmName" }
    } while ($bisfState -notin @('Succeeded','Failed'))
    if ($bisfState -eq 'Failed') { throw "BIS-F run command failed on $PrepVmName" }

    # Print output
    $bisfOutput = $bisfStatus.properties.instanceView.output
    if ($bisfOutput) { Write-Host $bisfOutput }

    Write-Host
    Write-Host "$(Get-Date -Format HH:mm:ss) Running Sysprep on $PrepVmName"

    $sysprepScript = @'
$logPath = 'C:\Windows\System32\Sysprep\Panther\setuperr.log'
if (Test-Path $logPath) { Clear-Content -Path $logPath -Force; Write-Output "Cleared existing setuperr.log" }
$sysprep = Start-Process -FilePath 'C:\Windows\System32\Sysprep\sysprep.exe' `
    -ArgumentList '/generalize /oobe /shutdown /quiet' -PassThru
Write-Output "Sysprep started (PID: $($sysprep.Id))"
$lastPos = 0
$waited  = 0
while (-not (Test-Path $logPath) -and $waited -lt 60) { Start-Sleep 2; $waited += 2 }
while (-not $sysprep.HasExited) {
    if (Test-Path $logPath) {
        $fs = [System.IO.File]::Open($logPath,'Open','Read','ReadWrite')
        $fs.Seek($lastPos,'Begin') | Out-Null
        $sr = New-Object System.IO.StreamReader($fs)
        $new = $sr.ReadToEnd(); $lastPos = $fs.Position
        $sr.Close(); $fs.Close()
        if ($new) { Write-Output $new }
    }
    Start-Sleep 5
}
if (Test-Path $logPath) {
    $fs = [System.IO.File]::Open($logPath,'Open','Read','ReadWrite')
    $fs.Seek($lastPos,'Begin') | Out-Null
    $sr = New-Object System.IO.StreamReader($fs)
    $new = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
    if ($new) { Write-Output $new }
}
Write-Output "Sysprep exit code: $($sysprep.ExitCode)"
'@

    # Run Command v1 (action-based POST) - Azure returns 202 Accepted with an Azure-AsyncOperation
    # header. We poll that URL until Succeeded. The embedded script runs Sysprep synchronously
    # inside the VM and outputs the setuperr.log tail before the VM powers off, so the output
    # is fully captured in the operation result.
    $sysprepV1Body = @{
        commandId = 'RunPowerShellScript'
        script    = @($sysprepScript -split "`n")
    }
    Write-Host "$(Get-Date -Format HH:mm:ss) Sysprep running (waiting up to $SysprepTimeoutMinutes min for VM to shut down)..."

    $armBase  = 'https://management.azure.com'
    $v1Path   = "$armBase$vmBase/$PrepVmName/runCommand?api-version=$computeApi"
    $v1Json   = $sysprepV1Body | ConvertTo-Json -Depth 5
    $v1Resp   = Invoke-WebRequest -Uri $v1Path -Method POST -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } -Body $v1Json -UseBasicParsing
    $asyncUrl = $v1Resp.Headers['Azure-AsyncOperation']
    if (-not $asyncUrl) { $asyncUrl = $v1Resp.Headers['Location'] }

    if ($asyncUrl) {
        $sysSw      = [Diagnostics.Stopwatch]::StartNew()
        $sysTimeout = $SysprepTimeoutMinutes * 60
        $sysState   = 'InProgress'
        $sysResult  = $null
        do {
            Start-Sleep -Seconds 60
            $pollResp  = Invoke-WebRequest -Uri $asyncUrl -Method GET -Headers @{ Authorization = "Bearer $Token" } -UseBasicParsing
            $sysResult = $pollResp.Content | ConvertFrom-Json
            $sysState  = $sysResult.status
            Write-Host "$(Get-Date -Format HH:mm:ss) Sysprep state: $sysState ($([math]::Round($sysSw.Elapsed.TotalMinutes, 1)) min / $SysprepTimeoutMinutes min timeout)"
            if ($sysSw.Elapsed.TotalSeconds -gt $sysTimeout) { throw "Sysprep timed out after $SysprepTimeoutMinutes minutes" }
        } while ($sysState -notin @('Succeeded', 'Failed', 'Canceled'))

        if ($sysState -ne 'Succeeded') { throw "Sysprep Run Command $sysState`: $($sysResult.error.message)" }

        $sysOutput = if ($sysResult.properties.output.value) {
            ($sysResult.properties.output.value | ForEach-Object { $_.message }) -join "`n"
        } else { '' }
        if ($sysOutput) { Write-Host '--- Sysprep output ---'; Write-Host $sysOutput }
    } else {
        Write-Host "Warning: No async URL returned from runCommand POST - cannot poll status"
    }
    Write-Host "$(Get-Date -Format HH:mm:ss) Sysprep complete - VM has shut down"

} elseif ($extension -eq 'sysprep') {
    Write-Host
    Write-Host "$(Get-Date -Format HH:mm:ss) Running Sysprep on $PrepVmName (BIS-F skipped)"

    $sysprepScript = @'
$logPath = 'C:\Windows\System32\Sysprep\Panther\setuperr.log'
if (Test-Path $logPath) { Clear-Content -Path $logPath -Force; Write-Output "Cleared existing setuperr.log" }
$sysprep = Start-Process -FilePath 'C:\Windows\System32\Sysprep\sysprep.exe' `
    -ArgumentList '/generalize /oobe /shutdown /quiet' -PassThru
Write-Output "Sysprep started (PID: $($sysprep.Id))"
$lastPos = 0
$waited  = 0
while (-not (Test-Path $logPath) -and $waited -lt 60) { Start-Sleep 2; $waited += 2 }
while (-not $sysprep.HasExited) {
    if (Test-Path $logPath) {
        $fs = [System.IO.File]::Open($logPath,'Open','Read','ReadWrite')
        $fs.Seek($lastPos,'Begin') | Out-Null
        $sr = New-Object System.IO.StreamReader($fs)
        $new = $sr.ReadToEnd(); $lastPos = $fs.Position
        $sr.Close(); $fs.Close()
        if ($new) { Write-Output $new }
    }
    Start-Sleep 5
}
if (Test-Path $logPath) {
    $fs = [System.IO.File]::Open($logPath,'Open','Read','ReadWrite')
    $fs.Seek($lastPos,'Begin') | Out-Null
    $sr = New-Object System.IO.StreamReader($fs)
    $new = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
    if ($new) { Write-Output $new }
}
Write-Output "Sysprep exit code: $($sysprep.ExitCode)"
'@

    $sysprepV1Body = @{
        commandId = 'RunPowerShellScript'
        script    = @($sysprepScript -split "`n")
    }
    Write-Host "$(Get-Date -Format HH:mm:ss) Sysprep running (waiting up to $SysprepTimeoutMinutes min for VM to shut down)..."

    $armBase  = 'https://management.azure.com'
    $v1Path   = "$armBase$vmBase/$PrepVmName/runCommand?api-version=$computeApi"
    $v1Json   = $sysprepV1Body | ConvertTo-Json -Depth 5
    $v1Resp   = Invoke-WebRequest -Uri $v1Path -Method POST -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } -Body $v1Json -UseBasicParsing
    $asyncUrl = $v1Resp.Headers['Azure-AsyncOperation']
    if (-not $asyncUrl) { $asyncUrl = $v1Resp.Headers['Location'] }

    if ($asyncUrl) {
        $sysSw      = [Diagnostics.Stopwatch]::StartNew()
        $sysTimeout = $SysprepTimeoutMinutes * 60
        $sysState   = 'InProgress'
        $sysResult  = $null
        do {
            Start-Sleep -Seconds 60
            $pollResp  = Invoke-WebRequest -Uri $asyncUrl -Method GET -Headers @{ Authorization = "Bearer $Token" } -UseBasicParsing
            $sysResult = $pollResp.Content | ConvertFrom-Json
            $sysState  = $sysResult.status
            Write-Host "$(Get-Date -Format HH:mm:ss) Sysprep state: $sysState ($([math]::Round($sysSw.Elapsed.TotalMinutes, 1)) min / $SysprepTimeoutMinutes min timeout)"
            if ($sysSw.Elapsed.TotalSeconds -gt $sysTimeout) { throw "Sysprep timed out after $SysprepTimeoutMinutes minutes" }
        } while ($sysState -notin @('Succeeded', 'Failed', 'Canceled'))

        if ($sysState -ne 'Succeeded') { throw "Sysprep Run Command $sysState`: $($sysResult.error.message)" }

        $sysOutput = if ($sysResult.properties.output.value) {
            ($sysResult.properties.output.value | ForEach-Object { $_.message }) -join "`n"
        } else { '' }
        if ($sysOutput) { Write-Host '--- Sysprep output ---'; Write-Host $sysOutput }
    } else {
        Write-Host "Warning: No async URL returned from runCommand POST - cannot poll status"
    }
    Write-Host "$(Get-Date -Format HH:mm:ss) Sysprep complete - VM has shut down"

} else {
    # extension -eq 'false': set BIS-F registry keys only, then wait for manual Sysprep
    Write-Host
    Write-Host "$(Get-Date -Format HH:mm:ss) Setting BIS-F registry keys on $PrepVmName (no extension mode)"

    $regScript = @'
Write-Host "Creating registry key..."
New-Item -Path 'HKLM:\SOFTWARE\Policies\Login Consultants\BISF' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Login Consultants\BISF' -Name 'LIC_BISF_CLI_ST' -Value 'YES' -Type String -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Login Consultants\BISF' -Name 'LIC_BISF_POL_ST' -Value 1 -Type DWord -Force
Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Login Consultants\BISF'
Install-PackageProvider -Name NuGet -Force -Scope CurrentUser
Install-Module -Name PolicyFileEditor -Force -Scope AllUsers -SkipPublisherCheck
Import-Module PolicyFileEditor
Set-PolicyFileEntry -Path 'C:\Windows\System32\GroupPolicy\Machine\Registry.pol' -Key 'SOFTWARE\Policies\Login Consultants\BISF' -ValueName 'LIC_BISF_CLI_ST' -Data 'YES' -Type String
Set-PolicyFileEntry -Path 'C:\Windows\System32\GroupPolicy\Machine\Registry.pol' -Key 'SOFTWARE\Policies\Login Consultants\BISF' -ValueName 'LIC_BISF_POL_ST' -Data 1 -Type DWord
gpupdate /force
Remove-Module PolicyFileEditor -Force
Uninstall-Module -Name PolicyFileEditor -Force
Write-Host "Done"
'@

    $regBody = @{
        location   = $Location
        properties = @{
            source = @{ script = $regScript }
        }
    }
    Invoke-Arm -Method PUT -Path "$vmBase/$PrepVmName/runCommands/BisfRegKeys" -Token $Token -ApiVersion $computeApi -Body $regBody -FullResponse | Out-Null

    $regSw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 30
        $regStatus = Invoke-Arm -Path "$vmBase/$PrepVmName/runCommands/BisfRegKeys" -Token $Token -ApiVersion $computeApi -FullResponse
        $regState  = $regStatus.properties.provisioningState
        Write-Host "$(Get-Date -Format HH:mm:ss) Registry key command: $regState ($([math]::Round($regSw.Elapsed.TotalMinutes, 1)) min)"
        if ($regSw.Elapsed.TotalMinutes -gt 15) { throw "BIS-F registry key command timed out on $PrepVmName" }
    } while ($regState -notin @('Succeeded','Failed'))
    if ($regState -eq 'Failed') { throw "BIS-F registry key command failed on $PrepVmName" }

    Write-Host "$(Get-Date -Format HH:mm:ss) BIS-F registry keys set successfully"

    Write-Host "$(Get-Date -Format HH:mm:ss) Waiting for VM to stop (Sysprep running manually)..."
    $sw      = [Diagnostics.Stopwatch]::StartNew()
    $timeout = New-TimeSpan -Minutes $SysprepTimeoutMinutes
    do {
        Start-Sleep -Seconds 90
        $iv = Invoke-Arm -Path "$vmBase/$PrepVmName/instanceView" -Token $Token -ApiVersion $computeApi -FullResponse
        $ps = ($iv.statuses | Where-Object { $_.code -like 'PowerState/*' }).code
        Write-Host "  Current state: $ps (Elapsed: $($sw.Elapsed.ToString('mm\:ss')))"
        if ($sw.Elapsed -ge $timeout) {
            throw "VM $PrepVmName has not stopped after $SysprepTimeoutMinutes minutes. Sysprep may have failed."
        }
    } while ($ps -ne 'PowerState/stopped')
}

Write-Host "$(Get-Date -Format HH:mm:ss) VM stopped. Deallocating..."
Invoke-Arm -Method POST -Path "$vmBase/$PrepVmName/deallocate" -Token $Token -ApiVersion $computeApi -FullResponse | Out-Null

Wait-VMPowerState -SubscriptionId $SubId -ResourceGroup $ResourceGroupName -VMName $PrepVmName -Expected 'PowerState/deallocated' -Token $Token -TimeoutSeconds 300
Write-Host "$(Get-Date -Format HH:mm:ss) VM deallocated"

# Generalise
Write-Host "$(Get-Date -Format HH:mm:ss) Generalising $PrepVmName"
Invoke-Arm -Method POST -Path "$vmBase/$PrepVmName/generalize" -Token $Token -ApiVersion $computeApi -FullResponse | Out-Null
Start-Sleep -Seconds 30

# Verify VM is marked Generalized before submitting to gallery
$prepVmObj = Invoke-Arm -Path "$vmBase/$PrepVmName" -Token $Token -ApiVersion $computeApi -FullResponse
if ($prepVmObj.properties.storageProfile.osDisk.osType -and
    $prepVmObj.properties.osProfile -and
    $prepVmObj.properties.osProfile.allowExtensionOperations -eq $false) {
    Write-Host "  VM is generalized"
} else {
    Write-Host "  VM generalization state: $($prepVmObj.properties.provisioningState)"
}

# ==========================================
# STAGE 3 - Submit Gallery Image Version
# ==========================================

Write-Host
Write-Host "$(Get-Date -Format HH:mm:ss) Getting gallery image definition: $galleryImageDefinitionName"
$null = Invoke-Arm -Path "$galleryBase/images/$galleryImageDefinitionName" -Token $Token -ApiVersion $galleryApi -FullResponse

$Version = Get-Date -Format 'yyyyMM.dd.HHmm'
Write-Host "$(Get-Date -Format HH:mm:ss) Version: $Version"

Write-Host
Write-Host '=========================================='
Write-Host 'Gallery Image Version Parameters'
Write-Host '=========================================='
Write-Host "Gallery:        $galleryName"
Write-Host "Definition:     $galleryImageDefinitionName"
Write-Host "Version:        $Version"
Write-Host "Resource Group: $galleryRG"
Write-Host "Location:       $Location"
Write-Host "Source VM ID:   $($prepVmObj.id)"
Write-Host "End of Life:    $((Get-Date).ToUniversalTime().AddMonths(12).ToString('yyyy-MM-dd'))"
Write-Host "Target Regions:"
$arrLocations | ForEach-Object { Write-Host "  - $($_.name)  replicas=$($_.regionalReplicaCount)  storage=$($_.storageAccountType)" }
Write-Host '=========================================='

$imgVerBody = @{
    location   = $Location
    properties = @{
        publishingProfile = @{
            replicaCount       = $ImageReplicaCount
            storageAccountType = $ImageStorageAccountType
            targetRegions      = $arrLocations
            endOfLifeDate      = (Get-Date).ToUniversalTime().AddMonths(12).ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        storageProfile = @{
            source = @{ virtualMachineId = $prepVmObj.id }
        }
    }
}

Write-Host "$(Get-Date -Format HH:mm:ss) Submitting gallery image version (this can take up to 30 minutes)..."
Invoke-Arm -Method PUT -Path "$galleryBase/images/$galleryImageDefinitionName/versions/$Version" -Token $Token -ApiVersion $galleryApi -Body $imgVerBody -FullResponse | Out-Null

# Poll until replication succeeds
$sw = [Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds 30
do {
    $verStatus = Invoke-Arm -Path "$galleryBase/images/$galleryImageDefinitionName/versions/$Version" -Token $Token -ApiVersion $galleryApi -FullResponse
    $state     = $verStatus.properties.provisioningState
    Write-Host "$(Get-Date -Format HH:mm:ss) Gallery version state: $state ($([math]::Round($sw.Elapsed.TotalMinutes, 1)) min)"
    if ($state -eq 'Failed') {
        Write-Host ''
        Write-Host 'Gallery version failure details:'
        # Top-level error
        if ($verStatus.properties.provisioningError) {
            Write-Host "  Error code   : $($verStatus.properties.provisioningError.code)"
            Write-Host "  Error message: $($verStatus.properties.provisioningError.message)"
        }
        # Per-region replication status
        $repStatus = $verStatus.properties.replicationStatus
        if ($repStatus) {
            Write-Host "  Aggregated state: $($repStatus.aggregatedState)"
            foreach ($r in $repStatus.summary) {
                Write-Host "  Region: $($r.region)  state=$($r.state)  progress=$($r.replicationPercentage)%"
                foreach ($d in $r.details) {
                    Write-Host "    code=$($d.code)  message=$($d.message)"
                }
            }
        }
        # Raw status blob for anything not covered above
        Write-Host "  Raw status: $($verStatus.properties | ConvertTo-Json -Depth 4 -Compress)"
        throw "Gallery image version creation failed"
    }
    if ($state -ne 'Succeeded') { Start-Sleep -Seconds 60 }
} while ($state -ne 'Succeeded')

Write-Host "$(Get-Date -Format HH:mm:ss) Gallery image version Succeeded"

# ==========================================
# STAGE 4 - Cleanup
# ==========================================

Write-Host
Write-Host "$(Get-Date -Format HH:mm:ss) Cleaning up preparation resources"

$cleanVM = Invoke-Arm -Path "$vmBase/$PrepVmName" -Token $Token -ApiVersion $computeApi -FullResponse
$cleanDisk = $cleanVM.properties.storageProfile.osDisk.name
$cleanNicId = $cleanVM.properties.networkProfile.networkInterfaces[0].id
$cleanNicName = $cleanNicId -split '/' | Select-Object -Last 1

Write-Host "  Removing VM: $PrepVmName"
Invoke-Arm -Method DELETE -Path "$vmBase/$PrepVmName" -Token $Token -ApiVersion $computeApi -FullResponse | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 10
    $check = $null
    try { $check = Invoke-Arm -Path "$vmBase/$PrepVmName" -Token $Token -ApiVersion $computeApi -FullResponse } catch {}
} while ($check -and $sw.Elapsed.TotalSeconds -lt 180)

Write-Host "  Removing OS disk: $cleanDisk"
Invoke-Arm -Method DELETE -Path "$diskBase/$cleanDisk" -Token $Token -ApiVersion $diskApi -FullResponse | Out-Null

Write-Host "  Removing NIC: $cleanNicName"
Invoke-Arm -Method DELETE -Path "/subscriptions/$SubId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/networkInterfaces/$cleanNicName" -Token $Token -ApiVersion $netApi -FullResponse | Out-Null

Write-Host "  Removing snapshot: $snapshotName"
Invoke-Arm -Method DELETE -Path "$snapBase/$snapshotName" -Token $Token -ApiVersion $diskApi -FullResponse | Out-Null

Write-Host
Write-Host '=========================================='
Write-Host 'Image creation complete'
Write-Host "Version: $Version"
Write-Host '=========================================='
