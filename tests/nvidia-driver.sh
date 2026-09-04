#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"

cat > "$TMP/bin/nvidia-smi" <<'MOCK'
#!/bin/bash
printf '%s\n' "$HOST_DRIVER"
MOCK

cat > "$TMP/bin/curl" <<'MOCK'
#!/bin/bash
printf 'FROM scratch\n'
MOCK

cat > "$TMP/bin/docker" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$DOCKER_LOG"

if [[ "$1 $2" == "volume inspect" ]]; then
    [[ " $* " == *" --format "* ]] && printf '%s\n' "$VOLUME_DRIVER"
    exit 0
fi

case "$1 $2" in
    "ps -aq")
        exit 0
        ;;
    "volume rm"|"volume create")
        exit 0
        ;;
esac

case "$1" in
    build)
        while IFS= read -r _; do :; done
        ;;
    create)
        printf 'helper-container\n'
        ;;
    rm)
        ;;
    *)
        printf 'unexpected docker command: %s\n' "$*" >&2
        exit 1
        ;;
esac
MOCK

chmod +x "$TMP/bin/nvidia-smi" "$TMP/bin/curl" "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"
export DOCKER_LOG="$TMP/docker.log"
export HOST_DRIVER="610.43.03"
export VOLUME_DRIVER="580.159.03"

err() { printf 'unexpected error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >> "$TMP/info.log"; }

# shellcheck source=../scripts/nvidia-driver.sh
source "$ROOT/scripts/nvidia-driver.sh"

build_nvidia_volume
grep -Fx 'volume rm nvidia-driver-vol' "$DOCKER_LOG" >/dev/null
grep -F 'build -t gow/nvidia-driver:latest' "$DOCKER_LOG" >/dev/null
grep -Fx "volume create --label ${NV_VERSION_LABEL}=${HOST_DRIVER} nvidia-driver-vol" "$DOCKER_LOG" >/dev/null
grep -Fx 'rm helper-container' "$DOCKER_LOG" >/dev/null

# A matching volume stays on the fast path and performs no build or removal.
: > "$DOCKER_LOG"
: > "$TMP/info.log"
export VOLUME_DRIVER="$HOST_DRIVER"
build_nvidia_volume
if grep -Eq '^(volume rm|build )' "$DOCKER_LOG"; then
    echo "matching NVIDIA volume was rebuilt" >&2
    exit 1
fi
grep -Fx "NVIDIA driver volume already built for ${HOST_DRIVER} — skipping build" "$TMP/info.log" >/dev/null

echo "nvidia-driver tests passed"
