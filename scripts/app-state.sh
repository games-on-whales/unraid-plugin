#!/bin/bash
# app-state.sh — keep Wolf's per-app state owned by the uid/gid apps run as.
#
# Sourced by deploy.sh (Install / Apply) and update.sh (Update Images). Both
# entry points need it: a plugin update followed by "Update Images" is the most
# common way users pick up a new run uid, and skipping the migration there left
# apps unable to write their own home directory (issue #66).
#
# Callers must have APPDATA set and provide info()/warn().

# Unraid's nobody:users. Apps write into appdata, which Unraid keeps owned by
# this pair, so it is the default that works without hand-editing shares.
DEFAULT_WOLF_RUN_UID=99
DEFAULT_WOLF_RUN_GID=100

# Wolf stores app state under a folder the client asks for: Wolf UI requests
# "profile-data/<profile>/<app>", while Wolf's own docs use "profile_data".
# Cover both rather than betting on one spelling — the cost of an extra miss is
# a silent no-op migration, which is exactly how #66 stayed broken.
APP_STATE_ROOTS=(profile-data profile_data)

valid_run_id() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65533 ))
}

# Falls back to the Unraid defaults so an older gow.cfg (written before the
# setting existed) keeps the behaviour it was deployed with.
resolve_run_ids() {
    WOLF_RUN_UID="${WOLF_RUN_UID:-$DEFAULT_WOLF_RUN_UID}"
    WOLF_RUN_GID="${WOLF_RUN_GID:-$DEFAULT_WOLF_RUN_GID}"
    valid_run_id "$WOLF_RUN_UID" || return 1
    valid_run_id "$WOLF_RUN_GID" || return 1
}

app_state_stamp() {
    printf '%s/cfg/.run-ids' "$APPDATA"
}

# Existing app state roots, one per line. Empty output means Wolf has not
# launched an app yet, so there is nothing to re-own.
app_state_dirs() {
    local name
    for name in "${APP_STATE_ROOTS[@]}"; do
        [[ -d "${APPDATA}/${name}" ]] && printf '%s\n' "${APPDATA}/${name}"
    done
    return 0
}

# Wolf itself runs as root and creates a client's profile/app directories when
# that client launches an app for the first time. On a fresh install there is
# no tree for migrate_app_state_ownership() to chown before Wolf starts, so the
# first app home used to land as root:root and Steam failed before the next
# Install / Update Images could repair it.
#
# Seed both supported roots and give the configured app uid/gid an inheritable
# ACL. Every directory Wolf creates below them then remains writable by the app
# even though Wolf is its owner. Only the root and the profile/app directory
# levels are touched here; applying this on every sync stays cheap even when an
# app home contains a large Steam library. The normal ownership migration still
# re-owns existing drift and records the stamp.
prepare_app_state_roots() {
    local name state_dir want="${WOLF_RUN_UID}:${WOLF_RUN_GID}"
    local acl="u:${WOLF_RUN_UID}:rwx,g:${WOLF_RUN_GID}:rwx,m::rwx,d:u:${WOLF_RUN_UID}:rwx,d:g:${WOLF_RUN_GID}:rwx,d:m::rwx"
    local have_setfacl=true
    if ! valid_run_id "${WOLF_RUN_UID:-}" || ! valid_run_id "${WOLF_RUN_GID:-}"; then
        warn "Cannot prepare Wolf app state roots: invalid run UID/GID ${WOLF_RUN_UID:-unset}:${WOLF_RUN_GID:-unset}"
        return 1
    fi
    if ! command -v setfacl >/dev/null 2>&1; then
        have_setfacl=false
        warn "setfacl is unavailable; Wolf may create new app homes that ${want} cannot write"
    fi

    for name in "${APP_STATE_ROOTS[@]}"; do
        state_dir="${APPDATA}/${name}"
        if ! mkdir -p "$state_dir"; then
            warn "Could not create Wolf app state root ${state_dir}"
            continue
        fi
        if ! chown "$want" "$state_dir" || ! chmod 2775 "$state_dir"; then
            warn "Could not prepare ${state_dir} for apps running as ${want}"
            continue
        fi
        [[ "$have_setfacl" == true ]] || continue

        # Existing profile/app directories need the same default ACL so a new
        # root-created child (notably udev/) inherits access too: the state root
        # is depth 0, profile/client is 1, and app HOME is 2. The bounded walk
        # never reaches the Steam library below HOME.
        if ! find "$state_dir" -maxdepth 2 -type d \
            -exec setfacl -m "$acl" -- {} +; then
            warn "Could not set inherited app access under ${state_dir}; fresh app homes may be unwritable"
        fi
    done
}

