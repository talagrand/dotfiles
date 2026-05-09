#!/usr/bin/env bash
# Idempotent dotfiles installer.
# Run by GitHub Codespaces on container creation; also safe to run by hand.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "[dotfiles] installing from $DOTFILES_DIR"

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------
NEED_APT=()
command -v lazygit >/dev/null || NEED_APT+=(lazygit)
command -v tig     >/dev/null || NEED_APT+=(tig)
command -v less    >/dev/null || NEED_APT+=(less)

if [ ${#NEED_APT[@]} -gt 0 ]; then
  echo "[dotfiles] apt install: ${NEED_APT[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends "${NEED_APT[@]}"
fi

# delta: prefer apt if available, otherwise cargo (Codespaces ships rust)
if ! command -v delta >/dev/null; then
  if apt-cache show git-delta >/dev/null 2>&1; then
    sudo apt-get install -y git-delta
  elif command -v cargo >/dev/null; then
    cargo install --locked git-delta
  else
    echo "[dotfiles] WARNING: could not install delta (no apt package, no cargo)"
  fi
fi

# Optional: gh copilot extension if gh is present
if command -v gh >/dev/null && ! gh extension list 2>/dev/null | grep -q copilot; then
  gh extension install github/gh-copilot 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 2. Symlink dotfiles into $HOME
# ---------------------------------------------------------------------------
link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    cp -a "$dst" "${dst}.bak.$(date +%s)"
    rm -rf "$dst"
  fi
  ln -sfn "$src" "$dst"
  echo "[dotfiles] linked $dst -> $src"
}

link "$DOTFILES_DIR/.gitconfig"             "$HOME/.gitconfig"
link "$DOTFILES_DIR/.tigrc"                 "$HOME/.tigrc"
link "$DOTFILES_DIR/.config/lazygit"        "$HOME/.config/lazygit"

# Append bash_profile sourcing once
BP_LINE="source $DOTFILES_DIR/bash_profile  # dotfiles"
if ! grep -Fqx "$BP_LINE" "$HOME/.bashrc" 2>/dev/null; then
  echo "" >> "$HOME/.bashrc"
  echo "$BP_LINE" >> "$HOME/.bashrc"
  echo "[dotfiles] appended bash_profile source to ~/.bashrc"
fi

echo "[dotfiles] done"
