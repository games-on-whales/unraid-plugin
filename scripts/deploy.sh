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

source "$(dirname "$0")/app-state.sh"

[[ $EUID -eq 0 ]] || err "Must run as root"

[[ -f "$GOW_CFG" ]] || err "Config not found at ${GOW_CFG} — run the plugin installer first"
source "$GOW_CFG"

APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
WOLF_DEN_PORT="${WOLF_DEN_PORT:-8080}"
WOLF_NETWORK_MODE="${WOLF_NETWORK_MODE:-host}"
WOLF_NETWORK_NAME="${WOLF_NETWORK_NAME:-}"
WOLF_NETWORK_IPV4="${WOLF_NETWORK_IPV4:-}"
WOLF_ZERO_COPY="${WOLF_ZERO_COPY:-true}"

# Wolf hands these to every app container as PUID/PGID, and the app state on
# disk has to be owned by the same pair — see migrate_app_state_ownership. The
# default is Unraid's nobody:users (99:100) rather than Wolf's own 1000:1000,
# because that is what owns appdata.
resolve_run_ids \
    || err "App run UID/GID must be numbers between 1 and 65533 (got ${WOLF_RUN_UID}:${WOLF_RUN_GID})"

[[ -n "${RENDER_NODE:-}" ]] || err "No GPU configured. Select a GPU in Settings > Games on Whales."
[[ -n "${GPU_VENDOR:-}"  ]] || err "GPU vendor not set. Re-run setup in Settings > Games on Whales."
if [[ ! "$WOLF_DEN_PORT" =~ ^[0-9]+$ ]] || (( WOLF_DEN_PORT < 1 || WOLF_DEN_PORT > 65535 )); then
    err "Wolf Den port must be a TCP port between 1 and 65535"
fi

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
# Wolf owns the udev rules for its virtual input devices. They are installed
# under the upstream filename so Wolf's own scripts/wolf-input-diag.sh finds
# them. The plugin used to carry its own copy, which went stale as Wolf renamed
# devices and let controller input leak onto other seats and containers
# (games-on-whales/wolf#455).
UDEV_RULES_URL="https://raw.githubusercontent.com/games-on-whales/wolf/stable/85-wolf.rules"
UDEV_RULES_FLASH="/boot/config/gow-85-wolf.rules"
UDEV_RULES_LIVE="/etc/udev/rules.d/85-wolf.rules"
LEGACY_UDEV_RULES_FLASH="/boot/config/gow-virtual-inputs.rules"
LEGACY_UDEV_RULES_LIVE="/etc/udev/rules.d/85-gow-virtual-inputs.rules"

# ── udev rules ────────────────────────────────────────────────────────────────

# Guards against installing a captive-portal page, a GitHub error page, or a
# truncated download as udev rules. The uinput rule is the one Wolf cannot run
# without, so its presence is a reliable marker for "this really is the file".
udev_rules_valid() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    grep -q 'KERNEL=="uinput"' "$file"
}

# Snapshot of games-on-whales/wolf@stable:85-wolf.rules, used only when the host
# cannot reach GitHub. Refresh it when upstream changes the rules.
write_bundled_udev_rules() {
    cat > "$1" <<'UDEV'
# Allows Wolf to access /dev/uinput (needed to create the virtual gamepad)
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"

# Allows Wolf to access /dev/uhid (needed for DualSense emulation)
KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"

# Wolf virtual controllers: the gamepads (Xbox / DualSense / Nintendo), the
# DualSense's "Touchpad" and "Motion Sensors" child input devices, and the
# DualSense /dev/hidraw* node. Matching the "Wolf *virtual*" name glob covers
# every device Wolf creates without going stale on a rename; parking them on
# the phantom seat9 and stripping the uaccess ACL keeps them off every other
# seat. See https://github.com/games-on-whales/wolf/issues/451
SUBSYSTEM=="input",  ATTR{name}=="Wolf *virtual*",  MODE="0660", GROUP="input", ENV{ID_SEAT}="seat9", TAG-="uaccess"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf *virtual*", MODE="0660", GROUP="input", ENV{ID_SEAT}="seat9", TAG-="uaccess"
KERNEL=="hidraw*",   ATTRS{name}=="Wolf *virtual*", MODE="0660", GROUP="input", ENV{ID_SEAT}="seat9", TAG-="uaccess"
UDEV
}