# Ownership is the wrong question. Wolf runs as root and creates the profile,
# app and udev directories; the app images' /etc/cont-init.d scripts also run as
# root and create $HOME/.steam and $HOME/homebrew before dropping to the run uid,
# and Decky owns homebrew/plugins as root on purpose. All of that comes back
# root-owned on every launch, so no host-side chown can hold it — the inheritable
# ACL is what makes those paths writable. access(2) honours that ACL, so ask the
# kernel rather than comparing uids (issue #66: root-owned-but-writable paths
# were reported as breakage forever, and re-triggered a full chown -R over a
# Steam library on every deploy).
#
# Resolved once: "setpriv" when we can drop to the run ids and ask, "ownership"
# when we cannot and must fall back to over-reporting.
app_state_probe_kind() {
    if [[ -z "${APP_STATE_PROBE_KIND:-}" ]]; then
        if [[ $EUID -eq 0 ]] && command -v setpriv >/dev/null 2>&1; then
            APP_STATE_PROBE_KIND=setpriv
        else
            APP_STATE_PROBE_KIND=ownership
        fi
    fi
    printf '%s' "$APP_STATE_PROBE_KIND"
}

# --clear-groups matters: an app container has no supplementary groups, so
# neither may this probe, or it reports access the app will not have.
#
# Run uid 0 falls back deliberately: root bypasses the permission bits, so a
# probe as root answers "writable" for every path and proves nothing. Real
# installs never get here — valid_run_id() rejects 0 and both entry points
# validate before calling — but a probe that silently always passes is the kind
# of check that certifies a broken tree, so refuse it rather than trust it.
run_ids_can_write() {
    local path="$1" owner
    if [[ "$(app_state_probe_kind)" == setpriv && "$WOLF_RUN_UID" -ne 0 ]]; then
        if [[ -d "$path" ]]; then
            setpriv --reuid="$WOLF_RUN_UID" --regid="$WOLF_RUN_GID" --clear-groups \
                test -w "$path" -a -x "$path" 2>/dev/null
        else
            setpriv --reuid="$WOLF_RUN_UID" --regid="$WOLF_RUN_GID" --clear-groups \
                test -w "$path" 2>/dev/null
        fi
        return
    fi
    owner="$(stat -c '%u:%g' "$path" 2>/dev/null)" || return 1
    [[ "$owner" == "${WOLF_RUN_UID}:${WOLF_RUN_GID}" ]]
}

# How deep to look. These trees hold entire Steam libraries, so the walk has to
# be bounded, and a fault shows up near the top because the app's home directory
# is the mount point itself: state root is depth 0, profile 1, app HOME 2, and
# the directories the app image creates as root ($HOME/.steam, $HOME/homebrew)
# are 3, with their children at 4.
#
# The repair and the doctor MUST share this. When they disagreed, diagnose.sh
# reported a path at depth 4 that migrate_app_state_ownership never looked at,
# so "fix: run Install" never cleared the warning it told the user to fix.
APP_STATE_PROBE_DEPTH=4

