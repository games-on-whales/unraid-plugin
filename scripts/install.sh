#!/bin/bash

source vars.sh
source utils.sh

KERNEL_PKG_DIR="$PACKAGE_DIR/$KERNEL_VER"
COMMON_PKG_DIR="$PACKAGE_DIR/$GOW_VERSION"

for dir in $KERNEL_PKG_DIR $COMMON_PKG_DIR; do
    if [ ! -d $dir ]; then
        mkdir -p $dir
    fi
done

function wait_for_network() {
    local host=8.8.8.8
    for i in {1..30}; do
        ping -c1 $host &>/dev/null && return 0
    done

    return 1
}

function ensure_pkg() {
    local package_name=$1
    local package_file=$(pkg_file "$package_name")

    # if it doesn't exist, download it
    if [ ! -f "$package_file" ] || [ ! -s "$package_file" ]; then
        rm -f "$package_file"
        if ! download_pkg "$package_name"; then
            return 1
        fi
    fi
}

function install_pkg() {
    local package_file=$(pkg_file "$1")

    echo "Installing: $package_file"
    /sbin/installpkg "$package_file"
}

function start_pkg() {
    # strip everything before the first slash. start/stop scripts are versioned
    # with the plugin, so they don't need the version in their filename.
    local name=${1#*/}

    echo "attempting to start $name"

    local start_script="$GOW_PLUGIN/scripts/start/$name.sh"

    if [ -f "$start_script" ]; then
        echo "executing $start_script"
        bash "$start_script"
    fi
}

# If we needed a settings file, it might go something like this:
# Create settings file if not found
#if [ ! -f "$GOW_PLUGIN/settings.cfg" ]; then
#    echo 'setting=value' > "$GOW_PLUGIN/settings.cfg"
#fi

if ! wait_for_network; then
    echo "Couldn't reach the network; failing"
    exit 1
fi

# Delete any older versions of the packages
if [ -d "$PACKAGE_DIR/*" ]; then
    rm -rf $(ls -1d $PACKAGE_DIR/* | grep -vE "$KERNEL_VER|$GOW_VERSION")
fi

echo "╔════════════════╗"
echo "║ Please wait... ║"
echo "╚════════════════╝"

for pkg in $GOW_PACKAGES; do
    # if this is an nvidia-specific package and there's no nvidia driver
    # loaded, skip
    if [ "$pkg" = nvidia/* ]; then
        if [ ! -f /proc/driver/nvidia/version ]; then
            echo "Skipping nvidia package $pkg; no nvidia driver loaded"
        fi
    fi

    if ensure_pkg "$pkg"; then
        if ! install_pkg "$pkg"; then
            echo "╔═══════╗"
            echo "║ ERROR ║"
            echo "╚═══════╝"
            echo "Could not install $pkg"
            exit 1
        fi
    else
        echo "╔═══════╗"
        echo "║ ERROR ║"
        echo "╚═══════╝"
        echo "Could not fetch $pkg"
        exit 1
    fi
done

echo "Generating module dependencies..."

# in case any kernel modules were installed, update module dependencies and
# trigger udev events
depmod -a 2>/dev/null
sleep 1 # wait a bit

udevadm control --reload 2>/dev/null && udevadm trigger --action=add 2>/dev/null
sleep 1 # wait a bit longer

echo "Setting up packages..."

for pkg in $GOW_PACKAGES; do
    start_pkg "$pkg"
done

echo "╔══════════╗"
echo "║ Complete ║"
echo "╚══════════╝"

exit 0

