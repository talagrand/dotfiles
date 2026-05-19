<#
.SYNOPSIS
    Idempotent dotfiles installer for native Windows.

.DESCRIPTION
    Mirror of install.sh for PowerShell on Windows. Installs CLI tools via
    winget (with scoop fallback) and creates symlinks from the dotfiles
    repo into $HOME ($env:USERPROFILE).

    Symlink creation requires either:
      - Developer Mode enabled (Settings → Privacy → For developers), or
      - An elevated (Administrator) PowerShell session.

    Tested on Windows 10/11 with PowerShell 5.1 and PowerShell 7+.

.NOTES
    Use install.sh on Linux/WSL/Codespaces/macOS. Use install.ps1 on
    native Windows. Both consume the same config files in the repo.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$dotfilesDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$homeDir     = $env:USERPROFILE
Write-Host "[dotfiles] installing from $dotfilesDir"

# ---------------------------------------------------------------------------
# 0. Detect environment & symlink capability
# ---------------------------------------------------------------------------
function Test-CanCreateSymlink {
    # Try to make a probe symlink in TEMP; if it succeeds we're good.
    $probe  = Join-Path $env:TEMP ("dotfiles-symlink-probe-" + [guid]::NewGuid())
    $target = Join-Path $env:TEMP ("dotfiles-symlink-target-" + [guid]::NewGuid())
    try {
        New-Item -ItemType File -Path $target -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $probe -Target $target -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $probe, $target
    }
}

if (-not (Test-CanCreateSymlink)) {
    Write-Warning "Cannot create symlinks. Enable Developer Mode (recommended) or run this script as Administrator."
    Write-Warning "  Settings → Privacy & security → For developers → Developer Mode"
    throw "Symlink creation not permitted."
}

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
function Install-WithWinget {
    param([string]$Id)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        return $false
    }
    Write-Host "[dotfiles] winget install $Id"
    & winget install --silent --accept-source-agreements --accept-package-agreements --id $Id
    return ($LASTEXITCODE -eq 0)
}

function Install-WithScoop {
    param([string]$Pkg)
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        return $false
    }
    Write-Host "[dotfiles] scoop install $Pkg"
    & scoop install $Pkg
    return ($LASTEXITCODE -eq 0)
}

# Map of friendly name -> @(wingetId, scoopName, command-to-test)
# Prefer winget on Windows — it provides an update story (`winget upgrade --all`).
#
# NOTE: `tig` is intentionally omitted. It ships as part of Git-for-Windows
# (`C:\Program Files\Git\cmd\tig.exe`), which we assume is already
# installed on any Windows dev machine. Installing the winget `jonas.tig`
# package would shadow the Git-for-Windows copy in PATH for no gain.
$packages = @(
    @{ Name = 'lazygit';    Winget = 'JesseDuffield.Lazygit'; Scoop = 'lazygit';    Command = 'lazygit' },
    @{ Name = 'delta';      Winget = 'dandavison.delta';      Scoop = 'delta';      Command = 'delta'   },
    @{ Name = 'difftastic'; Winget = 'Wilfred.difftastic';    Scoop = 'difftastic'; Command = 'difft'   },
    @{ Name = 'gh';         Winget = 'GitHub.cli';            Scoop = 'gh';         Command = 'gh'      }
)

foreach ($p in $packages) {
    if (Get-Command $p.Command -ErrorAction SilentlyContinue) {
        Write-Host "[dotfiles] $($p.Name) already installed"
        continue
    }
    $ok = Install-WithWinget -Id $p.Winget
    if (-not $ok) { $ok = Install-WithScoop -Pkg $p.Scoop }
    if (-not $ok) {
        Write-Warning "[dotfiles] failed to install $($p.Name) (no winget or scoop, or install failed)"
    }
}

# gh extensions
if (Get-Command gh -ErrorAction SilentlyContinue) {
    $extList = (& gh extension list 2>$null) | Out-String
    if ($extList -notmatch 'gh-dash') {
        try { & gh extension install dlvhdr/gh-dash 2>$null } catch { }
    }
}

