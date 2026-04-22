# installed-apps.ps1 - List installed applications
#
# Queries both 64-bit and 32-bit Uninstall registry keys to capture all
# installed software. Filters out:
#   - System components (hidden from Programs & Features)
#   - Windows Installer patches
#   - Entries with no DisplayName (orphaned uninstall keys)
#
# Output is sorted alphabetically by application name.

$regPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# Patterns to exclude - uses PowerShell wildcard matching (-like).
# Add entries to hide specific applications from the output. Examples:
#   'Microsoft Edge*'         - excludes anything starting with "Microsoft Edge"
#   '*Visual C++*'            - excludes any name containing "Visual C++"
#   'Remote Desktop*'         - excludes apps starting with "Remote Desktop"
$excludePatterns = @(
)

$apps = foreach ($path in $regPaths) {
    Get-ItemProperty $path -ErrorAction SilentlyContinue |
        Where-Object {
            # Must have a display name
            $_.DisplayName -and
            # Exclude system components (hidden from Programs & Features)
            (-not $_.SystemComponent -or $_.SystemComponent -ne 1) -and
            # Exclude Windows Installer patches
            (-not $_.ParentKeyName)
        }
}

# Remove duplicates (same app in 64-bit and 32-bit keys), apply exclusion filters
$filtered = $apps |
    Sort-Object DisplayName -Unique |
    Where-Object {
        $name = $_.DisplayName
        # Check against all exclusion patterns
        $excluded = $false
        foreach ($p in $excludePatterns) {
            if ($name -like $p) { $excluded = $true; break }
        }
        -not $excluded
    } |
    Select-Object @{N='Application';E={$_.DisplayName}},
                  @{N='Version';E={$_.DisplayVersion}},
                  @{N='Publisher';E={$_.Publisher}} |
    Sort-Object Application

# Output as compact lines to stay within the Azure Run Command ~4KB output limit.
# Format-Table with wide columns can exceed this and cause the top to be truncated.
Write-Output "Installed Applications: $($filtered.Count)"
Write-Output ('=' * 60)
foreach ($app in $filtered) {
    $ver = if ($app.Version) { " [$($app.Version)]" } else { '' }
    Write-Output "$($app.Application)$ver"
}
