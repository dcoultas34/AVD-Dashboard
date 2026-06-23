#
# Environment configuration for AVD Live Dashboard and Profile Tools.
# Edit this file for each deployment - the scripts themselves do not need modification.
#
# Author  : virtualwebber (https://github.com/virtualwebber)
#

@{

    # Optional display name shown in the config picker when multiple configs are present.
    # Defaults to the filename (without .psd1) if omitted.
    Name = 'Example Configuration'

    # =========================================================================
    # Azure Connection - used by avd-live-dashboard.ps1
    # =========================================================================

    Azure = @{

        # Tenant ID to connect to on sign-in.
        # Leave as '' to use the default tenant for the signing-in account.
        # Example: '00000000-0000-0000-0000-000000000000'
        TenantId = ''

        # Subscription ID to set as active after sign-in.
        # Leave as '' to use whichever subscription the context defaults to.
        # Example: '00000000-0000-0000-0000-000000000000'
        SubscriptionId = ''
    }

    # =========================================================================
    # Dashboard - used by avd-live-dashboard.ps1
    # =========================================================================

    Dashboard = @{

        # Tabs to hide from the dashboard tab strip.
        # These are enforced at the deployment level — hidden tabs cannot be re-enabled via the Settings UI.
        # Valid names: 'Per Host Pool', 'By Region', 'Session Hosts', 'Azure Files', 'Monitoring', 'Images', 'Infrastructure', 'Azure DevOps'
        # Example: @('Monitoring', 'Azure Files')
        HiddenTabs = @('Images')

        # Hide the Settings button from the dashboard toolbar.
        # When $true, settings can only be changed by editing config.psd1 directly.
        # Default: $false
        HideSettingsButton = $false

        # Hide the Session History button from the session detail window.
        # When $true, the button is not shown and the feature is unavailable.
        # Session History queries LAW for additional session host data
        # (e.g. lock/unlock events) and displays it in a separate modal window.
        # Default: $false
        HideSessionHistory = $false

    }

    # =========================================================================
    # Azure Files - used by avd-live-dashboard.ps1
    # =========================================================================

    AzureFiles = @{

        # Resource groups containing storage accounts to monitor.
        # Leave as @() to scan all matching accounts across the entire subscription.
        # Wildcards supported (e.g. '*-FILES-*', 'RG-AVD-*').
        # Example: @('RG-AVD-FILES-UKS', 'RG-AVD-FILES-UKW')
        FilesRGs = @()

        # Percentage used at which the amber warning card appears on the dashboard.
        # Range: 1-100.
        StorageWarningPct = 90

        # Storage account kinds to include.
        # FileStorage = premium file share accounts (dedicated FileStorage SKU)
        # StorageV2   = general-purpose v2 accounts hosting standard file shares
        StorageAccountKinds = @('FileStorage', 'StorageV2')
    }

    # =========================================================================
    # AVD Host Pools - used by avd-live-dashboard.ps1
    # =========================================================================

    AVDHostPools = @{

        # Resource groups to INCLUDE when querying AVD host pools.
        # Leave as @() to query all resource groups in the subscription.
        # Wildcards supported (e.g. 'AVDCORE-*', '*-PROD-RG').
        # Example: @('AVDCORE-UKS-PROD-RG', 'AVDCORE-UKW-PROD-RG')
        IncludeRGs = @()

        # Resource groups to EXCLUDE from AVD queries.
        # Applied after IncludeRGs. Leave as @() to exclude nothing.
        # Wildcards supported (e.g. '*-UAT-*', '*-TEST-*').
        ExcludeRGs = @()

        # Host pool name patterns sorted to the bottom of the Per Host Pool tab.
        # Case-insensitive substring match.
        # Example: @('-UAT', '-TEST', '-DEV')
        LowPriorityPatterns = @('-UAT')

        # Azure regions treated as secondary.
        # Rows are highlighted red when sessions are running in these regions.
        # Leave as @() to disable highlighting entirely.
        # Example: @('francecentral', 'westeurope')
        SecondaryRegions = @('francecentral')

        # Whether secondary region row highlighting is enabled by default.
        # Can be toggled at runtime via the Settings UI.
        SecondaryRegionHighlightEnabled = $true

        # Host pools to exclude from all views and data queries.
        # Case-insensitive exact name match. Can also be managed via the Settings UI.
        # Example: @('HP-TEST', 'HP-UAT-POOL')
        ExcludedHostPools = @()

        # Substrings used to split session hosts into two groups (A and B) for
        # image version comparison on the Per Host Pool tab. Each pattern is
        # matched case-insensitively against the short VM hostname.
        # If only one group exists in a host pool, the other shows "N/A".
        # Leave both as '' to disable grouping (single Image Version column).
        # Example: HostGroupPatterns = @{ A = '-A-'; B = '-B-' }
        HostGroupPatterns = @{ A = ''; B = '' }

        # Columns to hide in the Per Host Pool grid.
        # Leave as @() to show all columns.
        # Valid names: 'Host Pool', 'Workspace', 'VM Region', 'Image Version A',
        #              'Image Version B', 'Total VMs', 'RG VMs', 'VMs Available', 'VMs Not Available',
        #              'VMs Drained', 'Active Users', 'Disconnected', 'Total Sessions',
        #              'Scaling Plan', 'Max Sessions', 'Load Balancer', 'Validation',
        #              'Start VM on Connect', 'Host Pool RG', 'Scope', 'HP Location'
        # Example: @('Workspace', 'Host Pool RG', 'Scaling Plan')
        HiddenColumns = @()

        # Tag name checked on session host VMs to show scaling exclusion in the Session Hosts tab.
        # The Query Details button checks for this tag (presence only, value is ignored).
        # Default: 'ExcludeFromScaling'
        ScalingExcludeTag = 'ExcludeFromScaling'

        # Whether to query and display RG VM counts in the Per Host Pool tab.
        # When $true (default), an extra ARM call per VM resource group fetches all VMs in that
        # RG and compares the count to the AVD session host count — a mismatch (red cell) means
        # VMs exist in the RG that are not registered as session hosts.
        # Set to $false to skip the RG VM count queries and hide the RG VMs column entirely.
        ShowRGVMCount = $true
    }

    # =========================================================================
    # Shadow / RDP - used by avd-live-dashboard.ps1
    # =========================================================================

    ShadowRDP = @{

        # Shadow tool to use for right-click session connections.
        # 'MSTSC' = mstsc.exe (Remote Desktop)
        #           Requires port 445 open from the dashboard machine to session hosts
        #           (the "Remote Desktop - Shadow (TCP-In)" firewall rule on session hosts).
        #           If port 445 is blocked in your environment, use MSRA instead.
        # 'MSRA'  = msra.exe  (Remote Assistance) - uses port 3389 only, no port 445 needed.
        ShadowMethod = 'MSTSC'

        # Connection target for Shadow and RDP.
        # $true  = resolve and use the VM private IP address
        # $false = use the DNS hostname (recommended for most environments)
        ShadowUseIP = $true
    }

    # =========================================================================
    # Messaging - used by avd-live-dashboard.ps1
    # =========================================================================

    Messaging = @{

        # Default title pre-populated in the Send Message dialog.
        DefaultTitle = 'Message from IT Support'

        # Default body pre-populated in the Send Message dialog.
        DefaultBody = 'Please save your work and log off when you are done.'
    }

    # =========================================================================
    # Network Ranges - used by avd-live-dashboard.ps1 (Session Detail)
    # =========================================================================

    # Ordered list of named CIDR ranges used to classify Client IP in Session Detail.
    # Each entry: @{ Label = 'DisplayName'; Ranges = @('cidr1', 'cidr2') }
    # Checked top-to-bottom, first match wins.
    # Any private IP (RFC 1918) not matched above is labelled "Office".
    # Everything else is "Public".
    # Leave empty @() to just use Office / Public defaults.
    NetworkRanges = @(
        # @{ Label = 'VPN';     Ranges = @('10.100.0.0/16') }
        # @{ Label = 'Proxy';   Ranges = @('85.115.53.0/24', '85.115.33.0/24') }
        # @{ Label = 'Office1'; Ranges = @('10.10.0.0/16') }
        # @{ Label = 'Office2'; Ranges = @('10.20.0.0/16') }
    )

    # =========================================================================
    # FSLogix / Profile Tools - used by profile-tools.ps1
    # =========================================================================

    ProfileTools = @{

        # Storage accounts to check when searching for FSLogix profile folders.
        # Key   = storage account short name (no domain suffix)
        # Value = full UNC path pointing directly to the folder that contains profile folders.
        #         Include a subpath if profiles are not at the share root.
        #         e.g. '\\account.file.core.windows.net\share\profiles'
        StorageAccountShareMap = @{
            'salivedashboard2'    = '\\salivedashboard2.file.core.windows.net\fslogix\profiles'
            'salivedashboardtest' = '\\salivedashboardtest.file.core.windows.net\fslogix\profiles'
            'sauksprofiles1'      = '\\sauksprofiles1.file.core.windows.net\fslogix\profiles'
            'saukwprofiles1'      = '\\saukwprofiles1.file.core.windows.net\fslogix\profiles'
        }

        # Account names to exclude from profile tool tabs and scans.
        # Excluded accounts are still checked during profile deletion operations.
        # Leave as @() to include all accounts.
        ExcludeStorage = @()

        # Maps a substring of a storage account name to a human-readable Azure region label.
        # Used to display the region badge on Storage Location cards.
        # Key   = substring to match against the storage account name (case-insensitive)
        # Value = label to display on the card
        RegionLabels = @{
            'ukw' = 'UK West'
            'uks' = 'UK South'
            'frc' = 'France Central'
        }

        # Named pairs of storage accounts. Each pair appears as a radio button in Profile Tools —
        # selecting it ticks only that pair's account checkboxes across all action tabs.
        # Key = label shown on the radio button. Value = two storage account short names.
        # Leave as @{} to disable pair selection.
        StorageAccountPairs = @{
            'UKS + UKW' = @('sauksprofiles1', 'saukwprofiles1')
            'FRC + UKS' = @('safrcprofiles1', 'sauksprofiles1')
        }
    }

    # =========================================================================
    # Log Analytics - used by avd-live-dashboard.ps1 (Session Hosts tab)
    # =========================================================================

    LogAnalytics = @{

        # Full ARM resource ID of the Log Analytics workspace that receives
        # AVD session host performance data (CPU / Memory / Disk from the Perf table).
        # Leave as '' to disable the CPU %, Mem %, and Disk % columns in the Session Hosts tab.
        # Example: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/RG-LOGS/providers/Microsoft.OperationalInsights/workspaces/my-law-workspace'
        WorkspaceResourceId = ''

        # Optional: route KQL queries through the direct Log Analytics API instead of
        # the ARM management plane. Set to https://api.loganalytics.azure.com to enable
        # AMPLS private endpoint support (api.loganalytics.azure.com CNAMEs to
        # api.monitor.azure.com, which privatelink.monitor.azure.com resolves privately).
        # Leave as '' (default) to use the ARM path - no change to existing behaviour.
        QueryBaseUrl = 'https://api.loganalytics.azure.com'

        # Processes to exclude from Input Delay calculations.
        # Background/system processes that report input delay but do not represent
        # real user interaction. These are filtered out of both the grid Median/P95
        # columns and the Input Delay Breakdown popup.
        # Example: @('LapsView.exe', 'SomeAgent.exe')
        InputDelayExcludeProcesses = @('LapsView.exe')
    }

    # =========================================================================
    # Permissions Checker - used by scripts\Check-Permissions.ps1 only
    # =========================================================================

    PermissionsChecker = @{

        # Resource groups containing the Log Analytics workspaces used by AVD Insights.
        # Used only by Check-Permissions.ps1 to scope the Log Analytics Reader role check.
        # Leave as @() to check all resource groups in the subscription.
        # Wildcards supported (e.g. 'RG-LOGS-*', '*-MONITORING*').
        # Example: @('RG-LOGS-UKS', 'RG-MONITORING')
        LogAnalyticsRGs = @()
    }

    # =========================================================================
    # Infrastructure Servers - used by avd-live-dashboard.ps1
    # =========================================================================

    InfrastructureServers = @{

        # Resource groups containing infrastructure VMs to display in the Infrastructure tab.
        # Leave as @() to show an empty tab.
        # Wildcards supported (e.g. 'RG-INFRA-*', '*-SERVERS-*').
        # Example: @('RG-INFRA-UKS', 'RG-INFRA-UKW')
        ResourceGroups = @()

        # VM name substrings to exclude from the Infrastructure tab (case-insensitive).
        # Leave as @() to include all VMs in the configured resource groups.
        # Example: @('-TEMP', '-OLD')
        ExcludePatterns = @()
    }

    # =========================================================================
    # Images - used by scripts\tab-images.ps1 and scripts\Create-Image.ps1
    # =========================================================================

    Images = @{

        # Resource groups containing image VMs to display in the Images tab.
        # Leave as @() to show an empty tab.
        # Example: @('rg-weu-avdimages-prod')
        ResourceGroups = @()

        # VM name substrings to include in the Images tab (case-insensitive).
        # Only VMs whose names contain at least one of these strings will appear.
        # Leave as @() to include all VMs in the configured resource groups.
        # Example: @('AVDGI', 'GOLD')
        IncludePatterns = @()

        # How often the Images tab auto-refreshes (seconds). Default: 60
        RefreshIntervalSeconds = 60

        # Resource groups to search for Shared Image Galleries in the Create Image dialog.
        # Leave as @() to search the entire subscription (slower but finds all galleries).
        # Wildcards are NOT supported here — use exact RG names.
        # Example: @('rg-weu-avdimages-prod', 'rg-uks-avdimages-prod')
        GalleryRGs = @()

        # VM sizes offered in the Preparation VM Size dropdown in the Create Image dialog.
        # The first entry is pre-selected by default unless PrepVMSizeDefault is set.
        # Example: @('Standard_D2s_v5', 'Standard_D4s_v5', 'Standard_D8s_v5')
        PrepVMSizes = @('Standard_D2s_v5', 'Standard_D4s_v5', 'Standard_D8s_v5', 'Standard_D2s_v4', 'Standard_D4s_v4')

        # Size pre-selected in the Create Image dialog. Must be one of the entries in PrepVMSizes.
        # Default: 'Standard_D4s_v5'
        PrepVMSizeDefault = 'Standard_D4s_v5'

        # Number of image versions to retain per image definition when using Clean Image Versions.
        # The newest N versions are kept; all older versions are deleted.
        # Default: 5
        ImageVersionsToKeep = 5

        # Full path to the BIS-F (Base Image Script Framework) installation on the preparation VM.
        # Used by the Create Image process to run BIS-F sealing before generalising the VM.
        # Default: 'C:\_source\Bis-F'
        BisFPath = 'C:\_source\Bis-F'

        # Gallery image replication regions. Region1 is required; Region2 is optional (leave blank to skip).
        # ReplicationRegionReplicas = number of replicas to create in that region.
        ReplicationRegion1         = 'westeurope'
        ReplicationRegion1Replicas = 1
        ReplicationRegion2         = ''
        ReplicationRegion2Replicas = 1

    }

    # =========================================================================
    # Costs - used by scripts\cost-lookup.ps1 (Session Hosts / Infrastructure tabs)
    # =========================================================================

    Costs = @{

        # Controls whether the Windows Server licence cost is included in compute pricing.
        #
        # $false (default) - base/Linux compute rate.
        #   Use this for Windows 10/11 multisession AVD session hosts — the Windows licence
        #   is covered by Microsoft 365 (E3/E5/F3) and is NOT charged per-VM. This matches
        #   what Azure actually bills for multisession hosts.
        #   Also use this for VMs with Azure Hybrid Benefit (AHB) enabled.
        #
        # $true - full Windows Server PAYG rate (compute + Windows Server licence bundled).
        #   Use this only if your VMs are billed at the Windows Server PAYG rate
        #   (i.e. Windows Server session hosts without AHB or an included licence).
        PricingWindowsLicence = $false
    }

    # =========================================================================
    # Azure DevOps - used by scripts\tab-azuredevops.ps1
    # =========================================================================

    AzureDevOps = @{

        # Full URL to your Azure DevOps organisation and project.
        # Format: 'https://dev.azure.com/<organisation>/<project>'
        # Example: 'https://dev.azure.com/contoso/MyProject'
        # Leave as '' to disable the tab (it will show an error banner if enabled
        # via HiddenTabs but this value is blank).
        OrganisationUrl = ''

        # How often the pipeline list auto-refreshes (seconds).
        # Default: 30
        RefreshIntervalSeconds = 30
    }
}