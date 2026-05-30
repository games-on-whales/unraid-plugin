#!/bin/bash
# library-links.sh — keep Wolf library mounts under ${APPDATA} via symlinks when needed.
#
# gow.cfg stores the user's chosen paths. Wolf and docker-compose always use stable
# paths inside the GoW appdata tree (${APPDATA}/roms, …/lutris, etc.). When the
# user's path differs, we ln -sfn it into the appdata slot.

_gow_warn() { echo "WARN:  $*" >&2; }

gow_norm_path() {
    local p="${1%/}"
    [[ -n "$p" ]] || return 0
    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$p" 2>/dev/null || echo "$p"
        return
    fi
    if readlink -f "$p" >/dev/null 2>&1; then
        readlink -f "$p"
        return
    fi
    echo "$p"
}

# Print canonical mount path for a slot (empty if library unset).
gow_library_slot_path() {
    local appdata="${1%/}"
    local slot="$2"
    echo "${appdata}/${slot}"
}

# Ensure ${APPDATA}/<slot> exists and points at the configured user path when necessary.
# Prints the canonical path on success; returns 1 if the library is unset.
gow_ensure_library_link() {
    local appdata="${1%/}"
    local slot="$2"
    local user_path="${3:-}"
    local canonical="${appdata}/${slot}"

    user_path="${user_path%/}"
    if [[ -z "$user_path" ]]; then
        if [[ -L "$canonical" ]]; then
            rm -f "$canonical"
        fi
        return 1
    fi

    local user_norm canonical_norm
    user_norm="$(gow_norm_path "$user_path")"
    canonical_norm="$(gow_norm_path "$canonical")"

    if [[ "$user_norm" == "$canonical_norm" ]]; then
        mkdir -p "$canonical"
        echo "$canonical"
        return 0
    fi

    # User data lives elsewhere — expose it under appdata for Wolf.
    mkdir -p "$(dirname "$canonical")"

    if [[ -e "$canonical" && ! -L "$canonical" ]]; then
        if [[ -n "$(ls -A "$canonical" 2>/dev/null)" ]]; then
            _gow_warn "Keeping non-empty ${canonical} (not symlinking to ${user_norm})"
            echo "$canonical"
            return 0
        fi
        rm -rf "$canonical"
    elif [[ -L "$canonical" ]]; then
        rm -f "$canonical"
    fi

    ln -sfn "$user_norm" "$canonical"
    echo "$canonical"
    return 0
}

# Sync all library slots from a sourced gow.cfg. Emits lines: SLOT=canonical_path
gow_sync_library_links() {
    local appdata="${1%/}"
    local steam games roms bios media lutris compat

    steam="$(gow_ensure_library_link "$appdata" steam "${STEAM_LIBRARY:-}" || true)"
    games="$(gow_ensure_library_link "$appdata" games "${GAMES_LIBRARY:-}" || true)"
    roms="$(gow_ensure_library_link "$appdata" roms "${ROMS_LIBRARY:-}" || true)"
    bios="$(gow_ensure_library_link "$appdata" bioses "${BIOS_LIBRARY:-}" || true)"
    media="$(gow_ensure_library_link "$appdata" media "${MEDIA_LIBRARY:-}" || true)"
    lutris="$(gow_ensure_library_link "$appdata" lutris "${LUTRIS_LIBRARY:-}" || true)"
    compat="$(gow_ensure_library_link "$appdata" compatibilitytools.d "${COMPAT_TOOLS_PATH:-}" || true)"

    [[ -n "$steam" ]] && echo "STEAM_LIBRARY=${steam}"
    [[ -n "$games" ]] && echo "GAMES_LIBRARY=${games}"
    [[ -n "$roms" ]] && echo "ROMS_LIBRARY=${roms}"
    [[ -n "$bios" ]] && echo "BIOS_LIBRARY=${bios}"
    [[ -n "$media" ]] && echo "MEDIA_LIBRARY=${media}"
    [[ -n "$lutris" ]] && echo "LUTRIS_LIBRARY=${lutris}"
    [[ -n "$compat" ]] && echo "COMPAT_TOOLS_PATH=${compat}"
}

# Resolve paths for mount presets / compose (same order as apply-mount-presets.py args).
gow_resolve_library_mounts() {
    local appdata="${1%/}"
    ROMS_LIBRARY=""
    BIOS_LIBRARY=""
    MEDIA_LIBRARY=""
    STEAM_LIBRARY=""
    GAMES_LIBRARY=""
    LUTRIS_LIBRARY=""
    COMPAT_TOOLS_PATH=""

    while IFS='=' read -r key value; do
        case "$key" in
            ROMS_LIBRARY) ROMS_LIBRARY="$value" ;;
            BIOS_LIBRARY) BIOS_LIBRARY="$value" ;;
            MEDIA_LIBRARY) MEDIA_LIBRARY="$value" ;;
            STEAM_LIBRARY) STEAM_LIBRARY="$value" ;;
            GAMES_LIBRARY) GAMES_LIBRARY="$value" ;;
            LUTRIS_LIBRARY) LUTRIS_LIBRARY="$value" ;;
            COMPAT_TOOLS_PATH) COMPAT_TOOLS_PATH="$value" ;;
        esac
    done < <(gow_sync_library_links "$appdata")
}
