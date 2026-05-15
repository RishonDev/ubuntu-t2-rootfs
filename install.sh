#!/usr/bin/env bash
# T2 Ubuntu Installer
# Usage: sudo bash install.sh [--dry-run] [--flavor FLAVOR] [--disk /dev/sdX]

set -euo pipefail

GITHUB_REPO="RishonDev/ubuntu-t2-rootfs"
UBUNTU_VERSION="24.04"
FLAVORS=(ubuntu kubuntu ubuntu-unity ubuntu-budgie ubuntu-cinnamon xubuntu)

# ── Colors ────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' W='\033[1m' N='\033[0m'
else
  R='' G='' Y='' C='' W='' N=''
fi

DRY_RUN=false
FLAVOR=""
TARGET_DISK=""

die()   { echo -e "\n${R}✗ $*${N}" >&2; exit 1; }
info()  { echo -e "\n${W}==> $*${N}"; }
step()  { echo -e "  ${C}•${N} $*"; }
ok()    { echo -e "  ${G}✓${N} $*"; }
warn()  { echo -e "  ${Y}⚠  $*${N}"; }
ask()   { read -rp "$(echo -e "  ${W}$1${N}: ")" "$2"; }

run() {
  $DRY_RUN && { echo -e "  ${Y}[dry-run]${N} $(printf '%q ' "$@")"; return 0; }
  "$@"
}

run_sh() {
  $DRY_RUN && { echo -e "  ${Y}[dry-run]${N} $*"; return 0; }
  bash -c "$*"
}

# ── Args ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true ;;
    --flavor)   FLAVOR="${2:?'--flavor requires an argument'}"; shift ;;
    --disk)     TARGET_DISK="${2:?'--disk requires an argument'}"; shift ;;
    -h|--help)
      echo "Usage: sudo bash install.sh [--dry-run] [--flavor FLAVOR] [--disk /dev/sdX]"
      echo "Flavors: ${FLAVORS[*]}"
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

# ── Preflight ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"
for cmd in lsblk curl xz dd partprobe udevadm; do
  command -v "$cmd" &>/dev/null || die "Missing: $cmd"
done
command -v growpart &>/dev/null || { warn "growpart not found — partition won't be resized (install cloud-guest-utils)"; SKIP_GROW=true; }
command -v resize2fs &>/dev/null || { SKIP_GROW=true; }
SKIP_GROW=${SKIP_GROW:-false}

# ── Banner ────────────────────────────────────────────────────────────────
echo -e "${W}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║       T2 Ubuntu Installer            ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${N}"
$DRY_RUN && warn "DRY-RUN — no changes will be made\n"
echo "  Before proceeding, ensure your Mac has:"
echo "    1. Reduced Security enabled"
echo "       (macOS Recovery → Utilities → Startup Security Utility)"
echo "    2. 'Allow booting from external media' checked"
echo ""
read -rp "  Press Enter to continue (Ctrl+C to cancel)..."

# ── Disk selection ────────────────────────────────────────────────────────
info "Available disks"

