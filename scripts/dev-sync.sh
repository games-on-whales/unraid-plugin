#!/bin/bash
# dev-sync.sh — pull UI + scripts from a local dev HTTP server (see DEVELOPING.md)
set -euo pipefail

BASE_URL="${1:-http://192.168.1.3:8888}"
BASE_URL="${BASE_URL%/}"

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root on Unraid"

# Keep in sync with <FILE Name="&script_dir;/..."> entries in gow.plg + dev-only helpers
SCRIPT_NAMES=(
  vars.sh preinstall.sh install.sh deploy.sh uninstall.sh update.sh reset.sh
  wipe-full.sh library-links.sh wolf-api.sh apply-mount-presets.sh apply-mount-presets.py
  run-python3.sh rom-platform-dirs.sh
  pairing-state.sh repair-esde.sh repair-pegasus.sh repair-frontend-lib.sh detect-paths.sh health-check.sh fix-all.sh
  cleanup-wolf-sessions.sh apply-ui.sh hotfix-page.sh dev-sync.sh dev-test.sh
)

mkdir -p "$GOW_PLUGIN/scripts"

info "Syncing scripts from ${BASE_URL}/scripts/"
for name in "${SCRIPT_NAMES[@]}"; do
  dest="${GOW_PLUGIN}/scripts/${name}"
  wget -qO "$dest" "${BASE_URL}/scripts/${name}" \
    || err "Could not download scripts/${name}"
  sed -i 's/\r$//' "$dest" 2>/dev/null || true
  [[ "$name" == *.sh ]] && chmod +x "$dest"
done

info "Installing settings UI from ${BASE_URL}/dist/settings-ui.txz"
bash "${GOW_PLUGIN}/scripts/hotfix-page.sh" "$BASE_URL"

info "Dev sync complete. Hard-refresh Settings → Games on Whales (Ctrl+F5)."
