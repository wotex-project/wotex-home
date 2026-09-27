#!/usr/bin/env python3
"""Check the built Pi 4 development image's host-independent packaging gates.

This inspects the cross-built release tree and firmware file. It cannot prove
that the firmware boots, survives a power cut, or runs on an actual board.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from release_components import APACHE_LICENSE_INPUT, MAUDE_LICENSE_INPUT, MAUDE_NOTICE_INPUT


MAX_FILES = 10_000
MAX_RELEASE_BYTES = 1_073_741_824
MAX_FIRMWARE_BYTES = 536_870_912
MACHO_MAGIC = {
    bytes.fromhex(value)
    for value in ("feedface", "feedfacf", "cefaedfe", "cffaedfe")
}
FOREIGN_MAUDE = {
    "maude-darwin-arm64", "maude-darwin-x64", "maude-linux-x64", "maude_bridge"
}
NODE_FLAG = re.compile(r"(?m)^\s*-(?:name|sname|proto_dist|start_epmd)\b")
MAX_FWUP_METADATA_BYTES = 131_072
MAX_AUTOBOOT_BYTES = 512
MAX_FIRMWARE_MEMBERS = 10_000
MAX_ROOTFS_BYTES = 134_217_728


def firmware_update_layout(firmware: Path) -> str:
    """Check the bounded fwup plan shipped in this exact firmware archive."""
    with zipfile.ZipFile(firmware) as archive:
        members = archive.infolist()
        if len(members) > MAX_FIRMWARE_MEMBERS:
            raise ValueError("firmware archive has too many members")
        names = [member.filename for member in members]
        required = ("meta.conf", "data/autoboot-a.txt", "data/autoboot-b.txt")
        if any(names.count(name) != 1 for name in required):
            raise ValueError("firmware update metadata or autoboot resource is missing")
        sizes = (MAX_FWUP_METADATA_BYTES, MAX_AUTOBOOT_BYTES, MAX_AUTOBOOT_BYTES)
        if any(archive.getinfo(name).file_size > size for name, size in zip(required, sizes)):
            raise ValueError("firmware update metadata exceeds the development bound")
        metadata = archive.read("meta.conf").decode("utf-8")
        autoboot = [archive.read(name).decode("utf-8") for name in required[1:]]

    if "meta-platform=rpi4" not in metadata.splitlines():
        raise ValueError("firmware metadata is not for Raspberry Pi 4")
    for name, content in zip(("a", "b"), autoboot):
        if "tryboot_a_b=1" not in content.splitlines() or "[tryboot]" not in content.splitlines():
            raise ValueError(f"firmware autoboot {name} lacks tryboot selection")

    tasks = re.split(r'(?m)^task "([^"]+)" \{\s*$', metadata)
    task_bodies = dict(zip(tasks[1::2], tasks[2::2]))
    for target, previous in (("a", "b"), ("b", "a")):
        body = task_bodies.get(f"upgrade.{target}")
        if body is None or not all(
            token in body for token in (
                f"{previous}.nerves_fw_validated,1",
                f"{target}.nerves_fw_validated,0",
                'reboot_param,"0 tryboot"',
            )
        ):
            raise ValueError(f"firmware upgrade.{target} lacks validated-source tryboot plan")
    return "both_upgrade_slots_require_valid_source_and_tryboot"


def firmware_data_path(firmware: Path) -> str:
    """Verify that Home's /data path resolves to the selected writable mount."""
    with zipfile.ZipFile(firmware) as archive:
        names = [member.filename for member in archive.infolist()]
        if names.count("data/rootfs.img") != 1:
            raise ValueError("firmware root filesystem is missing")
        rootfs_info = archive.getinfo("data/rootfs.img")
        if not 0 < rootfs_info.file_size <= MAX_ROOTFS_BYTES:
            raise ValueError("firmware root filesystem exceeds the development bound")
        metadata = archive.read("meta.conf").decode("utf-8")
        if not all(
            f'{slot}.nerves_fw_application_part0_target,"/root"' in metadata
            for slot in ("a", "b")
        ):
            raise ValueError("firmware writable application mount is not /root")
        with tempfile.TemporaryDirectory(prefix="wotex-nerves-rootfs-") as directory:
            rootfs = Path(directory) / "rootfs.img"
            with archive.open(rootfs_info) as source, rootfs.open("wb") as destination:
                shutil.copyfileobj(source, destination, length=1024 * 1024)
            result = subprocess.run(
                ["unsquashfs", "-ll", str(rootfs), "data", "root"],
                capture_output=True, text=True, check=True, timeout=30,
            )
            firmware_legal_inputs(rootfs)

    entries = result.stdout.splitlines()
    data = [line for line in entries if " squashfs-root/data -> " in line]
    root = [line for line in entries if line.endswith(" squashfs-root/root")]
    if len(data) != 1 or not data[0].startswith("l") or not data[0].endswith(" -> root") or \
            len(root) != 1 or not root[0].startswith("d"):
        raise ValueError("firmware /data does not resolve to the writable /root mount")
    return "data_symlink_to_root_writable_application_mount"


