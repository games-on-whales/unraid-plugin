# Developer How-To

## Overview

The plugin has two installation phases:

1. **Phase 1 (headless, during plugin install)** — `gow.plg` installs the `settings-ui` package, which ships both the emhttp page and all helper scripts. It then runs `preinstall.sh` (checks) and `install.sh` (GPU detection, writes `/boot/config/plugins/gow/gow.cfg`).

   The helper scripts are bundled inside the version-stamped `settings-ui.txz` rather than downloaded as individual `<FILE>` entries. Unraid caches constant-path `<FILE>` downloads and does not refresh them on update unless their MD5 changes, so loose scripts went stale on in-place updates. The `.txz` filename embeds the version, so Unraid always re-fetches it.
2. **Phase 2 (user-triggered, via the settings page)** — the user opens Settings > Games on Whales, picks a GPU and appdata path, and clicks Install. This calls `deploy.sh`, which writes udev rules, generates `docker-compose.yml`, builds the NVIDIA driver volume if needed, and starts Wolf + Wolf Den.

## Prerequisites

- Unraid 6.12+ (for testing in a VM or bare metal)
- Unraid installs plugins by fetching files over HTTP, so you need a local HTTP server to serve your development files.

## Serving files locally

From the repo root:

```sh
# Node.js
npx http-server -p 8888

# Python 3
python3 -m http.server 8888
```

Your files will be available at `http://<your-dev-machine-ip>:8888/`.

## Installing the development version

Build the package first (see [Building the settings-ui package](#building-the-settings-ui-package)) so your script changes are bundled in the `.txz` — they are no longer served loose.

Open `gow.plg` and temporarily change `gitReleaseURL` to point at your local server's `dist/` directory:

```xml
<!ENTITY gitReleaseURL "http://<your-dev-machine-ip>:8888/packages/settings-ui/dist">
```

> Do not commit this change. Revert before pushing.

Then on your Unraid server:

```sh
plugin remove gow.plg          # remove any existing version
plugin install http://<your-dev-machine-ip>:8888/gow.plg
```

## Script reference

| Script | When it runs | What it does |
|---|---|---|
| `preinstall.sh` | Plugin install / boot replay | Unraid version check, plus non-fatal Docker, NVIDIA driver plugin, and network warnings |
| `install.sh` | Plugin install | GPU detection, writes `gow.cfg` (installs `settings-ui.txz` only if `gow.plg` somehow did not) |
| `deploy.sh` | User clicks Install in UI | udev rules, appdata dirs, `docker-compose.yml`, containers, retrying boot hook |
| `uninstall.sh` | Plugin remove | Stops containers, cleans `/boot/config/go`, removes udev rules |
| `update.sh` | User clicks Update in UI | `docker compose pull && up -d` |
| `vars.sh` | Sourced by all scripts | Shared env vars (`GOW_CFG`, `GOW_PLUGIN`, `DEFAULT_APPDATA`, …); reads `GOW_VERSION` from the installed `gow.plg` |

All scripts are shipped inside `settings-ui.txz` and installed to `/boot/config/plugins/gow/scripts/` by `gow.plg`. `scripts/` in the repo is the single source of truth; the package build copies them in.

## Config file

`/boot/config/plugins/gow/gow.cfg` (on the Unraid flash drive, persists across reboots):

```bash
APPDATA=/mnt/user/appdata/gow
RENDER_NODE=/dev/dri/renderD128
GPU_VENDOR=NVIDIA
GPU_NAME=RTX 3090
GPU_DRIVER=nvidia
WOLF_DEN_PORT=8080
WOLF_NETWORK_MODE=host
WOLF_NETWORK_NAME=
WOLF_NETWORK_IPV4=
DEPLOYED=true
```

`install.sh` creates this file. `gow.page` reads and writes it. `deploy.sh` sources it.

## Building the settings-ui package

The emhttp page (`gow.page`), its assets, and the helper scripts are shipped together as a Slackware `.txz` package. Stage the scripts into the package tree first (CI does this automatically; see `auto-release.yml`):

```sh
mkdir -p packages/settings-ui/root/boot/config/plugins/gow/scripts
cp scripts/*.sh packages/settings-ui/root/boot/config/plugins/gow/scripts/
chmod +x packages/settings-ui/root/boot/config/plugins/gow/scripts/*.sh

cd packages/settings-ui/root
../../../utils/fmakepkg.sh ../../../packages/settings-ui/dist/settings-ui.txz
```

The staged scripts under `root/boot/` are gitignored — never commit them.

During development, serve the `dist/` directory from your local HTTP server and point `gitReleaseURL` there (see above). The `.plg` downloads `settings-ui.txz` and renames it to `settings-ui-<version>.txz` on the flash drive.

## Releasing

Releases are automated. Merging to `main` triggers the `auto-release` workflow, which bumps the `version` entity in `gow.plg` to today's date (`YYYY.MM.DD`, with an `a`/`b`/… suffix for same-day hotfixes), tags it, builds the package, and publishes a GitHub release with `settings-ui.txz`, its checksums, and `gow.plg` as assets.

`GOW_VERSION` is read at runtime from the installed `gow.plg`, so there is no second version string to keep in sync. To cut a release with a specific version instead of today's date, run the workflow manually (`workflow_dispatch`) with the `version` input.

## Adding a new package

1. Create `packages/<name>/root/` with the desired filesystem layout.
2. Add `packages/<name>/root/install/slack-desc` (copy an existing one and adapt).
3. Add any start/stop scripts under `packages/<name>/root/boot/config/plugins/gow/scripts/start/` and `.../stop/`.
4. Build with `fmakepkg.sh`, add a `<FILE>` entry in `gow.plg`, and install it in `install.sh`.
