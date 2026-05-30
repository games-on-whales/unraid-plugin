#!/bin/bash
# diagnose-mounts.sh — Wolf app runner mount readiness (all preset apps).

set -euo pipefail

source "$(dirname "$0")/vars.sh"
# shellcheck source=library-links.sh
source "$(dirname "$0")/library-links.sh"

info() { echo "==> $*"; }
ok()   { echo "  OK:  $*"; }
warn() { echo "  WARN: $*" >&2; ISSUES=$((ISSUES + 1)); }
fail() { echo "  FAIL: $*" >&2; ISSUES=$((ISSUES + 1)); }

ISSUES=0

[[ -f "$GOW_CFG" ]] || { fail "Config not found at ${GOW_CFG}"; exit 1; }
source "$GOW_CFG"

APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
CFG="${APPDATA}/cfg/config.toml"
WOLF_SOCK="${APPDATA}/run/wolf.sock"

info "Mount diagnostic (gow.cfg + config.toml + compose)"
echo

check_cfg_path() {
    local var="$1"
    local val="${!var:-}"
    if [[ -z "$val" ]]; then
        warn "${var} unset in gow.cfg"
        return 1
    fi
    local resolved
    resolved="$(gow_mount_source_path "$val")"
    if [[ ! -d "$resolved" ]]; then
        warn "${var} path missing: ${resolved} (from ${val})"
        return 1
    fi
    ok "${var}=${resolved}"
    return 0
}

for var in ROMS_LIBRARY BIOS_LIBRARY MEDIA_LIBRARY STEAM_LIBRARY GAMES_LIBRARY \
    LUTRIS_LIBRARY PRISM_LIBRARY COMPAT_TOOLS_PATH; do
    check_cfg_path "$var" || true
done

if [[ ! -f "$CFG" ]]; then
    fail "Wolf config missing: ${CFG}"
else
    ok "Wolf config: ${CFG}"

    if grep -qE '/etc/wolf/[^"'\'' ]+:[^"'\'' ]+' "$CFG"; then
        fail "App runner mount uses /etc/wolf/* as source — run Fix mounts"
    else
        ok "No /etc/wolf/* mount sources in app runners"
    fi

    if grep -qE '["'\'']lutris:/var/lutris' "$CFG"; then
        fail "Lutris placeholder mount (lutris:/var/lutris) — run Fix mounts"
    else
        ok "No Lutris placeholder mounts"
    fi

    if grep -q 'GOW_REQUIRED_DEVICES=.*\/var\/lutris\/' "$CFG" \
        && ! grep -q ':/var/lutris' "$CFG"; then
        fail "Stale /var/lutris/ in GOW_REQUIRED_DEVICES without Lutris bind"
    else
        ok "GOW_REQUIRED_DEVICES /var/lutris/ tokens consistent"
    fi

    check_app_mount() {
        local title="$1"
        local host_var="$2"
        local dest_pattern="$3"
        local host="${!host_var:-}"
        [[ -n "$host" ]] || return 0
        host="$(gow_mount_source_path "$host")"
        if ! grep -A24 "title = \"${title}\"" "$CFG" | grep -qF "${host}:${dest_pattern}"; then
            warn "${title} missing expected bind (*:${dest_pattern}) for ${host_var}"
        else
            ok "${title} host bind present"
        fi
    }

    check_app_mount "EmulationStation" ROMS_LIBRARY "/ROMs"
    check_app_mount "Steam" STEAM_LIBRARY "/home/retro/.local/share/Steam"
    check_app_mount "Lutris" LUTRIS_LIBRARY "/var/lutris"
    check_app_mount "Kodi" MEDIA_LIBRARY "/media"
    check_app_mount "Heroic" GAMES_LIBRARY "/games"
    check_app_mount "Prismlauncher" PRISM_LIBRARY "/games/prismlauncher"

    if grep -A16 'title = "Wolf UI"' "$CFG" | grep -qF "${WOLF_SOCK}:/var/run/wolf/wolf.sock"; then
        ok "Wolf UI socket bind uses appdata wolf.sock"
    elif grep -q 'title = "Wolf UI"' "$CFG"; then
        warn "Wolf UI socket mount may not point at ${WOLF_SOCK}"
    fi
fi

COMPOSE="${APPDATA}/docker-compose.yml"
if [[ -f "$COMPOSE" ]]; then
    ok "Compose file: ${COMPOSE}"
    if grep -q '/etc/wolf/steam:rw' "$COMPOSE" && [[ -z "${STEAM_LIBRARY:-}" ]]; then
        warn "Compose binds /etc/wolf/steam but STEAM_LIBRARY unset"
    fi
else
    warn "Compose file missing (stack not deployed?): ${COMPOSE}"
fi

info "Recent Wolf session containers"
docker ps -a --filter 'name=Wolf' \
    --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | head -15 || warn "docker ps failed"

echo
if (( ISSUES == 0 )); then
    echo "diagnose-mounts: all checks passed"
    exit 0
fi
echo "diagnose-mounts: ${ISSUES} issue(s) — run Fix mounts from plugin settings, then retry"
exit 2
