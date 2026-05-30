#!/usr/bin/env bash
# Build settings-ui.txz for local Unraid dev install (run via WSL or Git Bash).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist/settings-ui.txz"

echo "==> Building settings-ui package"
mkdir -p "$ROOT/dist"
cd "$ROOT/packages/settings-ui/root"
"$ROOT/utils/fmakepkg.sh" "$OUT"

if [[ ! -f "$OUT" ]]; then
  echo "ERROR: $OUT was not created" >&2
  exit 1
fi

SIZE="$(wc -c < "$OUT" | tr -d ' ')"
echo "==> OK: $OUT ($SIZE bytes)"
