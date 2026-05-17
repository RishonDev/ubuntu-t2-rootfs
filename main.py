#!/usr/bin/python3
# SPDX-License-Identifier: MIT
import os, sys, re, json, shutil, hashlib, tempfile, argparse, subprocess
import urllib.request, urllib.error, atexit

##
## Output helpers — adapted from Asahi Linux installer (util.py)
##

def col(*codes):
    return f"\033[{';'.join(map(str, codes))}m"

RESET = col(0)
BOLD, RED, GREEN, YELLOW, CYAN, WHITE = 1, 31, 32, 33, 36, 37

def _p(text, *codes, file=sys.stdout, end="\n"):
    prefix = col(*codes) if codes else ""
    print(f"{prefix}{text}{RESET}", file=file, end=end, flush=True)

def p_info(*args):    _p("\n==> " + " ".join(map(str, args)), BOLD)
def p_step(*args):    _p("  • " + " ".join(map(str, args)), CYAN)
def p_ok(*args):      _p("  ✓ " + " ".join(map(str, args)), BOLD, GREEN)
def p_warning(*args): _p("  ⚠  " + " ".join(map(str, args)), BOLD, YELLOW)
def p_error(*args):   _p("\n✗ " + " ".join(map(str, args)), BOLD, RED, file=sys.stderr)

def die(*args):
    p_error(*args)
    sys.exit(1)

def input_prompt(prompt):
    _p(f"» {prompt}: ", BOLD, WHITE, end="")
    sys.stdout.flush()
    return input()

