#!/usr/bin/env bash
# Source this from a flavor script after setting FLAVOR, CODENAME,
# UBUNTU_VERSION, and DESKTOP_PKGS, then call build_rootfs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

: "${FLAVOR:?'FLAVOR must be set'}"
: "${CODENAME:=noble}"
: "${UBUNTU_VERSION:=24.04}"
: "${DESKTOP_PKGS:?'DESKTOP_PKGS must be set'}"

# Resolve the latest point release (e.g. 24.04.4) so the URL is always valid.
UBUNTU_ISO=$(curl -fsSL "https://releases.ubuntu.com/${UBUNTU_VERSION}/" \
  | grep -oP "ubuntu-${UBUNTU_VERSION//./\\.}\\.\\d+-live-server-amd64\\.iso" \
  | sort -V | tail -1)
UBUNTU_ISO_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}/${UBUNTU_ISO}"
OUT_NAME="${FLAVOR}-${UBUNTU_VERSION}-t2-rootfs"
BUILD_DIR="${REPO_ROOT}/build/${FLAVOR}"

build_rootfs() {
  mkdir -p "${BUILD_DIR}"
  cd "${BUILD_DIR}"

  echo "==> [${FLAVOR}] Installing build tools..."
  sudo apt-get install -y -q qemu-system-x86 qemu-utils xorriso

  echo "==> [${FLAVOR}] Fetching Ubuntu Server ${UBUNTU_VERSION}..."
  [[ -f "${UBUNTU_ISO}" ]] || wget -q --show-progress -O "${UBUNTU_ISO}" "${UBUNTU_ISO_URL}"

  # Direct kernel boot bypasses the GRUB menu entirely, no keystrokes needed.
  echo "==> [${FLAVOR}] Extracting boot files from ISO..."
  xorriso -osirrox on -indev "${UBUNTU_ISO}" -extract /casper/vmlinuz vmlinuz 2>/dev/null
  xorriso -osirrox on -indev "${UBUNTU_ISO}" -extract /casper/initrd  initrd  2>/dev/null

  echo "==> [${FLAVOR}] Building seed ISO..."
  local tmpdir
  tmpdir=$(mktemp -d)
  sed \
    -e "s|%%CODENAME%%|${CODENAME}|g" \
    -e "s|%%DESKTOP_PKGS%%|${DESKTOP_PKGS}|g" \
    "${REPO_ROOT}/autoinstall.yaml" > "${tmpdir}/user-data"
  touch "${tmpdir}/meta-data"
  xorriso -as mkisofs -volid CIDATA -joliet -rock \
    -output seed.iso "${tmpdir}" 2>/dev/null
  rm -rf "${tmpdir}"

  echo "==> [${FLAVOR}] Creating 8G disk image..."
  qemu-img create -f qcow2 disk.qcow2 8G

  sudo chmod 666 /dev/kvm 2>/dev/null || true

  echo "==> [${FLAVOR}] Running installer (expect 30-90 min)..."
  timeout 7200 qemu-system-x86_64 \
    -enable-kvm \
    -m 4096 \
    -smp "$(nproc)" \
    -cpu host \
    -no-reboot \
    -display none \
    -serial stdio \
    -kernel vmlinuz \
    -initrd initrd \
    -append "console=ttyS0 autoinstall ds=nocloud quiet" \
    -drive "file=${UBUNTU_ISO},format=raw,media=cdrom,readonly=on,if=ide,index=0" \
    -drive "file=seed.iso,format=raw,media=cdrom,readonly=on,if=ide,index=1" \
    -drive "file=disk.qcow2,format=qcow2,if=virtio,cache=unsafe" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0

  echo "==> [${FLAVOR}] Converting to raw..."
  rm -f "${UBUNTU_ISO}" vmlinuz initrd seed.iso
  qemu-img convert -p -f qcow2 -O raw disk.qcow2 disk.img
  rm -f disk.qcow2

  echo "==> [${FLAVOR}] Compressing (xz -T0)..."
  xz -T0 disk.img  # removes disk.img, writes disk.img.xz

  echo "==> [${FLAVOR}] Splitting into ≤2G parts..."
  split \
    --bytes=2G \
    --numeric-suffixes=1 \
    --suffix-length=2 \
    disk.img.xz \
    "${OUT_NAME}.img.xz.part"
  rm -f disk.img.xz

  sha256sum "${OUT_NAME}".img.xz.part* > "${OUT_NAME}.sha256"

  echo "==> [${FLAVOR}] Done:"
  ls -lh "${OUT_NAME}".img.xz.part* "${OUT_NAME}".sha256

  echo ""
  echo "Reassemble with: cat ${OUT_NAME}.img.xz.part* | xz -d > disk.img"
}
