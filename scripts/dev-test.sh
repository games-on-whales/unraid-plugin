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
ROMGEN_TMP=""
QUOTE_TMP=""
SOCKET_TMP=""
LAUNCHERS_TMP=""
trap 'rm -rf "$TMP" "$ROMGEN_TMP" "$QUOTE_TMP" "$SOCKET_TMP" "$LAUNCHERS_TMP"' EXIT

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

[[profiles.apps]]
title = "RetroArch"

[profiles.apps.runner]
type = "docker"
name = "WolfRetroArch"
image = "ghcr.io/games-on-whales/retroarch:edge"
mounts = []
env = ["GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/*"]

[[profiles.apps]]
title = "Pegasus"

[profiles.apps.runner]
type = "docker"
name = "WolfPegasus"
image = "ghcr.io/games-on-whales/pegasus:edge"
mounts = []
env = ["GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/*"]
EOF

COMPAT="/mnt/user/appdata/gow/compatibilitytools.d"
if ! python3 "$SCRIPTS/apply-mount-presets.py" "$TMP/config.toml" \
    /mnt/user/games/roms /mnt/user/games/bioses /mnt/user/games/media \
    /mnt/user/games/steam /mnt/user/games /mnt/user/games/lutris \
    /mnt/user/games/prismlauncher "$COMPAT"; then
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

if grep -A12 'title = "Prismlauncher"' "$TMP/config.toml" | grep -q '/mnt/user/games/prismlauncher:/games/prismlauncher:rw'; then
    pass "Prismlauncher data mount"
else
    fail "Prismlauncher /games/prismlauncher mount missing"
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

if grep -A12 'title = "RetroArch"' "$TMP/config.toml" | grep -q '/mnt/user/games/roms:/ROMs:rw'; then
    pass "RetroArch ROM mount"
else
    fail "RetroArch ROM mount missing"
fi

if grep -A12 'title = "RetroArch"' "$TMP/config.toml" | grep -q '/mnt/user/games/media:/media:rw'; then
    pass "RetroArch media mount"
else
    fail "RetroArch media mount missing"
fi

if grep -A12 'title = "Pegasus"' "$TMP/config.toml" | grep -q '/mnt/user/games/roms:/ROMs:rw'; then
    pass "Pegasus ROM mount"
else
    fail "Pegasus ROM mount missing"
fi

echo "==> dev-test: ROM root detection (nested roms/roms)"
# shellcheck source=rom-platform-dirs.sh
source "$SCRIPTS/rom-platform-dirs.sh"
DETECT_TMP="$(mktemp -d)"
mkdir -p "$DETECT_TMP/share/roms/nes" "$DETECT_TMP/share/Roms/Xbox 360"
best=$(gow_best_rom_root "$DETECT_TMP/share" "$DETECT_TMP/share/roms")
if [[ "$best" == "$DETECT_TMP/share/roms" ]]; then
    pass "ROM root prefers platform tree over console folder"
else
    fail "ROM root detection expected .../roms got: ${best:-empty}"
fi

echo "==> dev-test: ES-DE profile discovery"
# shellcheck source=repair-esde.sh
source "$SCRIPTS/repair-esde.sh"
PROFILE_TMP="$(mktemp -d)"
mkdir -p "$PROFILE_TMP/profile-data/user/WolfES-DE/ES-DE/custom_systems"
found=$(gow_find_esde_profile_dirs "$PROFILE_TMP" | head -1)
if [[ "$found" == "$PROFILE_TMP/profile-data/user/WolfES-DE" ]]; then
    pass "repair-esde finds profile-data/ES-DE"
else
    fail "repair-esde profile discovery expected WolfES-DE parent got: ${found:-empty}"
fi

echo "==> dev-test: ROM library config generator"
ROMGEN_TMP="$(mktemp -d)"
mkdir -p "$ROMGEN_TMP/roms/nes" "$ROMGEN_TMP/roms/snes" "$ROMGEN_TMP/roms/gc"
python3 "$SCRIPTS/rom-config/generate_rom_library_configs.py" \
    --format esde --roms-dir "$ROMGEN_TMP/roms" --only-existing \
    | grep -q '<name>Custom Scripts</name>' && pass "ES-DE generator keeps Custom Scripts platform" \
    || fail "ES-DE generator dropped Custom Scripts"
python3 "$SCRIPTS/rom-config/generate_rom_library_configs.py" \
    --format esde --roms-dir "$ROMGEN_TMP/roms" --only-existing \
    | grep -q '%ROMPATH%/nes' && pass "ES-DE generator includes existing nes platform" \
    || fail "ES-DE generator missing nes platform"
LAUNCHERS_TMP="$(mktemp -d)"
printf '#!/bin/sh\n' > "$LAUNCHERS_TMP/retroarch.sh"
printf '#!/bin/sh\n' > "$LAUNCHERS_TMP/dolphin.sh"
python3 "$SCRIPTS/rom-config/generate_rom_library_configs.py" \
    --format esde-custom-scripts-gamelist --launchers-dir "$LAUNCHERS_TMP" \
    | grep -q '/home/retro/Applications/launchers/retroarch.sh' && pass "Custom Scripts gamelist uses profile launcher paths" \
    || fail "Custom Scripts gamelist path format wrong"
python3 "$SCRIPTS/rom-config/generate_rom_library_configs.py" \
    --format esde --roms-dir "$ROMGEN_TMP/roms" --only-existing \
    | grep -q '/home/retro/Applications/launchers/rom_launcher.sh' && pass "ES-DE generator uses profile rom_launcher path" \
    || fail "ES-DE generator missing profile rom_launcher path"
[[ -x "$SCRIPTS/rom-config/launchers/rom_launcher.sh" ]] && pass "Bundled rom_launcher.sh present" \
    || fail "Bundled rom_launcher.sh missing"
