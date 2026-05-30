#!/bin/bash
# diagnose-esde-launch.sh — ES-DE ROM launch readiness (mounts, cores, profile launchers, image emulators).

set -euo pipefail

source "$(dirname "$0")/vars.sh"
# shellcheck source=run-python3.sh
source "$(dirname "$0")/run-python3.sh"
# shellcheck source=library-links.sh
source "$(dirname "$0")/library-links.sh"

LAUNCHERS_PROFILE="/home/retro/Applications/launchers"
ESDE_IMAGE="${ESDE_IMAGE:-ghcr.io/games-on-whales/es-de:edge}"

info() { echo "==> $*"; }
ok()   { echo "  OK:  $*"; }
warn() { echo "  WARN: $*" >&2; ISSUES=$((ISSUES + 1)); }
fail() { echo "  FAIL: $*" >&2; ISSUES=$((ISSUES + 1)); }

ISSUES=0

[[ -f "$GOW_CFG" ]] || { fail "Config not found at ${GOW_CFG}"; exit 1; }
source "$GOW_CFG"

APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
gow_resolve_library_mounts "$APPDATA" 2>/dev/null || true

info "ES-DE launch diagnostic"
echo

# ROM library
roms="${ROMS_LIBRARY:-}"
if [[ -n "$roms" && -d "$roms" ]]; then
    subdirs=$(find "$roms" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    ok "ROM library: ${roms} (${subdirs} subfolder(s))"
else
    warn "ROM library missing or unset (ROMS_LIBRARY=${roms:-empty})"
fi

# ES-DE profiles
profile_count=0
while IFS= read -r es_de; do
    [[ -n "$es_de" ]] || continue
    profile_dir="$(dirname "$es_de")"
    profile_count=$((profile_count + 1))

    info "Profile: ${profile_dir}"

    launchers="${profile_dir}/Applications/launchers"
    if [[ -d "$launchers" ]]; then
        lc=$(find "$launchers" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
        if [[ -x "${launchers}/rom_launcher.sh" && -x "${launchers}/xenia.sh" ]]; then
            ok "Profile launchers: ${lc} script(s) at Applications/launchers"
        else
            warn "Profile launchers incomplete (run repair-esde.sh)"
        fi
    else
        warn "No profile launchers at ${launchers}"
    fi

    es_xml="${es_de}/custom_systems/es_systems.xml"
    if [[ -f "$es_xml" ]]; then
        if grep -q "${LAUNCHERS_PROFILE}/rom_launcher.sh" "$es_xml" 2>/dev/null; then
            ok "es_systems.xml uses profile launcher paths"
        else
            warn "es_systems.xml still points at image launchers — run repair-esde.sh"
        fi
    else
        warn "Missing ${es_xml}"
    fi

        if [[ -f "${profile_dir}/.config/dolphin-emu/Profiles/GCPad/Wolf_XBox_One.ini" ]]; then
            ok "Dolphin Wolf gamepad profile present"
        else
            warn "Dolphin controller profile missing — run repair-esde.sh"
        fi

    cores_dir="${profile_dir}/.config/retroarch/cores"
    if [[ -d "$cores_dir" ]]; then
        missing=$(
            gow_python3 - "$cores_dir" "$(dirname "$0")/rom-config" <<'PY' 2>/dev/null | wc -l | tr -d ' '
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[2])
from required_cores import ROM_LAUNCHER_CORES
cores = Path(sys.argv[1])
for name in ROM_LAUNCHER_CORES:
    if not (cores / f"{name}_libretro.so").exists():
        print(name)
PY
        )
        total=$(ls -1 "${cores_dir}"/*.so 2>/dev/null | wc -l | tr -d ' ')
        if [[ "${missing:-0}" -eq 0 ]]; then
            ok "RetroArch cores: ${total} installed, all rom_launcher cores present"
        else
            warn "RetroArch cores: ${missing} missing for rom_launcher (${total} .so total)"
        fi
    else
        warn "RetroArch cores dir missing: ${cores_dir}"
    fi
done < <(find "${APPDATA}/profile-data" -type d -name ES-DE 2>/dev/null \
    | grep -v '\.esde-repair-backup' || true)

if (( profile_count == 0 )); then
    warn "No ES-DE profiles under ${APPDATA}/profile-data — launch ES-DE once from Moonlight"
fi

echo
info "ES-DE image emulators (${ESDE_IMAGE})"
if docker image inspect "$ESDE_IMAGE" >/dev/null 2>&1; then
    docker run --rm --entrypoint bash "$ESDE_IMAGE" -c '
for path in \
    /Applications/dolphin-emu.AppImage \
    /Applications/pcsx2-emu.AppImage \
    /Applications/rpcs3-emu.AppImage \
    /Applications/cemu-emu.AppImage \
    /Applications/xemu-emu.AppImage \
    /Applications/citron.AppImage; do
    if [[ -x "$path" || -f "$path" ]]; then echo "  OK:  $path"; else echo "  WARN: missing $path"; fi
done
if [[ -x /Applications/xenia-canary/xenia_canary ]]; then
    echo "  OK:  /Applications/xenia-canary/xenia_canary"
elif [[ -x /Applications/xenia-canary/build/bin/Linux/Release/xenia_canary ]]; then
    echo "  OK:  xenia at build/bin/Linux/Release/xenia_canary (profile xenia.sh resolves this)"
else
    echo "  WARN: xenia_canary not found in image"
fi
' || warn "Could not inspect image emulators"
else
    warn "ES-DE image not present locally: ${ESDE_IMAGE}"
fi

echo
if (( ISSUES == 0 )); then
    info "ES-DE launch diagnostic: all checks passed"
    exit 0
fi
info "ES-DE launch diagnostic: ${ISSUES} issue(s) — run fix-all.sh then relaunch ES-DE from Moonlight"
exit 2
