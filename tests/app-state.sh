#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ORIGINAL_PATH="$PATH"
REAL_SETFACL="$(command -v setfacl || true)"

mkdir -p "$TMP/bin" "$TMP/appdata/cfg"
cat > "$TMP/bin/setfacl" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$SETFACL_LOG"
MOCK
chmod +x "$TMP/bin/setfacl"

export PATH="$TMP/bin:$PATH"
export SETFACL_LOG="$TMP/setfacl.log"
APPDATA="$TMP/appdata"
WOLF_RUN_UID="$(id -u)"
WOLF_RUN_GID="$(id -g)"
info() { :; }
warn() { printf 'unexpected warning: %s\n' "$*" >&2; return 1; }

# shellcheck source=../scripts/app-state.sh
source "$ROOT/scripts/app-state.sh"

sync_app_state_ownership

for name in profile-data profile_data; do
    root="$APPDATA/$name"
    [[ -d "$root" ]]
    [[ "$(stat -c '%u:%g' "$root")" == "$WOLF_RUN_UID:$WOLF_RUN_GID" ]]
    [[ "$(stat -c '%a' "$root")" == 2775 ]]
    grep -F -- "d:u:${WOLF_RUN_UID}:rwx" "$SETFACL_LOG" >/dev/null
done

[[ "$(cat "$APPDATA/cfg/.run-ids")" == "$WOLF_RUN_UID:$WOLF_RUN_GID" ]]

# Repeated syncs may refresh ACLs on the root/profile/app levels, but must not
# descend into a potentially huge Steam library.
mkdir -p "$APPDATA/profile-data/user/WolfSteam/steamapps/common/game"
: > "$SETFACL_LOG"
sync_app_state_ownership
grep -F -- "$APPDATA/profile-data/user/WolfSteam" "$SETFACL_LOG" >/dev/null
if grep -F -- "/steamapps" "$SETFACL_LOG" >/dev/null; then
    echo "prepare_app_state_roots walked into the Steam library" >&2
    exit 1
fi

# A shallow root-owned directory created later must invalidate the stamp and be
# repaired without relying on a UID/GID change.
mkdir -p "$APPDATA/profile-data/user/WolfSteam"
if [[ "$(id -u)" == 0 ]]; then
    chown 1:1 "$APPDATA/profile-data/user/WolfSteam"
    migrate_app_state_ownership
    [[ "$(stat -c '%u:%g' "$APPDATA/profile-data/user/WolfSteam")" == "$WOLF_RUN_UID:$WOLF_RUN_GID" ]]
else
    echo "root-only ownership repair test skipped" >&2
fi

# When the host has the same ACL primitives as Unraid, verify the kernel-level
# effect as well as the mocked command contract above.
if [[ "$(id -u)" == 0 && -n "$REAL_SETFACL" ]] && command -v setpriv >/dev/null 2>&1; then
    PATH="$ORIGINAL_PATH"
    APPDATA="$TMP/acl-appdata"
    WOLF_RUN_UID=65532
    WOLF_RUN_GID=65532
    mkdir -p "$APPDATA/cfg"
    prepare_app_state_roots
    mkdir -p "$APPDATA/profile-data/user/WolfSteam"
    setpriv --reuid="$WOLF_RUN_UID" --regid="$WOLF_RUN_GID" --clear-groups \
        test -w "$APPDATA/profile-data/user/WolfSteam"
else
    echo "real ACL writability test skipped (setfacl, setpriv, and root required)" >&2
fi

echo "app-state tests passed"
