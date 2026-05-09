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
$packages = @(
    @{ Name = 'lazygit'; Winget = 'JesseDuffield.Lazygit'; Scoop = 'lazygit'; Command = 'lazygit' },
    @{ Name = 'tig';     Winget = 'jonas.tig';            Scoop = 'tig';     Command = 'tig'     },
    @{ Name = 'delta';   Winget = 'dandavison.delta';     Scoop = 'delta';   Command = 'delta'   },
    @{ Name = 'gh';      Winget = 'GitHub.cli';           Scoop = 'gh';      Command = 'gh'      }
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

# Optional: gh copilot extension
if (Get-Command gh -ErrorAction SilentlyContinue) {
    $hasCopilot = (& gh extension list 2>$null | Select-String -Quiet 'copilot')
    if (-not $hasCopilot) {
        try { & gh extension install github/gh-copilot 2>$null } catch { }
    }
}

# ---------------------------------------------------------------------------
# 2. Symlink dotfiles into $HOME
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
            $stamp = Get-Date -Format 'yyyyMMddHHmmss'
            $backup = "$Destination.bak.$stamp"
            Write-Host "[dotfiles] backing up existing $Destination -> $backup"
            Move-Item -LiteralPath $Destination -Destination $backup -Force
        }
    }

    New-Item -ItemType SymbolicLink -Path $Destination -Target $Source -Force | Out-Null
    Write-Host "[dotfiles] linked $Destination -> $Source"
}

Link-DotFile -Source (Join-Path $dotfilesDir '.gitconfig') `
             -Destination (Join-Path $homeDir '.gitconfig')

Link-DotFile -Source (Join-Path $dotfilesDir '.tigrc') `
             -Destination (Join-Path $homeDir '.tigrc')

# lazygit on Windows looks for config under %APPDATA%\lazygit, not ~/.config/lazygit
$lazygitWinDir = Join-Path $env:APPDATA 'lazygit'
Link-DotFile -Source (Join-Path $dotfilesDir '.config\lazygit') `
             -Destination $lazygitWinDir

# Some tools (and developers used to *nix paths) still look in ~/.config; mirror it too.
Link-DotFile -Source (Join-Path $dotfilesDir '.config\lazygit') `
             -Destination (Join-Path $homeDir '.config\lazygit')

# ---------------------------------------------------------------------------
# 3. PowerShell profile — source equivalent of bash_profile (PS-friendly bits)
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

Write-Host "[dotfiles] done"
