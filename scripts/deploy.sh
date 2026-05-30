#!/bin/bash
# deploy.sh — Phase 2: deploy Wolf + Wolf Den via Docker Compose
#
# Called by gow.page when the user clicks Install/Apply.
# Reads GPU and appdata config from $GOW_CFG.
# Safe to re-run: stops any existing stack before reconfiguring.

set -euo pipefail

source "$(dirname "$0")/vars.sh"
source "$(dirname "$0")/pairing-state.sh"
source "$(dirname "$0")/library-links.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN:  $*" >&2; }

[[ $EUID -eq 0 ]] || err "Must run as root"

[[ -f "$GOW_CFG" ]] || err "Config not found at ${GOW_CFG} — run the plugin installer first"
source "$GOW_CFG"

APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
WOLF_DEN_PORT="${WOLF_DEN_PORT:-8080}"
WOLF_NETWORK_MODE="${WOLF_NETWORK_MODE:-host}"
WOLF_NETWORK_NAME="${WOLF_NETWORK_NAME:-}"
WOLF_NETWORK_IPV4="${WOLF_NETWORK_IPV4:-}"
STEAM_LIBRARY="${STEAM_LIBRARY:-}"
GAMES_LIBRARY="${GAMES_LIBRARY:-}"
ROMS_LIBRARY="${ROMS_LIBRARY:-}"
BIOS_LIBRARY="${BIOS_LIBRARY:-}"
MEDIA_LIBRARY="${MEDIA_LIBRARY:-}"
LUTRIS_LIBRARY="${LUTRIS_LIBRARY:-}"
PRISM_LIBRARY="${PRISM_LIBRARY:-}"
COMPAT_TOOLS_PATH="${COMPAT_TOOLS_PATH:-}"
WOLF_MEMORY_LIMIT="${WOLF_MEMORY_LIMIT:-}"
WOLF_DEN_MEMORY_LIMIT="${WOLF_DEN_MEMORY_LIMIT:-}"
WOLF_IMAGE="${WOLF_IMAGE:-${DEFAULT_WOLF_IMAGE}}"
WOLF_DEN_IMAGE="${WOLF_DEN_IMAGE:-${DEFAULT_WOLF_DEN_IMAGE}}"
WOLF_ENCODER_NODE="${WOLF_ENCODER_NODE:-}"
[[ -n "${RENDER_NODE:-}" ]] || err "No GPU configured. Select a GPU in Settings > Games on Whales."
[[ -n "${GPU_VENDOR:-}"  ]] || err "GPU vendor not set. Re-run setup in Settings > Games on Whales."
if [[ ! "$WOLF_DEN_PORT" =~ ^[0-9]+$ ]] || (( WOLF_DEN_PORT < 1 || WOLF_DEN_PORT > 65535 )); then
    err "Wolf Den port must be a TCP port between 1 and 65535"
fi
WOLF_DEN_LISTEN_URL="http://0.0.0.0:${WOLF_DEN_PORT}"

valid_network_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

valid_ipv4() {
    local ip="$1" part
    local -a parts
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do
        (( part >= 0 && part <= 255 )) || return 1
    done
}

valid_memory_limit() {
    local limit="$1"
    [[ -z "$limit" ]] && return 0
    [[ "$limit" =~ ^[0-9]+[bkmgBKMG]?$ ]]
}

warn_host_memory() {
    local total_kb total_gib
    total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    (( total_kb > 0 )) || return 0
    total_gib=$(( total_kb / 1024 / 1024 ))
    if (( total_gib < 12 )); then
        warn "Host RAM is about ${total_gib} GiB. Wolf streaming plus emulators can OOM smaller systems — enable Unraid swap and keep Moonlight at 1080p/H.264 if you see crashes."
    fi
    if [[ -z "$WOLF_MEMORY_LIMIT" ]] && (( total_gib <= 16 )); then
        warn "Consider setting a Wolf memory cap in plugin setup (e.g. 6G on a 16 GiB box) so a Wolf leak cannot take down the whole server."
    fi
}

