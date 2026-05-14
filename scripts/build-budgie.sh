#!/usr/bin/env bash
FLAVOR="ubuntu-budgie"
CODENAME="noble"
UBUNTU_VERSION="24.04"
DESKTOP_PKGS="ubuntu-budgie-desktop"

source "$(dirname "$0")/_common.sh"
build_rootfs
