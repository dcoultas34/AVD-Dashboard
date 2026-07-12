# Auto-update

The dashboard (`avd-live-dashboard.ps1`) and Profile Tools (`profile-tools.ps1`) can update
themselves from this repo. This document covers how it works and how to publish a release.

## How it works (user side)

- On launch, before the Azure sign-in prompt, the app resolves the current HEAD commit of
  `main` via the GitHub API, then fetches `update-manifest.json` from a commit-pinned
  `raw.githubusercontent.com/<repo>/<sha>/` URL and compares each listed file's SHA-256 hash
  against the local copy. Commit pinning means the CDN's ~5 minute branch-URL cache can never
  serve a stale manifest, and the manifest and files are guaranteed to come from the same
  commit even if a push lands mid-update. If the API lookup fails (rate-limited, blocked),
  it falls back to the plain `main` branch URL.
- If the manifest can't be reached (repo is private, offline, DNS failure, etc.) the
  automatic check fails **completely silently** - a log line only, no dialog. This is the
  expected steady state whenever this repo isn't public. The manual button (below) always
  shows a response instead.
- If some files differ, a dialog shows a "What's new" excerpt from the changelog, lists the
  changed files, and offers **Update** / **Not now**. When the release version matches but
  files differ (a hotfix pushed without a version bump), the wording says "An updated build
  is available" rather than showing identical Current/New versions.
- Accepting shows a small progress window while every changed file is downloaded to a temp
  folder and validated (parses `.ps1`/`.psd1` files, checks `.xaml` is well-formed XML,
  re-hashes everything against the manifest). Only if **all** of them pass does it back up
  each file into the `backup` folder (mirroring the folder structure, so the pre-update
  version of every file it changes is kept) and replace the live files.
  - If a replacement fails partway, everything already replaced is **rolled back** from the
    `backup` copies and the failure dialog says exactly what happened.
  - Files the running process has locked (in practice `lib\*.dll`, loaded at startup) are
    written as `<file>.new` instead; the post-update relaunch swaps them into place at the
    very top of the script, before anything loads them (`Complete-DashboardPendingUpdate`).
- On success it relaunches the same script with the same command-line arguments it was
  originally started with (hidden console, matching the `.cmd` launchers).
- A manual **Check for Updates** button lives in each app's About dialog, for checking without
  waiting for the next launch (and it tells you when you're already up to date or when the
  check couldn't run, unlike the silent automatic check).
- Pass `-SkipUpdateCheck` to either script to disable the automatic check entirely (the manual
  button still works).

Implementation: `scripts/update-check.ps1` (dot-sourced near the top of both apps, before any
`Add-Type`, so the pending-swap can run while nothing has the DLLs loaded). Check call sites:
`avd-live-dashboard.ps1` (before `Connect-AzureDashboard`, and in `Show-About`) and
`profile-tools.ps1` (same pattern; skipped automatically when launched as a companion process
from the dashboard, since the dashboard already checked).

## `update-manifest.json`

Lives at the repo root. Shape:

```json
{
  "version": "2026-07-11.2",
  "notes": "## 2026-07-11.2\n- What changed...",
  "files": [
    { "path": "avd-live-dashboard.ps1", "sha256": "...", "size": 291421 },
    { "path": "scripts/tab-sessionhosts.ps1", "sha256": "...", "size": 372010 }
  ]
}
```

- `version` is read from `$ScriptVersion` in `avd-live-dashboard.ps1` and is purely
  informational (shown in the update prompt) - the actual change detection is per-file hash
  comparison, not a version-number check, so partial releases (only some files changed) only
  download what actually changed.
- `notes` is the newest section of `CHANGELOG.md` (capped ~1500 chars), shown as "What's new"
  in the update prompt.
- `path` is repo-relative, forward-slashed. `sha256` is `(Get-FileHash -Algorithm SHA256).Hash`.

Not every file in the repo is included - see `$includeGlobs` in
`tools/New-UpdateManifest.ps1` for the current list. Customer-specific and gitignored files
(`config/config.psd1`, `config/*.psd1` other than `EXAMPLE-config.psd1`, `logs/`, `CLAUDE.md`,
`ISSUES.md`) are never part of the manifest and are never touched by an update.

## Line endings

`.gitattributes` disables all eol conversion (`* -text`) so working trees, blobs, zips, and
raw downloads are byte-identical - otherwise a clone made with `core.autocrlf=true` would
hash every text file differently from the blobs GitHub serves and the updater would report
all files as changed. Text files are committed with LF (one-time normalization done
2026-07-11); `.cmd` files keep CRLF (cmd.exe label parsing is unreliable with bare LF).
Editors should write LF for new files in this repo.

## Publishing a release

1. Bump `$ScriptVersion` in `avd-live-dashboard.ps1` (and `profile-tools.ps1`, if it changed
   too) and add a `CHANGELOG.md` section - the newest section becomes the update prompt's
   "What's new" text. Use `YYYY-MM-DD` or `YYYY-MM-DD.rev` for same-day releases.
2. Commit and push to `main` - the pre-commit hook (`.githooks/pre-commit`) regenerates
   `update-manifest.json` and stages it automatically on every commit.

One-time setup after cloning (hooks aren't versioned by git itself):

```powershell
git config core.hooksPath .githooks
```

Without the hook, run `.\tools\New-UpdateManifest.ps1` manually before committing. Either
way, commit everything together - the manifest hashes the working tree, so committing with
unstaged edits to shipped files would publish hashes that don't match the pushed blobs.
