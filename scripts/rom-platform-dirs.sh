#!/bin/bash
# rom-platform-dirs.sh — folder names synced with rom-config/rom_platforms.py (bash-only).

# shellcheck disable=SC2034
GOW_ROM_PLATFORM_DIRS=(
    3do amiga amigacd32 arcade atari2600 atari5200 atari7800 atarijaguar atarijaguarcd
    atarilynx atarist dreamcast gb gbc gba gc genesis mastersystem megacd model2 model3
    n64 naomi neogeo nes ngp ngpc n3ds psx psp ps2 saturn segacd snes tg16 tg-cd
    vectrex wii wiiu ws wonderswan wonderswancolor xbox xbox360
)

gow_score_rom_root() {
    local root="${1%/}"
    local score=0 platform

    [[ -d "$root" ]] || { echo 0; return; }

    for platform in "${GOW_ROM_PLATFORM_DIRS[@]}"; do
        [[ -d "${root}/${platform}" ]] && score=$((score + 1))
    done
    echo "$score"
}

gow_best_rom_root() {
    local -a candidates=()
    local candidate best="" best_score=0 score

    for candidate in "$@"; do
        [[ -d "$candidate" ]] || continue
        candidates+=("$candidate")
        local nested="${candidate%/}/roms"
        [[ -d "$nested" ]] && candidates+=("$nested")
    done

    for candidate in "${candidates[@]}"; do
        score=$(gow_score_rom_root "$candidate")
        if (( score > best_score )); then
            best_score=$score
            best="$candidate"
        fi
    done

    if (( best_score > 0 )); then
        echo "$best"
    fi
}
