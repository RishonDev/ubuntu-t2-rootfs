#!/usr/bin/env bash
FLAVOR="ubuntu-cinnamon"
CODENAME="noble"
UBUNTU_VERSION="24.04"
DESKTOP_PKGS="ubuntu-cinnamon-desktop"

source "$(dirname "$0")/_common.sh"
build_rootfs
