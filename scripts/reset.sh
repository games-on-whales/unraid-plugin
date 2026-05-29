#!/bin/bash
# reset.sh — restore plugin settings to defaults without deleting appdata
#
# Stops the Wolf stack, removes generated compose/autostart hooks, and resets
# gow.cfg. User data under APPDATA is intentionally left intact.

set -euo pipefail

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN:  $*" >&2; }

[[ $EUID -eq 0 ]] || err "Must run as root"

DEFAULT_CFG="${GOW_EMHTTP}/default.cfg"
[[ -f "$DEFAULT_CFG" ]] || err "default.cfg not found at ${DEFAULT_CFG}"

APPDATA="${DEFAULT_APPDATA}"
if [[ -f "$GOW_CFG" ]]; then
    # shellcheck disable=SC1090
    source "$GOW_CFG"
    APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
fi

COMPOSE_FILE="${APPDATA}/docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]]; then
    info "Stopping Wolf stack"
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || warn "Could not stop stack cleanly"
fi

if docker inspect WolfPulseAudio &>/dev/null; then
    info "Removing Wolf runtime container WolfPulseAudio"
    docker rm -f WolfPulseAudio >/dev/null 2>&1 || true
fi

GO_SCRIPT="/boot/config/go"
remove_go_block() {
    local marker="$1"
    if grep -qF "$marker" "$GO_SCRIPT" 2>/dev/null; then
        info "Removing '${marker}' from /boot/config/go"
        local end_marker="# End ${marker#\# }"
        local marker_re="${marker//\//\\/}"
        local end_marker_re="${end_marker//\//\\/}"
        if grep -qF "$end_marker" "$GO_SCRIPT" 2>/dev/null; then
            sed -i "/${marker_re}/,/${end_marker_re}/d" "$GO_SCRIPT"
        else
            sed -i "/${marker_re}/,/^$/d" "$GO_SCRIPT"
        fi
    fi
}

remove_go_block "# GoW docker-compose"

info "Restoring default plugin settings"
cp "$DEFAULT_CFG" "$GOW_CFG"

info "Reset complete — open Settings > Games on Whales to configure again"
exit 0
