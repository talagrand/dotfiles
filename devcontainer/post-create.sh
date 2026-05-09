#!/usr/bin/env bash
# Runs once per Codespace after the container is created.
# Idempotent: safe to re-run if needed.
set -euo pipefail

echo "[post-create] starting"

# Fix ownership of cargo + target volume mounts so the codespace user can write
if [ -d /usr/local/cargo ]; then
  sudo chown -R "$(id -u):$(id -g)" /usr/local/cargo || true
fi
if [ -d "${WORKSPACE_FOLDER:-/workspaces}/target" ]; then
  sudo chown -R "$(id -u):$(id -g)" "${WORKSPACE_FOLDER:-/workspaces}/target" || true
fi

# Ensure cargo bin on PATH for this user
if ! grep -q 'cargo/env' "$HOME/.bashrc" 2>/dev/null; then
  echo '. "$HOME/.cargo/env" 2>/dev/null || true' >> "$HOME/.bashrc"
fi

# Trust the workspace as a safe git directory (Codespaces sometimes mounts
# it with different ownership than the codespace user)
git config --global --add safe.directory '*' || true

echo "[post-create] done"
