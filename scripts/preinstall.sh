#!/bin/bash
# preinstall.sh — boot-safe precondition checks before installing the GoW plugin

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "==> $*"; }

check_unraid_version() {
    local version_file="/etc/unraid-version"
    [[ -f "$version_file" ]] || err "Not running on Unraid"

    local ver
    ver=$(grep -oP 'version="\K[^"]+' "$version_file")
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)

    if (( major < 6 || ( major == 6 && minor < 12 ) )); then
        err "Unraid 6.12.0 or newer is required (found ${ver}). Please update Unraid first."
    fi
    info "Unraid version OK (${ver})"
}

check_docker() {
    if ! docker info &>/dev/null; then
        warn "Docker is not running yet. Enable Docker before deploying Wolf from the settings page."
        return
    fi
    info "Docker OK"
}

check_nvidia() {
    local has_nvidia=false driver

    for node in /sys/class/drm/renderD*/device/driver; do
        [[ -e "$node" ]] || continue
        driver=$(basename "$(readlink "$node")")
        if [[ "$driver" == "nvidia" ]]; then
            has_nvidia=true
        fi
    done

    if [[ "$has_nvidia" == "true" ]]; then
        if [[ ! -f /boot/config/plugins/nvidia-driver.plg ]]; then
            warn "NVIDIA GPU detected but the Nvidia-Driver plugin is not installed."
            warn "If you want to use the NVIDIA GPU with Wolf, install Nvidia-Driver from Community Applications first."
        else
            info "NVIDIA driver plugin OK"
        fi
    fi
}

check_network() {
    info "Checking network connectivity..."
    if ping -c1 -W2 ghcr.io &>/dev/null; then
        info "Network OK"
    else
        warn "Cannot reach ghcr.io right now. Image pulls may fail until network connectivity is available."
    fi
}

check_unraid_version
check_docker
check_nvidia
check_network

exit 0
