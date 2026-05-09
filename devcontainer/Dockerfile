# Shared dev container image
# Bakes the equivalent of the rustler repo's `features:` stack into one image,
# so consuming repos only need a slim devcontainer.json that points here.

FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie

# Avoid interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Base APT packages
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ripgrep \
        neovim \
        tig \
        less \
        jq \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# GitHub CLI (replaces ghcr.io/devcontainers/features/github-cli)
# ---------------------------------------------------------------------------
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# .NET SDK (replaces ghcr.io/devcontainers/features/dotnet)
# ---------------------------------------------------------------------------
RUN curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
 && chmod +x /tmp/dotnet-install.sh \
 && /tmp/dotnet-install.sh --channel 9.0 --install-dir /usr/share/dotnet \
 && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
 && rm /tmp/dotnet-install.sh
ENV DOTNET_ROOT=/usr/share/dotnet
ENV PATH=$PATH:/usr/share/dotnet:/root/.dotnet/tools

# ---------------------------------------------------------------------------
# Cargo extras (replaces ghcr.io/lee-orr/rusty-dev-containers/*)
# Pinned to --locked for reproducibility
# ---------------------------------------------------------------------------
RUN cargo install --locked \
        cargo-audit \
        cargo-expand \
        cargo-llvm-cov \
        sccache \
        git-delta

# ---------------------------------------------------------------------------
# GitHub Copilot CLI (replaces ghcr.io/devcontainers/features/copilot-cli)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://github.com/github/gh-copilot/releases/latest/download/install.sh \
        | bash || echo "WARNING: copilot CLI install failed (non-fatal)"

# ---------------------------------------------------------------------------
# PowerShell (often needed; pulled from MS repo)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/microsoft-debian-trixie-prod trixie main" \
        > /etc/apt/sources.list.d/microsoft.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends powershell \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Default env: sccache as Rust compiler wrapper
# ---------------------------------------------------------------------------
ENV RUSTC_WRAPPER=sccache

# Ship post-create script in a known location for downstream devcontainer.json
COPY post-create.sh /usr/local/bin/post-create.sh
RUN chmod +x /usr/local/bin/post-create.sh

# Verify install
RUN cargo --version && rustc --version && dotnet --version && gh --version \
 && pwsh --version && delta --version && rg --version | head -1
