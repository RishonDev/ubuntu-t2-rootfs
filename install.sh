#!/usr/bin/env bash
# T2 Ubuntu Installer — macOS
# Usage: sudo bash install.sh [--dry-run] [--flavor FLAVOR] [--disk /dev/diskN]

set -euo pipefail

GITHUB_REPO="RishonDev/ubuntu-t2-rootfs"
UBUNTU_VERSION="26.04"
FLAVORS=(ubuntu kubuntu ubuntu-unity ubuntu-budgie ubuntu-cinnamon xubuntu)

# ── Colors ────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0;31m'  # red
  G='\033[0;32m'  # green
  Y='\033[1;33m'  # yellow
  C='\033[0;36m'  # cyan
  W='\033[1m'     # bold
  N='\033[0m'     # reset
else
  R='' G='' Y='' C='' W='' N=''
fi

DRY_RUN=false
FLAVOR=""
TARGET_DISK=""
PV=false

die()  { echo -e "\n${R}✗ $*${N}" >&2; exit 1; }
info() { echo -e "\n${W}==> $*${N}"; }
step() { echo -e "  ${C}•${N} $*"; }
ok()   { echo -e "  ${G}✓${N} $*"; }
warn() { echo -e "  ${Y}⚠  $*${N}"; }
ask()  { read -rp "$(echo -e "  ${W}$1${N}: ")" "$2"; }

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
      echo "Usage: sudo bash install.sh [--dry-run] [--flavor FLAVOR] [--disk /dev/diskN]"
      echo "Flavors: ${FLAVORS[*]}"
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

# ── Preflight ─────────────────────────────────────────────────────────────
[[ "$(uname)" == Darwin ]] || die "This script is for macOS only"
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"
for cmd in diskutil hdiutil curl python3 xz dd; do
  command -v "$cmd" &>/dev/null || die "Missing required tool: $cmd"
done
command -v pv &>/dev/null && PV=true

# ── Disk helpers ───────────────────────────────────────────────────────────
disk_info() {
  diskutil info "$1" 2>/dev/null
}

disk_size_bytes() {
  disk_info "$1" \
    | grep "Disk Size" \
    | grep -oE '\([0-9]+ Bytes\)' \
    | grep -oE '[0-9]+'
}

disk_size_human() {
  disk_info "$1" | awk -F': ' '
    /Disk Size:/ {
      gsub(/^ +/, "", $2)
      split($2, fields, "(")
      gsub(/ +$/, "", fields[1])
      print fields[1]
    }
  '
}

disk_model() {
  disk_info "$1" | awk -F': ' '
    /Device \/ Media Name:/ { gsub(/^ +/, "", $2); print $2 }
  '
}

disk_location() {
  disk_info "$1" | awk -F': ' '
    /Device Location:/ { gsub(/^ +/, "", $2); print $2 }
  '
}

# Converts a human size string (e.g. "50G", "1.5TB") to bytes.
parse_size() {
  python3 -c "
import re, sys
s = '${1}'.strip().upper()
m = re.match(r'^([0-9.]+)\s*(T|TB|G|GB|M|MB)?$', s)
if not m:
    sys.exit(1)
n, unit = float(m.group(1)), (m.group(2) or 'B')
multipliers = {
    'M': 1000**2, 'MB': 1000**2,
    'G': 1000**3, 'GB': 1000**3,
    'T': 1000**4, 'TB': 1000**4,
}
print(int(n * multipliers.get(unit, 1)))
" 2>/dev/null || die "Invalid size: ${1} — use e.g. 50G, 80GB"
}

gb() {
  python3 -c "print(f'{int(${1}) // 1000**3} GB')"
}

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
echo "    2. 'Allow booting from external media' checked (external installs)"
echo ""
read -rp "  Press Enter to continue (Ctrl+C to cancel)..."

# ── Disk selection ────────────────────────────────────────────────────────
info "Available disks"

