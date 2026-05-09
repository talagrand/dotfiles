# dotfiles

Personal shell + git + TUI configuration that follows me into every Codespace.

## What it sets up

- `git` with `delta` as the pager (side-by-side, navigate, line numbers)
- `lazygit` configured to expand the focused panel — survivable in narrow terminals
- `tig` with vertically-stacked panes — readable on small windows
- `bash` profile with `PAGER='less -RFX'`, a few aliases, and a clean prompt
- Installs: `lazygit`, `tig`, `git-delta`, `gh` extensions

## How GitHub Codespaces uses this

Point GitHub at this repo:

  Settings → Codespaces → Dotfiles → "Automatically install dotfiles"

On every new Codespace, GitHub will:

1. Clone this repo to `~/dotfiles/`.
2. Run `install.sh` (because it exists and is executable).

`install.sh` is idempotent — safe to re-run by hand.

## Manual install on other machines

| Environment | Command |
| ----------- | ------- |
| Linux / WSL2 / macOS | `git clone <repo> ~/dotfiles && ~/dotfiles/install.sh` |
| Native Windows (PowerShell) | `git clone <repo> $env:USERPROFILE\dotfiles; & $env:USERPROFILE\dotfiles\install.ps1` |

Both scripts are idempotent. Re-run after pulling new commits to pick up changes.

### Native Windows prerequisites

- **Enable Developer Mode** (Settings → Privacy & security → For developers).
  This lets non-admin users create symlinks. Otherwise run `install.ps1`
  from an elevated PowerShell window.
- The script installs CLIs via `winget`, falling back to `scoop` if winget
  isn't present. Install one of them first if neither exists.
- For the best terminal experience, install **Windows Terminal**
  (`winget install Microsoft.WindowsTerminal`).

## What's NOT auto-applied

- Anything under `devcontainer/` — that's a staging area for a shared dev
  container image. See `devcontainer/README.md`.