def firmware_legal_inputs(rootfs: Path) -> None:
    """Check legal payload bytes in the built SquashFS, not only its release tree."""
    expected = {
        "srv/erlang/lib/ex_maude-0.4.3/priv/maude/COPYING": MAUDE_LICENSE_INPUT[1],
        "srv/erlang/lib/ex_maude-0.4.3/priv/maude/THIRD_PARTY_NOTICES.md":
            MAUDE_NOTICE_INPUT[1],
        "srv/erlang/lib/db_connection-2.10.2/priv/LICENSE": APACHE_LICENSE_INPUT[1],
        "srv/erlang/lib/rustler_precompiled-0.9.0/priv/LICENSE": APACHE_LICENSE_INPUT[1],
    }
    for relative, digest in expected.items():
        listing = subprocess.run(
            ["unsquashfs", "-ll", str(rootfs), relative],
            capture_output=True, text=True, check=True, timeout=30,
        ).stdout
        matches = [line for line in listing.splitlines()
                   if line.endswith(" squashfs-root/" + relative)]
        fields = matches[0].split() if len(matches) == 1 else []
        if len(fields) < 6 or not fields[0].startswith("-") or \
                not fields[2].isdigit() or not 0 < int(fields[2]) <= 20_000:
            raise ValueError(f"firmware legal input missing or oversized: {relative}")
        data = subprocess.run(
            ["unsquashfs", "-cat", str(rootfs), relative],
            capture_output=True, check=True, timeout=30,
        ).stdout
        if len(data) != int(fields[2]) or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"firmware legal input differs: {relative}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def elf_machine(path: Path) -> int:
    with path.open("rb") as stream:
        header = stream.read(20)
    if len(header) < 20 or header[:4] != b"\x7fELF" or header[4:6] != b"\x02\x01":
        raise ValueError(f"expected 64-bit little-endian ELF: {path.name}")
    return int.from_bytes(header[18:20], "little")


def one(paths: list[Path], description: str) -> Path:
    if len(paths) != 1:
        raise ValueError(f"expected one {description}, found {len(paths)}")
    return paths[0]