validate_network_config() {
    case "$WOLF_NETWORK_MODE" in
        host|bridge)
            ;;
        custom)
            [[ -n "$WOLF_NETWORK_NAME" ]] || err "Custom Wolf network requires a Docker network name such as br0"
            valid_network_name "$WOLF_NETWORK_NAME" || err "Wolf network name contains unsupported characters"
            docker network inspect "$WOLF_NETWORK_NAME" >/dev/null 2>&1 \
                || err "Docker network '${WOLF_NETWORK_NAME}' was not found"
            [[ -n "$WOLF_NETWORK_IPV4" ]] || err "Custom Wolf network requires a static IPv4 address"
            valid_ipv4 "$WOLF_NETWORK_IPV4" || err "Wolf static IPv4 address is invalid"
            ;;
        *)
            err "Wolf network mode must be host, bridge, or custom"
            ;;
    esac
}

GO_SCRIPT="/boot/config/go"
COMPOSE_FILE="${APPDATA}/docker-compose.yml"
UDEV_RULES_FLASH="/boot/config/gow-virtual-inputs.rules"
UDEV_RULES_LIVE="/etc/udev/rules.d/85-gow-virtual-inputs.rules"

# ── udev rules ────────────────────────────────────────────────────────────────

install_udev_rules() {
    info "Installing udev rules"

    cat > "$UDEV_RULES_FLASH" <<'UDEV'
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="input", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", MODE="0660", ENV{ID_SEAT}="seat9"
UDEV

    cp "$UDEV_RULES_FLASH" "$UDEV_RULES_LIVE"
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true

    local marker="# GoW udev rules"
    if ! grep -qF "$marker" "$GO_SCRIPT" 2>/dev/null; then
        info "Adding udev restore to /boot/config/go"
        cat >> "$GO_SCRIPT" <<EOF

${marker}
cp ${UDEV_RULES_FLASH} ${UDEV_RULES_LIVE}
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
EOF
    fi
}

# ── appdata directories ───────────────────────────────────────────────────────

setup_appdata_dirs() {
    info "Creating appdata directories at ${APPDATA}"
    mkdir -p \
        "${APPDATA}/cfg" \
        "${APPDATA}/run" \
        "${APPDATA}/wolf-den" \
        "${APPDATA}/covers"
    info "Appdata skeleton created"

    # wolf-den drops privileges to UID 1000 via gosu, so its writable dirs
    # must be accessible before the app starts.
    info "Setting Wolf Den file ownership (can take a moment on slow shares)..."
    chown -R 1000:1000 "${APPDATA}/wolf-den" "${APPDATA}/covers" 2>/dev/null || true
    chmod 775 "${APPDATA}/wolf-den" "${APPDATA}/covers"
    info "Appdata directories ready"
}

sync_library_links_logged() {
    local line
    info "Publishing library paths under ${APPDATA} (symlinks only when needed)"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        info "  ${line/=/ → }"
    done < <(gow_sync_library_links "$APPDATA")
    gow_resolve_library_mounts "$APPDATA"
    if [[ -n "${PRISM_LIBRARY:-}" ]]; then
        mkdir -p "${PRISM_LIBRARY}"
        chown 1000:1000 "${PRISM_LIBRARY}" 2>/dev/null || true
    elif [[ -n "${GAMES_LIBRARY:-}" ]]; then
        mkdir -p "${GAMES_LIBRARY}/prismlauncher"
        chown 1000:1000 "${GAMES_LIBRARY}/prismlauncher" 2>/dev/null || true
    fi
    if [[ -n "${COMPAT_TOOLS_PATH:-}" ]]; then
        chown -R 1000:1000 "$COMPAT_TOOLS_PATH" 2>/dev/null || true
        chmod 775 "$COMPAT_TOOLS_PATH" 2>/dev/null || true
    fi
}

migrate_legacy_etc_wolf() {
    local legacy="/etc/wolf"
    [[ "$APPDATA" != "$legacy" && -d "$legacy" && ! -L "$legacy" ]] || return 0

    info "Migrating existing Wolf data from ${legacy} into ${APPDATA}"
    cp -a -n "${legacy}/." "${APPDATA}/" 2>/dev/null \
        || warn "Could not migrate all existing Wolf data from ${legacy}"
}

