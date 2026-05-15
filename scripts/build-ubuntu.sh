#!/usr/bin/env bash
FLAVOR="ubuntu"
CODENAME="noble"
UBUNTU_VERSION="24.04"
DESKTOP_PKGS="ubuntu-desktop-minimal"
DISK_SIZE="8G"

source "$(dirname "$0")/_common.sh"
build_rootfs
