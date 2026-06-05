#!/bin/bash
# vars.sh — shared environment for all GoW plugin scripts

export GOW_NAME="gow"
export GOW_ORG="games-on-whales"
export GOW_PLUGIN="/boot/config/plugins/gow"

# Plugin version, read from the installed .plg so it always matches what is
# actually deployed. Avoids a hardcoded value silently drifting out of sync —
# the same class of staleness that hid an old on-disk deploy.sh from users.
export GOW_VERSION="$(grep -oP '<!ENTITY\s+version\s+"\K[^"]+' "${GOW_PLUGIN}.plg" 2>/dev/null || true)"
[[ -n "$GOW_VERSION" ]] || export GOW_VERSION="unknown"

export GOW_CFG="${GOW_PLUGIN}/gow.cfg"
export GOW_SCRIPT_DIR="${GOW_PLUGIN}/scripts"
export GOW_EMHTTP="/usr/local/emhttp/plugins/gow"
export GOW_PACKAGE_DIR="${GOW_PLUGIN}/packages"
export DEFAULT_APPDATA="/mnt/user/appdata/gow"
