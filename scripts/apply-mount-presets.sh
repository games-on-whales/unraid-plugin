#!/bin/bash
# apply-mount-presets.sh — push plugin library paths into Wolf app runners.
#
# Always patches config.toml (user + Moonlight profiles). Optionally also
# updates Moonlight-profile apps via the Wolf REST API when the socket is up.
# See: https://games-on-whales.github.io/wolf/stable/dev/api.html

set -euo pipefail

source "$(dirname "$0")/vars.sh"
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

if [[ -z "$ROMS_LIBRARY$BIOS_LIBRARY$MEDIA_LIBRARY$STEAM_LIBRARY$GAMES_LIBRARY$LUTRIS_LIBRARY$COMPAT_TOOLS_PATH" ]]; then
    info "No shared library paths configured; skipping mount presets"
    exit 0
fi

LIB_ARGS=(
    "$ROMS_LIBRARY"
    "$BIOS_LIBRARY"
    "$MEDIA_LIBRARY"
    "$STEAM_LIBRARY"
    "$GAMES_LIBRARY"
    "$LUTRIS_LIBRARY"
    "$COMPAT_TOOLS_PATH"
)

if [[ ! -f "$CFG_FILE" ]] && ! gow_wolf_api_ready "$APPDATA"; then
    info "Wolf config and API socket not ready; mount presets will apply after Wolf starts"
    exit 0
fi

PRESET_ARGS=()
if gow_wolf_api_ready "$APPDATA"; then
    info "Moonlight-profile apps: also using Wolf API (${WOLF_SOCKET})"
    PRESET_ARGS+=(--socket "$WOLF_SOCKET")
fi
if [[ -f "$CFG_FILE" ]]; then
    PRESET_ARGS+=("$CFG_FILE")
fi

info "Applying library mount presets (config.toml + optional API)"
python3 "$PRESET_SCRIPT" "${PRESET_ARGS[@]}" "${LIB_ARGS[@]}"

exit 0
