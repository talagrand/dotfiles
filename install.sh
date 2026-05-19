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

# delta + difftastic: prefer apt (gives an update story via `apt upgrade`);
# fall back to cargo on systems where the apt package isn't available
# (older Debian/Ubuntu, etc.).
if ! command -v delta >/dev/null; then
  if apt-cache show git-delta >/dev/null 2>&1; then
    sudo apt-get install -y git-delta
  elif command -v cargo >/dev/null; then
    cargo install --locked git-delta
  else
    echo "[dotfiles] WARNING: could not install delta (no apt package, no cargo)"
  fi
fi

if ! command -v difft >/dev/null; then
  if apt-cache show difftastic >/dev/null 2>&1; then
    sudo apt-get install -y difftastic
  elif command -v cargo >/dev/null; then
    cargo install --locked difftastic
  else
    echo "[dotfiles] WARNING: could not install difftastic (no apt package, no cargo)"
  fi
fi

# gh extensions if gh is present
if command -v gh >/dev/null; then
  if ! gh extension list 2>/dev/null | grep -q gh-dash; then
    gh extension install dlvhdr/gh-dash 2>/dev/null || true
  fi
fi

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
migrate_local_sections() {
  local src="$1" dst="$2"
  [ -e "$src" ] || return 0
  if [ -L "$src" ]; then return 0; fi  # already managed by dotfiles
  if ! command -v git >/dev/null; then
    echo "[dotfiles] WARNING: git not on PATH; cannot migrate machine-local sections from $src"
    return 0
  fi

  # Keep this list narrow: only sections that are per-machine/per-user identity,
  # never things the dotfiles base config intends to own (core/diff/merge/alias/...).
  local patterns=( '^user\.' '^credential\.' '^filter\.lfs\.' )

  local migrated=0 skipped=0 header_printed=0
  for pattern in "${patterns[@]}"; do
    local entries
    entries="$(git config --file "$src" --get-regexp "$pattern" 2>/dev/null || true)"
    [ -z "$entries" ] && continue

    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local key="${line%% *}"
      local value="${line#* }"

      if [ "$header_printed" -eq 0 ]; then
        echo ""
        echo "[dotfiles] machine-local migration: $src -> $dst"
        header_printed=1
      fi

      if git config --file "$dst" --get "$key" >/dev/null 2>&1; then
        echo "    = $key  (already in $(basename "$dst"))"
        skipped=$((skipped + 1))
      else
        git config --file "$dst" --add "$key" "$value"
        echo "    + $key = $value"
        migrated=$((migrated + 1))
      fi
    done <<< "$entries"
  done

  if [ "$header_printed" -eq 1 ]; then
    echo "  migrated $migrated, skipped $skipped"
    echo "  (original $src backed up under ~/.dotfiles-backup/<timestamp>/ below)"
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# 3. Centralized backups (used by link and build_gh_dash_config)
# ---------------------------------------------------------------------------
# Anything we overwrite (non-symlink) on a first run goes under one per-run
# directory: ~/.dotfiles-backup/<timestamp>/<relative-path-under-HOME>.
# Restore = copy back from there. manifest.txt records every backup.
DOTFILES_BACKUP_ROOT=""
DOTFILES_BACKUP_COUNT=0

_iso_now() {
  date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

_backup_root() {
  if [ -z "$DOTFILES_BACKUP_ROOT" ]; then
    DOTFILES_BACKUP_ROOT="$HOME/.dotfiles-backup/$(date '+%Y%m%d-%H%M%S')"
  fi
  printf '%s\n' "$DOTFILES_BACKUP_ROOT"
}

save_backup() {
  local src="$1"
  [ -e "$src" ] || return 0
  if [ -L "$src" ]; then return 0; fi  # source itself is a symlink -- skip

  local home="${HOME%/}"
  local rel
  case "$src" in
    "$home"/*) rel="${src#$home/}" ;;
    *)         rel="_other/$(basename "$src")" ;;
  esac

  local root; root="$(_backup_root)"
  local dest="$root/$rel"
  mkdir -p "$(dirname "$dest")"

  local kind
  if [ -d "$src" ]; then
    cp -a "$src" "$dest"
    kind="dir "
  else
    cp -a "$src" "$dest"
    kind="file"
  fi

  local manifest="$root/manifest.txt"
  if [ ! -e "$manifest" ]; then
    {
      echo "# dotfiles installer backup manifest"
      echo "# created: $(_iso_now)"
      echo "# host:    $(hostname)"
      echo "# user:    ${USER:-$(id -un)}"
      echo ""
    } > "$manifest"
  fi
  printf '%s\t%s\t%s\t->\t%s\n' "$(_iso_now)" "$kind" "$src" "$rel" >> "$manifest"

  DOTFILES_BACKUP_COUNT=$((DOTFILES_BACKUP_COUNT + 1))
  echo "[dotfiles] backed up $src -> $dest"
}

# ---------------------------------------------------------------------------
# 4. Symlink dotfiles into $HOME
# ---------------------------------------------------------------------------
link() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    save_backup "$dst"
    rm -rf "$dst"
  fi
  ln -sfn "$src" "$dst"
  echo "[dotfiles] linked $dst -> $src"
}

# ---------------------------------------------------------------------------
# Generate ~/.config/gh-dash/config.yml from template + auto-discovered repos
# ---------------------------------------------------------------------------
# gh-dash has no YAML-include / env-var expansion for `repoPaths`, so the
# live config file can't simply be a symlink to the template. Instead, we
# concatenate the template + a generated `repoPaths:` block produced by
# scanning configured roots for github clones.
build_gh_dash_config() {
  local template="$1" dest="$2"
  shift 2
  local roots=("$@")
  if [ ! -e "$template" ]; then
    echo "[dotfiles] WARNING: gh-dash template missing: $template"
    return 0
  fi
  if ! command -v git >/dev/null; then
    echo "[dotfiles] WARNING: git not on PATH; gh-dash repoPaths will be empty"
  fi

  local scanned=0 found=0 seen=""
  local tmpfile; tmpfile="$(mktemp)"

  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r -d '' gitpath; do
      scanned=$((scanned + 1))
      local parent; parent="$(dirname "$gitpath")"
      local url;    url="$(git -C "$parent" remote get-url origin 2>/dev/null || true)"
      [ -z "$url" ] && continue
      local ownerrepo=""
      case "$url" in
        https://github.com/*|http://github.com/*) ownerrepo="${url#http*://github.com/}" ;;
        git@github.com:*)                         ownerrepo="${url#git@github.com:}" ;;
        *) continue ;;
      esac
      ownerrepo="${ownerrepo%.git}"
      ownerrepo="${ownerrepo%/}"
      # Sanity: must be exactly owner/repo (one slash).
      case "$ownerrepo" in
        */*/*) continue ;;
        */*)   ;;
        *)     continue ;;
      esac
      # Dedupe (first wins, matches PowerShell behavior).
      case ",$seen," in
        *",$ownerrepo,"*) continue ;;
      esac
      seen="$seen,$ownerrepo"
      printf '  %s: %s\n' "$ownerrepo" "$parent" >> "$tmpfile"
      found=$((found + 1))
    done < <(find "$root" -maxdepth 5 -name .git -print0 2>/dev/null)
  done

  local destdir; destdir="$(dirname "$dest")"
  if [ -L "$destdir" ]; then
    # No backup needed -- symlink content lives in the dotfiles repo itself.
    echo "[dotfiles] $destdir was a symlink (legacy installer); removing to create real directory"
    rm "$destdir"
  fi
  mkdir -p "$destdir"

  # Back up any existing live file we didn't generate ourselves.
  if [ -f "$dest" ] && ! grep -q 'AUTO-APPENDED by dotfiles installer' "$dest" 2>/dev/null; then
    save_backup "$dest"
  fi

  local stamp_human; stamp_human="$(date '+%Y-%m-%d %H:%M:%S %z')"
  local roots_csv;   roots_csv="$(IFS=: ; echo "${roots[*]}")"
  {
    cat "$template"
    echo ""
    echo "# ----- AUTO-APPENDED by dotfiles installer at $stamp_human -----"
    echo "# Discovered repos under: $roots_csv"
    echo "# Override roots via env var DOTFILES_REPO_ROOTS (colon-separated)."
    echo "# DO NOT EDIT below this line by hand -- re-run install.sh instead."
    if [ "$found" -gt 0 ]; then
      echo "repoPaths:"
      cat "$tmpfile"
    else
      echo "# (no github clones found under the configured roots)"
    fi
  } > "$dest"
  rm -f "$tmpfile"

  echo "[dotfiles] generated $dest (scanned $scanned git checkouts, $found github clones)"
}

