#!/bin/bash

source vars.sh

# What kind of GPUs do we have?
has_nvidia=false
has_non_nvidia=false

if command -v lshw >/dev/null 2>&1; then
    while read line; do
        if [[ ${line,,} =~ nvidia ]]; then
            has_nvidia=true
        else
            has_non_nvidia=true
        fi
    done < <(lshw -C display 2>/dev/null | grep vendor)
fi

if [[ "$has_nvidia" = "true" && ! -f /boot/config/plugins/nvidia-driver.plg ]]; then
    if [ "$has_non_nvidia" = "true" ]; then
        # This user has both NVIDIA and non-NVIDIA cards, so don't prevent
        # installation, but provide a warning.
        echo "╔══════════╗"
        echo "║ WARNING! ║"
        echo "╚══════════╝"
        echo "Using Games on Whales with an NVIDIA GPU requires the Nvidia-Driver plugin, but you don't have it installed. If you want to use your NVIDIA GPU, please install Nvidia-Driver from Community Applications."
    else
        # This user only has NVIDIA GPUs, so it's an error to install GoW without the Nvidia-Driver plugin.
        echo "╔════════╗"
        echo "║ ERROR! ║"
        echo "╚════════╝"
        echo "Games on Whales requires the Nvidia-Driver plugin. Please install it from Community Applications and try again."
        exit 1
    fi
fi
