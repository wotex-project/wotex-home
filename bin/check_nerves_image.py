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

    beam = one(list(release.glob("erts-*/bin/beam.smp")), "ERTS executable")
    if elf_machine(beam) != 183:
        raise ValueError("ERTS is not AArch64")
    vm_args = one(list(release.glob("releases/*/vm.args")), "VM arguments")
    if vm_args.is_symlink() or vm_args.stat().st_size > 16_384:
        raise ValueError("VM arguments are unavailable or overlong")
    if NODE_FLAG.search(vm_args.read_text(encoding="utf-8")):
        raise ValueError("firmware enables an Erlang network node")

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
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Nerves image check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
