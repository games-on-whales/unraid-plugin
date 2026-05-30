# Developer How-To

## Overview

The plugin has two installation phases:

1. **Phase 1 (headless, during plugin install)** — `preinstall.sh` runs checks, `install.sh` detects GPUs and writes `/boot/config/plugins/gow/gow.cfg`, and the `settings-ui` package is installed to register the emhttp page.
2. **Phase 2 (user-triggered, via the settings page)** — the user opens Settings > Games on Whales, picks a GPU and appdata path, and clicks Install. This calls `deploy.sh`, which writes udev rules, generates `docker-compose.yml`, builds the NVIDIA driver volume if needed, and starts Wolf + Wolf Den.

## Prerequisites

- Unraid 6.12+ (for testing in a VM or bare metal)
- Unraid installs plugins by fetching files over HTTP, so you need a local HTTP server to serve your development files.

## Local checks

From the repo root:

```sh
bash scripts/dev-test.sh
```

This validates mount-preset logic against a sample `config.toml`, compiles the Python helper, and syntax-checks shell scripts.

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
| `preinstall.sh` | Plugin install / boot replay | Unraid version check, plus non-fatal Docker, NVIDIA driver plugin, and network warnings |
| `install.sh` | Plugin install | GPU detection, writes `gow.cfg`, installs `settings-ui.txz` |
| `deploy.sh` | User clicks Install in UI | udev rules, appdata dirs, `docker-compose.yml`, containers, retrying boot hook |
| `uninstall.sh` | Plugin remove | Stops containers, cleans `/boot/config/go`, removes udev rules |
| `update.sh` | User clicks Update in UI | `docker compose pull && up -d --force-recreate`, re-applies mounts |
| `vars.sh` | Sourced by all scripts | Shared env vars (`GOW_CFG`, `GOW_PLUGIN`, `DEFAULT_APPDATA`, …) |
| `utils.sh` | Sourced by install/update | Package name/URL helpers and checksum-verified downloads |
| `pairing-state.sh` | Sourced by deploy/update | Backup/restore Wolf pairing identity (`config.toml`, `key.pem`, `cert.pem`) |
| `library-links.sh` | Deploy/update/mount presets | Symlink user library paths under `${APPDATA}/` when they live outside GoW appdata |
| `wolf-api.sh` | Other scripts | `curl` helpers for Wolf's Unix-socket REST API (`/api/v1/*`) |
| `apply-mount-presets.sh` / `.py` | Deploy/update/fix | Apply library mounts via Wolf API when `${APPDATA}/run/wolf.sock` is up, else patch `config.toml` |
| `run-python3.sh` | Sourced by mount/repair scripts | Host `python3` or Docker `python:3-alpine` fallback (Unraid has no Python) |
| `rom-platform-dirs.sh` | detect-paths / health | Bash platform folder names for ROM root scoring |
| `detect-paths.sh` | `install.sh` (first cfg) | Suggest existing ROM/BIOS/Steam/etc. share paths when folders exist |
| `repair-esde.sh` | UI Advanced | Restore ES-DE Custom Scripts config and re-apply ROM/BIOS mounts |
| `cleanup-wolf-sessions.sh` | UI / stop / Fix mounts | Remove exited `Wolf*` session containers that hold memory |
| `health-check.sh` | CLI | Print stack health; exit code reflects healthy/degraded/unhealthy |
| `fix-all.sh` | UI "Fix mounts" | Cleanup sessions, re-apply mount presets, restart Wolf |
| `dev-test.sh` | Local dev | Run mount-preset unit checks and `bash -n` on all scripts (no Unraid required) |
| `reset.sh` | UI "Reset to Defaults" | Reset plugin settings to defaults (appdata kept) |
| `hotfix-page.sh` | Dev | Hot-swap the settings page during development |
| `apply-ui.sh` | Dev / after plugin update | Re-run `installpkg` on the newest `settings-ui-*.txz` under `/boot/config/plugins/gow/packages/` |

## Config file

`/boot/config/plugins/gow/gow.cfg` (on the Unraid flash drive, persists across reboots):

