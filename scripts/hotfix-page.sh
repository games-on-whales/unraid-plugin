#!/bin/bash
# hotfix-page.sh — apply the latest gow.page directly on Unraid (dev/testing)
set -euo pipefail

GOW_PAGE="/usr/local/emhttp/plugins/gow/gow.page"
GOW_CFG="/boot/config/plugins/gow/gow.cfg"
BASE_URL="${1:-http://192.168.1.3:8888}"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ $EUID -eq 0 ]] || err "Run as root on Unraid"

info "Downloading settings UI package from ${BASE_URL}"
wget -qO /tmp/gow-settings-ui.txz "${BASE_URL}/dist/settings-ui.txz" \
    || err "Could not download settings-ui.txz from ${BASE_URL}"

info "Installing settings UI package"
installpkg /tmp/gow-settings-ui.txz

info "Ensuring Unix line endings on gow.page"
sed -i 's/\r$//' "$GOW_PAGE"

info "Checking PHP syntax"
php -l "$GOW_PAGE" || err "gow.page has PHP syntax errors"

if [[ -f "$GOW_PAGE" ]]; then
    info "Installed page: $(wc -l < "$GOW_PAGE") lines"
else
    err "gow.page missing after installpkg"
fi

if grep -q 'gow-health-card' "$GOW_PAGE" 2>/dev/null; then
    info "Verified: lean settings page installed"
else
    echo "WARN:  gow.page is missing gow-health-card — dist/settings-ui.txz may be stale" >&2
    echo "       Rebuild on dev: cd packages/settings-ui/root && fmakepkg ..." >&2
    exit 2
fi

info "Done. Hard-refresh Settings > Games on Whales (Ctrl+F5)."
info "If still blank: tail -20 /var/log/phplog"
info "To refresh scripts too: Plugins page update, or copy scripts to /boot/config/plugins/gow/scripts"
