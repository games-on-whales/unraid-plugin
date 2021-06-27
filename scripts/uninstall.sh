#1/bin/bash

source vars.sh

KV="$(uname -r)"
KERNEL_VER=${KV%%-*}

PACKAGE_DIR="$GOW_PLUGIN/packages"

function pkg_name() {
    PACKAGE_NAME=${1/kernel\//$KERNEL_VER\/}
    PACKAGE_NAME=${PACKAGE_NAME/common\//$GOW_VERSION\/}

    echo "$PACKAGE_NAME"
}

function pkg_file() {
    PACKAGE_NAME=$(pkg_name "$1")

    echo "$PACKAGE_DIR/$PACKAGE_NAME.txz"
}

function stop_pkg() {
    PACKAGE_NAME=$(pkg_name "$1")

    STOP_SCRIPT="$GOW_PLUGIN/scripts/stop/$PACKAGE_NAME.sh"

    if [ -f "$STOP_SCRIPT" ]; then
        bash "$STOP_SCRIPT"
    fi
}

for pkg in $GOW_PACKAGES; do
    PKG_NAME=$(pkg_name "$pkg")
    PKG_FILE=$(pkg_file "$pkg")

    stop_pkg "$pkg"

    if [ -f "$PKG_FILE" ]; then
        /sbin/removepkg "$PKG_FILE" 2>/dev/null
    fi
done

exit 0