def ssize(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return f"{n:.1f} {unit}" if n % 1 else f"{int(n)} {unit}"
        n /= 1000

##
## Config
##

GITHUB_REPO    = "RishonDev/ubuntu-t2-rootfs"
UBUNTU_VERSION = "26.04"

##
## Args
##

parser = argparse.ArgumentParser(description="T2 Ubuntu Installer")
parser.add_argument("--dry-run", action="store_true", help="Show actions without making changes")
parser.add_argument("--flavor",  help="Skip flavor prompt (name or partial match)")
parser.add_argument("--disk",    help="Skip disk prompt (e.g. /dev/disk2)")
args = parser.parse_args()
dry_run = args.dry_run

##
## Subprocess helpers
##

def run(*cmd, capture=False, check=True):
    if dry_run:
        _p(f"  [dry-run] {' '.join(cmd)}", BOLD, YELLOW)
        return ""
    r = subprocess.run(cmd, capture_output=capture, text=True, check=check)
    return r.stdout.strip() if capture else ""

def run_shell(cmd, check=True):
    if dry_run:
        _p(f"  [dry-run] {cmd}", BOLD, YELLOW)
        return
    subprocess.run(cmd, shell=True, check=check)

##
## Disk helpers
##

def diskutil_info(dev):
    out = subprocess.run(["diskutil", "info", dev],
                         capture_output=True, text=True).stdout
    result = {}
    for line in out.splitlines():
        k, _, v = line.partition(":")
        result[k.strip()] = v.strip()
    return result

def disk_size_bytes(dev):
    m = re.search(r"\((\d+) Bytes\)",
                  diskutil_info(dev).get("Disk Size", ""))
    return int(m.group(1)) if m else 0

def disk_size_human(dev):
    raw = diskutil_info(dev).get("Disk Size", "")
    m = re.match(r"(.+?)\s*\(", raw)
    return m.group(1).strip() if m else raw

def disk_model(dev):
    return diskutil_info(dev).get("Device / Media Name", "Unknown")

def disk_location(dev):
    return diskutil_info(dev).get("Device Location", "")

def list_disks():
    out = subprocess.run(["diskutil", "list"],
                         capture_output=True, text=True).stdout
    return re.findall(r"^(/dev/disk\d+)\s", out, re.MULTILINE)

def diskutil_list_text(dev):
    return subprocess.run(["diskutil", "list", dev],
                          capture_output=True, text=True).stdout

def find_partition(dev, label):
    for line in diskutil_list_text(dev).splitlines():
        if label in line:
            parts = line.split()
            if parts:
                return parts[-1]
    return ""

##
## Preflight
##

for tool in ("diskutil", "hdiutil", "curl", "xz", "dd"):
    if not shutil.which(tool):
        die(f"Missing required tool: {tool}")

pv_available = bool(shutil.which("pv"))

##
## Banner
##

print()
_p("  ╔══════════════════════════════════════╗", BOLD, WHITE)
_p("  ║       T2 Ubuntu Installer            ║", BOLD, WHITE)
_p("  ╚══════════════════════════════════════╝", BOLD, WHITE)
print()

if dry_run:
    p_warning("DRY-RUN — no changes will be made")
    print()

print("  Before proceeding, ensure your Mac has:")
print("    1. Reduced Security enabled")
print("       (macOS Recovery → Utilities → Startup Security Utility)")
print("    2. 'Allow booting from external media' checked (external installs)")
print()
input("  Press Enter to continue (Ctrl+C to cancel)... ")

##
## Disk selection
##

p_info("Available disks")
print()

disk_list = list_disks()
if not disk_list:
    die("No disks found")

disk_locations = {}
print(f"  {'#':<5} {'DEVICE':<14} {'SIZE':<14} {'TYPE':<12} NAME")
print(f"  {'─':<5} {'──────────':<14} {'──────────':<14} {'──────────':<12} ────")

for i, dev in enumerate(disk_list):
    loc   = disk_location(dev)
    size  = disk_size_human(dev)
    model = disk_model(dev)
    disk_locations[dev] = loc
    row = f"  {i+1:<5} {dev:<14} {size:<14} {loc:<12} {model}"
    _p(row, YELLOW) if loc == "Internal" else print(row)

print()

target_disk = args.disk
if not target_disk:
    sel = input_prompt("Select disk number")
    if not sel.isdigit() or not (1 <= int(sel) <= len(disk_list)):
        die(f"Invalid selection: {sel}")
    target_disk = disk_list[int(sel) - 1]

if not os.path.exists(target_disk):
    die(f"Not a block device: {target_disk}")

disk_bytes = disk_size_bytes(target_disk)
if disk_bytes < 8 * 1024**3:
    die(f"{target_disk} is too small — need at least 8 GB")

print()
_p(f"  Target: {target_disk} — {disk_size_human(target_disk)} — {disk_locations[target_disk]}", BOLD)

##
## Flavor selection
##

p_info("Fetching available flavors")
p_step("Loading metadata from latest release...")

try:
    with urllib.request.urlopen(
        f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest",
        timeout=15,
    ) as resp:
        release = json.load(resp)

    meta_url = next(
        a["browser_download_url"]
        for a in release.get("assets", [])
        if a["name"] == "metadata.json"
    )
    with urllib.request.urlopen(meta_url, timeout=15) as resp:
        metadata = json.load(resp)
except StopIteration:
    die("No metadata.json in latest release — run the build workflow first")
except Exception as exc:
    die(f"Could not fetch metadata: {exc}")

entries = metadata.get("all", [])
if not entries:
    die("No flavors in metadata.json — run the build workflow first")

p_ok("Metadata loaded")
p_info("Select Ubuntu flavor")
print()

for i, entry in enumerate(entries):
    print(f"  {i+1}  {entry['name']}")
print()

selected = None
if args.flavor:
    for entry in entries:
        if args.flavor.lower() in entry["name"].lower():
            selected = entry
            break
    if not selected:
        die(f"Unknown flavor: {args.flavor}")
else:
    sel = input_prompt("Flavor number")
    if not sel.isdigit() or not (1 <= int(sel) <= len(entries)):
        die(f"Invalid selection: {sel}")
    selected = entries[int(sel) - 1]

p_ok(f"Flavor: {selected['name']}")

##
## Download
##

p_info("Downloading rootfs")

work_dir = tempfile.mkdtemp(prefix="t2-ubuntu-")
atexit.register(lambda: shutil.rmtree(work_dir, ignore_errors=True))

parts = []
for url in selected["iso"]:
    fname = os.path.join(work_dir, os.path.basename(url))
    p_step(f"Downloading {os.path.basename(url)}...")
    run("curl", "-fL", "--progress-bar", "-o", fname, url)
    parts.append(fname)

expected_sha = selected.get("sha256", "")
if expected_sha and not dry_run:
    p_step("Verifying SHA256...")
    h = hashlib.sha256()
    for part in parts:
        with open(part, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    if h.hexdigest() != expected_sha:
        die(f"SHA256 mismatch\n  expected: {expected_sha}\n  got:      {h.hexdigest()}")
    p_ok("SHA256 verified")
elif not expected_sha:
    p_warning("No SHA256 in metadata — skipping verification")

##
## Write
##

parts_q = " ".join(f"'{p}'" for p in parts)

if disk_locations[target_disk] == "Internal":

    ##
    ## Internal — dual-boot
    ##

    p_info("Internal disk — dual-boot setup")

    efi_id  = find_partition(target_disk, "Linux_EFI")
    root_id = find_partition(target_disk, "Linux_Root")

    if efi_id and root_id:
        print()
        print(diskutil_list_text(target_disk))
        p_warning(f"Existing Linux install found: EFI={efi_id}  Root={root_id}")
        print()
        _p("  The existing Linux partitions will be overwritten.", BOLD, RED)
        if input_prompt("Type 'yes' to replace") != "yes":
            die("Aborted")

    else:
        apfs_id = find_partition(target_disk, "Apple_APFS")
        if not apfs_id:
            die(f"Could not find macOS APFS container on {target_disk}")

        apfs_bytes = disk_size_bytes(f"/dev/{apfs_id}")
        print()
        print(diskutil_list_text(target_disk))
        print()
        print(f"  macOS container : {ssize(apfs_bytes)}")
        print(f"  Total disk      : {ssize(disk_bytes)}")
        print()

        linux_input = input_prompt("Space to allocate to Linux (e.g. 50G, 80G)")
        m = re.match(r"^([0-9.]+)\s*([TGMB]i?B?)$", linux_input.strip(), re.IGNORECASE)
        if not m:
            die(f"Invalid size: {linux_input}")
        n, unit = float(m.group(1)), m.group(2).upper().rstrip("B").rstrip("I")
        linux_bytes = int(n * {"T": 1e12, "G": 1e9, "M": 1e6}.get(unit[0], 1e9))
        new_apfs_bytes = disk_bytes - linux_bytes

        if new_apfs_bytes < 20 * 1_000**3:
            die(f"macOS would only have {ssize(new_apfs_bytes)} — leave at least 20 GB")
        if linux_bytes < 8 * 1024**3:
            die("Linux allocation too small — need at least 8 GB")

        print()
        print(f"  macOS shrinks to : {ssize(new_apfs_bytes)}")
        print(f"  Linux receives   : {ssize(linux_bytes)}  (512 MB EFI + rest as root)")
        print()
        if input_prompt("Confirm? [y/N]").lower() != "y":
            die("Aborted")

        p_step("Resizing macOS APFS container...")
        run("diskutil", "apfs", "resizeContainer", f"/dev/{apfs_id}", f"{new_apfs_bytes}b")

        p_step("Creating Linux EFI partition (512 MB)...")
        run("diskutil", "addPartition", f"/dev/{apfs_id}", "MS-DOS FAT32", "Linux_EFI", "512M")
        efi_id = find_partition(target_disk, "Linux_EFI")
        if not efi_id:
            die("Failed to create EFI partition")

        p_step("Creating Linux root partition...")
        run("diskutil", "addPartition", f"/dev/{efi_id}", "MS-DOS FAT32", "Linux_Root", "0b")
        root_id = find_partition(target_disk, "Linux_Root")
        if not root_id:
            die("Failed to create root partition")

    run("diskutil", "unmount", f"/dev/{efi_id}",  check=False)
    run("diskutil", "unmount", f"/dev/{root_id}", check=False)

    image_file = os.path.join(work_dir, "disk.img")
    p_step("Reassembling image...")
    run_shell(f"cat {parts_q} | xz -d > '{image_file}'")

    p_step("Attaching disk image...")
    if not dry_run:
        img_disk = subprocess.run(
            ["hdiutil", "attach", "-nomount",
             "-imagekey", "diskimage-class=CRawDiskImage", image_file],
            capture_output=True, text=True, check=True,
        ).stdout.split()[0]

        efi_src  = find_partition(img_disk, "EFI")
        root_src = find_partition(img_disk, "Linux")
        if not efi_src or not root_src:
            subprocess.run(["hdiutil", "detach", img_disk], check=False)
            die("Could not identify EFI + root partitions in disk image")

        try:
            p_step(f"Writing EFI  /dev/{efi_src} → /dev/r{efi_id}")
            subprocess.run(["dd", f"if=/dev/r{efi_src}", f"of=/dev/r{efi_id}", "bs=4m"], check=True)
            p_ok("EFI written")

            p_step(f"Writing root /dev/{root_src} → /dev/r{root_id}")
            subprocess.run(["dd", f"if=/dev/r{root_src}", f"of=/dev/r{root_id}", "bs=4m"], check=True)
            p_ok("Root written")
        finally:
            subprocess.run(["hdiutil", "detach", img_disk], check=False)

    subprocess.run(["sync"])

else:

    ##
    ## External — full wipe
    ##

    p_info(f"Writing image to {target_disk}")

    if "linux" in diskutil_list_text(target_disk).lower():
        p_warning("Existing Linux install detected — it will be replaced")

    print()
    _p(f"  All data on {target_disk} will be permanently erased.", BOLD, RED)
    if input_prompt("Type 'yes' to confirm") != "yes":
        die("Aborted")

    raw_disk = target_disk.replace("/dev/disk", "/dev/rdisk")
    run("diskutil", "unmountDisk", target_disk)

    p_step("Reassembling and writing (~8–20 GB depending on flavor)...")
    if pv_available:
        run_shell(f"cat {parts_q} | xz -d | pv | dd of='{raw_disk}' bs=4m")
    else:
        p_warning("pv not found — no progress display (brew install pv to enable)")
        run_shell(f"cat {parts_q} | xz -d | dd of='{raw_disk}' bs=4m")

    subprocess.run(["sync"])
    p_ok("Image written")

##
## Done
##

print()
_p("  ✓ Installation complete!", BOLD, GREEN)
print()

if disk_locations[target_disk] == "Internal":
    print("  Next steps:")
    print("    1. Restart and hold Option (⌥) to select Ubuntu")
    print("    2. Default login: ubuntu")
    print("    3. On first boot, run:  sudo apple-get-firmware")
    print("       to extract WiFi/Bluetooth firmware from macOS")
else:
    print("  Next steps:")
    print(f"    1. Eject:              diskutil eject {target_disk}")
    print("    2. Hold Option (⌥) at startup to select the drive")
    print("    3. Default login:      ubuntu")
    print("    4. On first boot, run: sudo apple-get-firmware")
print()
