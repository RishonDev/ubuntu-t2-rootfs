#!/usr/bin/env bash
FLAVOR="ubuntu-cinnamon"
CODENAME="resolute"
UBUNTU_VERSION="26.04"
DESKTOP_PKGS="ubuntucinnamon-desktop"
DISK_SIZE="20G"

source "$(dirname "$0")/_common.sh"
build_rootfs
