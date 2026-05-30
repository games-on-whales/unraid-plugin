#!/bin/bash
# repair-esde.sh — restore ES-DE Custom Scripts platform config and fix common mount issues.
#
# Wolf persists ES-DE state under ${APPDATA}/<client-id>/EmulationStation/. The image
# only seeds defaults on first launch (cp -u), so stale or broken XML survives forever
# unless reset. This script re-applies the stock Custom Scripts config from the ES-DE image.

set -euo pipefail

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN:  $*" >&2; }

[[ $EUID -eq 0 ]] || err "Must run as root"
[[ -f "$GOW_CFG" ]] || err "Config not found at ${GOW_CFG}"
source "$GOW_CFG"

APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
CFG_FILE="${APPDATA}/cfg/config.toml"
COMPOSE_FILE="${APPDATA}/docker-compose.yml"

esde_image() {
    local image=""
    if [[ -f "$CFG_FILE" ]]; then
        image=$(python3 - "$CFG_FILE" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
for block in text.split("[[profiles.apps]]"):
    if re.search(r'^title\s*=\s*"EmulationStation"', block, flags=re.MULTILINE):
        match = re.search(r'image\s*=\s*"([^"]+)"', block)
        if match:
            print(match.group(1))
            break
PY
)
    fi
    echo "${image:-ghcr.io/games-on-whales/es-de:stable}"
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
        return
    fi

    cp "$settings_file" "${settings_file}.bak"
    python3 - "$settings_file" "$tmp" <<'PY'
import re
import sys
from pathlib import Path

current = Path(sys.argv[1]).read_text(encoding="utf-8")
template = Path(sys.argv[2]).read_text(encoding="utf-8")

def get_value(text: str, name: str) -> str | None:
    match = re.search(
        rf'<string name="{re.escape(name)}" value="([^"]*)"',
        text,
    )
    return match.group(1) if match else None

def set_value(text: str, name: str, value: str) -> str:
    pattern = rf'(<string name="{re.escape(name)}" value=")([^"]*)(" />?)'
    if re.search(pattern, text):
        return re.sub(pattern, rf"\g<1>{value}\g<3>", text, count=1)
    return text

fixes = {
    "ROMDirectory": "/ROMs",
    "StartupSystem": "Custom Scripts",
    "MediaDirectory": "/media",
}

for key, expected in fixes.items():
    current_val = get_value(current, key)
    if current_val is None:
        template_val = get_value(template, key)
        if template_val is not None:
            current = set_value(current, key, template_val)
    elif current_val != expected:
        current = set_value(current, key, expected)

Path(sys.argv[1]).write_text(current, encoding="utf-8")
PY
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

    extract_cfg "$image" /cfg/es/es_systems.xml > "${es_de}/custom_systems/es_systems.xml"
    extract_cfg "$image" /cfg/es/gamelist.xml > "${es_de}/gamelists/Custom Scripts/gamelist.xml"

    local settings_tmp
    settings_tmp=$(mktemp)
    extract_cfg "$image" /cfg/es/es_settings.xml > "$settings_tmp"
    fix_es_settings "${es_de}/settings/es_settings.xml" "$settings_tmp"
    rm -f "$settings_tmp"

    chown -R 1000:1000 "$profile_dir" 2>/dev/null || true
    info "Backup saved to ${backup}"
}

IMAGE=$(esde_image)
info "Using ES-DE image: ${IMAGE}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    info "Pulling ${IMAGE}..."
    docker pull "$IMAGE" || err "Could not pull ES-DE image ${IMAGE}"
fi

repaired=0
while IFS= read -r profile_dir; do
    repair_profile "$profile_dir" "$IMAGE"
    repaired=$((repaired + 1))
done < <(find "$APPDATA" -mindepth 2 -maxdepth 2 -type d -name EmulationStation 2>/dev/null \
    | grep -v '/cfg/' || true)

if (( repaired == 0 )); then
    info "No paired ES-DE profiles found yet — launch EmulationStation once from Moonlight, then run repair again if Custom Scripts are missing"
else
    info "Repaired ${repaired} ES-DE profile(s)"
fi

if [[ -x "$(dirname "$0")/apply-mount-presets.sh" ]]; then
    info "Re-applying Wolf app mount presets..."
    bash "$(dirname "$0")/apply-mount-presets.sh" || warn "Mount preset apply failed"
    if [[ -f "$COMPOSE_FILE" ]]; then
        docker compose -f "$COMPOSE_FILE" restart wolf >/dev/null 2>&1 \
            && info "Restarted Wolf to pick up config.toml changes" \
            || warn "Could not restart Wolf — restart manually from the plugin UI"
    fi
fi

info "ES-DE repair complete."
exit 0
