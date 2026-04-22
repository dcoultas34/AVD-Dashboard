#
# Environment configuration for AVD Live Dashboard and Profile Tools.
# Edit this file for each deployment - the scripts themselves do not need modification.
#
# Author  : virtualwebber (https://github.com/virtualwebber)
#

@{

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
        # Hidden tabs are fully collapsed - their header and content are not visible.
        # Valid names: 'Per Host Pool', 'By Region', 'Session Hosts', 'Azure Files', 'Monitoring', 'Infrastructure', 'Azure DevOps'
        # Example: @('Monitoring', 'Azure Files')
        HiddenTabs = @()

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

        # Audit logging - records destructive actions (logoff, drain, power actions,
        # run commands, profile delete/unlock, shadow/RDP, send message) to daily
        # CSV files in the logs/ subfolder next to the dashboard script.
        # File format: logs/audit-YYYY-MM-DD.csv
        # Default: $true (enabled)
        EnableAuditLog = $true
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
        # 'MSTSC' = mstsc.exe (Remote Desktop) - recommended
        # 'MSRA'  = msra.exe  (Remote Assistance)
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
        # Value = full UNC path to the share including the fslogix subfolder
        StorageAccountShareMap = @{
            'salivedashboard2'    = '\\salivedashboard2.file.core.windows.net\fslogix'
            'salivedashboardtest' = '\\salivedashboardtest.file.core.windows.net\fslogix'
            'sauksprofiles1'      = '\\sauksprofiles1.file.core.windows.net\fslogix'
            'saukwprofiles1'      = '\\saukwprofiles1.file.core.windows.net\fslogix'
        }

        # Account names to exclude from profile tool tabs and scans.
        # Excluded accounts are still checked during profile deletion operations.
        # Leave as @() to include all accounts.
        ExcludeStorage = @()

        # Azure File Share name (the share itself — must match the share name in the UNC paths above).
        FileShareName = 'fslogix'

        # Sub-path within the file share where profile folders live.
        # e.g. 'fslogix' if profiles are at \\share\profiles\fslogix\<username>
        # Leave as '' if profiles are directly at the share root (\\share\profiles\<username>).
        FileShareSubPath = ''

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