mapfile -t DISK_LIST < <(lsblk -dpno NAME | grep -E '^/dev/(sd|nvme|mmcblk)')
[[ ${#DISK_LIST[@]} -gt 0 ]] || die "No disks found"

classify_disk() {
  local name="${1#/dev/}"
  local removable transport
  removable=$(cat "/sys/block/${name}/removable" 2>/dev/null || echo 0)
  transport=$(udevadm info --query=property --name="$name" 2>/dev/null | grep "^ID_BUS=" | cut -d= -f2 || true)
  if   [[ "$name" == nvme0n1 ]];                        then echo "internal"
  elif [[ "$removable" == 1 || "$transport" == usb ]];  then echo "external (USB)"
  elif [[ "$name" == nvme* ]];                          then echo "external (TB)"
  else                                                       echo "external"
  fi
}

printf "\n  %-5s %-14s %-9s %-16s %s\n" "#" "DEVICE" "SIZE" "TYPE" "MODEL"
printf "  %-5s %-14s %-9s %-16s %s\n"   "─" "──────────────" "─────────" "────────────────" "─────"

declare -A DISK_TYPE_MAP
for i in "${!DISK_LIST[@]}"; do
  dev="${DISK_LIST[$i]}"
  dtype=$(classify_disk "$dev")
  DISK_TYPE_MAP[$dev]="$dtype"
  size=$(lsblk -dno SIZE "$dev")
  model=$(lsblk -dno MODEL "$dev" | xargs)
  if [[ "$dtype" == internal ]]; then
    printf "  ${Y}%-5s %-14s %-9s %-16s %s${N}\n" "$((i+1))" "$dev" "$size" "$dtype" "$model"
  else
    printf "  %-5s %-14s %-9s %-16s %s\n"          "$((i+1))" "$dev" "$size" "$dtype" "$model"
  fi
done
echo ""

if [[ -z "$TARGET_DISK" ]]; then
  ask "Select disk number" sel
  [[ "$sel" =~ ^[1-9][0-9]*$ ]] && (( sel <= ${#DISK_LIST[@]} )) || die "Invalid: $sel"
  TARGET_DISK="${DISK_LIST[$((sel-1))]}"
fi

[[ -b "$TARGET_DISK" ]] || die "Not a block device: $TARGET_DISK"
(( $(lsblk -dno SIZE --bytes "$TARGET_DISK") >= 8*1024*1024*1024 )) \
  || die "$TARGET_DISK is too small — need at least 8 GB (20 GB for kubuntu/unity/budgie/cinnamon)"

echo ""
echo -e "  Target: ${W}${TARGET_DISK}${N} — $(lsblk -dno SIZE "$TARGET_DISK") — ${DISK_TYPE_MAP[$TARGET_DISK]}"
[[ "${DISK_TYPE_MAP[$TARGET_DISK]}" == internal ]] && warn "This is the INTERNAL disk — this will erase macOS!"
echo ""
echo -e "  ${R}${W}All data on ${TARGET_DISK} will be permanently erased.${N}"
ask "Type 'yes' to confirm" confirm
[[ "$confirm" == yes ]] || die "Aborted"

# ── Flavor selection ──────────────────────────────────────────────────────
info "Select Ubuntu flavor"

if [[ -z "$FLAVOR" ]]; then
  for i in "${!FLAVORS[@]}"; do
    printf "  %-5s %s\n" "$((i+1))" "${FLAVORS[$i]}"
  done
  echo ""
  ask "Flavor number" sel
  [[ "$sel" =~ ^[1-9][0-9]*$ ]] && (( sel <= ${#FLAVORS[@]} )) || die "Invalid: $sel"
  FLAVOR="${FLAVORS[$((sel-1))]}"
fi

printf '%s\n' "${FLAVORS[@]}" | grep -qxF "$FLAVOR" || die "Unknown flavor: $FLAVOR"
ok "Flavor: $FLAVOR"

# ── Locate rootfs ─────────────────────────────────────────────────────────
info "Locating rootfs for ${FLAVOR} ${UBUNTU_VERSION}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

EXPECTED_SHA=""
mapfile -t PARTS < <(find . -maxdepth 3 -name "${FLAVOR}-${UBUNTU_VERSION}-t2-rootfs.img.xz.part*" | sort -V)

if [[ ${#PARTS[@]} -gt 0 ]]; then
  ok "Found ${#PARTS[@]} local part(s)"
  local_sha=$(find . -maxdepth 3 -name "${FLAVOR}-${UBUNTU_VERSION}-t2-rootfs.img.xz.sha256" | head -1)
  [[ -n "$local_sha" ]] && EXPECTED_SHA=$(cat "$local_sha")
else
  step "Fetching metadata from latest release..."
  META_URL=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
    | grep -oP '"browser_download_url":\s*"\K[^"]+metadata\.json') \
    || die "Cannot reach GitHub API"
  [[ -n "$META_URL" ]] || die "No metadata.json in latest release — run the build workflow first"

  mapfile -t META_LINES < <(
    curl -fsSL "$META_URL" | python3 -c "
import json, sys
data = json.load(sys.stdin)
flavor = '${FLAVOR}'.replace('-', ' ')
version = '${UBUNTU_VERSION}'
for e in data.get('all', []):
    if e['name'].lower().startswith(flavor + ' ' + version):
        print(e.get('sha256', ''))
        for url in e.get('iso', []):
            print(url)
        break
"
  )

  [[ ${#META_LINES[@]} -gt 1 ]] \
    || die "'${FLAVOR} ${UBUNTU_VERSION}' not found in metadata.json — run the build workflow first"

  EXPECTED_SHA="${META_LINES[0]}"

  for url in "${META_LINES[@]:1}"; do
    fname="${WORK_DIR}/$(basename "$url")"
    step "Downloading $(basename "$url")..."
    run curl -fL --progress-bar -o "$fname" "$url"
    PARTS+=("$fname")
  done
fi

if [[ -n "$EXPECTED_SHA" ]]; then
  step "Verifying SHA256..."
  if $DRY_RUN; then
    step "[dry-run] Would verify: cat parts | sha256sum == ${EXPECTED_SHA}"
  else
    ACTUAL_SHA=$(cat "${PARTS[@]}" | sha256sum | awk '{print $1}')
    [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] \
      || die "SHA256 mismatch\n  expected: ${EXPECTED_SHA}\n  got:      ${ACTUAL_SHA}"
    ok "SHA256 verified"
  fi
else
  warn "No SHA256 available — skipping verification"
fi

# ── Write image ───────────────────────────────────────────────────────────
info "Writing image to ${TARGET_DISK}"
step "Reassembling and writing (~8 GB, may take several minutes)..."

PARTS_QUOTED=$(printf '%q ' "${PARTS[@]}")
run_sh "cat ${PARTS_QUOTED}| xz -d | dd of=$(printf '%q' "$TARGET_DISK") bs=4M conv=fsync status=progress"
run sync
run partprobe "$TARGET_DISK"
run udevadm settle
ok "Image written"

# ── Grow root partition ───────────────────────────────────────────────────
if ! $SKIP_GROW; then
  info "Expanding root partition to fill disk"
  if $DRY_RUN; then
    step "[dry-run] Would growpart + resize2fs the ext4 partition on ${TARGET_DISK}"
  else
    ROOT_PART=$(lsblk -lpno NAME,FSTYPE "$TARGET_DISK" | awk '$2=="ext4"{print $1}' | tail -1)
    [[ -n "$ROOT_PART" ]] || die "Could not find ext4 partition on ${TARGET_DISK}"
    ROOT_NUM=$(grep -oP '\d+$' <<< "$ROOT_PART")
    step "Root partition: ${ROOT_PART}"
    run growpart "$TARGET_DISK" "$ROOT_NUM"
    run resize2fs "$ROOT_PART"
    ok "Root partition expanded"
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${G}${W}  ✓ Installation complete!${N}"
echo ""
echo "  Next steps:"
echo "    1. Safely eject ${TARGET_DISK}"
echo "    2. Hold Option (⌥) at startup to select the drive"
echo "    3. Default login: ubuntu"
echo "    4. On first boot, run:  sudo apple-get-firmware"
echo "       to extract WiFi/Bluetooth firmware from macOS"
echo ""
