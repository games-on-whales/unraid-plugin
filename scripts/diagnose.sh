#!/bin/bash
# diagnose.sh — read-only report of everything needed to triage "the app
# container starts but the app never appears" (issue #66) and controller
# problems (issue #57).
#
# Changes nothing. Safe to run while streaming. Paste the output into an issue.

source "$(dirname "$0")/vars.sh"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*"; }
warn() { echo "$*"; }

source "$(dirname "$0")/app-state.sh"

section() { printf '\n== %s ==\n' "$1"; }
ok()      { printf '  ok    %s\n' "$1"; }
bad()     { printf '  BAD   %s\n' "$1"; }
note()    { printf '        %s\n' "$1"; }

[[ -f "$GOW_CFG" ]] || err "Config not found at ${GOW_CFG} — the plugin is not set up yet"
source "$GOW_CFG"

APPDATA="${APPDATA:-${DEFAULT_APPDATA}}"
resolve_run_ids || err "App run UID/GID in ${GOW_CFG} is not a valid number pair"
WANT="${WOLF_RUN_UID}:${WOLF_RUN_GID}"

section "Plugin"
note "version:  ${GOW_VERSION}"
note "appdata:  ${APPDATA}"
note "run ids:  ${WANT} (uid:gid apps run as)"
note "compose:  ${APPDATA}/docker-compose.yml"
[[ -f "${APPDATA}/docker-compose.yml" ]] && ok "compose file present" || bad "no compose file — Wolf was never deployed"

section "Containers"
for name in wolf wolf-den; do
    status="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo 'not found')"
    [[ "$status" == running ]] && ok "${name}: ${status}" || bad "${name}: ${status}"
done
# Wolf names the app containers it spawns after the app (WolfSteam_<lobby>, …).
app_containers="$(docker ps --format '{{.Names}}' --filter 'name=Wolf' 2>/dev/null | grep -v '^wolf' || true)"
if [[ -n "$app_containers" ]]; then
    note "app containers running:"
    while read -r c; do
        [[ -n "$c" ]] || continue
        puid="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null \
                | grep '^PUID=' | cut -d= -f2)"
        note "  ${c} runs as uid ${puid:-unknown}"
    done <<< "$app_containers"
else
    note "no app containers running"
fi

section "Saved client run ids (cfg/config.toml)"
cfg_toml="${APPDATA}/cfg/config.toml"
if [[ -f "$cfg_toml" ]]; then
    saved="$(grep -oE 'run_uid[[:space:]]*=[[:space:]]*[0-9]+' "$cfg_toml" | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ')"
    if [[ -z "$saved" ]]; then
        note "no paired clients with a saved run_uid yet"
    elif [[ "$saved" == "${WOLF_RUN_UID} " ]]; then
        ok "all paired clients run as ${WOLF_RUN_UID}"
    else
        bad "paired clients run as: ${saved}— expected ${WOLF_RUN_UID}"
        note "apps will run as that uid, not ${WOLF_RUN_UID}; re-deploy to realign"
    fi
else
    bad "no config.toml at ${cfg_toml}"
fi

section "App state access"
stamp="$(app_state_stamp)"
note "stamp:    $(cat "$stamp" 2>/dev/null || echo '(none)')"
# Root ownership inside the app state tree is normal: Wolf creates the profile
# and app directories as root, and the app images create $HOME/.steam and
# $HOME/homebrew from root-run init scripts. What matters for app-user state is
# whether the run ids can write it, which the inherited ACL decides. Root-only
# service state (Wolf's udev data and Decky's service/plugin directories) is
# excluded because the unprivileged app neither owns nor writes it.
if [[ "$(app_state_probe_kind)" == ownership ]]; then
    note "check:    ownership only — setpriv is unavailable or this is not running"
    note "          as root, so root-owned paths an ACL makes writable are over-reported"
else
    note "check:    real write access as ${WANT} (honours inherited ACLs)"
fi

# One line of ACL context per bad path: the run uid's entry and the mask are
# what explain a path that looks permissive but is not (a chmod clips the mask
# and with it every named entry).
acl_summary() {
    command -v getfacl >/dev/null 2>&1 || return 0
    getfacl -p --omit-header -- "$1" 2>/dev/null \
        | grep -E "^(user:${WOLF_RUN_UID}:|mask::)" | tr '\n' ' '
}

