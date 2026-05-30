#!/bin/bash
# health-check.sh — print GoW stack health (for UI, CLI, and troubleshooting).

set -euo pipefail

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ -f "$GOW_CFG" ]] || err "Config not found at ${GOW_CFG}"
source "$GOW_CFG"

HEALTH_PHP="${GOW_EMHTTP}/php/health.php"
if [[ ! -f "$HEALTH_PHP" ]]; then
    HEALTH_PHP="/usr/local/emhttp/plugins/gow/php/health.php"
fi
[[ -f "$HEALTH_PHP" ]] || err "Health endpoint not installed (${HEALTH_PHP})"

json=$(php "$HEALTH_PHP" 2>/dev/null) || err "Health check failed to run"

summary=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('summary','unknown'))")
echo "Games on Whales health: ${summary^^}"
echo

echo "$json" | python3 - <<'PY'
import json
import sys

data = json.load(sys.stdin)
icons = {"ok": "OK", "warn": "WARN", "fail": "FAIL"}
for item in data.get("checks", []):
    level = item.get("level", "warn")
    label = item.get("label", "")
    hint = item.get("hint", "")
    mark = icons.get(level, "?")
    line = f"[{mark}] {label}"
    if hint:
        line += f" — {hint}"
    print(line)
PY

case "$summary" in
    healthy) exit 0 ;;
    degraded) exit 2 ;;
    *) exit 1 ;;
esac
