#!/bin/bash
# repair-frontend-lib.sh — shared ES-DE / Pegasus profile repair helpers.

_gow_repair_warn() { echo "WARN:  $*" >&2; }
_gow_repair_info() { echo "==> $*"; }

# Copy a directory tree from a container image to a host path (tar stream).
gow_docker_extract_dir() {
    local image="$1"
    local container_path="$2"
    local host_dir="$3"

    mkdir -p "$host_dir"
    docker run --rm --entrypoint tar "$image" -cf - -C "$container_path" . 2>/dev/null \
        | tar -xf - -C "$host_dir"
}

# Copy bundled profile launchers into a Wolf profile (writable; image /Applications is not).
gow_seed_profile_launchers() {
    local profile_dir="${1%/}"
    local bundled="$(dirname "${BASH_SOURCE[0]}")/rom-config/launchers"
    local dest="${profile_dir}/Applications/launchers"

    [[ -d "$bundled" ]] || {
        _gow_repair_warn "Bundled profile launchers missing at ${bundled}"
        return 1
    }

    mkdir -p "$dest"
    cp -f "${bundled}/"*.sh "$dest/"
    chmod -R a+x "$dest"
    chown -R 1000:1000 "${profile_dir}/Applications" 2>/dev/null || true

    local count
    count=$(find "$dest" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
    _gow_repair_info "Profile launchers seeded: ${count} script(s) at ${dest}"
}

_gow_bundled_launchers_dir() {
    echo "$(dirname "${BASH_SOURCE[0]}")/rom-config/launchers"
}

# Regenerate ES-DE Custom Scripts gamelist from bundled plugin launchers.
gow_regenerate_esde_custom_scripts_gamelist() {
    local es_de="${1%/}"
    local _image="${2:-}"
    local generator="$3"
    local gamelist="${es_de}/gamelists/Custom Scripts/gamelist.xml"
    local launchers_dir
    launchers_dir=$(_gow_bundled_launchers_dir)

    [[ -f "$generator" ]] || {
        _gow_repair_warn "ROM generator missing; skipped Custom Scripts gamelist"
        return 1
    }

    if [[ ! -d "$launchers_dir" ]]; then
        _gow_repair_warn "Bundled launchers dir missing: ${launchers_dir}"
        return 1
    fi

    mkdir -p "$(dirname "$gamelist")"
    local tmp_gamelist
    tmp_gamelist=$(mktemp)
    if [[ -f "$gamelist" ]]; then
        gow_python3 "$generator" --format esde-custom-scripts-gamelist \
            --launchers-dir "$launchers_dir" --merge-gamelist "$gamelist" > "$tmp_gamelist"
    else
        gow_python3 "$generator" --format esde-custom-scripts-gamelist \
            --launchers-dir "$launchers_dir" > "$tmp_gamelist"
    fi
    chmod u+w "$(dirname "$gamelist")" 2>/dev/null || true
    chattr -i "$gamelist" 2>/dev/null || true
    rm -f "$gamelist" 2>/dev/null || true
    mv "$tmp_gamelist" "$gamelist"
    chmod u+w "$gamelist" 2>/dev/null || true
    chown 1000:1000 "$gamelist" 2>/dev/null || true

    local count=0
    count=$(grep -c '<game>' "$gamelist" 2>/dev/null || echo 0)
    _gow_repair_info "Custom Scripts gamelist: ${count} emulator launcher(s)"
}

_gow_missing_rom_launcher_cores() {
    local cores_dir="$1"
    local rom_config="$(dirname "${BASH_SOURCE[0]}")/rom-config"
    [[ -f "${rom_config}/required_cores.py" ]] || return 1
    gow_python3 - "$cores_dir" "$rom_config" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[2])
from required_cores import ROM_LAUNCHER_CORES

cores = Path(sys.argv[1])
for name in ROM_LAUNCHER_CORES:
    if not (cores / f"{name}_libretro.so").exists():
        print(name)
PY
}

