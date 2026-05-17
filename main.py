#!/usr/bin/python3
# SPDX-License-Identifier: MIT
# Adapted from the Asahi Linux installer (https://asahilinux.org/)
import os, shlex, subprocess, sys, time, termios, json, hashlib, shutil, tempfile, atexit
import plistlib, urllib.request, urllib.error, logging
from dataclasses import dataclass, field

from util import *

PART_ALIGN        = psize("1MiB")
MIN_MACOS_VERSION = "13.5"
MIN_LINUX_SPACE   = psize("8GB")
MIN_MACOS_FREE    = psize("20GB")
EFI_SIZE          = psize("512MiB")

GITHUB_REPO = "RishonDev/ubuntu-t2-rootfs"

##
## Disk abstraction
##

@dataclass
class Partition:
    name:      str
    offset:    int
    size:      int
    free:      bool
    type:      str
    label:     str  = None
    desc:      str  = None
    container: dict = None
    index:     int  = None

class DiskUtil:
    FREE_THRESHOLD = 16 * 1024 * 1024

    def __init__(self):
        self.verbose  = "-v" in sys.argv
        self.disks    = {}
        self.disk_parts = {}

    def _get(self, *args):
        logging.debug(f"diskutil {args!r}")
        result = subprocess.run(["diskutil"] + list(args),
                                stdout=subprocess.PIPE, check=True)
        return plistlib.loads(result.stdout)

    def _run(self, *args, verbose=False):
        logging.debug(f"diskutil {args!r}")
        if verbose or self.verbose:
            subprocess.run(["diskutil"] + list(args), check=True)
        else:
            subprocess.run(["diskutil"] + list(args), check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def get_info(self):
        lst = self._get("list", "-plist")
        self.disk_parts = {d["DeviceIdentifier"]: d
                           for d in lst["AllDisksAndPartitions"]}
        for name in lst["WholeDisks"]:
            self.disks[name] = self._get("info", "-plist", name)

    def find_system_disk(self):
        for name, dsk in self.disks.items():
            try:
                if dsk.get("VirtualOrPhysical") == "Virtual":
                    continue
                if not dsk.get("Internal"):
                    continue
                # T2 Macs have a standard GPT starting with EFI
                parts = self.disk_parts[name].get("Partitions", [])
                if any(p.get("Content", "").startswith(("EFI", "Apple_APFS")) for p in parts):
                    logging.info(f"System disk: {name}")
                    return name
            except (KeyError, IndexError):
                continue
        raise Exception("Could not find system disk")

    def find_external_disks(self):
        disks = []
        for name, dsk in self.disks.items():
            try:
                if dsk.get("VirtualOrPhysical") == "Virtual":
                    continue
                if dsk.get("Internal"):
                    continue
                if not dsk.get("Writable"):
                    continue
                if not dsk.get("WholeDisk"):
                    continue
                disks.append(dsk)
            except (KeyError, IndexError):
                continue
        return disks

    def get_partitions(self, disk):
        parts   = []
        raw     = self.disk_parts.get(disk, {}).get("Partitions", [])
        disk_sz = self.disks[disk].get("TotalSize", 0)
        covered = 0

        for p in raw:
            dev  = p["DeviceIdentifier"]
            info = self._get("info", "-plist", dev)
            off  = info.get("PartitionMapPartitionOffset", covered)
            sz   = info.get("Size", 0)
            typ  = p.get("Content", "")
            lbl  = p.get("VolumeName") or p.get("VolumeName", None)

            ctnr = None
            if typ.startswith("Apple_APFS"):
                try:
                    apfs = self._get("apfs", "list", dev, "-plist")
                    ctnr = apfs["Containers"][0] if apfs.get("Containers") else None
                except Exception:
                    pass

            parts.append(Partition(
                name=dev, offset=off, size=sz, free=False,
                type=typ, label=lbl, container=ctnr,
            ))
            covered = off + sz

        # Any gap at the end is free space
        if disk_sz - covered >= self.FREE_THRESHOLD:
            parts.append(Partition(
                name="free", offset=covered, size=disk_sz - covered,
                free=True, type="free",
            ))

        return parts

    def disk_size(self, disk):
        return self.disks.get(disk, {}).get("TotalSize", 0)

    def partition_size(self, dev):
        info = self._get("info", "-plist", dev)
        return info.get("Size", 0)

    def get_resize_limits(self, dev):
        try:
            info = self._get("apfs", "resizeContainer", dev, "0", "-plist")
            return {
                "MinimumSizePreferred": info.get("APFSContainerMinimumSize", 0),
            }
        except Exception:
            return {"MinimumSizePreferred": 0}

    def resizeContainer(self, dev, size):
        self._run("apfs", "resizeContainer", dev, str(size), verbose=True)

    def addPartition(self, after, fstype, name, size):
        self._run("addPartition", after, fstype, name, str(size), verbose=True)

    def unmount(self, dev):
        subprocess.run(["diskutil", "unmount", dev],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def unmountDisk(self, dev):
        self._run("unmountDisk", dev, verbose=True)

    def find_partition_by_label(self, disk, label):
        for p in self.disk_parts.get(disk, {}).get("Partitions", []):
            if p.get("VolumeName") == label:
                return p["DeviceIdentifier"]
        return None

##
## Installer
##

class InstallerMain:
    def __init__(self):
        self.sys_disk       = None
        self.cur_disk       = None
        self.external_disks = []
        self.parts          = []
        self.dutil          = None
        self.metadata       = None
        self.work_dir       = None

    def input(self):
        self.flush_input()
        return input()

    def get_size(self, prompt, default=None, min=None, max=None, total=None):
        self.flush_input()
        if default is not None:
            prompt += f" ({default})"
        new_size = input_prompt(prompt + ": ").strip()
        try:
            if default is not None and not new_size:
                new_size = default
            if new_size.lower() == "min" and min is not None:
                val = min
            elif new_size.lower() == "max" and max is not None:
                val = max
            elif new_size.endswith("%") and total is not None:
                val = int(float(new_size[:-1]) * total / 100)
            elif new_size.endswith("B"):
                val = psize(new_size.upper())
            else:
                val = psize(new_size.upper() + "B")
        except Exception as e:
            print(e)
            val = None

        if val is None:
            p_error(f"Invalid size '{new_size}'.")

        return val

    def choice(self, prompt, options, default=None):
        is_array = False

        if isinstance(options, list):
            is_array = True
            options = {str(i + 1): v for i, v in enumerate(options)}
            if default is not None:
                default += 1

        for k, v in options.items():
            p_choice(f"  {col(BRIGHT)}{k}{col(NORMAL)}: {v}")

        if default:
            prompt += f" ({default})"

        while True:
            self.flush_input()
            res = input_prompt(prompt + ": ").strip()
            if res == "" and default is not None:
                res = str(default)
            if res not in options:
                p_warning(f"Enter one of the following: {', '.join(map(str, options.keys()))}")
                continue
            print()
            if is_array:
                return int(res) - 1
            else:
                return res

    def yesno(self, prompt, default=False):
        if default:
            prompt += " (Y/n): "
        else:
            prompt += " (y/N): "

        while True:
            self.flush_input()
            res = input_prompt(prompt).strip()
            if not res:
                return default
            elif res.lower() in ("y", "yes", "1", "true"):
                return True
            elif res.lower() in ("n", "no", "0", "false"):
                return False
            p_warning("Please enter 'Y' or 'N'")

    def flush_input(self):
        try:
            termios.tcflush(sys.stdin, termios.TCIFLUSH)
        except Exception:
            pass

    def fetch_metadata(self):
        p_progress("Fetching available OS versions from GitHub...")
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
            p_error("No metadata.json in the latest release.")
            p_message("Please run the build workflow first.")
            sys.exit(1)
        except Exception as exc:
            p_error(f"Could not fetch release metadata: {exc}")
            sys.exit(1)

        entries = metadata.get("all", [])
        if not entries:
            p_error("No OS versions found in metadata.json.")
            p_message("Please run the build workflow first.")
            sys.exit(1)

        logging.info(f"Loaded {len(entries)} OS entries from metadata")
        return metadata

    def choose_flavor(self):
        entries = self.metadata["all"]
        print()
        p_question("Choose an OS to install:")
        idx = self.choice("OS", [e["name"] for e in entries])
        entry = entries[idx]
        logging.info(f"Chosen OS: {entry['name']}")
        return entry

    def download_rootfs(self, entry):
        self.work_dir = tempfile.mkdtemp(prefix="t2-ubuntu-")
        atexit.register(lambda: shutil.rmtree(self.work_dir, ignore_errors=True))

        parts = []
        for url in entry["iso"]:
            fname = os.path.join(self.work_dir, os.path.basename(url))
            p_progress(f"Downloading {os.path.basename(url)}...")
            subprocess.run(["curl", "-fL", "--progress-bar", "-o", fname, url],
                           check=True)
            parts.append(fname)

        expected = entry.get("sha256", "")
        if expected:
            p_progress("Verifying SHA256...")
            h = hashlib.sha256()
            for part in parts:
                with open(part, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
            if h.hexdigest() != expected:
                p_error("SHA256 mismatch!")
                p_error(f"  expected: {expected}")
                p_error(f"  got:      {h.hexdigest()}")
                sys.exit(1)
            p_success("SHA256 verified.")
        else:
            p_warning("No SHA256 in metadata — skipping verification.")

        return parts

    def write_to_partitions(self, img_parts, efi_id, root_id):
        parts_q = " ".join(shlex.quote(p) for p in img_parts)
        image_file = os.path.join(self.work_dir, "disk.img")

        p_progress("Reassembling image...")
        subprocess.run(f"cat {parts_q} | xz -d > {shlex.quote(image_file)}",
                       shell=True, check=True)

        p_progress("Attaching disk image...")
        img_disk = subprocess.run(
            ["hdiutil", "attach", "-nomount",
             "-imagekey", "diskimage-class=CRawDiskImage", image_file],
            capture_output=True, text=True, check=True,
        ).stdout.split()[0]

        try:
            efi_src  = self._find_img_partition(img_disk, "EFI")
            root_src = self._find_img_partition(img_disk, "Linux")
            if not efi_src or not root_src:
                raise Exception("Could not find EFI + root partitions in disk image")

            p_progress(f"Writing EFI  /dev/{efi_src} → /dev/r{efi_id}")
            subprocess.run(["dd", f"if=/dev/r{efi_src}",
                            f"of=/dev/r{efi_id}", "bs=4m"], check=True)
            p_success("EFI written.")

            p_progress(f"Writing root /dev/{root_src} → /dev/r{root_id}")
            subprocess.run(["dd", f"if=/dev/r{root_src}",
                            f"of=/dev/r{root_id}", "bs=4m"], check=True)
            p_success("Root written.")
        finally:
            subprocess.run(["hdiutil", "detach", img_disk], check=False)

        subprocess.run(["sync"])

    def write_to_disk(self, img_parts, raw_disk):
        parts_q = " ".join(shlex.quote(p) for p in img_parts)
        pv = shutil.which("pv")

        p_progress("Reassembling and writing image (this may take a while)...")
        if pv:
            subprocess.run(f"cat {parts_q} | xz -d | pv | dd of={shlex.quote(raw_disk)} bs=4m",
                           shell=True, check=True)
        else:
            p_warning("pv not found — no progress display. Install with: brew install pv")
            subprocess.run(f"cat {parts_q} | xz -d | dd of={shlex.quote(raw_disk)} bs=4m",
                           shell=True, check=True)

        subprocess.run(["sync"])

    def _find_img_partition(self, img_disk, label):
        out = subprocess.run(["diskutil", "list", img_disk],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            if label in line:
                parts = line.split()
                if parts:
                    return parts[-1]
        return None

    def action_install_into_free(self, apfs_id, free_bytes):
        entry     = self.choose_flavor()
        img_parts = self.download_rootfs(entry)

        efi_size  = align_up(EFI_SIZE, PART_ALIGN)
        root_size = align_down(free_bytes - efi_size, PART_ALIGN)

        print()
        p_message(f"  EFI partition  : {ssize(efi_size)}")
        p_message(f"  Root partition : {ssize(root_size)}")
        print()

        p_progress("Creating Linux EFI partition (512 MiB)...")
        self.dutil.addPartition(f"/dev/{apfs_id}", "MS-DOS FAT32", "Linux_EFI", efi_size)

        efi_id = self.dutil.find_partition_by_label(self.cur_disk, "Linux_EFI")
        if not efi_id:
            p_error("Failed to create EFI partition.")
            sys.exit(1)

        p_progress("Creating Linux root partition...")
        self.dutil.addPartition(f"/dev/{efi_id}", "MS-DOS FAT32", "Linux_Root", 0)

        root_id = self.dutil.find_partition_by_label(self.cur_disk, "Linux_Root")
        if not root_id:
            p_error("Failed to create root partition.")
            sys.exit(1)

        self.dutil.unmount(f"/dev/{efi_id}")
        self.dutil.unmount(f"/dev/{root_id}")

        self.write_to_partitions(img_parts, efi_id, root_id)
        self.finish_internal()
        return False

    def action_update(self, efi_id, root_id):
        p_warning("This will overwrite your existing T2 Ubuntu installation.")
        if not self.yesno("Continue?"):
            return True

        entry     = self.choose_flavor()
        img_parts = self.download_rootfs(entry)

        self.dutil.unmount(f"/dev/{efi_id}")
        self.dutil.unmount(f"/dev/{root_id}")

        self.write_to_partitions(img_parts, efi_id, root_id)
        self.finish_internal()
        return False

    def action_resize(self, resizable):
        choices = {str(i): p.desc for i, p in enumerate(self.parts) if p in resizable}

        print()
        if len(resizable) > 1:
            p_question("Choose an existing partition to resize:")
            idx = self.choice("Partition", choices)
            target = self.parts[int(idx)]
        else:
            target = resizable[0]

        limits   = self.dutil.get_resize_limits(f"/dev/{target.name}")
        total    = target.container["CapacityCeiling"] if target.container else target.size
        free     = target.container["CapacityFree"]    if target.container else 0
        min_size = max(
            align_up(total - free + MIN_MACOS_FREE, PART_ALIGN),
            limits.get("MinimumSizePreferred", 0),
        )
        avail    = total - min_size
        min_perc = 100 * min_size / total

        p_message( "We're going to resize this partition:")
        p_message(f"  {target.desc}")
        p_info(   f"  Total size       : {col()}{ssize(total)}")
        p_info(   f"  Free space       : {col()}{ssize(free)}")
        p_info(   f"  Available to free: {col()}{ssize(avail)}")
        p_info(   f"  Minimum new size : {col()}{ssize(min_size)} ({min_perc:.2f}%)")
        print()

        if avail < MIN_LINUX_SPACE:
            p_error(f"Not enough free space — need at least {ssize(MIN_LINUX_SPACE)} for Linux.")
            return False

        print()
        p_question("Enter the new size for your macOS partition:")
        p_message( "  You can enter a size such as '80GB', a fraction such as '50%',")
        p_message( "  or 'min' to shrink as much as safely possible.")
        print()
        p_message( "  Examples:")
        p_message( "  50%   — 50% to macOS, 50% to Linux")
        p_message( "  80GB  — 80 GB to macOS, the rest to Linux")
        p_message( "  min   — Shrink macOS as much as (safely) possible")
        print()

        default = "50%"
        if total / 2 < min_size:
            default = "min"

        while True:
            val = self.get_size("New macOS size", default=default,
                                min=min_size, max=total, total=total)
            if val is None:
                continue
            val = align_up(val, PART_ALIGN)
            if val < min_size:
                p_error(f"Too small — minimum is {ssize(min_size)} ({min_perc:.2f}%)")
                continue
            if val >= total:
                p_error(f"Too large — must be less than {ssize(total)}")
                continue
            freeing = total - val
            print()
            p_message(f"Resizing will free up {ssize(freeing)} for Linux.")
            if freeing < MIN_LINUX_SPACE:
                p_error(f"That's not enough space for Linux — need at least {ssize(MIN_LINUX_SPACE)}.")
                continue
            print()
            p_message("Note: your system may appear to freeze during the resize.")
            p_message("This is normal — just wait until the process completes.")
            if self.yesno("Continue?"):
                break

        print()
        try:
            self.dutil.resizeContainer(f"/dev/{target.name}", val)
        except subprocess.CalledProcessError:
            print()
            p_error("Resize failed.")
            p_warning("This is usually caused by APFS filesystem corruption or Time Machine snapshots.")
            p_warning("Run First Aid from Disk Utility in Recovery Mode, then try again.")
            return False

        print()
        p_success("Resize complete. Press enter to continue.")
        self.input()
        print()
        return True

    def action_wipe(self):
        p_warning("This will wipe ALL data on the selected disk.")
        p_warning("Are you sure you want to continue?")
        if not self.yesno("Wipe my disk"):
            return True

        entry     = self.choose_flavor()
        img_parts = self.download_rootfs(entry)

        raw_disk = self.cur_disk.replace("/dev/disk", "/dev/rdisk")
        self.dutil.unmountDisk(self.cur_disk)
        self.write_to_disk(img_parts, raw_disk)
        self.finish_external()
        return False

    def action_select_disk(self):
        choices = {"1": "Internal storage"}
        for i, disk in enumerate(self.external_disks):
            name = disk.get("IORegistryEntryName", disk["DeviceIdentifier"])
            size = ssize(disk.get("TotalSize", 0))
            choices[str(i + 2)] = f"{name} ({size})"

        print()
        p_question("Choose a disk:")
        idx = int(self.choice("Disk", choices))
        if idx == 1:
            self.cur_disk = self.sys_disk
        else:
            self.cur_disk = self.external_disks[idx - 2]["DeviceIdentifier"]
        return True

    def finish_internal(self):
        print()
        p_success(f"{DISTRO} has been installed successfully!")
        print()
        p_message("Next steps:")
        p_plain(  "  1. Restart your Mac and hold Option (⌥) to select Ubuntu")
        p_plain(  "  2. Default login: ubuntu")
        p_plain(  "  3. On first boot, run:  sudo apple-get-firmware")
        p_plain(  "     to extract WiFi/Bluetooth firmware from macOS")
        print()
        p_prompt("Press enter to exit.")
        self.input()

    def finish_external(self):
        print()
        p_success(f"{DISTRO} has been written to {self.cur_disk} successfully!")
        print()
        p_message("Next steps:")
        p_plain( f"  1. Eject:              diskutil eject {self.cur_disk}")
        p_plain(  "  2. Hold Option (⌥) at startup to select the drive")
        p_plain(  "  3. Default login:      ubuntu")
        p_plain(  "  4. On first boot, run: sudo apple-get-firmware")
        print()
        p_prompt("Press enter to exit.")
        self.input()

    def main_loop(self):
        p_progress("Collecting partition information...")
        self.dutil = DiskUtil()
        self.dutil.get_info()

        if self.sys_disk is None:
            self.cur_disk = self.sys_disk = self.dutil.find_system_disk()

        self.external_disks = self.dutil.find_external_disks()

        p_info(f"  System disk: {col()}{self.sys_disk}")
        if self.external_disks:
            p_info(f"  External disk(s): {col()}" +
                   ", ".join(d["DeviceIdentifier"] for d in self.external_disks))

        self.parts = self.dutil.get_partitions(self.cur_disk)
        is_internal = (self.cur_disk == self.sys_disk)
        print()

        parts_resizable = []
        parts_free      = []
        linux_efi_id    = None
        linux_root_id   = None

        p_message(f"Partitions in {'system' if is_internal else 'external'} disk ({self.cur_disk}):")
        print()

        for i, p in enumerate(self.parts):
            p.index = i
            if p.free:
                p.desc = f"(free space: {ssize(p.size)})"
                if p.size >= MIN_LINUX_SPACE:
                    parts_free.append(p)
            elif p.type.startswith("Apple_APFS"):
                free  = p.container["CapacityFree"]    if p.container else 0
                total = p.container["CapacityCeiling"] if p.container else p.size
                lbl   = f" [{p.label}]" if p.label else ""
                p.desc = f"APFS{lbl} ({ssize(p.size)}, {ssize(free)} free)"
                if (p.container and free > MIN_MACOS_FREE + MIN_LINUX_SPACE):
                    parts_resizable.append(p)
            elif p.type == "EFI":
                p.desc = f"EFI ({ssize(p.size)})"
            elif p.label == "Linux_EFI":
                p.desc   = f"Linux EFI ({ssize(p.size)})"
                linux_efi_id = p.name
            elif p.label == "Linux_Root":
                p.desc    = f"Linux Root ({ssize(p.size)})"
                linux_root_id = p.name
            else:
                p.desc = f"{p.type} ({ssize(p.size)})"

            if p.desc:
                p_choice(f"  {col(BRIGHT)}{i}{col()}: {p.desc}")

        print()

        actions = {}
        default = None

        if is_internal:
            if linux_efi_id and linux_root_id:
                actions["u"] = f"Update existing {DISTRO} installation"
                default = default or "u"
            if parts_free:
                actions["f"] = f"Install {DISTRO} into free space"
                default = default or "f"
            if parts_resizable:
                actions["r"] = "Resize an existing partition to make space for a new OS"
                default = default or "r"
        else:
            actions["w"] = f"Wipe and install {DISTRO} onto the whole disk"
            default = default or "w"

        if self.external_disks:
            actions["d"] = "Select another disk for installation"

        if not actions or all(k in ("d",) for k in actions):
            p_error("No installation actions available on this disk.")
            if is_internal:
                p_message("Your macOS partition may not have enough free space to resize.")
                p_message("Try freeing up space in macOS first.")
            sys.exit(1)

        actions["q"] = "Quit without doing anything"

        print()
        p_question("Choose what to do:")
        act = self.choice("Action", actions, default)

        if act == "r":
            if self.action_resize(parts_resizable):
                return True  # re-scan after resize
        elif act == "f":
            apfs_part = next((p for p in self.parts
                              if p.type.startswith("Apple_APFS") and p not in parts_resizable), None)
            apfs_id   = apfs_part.name if apfs_part else None
            free_part = parts_free[0] if len(parts_free) == 1 else None
            if not free_part:
                p_question("Choose the free space to install into:")
                idx = self.choice("Free space",
                                  {str(i): p.desc for i, p in enumerate(self.parts) if p in parts_free})
                free_part = self.parts[int(idx)]
            return self.action_install_into_free(apfs_id, free_part.size)
        elif act == "u":
            return self.action_update(linux_efi_id, linux_root_id)
        elif act == "w":
            return self.action_wipe()
        elif act == "d":
            return self.action_select_disk()
        elif act == "q":
            return False

    def main(self):
        print()
        p_message(f"Welcome to the {DISTRO} installer!")
        print()
        p_message( "This installer will guide you through the process of setting up")
        p_message(f"{DISTRO} on your Mac.")
        print()
        p_message( "Please make sure you are familiar with the documentation at:")
        p_plain(  f"  {col(BLUE, BRIGHT)}{DISTRO_DOCS}{col()}")
        print()
        p_message( "Before proceeding, ensure your Mac has:")
        p_plain(   "  1. Reduced Security enabled")
        p_plain(   "     (macOS Recovery → Utilities → Startup Security Utility)")
        p_plain(   "  2. 'Allow booting from external media' checked (for external installs)")
        print()
        p_question("Press enter to continue.")
        self.input()
        print()

        self.metadata = self.fetch_metadata()
        print()

        while self.main_loop():
            pass


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.DEBUG,
        format="%(asctime)s %(name)-12s %(levelname)-8s %(message)s",
        datefmt="%m-%d %H:%M",
        filename="installer.log",
        filemode="w",
    )
    console = logging.StreamHandler()
    console.setLevel(logging.ERROR)
    console.setFormatter(logging.Formatter("%(name)-12s: %(levelname)-8s %(message)s"))
    logging.getLogger("").addHandler(console)
    logging.info("Startup")

    try:
        InstallerMain().main()
    except KeyboardInterrupt:
        print()
        logging.info("KeyboardInterrupt")
        p_error("Interrupted")
    except subprocess.CalledProcessError as e:
        cmd = shlex.join(e.cmd) if isinstance(e.cmd, list) else e.cmd
        p_error(f"Failed to run process: {cmd}")
        if e.output:
            p_error(f"Output: {e.output}")
        logging.exception("Process execution failed")
        p_warning("Please attach the log file if filing a bug report:")
        p_warning(f"  {os.getcwd()}/installer.log")
    except Exception:
        logging.exception("Exception caught")
        p_warning("Please attach the log file if filing a bug report:")
        p_warning(f"  {os.getcwd()}/installer.log")
