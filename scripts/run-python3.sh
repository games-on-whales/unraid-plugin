#!/bin/bash
# run-python3.sh — host python3 or Docker fallback for Unraid (no NerdPack required).
#
# Usage:
#   source .../run-python3.sh
#   gow_python3 script.py [args...]
#   gow_python3 - arg [args...]  # stdin = script body (heredoc)
#
# Or invoke directly: bash run-python3.sh script.py [args...]
set -euo pipefail

GOW_PYTHON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

gow_python3_use_host() {
    [[ -z "${GOW_FORCE_DOCKER_PYTHON:-}" ]] \
        && command -v python3 >/dev/null 2>&1
}

gow_python3_add_mount() {
    local -n _mounts=$1
    local -n _seen=$2
    local host_path="$3"
    local mode="${4:-ro}"

    [[ "$host_path" == /* ]] || return 0
    [[ "$_seen" == *"|${host_path}|"* ]] && return 0
    _seen+="|${host_path}|"

    if [[ -f "$host_path" || -d "$host_path" ]]; then
        _mounts+=("-v" "${host_path}:${host_path}:${mode}")
        return 0
    fi

    local parent
    parent="$(dirname "$host_path")"
    if [[ -d "$parent" && "$_seen" != *"|${parent}|"* ]]; then
        _seen+="|${parent}|"
        _mounts+=("-v" "${parent}:${parent}:rw")
    fi
}

gow_python3_build_mounts() {
    local -n _mounts=$1
    shift
    local seen="" arg

    for arg in "$@"; do
        [[ "$arg" == /* ]] || continue
        if [[ "$arg" == *.toml && -f "$arg" ]]; then
            gow_python3_add_mount mounts seen "$arg" rw
        elif [[ -f "$arg" && "$arg" == *.py ]]; then
            gow_python3_add_mount mounts seen "$arg" ro
        elif [[ -d "$arg" ]]; then
            gow_python3_add_mount mounts seen "$arg" ro
        elif [[ -f "$arg" ]]; then
            gow_python3_add_mount mounts seen "$arg" ro
        else
            gow_python3_add_mount mounts seen "$arg" ro
        fi
    done

    if [[ -d "${GOW_PYTHON_DIR}/rom-config" ]]; then
        gow_python3_add_mount mounts seen "${GOW_PYTHON_DIR}/rom-config" ro
        # Also expose at path used inside ES-DE image helpers
        _mounts+=("-v" "${GOW_PYTHON_DIR}/rom-config:/opt/gow/rom-config:ro")
    fi
}

gow_python3_docker() {
    local image="${GOW_PYTHON_IMAGE:-python:3-alpine}"
    local -a mounts=()
    local use_stdin=0

    if ! command -v docker >/dev/null 2>&1; then
        echo "ERROR: python3 not found and Docker is unavailable — library mount presets require Docker on Unraid" >&2
        return 127
    fi

    if ! docker image inspect "$image" >/dev/null 2>&1; then
        docker pull "$image" >/dev/null || {
            echo "ERROR: could not pull ${image} for plugin Python helpers" >&2
            return 1
        }
    fi

    gow_python3_build_mounts mounts "$@"

    if [[ "${1:-}" == "-" ]]; then
        use_stdin=1
    fi

    if (( use_stdin )); then
        docker run --rm -i "${mounts[@]}" "$image" python3 "$@"
    else
        docker run --rm "${mounts[@]}" "$image" python3 "$@"
    fi
}

gow_python3() {
    if gow_python3_use_host; then
        python3 "$@"
    else
        gow_python3_docker "$@"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    gow_python3 "$@"
fi
