#!/bin/bash
# uninstall.sh — stop containers, remove boot hooks, clean udev rules
# Appdata is intentionally left intact (Unraid convention).

source "$(dirname "$0")/vars.sh"

info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

GO_SCRIPT="/boot/config/go"
APPDATA="${DEFAULT_APPDATA}"

if [[ -f "$GOW_CFG" ]]; then
    source "$GOW_CFG"
fi

# Stop Wolf + Wolf Den
COMPOSE_FILE="${APPDATA}/docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]]; then
    info "Stopping Wolf + Wolf Den"
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || warn "Could not stop containers cleanly"
fi

# Remove marker blocks from /boot/config/go
remove_go_block() {
    local marker="$1"
    if grep -qF "$marker" "$GO_SCRIPT" 2>/dev/null; then
        info "Removing '${marker}' from /boot/config/go"
        # Delete from marker line through the following blank line (the block we appended)
        sed -i "/$(echo "$marker" | sed 's|/|\\/|g')/,/^$/d" "$GO_SCRIPT"
    fi
}

remove_go_block "# GoW udev rules"
remove_go_block "# GoW docker-compose"

# Remove udev rules
info "Removing udev rules"
rm -f "/etc/udev/rules.d/85-gow-virtual-inputs.rules"
rm -f "/boot/config/gow-virtual-inputs.rules"
udevadm control --reload-rules 2>/dev/null || true

# Remove settings-ui package
PKG=$(ls "${GOW_PACKAGE_DIR}"/settings-ui-*.txz 2>/dev/null | tail -1)
if [[ -n "$PKG" ]]; then
    info "Removing settings-ui package"
    /sbin/removepkg "$PKG" 2>/dev/null || warn "Could not remove settings-ui package"
fi

info "Done. Appdata at ${APPDATA} was left intact."
exit 0
