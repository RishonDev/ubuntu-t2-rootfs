#!/bin/sh
# SPDX-License-Identifier: MIT
# Adapted from the Asahi Linux installer (https://asahilinux.org/)

set -e

if [ "${0%/*}" != "$0" ]; then
    cd "${0%/*}"
fi

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

REPO="RishonDev/ubuntu-t2-rootfs"

# Fetch main.py alongside this script if bootstrap only downloaded install.sh
if [ ! -f main.py ]; then
    echo "  Fetching installer..."
    curl --no-progress-meter -L -o main.py \
        "https://raw.githubusercontent.com/${REPO}/main/main.py"
    curl --no-progress-meter -L -o util.py \
        "https://raw.githubusercontent.com/${REPO}/main/util.py"
fi

set +e
macos_ver=$(/usr/libexec/PlistBuddy -c "Print :ProductVersion" \
    /System/Library/CoreServices/SystemVersion.plist 2>/dev/null)
res=$?
set -e

if [ "$res" -ne 0 ] || [ -z "$macos_ver" ]; then
    echo "Unable to determine macOS version. Please report a bug."
    exit 1
fi

if [ "${macos_ver%%.*}" -lt 13 ]; then
    echo "T2 Ubuntu requires macOS 13.5 or later (found ${macos_ver})."
    exit 1
fi

if arch -arm64 true >/dev/null 2>&1; then
    echo "This installer is for Intel T2 Macs only."
    echo "For Apple Silicon, see https://asahilinux.org/"
    exit 1
fi

exec python3 main.py "$@"
