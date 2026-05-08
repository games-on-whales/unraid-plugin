#!/bin/bash
# deploy.sh — Phase 2: deploy Wolf + Wolf Den via Docker Compose
#
# Called by gow.page when the user clicks Install/Apply.
# Reads GPU and appdata config from $GOW_CFG.
# Safe to re-run: stops any existing stack before reconfiguring.

set -euo pipefail

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN:  $*" >&2; }

[[ $EUID -eq 0 ]] || err "Must run as root"

[[ -f "$GOW_CFG" ]] || err "Config not found at ${GOW_CFG} — run the plugin installer first"
source "$GOW_CFG"

APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
[[ -n "${RENDER_NODE:-}" ]] || err "No GPU configured. Select a GPU in Settings > Games on Whales."
[[ -n "${GPU_VENDOR:-}"  ]] || err "GPU vendor not set. Re-run setup in Settings > Games on Whales."

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
    mkdir -p "${APPDATA}/cfg" "${APPDATA}/wolf-den" "${APPDATA}/covers" "${APPDATA}/steam"
    # wolf-den drops privileges via gosu — dirs must be accessible by the container user
    chmod 755 "${APPDATA}/wolf-den" "${APPDATA}/covers"
}

# Wolf v1+ requires a uuid in config.toml. Older auto-generated configs (v0)
# may be missing it, which causes Wolf to crash on startup.
ensure_wolf_uuid() {
    local cfg_file="${APPDATA}/cfg/config.toml"
    [[ -f "$cfg_file" ]] || return 0   # no existing config — Wolf generates a fresh one
    if ! grep -q 'uuid' "$cfg_file"; then
        info "Upgrading Wolf config: adding missing uuid"
        local uuid
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) \
            || uuid=$(printf '%s' "$(date +%s%N)$(hostname)" | md5sum | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\).*/\1-\2-\3-\4-\5/')
        if grep -q '^\[server\]' "$cfg_file"; then
            sed -i '/^\[server\]/a uuid = "'"${uuid}"'"' "$cfg_file"
        else
            printf '[server]\nuuid = "%s"\n\n' "${uuid}" | cat - "$cfg_file" > "${cfg_file}.tmp"
            mv "${cfg_file}.tmp" "$cfg_file"
        fi
    fi
}

# ── Docker Compose ────────────────────────────────────────────────────────────

write_compose_nvidia() {
    cat > "$COMPOSE_FILE" <<YAML
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    container_name: wolf
    environment:
      - WOLF_RENDER_NODE=${RENDER_NODE}
      - NVIDIA_DRIVER_VOLUME_NAME=nvidia-driver-vol
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
    volumes:
      - ${APPDATA}/cfg:/etc/wolf/cfg:rw
      - ${APPDATA}/steam:/etc/wolf/steam:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - nvidia-driver-vol:/usr/nvidia:rw
      - wolf-socket:/tmp/sockets
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
      - /dev/nvidia-uvm
      - /dev/nvidia-uvm-tools
      - /dev/nvidia-caps/nvidia-cap1
      - /dev/nvidia-caps/nvidia-cap2
      - /dev/nvidiactl
      - /dev/nvidia0
      - /dev/nvidia-modeset
    device_cgroup_rules:
      - 'c 13:* rmw'
    network_mode: host
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    container_name: wolf-den
    environment:
      - WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock
      - WOLF_SOCKET_TIMEOUT=60
    volumes:
      - wolf-socket:/tmp/sockets
      - ${APPDATA}/wolf-den:/app/wolf-den
      - ${APPDATA}/covers:/etc/wolf/covers
    ports:
      - "8080:8080"
    depends_on:
      - wolf
    restart: unless-stopped

volumes:
  nvidia-driver-vol:
    external: true
  wolf-socket:
YAML
}

write_compose_standard() {
    cat > "$COMPOSE_FILE" <<YAML
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    container_name: wolf
    environment:
      - WOLF_RENDER_NODE=${RENDER_NODE}
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=/etc/wolf/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
    volumes:
      - ${APPDATA}/cfg:/etc/wolf/cfg:rw
      - ${APPDATA}/steam:/etc/wolf/steam:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - wolf-socket:/tmp/sockets
    device_cgroup_rules:
      - 'c 13:* rmw'
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
    network_mode: host
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    container_name: wolf-den
    environment:
      - WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock
      - WOLF_SOCKET_TIMEOUT=60
    volumes:
      - wolf-socket:/tmp/sockets
      - ${APPDATA}/wolf-den:/app/wolf-den
      - ${APPDATA}/covers:/etc/wolf/covers
    ports:
      - "8080:8080"
    depends_on:
      - wolf
    restart: unless-stopped

volumes:
  wolf-socket:
YAML
}

write_compose() {
    info "Writing docker-compose.yml for ${GPU_VENDOR}"
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

    if docker volume inspect nvidia-driver-vol &>/dev/null; then
        info "NVIDIA driver volume already exists — skipping build"
        return
    fi

    info "Building NVIDIA driver volume — this may take several minutes..."
    curl -fsSL \
        "https://raw.githubusercontent.com/games-on-whales/gow/master/images/nvidia-driver/Dockerfile" \
        | docker build -t gow/nvidia-driver:latest -f - \
            --build-arg NV_VERSION="${NV_VERSION}" .

    docker create --rm \
        --mount source=nvidia-driver-vol,destination=/usr/nvidia \
        gow/nvidia-driver:latest sh

    info "NVIDIA driver volume ready"
}

# ── Boot persistence ──────────────────────────────────────────────────────────

install_autostart() {
    local marker="# GoW docker-compose"
    if ! grep -qF "$marker" "$GO_SCRIPT" 2>/dev/null; then
        info "Adding Wolf auto-start to /boot/config/go"
        cat >> "$GO_SCRIPT" <<EOF

${marker}
docker compose -f ${COMPOSE_FILE} up -d &
EOF
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Stop existing stack on reconfigure
if [[ -f "$COMPOSE_FILE" ]]; then
    info "Stopping existing stack for reconfiguration"
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
fi

install_udev_rules
setup_appdata_dirs
ensure_wolf_uuid
write_compose

if [[ "$GPU_VENDOR" == "NVIDIA" ]]; then
    build_nvidia_volume
fi

info "Pulling Docker images..."
docker compose -f "$COMPOSE_FILE" pull

info "Starting Wolf + Wolf Den..."
docker compose -f "$COMPOSE_FILE" up -d

install_autostart

sed -i "s|^DEPLOYED=.*|DEPLOYED=true|" "$GOW_CFG"

LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

cat <<EOF

================================================================
Games on Whales deployed successfully.

  Wolf Den:  http://${LOCAL_IP:-<HOST_IP>}:8080
  Appdata:   ${APPDATA}
  GPU:       ${GPU_VENDOR} ${GPU_NAME:-} (${RENDER_NODE})

To pair with Moonlight:
  1. Open Wolf Den at http://${LOCAL_IP:-<HOST_IP>}:8080
  2. Add this server in Moonlight: ${LOCAL_IP:-<HOST_IP>}
  3. Enter the PIN shown in Moonlight into Wolf Den
================================================================
EOF

exit 0
