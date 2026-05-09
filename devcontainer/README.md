# shared devcontainer (staging)

This folder is **not** wired into Codespaces. It's a place to iterate on a
shared dev container image that I can eventually point multiple repos at via:

    { "image": "ghcr.io/<my-org>/devcontainer:latest" }

## Workflow

1. Edit `Dockerfile` / `post-create.sh` here.
2. When ready to publish, move this folder into its own GitHub repo
   (e.g. `<my-org>/devcontainer`), let `.github/workflows/build.yml` push
   the image to ghcr.
3. In each consuming repo, replace `.devcontainer/devcontainer.json` with a
   slimmed copy of `template.devcontainer.json`.

## Files

- `Dockerfile`               — bakes the equivalent of the rustler repo's
                                current `features:` stack into one image.
- `post-create.sh`           — runs in the container after creation
                                (per-Codespace setup, e.g. fix volume perms).
- `template.devcontainer.json` — the slim per-repo file. Only the image
                                ref + per-repo bits (mounts, extensions).
- `.github/workflows/build.yml` — weekly + on-push + on-demand publish to
                                ghcr.io with `pull: true` so base updates
                                flow through.

## Iteration tips while still local

You can build it locally to test:

    docker build -t my-devcontainer:dev devcontainer/
    docker run -it --rm my-devcontainer:dev bash

Or test as a real devcontainer in any repo by symlinking it into place:

    mkdir -p /workspaces/some-repo/.devcontainer
    cp template.devcontainer.json /workspaces/some-repo/.devcontainer/devcontainer.json
    # then: VS Code "Codespaces: Rebuild Container"

## TODOs before publishing

- [ ] Decide host org (GHEMU org or personal account)
- [ ] Update `template.devcontainer.json` image ref
- [ ] Update `build.yml` registry + repo names
- [ ] Confirm package visibility (Internal for cross-org GHEMU pull)
