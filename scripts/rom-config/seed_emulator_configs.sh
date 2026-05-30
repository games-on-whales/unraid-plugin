#!/bin/bash
# seed_emulator_configs.sh — Wolf/Moonlight gamepad defaults for standalone emulators.
set -euo pipefail

PROFILE="${1%/}"
BUNDLED="${2:-/bundled-emulator-config}"

if [[ ! -d "$BUNDLED" ]]; then
    echo "ERROR: bundled emulator config missing: ${BUNDLED}" >&2
    exit 1
fi

copy_if() {
    local src="$1"
    local dest="$2"
    [[ -f "$src" ]] || return 0
    mkdir -p "$(dirname "$dest")"
    cp -f "$src" "$dest"
}

copy_if "${BUNDLED}/dolphin_Dolphin.ini" "${PROFILE}/.config/dolphin-emu/Dolphin.ini"
copy_if "${BUNDLED}/dolphin_GCPad_Wolf_XBox_One.ini" \
    "${PROFILE}/.config/dolphin-emu/Profiles/GCPad/Wolf_XBox_One.ini"
copy_if "${BUNDLED}/dolphin_Wiimote_Wolf_XBox_One.ini" \
    "${PROFILE}/.config/dolphin-emu/Profiles/Wiimote/Wolf_XBox_One.ini"
copy_if "${BUNDLED}/pcsx2_PCSX2.ini" "${PROFILE}/.config/PCSX2/inis/PCSX2.ini"
copy_if "${BUNDLED}/rpcs3_config.yml" "${PROFILE}/.config/rpcs3/config.yml"
copy_if "${BUNDLED}/rpcs3_Default.yml" "${PROFILE}/.config/rpcs3/input_configs/global/Default.yml"
copy_if "${BUNDLED}/rpcs3_CurrentSettings.ini" "${PROFILE}/.config/rpcs3/GuiConfigs/CurrentSettings.ini"
copy_if "${BUNDLED}/xemu_xemu.toml" "${PROFILE}/.local/share/xemu/xemu/xemu.toml"

echo "Seeded Wolf gamepad configs under ${PROFILE}"