# ---------------------------------------------------------------------------
# 2. Migrate machine-local sections out of existing ~/.gitconfig
# ---------------------------------------------------------------------------
# On first run, the user's existing ~/.gitconfig gets moved to a .bak file
# and replaced by a symlink to the dotfiles version. Without help, that
# would strip the user's identity and per-org credentials from git's live
# config until they manually copied them back. This function migrates the
# safe-to-move sections (identity, credentials, lfs filter) into
# ~/.gitconfig.local before the symlink swap. It is idempotent — keys that
# already exist in ~/.gitconfig.local are left alone.
function Migrate-LocalSections {
    param(
        [Parameter(Mandatory)] [string]$Source,       # e.g. ~/.gitconfig
        [Parameter(Mandatory)] [string]$Destination   # e.g. ~/.gitconfig.local
    )

    if (-not (Test-Path -LiteralPath $Source)) { return }

    $item = Get-Item -LiteralPath $Source -Force
    $isSymlink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint
    if ($isSymlink) { return }  # already managed by dotfiles, nothing to migrate

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warning "[dotfiles] git not on PATH; cannot migrate machine-local sections from $Source"
        return
    }

    # Each pattern is fed to `git config --get-regexp`. Keep this list narrow:
    # only sections that are genuinely per-machine/per-user identity, never
    # things the dotfiles base config intends to own (core/diff/merge/alias/...).
    $patterns = @('^user\.', '^credential\.', '^filter\.lfs\.')

    $migrated = New-Object System.Collections.Generic.List[string]
    $skipped  = New-Object System.Collections.Generic.List[string]

    foreach ($pattern in $patterns) {
        $entries = @(& git config --file $Source --get-regexp $pattern 2>$null)
        if ($LASTEXITCODE -ne 0 -or $entries.Count -eq 0) { continue }

        foreach ($line in $entries) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $idx = $line.IndexOf(' ')
            if ($idx -lt 0) { continue }
            $key   = $line.Substring(0, $idx)
            $value = $line.Substring($idx + 1)

            & git config --file $Destination --get $key *> $null
            if ($LASTEXITCODE -eq 0) {
                $skipped.Add($key)
            } else {
                & git config --file $Destination --add $key $value
                $migrated.Add("$key = $value")
            }
        }
    }

    if ($migrated.Count -gt 0 -or $skipped.Count -gt 0) {
        Write-Host ""
        Write-Host "[dotfiles] machine-local migration: $Source -> $Destination"
        if ($migrated.Count -gt 0) {
            Write-Host "  migrated $($migrated.Count):"
            $migrated | ForEach-Object { Write-Host "    + $_" }
        }
        if ($skipped.Count -gt 0) {
            $leaf = Split-Path -Leaf $Destination
            Write-Host "  skipped $($skipped.Count) (already present in $leaf):"
            $skipped | ForEach-Object { Write-Host "    = $_" }
        }
        Write-Host "  (original $Source backed up under ~/.dotfiles-backup/<timestamp>/ below)"
        Write-Host ""
    }
}

# ---------------------------------------------------------------------------
# 3. Centralized backups (used by Link-DotFile and Build-GhDashConfig)
# ---------------------------------------------------------------------------
# Anything we overwrite (non-symlink) on a first run goes under one per-run
# directory: ~/.dotfiles-backup/<timestamp>/<relative-path-under-HOME>.
# Restore = copy back from there. manifest.txt records every backup.
$script:BackupRoot  = $null
$script:BackupCount = 0

function Get-BackupRoot {
    if (-not $script:BackupRoot) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $script:BackupRoot = Join-Path $homeDir ".dotfiles-backup\$stamp"
    }
    $script:BackupRoot
}

