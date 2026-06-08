#!/bin/bash
# update.sh — pull the latest Wolf + Wolf Den images and restart the stack

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ -f "$GOW_CFG" ]] || err "Config not found. The plugin may not be set up yet."
source "$GOW_CFG"

[[ "${DEPLOYED:-false}" == "true" ]] \
    || err "Wolf is not deployed. Complete setup in Settings > Games on Whales first."

COMPOSE_FILE="${APPDATA}/docker-compose.yml"
[[ -f "$COMPOSE_FILE" ]] || err "docker-compose.yml not found at ${COMPOSE_FILE}"

info "Pulling latest Wolf + Wolf Den images..."
docker compose -f "$COMPOSE_FILE" pull

# Recreate the stack with a fresh wolf-socket volume. Wolf now runs PulseAudio
# inside its own container as root; the old WolfPulseAudio sidecar left
# /tmp/sockets owned by the run uid (1000), which makes the embedded PulseAudio
# refuse to start with "XDG_RUNTIME_DIR is not owned by us". down -v drops the
# non-external wolf-socket volume (runtime sockets only) so it comes back
# root-owned; the external nvidia-driver-vol is left untouched.
info "Restarting stack..."
docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
docker rm -f WolfPulseAudio >/dev/null 2>&1 || true
docker compose -f "$COMPOSE_FILE" up -d

info "Update complete."
exit 0
