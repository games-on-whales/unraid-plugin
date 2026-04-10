# Developer How-To

## Overview

The plugin has two installation phases:

1. **Phase 1 (headless, during plugin install)** — `preinstall.sh` runs checks, `install.sh` detects GPUs and writes `/boot/config/plugins/gow/gow.cfg`, and the `settings-ui` package is installed to register the emhttp page.
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

Open `gow.plg` and temporarily change `gitPkgURL` to point at your local server:

```xml
<!ENTITY gitPkgURL "http://<your-dev-machine-ip>:8888">
```

Also change `gitReleaseURL` to the same base with `/packages/settings-ui/dist`:

```xml
<!ENTITY gitReleaseURL "http://<your-dev-machine-ip>:8888/packages/settings-ui/dist">
```

> Do not commit these changes. Revert before pushing.

Then on your Unraid server:

```sh
plugin remove gow.plg          # remove any existing version
plugin install http://<your-dev-machine-ip>:8888/gow.plg
```

## Script reference

| Script | When it runs | What it does |
|---|---|---|
| `preinstall.sh` | Plugin install | Unraid version, Docker, NVIDIA driver plugin, network checks |
| `install.sh` | Plugin install | GPU detection, writes `gow.cfg`, installs `settings-ui.txz` |
| `deploy.sh` | User clicks Install in UI | udev rules, appdata dirs, `docker-compose.yml`, containers, boot hooks |
| `uninstall.sh` | Plugin remove | Stops containers, cleans `/boot/config/go`, removes udev rules |
| `update.sh` | User clicks Update in UI | `docker compose pull && up -d` |
| `vars.sh` | Sourced by all scripts | Shared env vars (`GOW_CFG`, `GOW_PLUGIN`, `DEFAULT_APPDATA`, …) |

## Config file

`/boot/config/plugins/gow/gow.cfg` (on the Unraid flash drive, persists across reboots):

```bash
APPDATA=/mnt/user/appdata/gow
RENDER_NODE=/dev/dri/renderD128
GPU_VENDOR=NVIDIA
GPU_NAME=RTX 3090
GPU_DRIVER=nvidia
DEPLOYED=true
```

`install.sh` creates this file. `gow.page` reads and writes it. `deploy.sh` sources it.

## Building the settings-ui package

The emhttp page (`gow.page`) and its assets are shipped as a Slackware `.txz` package.

```sh
cd packages/settings-ui/root
../../../utils/fmakepkg.sh ../../../packages/settings-ui/dist/settings-ui-<version>.txz
cd ../dist
sha256sum settings-ui-<version>.txz | awk '{print $1}' > settings-ui-<version>.txz.sha256
md5sum    settings-ui-<version>.txz | awk '{print $1}' > settings-ui-<version>.txz.md5
```

Update the `<SHA256>` and `<MD5>` fields in `gow.plg` after each rebuild.

During development, serve the `dist/` directory from your local HTTP server and point `gitReleaseURL` there (see above).

## Releasing

1. Update the `version` entity in `gow.plg` to today's date (`YYYY.MM.DD`).
2. Update `GOW_VERSION` in `scripts/vars.sh` to match.
3. Rebuild `settings-ui.txz` (see above) and update the hashes in `gow.plg`.
4. Commit and push, then create a git tag matching the version:
   ```sh
   git tag 2026.04.10
   git push origin 2026.04.10
   ```
5. The `release` GitHub Actions workflow triggers automatically, builds the package, and creates a GitHub release with `settings-ui.txz`, its checksums, and `gow.plg` as release assets.

## Adding a new package

1. Create `packages/<name>/root/` with the desired filesystem layout.
2. Add `packages/<name>/root/install/slack-desc` (copy an existing one and adapt).
3. Add any start/stop scripts under `packages/<name>/root/boot/config/plugins/gow/scripts/start/` and `.../stop/`.
4. Build with `fmakepkg.sh`, add a `<FILE>` entry in `gow.plg`, and install it in `install.sh`.
