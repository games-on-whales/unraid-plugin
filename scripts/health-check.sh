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

summary=$(php -r '
$d = json_decode(stream_get_contents(STDIN), true);
echo $d["summary"] ?? "unknown";
' <<<"$json")
summary_upper=$(echo "$summary" | tr '[:lower:]' '[:upper:]')
echo "Games on Whales health: ${summary_upper}"
echo

php -r '
$d = json_decode(stream_get_contents(STDIN), true);
$icons = ["ok" => "OK", "warn" => "WARN", "fail" => "FAIL"];
foreach ($d["checks"] ?? [] as $item) {
    $level = $item["level"] ?? "warn";
    $label = $item["label"] ?? "";
    $hint = $item["hint"] ?? "";
    $mark = $icons[$level] ?? "?";
    $line = "[$mark] $label";
    if ($hint !== "") {
        $line .= " — $hint";
    }
    echo $line, PHP_EOL;
}
' <<<"$json"

case "$summary" in
    healthy) exit 0 ;;
    degraded) exit 2 ;;
    *) exit 1 ;;
esac