mapfile -t DISK_LIST < <(
  diskutil list | awk '/^\/dev\/disk[0-9]+[[:space:]]/ { print $1 }'
)
[[ ${#DISK_LIST[@]} -gt 0 ]] || die "No disks found"

printf "\n  %-5s %-12s %-12s %-12s %s\n" "#" "DEVICE" "SIZE" "TYPE" "NAME"
printf "  %-5s %-12s %-12s %-12s %s\n"   "─" "──────────" "──────────" "──────────" "────"

declare -A DISK_LOC_MAP
for i in "${!DISK_LIST[@]}"; do
  dev="${DISK_LIST[$i]}"
  loc=$(disk_location "$dev")
  DISK_LOC_MAP[$dev]="$loc"
  size=$(disk_size_human "$dev")
  model=$(disk_model "$dev")
  if [[ "$loc" == Internal ]]; then
    printf "  ${Y}%-5s %-12s %-12s %-12s %s${N}\n" "$((i+1))" "$dev" "$size" "$loc" "$model"
  else
    printf "  %-5s %-12s %-12s %-12s %s\n"          "$((i+1))" "$dev" "$size" "$loc" "$model"
  fi
done
echo ""

if [[ -z "$TARGET_DISK" ]]; then
  ask "Select disk number" sel
  [[ "$sel" =~ ^[1-9][0-9]*$ ]] && (( sel <= ${#DISK_LIST[@]} )) || die "Invalid: $sel"
  TARGET_DISK="${DISK_LIST[$((sel-1))]}"
fi

[[ -b "$TARGET_DISK" ]] || die "Not a block device: $TARGET_DISK"
DISK_BYTES=$(disk_size_bytes "$TARGET_DISK")
(( DISK_BYTES >= 8*1024**3 )) \
  || die "$TARGET_DISK is too small — need at least 8 GB (20 GB for kubuntu/unity/budgie/cinnamon)"

echo ""
echo -e "  Target: ${W}${TARGET_DISK}${N} — $(disk_size_human "$TARGET_DISK") — ${DISK_LOC_MAP[$TARGET_DISK]}"
echo ""

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
mapfile -t PARTS < <(
  find . -maxdepth 3 -name "${FLAVOR}-${UBUNTU_VERSION}-t2-rootfs.img.xz.part*" | sort -V
)

if [[ ${#PARTS[@]} -gt 0 ]]; then
  ok "Found ${#PARTS[@]} local part(s)"
  local_sha=$(find . -maxdepth 3 -name "${FLAVOR}-${UBUNTU_VERSION}-t2-rootfs.img.xz.sha256" | head -1)
  [[ -n "$local_sha" ]] && EXPECTED_SHA=$(cat "$local_sha")
else
  step "Fetching metadata from latest release..."
  META_URL=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]+metadata\.json"' \
    | grep -oE 'https://[^"]+') \
    || die "Cannot reach GitHub API"
  [[ -n "$META_URL" ]] || die "No metadata.json in latest release — run the build workflow first"

  mapfile -t META_LINES < <(
    curl -fsSL "$META_URL" | python3 -c "
import json, sys
data    = json.load(sys.stdin)
flavor  = '${FLAVOR}'.replace('-', ' ')
version = '${UBUNTU_VERSION}'
for entry in data.get('all', []):
    if entry['name'].lower().startswith(flavor + ' ' + version):
        print(entry.get('sha256', ''))
        for url in entry.get('iso', []):
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
    step "[dry-run] Would verify: cat parts | shasum -a 256 == ${EXPECTED_SHA}"
  else
    ACTUAL_SHA=$(cat "${PARTS[@]}" | shasum -a 256 | awk '{print $1}')
    [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] \
      || die "SHA256 mismatch\n  expected: ${EXPECTED_SHA}\n  got:      ${ACTUAL_SHA}"
    ok "SHA256 verified"
  fi
else
  warn "No SHA256 available — skipping verification"
fi

# ── Write ──────────────────────────────────────────────────────────────────
if [[ "${DISK_LOC_MAP[$TARGET_DISK]}" == Internal ]]; then
  # ── Internal disk: dual-boot (Asahi-style APFS resize) ────────────────────
  info "Internal disk selected — dual-boot setup"

  EFI_ID=$(diskutil list "$TARGET_DISK" | awk '/Linux_EFI/  { print $NF; exit }')
  ROOT_ID=$(diskutil list "$TARGET_DISK" | awk '/Linux_Root/ { print $NF; exit }')

  if [[ -n "$EFI_ID" && -n "$ROOT_ID" ]]; then
    # ── Overwrite existing Linux install ──────────────────────────────────
    echo ""
    diskutil list "$TARGET_DISK"
    echo ""
    warn "Existing Linux install found:  EFI=${EFI_ID}  Root=${ROOT_ID}"
    echo ""
    echo -e "  ${R}${W}The existing Linux partitions will be overwritten.${N}"
    ask "Type 'yes' to replace the existing install" confirm
    [[ "$confirm" == yes ]] || die "Aborted"

  else
    # ── Fresh install: shrink macOS and carve out Linux partitions ─────────
    APFS_ID=$(diskutil list "$TARGET_DISK" \
      | awk '/Apple_APFS[[:space:]]/ { print $NF; exit }')
    [[ -n "$APFS_ID" ]] || die "Could not find macOS APFS container on ${TARGET_DISK}"

    APFS_BYTES=$(disk_size_bytes "/dev/${APFS_ID}")

    echo ""
    diskutil list "$TARGET_DISK"
    echo ""
    echo "  macOS container : $(gb "$APFS_BYTES")"
    echo "  Total disk      : $(gb "$DISK_BYTES")"
    echo ""
    ask "Space to allocate to Linux (e.g. 50G, 80G)" linux_size_input

    LINUX_BYTES=$(parse_size "$linux_size_input")
    NEW_APFS_BYTES=$(( DISK_BYTES - LINUX_BYTES ))

    (( NEW_APFS_BYTES > 20*1000**3 )) \
      || die "macOS would only have $(gb "$NEW_APFS_BYTES") remaining — need to leave at least 20 GB"
    (( LINUX_BYTES >= 8*1024**3 )) \
      || die "Linux allocation too small — need at least 8 GB (20 GB for kubuntu/unity/budgie/cinnamon)"

    echo ""
    echo "  macOS will shrink to : $(gb "$NEW_APFS_BYTES")"
    echo "  Linux will receive   : $(gb "$LINUX_BYTES")  (512 MB EFI + rest as root)"
    echo ""
    ask "Confirm? [y/N]" confirm
    [[ "${confirm,,}" == y ]] || die "Aborted"

    step "Resizing macOS APFS container..."
    run diskutil apfs resizeContainer "/dev/${APFS_ID}" "${NEW_APFS_BYTES}b"

    step "Creating Linux EFI partition (512 MB)..."
    run diskutil addPartition "/dev/${APFS_ID}" "MS-DOS FAT32" "Linux_EFI" 512M

    EFI_ID=$(diskutil list "$TARGET_DISK" | awk '/Linux_EFI/ { print $NF; exit }')
    [[ -n "$EFI_ID" ]] || die "Failed to locate new EFI partition"

    step "Creating Linux root partition (remaining space)..."
    run diskutil addPartition "/dev/${EFI_ID}" "MS-DOS FAT32" "Linux_Root" 0b

    ROOT_ID=$(diskutil list "$TARGET_DISK" | awk '/Linux_Root/ { print $NF; exit }')
    [[ -n "$ROOT_ID" ]] || die "Failed to locate new root partition"
  fi

  # macOS may auto-mount FAT32 partitions — unmount before writing
  run diskutil unmount "/dev/${EFI_ID}"  2>/dev/null || true
  run diskutil unmount "/dev/${ROOT_ID}" 2>/dev/null || true

  # Warn if the reassembled image won't fit in the temp directory
  IMG_BYTES=$(du -sk "${PARTS[@]}" | awk '{ s += $1 } END { print s * 1024 }')
  FREE_MACOS=$(df -k / | awk 'NR==2 { print $4 * 1024 }')
  (( FREE_MACOS > IMG_BYTES )) \
    || warn "Low free space on macOS — the reassembled image may not fit in ${WORK_DIR}"

  step "Reassembling image..."
  IMAGE_FILE="${WORK_DIR}/disk.img"
  PARTS_Q=$(printf '%q ' "${PARTS[@]}")   # shell-quote paths in case they contain spaces
  run_sh "cat ${PARTS_Q}| xz -d > $(printf '%q' "$IMAGE_FILE")"

  step "Attaching disk image..."
  if ! $DRY_RUN; then
    IMG_DISK=$(hdiutil attach -nomount \
      -imagekey diskimage-class=CRawDiskImage "$IMAGE_FILE" \
      | awk 'NR==1 { print $1 }')
    [[ -n "$IMG_DISK" ]] || die "hdiutil attach failed"
    trap 'hdiutil detach "$IMG_DISK" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT

    EFI_SRC=$(diskutil list "$IMG_DISK" | awk '/EFI/   { print $NF; exit }')
    ROOT_SRC=$(diskutil list "$IMG_DISK" | awk '/Linux/ { print $NF; exit }')
    [[ -n "$EFI_SRC" && -n "$ROOT_SRC" ]] \
      || die "Could not identify EFI+root partitions in disk image"

    step "Writing EFI  : /dev/${EFI_SRC}  →  /dev/r${EFI_ID}"
    dd if="/dev/r${EFI_SRC}" of="/dev/r${EFI_ID}" bs=4m
    ok "EFI written"

    step "Writing root : /dev/${ROOT_SRC}  →  /dev/r${ROOT_ID}"
    dd if="/dev/r${ROOT_SRC}" of="/dev/r${ROOT_ID}" bs=4m
    ok "Root written"

    hdiutil detach "$IMG_DISK"
    trap 'rm -rf "$WORK_DIR"' EXIT
  else
    step "[dry-run] Would attach disk.img → dd EFI+root to ${EFI_ID}, ${ROOT_ID}"
  fi

  run sync

else
  # ── External disk: wipe and write ─────────────────────────────────────────
  info "Writing image to ${TARGET_DISK}"

  if diskutil list "$TARGET_DISK" | grep -qi "linux"; then
    warn "Existing Linux install detected on ${TARGET_DISK} — it will be replaced"
  fi

  echo ""
  echo -e "  ${R}${W}All data on ${TARGET_DISK} will be permanently erased.${N}"
  ask "Type 'yes' to confirm" confirm
  [[ "$confirm" == yes ]] || die "Aborted"

  # /dev/disk2 → /dev/rdisk2  (raw device bypasses buffer cache, ~3× faster writes)
  RAW_DISK="${TARGET_DISK/\/dev\/disk//dev/rdisk}"
  PARTS_Q=$(printf '%q ' "${PARTS[@]}")

  run diskutil unmountDisk "$TARGET_DISK"
  step "Reassembling and writing (~8–20 GB depending on flavor)..."

  if $PV; then
    run_sh "cat ${PARTS_Q}| xz -d | pv | dd of=$(printf '%q' "$RAW_DISK") bs=4m"
  else
    warn "pv not found — no progress display (brew install pv to enable)"
    run_sh "cat ${PARTS_Q}| xz -d | dd of=$(printf '%q' "$RAW_DISK") bs=4m"
  fi

  run sync
  ok "Image written"
fi

# ── Done ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${G}${W}  ✓ Installation complete!${N}"
echo ""
if [[ "${DISK_LOC_MAP[$TARGET_DISK]}" == Internal ]]; then
  echo "  Next steps:"
  echo "    1. Restart your Mac and hold Option (⌥) to select Ubuntu"
  echo "    2. Default login: ubuntu"
  echo "    3. On first boot, run:  sudo apple-get-firmware"
  echo "       to extract WiFi/Bluetooth firmware from macOS"
  echo "    4. To expand root to use all allocated space (optional):"
  echo "       sudo growpart /dev/nvme0n1 <root-partition-number>"
  echo "       sudo resize2fs /dev/nvme0n1p<number>"
else
  echo "  Next steps:"
  echo "    1. Eject:              diskutil eject ${TARGET_DISK}"
  echo "    2. Hold Option (⌥) at startup to select the drive"
  echo "    3. Default login:      ubuntu"
  echo "    4. On first boot, run: sudo apple-get-firmware"
fi
echo ""
