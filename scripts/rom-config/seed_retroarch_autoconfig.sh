#!/bin/bash
# seed_retroarch_autoconfig.sh — libretro autoconfig DB + Wolf virtual pad profiles
set -euo pipefail

RA_DIR="${1:-/ra}"
BUNDLED="${2:-/bundled-autoconfig}"

mkdir -p "${RA_DIR}/autoconfig/udev"

cfg_count=$(find "${RA_DIR}/autoconfig/udev" -maxdepth 1 -name '*.cfg' 2>/dev/null | wc -l | tr -d ' ')
if (( cfg_count < 100 )); then
    apt-get update -qq
    apt-get install -y --no-install-recommends wget p7zip-full ca-certificates
    wget -q -O /tmp/autoconfig.zip https://buildbot.libretro.com/assets/frontend/autoconfig.zip
    7z x /tmp/autoconfig.zip -o"${RA_DIR}/autoconfig" -bso0 -bse0 -bsp0
    rm -f /tmp/autoconfig.zip
fi

if [[ -d "${BUNDLED}/udev" ]]; then
    cp -f "${BUNDLED}/udev/"*.cfg "${RA_DIR}/autoconfig/udev/" 2>/dev/null || true
fi

echo "RetroArch autoconfig profiles: $(find "${RA_DIR}/autoconfig/udev" -name '*.cfg' | wc -l | tr -d ' ')"