# Migrate identity/credentials/lfs from existing ~/.gitconfig (if not a symlink)
# into ~/.gitconfig.local BEFORE we replace ~/.gitconfig with our symlink.
migrate_local_sections "$HOME/.gitconfig" "$HOME/.gitconfig.local"

link "$DOTFILES_DIR/.gitconfig"             "$HOME/.gitconfig"

# Unix-only override file: [core] editor=vim, etc.
# install.ps1 deliberately does NOT symlink this on Windows, so the
# corresponding [include] in .gitconfig is a silent no-op there.
link "$DOTFILES_DIR/.gitconfig.linux"       "$HOME/.gitconfig.linux"

link "$DOTFILES_DIR/.tigrc"                 "$HOME/.tigrc"
link "$DOTFILES_DIR/.config/lazygit"        "$HOME/.config/lazygit"

# gh-dash: NOT a symlink -- generated from template + auto-discovered repoPaths.
# Default scan root: $HOME/src. Override via DOTFILES_REPO_ROOTS (colon-separated).
if [ -n "${DOTFILES_REPO_ROOTS:-}" ]; then
  IFS=':' read -ra GH_DASH_ROOTS <<< "$DOTFILES_REPO_ROOTS"
else
  GH_DASH_ROOTS=("$HOME/src")
fi
build_gh_dash_config "$DOTFILES_DIR/.config/gh-dash/config.yml" \
                     "$HOME/.config/gh-dash/config.yml" \
                     "${GH_DASH_ROOTS[@]}"

# Append bash_profile sourcing once
BP_LINE="source $DOTFILES_DIR/bash_profile  # dotfiles"
if ! grep -Fqx "$BP_LINE" "$HOME/.bashrc" 2>/dev/null; then
  echo "" >> "$HOME/.bashrc"
  echo "$BP_LINE" >> "$HOME/.bashrc"
  echo "[dotfiles] appended bash_profile source to ~/.bashrc"
fi

if [ "$DOTFILES_BACKUP_COUNT" -gt 0 ]; then
  echo ""
  echo "[dotfiles] $DOTFILES_BACKUP_COUNT item(s) backed up under $DOTFILES_BACKUP_ROOT"
  echo "[dotfiles] (review/restore from there, then delete when satisfied)"
fi

echo "[dotfiles] done"
