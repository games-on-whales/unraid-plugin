#!/bin/bash
# wipe-full.sh — remove GoW/Wolf stack, hooks, UI package, and appdata for a clean reinstall.
#
# Does NOT remove the plugin entry from Unraid's Plugins page by default.
# Pass --remove-plugin to also delete /boot/config/plugins/gow.plg and the plugin folder.

set -euo pipefail

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN:  $*" >&2; }

[[ $EUID -eq 0 ]] || err "Must run as root"

REMOVE_PLUGIN=false
for arg in "$@"; do
    case "$arg" in
        --remove-plugin) REMOVE_PLUGIN=true ;;
        -h|--help)
            echo "Usage: wipe-full.sh [--remove-plugin]"
            echo "  Stops Wolf, removes hooks/udev, settings UI package, and appdata."
            echo "  --remove-plugin  Also removes gow.plg and /boot/config/plugins/gow"
            exit 0
            ;;
        *) err "Unknown option: $arg (try --help)" ;;
    esac
done

APPDATA="${DEFAULT_APPDATA}"
if [[ -f "$GOW_CFG" ]]; then
    # shellcheck disable=SC1090
    source "$GOW_CFG"
    APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
fi

COMPOSE_FILE="${APPDATA}/docker-compose.yml"
GO_SCRIPT="/boot/config/go"

remove_go_block() {
    local marker="${1-}"
    [[ -n "$marker" ]] || return 0
    [[ -f "$GO_SCRIPT" ]] || return 0
    if ! grep -qF "$marker" "$GO_SCRIPT" 2>/dev/null; then
        return 0
    fi
    info "Removing '${marker}' from /boot/config/go"
    local end_marker="# End ${marker#\# }"
    local marker_re="${marker//\//\\/}"
    local end_marker_re="${end_marker//\//\\/}"
    if grep -qF "$end_marker" "$GO_SCRIPT" 2>/dev/null; then
        sed -i "/${marker_re}/,/${end_marker_re}/d" "$GO_SCRIPT"
    else
        sed -i "/${marker_re}/,/^$/d" "$GO_SCRIPT"
    fi
}

info "Stopping Wolf stack and session containers"
if [[ -f "$COMPOSE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null \
        || warn "docker compose down reported errors"
fi
docker stop wolf wolf-den 2>/dev/null || true
docker rm -f wolf wolf-den WolfPulseAudio 2>/dev/null || true
while read -r cid; do
    [[ -n "$cid" ]] || continue
    docker rm -f "$cid" 2>/dev/null || true
done < <(docker ps -aq --filter 'name=Wolf' 2>/dev/null || true)

remove_go_block "# GoW udev rules"
remove_go_block "# GoW docker-compose"

info "Removing udev rules"
rm -f "/etc/udev/rules.d/85-gow-virtual-inputs.rules"
rm -f "/boot/config/gow-virtual-inputs.rules"
udevadm control --reload-rules 2>/dev/null || true

PKG=$(ls "${GOW_PACKAGE_DIR}"/settings-ui-*.txz 2>/dev/null | tail -1 || true)
if [[ -n "$PKG" ]]; then
    info "Removing settings UI package"
    /sbin/removepkg "$PKG" 2>/dev/null || warn "removepkg failed for ${PKG}"
fi

rm -f /etc/cron.d/gow-health
rm -f /tmp/gow-deploy.log /tmp/gow-update.log /tmp/gow-autostart.log

info "Removing appdata at ${APPDATA}"
rm -rf "$APPDATA"

if [[ "$REMOVE_PLUGIN" == true ]]; then
    info "Removing plugin files from flash"
    rm -f "/boot/config/plugins/${GOW_NAME}.plg"
    rm -rf "$GOW_PLUGIN"
fi

cat <<EOF

GoW server wipe complete.

  Appdata removed: ${APPDATA}
  Moonlight pairing and Wolf config are gone.

Next steps:
  1. Plugins → reinstall or update Games on Whales (if you kept the .plg)
  2. Settings → Games on Whales → run setup / Install

Optional (NVIDIA only — forces driver volume rebuild on next install):
  docker volume rm nvidia-driver-vol
  docker image rm gow/nvidia-driver:latest 2>/dev/null || true

EOF

exit 0
