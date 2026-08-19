#!/bin/bash
# udev-rules.sh — install Wolf's udev rules for its virtual input devices.
#
# Sourced by deploy.sh (Install / Apply) and update.sh (Update Images). Both
# entry points need it for the same reason app-state.sh does: the rules have to
# track the Wolf image, and "Update Images" is how most users pick up a new
# one. Refreshing only from Install left a newer Wolf running against rules
# fetched for an older one — which is how the gamepad leak came back for the
# reporter of issue #57 ("after re-pulling the images today the issue seems to
# have resurfaced").
#
# Callers must provide info() and warn().

# Wolf owns the udev rules for its virtual input devices. They are installed
# under the upstream filename so Wolf's own scripts/wolf-input-diag.sh finds
# them. The plugin used to carry its own copy, which went stale as Wolf renamed
# devices and let controller input leak onto other seats and containers
# (games-on-whales/wolf#455).
UDEV_RULES_URL="https://raw.githubusercontent.com/games-on-whales/wolf/stable/85-wolf.rules"
UDEV_RULES_FLASH="/boot/config/gow-85-wolf.rules"
UDEV_RULES_LIVE="/etc/udev/rules.d/85-wolf.rules"
LEGACY_UDEV_RULES_FLASH="/boot/config/gow-virtual-inputs.rules"
LEGACY_UDEV_RULES_LIVE="/etc/udev/rules.d/85-gow-virtual-inputs.rules"

# deploy.sh sets this for its auto-start block too; default it so update.sh and
# any other caller get the same path without having to know about it.
GO_SCRIPT="${GO_SCRIPT:-/boot/config/go}"

# Guards against installing a captive-portal page, a GitHub error page, or a
# truncated download as udev rules. The uinput rule is the one Wolf cannot run
# without, so its presence is a reliable marker for "this really is the file".
udev_rules_valid() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    grep -q 'KERNEL=="uinput"' "$file"
}

# Snapshot of games-on-whales/wolf@stable:85-wolf.rules, used only when the host
# cannot reach GitHub. Refresh it when upstream changes the rules.
write_bundled_udev_rules() {
    cat > "$1" <<'UDEV'
# Allows Wolf to access /dev/uinput (needed to create the virtual gamepad)
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"

# Allows Wolf to access /dev/uhid (needed for DualSense emulation)
KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"

# Wolf virtual controllers: the gamepads (Xbox / DualSense / Nintendo), the
# DualSense's "Touchpad" and "Motion Sensors" child input devices, and the
# DualSense /dev/hidraw* node. Matching the "Wolf *virtual*" name glob covers
# every device Wolf creates without going stale on a rename; parking them on
# the phantom seat9 and stripping the uaccess ACL keeps them off every other
# seat. See https://github.com/games-on-whales/wolf/issues/451
SUBSYSTEM=="input",  ATTR{name}=="Wolf *virtual*",  MODE="0660", GROUP="input", ENV{ID_SEAT}="seat9", TAG-="uaccess"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf *virtual*", MODE="0660", GROUP="input", ENV{ID_SEAT}="seat9", TAG-="uaccess"
KERNEL=="hidraw*",   ATTRS{name}=="Wolf *virtual*", MODE="0660", GROUP="input", ENV{ID_SEAT}="seat9", TAG-="uaccess"
UDEV
}

# Prefers the rules Wolf publishes so they stay in sync as Wolf's device names
# evolve, and falls back to the rules already on the flash drive, then to the
# bundled snapshot, when the host is offline.
fetch_udev_rules() {
    local tmp
    tmp="$(mktemp)"
    if curl -fsSL --connect-timeout 10 --max-time 30 "$UDEV_RULES_URL" -o "$tmp" \
        && udev_rules_valid "$tmp"; then
        info "Fetched Wolf udev rules from ${UDEV_RULES_URL}"
        cat "$tmp" > "$UDEV_RULES_FLASH"
        rm -f "$tmp"
        return
    fi
    rm -f "$tmp"

    if udev_rules_valid "$UDEV_RULES_FLASH"; then
        warn "Could not fetch Wolf udev rules — keeping the copy at ${UDEV_RULES_FLASH}"
        return
    fi

    warn "Could not fetch Wolf udev rules — installing the bundled copy"
    write_bundled_udev_rules "$UDEV_RULES_FLASH"
}

# The plugin's old hand-maintained rules matched device names Wolf no longer
# uses, so leaving them in place would only re-introduce the leak.
remove_legacy_udev_rules() {
    [[ -e "$LEGACY_UDEV_RULES_FLASH" || -e "$LEGACY_UDEV_RULES_LIVE" ]] || return 0
    info "Removing superseded plugin udev rules"
    rm -f "$LEGACY_UDEV_RULES_FLASH" "$LEGACY_UDEV_RULES_LIVE"
}

install_udev_rules() {
    info "Installing udev rules"

    fetch_udev_rules
    remove_legacy_udev_rules

    cp "$UDEV_RULES_FLASH" "$UDEV_RULES_LIVE"
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true

    # /etc is tmpfs on Unraid, so the rules must be restored from the flash
    # drive on every boot. Rewrite the block rather than only appending a
    # missing one, so existing installs pick up the new filename.
    local marker="# GoW udev rules"
    local end_marker="# End GoW udev rules"
    local marker_re="${marker//\//\\/}"
    local end_marker_re="${end_marker//\//\\/}"
    if grep -qF "$marker" "$GO_SCRIPT" 2>/dev/null; then
        info "Updating udev restore in /boot/config/go"
        if grep -qF "$end_marker" "$GO_SCRIPT" 2>/dev/null; then
            sed -i "/${marker_re}/,/${end_marker_re}/d" "$GO_SCRIPT"
        else
            sed -i "/${marker_re}/,/^$/d" "$GO_SCRIPT"
        fi
    else
        info "Adding udev restore to /boot/config/go"
    fi

    # Removing the old block leaves the blank line that separated it behind, so
    # trim trailing blanks before appending — otherwise every deploy grows the
    # file by one empty line.
    # Truncated in place so the go script keeps its permissions.
    if [[ -f "$GO_SCRIPT" ]]; then
        local go_body
        go_body="$(< "$GO_SCRIPT")"
        printf '%s\n' "$go_body" > "$GO_SCRIPT"
    fi

    cat >> "$GO_SCRIPT" <<EOF

${marker}
cp ${UDEV_RULES_FLASH} ${UDEV_RULES_LIVE}
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true
${end_marker}
EOF
}
