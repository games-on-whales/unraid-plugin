#!/bin/bash
# pairing-state.sh — backup and restore Wolf Moonlight pairing identity
#
# Moonlight pairing survives container recreation only when these files persist
# on the host under ${APPDATA}/cfg/:
#   - config.toml  (uuid + [[paired_clients]])
#   - key.pem / cert.pem (server TLS identity used during pairing)
#
# Source this from deploy.sh and update.sh; do not execute directly.

pairing_cfg_dir() {
    echo "${APPDATA}/cfg"
}

pairing_backup_dir() {
    echo "${APPDATA}/.pairing-backup"
}

pairing_files() {
    echo "config.toml key.pem cert.pem"
}

backup_pairing_state() {
    local cfg_dir backup_dir file
    cfg_dir="$(pairing_cfg_dir)"
    backup_dir="$(pairing_backup_dir)"
    mkdir -p "$backup_dir"

    for file in $(pairing_files); do
        if [[ -f "${cfg_dir}/${file}" ]]; then
            cp -a "${cfg_dir}/${file}" "${backup_dir}/${file}"
        fi
    done
}

restore_pairing_state() {
    local cfg_dir backup_dir file restored=0
    cfg_dir="$(pairing_cfg_dir)"
    backup_dir="$(pairing_backup_dir)"
    [[ -d "$backup_dir" ]] || return 0

    mkdir -p "$cfg_dir"
    for file in $(pairing_files); do
        if [[ ! -f "${cfg_dir}/${file}" && -f "${backup_dir}/${file}" ]]; then
            cp -a "${backup_dir}/${file}" "${cfg_dir}/${file}"
            info "Restored Wolf pairing file: ${file}"
            restored=1
        fi
    done
    return "$restored"
}

count_paired_clients() {
    local cfg_file="${1:-$(pairing_cfg_dir)/config.toml}"
    if [[ ! -f "$cfg_file" ]]; then
        echo 0
        return
    fi
    # grep -c prints 0 with exit 1 when there are no matches — do not append "|| echo 0"
    grep -c '^\[\[paired_clients\]\]' "$cfg_file" 2>/dev/null || true
}

pairing_state_summary() {
    local cfg_dir backup_dir cfg_file paired
    cfg_dir="$(pairing_cfg_dir)"
    backup_dir="$(pairing_backup_dir)"
    cfg_file="${cfg_dir}/config.toml"
    paired="$(count_paired_clients "$cfg_file")"

    if [[ -f "${cfg_dir}/key.pem" && -f "${cfg_dir}/cert.pem" && -f "$cfg_file" ]]; then
        echo "ok:${paired}"
    elif [[ -f "${backup_dir}/key.pem" && -f "${backup_dir}/cert.pem" && -f "${backup_dir}/config.toml" ]]; then
        echo "backup:${paired}"
    else
        echo "missing:0"
    fi
}

ensure_wolf_uuid() {
    local cfg_file="${APPDATA}/cfg/config.toml"
    [[ -f "$cfg_file" ]] || return 0
    if grep -qE '^[[:space:]]*uuid[[:space:]]*=' "$cfg_file"; then
        return 0
    fi

    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) \
        || uuid=$(printf '%s' "$(date +%s%N)$(hostname)" | md5sum | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\).*/\1-\2-\3-\4-\5/')

    info "Adding missing Wolf host uuid to config.toml"
    if grep -qE '^[[:space:]]*hostname[[:space:]]*=' "$cfg_file"; then
        sed -i "/^[[:space:]]*hostname[[:space:]]*=/a uuid = \"${uuid}\"" "$cfg_file"
    else
        sed -i "1i uuid = \"${uuid}\"" "$cfg_file"
    fi
}

prepare_pairing_state() {
    restore_pairing_state
    ensure_wolf_uuid
    chmod 755 "$(pairing_cfg_dir)" 2>/dev/null || true
}

verify_pairing_state() {
    local cfg_dir backup_dir summary paired
    cfg_dir="$(pairing_cfg_dir)"
    backup_dir="$(pairing_backup_dir)"
    summary="$(pairing_state_summary)"
    paired="${summary#*:}"
    paired="${paired//[$'\r\n ']/}"
    paired="${paired:-0}"

    case "${summary%%:*}" in
        ok)
            if (( paired > 0 )); then
                info "Moonlight pairing preserved (${paired} client(s) in config.toml)"
            else
                info "Wolf pairing identity ready (no clients paired yet)"
            fi
            ;;
        backup)
            warn "Wolf pairing files were missing; restored from ${backup_dir}"
            if (( paired > 0 )); then
                info "Restored ${paired} paired Moonlight client(s)"
            fi
            ;;
        missing)
            warn "Wolf pairing identity not found under ${cfg_dir}"
            warn "Moonlight clients will need to pair again after this deploy/update"
            ;;
    esac
}

write_wolf_pairing_env() {
    cat <<'YAML'
      - HOST_APPS_STATE_FOLDER=/etc/wolf
      - WOLF_CFG_FOLDER=/etc/wolf/cfg
      - WOLF_PRIVATE_KEY_FILE=/etc/wolf/cfg/key.pem
      - WOLF_PRIVATE_CERT_FILE=/etc/wolf/cfg/cert.pem
YAML
}
