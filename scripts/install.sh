#!/bin/bash

source vars.sh

KV="$(uname -r)"
KERNEL_VER=${KV%%-*}

PACKAGE_DIR="$GOW_PLUGIN/packages"

KERNEL_PKG_DIR="$PACKAGE_DIR/$KERNEL_VER"
COMMON_PKG_DIR="$PACKAGE_DIR/$GOW_VERSION"

for dir in $KERNEL_PKG_DIR $COMMON_PKG_DIR; do
    if [ ! -d $dir ]; then
        mkdir -p $dir
    fi
done

function wait_for_network() {
    HOST=8.8.8.8
    for i in {1..30}; do
        ping -c1 $HOST &>/dev/null && return 0
    done

    return 1
}

function pkg_name() {
    PACKAGE_NAME=${1/kernel\//$KERNEL_VER\/}
    PACKAGE_NAME=${PACKAGE_NAME/common\//$GOW_VERSION\/}
    PACKAGE_NAME=${PACKAGE_NAME/nvidia\//$GOW_VERSION\/}

    echo "$PACKAGE_NAME"
}

function pkg_file() {
    PACKAGE_NAME=$(pkg_name "$1")

    echo "$PACKAGE_DIR/$PACKAGE_NAME.txz"
}

function pkg_url() {
    name=$1
    PACKAGE_NAME=$(pkg_name "$name")

    if [[ $name == kernel/* ]]; then
        echo "$GOW_GITPKGURL/kernel-bin/$PACKAGE_NAME.txz"
    else
        echo "https://github.com/games-on-whales/unraid-plugin/releases/download/$PACKAGE_NAME.txz"
    fi
}

function download_pkg() {
    PACKAGE_FILE=$(pkg_file "$1")
    PACKAGE_URL=$(pkg_url "$1")

    echo "Downloading $PACKAGE_URL"

    if wget -q -nc --show-progress --progress=bar:force:noscroll -O "$PACKAGE_FILE" "$PACKAGE_URL"; then
        if [ "$(md5sum "$PACKAGE_FILE" | cut -d ' ' -f1)" != "$(wget -qO- "$PACKAGE_URL.md5" | cut -d ' ' -f1)" ]; then
            echo "ERROR: Checksum mismatch for $PACKAGE_URL"
            return 1
        fi
    else
        echo "ERROR: Unable to download $PACKAGE_URL"
        return 1
    fi
}

function ensure_pkg() {
    PACKAGE_NAME=$1
    PACKAGE_FILE=$(pkg_file "$PACKAGE_NAME")

    # if it doesn't exist, download it
    if [ ! -f "$PACKAGE_FILE" ] || [ ! -s "$PACKAGE_FILE" ]; then
        rm -f "$PACKAGE_FILE"
        if ! download_pkg "$PACKAGE_NAME"; then
            return 1
        fi
    fi
}

function install_pkg() {
    PACKAGE_FILE=$(pkg_file "$1")

    echo "Installing: $PACKAGE_FILE"
    /sbin/installpkg "$PACKAGE_FILE"
}

function start_pkg() {
    # strip everything before the first slash. start/stop scripts are versioned
    # with the plugin, so they don't need the version in their filename.
    NAME=${1#*/}

    echo "attempting to start $NAME"

    START_SCRIPT="$GOW_PLUGIN/scripts/start/$NAME.sh"

    if [ -f "$START_SCRIPT" ]; then
        echo "executing $START_SCRIPT"
        bash "$START_SCRIPT"
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

