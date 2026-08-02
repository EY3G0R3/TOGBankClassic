param(
    [string]$Source = $PSScriptRoot,
    # When set, no files are copied or deleted -- output shows what *would* happen.
    # Use to verify the destination list, .pkgmeta parsing, and skip patterns
    # before letting the watcher actually mutate target installs.
    [switch]$DryRun
)

$AddonName   = "TOGBankClassic"
$WowBase     = "${env:ProgramFiles(x86)}\World of Warcraft"

# -----------------------------------------------------------------------------
# Single-instance guard -- PER REPO, not per-script-name.
#
# This same watcher script runs concurrently in many addon repos. We must NOT
# bail just because *a* wow-version-replication.ps1 is running somewhere else
# (that's a different addon). The guard is keyed on THIS repo's own source path,
# so:
#   * a second launch on the SAME repo (e.g. a VS Code window reload firing the
#     folderOpen task again) finds the mutex held and exits cleanly -- no racing
#     watchers mangling the same files;
#   * a watcher for a DIFFERENT addon has a different source path -> different
#     mutex name -> both run happily side by side.
#
# A named Mutex (kernel object) is used rather than scanning process command
# lines, because command-line matching is fragile: relative vs absolute launch
# paths, quoting, and "which addon is this" are all unreliable to parse. The
# mutex is released automatically when this process exits (crash, Ctrl+C, or
# normal stop), so a dead watcher never blocks a fresh one.
#
# Skipped in -DryRun: a dry run is a read-only diagnostic and should always run
# even while a real watcher holds the mutex.
$script:InstanceMutex = $null
if (-not $DryRun) {
    # Resolve to a canonical absolute path, lowercased, so the same repo always
    # yields the same key regardless of how it was launched. Non-alphanumeric
    # chars -> '_' because mutex names can't contain '\'.
    $repoKey = (Resolve-Path -LiteralPath $Source -ErrorAction SilentlyContinue).Path
    if (-not $repoKey) { $repoKey = $Source }
    $repoKey = ($repoKey.ToLowerInvariant() -replace '[^a-z0-9]', '_')
    $mutexName = "Global\WowDevSync_$repoKey"
    $createdNew = $false
    try {
        $script:InstanceMutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
    } catch {
        # If the mutex can't be created for any reason, fail open (run anyway)
        # rather than refusing to sync.
        $createdNew = $true
    }
    if (-not $createdNew) {
        Write-Host "A dev sync watcher is already running for this repo ($Source). Exiting." -ForegroundColor Yellow
        exit 0
    }
}

# The WoW client versions TOGBankClassic ships a .toc for -- and ONLY those:
#   _classic_era_  Classic Era  (TOGBankClassic.toc,     Interface 11508)
#   _anniversary_  TBC          (TOGBankClassic_BCC.toc, Interface 20506)
#
# _classic_ (MoP Classic) and _retail_ are deliberately absent: there is no TOC
# for either, so a copy there would sit in the AddOns list permanently flagged
# "out of date" and never load. Adding a flavour here without also adding its
# .toc just litters that install. The script copies into every listed version
# directory that exists on disk, except the one the source tree already lives in
# (avoids copying onto itself).
$WowVersions = @("_classic_era_", "_anniversary_")

# Build list of addon install directories that actually exist on disk
$Destinations = foreach ($ver in $WowVersions) {
    $addonsDir = Join-Path $WowBase "$ver\Interface\AddOns"
    $dest = Join-Path $addonsDir $AddonName
    if ((Test-Path $addonsDir) -and ($Source -notlike "$dest*")) {
        if (-not (Test-Path $dest) -and -not $DryRun) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
        }
        $dest
    }
}

if (-not $Destinations) {
    Write-Host "No target WoW installation found under $WowBase. Exiting." -ForegroundColor Red
    exit 1
}

# -----------------------------------------------------------------------------
# Skip-pattern construction
#
# The goal is for the synced target installs to look like the BigWigs-packaged
# release: only the files that ship to CurseForge, no git/IDE/dev metadata.
# So the skip list is built from two sources:
#   1) .pkgmeta `ignore:` entries -- the canonical "not in the zip" list.
#      Parsed at script start so updates to .pkgmeta automatically apply.
#   2) Always-skip -- git metadata and the script itself, regardless of .pkgmeta.
# -----------------------------------------------------------------------------