function Save-Backup {
    param([Parameter(Mandatory)] [string] $Source)
    if (-not (Test-Path -LiteralPath $Source)) { return }
    # Skip if the source is itself a symlink (it's our own prior install).
    $item = Get-Item -LiteralPath $Source -Force
    $isSymlink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint
    if ($isSymlink) { return }

    # Compute relpath. $env:APPDATA lives under $env:USERPROFILE on Windows,
    # so a single homeDir-strip handles AppData paths too.
    $homePrefix = $homeDir.TrimEnd('\','/')
    if ($Source.StartsWith($homePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $Source.Substring($homePrefix.Length).TrimStart('\','/')
    } else {
        $rel = Join-Path '_other' (Split-Path -Leaf $Source)
    }

    $root = Get-BackupRoot
    $dest = Join-Path $root $rel
    $destParent = Split-Path -Parent $dest
    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Source -PathType Container) {
        Copy-Item -LiteralPath $Source -Destination $dest -Recurse -Force
        $kind = 'dir '
    } else {
        Copy-Item -LiteralPath $Source -Destination $dest -Force
        $kind = 'file'
    }

    $manifest = Join-Path $root 'manifest.txt'
    if (-not (Test-Path -LiteralPath $manifest)) {
        $hdr = @(
            '# dotfiles installer backup manifest'
            "# created: $(Get-Date -Format 'o')"
            "# host:    $env:COMPUTERNAME"
            "# user:    $env:USERNAME"
            ''
        ) -join "`r`n"
        Set-Content -LiteralPath $manifest -Value $hdr -Encoding UTF8
    }
    $line = "$(Get-Date -Format 'o')`t$kind`t$Source`t->`t$rel"
    Add-Content -LiteralPath $manifest -Value $line -Encoding UTF8

    $script:BackupCount++
    Write-Host "[dotfiles] backed up $Source -> $dest"
}

# ---------------------------------------------------------------------------
# 4. Symlink dotfiles into $HOME
# ---------------------------------------------------------------------------
function Link-DotFile {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Warning "[dotfiles] source missing, skipping: $Source"
        return
    }

    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Destination) {
        $item = Get-Item -LiteralPath $Destination -Force
        $isSymlink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint
        if ($isSymlink) {
            # Already a symlink — delete & recreate (cheap, makes target swap atomic)
            Remove-Item -LiteralPath $Destination -Force -Recurse
        } else {
            Save-Backup -Source $Destination
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
    }

    New-Item -ItemType SymbolicLink -Path $Destination -Target $Source -Force | Out-Null
    Write-Host "[dotfiles] linked $Destination -> $Source"
}

# ---------------------------------------------------------------------------
# Generate ~/.config/gh-dash/config.yml from template + auto-discovered repos
# ---------------------------------------------------------------------------
# gh-dash has no YAML-include / env-var expansion for `repoPaths`, so the
# live config file can't simply be a symlink to the template. Instead, we
# concatenate the template + a generated `repoPaths:` block produced by
# scanning configured roots for github clones.
function Build-GhDashConfig {
    param(
        [Parameter(Mandatory)] [string]   $Template,
        [Parameter(Mandatory)] [string]   $Destination,
        [Parameter(Mandatory)] [string[]] $Roots
    )

    if (-not (Test-Path -LiteralPath $Template)) {
        Write-Warning "[dotfiles] gh-dash template missing: $Template"
        return
    }
    $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
    if (-not $hasGit) {
        Write-Warning "[dotfiles] git not on PATH; gh-dash repoPaths will be empty"
    }

    # Scan each root for `.git` (directory OR file -- the latter for worktrees).
    $repoPaths = [ordered]@{}
    $scanned = 0
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        if (-not $hasGit) { continue }
        $gitItems = Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -Force `
                                  -Filter '.git' -ErrorAction SilentlyContinue
        foreach ($g in $gitItems) {
            $scanned++
            $parent = Split-Path -Parent $g.FullName
            $url = & git -C $parent remote get-url origin 2>$null
            if (-not $url -or $LASTEXITCODE -ne 0) { continue }
            if ($url -match '(?i)(?:https?://|git@)github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$') {
                $key = "$($matches[1])/$($matches[2])"
                if (-not $repoPaths.Contains($key)) {
                    $repoPaths[$key] = $parent
                }
            }
        }
    }

    # Ensure parent dir exists as a real directory (handle legacy symlink leftover).
    $parentDir = Split-Path -Parent $Destination
    if ($parentDir -and (Test-Path -LiteralPath $parentDir)) {
        $pitem = Get-Item -LiteralPath $parentDir -Force
        $pIsSymlink = ($pitem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint
        if ($pIsSymlink) {
            # No backup needed -- symlink content lives in the dotfiles repo itself.
            Write-Host "[dotfiles] $parentDir was a symlink (legacy installer); removing to create real directory"
            Remove-Item -LiteralPath $parentDir -Force
        }
    }
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # Back up any existing live file we didn't generate ourselves.
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $existing = Get-Content -LiteralPath $Destination -Raw -ErrorAction SilentlyContinue
        if ($existing -notmatch 'AUTO-APPENDED by dotfiles installer') {
            Save-Backup -Source $Destination
        }
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append((Get-Content -LiteralPath $Template -Raw))
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# ----- AUTO-APPENDED by dotfiles installer at $stamp -----")
    [void]$sb.AppendLine("# Discovered repos under: $($Roots -join '; ')")
    [void]$sb.AppendLine("# Override roots via env var DOTFILES_REPO_ROOTS (semicolon-separated).")
    [void]$sb.AppendLine("# DO NOT EDIT below this line by hand -- re-run install.ps1 instead.")
    if ($repoPaths.Count -gt 0) {
        [void]$sb.AppendLine("repoPaths:")
        foreach ($k in $repoPaths.Keys) {
            [void]$sb.AppendLine("  ${k}: $($repoPaths[$k])")
        }
    } else {
        [void]$sb.AppendLine("# (no github clones found under the configured roots)")
    }

    Set-Content -LiteralPath $Destination -Value $sb.ToString() -NoNewline -Encoding UTF8
    Write-Host "[dotfiles] generated $Destination (scanned $scanned git checkouts, $($repoPaths.Count) github clones)"
}

# Migrate identity/credentials/lfs from existing ~/.gitconfig (if not a symlink)
# into ~/.gitconfig.local BEFORE we replace ~/.gitconfig with our symlink.
Migrate-LocalSections -Source (Join-Path $homeDir '.gitconfig') `
                      -Destination (Join-Path $homeDir '.gitconfig.local')

Link-DotFile -Source (Join-Path $dotfilesDir '.gitconfig') `
             -Destination (Join-Path $homeDir '.gitconfig')

# Windows-only override file: [core] autocrlf=true, etc.
# install.sh deliberately does NOT symlink this on Linux/Mac, so the
# corresponding [include] in .gitconfig is a silent no-op there.
Link-DotFile -Source (Join-Path $dotfilesDir '.gitconfig.windows') `
             -Destination (Join-Path $homeDir '.gitconfig.windows')

Link-DotFile -Source (Join-Path $dotfilesDir '.tigrc') `
             -Destination (Join-Path $homeDir '.tigrc')

# lazygit on Windows looks for config under %APPDATA%\lazygit, not ~/.config/lazygit
$lazygitWinDir = Join-Path $env:APPDATA 'lazygit'
Link-DotFile -Source (Join-Path $dotfilesDir '.config\lazygit') `
             -Destination $lazygitWinDir

# Some tools (and developers used to *nix paths) still look in ~/.config; mirror it too.
Link-DotFile -Source (Join-Path $dotfilesDir '.config\lazygit') `
             -Destination (Join-Path $homeDir '.config\lazygit')

# gh-dash: NOT a symlink -- generated from template + auto-discovered repoPaths.
# Default scan roots: C:\src ; T:\src. Override via $env:DOTFILES_REPO_ROOTS
# (semicolon-separated list of absolute paths).
$ghDashRoots = if ($env:DOTFILES_REPO_ROOTS) {
    $env:DOTFILES_REPO_ROOTS -split ';' | Where-Object { $_ }
} else {
    @('C:\src', 'T:\src')
}
Build-GhDashConfig -Template    (Join-Path $dotfilesDir '.config\gh-dash\config.yml') `
                   -Destination (Join-Path $homeDir '.config\gh-dash\config.yml') `
                   -Roots       $ghDashRoots

# ---------------------------------------------------------------------------
# 5. PowerShell profile — source equivalent of bash_profile (PS-friendly bits)
# ---------------------------------------------------------------------------
# We do NOT try to source bash_profile from PowerShell — it's bash syntax.
# If you want shared aliases, put them in a profile.ps1 inside the dotfiles
# repo and adapt this block to dot-source it. For now, just nudge the user.

$profileFile = $PROFILE.CurrentUserAllHosts
$profileDir  = Split-Path -Parent $profileFile
if ($profileDir -and -not (Test-Path -LiteralPath $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

$marker = "# dotfiles: PowerShell profile hook"
$profilePs1 = Join-Path $dotfilesDir 'profile.ps1'
if (Test-Path -LiteralPath $profilePs1) {
    $line = ". '$profilePs1'  $marker"
    $existing = if (Test-Path -LiteralPath $profileFile) { Get-Content -LiteralPath $profileFile -Raw } else { '' }
    if ($existing -notmatch [regex]::Escape($marker)) {
        Add-Content -LiteralPath $profileFile -Value "`n$line"
        Write-Host "[dotfiles] appended profile hook to $profileFile"
    }
} else {
    Write-Host "[dotfiles] (no profile.ps1 in repo — skipping PowerShell profile hook)"
}

if ($script:BackupCount -gt 0) {
    Write-Host ""
    Write-Host "[dotfiles] $($script:BackupCount) item(s) backed up under $(Get-BackupRoot)"
    Write-Host "[dotfiles] (review/restore from there, then delete when satisfied)"
}

Write-Host "[dotfiles] done"
