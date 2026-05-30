#!/bin/bash
# diagnose-steam-lutris-launch.sh — backward-compatible wrapper for diagnose-mounts.sh

set -euo pipefail
exec "$(dirname "$0")/diagnose-mounts.sh" "$@"
