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

info "Restarting stack..."
docker compose -f "$COMPOSE_FILE" up -d

info "Update complete."
exit 0
