<#
.SYNOPSIS
    Regenerates update-manifest.json for the AVD Dashboard auto-update feature.
.DESCRIPTION
    Hashes every file the dashboard/profile-tools ship with, reads $ScriptVersion out of
    avd-live-dashboard.ps1, and writes update-manifest.json to the repo root. Run this
    before pushing to main so the published manifest matches what's actually in the repo.
    See scripts\update-check.ps1 for the consumer side (what fetches and applies this).
.EXAMPLE
    .\tools\New-UpdateManifest.ps1
#>
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

# Fail hard on any error rather than writing a partial manifest: a broken environment once
# turned every Get-FileHash call into a non-terminating error and a zero-file manifest was
# written and committed. The pre-commit hook treats a non-zero exit as "leave the existing
# manifest alone", which is always safer than publishing garbage.
$ErrorActionPreference = 'Stop'

$includeGlobs = @(
    'avd-live-dashboard.ps1'
    'profile-tools.ps1'
    'README.md'
    'CHANGELOG.md'
    'AUTO-UPDATE.md'
    '.gitattributes'
    'scripts\*.ps1'
    'data\*.xaml'
    'data\run-commands.psd1'
    'data\kql\*.kql'
    'data\runcommands\*.ps1'
    'lib\*.dll'
    'config\EXAMPLE-config.psd1'
    '*.cmd'
    'tools\*.ps1'
)

$files = foreach ($glob in $includeGlobs) {
    Get-ChildItem -Path (Join-Path $RepoRoot $glob) -File -ErrorAction SilentlyContinue
}
$files = @($files | Sort-Object FullName -Unique)

if (-not $files.Count) {
    throw "No files matched the include list under '$RepoRoot' - check `$includeGlobs and -RepoRoot."
}

$mainScriptPath = Join-Path $RepoRoot 'avd-live-dashboard.ps1'
$versionLine = Get-Content -Path $mainScriptPath | Where-Object { $_ -match '^\$ScriptVersion\s*=\s*"([^"]+)"' } | Select-Object -First 1
if (-not $versionLine -or $versionLine -notmatch '^\$ScriptVersion\s*=\s*"([^"]+)"') {
    throw "Could not find `$ScriptVersion in $mainScriptPath"
}
$version = $matches[1]

$manifestFiles = foreach ($f in $files) {
    $relPath = $f.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
    [PSCustomObject]@{
        path   = $relPath
        sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        size   = $f.Length
    }
}
$manifestFiles = @($manifestFiles | Sort-Object path)

# Guard against publishing hashes GitHub will never serve: the hashes above come from the
# working tree, but raw.githubusercontent.com serves the committed blob bytes. If the two
# diverge (classic cause: line-ending drift between the index and the working tree), the
# update check flags those files forever on fresh downloads and applying the update never
# converges. Hash each staged blob (git cat-file blob :<path>) and warn on any mismatch.
# Raw bytes must come via Process redirection - PowerShell pipelines mangle binary output.
$divergent = @()
try {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    foreach ($mf in $manifestFiles) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git'
        $psi.Arguments = 'cat-file blob ":{0}"' -f $mf.path
        $psi.WorkingDirectory = $RepoRoot
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $ms = New-Object System.IO.MemoryStream
        $proc.StandardOutput.BaseStream.CopyTo($ms)
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { continue }  # untracked file - nothing staged to compare against
        $blobHash = (($sha256.ComputeHash($ms.ToArray()) | ForEach-Object { $_.ToString('X2') }) -join '')
        if ($blobHash -ne $mf.sha256) { $divergent += $mf.path }
    }
} catch {}
if ($divergent.Count) {
    # [Console]::Error so it survives the pre-commit hook's stdout redirect (Write-Warning
    # goes to stdout when powershell.exe output is redirected).
    [Console]::Error.WriteLine(("WARNING: manifest hashes were computed from the working tree, but these files differ from their staged blobs (GitHub serves blob bytes, so the update check would flag them forever): {0}. Run 'git add' on them and re-run this script." -f ($divergent -join ', ')))
}

# Newest CHANGELOG.md section (first "## " heading to the next) becomes the "What's new"
# text in the update prompt. Capped so the manifest stays small.
$notes = ''
try {
    $changelogPath = Join-Path $RepoRoot 'CHANGELOG.md'
    if (Test-Path -LiteralPath $changelogPath) {
        $lines = Get-Content -Path $changelogPath
        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^## ') {
                if ($start -lt 0) { $start = $i } else { break }
            }
        }
        if ($start -ge 0) {
            $end = if ($i -lt $lines.Count) { $i - 1 } else { $lines.Count - 1 }
            $notes = (($lines[$start..$end] -join "`n").Trim())
            if ($notes.Length -gt 1500) { $notes = $notes.Substring(0, 1500).TrimEnd() + ' [...]' }
        }
    }
} catch {}

$manifest = [PSCustomObject]@{
    version = $version
    notes   = $notes
    files   = $manifestFiles
}

$outPath = Join-Path $RepoRoot 'update-manifest.json'
$json = $manifest | ConvertTo-Json -Depth 4
# -Encoding UTF8 in Windows PowerShell 5.1 always writes a BOM, which breaks
# ConvertFrom-Json on the consuming side (Invoke-WebRequest.Content includes the BOM
# character, and the JSON parser rejects it as "Invalid JSON primitive"). Write plain
# UTF-8 without a BOM instead.
[System.IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Wrote $outPath - version $version, $($manifestFiles.Count) file(s)" -ForegroundColor Green