cleanup_wolf_runtime_containers() {
    local container="WolfPulseAudio"
    if docker inspect "$container" &>/dev/null; then
        info "Removing Wolf runtime container ${container}"
        docker rm -f "$container" >/dev/null 2>&1 \
            || warn "Could not remove Wolf runtime container ${container}"
    fi
}

cleanup_stale_wolf_sessions() {
    local script
    script="$(dirname "$0")/cleanup-wolf-sessions.sh"
    [[ -x "$script" ]] || return 0
    bash "$script" || warn "Stale Wolf session cleanup encountered errors"
}

write_compose_memory_limits() {
    local service="$1"
    local limit=""

    case "$service" in
        wolf) limit="$WOLF_MEMORY_LIMIT" ;;
        wolf-den) limit="$WOLF_DEN_MEMORY_LIMIT" ;;
    esac

    [[ -n "$limit" ]] || return 0
    valid_memory_limit "$limit" || err "Invalid memory limit for ${service}: ${limit} (use e.g. 6G or 512M)"
    printf '    mem_limit: %s\n' "$limit"
}

# ── Docker Compose ────────────────────────────────────────────────────────────

write_library_mounts() {
    if [[ -n "$STEAM_LIBRARY" ]]; then
        printf '      - %s:/etc/wolf/steam:rw\n' "$STEAM_LIBRARY"
    fi
    if [[ -n "$GAMES_LIBRARY" ]]; then
        printf '      - %s:/etc/wolf/games:rw\n' "$GAMES_LIBRARY"
    fi
    if [[ -n "$ROMS_LIBRARY" ]]; then
        printf '      - %s:/etc/wolf/roms:rw\n' "$ROMS_LIBRARY"
    fi
    if [[ -n "$BIOS_LIBRARY" ]]; then
        printf '      - %s:/etc/wolf/bioses:rw\n' "$BIOS_LIBRARY"
    fi
    if [[ -n "$MEDIA_LIBRARY" ]]; then
        printf '      - %s:/etc/wolf/media:rw\n' "$MEDIA_LIBRARY"
    fi
    if [[ -n "$LUTRIS_LIBRARY" ]]; then
        printf '      - %s:/etc/wolf/lutris:rw\n' "$LUTRIS_LIBRARY"
    fi
    if [[ -n "$PRISM_LIBRARY" ]]; then
        printf '      - %s:/etc/wolf/prismlauncher:rw\n' "$PRISM_LIBRARY"
    fi
    if [[ -n "$COMPAT_TOOLS_PATH" ]]; then
        printf '      - %s:/etc/wolf/compatibilitytools.d:rw\n' "$COMPAT_TOOLS_PATH"
    fi
}

write_wolf_den_compat_mount() {
    if [[ -n "$COMPAT_TOOLS_PATH" ]]; then
        cat <<YAML
      - ${COMPAT_TOOLS_PATH}:/etc/wolf/compatibilitytools.d:rw
YAML
    fi
}

write_wolf_network_env() {
    if [[ "$WOLF_NETWORK_MODE" == "custom" && -n "$WOLF_NETWORK_IPV4" ]]; then
        cat <<YAML
      - WOLF_INTERNAL_IP=${WOLF_NETWORK_IPV4}
YAML
    fi
}

write_wolf_encoder_env() {
    if [[ -n "$WOLF_ENCODER_NODE" ]]; then
        cat <<YAML
      - WOLF_ENCODER_NODE=${WOLF_ENCODER_NODE}
      - GST_GL_DRM_DEVICE=${WOLF_ENCODER_NODE}
YAML
    fi
}

write_wolf_network_service() {
    case "$WOLF_NETWORK_MODE" in
        host)
            cat <<YAML
    network_mode: ${WOLF_NETWORK_MODE}
YAML
            ;;
        bridge)
            cat <<YAML
    ports:
      - "47984:47984/tcp"
      - "47989:47989/tcp"
      - "48010:48010/tcp"
      - "47999:47999/udp"
      - "48100:48100/udp"
      - "48200:48200/udp"
    network_mode: bridge