def check(release: Path, firmware: Path) -> dict:
    if release.is_symlink() or not release.is_dir():
        raise ValueError("release tree is unavailable")
    if firmware.is_symlink() or not firmware.is_file() or firmware.suffix != ".fw":
        raise ValueError("firmware file is unavailable")
    firmware_bytes = firmware.stat().st_size
    if firmware_bytes < 1 or firmware_bytes > MAX_FIRMWARE_BYTES:
        raise ValueError("firmware size is outside the development bound")
    update_layout = firmware_update_layout(firmware)
    data_path = firmware_data_path(firmware)

    beam = one(list(release.glob("erts-*/bin/beam.smp")), "ERTS executable")
    if elf_machine(beam) != 183:
        raise ValueError("ERTS is not AArch64")
    vm_args = one(list(release.glob("releases/*/vm.args")), "VM arguments")
    if vm_args.is_symlink() or vm_args.stat().st_size > 16_384:
        raise ValueError("VM arguments are unavailable or overlong")
    if NODE_FLAG.search(vm_args.read_text(encoding="utf-8")):
        raise ValueError("firmware enables an Erlang network node")

    sys_config = one(list(release.glob("releases/*/sys.config")), "release configuration")
    if sys_config.is_symlink() or sys_config.stat().st_size > 262_144:
        raise ValueError("release configuration is unavailable or overlong")
    config = sys_config.read_text(encoding="utf-8")
    network_settings = (
        "'Elixir.VintageNetEthernet'",
        "eth0",
        "method=>dhcp",
        "{persistence,'Elixir.VintageNet.Persistence.Null'}",
    )
    probes = re.findall(r"\{internet_host_list,\[([^\]]*)\]\}", config)
    if not all(setting in config for setting in network_settings) or \
            probes != ["{{127,0,0,1},1}"]:
        raise ValueError("wired LAN configuration or local-only probe is missing")
    if len(list(release.glob("lib/vintage_net-[0-9]*"))) != 1 or \
            len(list(release.glob("lib/vintage_net_ethernet-[0-9]*"))) != 1:
        raise ValueError("wired LAN applications are not packaged")
    if any(any(release.glob(f"lib/{app}-[0-9]*")) for app in
           ("nerves_pack", "nerves_ssh", "mdns_lite", "nerves_hub_link",
            "vintage_net_wifi", "nerves_time")):
        raise ValueError("remote administration or discovery application is packaged")

    files = 0
    total_bytes = 0
    elf_files = 0
    maude_dirs = list(release.glob("lib/ex_maude-*/priv"))
    maude_priv = one(maude_dirs, "ex_maude private directory")
    maude_license = maude_priv / "maude/COPYING"
    maude_notice = maude_priv / "maude/THIRD_PARTY_NOTICES.md"
    if maude_license.is_symlink() or not maude_license.is_file() or \
            maude_license.stat().st_size > 20_000 or \
            sha256(maude_license) != MAUDE_LICENSE_INPUT[1] or \
            maude_notice.is_symlink() or not maude_notice.is_file() or \
            maude_notice.stat().st_size > 4_096 or \
            sha256(maude_notice) != MAUDE_NOTICE_INPUT[1]:
        raise ValueError("Maude standard-library legal inputs are missing")
    for package in ("db_connection-2.10.2", "rustler_precompiled-0.9.0"):
        apache = release / "lib" / package / "priv/LICENSE"
        if apache.is_symlink() or not apache.is_file() or \
                apache.stat().st_size > 20_000 or \
                sha256(apache) != APACHE_LICENSE_INPUT[1]:
            raise ValueError(f"Apache license input is missing for {package}")
    for path in release.rglob("*"):
        if path.is_symlink():
            raise ValueError("release tree contains a symlink")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError("release tree contains a nonregular entry")
        files += 1
        total_bytes += path.stat().st_size
        if files > MAX_FILES or total_bytes > MAX_RELEASE_BYTES:
            raise ValueError("release tree exceeds development bound")
        if path.name in FOREIGN_MAUDE:
            raise ValueError("foreign Maude executable remains in ARM release")
        with path.open("rb") as stream:
            header = stream.read(20)
        if header[:4] in MACHO_MAGIC:
            raise ValueError("Mach-O executable remains in ARM release")
        if header[:4] == b"\x7fELF":
            if len(header) < 20 or header[4:6] != b"\x02\x01" or \
                    int.from_bytes(header[18:20], "little") != 183:
                raise ValueError("non-AArch64 ELF remains in ARM release")
            if any(path.is_relative_to(directory) for directory in maude_dirs):
                raise ValueError("unqualified ARM Maude executable remains in release")
            elf_files += 1

    return {
        "firmware_sha256": sha256(firmware),
        "firmware_bytes": firmware_bytes,
        "release_files": files,
        "aarch64_elf_files": elf_files,
        "erlang_distribution": "not_configured_in_vm_args",
        "wired_network": "eth0_dhcp_loopback_probe",
        "firmware_update_layout": update_layout,
        "home_data_path": data_path,
        "remote_administration": "not_packaged",
        "maude_backend": "not_packaged",
        "scope": "cross_build_packaging_only",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", type=Path)
    parser.add_argument("firmware", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(check(args.release, args.firmware), sort_keys=True))
    except (OSError, UnicodeError, ValueError, zipfile.BadZipFile,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"Nerves image check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
