#
# Environment configuration for AVD Live Dashboard and Profile Tools.
# Edit this file for each deployment - the scripts themselves do not need modification.
#
# Author  : virtualwebber (https://github.com/virtualwebber/AVD-Dashboard)
#

@{

    # Optional display name shown in the config picker when multiple configs are present.
    # Defaults to the filename (without .psd1) if omitted.
    Name = 'Lab'

    # =========================================================================
    # Azure Connection - used by avd-live-dashboard.ps1
    # =========================================================================

    Azure = @{

        # Tenant ID to connect to on sign-in.
        # Leave as '' to use the default tenant for the signing-in account.
        TenantId = 'fd6c421d-95d5-4c92-8871-1dcc3b6fb3a8'

        # Subscription ID to set as active after sign-in.
        # Leave as '' to use whichever subscription the context defaults to.
        SubscriptionId = '5f67c3b3-8cb6-465b-8fa0-fa680c9668d6'
    }

    # =========================================================================
    # Dashboard - used by avd-live-dashboard.ps1
    # =========================================================================

    Dashboard = @{

        # Tabs to hide from the dashboard tab strip.
        # These are enforced at the deployment level - hidden tabs cannot be re-enabled via the Settings UI.
        # Valid names: 'Per Host Pool', 'By Region', 'Session Hosts', 'Azure Files', 'Monitoring', 'Images', 'Infrastructure', 'Azure DevOps'
        HiddenTabs = @()

        # Hide the Session History button in Session Detail windows.
        # Set to $true to remove the button from the toolbar.
        HideSessionHistory = $false
    }

    # =========================================================================
    # Azure Files - used by avd-live-dashboard.ps1
    # =========================================================================

    AzureFiles = @{

        # Resource groups containing storage accounts to monitor.
        # Leave as @() to scan all matching accounts across the entire subscription.
        FilesRGs = @()

        # Percentage used at which the amber warning card appears on the dashboard.
        StorageWarningPct = 90

        # Storage account kinds to include. FileStorage = premium, StorageV2 = general-purpose v2.
        StorageAccountKinds = @('FileStorage', 'StorageV2')
    }

    # =========================================================================
    # AVD Host Pools - used by avd-live-dashboard.ps1
    # =========================================================================

    AVDHostPools = @{

        # Resource groups to INCLUDE when querying AVD host pools.
        # Leave as @() to query all resource groups in the subscription.
        IncludeRGs = @()

        # Resource groups to EXCLUDE from AVD queries. Applied after IncludeRGs.
        ExcludeRGs = @()

        # Host pool name patterns sorted to the bottom of the Per Host Pool tab.
        LowPriorityPatterns = @('-UAT')

        # Azure regions treated as secondary. Rows highlighted red when sessions run here.
        SecondaryRegions = @('francecentral')

        # Whether secondary region row highlighting is enabled by default.
        SecondaryRegionHighlightEnabled = $true

        # Host pools to exclude from all views and data queries.
        ExcludedHostPools = @()

        # Columns to hide in the Per Host Pool grid.
        # Valid names: 'Host Pool', 'Workspace', 'VM Region', 'Image Version',
        #              'Total VMs', 'VMs On', 'VMs Off', 'Active Users', 'Disconnected',
        #              'Total Sessions', 'Scaling Plan', 'Host Pool RG', 'Scope', 'HP Location'
        HiddenColumns = @()

        # Whether to query and display RG VM counts in the Per Host Pool tab.
        # Set to $false to skip the RG VM count queries and hide the RG VMs column entirely.
        ShowRGVMCount = $false

        # Tag name checked on session host VMs to show scaling exclusion in the Session Hosts tab.
        # Query Details checks for this tag (presence only, value is ignored).
        ScalingExcludeTag = 'ExcludeFromScaling'
    }

    # =========================================================================
    # Shadow / RDP - used by avd-live-dashboard.ps1
    # =========================================================================

    ShadowRDP = @{

        # Shadow tool. 'MSTSC' = mstsc.exe (recommended). 'MSRA' = msra.exe.
        ShadowMethod = 'MSRA'

        # $true = use VM private IP address. $false = use DNS hostname.
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

    # Named CIDR ranges - checked in order, first match wins.
    # Unmatched private IPs = Office, else Public.
    NetworkRanges = @(
        @{ Label = 'Proxy'; Ranges = @('85.115.53.0/24', '85.115.33.0/24') }
    )

    # =========================================================================
    # FSLogix / Profile Tools - used by profile-tools.ps1
    # =========================================================================

    ProfileTools = @{

        # Storage accounts to check when searching for FSLogix profile folders.
        # Key = storage account short name, Value = full UNC path to the share.
        StorageAccountShareMap = @{
            'salivedashboard2' = '\\salivedashboard2.file.core.windows.net\fslogix'
            'salivedashboardtest' = '\\salivedashboardtest.file.core.windows.net\fslogix'
            'sauksprofiles1' = '\\sauksprofiles1.file.core.windows.net\fslogix'
            'saukwprofiles1' = '\\saukwprofiles1.file.core.windows.net\fslogix'
        }

        # Account names to exclude from profile tool tabs and scans.
        ExcludeStorage = @()

        # Maps a substring of a storage account name to a human-readable Azure region label.
        RegionLabels = @{
            'frc' = 'France Central'
            'uks' = 'UK South'
            'ukw' = 'UK West'
        }

        # Named pairs of storage accounts for one-click multi-account selection in Profile Tools.
        # Key = display name shown on the pair button, Value = array of two storage account short names.
        # Leave as @{} to disable pair buttons.
        StorageAccountPairs = @{
        'UKS2 + UKW2' = @('sauksprofiles1', 'saukwprofiles1')
        'UKS + UKW' = @('salivedashboard2', 'salivedashboardtest')
    }
    }

    # =========================================================================
    # Log Analytics - used by avd-live-dashboard.ps1 (Session Hosts tab)
    # =========================================================================

    LogAnalytics = @{

        # Full ARM resource ID of the Log Analytics workspace that receives
        # AVD session host performance data (CPU / Memory / Disk from the Perf table).
        # Leave as '' to disable the CPU %, Mem %, and Disk % columns in the Session Hosts tab.
        WorkspaceResourceId = '/subscriptions/5f67c3b3-8cb6-465b-8fa0-fa680c9668d6/resourceGroups/rg-weu-avdcore-prod/providers/Microsoft.OperationalInsights/workspaces/law-weu-avd-prod-01'
    }

    # =========================================================================
    # Permissions Checker - used by scripts\check-permissions.ps1 only
    # =========================================================================

    PermissionsChecker = @{

        # Resource groups containing the Log Analytics workspaces used by AVD Insights.
        # Used only by check-permissions.ps1 to scope the Log Analytics Reader role check.
        # Leave as @() to check all resource groups in the subscription.
        LogAnalyticsRGs = @()
    }

    # =========================================================================
    # Infrastructure Servers - used by avd-live-dashboard.ps1
    # =========================================================================

    InfrastructureServers = @{

        # Resource groups containing infrastructure VMs to display in the Infrastructure tab.
        # Leave as @() to show an empty tab.
        ResourceGroups = @('rg-weu-avdcore-prod')

        # VM name substrings to exclude from the Infrastructure tab (case-insensitive).
        # Leave as @() to include all VMs in the configured resource groups.
        ExcludePatterns = @()
    }

    # =========================================================================
    # Images - used by scripts\tab-images.ps1 and scripts\create-image.ps1
    # =========================================================================

    Images = @{

        # Resource groups containing image VMs to display in the Images tab.
        ResourceGroups = @('rg-weu-avdimages-prod')

        # VM name substrings to include (case-insensitive). Leave as @() to show all VMs in the RGs.
        IncludePatterns = @()

        # How often the Images tab auto-refreshes (seconds). Default: 60
        RefreshIntervalSeconds = 60

        # Resource groups to search for Shared Image Galleries in the Create Image dialog.
        GalleryRGs = @()

        # VM sizes offered in the Preparation VM Size dropdown in the Create Image dialog.
        PrepVMSizes = @('Standard_B4s_v2')

        # Size pre-selected by default. Default: 'Standard_D4s_v5'
        PrepVMSizeDefault = 'Standard_B4s_v2'

        # Number of image versions to retain per definition when using Clean Image Versions.
        ImageVersionsToKeep = 5

        # Full path to BIS-F on the preparation VM.
        BisFPath = 'C:\_source\Bis-F'

        # Gallery image replication regions. Region2 is optional - leave blank to use one region only.
        ReplicationRegion1         = 'westeurope'
        ReplicationRegion1Replicas = 1
        ReplicationRegion2         = ''
        ReplicationRegion2Replicas = 1

    }

    # =========================================================================
    # Costs - used by scripts\cost-lookup.ps1 (Session Hosts / Infrastructure tabs)
    # =========================================================================

    Costs = @{

        # $false = Linux/base compute rate (correct for Windows 10/11 multisession AVD
        #          and AHB VMs - Windows licence covered by M365, not billed per-VM).
        # $true  = Windows Server PAYG rate (includes Windows Server licence cost).
        PricingWindowsLicence = $false
    }

    # =========================================================================
    # Azure DevOps - used by scripts\tab-azuredevops.ps1
    # =========================================================================

    AzureDevOps = @{

        # Full URL to your Azure DevOps organisation and project.
        # Format: 'https://dev.azure.com/<organisation>/<project>'
        # Leave as '' to disable the tab.
        OrganisationUrl = ''

        # How often the pipeline list auto-refreshes (seconds). Default: 30
        RefreshIntervalSeconds = 30
    }
}