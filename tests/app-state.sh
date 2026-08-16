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
# Never use 0 as the run id, even when running as root: root bypasses the
# permission bits, so every writability probe would answer yes and the suite
# would certify nothing. Real installs cannot use 0 either — valid_run_id()
# rejects it. As root, pick an unprivileged id we can chown to; otherwise the
# only id we can hand out is our own.
if [[ "$(id -u)" == 0 ]]; then
    WOLF_RUN_UID=65532
    WOLF_RUN_GID=65532
else
    WOLF_RUN_UID="$(id -u)"
    WOLF_RUN_GID="$(id -g)"
fi
info() { :; }
warn() { printf 'unexpected warning: %s\n' "$*" >&2; return 1; }

# Directories the test creates stand in for ones a previous sync already
# repaired. As root, mkdir leaves them owned by 0:0, which is drift the code is
# supposed to react to — so hand them over explicitly when that is not what the
# case under test is about. As an ordinary user they already have the run ids.
own_as_run_ids() {
    [[ "$(id -u)" == 0 ]] || return 0
    chown -R "${WOLF_RUN_UID}:${WOLF_RUN_GID}" "$@"
}

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
own_as_run_ids "$APPDATA/profile-data"
: > "$SETFACL_LOG"
sync_app_state_ownership
grep -F -- "$APPDATA/profile-data/user/WolfSteam" "$SETFACL_LOG" >/dev/null
if grep -F -- "/steamapps" "$SETFACL_LOG" >/dev/null; then
    echo "prepare_app_state_roots walked into the Steam library" >&2
    exit 1
fi

# The deep ACL repair is the expensive half, so it must stay off the hot path:
# a healthy tree with a valid stamp gets the shallow refresh and nothing else.
if grep -F -- '-R -m' "$SETFACL_LOG" >/dev/null; then
    echo "recursive ACL repair ran on a healthy tree" >&2
    exit 1
fi

# ...but a stamp that no longer matches means directories predating the ACL may
# be sitting in the tree unwritable, which only the recursive repair can fix.
printf '1:1\n' > "$APPDATA/cfg/.run-ids"
: > "$SETFACL_LOG"
migrate_app_state_ownership
grep -F -- '-R -m' "$SETFACL_LOG" >/dev/null
grep -F -- "d:u:${WOLF_RUN_UID}:rwx" "$SETFACL_LOG" >/dev/null
[[ "$(cat "$APPDATA/cfg/.run-ids")" == "$WOLF_RUN_UID:$WOLF_RUN_GID" ]]

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
    unset APP_STATE_PROBE_KIND
    mkdir -p "$APPDATA/cfg"
    prepare_app_state_roots
    mkdir -p "$APPDATA/profile-data/user/WolfSteam"
    setpriv --reuid="$WOLF_RUN_UID" --regid="$WOLF_RUN_GID" --clear-groups \
        test -w "$APPDATA/profile-data/user/WolfSteam"

    # Reproduce issue #66 as reported: the app image's root-run init scripts
    # create $HOME/homebrew and $HOME/.steam. Here they predate the ACL seeding,
    # exactly like the trees of users who installed before it existed, so they
    # carry no ACL of their own. Strip group/other access the way a root-created
    # 0700 directory would, and the run uid is locked out.
    deep="$APPDATA/profile-data/user/WolfSteam/homebrew/plugins"
    mkdir -p "$deep" "$APPDATA/profile-data/user/WolfSteam/.steam"
    setfacl -R -b -- "$APPDATA/profile-data/user/WolfSteam/homebrew" \
                     "$APPDATA/profile-data/user/WolfSteam/.steam"
    chmod -R 700 "$APPDATA/profile-data/user/WolfSteam/homebrew" \
                 "$APPDATA/profile-data/user/WolfSteam/.steam"

    # Red before green: without the repair the run uid must genuinely fail here.
    # If this succeeds, the diagnosis behind this fix is wrong — say so loudly
    # rather than letting a green suite certify nothing.
    if run_ids_can_write "$deep"; then
        echo "pre-repair tree is already writable — the #66 reproduction is invalid" >&2
        exit 1
    fi

    sync_app_state_ownership
    run_ids_can_write "$deep"
    run_ids_can_write "$APPDATA/profile-data/user/WolfSteam/.steam"

    # The next app launch recreates directories as root all over again — Wolf's
    # udev/ folder at depth 3, Decky's plugin dirs deeper down. That is normal,
    # and inheritance, not another sync, is what has to keep them writable.
    fresh="$APPDATA/profile-data/user/WolfSteam/udev"
    mkdir "$fresh" "$deep/decky-recreated"
    [[ "$(stat -c '%u' "$fresh")" == 0 ]]
    run_ids_can_write "$fresh"
    run_ids_can_write "$deep/decky-recreated"

    # ...and a root-owned path that inheritance has made writable must stop being
    # reported as breakage, which is what the user kept seeing after every fix.
    [[ -z "$(first_unwritable_path "$APPDATA/profile-data")" ]]

    # $HOME/homebrew/plugins sits at APP_STATE_PROBE_DEPTH. diagnose.sh named it
    # in the user's report, so the repair has to scan that far too — when the two
    # used different depths, "fix: run Install" could not clear the warning it
    # told the user to run Install for.
    chown 0:0 "$deep"
    setfacl -b -- "$deep"
    chmod 700 "$deep"
    [[ "$(first_unwritable_path "$APPDATA/profile-data")" == "$deep" ]]
else
    echo "real ACL writability test skipped (setfacl, setpriv, and root required)" >&2
fi

echo "app-state tests passed"
