#!/bin/bash
# wolf-api.sh — curl helpers for the Wolf REST API (Unix socket).
#
# See: https://games-on-whales.github.io/wolf/stable/dev/api.html
# OpenAPI: curl --unix-socket "$sock" http://localhost/api/v1/openapi-schema

_gow_wolf_api_err() { echo "ERROR: $*" >&2; }

# Resolve the Wolf API Unix socket (host path under appdata).
gow_wolf_socket() {
    local appdata="${1:-${APPDATA:-}}"
    appdata="${appdata%/}"
    [[ -n "$appdata" ]] || return 1

    local sock="${appdata}/run/wolf.sock"
    if [[ -S "$sock" ]]; then
        echo "$sock"
        return 0
    fi
    return 1
}

# True when the Wolf container is running and the API socket is reachable.
gow_wolf_api_ready() {
    local appdata="${1:-${APPDATA:-}}"
    local sock
    sock="$(gow_wolf_socket "$appdata" 2>/dev/null)" || return 1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx wolf || return 1
    curl -sfS --max-time 3 --unix-socket "$sock" \
        "http://localhost/api/v1/openapi-schema" >/dev/null 2>&1
}

# Usage: gow_wolf_api METHOD PATH [JSON_BODY]
gow_wolf_api() {
    local method="${1:-GET}"
    local path="$2"
    local body="${3:-}"
    local appdata="${APPDATA:-}"
    local sock

    sock="$(gow_wolf_socket "$appdata")" || {
        _gow_wolf_api_err "Wolf API socket not found (expected \${APPDATA}/run/wolf.sock)"
        return 1
    }

    local url="http://localhost${path}"
    if [[ "$method" == "GET" ]]; then
        curl -sfS --unix-socket "$sock" "$url"
    else
        curl -sfS --unix-socket "$sock" -X "$method" \
            -H 'Content-Type: application/json' \
            -d "$body" \
            "$url"
    fi
}