# Prefers the rules Wolf publishes so they stay in sync as Wolf's device names
# evolve, and falls back to the rules already on the flash drive, then to the
# bundled snapshot, when the host is offline.
fetch_udev_rules() {
    local tmp
    tmp="$(mktemp)"
    if curl -fsSL --connect-timeout 10 --max-time 30 "$UDEV_RULES_URL" -o "$tmp" \
        && udev_rules_valid "$tmp"; then
        info "Fetched Wolf udev rules from ${UDEV_RULES_URL}"
        cat "$tmp" > "$UDEV_RULES_FLASH"
        rm -f "$tmp"
        return
    fi
    rm -f "$tmp"

    if udev_rules_valid "$UDEV_RULES_FLASH"; then
        warn "Could not fetch Wolf udev rules — keeping the copy at ${UDEV_RULES_FLASH}"
        return
    fi

    warn "Could not fetch Wolf udev rules — installing the bundled copy"
    write_bundled_udev_rules "$UDEV_RULES_FLASH"
}

# The plugin's old hand-maintained rules matched device names Wolf no longer
# uses, so leaving them in place would only re-introduce the leak.
remove_legacy_udev_rules() {
    [[ -e "$LEGACY_UDEV_RULES_FLASH" || -e "$LEGACY_UDEV_RULES_LIVE" ]] || return 0
    info "Removing superseded plugin udev rules"
    rm -f "$LEGACY_UDEV_RULES_FLASH" "$LEGACY_UDEV_RULES_LIVE"
}

install_udev_rules() {
    info "Installing udev rules"

    fetch_udev_rules
    remove_legacy_udev_rules

    cp "$UDEV_RULES_FLASH" "$UDEV_RULES_LIVE"
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true

    # /etc is tmpfs on Unraid, so the rules must be restored from the flash
    # drive on every boot. Rewrite the block rather than only appending a
    # missing one, so existing installs pick up the new filename.
    local marker="# GoW udev rules"
    local end_marker="# End GoW udev rules"
    local marker_re="${marker//\//\\/}"
    local end_marker_re="${end_marker//\//\\/}"
    if grep -qF "$marker" "$GO_SCRIPT" 2>/dev/null; then
        info "Updating udev restore in /boot/config/go"
        if grep -qF "$end_marker" "$GO_SCRIPT" 2>/dev/null; then
            sed -i "/${marker_re}/,/${end_marker_re}/d" "$GO_SCRIPT"
        else
            sed -i "/${marker_re}/,/^$/d" "$GO_SCRIPT"
        fi
    else
        info "Adding udev restore to /boot/config/go"
    fi

    # Removing the old block leaves the blank line that separated it behind, so
    # trim trailing blanks before appending — otherwise every deploy grows the
    # file by one empty line.
    # Truncated in place so the go script keeps its permissions.
    if [[ -f "$GO_SCRIPT" ]]; then
        local go_body
        go_body="$(< "$GO_SCRIPT")"
        printf '%s\n' "$go_body" > "$GO_SCRIPT"
    fi

    cat >> "$GO_SCRIPT" <<EOF

${marker}
cp ${UDEV_RULES_FLASH} ${UDEV_RULES_LIVE}
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
${end_marker}
EOF
}

# ── appdata directories ───────────────────────────────────────────────────────

# Wolf Den's entrypoint drops privileges to this uid via gosu. It is fixed by
# the image, not by the app run ids: apps never see these directories, because
# Wolf gives an app container only its own home directory.
WOLF_DEN_UID=1000
WOLF_DEN_GID=1000

