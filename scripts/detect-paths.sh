#!/bin/bash
# detect-paths.sh — suggest library paths from existing Unraid shares/folders.
#
# Prints KEY=value lines suitable for merging into gow.cfg. Only emits a key when
# the discovered directory already exists on disk.

set -euo pipefail

# shellcheck source=rom-platform-dirs.sh
source "$(dirname "$0")/rom-platform-dirs.sh"

first_dir() {
    local dir
    for dir in "$@"; do
        [[ -d "$dir" ]] || continue
        echo "$dir"
        return 0
    done
    return 1
}

emit_if_dir() {
    local key="$1"
    shift
    local found
    found=$(first_dir "$@" || true)
    [[ -n "$found" ]] && echo "${key}=${found}"
}

emit_roms_library() {
    local best
    best=$(gow_best_rom_root \
        /mnt/user/games/roms \
        /mnt/user/roms \
        /mnt/user/ROMs \
        /mnt/user/retrogaming/roms \
        /mnt/cache/games/roms \
        /mnt/cache/roms \
        /mnt/cache/ROMs \
        || true)
    if [[ -n "$best" ]]; then
        echo "ROMS_LIBRARY=${best}"
        return
    fi
    emit_if_dir ROMS_LIBRARY \
        /mnt/user/games/roms \
        /mnt/user/roms \
        /mnt/user/ROMs \
        /mnt/user/retrogaming/roms \
        /mnt/cache/games/roms \
        /mnt/cache/roms \
        /mnt/cache/ROMs
}

emit_if_dir APPDATA \
    /mnt/user/appdata/gow \
    /mnt/cache/appdata/gow

emit_roms_library

emit_if_dir BIOS_LIBRARY \
    /mnt/user/games/bioses \
    /mnt/user/roms/bioses \
    /mnt/user/bioses \
    /mnt/user/bios \
    /mnt/user/retrogaming/bios \
    /mnt/cache/games/bioses \
    /mnt/cache/bioses

emit_if_dir STEAM_LIBRARY \
    /mnt/user/games/steam \
    /mnt/user/steam \
    /mnt/cache/steam

emit_if_dir GAMES_LIBRARY \
    /mnt/user/games \
    /mnt/user/Games \
    /mnt/cache/games

emit_if_dir MEDIA_LIBRARY \
    /mnt/user/games/media \
    /mnt/user/media \
    /mnt/user/Media \
    /mnt/cache/games/media

emit_if_dir LUTRIS_LIBRARY \
    /mnt/user/games/lutris \
    /mnt/user/appdata/gow/lutris \
    /mnt/user/appdata/lutris \
    /mnt/cache/appdata/gow/lutris

emit_if_dir PRISM_LIBRARY \
    /mnt/user/games/prismlauncher \
    /mnt/user/appdata/gow/prismlauncher \
    /mnt/cache/games/prismlauncher \
    /mnt/cache/appdata/gow/prismlauncher

emit_if_dir COMPAT_TOOLS_PATH \
    /mnt/user/appdata/gow/compatibilitytools.d \
    /mnt/cache/appdata/gow/compatibilitytools.d

exit 0