# Probing forks a process per path, so bound the candidate list. Only paths not
# already owned by the run ids are probed at all, and the first failure ends the
# scan, so this cap is only reached on a tree where everything checked so far is
# fine.
APP_STATE_PROBE_LIMIT=200

# Prints the first path under $1 the run ids cannot write, if any. Ownership is
# only the cheap pre-filter that enumerates candidates — a path already owned by
# the run ids is writable by definition, so nothing else needs a probe.
first_unwritable_path() {
    local path
    while read -r path; do
        [[ -n "$path" ]] || continue
        run_ids_can_write "$path" && continue
        printf '%s\n' "$path"
        return 0
    done < <(find "$1" -maxdepth "$APP_STATE_PROBE_DEPTH" \
                 \( ! -uid "$WOLF_RUN_UID" -o ! -gid "$WOLF_RUN_GID" \) \
                 -print 2>/dev/null | head -n "$APP_STATE_PROBE_LIMIT")
    return 0
}

# One-time deep repair. prepare_app_state_roots only seeds the ACL down to the
# app HOME (depth 2), so directories that already existed when that seeding was
# introduced carry nothing — on a real install those are $HOME/.steam and
# $HOME/homebrew, created as root by the app image long before the plugin knew
# to seed anything. Their children inherit nothing either, so the run uid cannot
# write them however often the shallow refresh runs.
#
# Walking the whole tree costs the same as the chown -R beside it, and both only
# run when the state is actually broken, so a healthy install never pays it.
# Once every existing directory carries the default ACL, everything Wolf and the
# app images create below it inherits access for good.
repair_app_state_acls() {
    local state_dir="$1" access defaults
    command -v setfacl >/dev/null 2>&1 || return 0
    access="u:${WOLF_RUN_UID}:rwX,g:${WOLF_RUN_GID}:rwX,m::rwX"
    defaults="d:u:${WOLF_RUN_UID}:rwx,d:g:${WOLF_RUN_GID}:rwx,d:m::rwx"

    # rwX leaves plain files without a spurious execute bit while still making
    # every directory traversable. Default entries go on directories only.
    # acl 2.3.2 happens to skip files under `-R -d` rather than fail, but that
    # is not what setfacl(1) documents, so select the directories explicitly
    # instead of depending on the version Unraid ships.
    if ! setfacl -R -m "$access" -- "$state_dir"; then
        warn "Could not grant ${WOLF_RUN_UID}:${WOLF_RUN_GID} access under ${state_dir}"
        return 1
    fi
    if ! find "$state_dir" -type d -exec setfacl -m "$defaults" -- {} +; then
        warn "Could not make app access inheritable under ${state_dir}; new app directories may be unwritable"
        return 1
    fi
}

# Wolf bind-mounts <appdata>/<state root>/<profile>/<app> as /home/retro inside
# each app container and runs it as WOLF_RUN_UID:WOLF_RUN_GID. Nothing else
# re-owns what is already there: Wolf only create_directories() the folder, and
# the gow images chown just the top level of $HOME. So state written under a
# previous uid stays unwritable and the app dies during startup (#66).
#
# The stamp keeps the walk off the hot path — these trees hold entire Steam
# libraries — but it is only trusted when the tree agrees with it. A stamp that
# recorded intent rather than reality is how a half-migrated install kept
# looking migrated.
#
# "Agrees with it" now means the run ids can actually write the tree, not that
# they own it. Wolf and the app images recreate directories as root on every
# launch, so an ownership test never settles: it re-triggered the full chown on
# every deploy and still reported the tree as broken afterwards.
migrate_app_state_ownership() {
    local want="${WOLF_RUN_UID}:${WOLF_RUN_GID}"
    local stamp state_dir stamped unwritable clean=true found=false
    stamp="$(app_state_stamp)"
    stamped="$(cat "$stamp" 2>/dev/null || true)"

    while read -r state_dir; do
        [[ -n "$state_dir" ]] || continue
        found=true

        unwritable="$(first_unwritable_path "$state_dir")"
        if [[ "$stamped" == "$want" && -z "$unwritable" ]]; then
            continue
        fi

        info "Repairing Wolf app state under ${state_dir} for ${want} — this may take a while"
        # ACLs first: they are what survives the next launch, when Wolf and the
        # app image recreate their directories as root again. The chown behind
        # them is the fallback for a host without setfacl, and it is transient
        # by nature.
        repair_app_state_acls "$state_dir" || clean=false
        if ! chown -R "$want" "$state_dir"; then
            warn "Could not re-own all of ${state_dir}; apps may fail to write their state"
            clean=false
            continue
        fi

        unwritable="$(first_unwritable_path "$state_dir")"
        if [[ -n "$unwritable" ]]; then
            warn "${want} still cannot write ${unwritable}; apps may fail to write their state"
            clean=false
        fi
    done < <(app_state_dirs)

    # No state on disk yet (fresh install) — nothing to migrate, and stamping
    # now would let a later real migration be skipped.
    [[ "$found" == true ]] || return 0

    if [[ "$clean" == true ]]; then
        printf '%s\n' "$want" > "$stamp"
    else
        rm -f "$stamp"
    fi
}

