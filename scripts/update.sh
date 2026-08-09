#!/bin/bash
# update.sh — pull the latest Wolf + Wolf Den images and restart the stack

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN:  $*" >&2; }

source "$(dirname "$0")/app-state.sh"

# Re-owning app state needs root, same as deploy.sh.
[[ $EUID -eq 0 ]] || err "Must run as root"

[[ -f "$GOW_CFG" ]] || err "Config not found. The plugin may not be set up yet."
source "$GOW_CFG"

APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
COMPOSE_FILE="${APPDATA}/docker-compose.yml"

# A generated compose file is what "deployed" actually means. The DEPLOYED flag
# is only a cache of that, and it goes stale: an install that predates the flag,
# or a gow.cfg rewritten without it, left users with a running stack that Update
# refused to touch while the settings page happily showed it as deployed.
[[ -f "$COMPOSE_FILE" ]] \
    || err "Wolf is not deployed (no docker-compose.yml at ${COMPOSE_FILE}). Complete setup in Settings > Games on Whales first."

if [[ "${DEPLOYED:-false}" != "true" ]]; then
    info "Marking Wolf as deployed (found ${COMPOSE_FILE})"
    if grep -q '^DEPLOYED=' "$GOW_CFG"; then
        sed -i "s|^DEPLOYED=.*|DEPLOYED=true|" "$GOW_CFG"
    else
        printf "DEPLOYED=true\n" >> "$GOW_CFG"
    fi
fi

resolve_run_ids \
    || err "App run UID/GID must be numbers between 1 and 65533 (got ${WOLF_RUN_UID}:${WOLF_RUN_GID})"

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

# New images can ship a new run uid, and users reach for Update Images rather
# than Install after a plugin update — so the state on disk has to be checked
# here too, not only in deploy.sh (issue #66). Runs with the stack down: Wolf
# rewrites config.toml as it shuts down, which would undo the run-id rewrite.
sync_app_state_ownership

docker compose -f "$COMPOSE_FILE" up -d

info "Update complete."
exit 0
