#1/bin/bash

source vars.sh
source utils.sh

function stop_pkg() {
    # strip everything before the first slash. start/stop scripts are versioned
    # with the plugin, so they don't need the version in their filename.
    local name=${1#*/}

    local stop_script="$GOW_PLUGIN/scripts/stop/$name.sh"

    if [ -f "$stop_script" ]; then
        bash "$stop_script"
    fi
}

function main() {
    for pkg in $GOW_PACKAGES; do
        local package_name=$(pkg_name "$pkg")
        local package_file=$(pkg_file "$pkg")

        stop_pkg "$pkg"

        if [ -f "$package_file" ]; then
            /sbin/removepkg "$package_file" 2>/dev/null
        fi
    done
}

main

exit 0