function Convert-GlobToRegex([string]$glob) {
    # Normalize forward slashes to backslashes (file paths come in as Windows-style)
    $g = $glob -replace '/', '\'

    # "**\" prefix -> match anywhere in the tree, not just root
    $matchAnywhere = $false
    if ($g.StartsWith('**\')) {
        $g = $g.Substring(3)
        $matchAnywhere = $true
    }

    # Trailing "\" marks a directory; strip it for the literal match
    $isDir = $g.EndsWith('\')
    if ($isDir) {
        $g = $g.TrimEnd('\')
    }

    # Escape regex specials, then turn glob wildcards back into regex equivalents
    $escaped = [regex]::Escape($g)
    $escaped = $escaped -replace '\\\*', '[^\\]*'   # * -> any segment-internal chars
    $escaped = $escaped -replace '\\\?', '[^\\]'    # ? -> one char

    $prefix = if ($matchAnywhere) { '(^|\\)' } else { '^' }
    # Match the entry exactly OR anything beneath it. .pkgmeta lists directories
    # WITHOUT a trailing slash (the BigWigs packager appends "/*"), so a bare
    # "docs" / ".github" entry must still skip the folder's CONTENTS, not just an
    # exact-name file. For real files the "\" branch never matches, so this is
    # equivalent to "$". ($isDir is kept only to strip a trailing slash above.)
    $suffix = '(\\|$)'
    return "$prefix$escaped$suffix"
}

function Get-PkgmetaIgnores([string]$pkgmetaPath) {
    if (-not (Test-Path $pkgmetaPath)) { return @() }
    $ignores  = @()
    $inIgnore = $false
    foreach ($raw in Get-Content $pkgmetaPath) {
        # Strip comments
        $line = $raw -replace '#.*$', ''
        if ($line -match '^ignore:\s*$') {
            $inIgnore = $true
            continue
        }
        if (-not $inIgnore) { continue }
        # End of ignore block: any line that starts at column 0 with non-whitespace,
        # non-list-marker content (i.e. a new top-level YAML key)
        if ($line -match '^\S' -and $line -notmatch '^-') {
            $inIgnore = $false
            continue
        }
        if ($line -match '^\s*-\s+(.+?)\s*$') {
            $entry = $matches[1].Trim()
            # Strip surrounding quotes (single or double)
            $entry = $entry -replace '^["'']', '' -replace '["'']$', ''
            if ($entry) { $ignores += $entry }
        }
    }
    return $ignores
}

# Always-skip -- everything the packager drops without being asked, plus the
# sync script itself. This must NOT rely on .pkgmeta listing these, because
# .pkgmeta deliberately does not: the BigWigs packager prunes dot-prefixed paths
# unconditionally in copy_directory_tree() ...
#   _cdt_find_cmd+=" \( -name \".*\" -a \! -name \".\" \) -prune"
# ... so a `.vscode` / `.luarc.json` entry there matches nothing and is banned as
# misleading clutter. Mirroring the prune here is what lets the two stay in sync:
# any dot-prefixed segment anywhere in the relative path is skipped, exactly like
# the packaged zip.
#
# That covers .git, and it matters more than it looks: this repo's .git is a FILE
# holding a `gitdir:` pointer into C:\Users\ianpl\wow-addon-gitdirs\_classic_era_\
# TOGBankClassic. That pointer is flavour-specific -- copying it into the
# _anniversary_ tree would make git there resolve to the Era repo. A dot-segment
# match catches the pointer file and a .git directory alike.
$AlwaysSkip = @(
    '(^|\\)\.[^\\]+(\\|$)',
    '(^|\\)wow-version-replication\.ps1$'
)

$pkgmetaPath = Join-Path $Source ".pkgmeta"
$pkgIgnores  = Get-PkgmetaIgnores $pkgmetaPath
$pkgPatterns = $pkgIgnores | ForEach-Object { Convert-GlobToRegex $_ }

$SkipPatterns = $AlwaysSkip + $pkgPatterns

Write-Host ""
Write-Host "=== TOGBankClassic Dev Sync ===" -ForegroundColor Magenta
if ($DryRun) {
    Write-Host "(DRY RUN -- no files will be copied or deleted)" -ForegroundColor Yellow
}
Write-Host "Source : $Source"                  -ForegroundColor White
foreach ($d in $Destinations) {
    Write-Host "Target : $d" -ForegroundColor Green
}
if ($pkgIgnores) {
    Write-Host ("Loaded {0} ignore globs from .pkgmeta:" -f $pkgIgnores.Count) -ForegroundColor DarkGray
    foreach ($g in $pkgIgnores) {
        Write-Host "  $g" -ForegroundColor DarkGray
    }
}
Write-Host "Press Ctrl+C to stop." -ForegroundColor White
Write-Host ""

function Skip-Path([string]$rel) {
    foreach ($p in $SkipPatterns) {
        if ($rel -match $p) { return $true }
    }
    return $false
}

function Sync-File([string]$fullPath, [string]$verb) {
    $rel = $fullPath.Substring($Source.Length).TrimStart('\','/')
    if (Skip-Path $rel) {
        if ($DryRun) {
            Write-Host "[skip] $rel" -ForegroundColor DarkGray
        }
        return
    }

    $ts = Get-Date -Format "HH:mm:ss"
    $tag = if ($DryRun) { "WOULD" } else { $verb }

    foreach ($dest in $Destinations) {
        $target = Join-Path $dest $rel
        if ($verb -eq "Deleted") {
            if (Test-Path $target -ErrorAction SilentlyContinue) {
                if (-not $DryRun) {
                    Remove-Item $target -Force -Recurse -ErrorAction SilentlyContinue
                }
                Write-Host "[$ts] $($tag.PadRight(7)) DEL $rel" -ForegroundColor Red
            }
        } else {
            $dir = Split-Path $target -Parent
            if (-not (Test-Path $dir) -and -not $DryRun) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            }
            if (-not $DryRun) {
                # A locked target (WoW open + reading the file, AV scan, editor
                # write-replace in flight) makes Copy-Item throw. Don't let one
                # locked file kill the watcher -- log and let the next poll retry.
                # The file's lastWrite is recorded by the caller regardless, so a
                # transient failure self-heals on the user's next save of that file;
                # for the rarer "locked now, never touched again" case the initial
                # sync on next launch covers it.
                try {
                    Copy-Item $fullPath $target -Force -ErrorAction Stop
                    Write-Host "[$ts] $($tag.PadRight(7)) $rel" -ForegroundColor Cyan
                } catch {
                    Write-Host "[$ts] RETRY   $rel (target busy: $($_.Exception.Message))" -ForegroundColor DarkYellow
                }
            } else {
                Write-Host "[$ts] $($tag.PadRight(7)) $rel" -ForegroundColor Cyan
            }
        }
    }
}

# Full initial sync. Per-file try/catch so one unreadable/locked file (or a
# file that vanishes between enumeration and copy) can't abort the whole initial
# sync and exit the script before the watch loop ever starts -- that was one of
# the launch-time exit-4 crashes.
Write-Host "Initial sync..." -ForegroundColor Yellow
Get-ChildItem -Path $Source -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    try { Sync-File $_.FullName "SYNC" }
    catch { Write-Host "[init] skipped $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
Write-Host "Ready." -ForegroundColor Green
Write-Host ""

# In dry-run mode, exit after the initial sync. The whole point is "show me
# what would happen" -- there's no value in then sitting in a watcher loop.
if ($DryRun) {
    Write-Host "Dry run complete. Nothing was copied or deleted." -ForegroundColor Yellow
    exit 0
}

# Polling watcher -- scans the source tree every 2 seconds and syncs any file
# whose LastWriteTime advanced. Polling instead of Register-ObjectEvent because
# the event-action block runs in a separate runspace where this script's
# functions ($Source, $Destinations, Sync-File) are not in scope, so file
# changes were firing but silently doing nothing. Polling is slower (2 s
# latency) but reliable across PS5.1 / PS7 and across editor save patterns
# (some editors write-replace, which the FileSystemWatcher can mis-fire on).

$lastWrites = @{}
foreach ($f in Get-ChildItem -Path $Source -Recurse -File -Force) {
    $lastWrites[$f.FullName] = $f.LastWriteTimeUtc
}

Write-Host "Watching for changes (Ctrl+C to stop)..." -ForegroundColor Yellow
try {
    while ($true) {
        Start-Sleep -Seconds 2

        # Each poll iteration is wrapped so a transient I/O error never kills
        # the watcher. Real-world triggers seen in the field: Get-ChildItem
        # racing an editor's write-replace (a temp file enumerated then gone
        # mid-scan), a target file briefly locked, a directory vanishing during
        # recursion. Pre-fix, any of these threw out of the loop and the watcher
        # silently died (exit 4) -- the launcher then saw "already launched" and
        # never relaunched, so the target install went stale. Now we log the blip
        # and the next 2 s poll just tries again.
        try {
            # Snapshot the tree once per poll so a mid-enumeration deletion
            # (editor swap-file, .git churn) can't throw partway through.
            $current = Get-ChildItem -Path $Source -Recurse -File -Force -ErrorAction SilentlyContinue

            # Created / Changed
            foreach ($f in $current) {
                $cur  = $f.LastWriteTimeUtc
                $prev = $lastWrites[$f.FullName]
                if ($null -eq $prev) {
                    Sync-File $f.FullName "Created"
                    $lastWrites[$f.FullName] = $cur
                } elseif ($cur -gt $prev) {
                    Sync-File $f.FullName "Changed"
                    $lastWrites[$f.FullName] = $cur
                }
            }

            # Deleted -- any path we knew about that no longer exists on disk.
            # Iterate a static copy of the keys so removing from $lastWrites
            # can't invalidate the enumerator.
            $toRemove = @()
            foreach ($k in @($lastWrites.Keys)) {
                if (-not (Test-Path -LiteralPath $k)) {
                    Sync-File $k "Deleted"
                    $toRemove += $k
                }
            }
            foreach ($k in $toRemove) { $lastWrites.Remove($k) }
        } catch {
            $ts = Get-Date -Format "HH:mm:ss"
            Write-Host "[$ts] WARN    poll skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }
} finally {
    Write-Host "Watcher stopped." -ForegroundColor Yellow
    # Release the per-repo single-instance mutex so the next launch can start.
    if ($script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch {}
        $script:InstanceMutex.Dispose()
    }
}
