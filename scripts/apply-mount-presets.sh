#!/bin/bash
# apply-mount-presets.sh — push plugin library paths into Wolf app runners.
#
# Always patches config.toml (user + Moonlight profiles). Optionally also
# updates Moonlight-profile apps via the Wolf REST API when the socket is up.
# See: https://games-on-whales.github.io/wolf/stable/dev/api.html

set -euo pipefail

source "$(dirname "$0")/vars.sh"
# shellcheck source=run-python3.sh
source "$(dirname "$0")/run-python3.sh"
source "$(dirname "$0")/library-links.sh"
# shellcheck source=wolf-api.sh
source "$(dirname "$0")/wolf-api.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ -f "$GOW_CFG" ]] || err "Config not found at ${GOW_CFG}"
source "$GOW_CFG"

APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
CFG_FILE="${APPDATA}/cfg/config.toml"
PRESET_SCRIPT="$(dirname "$0")/apply-mount-presets.py"
WOLF_SOCKET="${APPDATA}/run/wolf.sock"

[[ -f "$PRESET_SCRIPT" ]] || err "Missing ${PRESET_SCRIPT}"

info "Syncing library symlinks under ${APPDATA}"
gow_resolve_library_mounts "$APPDATA"

# Docker bind mounts need real host directories, not appdata symlinks.
ROMS_LIBRARY="$(gow_mount_source_path "${ROMS_LIBRARY:-}")"
BIOS_LIBRARY="$(gow_mount_source_path "${BIOS_LIBRARY:-}")"
MEDIA_LIBRARY="$(gow_mount_source_path "${MEDIA_LIBRARY:-}")"
STEAM_LIBRARY="$(gow_mount_source_path "${STEAM_LIBRARY:-}")"
GAMES_LIBRARY="$(gow_mount_source_path "${GAMES_LIBRARY:-}")"
LUTRIS_LIBRARY="$(gow_mount_source_path "${LUTRIS_LIBRARY:-}")"
PRISM_LIBRARY="$(gow_mount_source_path "${PRISM_LIBRARY:-}")"
COMPAT_TOOLS_PATH="$(gow_mount_source_path "${COMPAT_TOOLS_PATH:-}")"

LIB_ARGS=(
    "$ROMS_LIBRARY"
    "$BIOS_LIBRARY"
    "$MEDIA_LIBRARY"
    "$STEAM_LIBRARY"
    "$GAMES_LIBRARY"
    "$LUTRIS_LIBRARY"
    "$PRISM_LIBRARY"
    "$COMPAT_TOOLS_PATH"
)

if [[ -z "$ROMS_LIBRARY$BIOS_LIBRARY$MEDIA_LIBRARY$STEAM_LIBRARY$GAMES_LIBRARY$LUTRIS_LIBRARY$PRISM_LIBRARY$COMPAT_TOOLS_PATH" ]]; then
    info "No shared library paths configured; skipping library mount presets"
fi

if [[ ! -f "$CFG_FILE" ]] && ! gow_wolf_api_ready "$APPDATA"; then
    info "Wolf config and API socket not ready; mount presets will apply after Wolf starts"
    exit 0
fi

PRESET_ARGS=(--wolf-socket-host "$WOLF_SOCKET")
if gow_wolf_api_ready "$APPDATA"; then
    info "Moonlight-profile apps: also using Wolf API (${WOLF_SOCKET})"
    PRESET_ARGS+=(--socket "$WOLF_SOCKET")
fi
if [[ -f "$CFG_FILE" ]]; then
    PRESET_ARGS+=("$CFG_FILE")
fi

info "Applying Wolf app runner presets (Wolf UI socket + optional library mounts)"
gow_python3 "$PRESET_SCRIPT" "${PRESET_ARGS[@]}" "${LIB_ARGS[@]}"

exit 0
