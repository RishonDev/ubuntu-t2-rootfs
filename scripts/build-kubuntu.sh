#!/usr/bin/env bash
FLAVOR="kubuntu"
CODENAME="noble"
UBUNTU_VERSION="24.04"
DESKTOP_PKGS="kubuntu-desktop"

source "$(dirname "$0")/_common.sh"
build_rootfs
