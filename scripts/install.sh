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
            name=$(lspci -s "$pci_slot" -mm 2>/dev/null | awk -F'"' '{print $6}') || true
            [[ -z "$name" ]] && name="Unknown"
        fi

        GPU_RENDER_NODES+=("$render_dev")
        GPU_DRIVERS+=("$driver")
        GPU_VENDORS+=("$vendor")
        GPU_NAMES+=("$name")
    done
}

write_initial_cfg() {
    mkdir -p "$GOW_PLUGIN"

    # Preserve existing config on reinstall so user settings aren't lost
    if [[ -f "$GOW_CFG" ]]; then
        info "Existing config found at ${GOW_CFG} — preserving"
        return
    fi

    cat > "$GOW_CFG" <<EOF
APPDATA=${DEFAULT_APPDATA}
RENDER_NODE=
GPU_VENDOR=
GPU_NAME=
GPU_DRIVER=
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
}

install_settings_ui() {
    local pkg
    pkg=$(ls "${GOW_PACKAGE_DIR}"/settings-ui-*.txz 2>/dev/null | tail -1)
    [[ -n "$pkg" ]] || err "settings-ui package not found in ${GOW_PACKAGE_DIR}"
    info "Installing settings-ui package"
    /sbin/installpkg "$pkg"
}

write_initial_cfg
install_settings_ui

info "Phase 1 complete — open Settings > Games on Whales to finish setup"
exit 0
