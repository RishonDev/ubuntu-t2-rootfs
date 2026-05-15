#!/usr/bin/env bash
FLAVOR="ubuntu-unity"
CODENAME="noble"
UBUNTU_VERSION="24.04"
DESKTOP_PKGS="ubuntu-unity-desktop"
DISK_SIZE="20G"

source "$(dirname "$0")/_common.sh"
build_rootfs