YAML
            ;;
        custom)
            cat <<YAML
    networks:
      gow-wolf:
        ipv4_address: ${WOLF_NETWORK_IPV4}
YAML
            ;;
    esac
}

write_compose_networks() {
    [[ "$WOLF_NETWORK_MODE" == "custom" ]] || return 0
    cat <<YAML

networks:
  gow-wolf:
    external: true
    name: ${WOLF_NETWORK_NAME}
YAML
}

write_compose_nvidia() {
    local nvidia_devices
    nvidia_devices="$(nvidia_device_entries)"

    {
    cat <<YAML
services:
  wolf:
    image: ${WOLF_IMAGE}
    container_name: wolf
    environment:
      - WOLF_RENDER_NODE=${RENDER_NODE}
$(write_wolf_encoder_env)
      - NVIDIA_DRIVER_VOLUME_NAME=nvidia-driver-vol
      - WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
$(write_wolf_pairing_env)
YAML
    write_wolf_network_env
    cat <<YAML
    volumes:
      - ${APPDATA}:/etc/wolf:rw
      - ${APPDATA}/run:/var/run/wolf:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - nvidia-driver-vol:/usr/nvidia:rw
$(write_library_mounts)
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
${nvidia_devices}
    device_cgroup_rules:
      - 'c 13:* rmw'
$(write_compose_memory_limits wolf)
YAML
    write_wolf_network_service
    cat <<YAML
    restart: unless-stopped

  wolf-den:
    image: ${WOLF_DEN_IMAGE}
    container_name: wolf-den
    environment:
      - WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock
      - WOLF_SOCKET_TIMEOUT=60
      - XDG_DATA_HOME=/app/wolf-den
      - ASPNETCORE_URLS=${WOLF_DEN_LISTEN_URL}
    volumes:
      - ${APPDATA}/run:/var/run/wolf:rw
      - ${APPDATA}:/etc/wolf:rw
      - ${APPDATA}/wolf-den:/app/wolf-den
$(write_wolf_den_compat_mount)
    network_mode: host
    depends_on:
      - wolf
$(write_compose_memory_limits wolf-den)
    restart: unless-stopped

volumes:
  nvidia-driver-vol:
    external: true
YAML
    write_compose_networks
    } > "$COMPOSE_FILE"
}

nvidia_device_entries() {
    local dev
    for dev in \
        /dev/nvidiactl \
        /dev/nvidia[0-9]* \
        /dev/nvidia-modeset \
        /dev/nvidia-uvm \
        /dev/nvidia-uvm-tools \
        /dev/nvidia-caps/nvidia-cap*; do
        [[ -e "$dev" ]] && printf '      - %s\n' "$dev"
    done
}

write_compose_standard() {
    {
    cat <<YAML
services:
  wolf:
    image: ${WOLF_IMAGE}
    container_name: wolf
    environment:
      - WOLF_RENDER_NODE=${RENDER_NODE}
$(write_wolf_encoder_env)
      - WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
$(write_wolf_pairing_env)
YAML
    write_wolf_network_env
    cat <<YAML
    volumes:
      - ${APPDATA}:/etc/wolf:rw
      - ${APPDATA}/run:/var/run/wolf:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
$(write_library_mounts)
    device_cgroup_rules:
      - 'c 13:* rmw'
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
$(write_compose_memory_limits wolf)
YAML
    write_wolf_network_service
    cat <<YAML
    restart: unless-stopped

  wolf-den:
    image: ${WOLF_DEN_IMAGE}
    container_name: wolf-den
    environment:
      - WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock
      - WOLF_SOCKET_TIMEOUT=60
      - XDG_DATA_HOME=/app/wolf-den
      - ASPNETCORE_URLS=${WOLF_DEN_LISTEN_URL}
    volumes:
      - ${APPDATA}/run:/var/run/wolf:rw
      - ${APPDATA}:/etc/wolf:rw
      - ${APPDATA}/wolf-den:/app/wolf-den
$(write_wolf_den_compat_mount)
    network_mode: host
    depends_on:
      - wolf
$(write_compose_memory_limits wolf-den)
    restart: unless-stopped
YAML
    write_compose_networks
    } > "$COMPOSE_FILE"
}