python3 -c "import sys; sys.path.insert(0, '$SCRIPTS/rom-config'); from required_cores import ROM_LAUNCHER_CORES; assert len(ROM_LAUNCHER_CORES) >= 20" \
    && pass "required_cores.py importable" || fail "required_cores.py import failed"
python3 "$SCRIPTS/rom-config/generate_rom_library_configs.py" \
    --format esde-custom-scripts-gamelist --launchers-dir "$LAUNCHERS_TMP" \
    | grep -q 'PlayStation 2' && pass "Custom Scripts gamelist includes system compatibility" \
    || fail "Custom Scripts gamelist missing emulator descriptions"
python3 "$SCRIPTS/rom-config/generate_rom_library_configs.py" \
    --format esde --roms-dir "$ROMGEN_TMP/roms" --only-existing \
    | grep -q 'label="Dolphin"' && pass "ES-DE gc/wii includes Dolphin alternative command" \
    || fail "ES-DE missing standalone emulator commands"
python3 "$SCRIPTS/rom-config/generate_rom_library_configs.py" \
    --format pegasus-metadata --roms-dir "$ROMGEN_TMP/roms" --only-existing \
    | grep -q 'shortname: nes' && pass "Pegasus metadata generator" \
    || fail "Pegasus metadata generator missing nes"

echo "==> dev-test: single-quote mount parsing"
QUOTE_TMP="$(mktemp -d)"
cat > "$QUOTE_TMP/config.toml" <<'EOF'
[[profiles.apps]]
title = 'EmulationStation'

[profiles.apps.runner]
type = "docker"
mounts = ['/etc/wolf/roms:/ROMs:rw']
env = ["GOW_REQUIRED_DEVICES=/dev/input/*"]
EOF
python3 "$SCRIPTS/apply-mount-presets.py" "$QUOTE_TMP/config.toml" \
    /mnt/user/games/roms /mnt/user/games/bioses >/dev/null
grep -q "/mnt/user/games/roms:/ROMs:rw" "$QUOTE_TMP/config.toml" \
    && pass "single-quote mounts patched" || fail "single-quote mount patch failed"

echo "==> dev-test: Wolf UI socket mount fix"
SOCKET_TMP="$(mktemp -d)"
cat > "$SOCKET_TMP/config.toml" <<'EOF'
[[profiles.apps]]
title = "Wolf UI"

[profiles.apps.runner]
type = "docker"
env = [
    'GOW_REQUIRED_DEVICES=/dev/input/event* /dev/dri/* /dev/nvidia*',
    'WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock',
    'WOLF_UI_AUTOUPDATE=False',
    'LOGLEVEL=INFO'
]
mounts = ["/var/run/wolf/wolf.sock:/var/run/wolf/wolf.sock"]
EOF
python3 "$SCRIPTS/apply-mount-presets.py" \
    --wolf-socket-host "/mnt/user/appdata/gow/run/wolf.sock" \
    "$SOCKET_TMP/config.toml" >/dev/null
if grep -A6 'title = "Wolf UI"' "$SOCKET_TMP/config.toml" | grep -q '/mnt/user/appdata/gow/run/wolf.sock:/var/run/wolf/wolf.sock'; then
    pass "Wolf UI socket mount uses host appdata path"
else
    fail "Wolf UI socket mount not patched to host path"
fi
if grep -A12 'title = "Wolf UI"' "$SOCKET_TMP/config.toml" | grep -q 'RUN_GAMESCOPE=1'; then
    pass "Wolf UI env includes RUN_GAMESCOPE=1"
else
    fail "Wolf UI missing RUN_GAMESCOPE=1 workaround"
fi
if grep -A12 'title = "Wolf UI"' "$SOCKET_TMP/config.toml" | grep -q 'WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock'; then
    pass "Wolf UI env keeps WOLF_SOCKET_PATH when patching"
else
    fail "Wolf UI env patch dropped WOLF_SOCKET_PATH"
fi

echo "==> dev-test: Unraid docker-python fallback"
if [[ -n "${GOW_FORCE_DOCKER_PYTHON:-}" ]] || command -v docker >/dev/null 2>&1; then
    DOCKER_TMP="$(mktemp -d)"
    cp "$TMP/config.toml" "$DOCKER_TMP/config.toml"
    # shellcheck source=run-python3.sh
    source "$SCRIPTS/run-python3.sh"
    if GOW_FORCE_DOCKER_PYTHON=1 gow_python3 "$SCRIPTS/apply-mount-presets.py" \
        "$DOCKER_TMP/config.toml" \
        /mnt/user/games/roms /mnt/user/games/bioses >/dev/null 2>&1; then
        if grep -q '/mnt/user/games/roms:/ROMs:rw' "$DOCKER_TMP/config.toml"; then
            pass "docker-python apply-mount-presets"
        else
            fail "docker-python apply-mount-presets did not write ROM bind"
        fi
    else
        echo "SKIP: docker-python fallback (Docker unavailable or pull failed)"
    fi
else
    echo "SKIP: docker not in PATH for docker-python fallback test"
fi

echo "==> dev-test: bash syntax"
for f in "$SCRIPTS"/*.sh; do
    bash -n "$f" || fail "bash -n $f"
done
pass "bash -n all scripts"

echo "==> dev-test: python compile"
python3 -m py_compile "$SCRIPTS/apply-mount-presets.py" || fail "py_compile apply-mount-presets.py"
python3 -m py_compile "$SCRIPTS/rom-config/generate_rom_library_configs.py" || fail "py_compile generate_rom_library_configs.py"
python3 -m py_compile "$SCRIPTS/rom-config/rom_platforms.py" || fail "py_compile rom_platforms.py"
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
