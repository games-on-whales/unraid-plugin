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

section "App state ownership"
stamp="$(app_state_stamp)"
note "stamp:    $(cat "$stamp" 2>/dev/null || echo '(none)')"
found=false
while read -r dir; do
    [[ -n "$dir" ]] || continue
    found=true
    foreign="$(find "$dir" -maxdepth 4 \( ! -uid "$WOLF_RUN_UID" -o ! -gid "$WOLF_RUN_GID" \) \
                 -printf '%u:%g %p\n' 2>/dev/null | head -5)"
    if [[ -z "$foreign" ]]; then
        ok "${dir} is owned by ${WANT}"
    else
        bad "${dir} has paths not owned by ${WANT}:"
        while read -r line; do note "  ${line}"; done <<< "$foreign"
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

printf '\nDone. Nothing was modified.\n'
exit 0