# WOLF_DEFAULT_RUN_UID/GID only apply to newly paired clients — clients paired
# earlier keep the uid/gid saved in config.toml. Rewrite those so every pairing
# runs as the user migrate_app_state_ownership just made the state folders owned
# by, instead of a stale value that can no longer write them.
normalize_client_run_ids() {
    local cfg_file="${APPDATA}/cfg/config.toml"
    [[ -f "$cfg_file" ]] || return 0
    grep -q 'run_uid\|run_gid' "$cfg_file" || return 0

    info "Aligning saved client run uid/gid with ${WOLF_RUN_UID}:${WOLF_RUN_GID}"
    sed -i -E \
        -e "s/(run_uid[[:space:]]*=[[:space:]]*)[0-9]+/\1${WOLF_RUN_UID}/g" \
        -e "s/(run_gid[[:space:]]*=[[:space:]]*)[0-9]+/\1${WOLF_RUN_GID}/g" \
        "$cfg_file"
}

fake_udev_path() { printf '%s/fake-udev' "$APPDATA"; }

# Wolf copies its fake-udev helper into the state folder on every start and
# bind-mounts it into each app container as /usr/bin/fake-udev, then docker-execs
# it to hot-plug controllers. `cp` keeps the mode of an existing destination, so
# a copy that once landed without +x stays broken forever — the app container
# then logs "Docker exec failed (126) ... /usr/bin/fake-udev: Permission denied"
# and controllers never appear inside the app.
ensure_fake_udev_executable() {
    local helper
    helper="$(fake_udev_path)"
    [[ -f "$helper" ]] || return 0
    [[ -x "$helper" ]] && return 0

    info "Making ${helper} executable so Wolf can hot-plug controllers"
    chmod a+rx "$helper" || warn "Could not make ${helper} executable; controllers may not appear inside apps"
}

# A noexec appdata mount breaks the same thing, and no amount of chmod fixes it.
# Unassigned Devices shares in particular can be mounted this way.
warn_if_appdata_noexec() {
    local opts
    opts="$(findmnt -no OPTIONS --target "$APPDATA" 2>/dev/null || true)"
    [[ ",${opts}," == *",noexec,"* ]] || return 0

    warn "${APPDATA} is on a noexec mount — Wolf's fake-udev helper cannot run, so controllers will not appear inside apps. Move appdata to a share mounted without noexec."
}

# Both entry points do the same things in the same order: point already paired
# clients at the run ids, make the state on disk match them, and keep the helper
# Wolf hands to app containers runnable.
sync_app_state_ownership() {
    normalize_client_run_ids
    prepare_app_state_roots
    migrate_app_state_ownership
    ensure_fake_udev_executable
    warn_if_appdata_noexec
}
