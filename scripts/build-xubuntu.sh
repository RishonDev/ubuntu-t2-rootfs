#!/usr/bin/env bash
FLAVOR="xubuntu"
CODENAME="resolute"
UBUNTU_VERSION="26.04"
DISK_SIZE="8G"

source "$(dirname "$0")/_common.sh"
build_rootfs