found=false
while read -r dir; do
    [[ -n "$dir" ]] || continue
    found=true
    unwritable=""
    inherited=0
    while read -r path; do
        [[ -n "$path" ]] || continue
        app_state_path_is_service_managed "$dir" "$path" && continue
        if run_ids_can_write "$path"; then
            inherited=$((inherited + 1))
            continue
        fi
        unwritable+="${path}"$'\n'
    done < <(app_state_probe_candidates "$dir")

    if [[ -z "$unwritable" ]]; then
        ok "${WANT} can write everything under ${dir}"
        (( inherited > 0 )) && note "${inherited} path(s) are root-owned by design; the inherited ACL keeps them writable"
    else
        # Say what was actually established. The fallback only compared uids, so
        # claiming the app cannot write these paths would be asserting more than
        # was checked.
        if [[ "$(app_state_probe_kind)" == ownership ]]; then
            bad "these paths under ${dir} are not owned by ${WANT}:"
        else
            bad "${WANT} cannot write these paths under ${dir}:"
        fi
        while read -r path; do
            [[ -n "$path" ]] || continue
            note "  $(stat -c '%U:%G %a' "$path" 2>/dev/null) ${path}"
            acl="$(acl_summary "$path")"
            [[ -n "$acl" ]] && note "      acl: ${acl}"
        done < <(printf '%s' "$unwritable" | head -5)
        note "apps cannot write their own home directory — this stops Steam at startup"
        note "fix: Settings > Games on Whales > Install (or Update Images)"
    fi
done < <(app_state_dirs)
[[ "$found" == true ]] || note "no app state on disk yet (no app has been launched)"

section "Controller hot-plug (fake-udev)"
helper="$(fake_udev_path)"
if [[ ! -f "$helper" ]]; then
    note "${helper} not present yet (Wolf writes it on start)"
elif [[ -x "$helper" ]]; then
    ok "${helper} is executable"
else
    bad "${helper} is not executable (mode $(stat -c '%a' "$helper" 2>/dev/null))"
    note "Wolf's docker exec fails with 126 Permission denied and controllers never appear"
fi

mount_opts="$(findmnt -no OPTIONS --target "$APPDATA" 2>/dev/null || true)"
note "appdata mount options: ${mount_opts:-unknown}"
if [[ ",${mount_opts}," == *",noexec,"* ]]; then
    bad "appdata is mounted noexec — fake-udev can never run from there"
fi

section "udev rules"
live="/etc/udev/rules.d/85-wolf.rules"
if [[ -f "$live" ]]; then
    ok "${live} installed"
    grep -q 'Wolf \*virtual\*' "$live" \
        && ok "rules use the current Wolf device match" \
        || bad "rules predate wolf#455 and will not match Wolf's device names"
else
    bad "${live} missing — re-deploy to install it"
fi

section "Wolf runtime socket volume"
# Compose prefixes the volume with the project name (the appdata dir), so match
# on the suffix rather than assuming a bare "wolf-socket".
sock_vol="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '(^|_)wolf-socket$' | head -1)"
sock_path="$(docker volume inspect -f '{{.Mountpoint}}' "$sock_vol" 2>/dev/null || true)"
sock_owner=""
[[ -n "$sock_path" && -d "$sock_path" ]] && sock_owner="$(stat -c '%u:%g' "$sock_path")"
if [[ -z "$sock_owner" ]]; then
    note "could not inspect the wolf-socket volume (is Docker running?)"
elif [[ "$sock_owner" == "0:0" ]]; then
    ok "wolf-socket is root-owned, as the embedded PulseAudio requires"
else
    bad "wolf-socket is owned by ${sock_owner}"
    note "an app container chowned it; PulseAudio refuses to start with"
    note "\"XDG_RUNTIME_DIR is not owned by us\" until the stack is re-deployed"
fi

section "Wayland socket wait (Test ball)"
# Read the live container, not the compose file: a stack deployed before this
# setting existed keeps running with the old environment until it is recreated.
wolf_env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' wolf 2>/dev/null || true)"
if [[ -z "$wolf_env" ]]; then
    note "wolf container not running — could not check WOLF_SKIP_WAYLAND_SOCKET_WAIT"
elif grep -qi '^WOLF_SKIP_WAYLAND_SOCKET_WAIT=\(TRUE\|1\)$' <<< "$wolf_env"; then
    ok "WOLF_SKIP_WAYLAND_SOCKET_WAIT is set"
else
    bad "WOLF_SKIP_WAYLAND_SOCKET_WAIT is not set on the running wolf container"
    note "apps without their own compositor (Wolf's \"Test ball\") abort with"
    note "\"Wayland endpoint /tmp/sockets/ exists but is not a socket\";"
    note "run Update Images, or Install, to recreate the stack with it"
fi

printf '\nDone. Nothing was modified.\n'
exit 0
