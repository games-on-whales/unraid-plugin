#!/bin/bash
# dev-test.sh — run plugin checks locally (no Unraid required).
#
# Usage (from repo root or scripts/):
#   bash scripts/dev-test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="${ROOT}/scripts"
FAIL=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

echo "==> dev-test: mount preset unit checks"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/config.toml" <<'EOF'
[[profiles]]
id = "moonlight-profile-id"

[[profiles.apps]]
title = "Wolf UI"

[profiles.apps.runner]
type = "docker"
name = "Wolf-UI"
image = "ghcr.io/games-on-whales/wolf-ui:main"
mounts = []
env = ["GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/*"]

[[profiles]]
id = "user"

[[profiles.apps]]
title = "EmulationStation"

[profiles.apps.runner]
type = "docker"
name = "WolfES-DE"
image = "ghcr.io/games-on-whales/es-de:edge"
mounts = ["/etc/wolf/roms:/ROMs:rw"]
env = ["GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"]

[[profiles.apps]]
title = "ES-DE"

[profiles.apps.runner]
type = "docker"
name = "WolfES-DE-alias"
image = "ghcr.io/games-on-whales/es-de:edge"
mounts = []
env = ["GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*"]

[[profiles.apps]]
title = "Heroic"

[profiles.apps.runner]
type = "docker"
name = "WolfHeroic"
image = "ghcr.io/games-on-whales/heroic-games-launcher:edge"
mounts = []
env = ["GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /var/lutris/"]

[[profiles.apps]]
title = "Prismlauncher"

[profiles.apps.runner]
type = "docker"
name = "WolfPrism"
image = "ghcr.io/games-on-whales/prismlauncher:edge"
mounts = []
env = ["GOW_REQUIRED_DEVICES=/dev/input/* /var/lutris/"]

[[profiles.apps]]
title = "Steam"

[profiles.apps.runner]
type = "docker"
name = "WolfSteam"
image = "ghcr.io/games-on-whales/steam:edge"
mounts = []
env = ["GOW_REQUIRED_DEVICES=/dev/input/*"]
EOF

COMPAT="/mnt/user/appdata/gow/compatibilitytools.d"
if ! python3 "$SCRIPTS/apply-mount-presets.py" "$TMP/config.toml" \
    /mnt/user/games/roms /mnt/user/games/bioses /mnt/user/games/media \
    /mnt/user/games/steam /mnt/user/games /mnt/user/games/lutris "$COMPAT"; then
    fail "apply-mount-presets.py exited non-zero"
fi

if grep -q '/mnt/user/games/roms:/ROMs:rw' "$TMP/config.toml" \
    && grep -A20 'title = "EmulationStation"' "$TMP/config.toml" | grep -q '/mnt/user/games/roms'; then
    pass "EmulationStation ROM mount"
else
    fail "EmulationStation ROM mount missing"
fi

if grep -A12 'title = "ES-DE"' "$TMP/config.toml" | grep -q '/mnt/user/games/roms:/ROMs:rw'; then
    pass "ES-DE title alias → EmulationStation ROM mount"
else
    fail "ES-DE alias ROM mount missing"
fi

if grep -A12 'title = "Heroic"' "$TMP/config.toml" | grep -q ':/games:rw'; then
    pass "Heroic title alias → /games"
else
    fail "Heroic /games mount missing"
fi

if grep -A12 'title = "Heroic"' "$TMP/config.toml" | grep -q 'compatibilitytools.d'; then
    pass "Heroic compatibility tools mount"
else
    fail "Heroic compat mount missing"
fi

if grep -A12 'title = "Prismlauncher"' "$TMP/config.toml" | grep -q ':/games:rw'; then
    pass "Prismlauncher /games mount"
else
    fail "Prismlauncher /games mount missing"
fi

if grep -A12 'title = "Prismlauncher"' "$TMP/config.toml" | grep -q '/var/lutris/'; then
    fail "Prismlauncher still has stale /var/lutris/ in GOW_REQUIRED_DEVICES"
else
    pass "Prismlauncher GOW_REQUIRED_DEVICES pruned"
fi

if grep -A8 'title = "Wolf UI"' "$TMP/config.toml" | grep -q '/mnt/user/games/roms'; then
    fail "Moonlight Wolf UI incorrectly got ROM mount"
else
    pass "Wolf UI left unchanged (no preset)"
fi

echo "==> dev-test: bash syntax"
for f in "$SCRIPTS"/*.sh; do
    bash -n "$f" || fail "bash -n $f"
done
pass "bash -n all scripts"

echo "==> dev-test: python compile"
python3 -m py_compile "$SCRIPTS/apply-mount-presets.py" || fail "py_compile apply-mount-presets.py"
pass "python compile"

echo "==> dev-test: health-lib smoke (PHP 8+)"
HEALTH_LIB="${ROOT}/packages/settings-ui/root/usr/local/emhttp/plugins/gow/php/health-lib.php"
HEALTH_TEST="${SCRIPTS}/dev-test-health.php"
if command -v php >/dev/null 2>&1; then
    php -l "$HEALTH_LIB" >/dev/null || fail "php -l health-lib.php"
    php "$HEALTH_TEST" >/dev/null || fail "gow_run_health_checks smoke"
    pass "health-lib smoke"
else
    echo "SKIP: php not in PATH (run: docker run --rm -v \"\$PWD:/repo\" php:8-cli php /repo/scripts/dev-test-health.php)"
fi

if [[ "$FAIL" -ne 0 ]]; then
    echo "dev-test: FAILED"
    exit 1
fi
echo "dev-test: all checks passed"
