#!/bin/bash
# install.sh — Phase 1: detect GPUs, write initial config, install settings-ui package
# Wolf deployment (Phase 2) happens when the user clicks Install in the settings page.

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# GPU detection — adapted from games-on-whales/wolf quickstart/common.sh
detect_gpus() {
    GPU_RENDER_NODES=()
    GPU_DRIVERS=()
    GPU_VENDORS=()
    GPU_NAMES=()

    local node device_dir driver vendor name pci_slot
    for node in /sys/class/drm/renderD*/device/driver; do
        [[ -e "$node" ]] || continue
        device_dir="$(dirname "$node")"
        local render_dev="/dev/dri/$(basename "$(dirname "$device_dir")")"
        driver=$(basename "$(readlink "$node")")

        case "$driver" in
            i915|xe) vendor="Intel"  ;;
            amdgpu)  vendor="AMD"    ;;
            nvidia)  vendor="NVIDIA" ;;
            *)       vendor="Unknown ($driver)" ;;
        esac

        name="Unknown"
        pci_slot=$(basename "$(readlink -f "$device_dir")" 2>/dev/null) || true
        if [[ -n "$pci_slot" ]] && command -v lspci &>/dev/null; then
            name=$(lspci -s "$pci_slot" -mm 2>/dev/null | awk -F'"' 'NF >= 8 {print $8}') || true
            [[ -z "$name" ]] && name="Unknown"
        fi

        GPU_RENDER_NODES+=("$render_dev")
        GPU_DRIVERS+=("$driver")
        GPU_VENDORS+=("$vendor")
        GPU_NAMES+=("$name")
    done
}

backfill_cfg_defaults() {
    local -A defaults=(
        [STEAM_LIBRARY]="${DEFAULT_STEAM_LIBRARY}"
        [GAMES_LIBRARY]="${DEFAULT_GAMES_LIBRARY}"
        [ROMS_LIBRARY]="${DEFAULT_ROMS_LIBRARY}"
        [BIOS_LIBRARY]="${DEFAULT_BIOS_LIBRARY}"
        [MEDIA_LIBRARY]="${DEFAULT_MEDIA_LIBRARY}"
        [LUTRIS_LIBRARY]="${DEFAULT_LUTRIS_LIBRARY}"
        [PRISM_LIBRARY]="${DEFAULT_PRISM_LIBRARY}"
        [COMPAT_TOOLS_PATH]="${DEFAULT_COMPAT_TOOLS_PATH}"
        [WOLF_MEMORY_LIMIT]=""
        [WOLF_DEN_MEMORY_LIMIT]=""
        [WOLF_IMAGE]="${DEFAULT_WOLF_IMAGE}"
        [WOLF_DEN_IMAGE]="${DEFAULT_WOLF_DEN_IMAGE}"
        [WOLF_ENCODER_NODE]=""
    )
    local key val current

    for key in "${!defaults[@]}"; do
        val="${defaults[$key]}"
        if ! grep -q "^${key}=" "$GOW_CFG" 2>/dev/null; then
            echo "${key}=${val}" >> "$GOW_CFG"
            info "Added default ${key}=${val}"
            continue
        fi
        current=$(grep "^${key}=" "$GOW_CFG" | tail -1 | cut -d= -f2- | tr -d "'")
        if [[ -z "${current}" ]]; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$GOW_CFG"
            info "Backfilled empty ${key} -> ${val}"
        fi
    done
}

# Use detect-paths.sh when share folders already exist (first install helper).
apply_detected_library_paths() {
    local script="${GOW_SCRIPT_DIR}/detect-paths.sh"
    [[ -f "$script" ]] || return 0

    local line key val
    while IFS= read -r line; do
        [[ "$line" == *"="* ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            APPDATA|*_LIBRARY|COMPAT_TOOLS_PATH) ;;
            *) continue ;;
        esac
        [[ -d "$val" ]] || continue
        if grep -q "^${key}=" "$GOW_CFG" 2>/dev/null; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$GOW_CFG"
        else
            echo "${key}=${val}" >> "$GOW_CFG"
        fi
        info "Detected existing path ${key}=${val}"
    done < <(bash "$script")
}

