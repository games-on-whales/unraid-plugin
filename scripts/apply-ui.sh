#!/bin/bash
# apply-ui.sh — reinstall the settings-ui txz without a full plugin reinstall.
#
# Unraid only runs install.sh (installpkg) when the plugin is installed or
# updated from the Plugins page. Editing the repo on your PC, clicking "Update
# Images" in GoW, or copying scripts alone does NOT refresh gow.page / php/*.
#
# Usage (on Unraid as root):
#   bash /boot/config/plugins/gow/scripts/apply-ui.sh
#   bash /boot/config/plugins/gow/scripts/apply-ui.sh /path/to/settings-ui.txz

set -euo pipefail

source "$(dirname "$0")/vars.sh"

info() { echo "==> $*"; }
err()  { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root on Unraid"

GOW_PAGE="${GOW_EMHTTP}/gow.page"
MARKER="gow-health-card"

if [[ -n "${1:-}" ]]; then
    pkg="$1"
    [[ -f "$pkg" ]] || err "Package not found: ${pkg}"
else
    pkg=""
    if [[ -d "${GOW_PACKAGE_DIR}" ]]; then
        # Newest by modification time (not alphabetical tail).
        pkg=$(ls -t "${GOW_PACKAGE_DIR}"/settings-ui-*.txz 2>/dev/null | head -1 || true)
    fi
    [[ -n "$pkg" ]] || err "No settings-ui-*.txz under ${GOW_PACKAGE_DIR}. Update/reinstall the plugin or pass a .txz path."
fi

info "Installing ${pkg}"
/sbin/installpkg "$pkg"

if [[ -f "$GOW_PAGE" ]]; then
    sed -i 's/\r$//' "$GOW_PAGE" 2>/dev/null || true
    for f in "${GOW_EMHTTP}"/php/*.php; do
        [[ -f "$f" ]] && sed -i 's/\r$//' "$f" 2>/dev/null || true
    done
fi

if command -v php >/dev/null 2>&1; then
    info "PHP syntax check"
    php -l "$GOW_PAGE" || err "gow.page failed php -l"
    for f in "${GOW_EMHTTP}"/php/*.php; do
        [[ -f "$f" ]] && php -l "$f" || err "$(basename "$f") failed php -l"
    done
fi

if grep -q "$MARKER" "$GOW_PAGE" 2>/dev/null; then
    info "Verified: installed settings page (${MARKER})"
else
    warn_msg="Installed page does NOT contain ${MARKER} — you may have an old txz"
    echo "WARN:  ${warn_msg}" >&2
    echo "       Rebuild dist/settings-ui.txz on your dev machine, copy it to" >&2
    echo "       ${GOW_PACKAGE_DIR}/, then run this script again." >&2
    exit 2
fi

info "Done. Hard-refresh Settings > Games on Whales (Ctrl+F5)."
info "Optional: /etc/rc.d/rc.nginx reload  (or restart emhttp if the page is still stale)"
