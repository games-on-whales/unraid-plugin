#!/bin/bash
# update.sh — pull the latest Wolf + Wolf Den images and restart the stack

set -euo pipefail

source "$(dirname "$0")/vars.sh"
source "$(dirname "$0")/pairing-state.sh"
source "$(dirname "$0")/library-links.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN:  $*" >&2; }

[[ -f "$GOW_CFG" ]] || err "Config not found. The plugin may not be set up yet."
source "$GOW_CFG"

[[ "${DEPLOYED:-false}" == "true" ]] \
    || err "Wolf is not deployed. Complete setup in Settings > Games on Whales first."

COMPOSE_FILE="${APPDATA}/docker-compose.yml"
[[ -f "$COMPOSE_FILE" ]] || err "docker-compose.yml not found at ${COMPOSE_FILE}"

pull_with_retry() {
    local attempt=1
    local max_attempts=3
    while (( attempt <= max_attempts )); do
        info "Pulling latest Wolf + Wolf Den images (attempt ${attempt}/${max_attempts})..."
        if docker compose -f "$COMPOSE_FILE" pull; then
            return 0
        fi
        warn "Image pull failed on attempt ${attempt}"
        (( attempt++ ))
        sleep 5
    done
    return 1
}

pull_with_retry || err "Image pull failed after multiple attempts"

backup_pairing_state
prepare_pairing_state

info "Recreating stack with updated images..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate --remove-orphans

verify_pairing_state

if [[ -x "$(dirname "$0")/cleanup-wolf-sessions.sh" ]]; then
    bash "$(dirname "$0")/cleanup-wolf-sessions.sh" || true
fi

if [[ -f "${APPDATA}/cfg/config.toml" ]] && [[ -x "$(dirname "$0")/apply-mount-presets.sh" ]]; then
    info "Refreshing library symlinks under ${APPDATA}"
    gow_resolve_library_mounts "$APPDATA"
    if bash "$(dirname "$0")/apply-mount-presets.sh"; then
        info "Restarting Wolf so app runner mount presets stay in sync..."
        docker compose -f "$COMPOSE_FILE" restart wolf >/dev/null 2>&1 || true
    fi
fi

info "Update complete."
exit 0