# Seed libretro cores + stock retroarch.cfg into a Wolf profile (required for rom_launcher.sh).
gow_seed_retroarch_cores() {
    local profile_dir="${1%/}"
    local image="$2"
    local cfg_dir="${profile_dir}/.config/retroarch"
    local cores_dir="${cfg_dir}/cores"
    local installer="$(dirname "${BASH_SOURCE[0]}")/rom-config/install_retroarch_cores.sh"
    local rom_config="$(dirname "${BASH_SOURCE[0]}")/rom-config"

    mkdir -p "$cores_dir"

    if [[ ! -f "${cfg_dir}/retroarch.cfg" ]]; then
        if docker run --rm --entrypoint cat "$image" /cfg/retroarch/retroarch.cfg \
            > "${cfg_dir}/retroarch.cfg" 2>/dev/null; then
            _gow_repair_info "Seeded stock retroarch.cfg"
        fi
    fi

    local missing_count=0
    if missing_count=$( (_gow_missing_rom_launcher_cores "$cores_dir" 2>/dev/null || true) | wc -l | tr -d ' '); then
        :
    fi
    if (( missing_count == 0 )); then
        _gow_repair_info "All rom_launcher RetroArch cores present (${cores_dir})"
        chown -R 1000:1000 "$cfg_dir" 2>/dev/null || true
        return 0
    fi
    _gow_repair_info "RetroArch cores incomplete (${missing_count} missing for rom_launcher) — installing"

    [[ -f "$installer" ]] || {
        _gow_repair_warn "RetroArch core installer missing at ${installer}"
        return 1
    }

    _gow_repair_info "Installing RetroArch cores into profile (may take a few minutes)"
    if docker run --rm \
        -v "${cores_dir}:/cores:rw" \
        -v "${installer}:/install_retroarch_cores.sh:ro" \
        -v "${rom_config}:/install-rom-config:ro" \
        --entrypoint bash \
        "$image" \
        -c 'cd /install-rom-config && /install_retroarch_cores.sh /cores'; then
        missing_count=$( (_gow_missing_rom_launcher_cores "$cores_dir" 2>/dev/null || true) | wc -l | tr -d ' ')
        local count
        count=$(ls -1 "$cores_dir"/*.so 2>/dev/null | wc -l | tr -d ' ')
        if (( missing_count > 0 )); then
            _gow_repair_warn "Still missing ${missing_count} rom_launcher core(s) after install — check plugin logs"
            _gow_missing_rom_launcher_cores "$cores_dir" 2>/dev/null | while read -r core; do
                [[ -n "$core" ]] && _gow_repair_warn "  missing: ${core}_libretro.so"
            done
        else
            _gow_repair_info "RetroArch cores ready: ${count} in ${cores_dir}"
        fi
    else
        _gow_repair_warn "RetroArch core install failed for ${image}"
        return 1
    fi

    chown -R 1000:1000 "$cfg_dir" 2>/dev/null || true
}

# Ensure RetroArch picks up Moonlight/Wolf virtual controllers (autoconfig + input settings).
gow_seed_retroarch_autoconfig() {
    local profile_dir="${1%/}"
    local image="$2"
    local cfg_dir="${profile_dir}/.config/retroarch"
    local bundled="$(dirname "${BASH_SOURCE[0]}")/rom-config/autoconfig"
    local seeder="$(dirname "${BASH_SOURCE[0]}")/rom-config/seed_retroarch_autoconfig.sh"

    mkdir -p "${cfg_dir}/autoconfig/udev"

    if [[ ! -f "${cfg_dir}/retroarch.cfg" ]]; then
        docker run --rm --entrypoint cat "$image" /cfg/retroarch/retroarch.cfg \
            > "${cfg_dir}/retroarch.cfg" 2>/dev/null || true
    fi

    _gow_patch_retroarch_cfg "${cfg_dir}/retroarch.cfg"

    local patcher="$(dirname "${BASH_SOURCE[0]}")/rom-config/patch_retroarch_cfg.py"
    if [[ -f "$patcher" && -f "${cfg_dir}/retroarch.cfg" ]]; then
        local tmp_cfg patch_err
        tmp_cfg=$(mktemp)
        patch_err=$(mktemp)
        if gow_python3 "$patcher" "${cfg_dir}/retroarch.cfg" --reset-port1 --stdout > "$tmp_cfg" 2>"$patch_err"; then
            if [[ -s "$tmp_cfg" ]] && grep -q '^reset [1-9]' "$patch_err"; then
                chmod u+w "${cfg_dir}/retroarch.cfg" 2>/dev/null || true
                chattr -i "${cfg_dir}/retroarch.cfg" 2>/dev/null || true
                mv "$tmp_cfg" "${cfg_dir}/retroarch.cfg"
                chmod u+w "${cfg_dir}/retroarch.cfg" 2>/dev/null || true
                _gow_repair_info "Cleared keyboard Port 1 binds so Wolf pad autoconfig can apply"
            else
                rm -f "$tmp_cfg"
            fi
        else
            rm -f "$tmp_cfg"
        fi
        rm -f "$patch_err"
    fi

    [[ -f "$seeder" ]] || {
        _gow_repair_warn "RetroArch autoconfig seeder missing at ${seeder}"
        return 1
    }

    _gow_repair_info "Seeding RetroArch controller autoconfig (Wolf virtual pads)"
    if docker run --rm \
        -v "${cfg_dir}:/ra:rw" \
        -v "${bundled}:/bundled-autoconfig:ro" \
        -v "${seeder}:/seed_retroarch_autoconfig.sh:ro" \
        --entrypoint bash \
        "$image" \
        /seed_retroarch_autoconfig.sh /ra /bundled-autoconfig; then
        local count
        count=$(find "${cfg_dir}/autoconfig/udev" -maxdepth 1 -name '*.cfg' 2>/dev/null | wc -l | tr -d ' ')
        _gow_repair_info "RetroArch autoconfig ready: ${count} profile(s)"
    else
        _gow_repair_warn "RetroArch autoconfig seed failed for ${image}"
        if [[ -d "${bundled}/udev" ]]; then
            cp -f "${bundled}/udev/"*.cfg "${cfg_dir}/autoconfig/udev/" 2>/dev/null || true
            _gow_repair_info "Installed bundled Wolf controller profiles only"
        fi
    fi

    chown -R 1000:1000 "$cfg_dir" 2>/dev/null || true
}

# Seed Wolf gamepad defaults for standalone emulators (Dolphin, PCSX2, RPCS3, Xemu, …).
gow_seed_emulator_controller_configs() {
    local profile_dir="${1%/}"
    local image="${2:-}"
    local bundled="$(dirname "${BASH_SOURCE[0]}")/emulator-config"
    local seeder="$(dirname "${BASH_SOURCE[0]}")/rom-config/seed_emulator_configs.sh"

    [[ -d "$bundled" ]] || {
        _gow_repair_warn "Bundled emulator configs missing at ${bundled}"
        return 1
    }
    [[ -f "$seeder" ]] || {
        _gow_repair_warn "Emulator config seeder missing at ${seeder}"
        return 1
    }

    _gow_repair_info "Seeding Wolf gamepad configs for standalone emulators"
    if docker run --rm \
        -v "${profile_dir}:/profile:rw" \
        -v "${bundled}:/bundled-emulator-config:ro" \
        -v "${seeder}:/seed_emulator_configs.sh:ro" \
        --entrypoint bash \
        "${image:-ghcr.io/games-on-whales/es-de:edge}" \
        /seed_emulator_configs.sh /profile /bundled-emulator-config; then
        if [[ -f "${profile_dir}/.config/dolphin-emu/Profiles/GCPad/Wolf_XBox_One.ini" ]]; then
            _gow_repair_info "Dolphin GameCube/Wii controller profiles installed"
        else
            _gow_repair_warn "Dolphin controller profile missing after seed"
        fi
    else
        _gow_repair_warn "Emulator controller config seed failed"
        return 1
    fi

    chown -R 1000:1000 "${profile_dir}/.config" "${profile_dir}/.local" 2>/dev/null || true
}

_gow_patch_retroarch_cfg() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0
    chmod u+w "$cfg" 2>/dev/null || true
    grep -q '^input_autodetect_enable' "$cfg" \
        || echo 'input_autodetect_enable = "true"' >> "$cfg"
    grep -q '^input_joypad_driver' "$cfg" \
        || echo 'input_joypad_driver = "udev"' >> "$cfg"
    grep -q '^input_auto_game_focus' "$cfg" \
        || echo 'input_auto_game_focus = "true"' >> "$cfg"
}

# Pegasus Applications collection (emulator launcher shortcuts).
gow_seed_pegasus_metadata() {
    local pegasus_cfg="${1%/}"
    local image="$2"
    local dest="${pegasus_cfg}/metadata.pegasus.txt"

    mkdir -p "$pegasus_cfg"
    if [[ -f "$dest" ]]; then
        _gow_repair_info "Pegasus metadata.pegasus.txt already present"
        return 0
    fi

    if docker run --rm --entrypoint cat "$image" /cfg/app/metadata.pegasus.txt > "$dest" 2>/dev/null; then
        _gow_repair_info "Seeded Pegasus Applications metadata"
    else
        _gow_repair_warn "Could not extract Pegasus metadata from ${image}"
        return 1
    fi
}
