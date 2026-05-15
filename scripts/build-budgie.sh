#!/usr/bin/env bash
FLAVOR="ubuntu-budgie"
CODENAME="resolute"
UBUNTU_VERSION="26.04"
DESKTOP_PKGS="ubuntu-budgie-desktop"
DISK_SIZE="20G"

source "$(dirname "$0")/_common.sh"
build_rootfs