write_initial_cfg() {
    mkdir -p "$GOW_PLUGIN"

    # Preserve existing config on reinstall so user settings aren't lost
    if [[ -f "$GOW_CFG" ]]; then
        info "Existing config found at ${GOW_CFG} — preserving"
        backfill_cfg_defaults
        GOW_FRESH_INSTALL=false
        return
    fi

    GOW_FRESH_INSTALL=true
    cat > "$GOW_CFG" <<EOF
APPDATA=${DEFAULT_APPDATA}
RENDER_NODE=
GPU_VENDOR=
GPU_NAME=
GPU_DRIVER=
WOLF_DEN_PORT=8080
WOLF_NETWORK_MODE=host
WOLF_NETWORK_NAME=
WOLF_NETWORK_IPV4=
STEAM_LIBRARY=${DEFAULT_STEAM_LIBRARY}
GAMES_LIBRARY=${DEFAULT_GAMES_LIBRARY}
ROMS_LIBRARY=${DEFAULT_ROMS_LIBRARY}
BIOS_LIBRARY=${DEFAULT_BIOS_LIBRARY}
MEDIA_LIBRARY=${DEFAULT_MEDIA_LIBRARY}
LUTRIS_LIBRARY=${DEFAULT_LUTRIS_LIBRARY}
PRISM_LIBRARY=${DEFAULT_PRISM_LIBRARY}
COMPAT_TOOLS_PATH=${DEFAULT_COMPAT_TOOLS_PATH}
WOLF_MEMORY_LIMIT=
WOLF_DEN_MEMORY_LIMIT=
WOLF_IMAGE=${DEFAULT_WOLF_IMAGE}
WOLF_DEN_IMAGE=${DEFAULT_WOLF_DEN_IMAGE}
WOLF_ENCODER_NODE=
DEPLOYED=false
EOF

    detect_gpus

    if [[ ${#GPU_RENDER_NODES[@]} -eq 0 ]]; then
        info "No GPU render nodes found — user must configure manually in the settings page"
    elif [[ ${#GPU_RENDER_NODES[@]} -eq 1 ]]; then
        info "Single GPU detected: ${GPU_VENDORS[0]} ${GPU_NAMES[0]} — pre-populating config"
        sed -i "s|^RENDER_NODE=.*|RENDER_NODE=${GPU_RENDER_NODES[0]}|" "$GOW_CFG"
        sed -i "s|^GPU_VENDOR=.*|GPU_VENDOR=${GPU_VENDORS[0]}|"       "$GOW_CFG"
        sed -i "s|^GPU_NAME=.*|GPU_NAME=${GPU_NAMES[0]}|"             "$GOW_CFG"
        sed -i "s|^GPU_DRIVER=.*|GPU_DRIVER=${GPU_DRIVERS[0]}|"       "$GOW_CFG"
    else
        info "${#GPU_RENDER_NODES[@]} GPUs detected — user must select one in the settings page"
    fi

    apply_detected_library_paths
}

install_settings_ui() {
    local pkg
    # Pick newest package by mtime (alphabetical tail can be wrong with -dev suffixes).
    pkg=$(ls -t "${GOW_PACKAGE_DIR}"/settings-ui-*.txz 2>/dev/null | head -1 || true)
    [[ -n "$pkg" ]] || err "settings-ui package not found in ${GOW_PACKAGE_DIR}"
    info "Installing settings-ui package"
    /sbin/installpkg "$pkg"
}

GOW_FRESH_INSTALL=false
write_initial_cfg
if [[ "$GOW_FRESH_INSTALL" == true ]]; then
    install_settings_ui
else
    info "Preserving installed settings UI (use Plugins → update or apply-ui.sh to refresh)"
fi

info "Phase 1 complete — open Settings > Games on Whales to finish setup"
exit 0
