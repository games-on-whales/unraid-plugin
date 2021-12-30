#!/bin/bash

if [ ! -f /proc/driver/nvidia/version ]; then
    echo "No nvidia driver loaded; skipping"
    exit 0
fi

source vars.sh

if [ $(jq ".auto_fetch_32bit" $GOW_EMHTTP/config.json) = "false" ]; then
    echo "Skipping auto-fetch of 32-bit drivers (per config)"
    exit 0
else
    echo "config: $(jq ".auto_fetch_32bit" $GOW_EMHTTP/config.json)"
fi

function download_pkg() {
    dl_url=$1
    dl_file=$2

    echo "Downloading $dl_url"

    if ! wget -q -nc --show-progress --progress=bar:force:noscroll -O "$dl_file" "$dl_url"; then
        echo "ERROR: Unable to download $dl_file"
        return 1
    fi
}

HOST_DRIVER_VERSION=$(cat /proc/driver/nvidia/version | sed -nE 's/.*Module[ \t]+([0-9]+(\.[0-9]+)?).*/\1/p')
DOWNLOAD_URL=https://us.download.nvidia.com/XFree86/Linux-x86_64/$HOST_DRIVER_VERSION/NVIDIA-Linux-x86_64-$HOST_DRIVER_VERSION.run
DL_FILE=/tmp/nvidia-$HOST_DRIVER_VERSION.run
EXTRACT_LOC=/tmp/gow/nvidia-32

if [ ! -d $EXTRACT_LOC ]; then
    if ! download_pkg "$DOWNLOAD_URL" "$DL_FILE"; then
        echo "Couldn't download nvidia driver version $HOST_DRIVER_VERSION"
        exit 1
    fi

    chmod +x $DL_FILE
    $DL_FILE -x --target $EXTRACT_LOC
else
    echo "32-bit drivers already found"
fi

ldconfig