setup_appdata_dirs() {
    info "Creating appdata directories at ${APPDATA}"
    mkdir -p \
        "${APPDATA}/cfg" \
        "${APPDATA}/wolf-den" \
        "${APPDATA}/covers" \
        "${APPDATA}/compatibilitytools.d"
    # No steam/ here on purpose. It existed only for a ${APPDATA}/steam:/etc/wolf/steam
    # mount that went away with the identity mount, and nothing has read it since:
    # Wolf keeps Steam's data in the app's own home under the app state root.
    # Existing (empty) ones are left alone rather than deleted.

    # covers/ and compatibilitytools.d/ no longer have mounts of their own —
    # wolf-den reaches them through ${APPDATA}:/etc/wolf, which lands them at the
    # same in-container paths the explicit mounts used to provide. They still
    # have to be writable by the uid wolf-den runs as before it starts.
    #
    # A failing chown must not abort the deploy (some appdata shares sit on
    # filesystems that refuse it) but it must not pass silently either: this used
    # to be `2>/dev/null || true` next to an unguarded chmod, so the failure that
    # actually breaks Wolf Den was the one that got hidden.
    local dir
    for dir in "${APPDATA}/wolf-den" "${APPDATA}/covers" "${APPDATA}/compatibilitytools.d"; do
        chown -R "${WOLF_DEN_UID}:${WOLF_DEN_GID}" "$dir" \
            || warn "Could not give ${dir} to ${WOLF_DEN_UID}:${WOLF_DEN_GID}; Wolf Den may fail to write it"
        chmod 775 "$dir" \
            || warn "Could not set mode 775 on ${dir}; Wolf Den may fail to write it"
    done
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

write_wolf_network_env() {
    if [[ "$WOLF_NETWORK_MODE" == "custom" && -n "$WOLF_NETWORK_IPV4" ]]; then
        cat <<YAML
      - WOLF_INTERNAL_IP=${WOLF_NETWORK_IPV4}
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
    image: ghcr.io/games-on-whales/wolf:stable
    container_name: wolf
    environment:
      - WOLF_RENDER_NODE=${RENDER_NODE}
      - NVIDIA_DRIVER_VOLUME_NAME=nvidia-driver-vol
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=${APPDATA}/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
      - WOLF_DEFAULT_RUN_UID=${WOLF_RUN_UID}
      - WOLF_DEFAULT_RUN_GID=${WOLF_RUN_GID}
      - HOST_APPS_STATE_FOLDER=${APPDATA}
YAML
    # Wolf's zero-copy NVIDIA pipeline fails to negotiate CUDA memory on some
    # newer driver branches (cudaconvertscale "not-negotiated", stream dies a
    # few seconds after connecting). Setting WOLF_USE_ZERO_COPY=FALSE makes Wolf
    # fall back to the legacy pipeline, which trades a little latency for working
    # video. See docs/FAQ.md.
    if [[ "${WOLF_ZERO_COPY,,}" == "false" ]]; then
        echo "      - WOLF_USE_ZERO_COPY=FALSE"
    fi
    write_wolf_network_env
    cat <<YAML
    volumes:
      # Identity mount (host path == container path): Wolf's startup.sh derives
      # WOLF_CFG_FILE and the per-app state folder from HOST_APPS_STATE_FOLDER and
      # bind-mounts that host path into the app containers it spawns. The appdata
      # must be reachable at the same path inside this container, otherwise Wolf
      # writes config/pairing to an unmounted (ephemeral) dir and loses it on restart.
      - ${APPDATA}:${APPDATA}:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - nvidia-driver-vol:/usr/nvidia:rw
      - wolf-socket:/tmp/sockets
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
${nvidia_devices}
    device_cgroup_rules:
      - 'c 13:* rmw'
YAML
    write_wolf_network_service
    cat <<YAML
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    container_name: wolf-den
    environment:
      # Plain filesystem path, NOT a unix:// URL: wolf-den's entrypoint feeds
      # this straight to `socat ... UNIX-CONNECT:${WOLF_SOCKET_PATH}` to build a
      # uid-1000-owned proxy at /app/wolf.sock, then re-exports the unix:// form
      # itself for the .NET client. A unix:// prefix here makes socat treat it as
      # a literal filename, silently (2>/dev/null) fail to create the proxy, and
      # the socket-wait times out forever.
      - WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock
      - WOLF_SOCKET_TIMEOUT=60
      - XDG_DATA_HOME=/app/wolf-den
    volumes:
      - wolf-socket:/tmp/sockets
      - ${APPDATA}:/etc/wolf:rw
      - ${APPDATA}/wolf-den:/app/wolf-den
    ports:
      - "${WOLF_DEN_PORT}:8080"
    depends_on:
      - wolf
    restart: unless-stopped

volumes:
  nvidia-driver-vol:
    external: true
  wolf-socket:
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
    image: ghcr.io/games-on-whales/wolf:stable
    container_name: wolf
    environment:
      - WOLF_RENDER_NODE=${RENDER_NODE}
      - XDG_RUNTIME_DIR=/tmp/sockets
      - WOLF_CFG_FILE=${APPDATA}/cfg/config.toml
      - WOLF_DOCKER_SOCKET=/var/run/docker.sock
      - WOLF_DEFAULT_RUN_UID=${WOLF_RUN_UID}
      - WOLF_DEFAULT_RUN_GID=${WOLF_RUN_GID}
      - HOST_APPS_STATE_FOLDER=${APPDATA}
YAML
    write_wolf_network_env
    cat <<YAML
    volumes:
      # Identity mount (host path == container path): Wolf's startup.sh derives
      # WOLF_CFG_FILE and the per-app state folder from HOST_APPS_STATE_FOLDER and
      # bind-mounts that host path into the app containers it spawns. The appdata
      # must be reachable at the same path inside this container, otherwise Wolf
      # writes config/pairing to an unmounted (ephemeral) dir and loses it on restart.
      - ${APPDATA}:${APPDATA}:rw
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
YAML
    write_wolf_network_service
    cat <<YAML
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    container_name: wolf-den
    environment:
      # Plain filesystem path, NOT a unix:// URL: wolf-den's entrypoint feeds
      # this straight to `socat ... UNIX-CONNECT:${WOLF_SOCKET_PATH}` to build a
      # uid-1000-owned proxy at /app/wolf.sock, then re-exports the unix:// form
      # itself for the .NET client. A unix:// prefix here makes socat treat it as
      # a literal filename, silently (2>/dev/null) fail to create the proxy, and
      # the socket-wait times out forever.
      - WOLF_SOCKET_PATH=/tmp/sockets/wolf.sock
      - WOLF_SOCKET_TIMEOUT=60
      - XDG_DATA_HOME=/app/wolf-den
    volumes:
      - wolf-socket:/tmp/sockets
      - ${APPDATA}:/etc/wolf:rw
      - ${APPDATA}/wolf-den:/app/wolf-den
    ports:
      - "${WOLF_DEN_PORT}:8080"
    depends_on:
      - wolf
    restart: unless-stopped

volumes:
  wolf-socket:
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

NV_VERSION_LABEL="org.games-on-whales.nv_version"

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

info "GoW plugin ${GOW_VERSION}"

validate_network_config

# Stop existing stack on reconfigure
if [[ -f "$COMPOSE_FILE" ]]; then
    info "Stopping existing stack for reconfiguration"
    # down -v drops the non-external wolf-socket volume so it is recreated
    # root-owned. Wolf now runs PulseAudio inside its own container (as root),
    # and the old WolfPulseAudio sidecar left /tmp/sockets owned by the run uid
    # (1000), which makes the embedded PulseAudio refuse to start with
    # "XDG_RUNTIME_DIR is not owned by us". The external nvidia-driver-vol is
    # never removed by down -v. wolf-socket only holds runtime sockets, so
    # recreating it is safe.
    docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null || true
    cleanup_wolf_runtime_containers
fi

install_udev_rules
setup_appdata_dirs
migrate_legacy_etc_wolf
ensure_wolf_uuid
sync_app_state_ownership
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
