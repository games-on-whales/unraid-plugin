#!/bin/bash
# fix-all.sh — cleanup stale sessions, re-apply mount presets, restart Wolf.

set -euo pipefail

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN:  $*" >&2; }

[[ $EUID -eq 0 ]] || err "Must run as root"
[[ -f "$GOW_CFG" ]] || err "Config not found at ${GOW_CFG}"
source "$GOW_CFG"

APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
COMPOSE_FILE="${APPDATA}/docker-compose.yml"
SCRIPT_DIR="$(dirname "$0")"

run_step() {
    local script="$1"
    local label="$2"
    [[ -f "$script" ]] || { warn "Missing ${script}; skipping ${label}"; return 0; }
    info "${label}"
    bash "$script" || warn "${label} reported errors (continuing)"
}

run_step "${SCRIPT_DIR}/cleanup-wolf-sessions.sh" "Cleaning stale Wolf session containers"
run_step "${SCRIPT_DIR}/apply-mount-presets.sh" "Re-applying library mount presets"

if [[ -f "$COMPOSE_FILE" ]]; then
    info "Restarting Wolf + Wolf Den"
    docker compose -f "$COMPOSE_FILE" restart wolf wolf-den >/dev/null 2>&1 \
        || warn "Could not restart Wolf stack"
else
    warn "Compose file not found — skipped stack restart"
fi

info "Fix-all complete."
exit 0
