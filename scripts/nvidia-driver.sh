#!/bin/bash
# Shared NVIDIA userspace driver-volume maintenance for deploy and update.
# Callers provide err() and info().

NV_VERSION_LABEL="org.games-on-whales.nv_version"

detect_nvidia_version() {
    NV_VERSION=$(cat /sys/module/nvidia/version 2>/dev/null) || true
    [[ -n "${NV_VERSION:-}" ]] && return

    if [[ -f /proc/driver/nvidia/version ]]; then
        NV_VERSION=$(awk '/NVRM version/{print $8}' /proc/driver/nvidia/version) || true
        [[ -n "${NV_VERSION:-}" ]] && return
    fi

    if command -v nvidia-smi &>/dev/null; then
        NV_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1) || true
        [[ -n "${NV_VERSION:-}" ]] && return
    fi

    err "Cannot determine NVIDIA driver version. Is the NVIDIA driver plugin active?"
}

cleanup_nvidia_driver_containers() {
    local ids
    ids=$(docker ps -aq \
        --filter "ancestor=gow/nvidia-driver:latest" \
        --filter "status=created" 2>/dev/null || true)
    if [[ -n "$ids" ]]; then
        info "Removing stale NVIDIA driver volume helper containers"
        docker rm $ids >/dev/null 2>&1 || true
    fi
}

build_nvidia_volume() {
    detect_nvidia_version
    info "NVIDIA driver version: ${NV_VERSION}"
    cleanup_nvidia_driver_containers

    if docker volume inspect nvidia-driver-vol &>/dev/null; then
        local built_version
        built_version=$(docker volume inspect nvidia-driver-vol \
            --format "{{ index .Labels \"${NV_VERSION_LABEL}\" }}" 2>/dev/null) || true
        if [[ "$built_version" == "$NV_VERSION" ]]; then
            info "NVIDIA driver volume already built for ${NV_VERSION} — skipping build"
            return
        fi
        info "NVIDIA driver volume was built for '${built_version:-unknown}' but host driver is ${NV_VERSION} — rebuilding"
        docker volume rm nvidia-driver-vol >/dev/null 2>&1 \
            || err "Failed to remove stale nvidia-driver-vol. Stop containers using it and retry."
    fi

    info "Building NVIDIA driver volume — this may take several minutes..."
    curl -fsSL \
        "https://raw.githubusercontent.com/games-on-whales/gow/master/images/nvidia-driver/Dockerfile" \
        | docker build -t gow/nvidia-driver:latest -f - \
            --build-arg NV_VERSION="${NV_VERSION}" .

    docker volume create \
        --label "${NV_VERSION_LABEL}=${NV_VERSION}" \
        nvidia-driver-vol >/dev/null

    local cid
    cid=$(docker create \
        --label org.games-on-whales.unraid-plugin=nvidia-driver-volume \
        --mount source=nvidia-driver-vol,destination=/usr/nvidia \
        gow/nvidia-driver:latest sh)
    docker rm "$cid" >/dev/null

    info "NVIDIA driver volume ready"
}
