#!/bin/bash
# repair-esde.sh — restore ES-DE Custom Scripts + ROM platforms; fix profile config.
#
# Wolf v0 persists ES-DE under ${APPDATA}/profile-data/.../ES-DE/. Older Wolf builds
# used ${APPDATA}/<client-id>/EmulationStation/ES-DE/. Re-applies stock + generated XML.

set -euo pipefail

source "$(dirname "$0")/vars.sh"
# shellcheck source=run-python3.sh
source "$(dirname "$0")/run-python3.sh"
# shellcheck source=library-links.sh
source "$(dirname "$0")/library-links.sh"
# shellcheck source=repair-frontend-lib.sh
source "$(dirname "$0")/repair-frontend-lib.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN:  $*" >&2; }

esde_image() {
    local cfg_file="${APPDATA:-${DEFAULT_APPDATA}}/cfg/config.toml"
    local image=""
    if [[ -f "$cfg_file" ]]; then
        image=$(gow_python3 - "$cfg_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
for block in text.split("[[profiles.apps]]"):
    if re.search(
        r'^title\s*=\s*"(?:ES-DE|EmulationStation)"',
        block,
        flags=re.MULTILINE,
    ):
        match = re.search(r'image\s*=\s*"([^"]+)"', block)
        if match:
            print(match.group(1))
            break
PY
)
    fi
    echo "${image:-ghcr.io/games-on-whales/es-de:edge}"
}

extract_cfg() {
    local image="$1"
    local path="$2"
    docker run --rm --entrypoint cat "$image" "$path"
}

fix_es_settings() {
    local settings_file="$1"
    local tmp="$2"

    if [[ ! -f "$settings_file" ]]; then
        cp "$tmp" "$settings_file"
    fi

    cp "$settings_file" "${settings_file}.bak"
    chmod u+w "$settings_file" 2>/dev/null || true

    # Host sed — gow_python3 Docker mounts file args read-only and cannot patch settings.
    sed -i \
        -e 's/name="ROMDirectory" value="[^"]*"/name="ROMDirectory" value="\/ROMs"/' \
        -e 's/name="MediaDirectory" value="[^"]*"/name="MediaDirectory" value="\/media"/' \
        -e 's/name="StartupSystem" value="Custom Scripts"/name="StartupSystem" value=""/' \
        "$settings_file"
}

gow_find_esde_profile_dirs() {
    local appdata="${1%/}"
    local -a found=()
    local es_de_dir parent

    while IFS= read -r es_de_dir; do
        [[ -n "$es_de_dir" ]] || continue
        parent="$(dirname "$es_de_dir")"
        found+=("$parent")
    done < <(
        find "${appdata}/profile-data" -type d -name ES-DE 2>/dev/null \
            | grep -v '\.esde-repair-backup' || true
    )

    while IFS= read -r es_de_dir; do
        [[ -n "$es_de_dir" ]] || continue
        found+=("$es_de_dir")
    done < <(
        find "$appdata" -mindepth 2 -maxdepth 2 -type d -name EmulationStation 2>/dev/null \
            | grep -v '/cfg/' || true
    )

    printf '%s\n' "${found[@]}" | awk '!seen[$0]++'
}

repair_profile() {
    local profile_dir="$1"
    local image="$2"
    local es_de="${profile_dir}/ES-DE"
    local stamp
    stamp=$(date +%Y%m%d%H%M%S)
    local backup="${profile_dir}/.esde-repair-backup-${stamp}"

    info "Repairing ES-DE profile at ${es_de}"
    mkdir -p "$backup"
    [[ -d "$es_de" ]] && cp -a "$es_de" "$backup/" || true

    mkdir -p "${es_de}/custom_systems"
    mkdir -p "${es_de}/gamelists/Custom Scripts"
    mkdir -p "${es_de}/settings"

    gow_seed_profile_launchers "$profile_dir" || warn "Profile launcher seed reported errors"

    local roms_dir="${ROMS_LIBRARY:-}"
    local generator="$(dirname "$0")/rom-config/generate_rom_library_configs.py"
    if [[ -f "$generator" ]]; then
        if [[ -n "$roms_dir" && -d "$roms_dir" ]]; then
            gow_python3 "$generator" --format esde --roms-dir "$roms_dir" \
                > "${es_de}/custom_systems/es_systems.xml"
        else
            gow_python3 "$generator" --format esde > "${es_de}/custom_systems/es_systems.xml"
        fi
        if ! grep -q '<name>Custom Scripts</name>' "${es_de}/custom_systems/es_systems.xml"; then
            err "ES-DE repair: generated es_systems.xml missing Custom Scripts platform"
        fi
        gow_regenerate_esde_custom_scripts_gamelist "$es_de" "$image" "$generator" \
            || warn "Custom Scripts gamelist regeneration failed"
    else
        extract_cfg "$image" /cfg/es/es_systems.xml > "${es_de}/custom_systems/es_systems.xml"
        extract_cfg "$image" /cfg/es/gamelist.xml > "${es_de}/gamelists/Custom Scripts/gamelist.xml"
        warn "ROM platform generator missing; ES-DE will only show Custom Scripts until images update"
    fi

    gow_seed_retroarch_cores "$profile_dir" "$image" || warn "RetroArch core seed reported errors"
    gow_seed_emulator_controller_configs "$profile_dir" "$image" || warn "Emulator controller config seed reported errors"
    gow_seed_retroarch_autoconfig "$profile_dir" "$image" || warn "RetroArch autoconfig seed reported errors"

    local settings_tmp
    settings_tmp=$(mktemp)
    extract_cfg "$image" /cfg/es/es_settings.xml > "$settings_tmp"
    chmod u+w "${es_de}/settings" 2>/dev/null || true
    rm -f "${es_de}/settings/es_settings.xml" 2>/dev/null || true
    fix_es_settings "${es_de}/settings/es_settings.xml" "$settings_tmp"
    chown 1000:1000 "${es_de}/settings/es_settings.xml" 2>/dev/null || true
    rm -f "$settings_tmp"

    chown -R 1000:1000 "$profile_dir" 2>/dev/null || true
    info "Backup saved to ${backup}"
}

gow_repair_esde_main() {
    [[ $EUID -eq 0 ]] || err "Must run as root"
    [[ -f "$GOW_CFG" ]] || err "Config not found at ${GOW_CFG}"
    # shellcheck disable=SC1090
    source "$GOW_CFG"

    local appdata="${APPDATA:-${DEFAULT_APPDATA}}"
    gow_resolve_library_mounts "$appdata"

    local image
    image=$(esde_image)
    info "Using ES-DE image: ${image}"

    if ! docker image inspect "$image" >/dev/null 2>&1; then
        info "Pulling ${image}..."
        docker pull "$image" || err "Could not pull ES-DE image ${image}"
    fi

    local repaired=0 profile_dir
    while IFS= read -r profile_dir; do
        [[ -n "$profile_dir" ]] || continue
        repair_profile "$profile_dir" "$image"
        repaired=$((repaired + 1))
    done < <(gow_find_esde_profile_dirs "$appdata")

    if (( repaired == 0 )); then
        info "No paired ES-DE profiles found yet — launch ES-DE once from Moonlight, then run repair again if ROM platforms are missing"
    else
        info "Repaired ${repaired} ES-DE profile(s)"
    fi

    info "ES-DE repair complete."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    gow_repair_esde_main
    exit 0
fi
