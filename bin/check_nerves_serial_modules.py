#!/usr/bin/env python3
"""Inventory USB serial modules in a Nerves system artifact before radio labs.

This checks the system root filesystem, not USB enumeration or a running board.
The selected dongle's USB identity and driver still need a physical check.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


MAX_ROOTFS_BYTES = 536_870_912
MAX_LISTING_BYTES = 8_388_608
DRIVERS = {
    "cdc_acm": "cdc-acm.ko",
    "ch341": "ch341.ko",
    "cp210x": "cp210x.ko",
    "ftdi_sio": "ftdi_sio.ko",
    "pl2303": "pl2303.ko",
}
MODULE_PATH = re.compile(r"\bsquashfs-root/lib/modules/[^\s]+/([^/\s]+\.ko)$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def check(rootfs: Path, required: list[str]) -> dict:
    if rootfs.is_symlink() or not rootfs.is_file():
        raise ValueError("system rootfs is unavailable")
    if not 0 < rootfs.stat().st_size <= MAX_ROOTFS_BYTES:
        raise ValueError("system rootfs is outside the development size bound")
    unknown = sorted(set(required) - DRIVERS.keys())
    if unknown:
        raise ValueError(f"unsupported serial driver selection: {', '.join(unknown)}")

    try:
        listing = subprocess.run(
            ["unsquashfs", "-ll", str(rootfs), "lib/modules"],
            capture_output=True,
            timeout=30,
            check=True,
        ).stdout
    except (FileNotFoundError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot list system modules: {error}") from error
    if len(listing) > MAX_LISTING_BYTES:
        raise ValueError("system module listing exceeds development bound")

    present = set()
    for line in listing.decode("utf-8").splitlines():
        match = MODULE_PATH.search(line)
        if match:
            present.add(match.group(1))

    available = {name: module in present for name, module in DRIVERS.items()}
    missing = [name for name in required if not available[name]]
    if missing:
        raise ValueError(f"selected USB serial modules missing: {', '.join(missing)}")

    return {
        "system_rootfs_sha256": sha256(rootfs),
        "serial_modules": available,
        "required_serial_drivers": required,
        "scope": "system_artifact_module_inventory_only",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rootfs", type=Path)
    parser.add_argument("--require", choices=sorted(DRIVERS), action="append", default=[])
    args = parser.parse_args()
    try:
        print(json.dumps(check(args.rootfs, args.require), sort_keys=True))
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Nerves serial module check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