```bash
APPDATA=/mnt/user/appdata/gow
ROMS_LIBRARY=/mnt/user/games/roms
BIOS_LIBRARY=/mnt/user/games/bioses
STEAM_LIBRARY=/mnt/user/games/steam
GAMES_LIBRARY=/mnt/user/games
LUTRIS_LIBRARY=/mnt/user/games/lutris
PRISM_LIBRARY=/mnt/user/games/prismlauncher
WOLF_IMAGE=ghcr.io/games-on-whales/wolf:stable
WOLF_DEN_IMAGE=ghcr.io/games-on-whales/wolf-den:stable
WOLF_ENCODER_NODE=
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

The emhttp page (`gow.page`) and its assets are shipped as a Slackware `.txz` package.

```sh
cd packages/settings-ui/root
../../../utils/fmakepkg.sh ../../../packages/settings-ui/dist/settings-ui-<version>.txz
cd ../dist
sha256sum settings-ui-<version>.txz | awk '{print $1}' > settings-ui-<version>.txz.sha256
md5sum    settings-ui-<version>.txz | awk '{print $1}' > settings-ui-<version>.txz.md5
```

Update the `<SHA256>` and `<MD5>` fields in `gow.plg` after each rebuild.

During development, serve the **repo root** (not only `packages/settings-ui/dist`) from your local HTTP server so both `gow-dev.plg`, `scripts/*`, and `dist/settings-ui.txz` are reachable. Point `gitReleaseURL` at `http://<ip>:8888/dist` (see above).

### UI changes not showing on Unraid

The settings page (`gow.page`, `php/*`) is **not** read from `/boot/config/plugins/gow/`. It is installed into `/usr/local/emhttp/plugins/gow/` by `installpkg` when the plugin runs `install.sh`. These actions **do not** refresh the UI:

- Clicking **Update Images** on the GoW dashboard (that only updates Wolf Docker images).
- Editing files on your PC without rebuilding and reinstalling the txz.
- Updating only shell scripts on the server (unless you also reinstall the txz).

**Check what is actually installed** (on Unraid as root):

```sh
grep -c gow-health-card /usr/local/emhttp/plugins/gow/gow.page
ls -la /usr/local/emhttp/plugins/gow/php/
ls -lt /boot/config/plugins/gow/packages/settings-ui-*.txz
```

If `gow-health-card` is missing, the running UI is still an old build. Fix:

1. Rebuild the package (from `packages/settings-ui/root`):
   ```sh
   ../../../utils/fmakepkg.sh ../../../dist/settings-ui.txz
   ```
2. Serve `dist/settings-ui.txz` from your dev machine (`python3 -m http.server 8888` in the repo root).
3. On Unraid, either:
   - `bash /boot/config/plugins/gow/scripts/hotfix-page.sh http://<dev-ip>:8888` (downloads txz and runs `installpkg`), or
     - Copy `settings-ui.txz` to `/boot/config/plugins/gow/packages/settings-ui-2026.05.30.txz` and run:
     ```sh
     bash /boot/config/plugins/gow/scripts/apply-ui.sh
     ```
   - Or **Plugins → Games on Whales → Update** after publishing a matching GitHub release (version in `gow.plg` must match the tag that ships `settings-ui.txz`).

4. Hard-refresh the browser (Ctrl+F5). If the page is still wrong, reload nginx: `/etc/rc.d/rc.nginx reload`.

Production installs pull `settings-ui.txz` from the GitHub **release** for the version in `gow.plg`. Bumping `gow.plg` to `2026.05.29` without a `2026.05.29` release tag leaves the plugin update unable to fetch the new txz.

## Scripts not shipped in `gow.plg`

<<<<<<< HEAD
These stay in the repo for development and support; the plugin installer does not download them:
=======
Active feature work is split into four branches on top of `games-on-whales/unraid-plugin` `main`. Merge in order:
>>>>>>> cbb6549 (Add advanced gow.cfg keys for images and encoder GPU)

| Script | Purpose |
|--------|---------|
| `dev-test.sh` | Local mount-preset and syntax checks |
| `hotfix-page.sh` | Dev: install a local `settings-ui.txz` without full plugin bump |
| `wipe-full.sh` | Destructive uninstall helper (manual use only) |

`utils.sh` is legacy; install/update use `vars.sh` and release URLs from `gow.plg`.

## Releasing

1. Update the `version` entity in `gow.plg` to today's date (`YYYY.MM.DD`). For same-day hotfixes, append a suffix such as `a`.
2. Update `GOW_VERSION` in `scripts/vars.sh` to match.
3. Commit and merge the release change, then create a git tag matching the version:
   ```sh
   git tag 2026.04.10
   git push origin 2026.04.10
   ```
4. The `release` GitHub Actions workflow triggers automatically, builds the package, and creates a GitHub release with `settings-ui.txz`, its checksums, and `gow.plg` as release assets. The moving install/update URL points at that latest release asset, so do not bump `version` without publishing the matching tag.

## Adding a new package

1. Create `packages/<name>/root/` with the desired filesystem layout.
2. Add `packages/<name>/root/install/slack-desc` (copy an existing one and adapt).
3. Add any start/stop scripts under `packages/<name>/root/boot/config/plugins/gow/scripts/start/` and `.../stop/`.
4. Build with `fmakepkg.sh`, add a `<FILE>` entry in `gow.plg`, and install it in `install.sh`.
