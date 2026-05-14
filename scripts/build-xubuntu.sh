#!/usr/bin/env bash
FLAVOR="xubuntu"
CODENAME="noble"
UBUNTU_VERSION="24.04"
DESKTOP_PKGS="xubuntu-desktop"

source "$(dirname "$0")/_common.sh"
build_rootfs