write_compose() {
    info "Writing docker-compose.yml for ${GPU_VENDOR} with Wolf network mode ${WOLF_NETWORK_MODE}"
    case "$GPU_VENDOR" in
        NVIDIA)    write_compose_nvidia   ;;
        AMD|Intel) write_compose_standard ;;
        *)         err "Unsupported GPU vendor: ${GPU_VENDOR}" ;;
    esac
}

# ── NVIDIA driver volume ──────────────────────────────────────────────────────

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

build_nvidia_volume() {
    detect_nvidia_version
    info "NVIDIA driver version: ${NV_VERSION}"
    cleanup_nvidia_driver_containers

    if docker volume inspect nvidia-driver-vol &>/dev/null; then
        info "NVIDIA driver volume already exists — skipping build"
        return
    fi

    info "Building NVIDIA driver volume — this may take several minutes..."
    curl -fsSL \
        "https://raw.githubusercontent.com/games-on-whales/gow/master/images/nvidia-driver/Dockerfile" \
        | docker build -t gow/nvidia-driver:latest -f - \
            --build-arg NV_VERSION="${NV_VERSION}" .

    local cid
    cid=$(docker create \
        --label org.games-on-whales.unraid-plugin=nvidia-driver-volume \
        --mount source=nvidia-driver-vol,destination=/usr/nvidia \
        gow/nvidia-driver:latest sh)
    docker rm "$cid" >/dev/null

    info "NVIDIA driver volume ready"
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

# ── Boot persistence ──────────────────────────────────────────────────────────

install_autostart() {
    local marker="# GoW docker-compose"
    local end_marker="# End GoW docker-compose"
    local marker_re="${marker//\//\\/}"
    local end_marker_re="${end_marker//\//\\/}"
    if grep -qF "$marker" "$GO_SCRIPT" 2>/dev/null; then
        info "Updating Wolf auto-start in /boot/config/go"
        if grep -qF "$end_marker" "$GO_SCRIPT" 2>/dev/null; then
            sed -i "/${marker_re}/,/${end_marker_re}/d" "$GO_SCRIPT"
        else
            sed -i "/${marker_re}/,/^$/d" "$GO_SCRIPT"
        fi
    else
        info "Adding Wolf auto-start to /boot/config/go"
    fi

    cat >> "$GO_SCRIPT" <<EOF

${marker}
(
  GOW_COMPOSE_FILE='${COMPOSE_FILE}'
  GOW_RENDER_NODE='${RENDER_NODE}'
  GOW_GPU_VENDOR='${GPU_VENDOR}'
  GOW_AUTOSTART_LOG='/tmp/gow-autostart.log'

  gow_nvidia_gpu_ready() {
    for dev in /dev/nvidia[0-9]*; do
      [ -e "\$dev" ] && return 0
    done
    return 1
  }

  gow_devices_ready() {
    [ -z "\$GOW_RENDER_NODE" ] || [ -e "\$GOW_RENDER_NODE" ] || return 1
    if [ "\$GOW_GPU_VENDOR" = "NVIDIA" ]; then
      [ -e /dev/nvidiactl ] && gow_nvidia_gpu_ready && [ -e /dev/nvidia-uvm ] || return 1
    fi
    return 0
  }

  for i in \$(seq 1 60); do
    if docker info >/dev/null 2>&1 && [ -f "\$GOW_COMPOSE_FILE" ] && gow_devices_ready; then
      docker compose -f "\$GOW_COMPOSE_FILE" up -d >"\$GOW_AUTOSTART_LOG" 2>&1
      exit
    fi
    sleep 5
  done

  echo "GoW auto-start timed out waiting for Docker, GPU devices, or \$GOW_COMPOSE_FILE" >"\$GOW_AUTOSTART_LOG"
) &
${end_marker}
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

validate_network_config
valid_memory_limit "$WOLF_MEMORY_LIMIT" || err "Wolf memory limit must be empty or like 6G / 8192M"
valid_memory_limit "$WOLF_DEN_MEMORY_LIMIT" || err "Wolf Den memory limit must be empty or like 512M"
warn_host_memory

backup_pairing_state

# Stop existing stack on reconfigure
if [[ -f "$COMPOSE_FILE" ]]; then
    info "Stopping existing stack for reconfiguration"
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
    cleanup_wolf_runtime_containers
    cleanup_stale_wolf_sessions
fi

install_udev_rules
setup_appdata_dirs
sync_library_links_logged
migrate_legacy_etc_wolf
info "Preparing Moonlight pairing state"
prepare_pairing_state
write_compose

if [[ "$GPU_VENDOR" == "NVIDIA" ]]; then
    build_nvidia_volume
fi

info "Pulling Docker images (progress below)..."
pull_attempt=1
while (( pull_attempt <= 3 )); do
    if docker compose -f "$COMPOSE_FILE" pull; then
        break
    fi
    if (( pull_attempt >= 3 )); then
        err "Image pull failed after 3 attempts"
    fi
    warn "Image pull failed (attempt ${pull_attempt}/3), retrying..."
    (( pull_attempt++ ))
    sleep 5
done

info "Starting Wolf + Wolf Den..."
docker compose -f "$COMPOSE_FILE" up -d

info "Waiting for Wolf config and API socket (for library mount presets)..."
for _ in $(seq 1 45); do
    [[ -f "${APPDATA}/cfg/config.toml" ]] || { sleep 2; continue; }
    if [[ -S "${APPDATA}/run/wolf.sock" ]]; then
        break
    fi
    sleep 2
done

if [[ -f "${APPDATA}/cfg/config.toml" ]]; then
    if bash "$(dirname "$0")/apply-mount-presets.sh"; then
        if [[ -n "${ROMS_LIBRARY:-}" ]] && [[ -x "$(dirname "$0")/repair-esde.sh" ]]; then
            bash "$(dirname "$0")/repair-esde.sh" || warn "ES-DE repair reported errors (continuing)"
            if [[ -x "$(dirname "$0")/repair-pegasus.sh" ]]; then
                bash "$(dirname "$0")/repair-pegasus.sh" || warn "Pegasus repair reported errors (continuing)"
            fi
        fi
        info "Restarting Wolf so app runner mount presets take effect..."
        docker compose -f "$COMPOSE_FILE" restart wolf
    fi
else
    warn "Wolf config not created yet; configure library paths and click Install again if app mounts are missing"
fi

verify_pairing_state

install_autostart

sed -i "s|^DEPLOYED=.*|DEPLOYED=true|" "$GOW_CFG"

LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
MOONLIGHT_HOST="${LOCAL_IP:-<HOST_IP>}"
if [[ "$WOLF_NETWORK_MODE" == "custom" && -n "$WOLF_NETWORK_IPV4" ]]; then
    MOONLIGHT_HOST="$WOLF_NETWORK_IPV4"
fi
NETWORK_LABEL="$WOLF_NETWORK_MODE"
if [[ "$WOLF_NETWORK_MODE" == "custom" ]]; then
    NETWORK_LABEL="${WOLF_NETWORK_NAME}${WOLF_NETWORK_IPV4:+ (${WOLF_NETWORK_IPV4})}"
fi

cat <<EOF

================================================================
Games on Whales deployed successfully.

  Wolf Den:  http://${LOCAL_IP:-<HOST_IP>}:${WOLF_DEN_PORT}
  Pairing:   http://${LOCAL_IP:-<HOST_IP>}:${WOLF_DEN_PORT}/Clients/Pairing
  Moonlight: ${MOONLIGHT_HOST}
  Network:   ${NETWORK_LABEL}
  Appdata:   ${APPDATA}
  GPU:       ${GPU_VENDOR} ${GPU_NAME:-} (${RENDER_NODE})

To pair with Moonlight:
  1. Open Wolf Den pairing at http://${LOCAL_IP:-<HOST_IP>}:${WOLF_DEN_PORT}/Clients/Pairing
  2. Add this server in Moonlight: ${MOONLIGHT_HOST}
  3. Enter the PIN shown in Moonlight into Wolf Den
================================================================
EOF

exit 0
