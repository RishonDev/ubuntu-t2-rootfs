#!/bin/sh
# SPDX-License-Identifier: MIT

# Truncation guard — prevents a partially-downloaded script from executing
if true; then
    set -e

    if [ ! -e /System ]; then
        echo "You appear to be running this script from Linux or another non-macOS system."
        echo "T2 Ubuntu can only be installed from macOS (or recoveryOS)."
        exit 1
    fi

    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

    if ! curl --no-progress-meter file:/// &>/dev/null; then
        echo "Your version of cURL is too old. This usually means your macOS is very out"
        echo "of date. Installing T2 Ubuntu requires at least macOS version 13.5."
        exit 1
    fi

    INSTALLER_URL="https://raw.githubusercontent.com/RishonDev/ubuntu-t2-rootfs/main/install.sh"

    TMP=/tmp/t2-ubuntu-install

    echo
    echo "Bootstrapping T2 Ubuntu installer:"

    if [ -e "$TMP" ]; then
        mv "$TMP" "$TMP-$(date +%Y%m%d-%H%M%S)"
    fi

    mkdir -p "$TMP"
    cd "$TMP"

    echo "  Downloading installer..."
    if ! curl --no-progress-meter -L -o install.sh "$INSTALLER_URL"; then
        echo "  Error downloading installer. GitHub might be blocked in your network."
        echo "  Please consider using a VPN if you experience issues."
        exit 1
    fi
    chmod +x install.sh

    echo "  Initializing..."
    echo

    if [ "$USER" != "root" ]; then
        echo "The installer needs to run as root."
        echo "Please enter your sudo password if prompted."
        exec caffeinate -dis sudo -E ./install.sh "$@"
    else
        exec caffeinate -dis ./install.sh "$@"
    fi
fi
