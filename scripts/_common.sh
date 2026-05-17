#!/usr/bin/env bash
# Source this after setting FLAVOR (and optionally DISK_SIZE),
# then call build_rootfs.
# Release info: release.conf  |  Packages: packages/<flavor>.packages + packages/t2.packages

set -euo pipefail

##
## Paths
##

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

##
## Configuration
##

: "${FLAVOR:?FLAVOR must be set}"
: "${DISK_SIZE:=20G}"

# shellcheck source=../release.conf
source "${repo_root}/release.conf"

##
## Logging
##

_esc()   { printf "\033[%sm" "$1"; }
bold()   { _esc "1;$1"; }
reset()  { _esc 0; }
green()  { bold 32; }
yellow() { bold 33; }
red()    { bold 31; }
cyan()   { bold 36; }

log()  { printf "%s==>%s [%s%s%s] %s\n" "$(green)" "$(reset)" "$(cyan)" "${FLAVOR}" "$(reset)" "$*"; }
warn() { printf "%sWARN%s %s\n" "$(yellow)" "$(reset)" "$*" >&2; }
err()  { printf "%sERROR%s %s\n" "$(red)" "$(reset)" "$*" >&2; exit 1; }

##
## Package lists
##

_read_pkgs() { grep -v '^\s*#' "$1" | grep -v '^\s*$' | tr '\n' ' ' | xargs; }

desktop_pkg_file="${repo_root}/packages/${FLAVOR}.packages"

[[ -f "${desktop_pkg_file}" ]] || err "no package list at ${desktop_pkg_file}"

desktop_pkgs=$(_read_pkgs "${desktop_pkg_file}")

##
## ISO resolution
##

# Matches both initial release (26.04) and point releases (26.04.1, 26.04.2, …)
ubuntu_iso=$(
  curl -fsSL "https://releases.ubuntu.com/${UBUNTU_VERSION}/" \
    | grep -oP "ubuntu-${UBUNTU_VERSION//./\\.}(?:\\.\\d+)?-live-server-amd64\\.iso" \
    | sort -V | tail -1 || true
)
[[ -n "${ubuntu_iso}" ]] || err "could not find Ubuntu ${UBUNTU_VERSION} ISO at releases.ubuntu.com"

iso_url="https://releases.ubuntu.com/${UBUNTU_VERSION}/${ubuntu_iso}"
out_name="${FLAVOR}-${UBUNTU_VERSION}-t2-rootfs"
build_dir="${repo_root}/build/${FLAVOR}"

##
## Build
##

build_rootfs() {
  mkdir -p "${build_dir}"
  cd "${build_dir}"

  log "Installing build tools..."
  sudo apt-get install -y -q qemu-system-x86 qemu-utils xorriso

  log "Fetching Ubuntu Server ${UBUNTU_VERSION} ISO..."
  [[ -f "${ubuntu_iso}" ]] || wget -q -O "${ubuntu_iso}" "${iso_url}"

  # Direct kernel boot bypasses the GRUB menu — no keystrokes needed
  log "Extracting kernel and initrd from ISO..."
  xorriso -osirrox on -indev "${ubuntu_iso}" -extract /casper/vmlinuz vmlinuz 2>/dev/null
  xorriso -osirrox on -indev "${ubuntu_iso}" -extract /casper/initrd  initrd  2>/dev/null

  log "Building cloud-init seed ISO..."
  local seed_dir
  seed_dir=$(mktemp -d)
  sed \
    -e "s|%%CODENAME%%|${CODENAME}|g" \
    -e "s|%%DESKTOP_PKGS%%|${desktop_pkgs}|g" \
    "${repo_root}/autoinstall.yaml" > "${seed_dir}/user-data"
  printf 'instance-id: ubuntu-t2-build\nlocal-hostname: t2-ubuntu\n' > "${seed_dir}/meta-data"
  xorriso -as mkisofs -volid CIDATA -joliet -rock -output seed.iso "${seed_dir}" 2>/dev/null
  rm -rf "${seed_dir}"

  log "Creating ${DISK_SIZE} disk image..."
  qemu-img create -f qcow2 disk.qcow2 "${DISK_SIZE}"

  sudo chmod 666 /dev/kvm 2>/dev/null || true

  log "Running installer (expect 30–90 min)..."
  timeout 7200 qemu-system-x86_64 \
    -enable-kvm \
    -m 6144 \
    -smp "$(nproc)" \
    -cpu host \
    -no-reboot \
    -display none \
    -serial stdio \
    -kernel vmlinuz \
    -initrd initrd \
    -append "console=ttyS0 autoinstall ds=nocloud quiet" \
    -drive "file=${ubuntu_iso},format=raw,media=cdrom,readonly=on,if=ide,index=0" \
    -drive "file=seed.iso,format=raw,media=cdrom,readonly=on,if=ide,index=1" \
    -drive "file=disk.qcow2,format=qcow2,if=virtio,cache=unsafe" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0

  log "Converting QCOW2 to raw..."
  rm -f "${ubuntu_iso}" vmlinuz initrd seed.iso
  qemu-img convert -p -f qcow2 -O raw disk.qcow2 disk.img
  rm -f disk.qcow2

  log "Compressing with xz..."
  xz -T0 disk.img
  sha256sum disk.img.xz | awk '{print $1}' > "${out_name}.img.xz.sha256"

  log "Splitting into ≤2 GiB parts..."
  split \
    --bytes=1990M \
    --numeric-suffixes=1 \
    --suffix-length=2 \
    disk.img.xz \
    "${out_name}.img.xz.part"
  rm -f disk.img.xz

  sha256sum "${out_name}".img.xz.part* > "${out_name}.sha256"

  log "Done:"
  ls -lh "${out_name}".img.xz.part* "${out_name}".sha256
  printf "\nReassemble: cat %s.img.xz.part* | xz -d > disk.img\n" "${out_name}"
}
