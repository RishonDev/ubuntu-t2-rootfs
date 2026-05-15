#!/usr/bin/env bash
FLAVOR="ubuntu"
CODENAME="resolute"
UBUNTU_VERSION="26.04"
DESKTOP_PKGS="ubuntu-desktop-minimal"
DISK_SIZE="8G"

source "$(dirname "$0")/_common.sh"
build_rootfs
