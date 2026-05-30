#!/bin/bash
# repair-pegasus.sh — regenerate Pegasus game_dirs + ROM collection metadata in Wolf profiles.

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

pegasus_image() {
    local cfg_file="${APPDATA:-${DEFAULT_APPDATA}}/cfg/config.toml"
    local image=""
    if [[ -f "$cfg_file" ]]; then
        image=$(gow_python3 - "$cfg_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
for block in text.split("[[profiles.apps]]"):
    if re.search(r'^title\s*=\s*"Pegasus"', block, flags=re.MULTILINE):
        match = re.search(r'image\s*=\s*"([^"]+)"', block)
        if match:
            print(match.group(1))
            break
PY
)
    fi
    echo "${image:-ghcr.io/games-on-whales/pegasus:edge}"
}

gow_find_pegasus_config_dirs() {
    local appdata="${1%/}"
    find "${appdata}/profile-data" -type d -path '*/.config/pegasus-frontend' 2>/dev/null \
        | grep -v '\.esde-repair-backup' || true
}

repair_profile() {
    local pegasus_cfg="$1"
    local roms_dir="${2:-}"
    local image="${3:-}"
    local generator="$(dirname "$0")/rom-config/generate_rom_library_configs.py"

    [[ -f "$generator" ]] || {
        warn "ROM platform generator missing; skipped ${pegasus_cfg}"
        return 0
    }

    info "Repairing Pegasus config at ${pegasus_cfg}"
    mkdir -p "$pegasus_cfg"

    local roms_args=()
    if [[ -n "$roms_dir" && -d "$roms_dir" ]]; then
        roms_args=(--roms-dir "$roms_dir" --only-existing)
    fi

    gow_python3 "$generator" --format pegasus-game-dirs "${roms_args[@]}" \
        > "${pegasus_cfg}/game_dirs.txt"
    {
        echo "$pegasus_cfg"
    } >> "${pegasus_cfg}/game_dirs.txt"

    gow_python3 "$generator" --format pegasus-metadata "${roms_args[@]}" \
        > "${pegasus_cfg}/gow-rom-collections.pegasus.txt"

    gow_seed_pegasus_metadata "$pegasus_cfg" "$image" || true
    gow_seed_retroarch_cores "$(dirname "$(dirname "$pegasus_cfg")")" "$image" || true
    gow_seed_retroarch_autoconfig "$(dirname "$(dirname "$pegasus_cfg")")" "$image" || true

    chown -R 1000:1000 "$(dirname "$pegasus_cfg")" 2>/dev/null || true
}

gow_repair_pegasus_main() {
    [[ $EUID -eq 0 ]] || err "Must run as root"
    [[ -f "$GOW_CFG" ]] || err "Config not found at ${GOW_CFG}"
    # shellcheck disable=SC1090
    source "$GOW_CFG"

    local appdata="${APPDATA:-${DEFAULT_APPDATA}}"
    gow_resolve_library_mounts "$appdata"

    local roms_dir="${ROMS_LIBRARY:-}"
    if [[ -n "$roms_dir" && -L "$roms_dir" ]]; then
        roms_dir="$(readlink -f "$roms_dir" 2>/dev/null || echo "$roms_dir")"
    fi

    local image
    image=$(pegasus_image)
    info "Using Pegasus image: ${image}"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        info "Pulling ${image}..."
        docker pull "$image" || warn "Could not pull Pegasus image ${image}"
    fi

    local repaired=0 cfg_dir
    while IFS= read -r cfg_dir; do
        [[ -n "$cfg_dir" ]] || continue
        repair_profile "$cfg_dir" "$roms_dir" "$image"
        repaired=$((repaired + 1))
    done < <(gow_find_pegasus_config_dirs "$appdata")

    if (( repaired == 0 )); then
        info "No Pegasus profiles found yet — launch Pegasus once from Moonlight, then run repair again"
    else
        info "Repaired ${repaired} Pegasus profile(s)"
    fi

    info "Pegasus repair complete."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    gow_repair_pegasus_main
    exit 0
fi
