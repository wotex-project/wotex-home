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
import sys
import zipfile


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
    one(maude_dirs, "ex_maude private directory")
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
    except (OSError, UnicodeError, ValueError, zipfile.BadZipFile) as error:
        print(f"Nerves image check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
