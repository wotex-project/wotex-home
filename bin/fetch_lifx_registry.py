#!/usr/bin/env python3
"""Provision the exact LIFX product metadata locally without tracking it in Git."""

import hashlib
import os
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

SOURCE_REVISION = "8adbe485db11621639f693f3a1510603f029c902"
EXPECTED_SHA256 = "09f6b87367ea3a974cd4be9e7a562db73e1776d012854fb487b00ac9be520360"
MAX_BYTES = 1_048_576
URL = f"https://raw.githubusercontent.com/LIFX/products/{SOURCE_REVISION}/products.json"
DESTINATION = Path(__file__).resolve().parent.parent / "priv/lifx/products.json"


def valid(data: bytes) -> bool:
    return 0 < len(data) <= MAX_BYTES and hashlib.sha256(data).hexdigest() == EXPECTED_SHA256


def main() -> int:
    if DESTINATION.exists() or DESTINATION.is_symlink():
        if (
            DESTINATION.is_symlink()
            or not DESTINATION.is_file()
            or DESTINATION.stat().st_size > MAX_BYTES
            or not valid(DESTINATION.read_bytes())
        ):
            raise ValueError("existing local registry does not match the pinned artifact")
        print(f"verified local LIFX registry: {DESTINATION}")
        return 0

    request = urllib.request.Request(URL, headers={"User-Agent": "wotex-home-artifact/1"})
    with urllib.request.urlopen(request, timeout=20) as response:
        data = response.read(MAX_BYTES + 1)
    if not valid(data):
        raise ValueError("downloaded LIFX registry exceeds the limit or has the wrong SHA-256")

    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".products-", dir=DESTINATION.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if DESTINATION.exists() or DESTINATION.is_symlink():
            raise ValueError("registry destination appeared during provisioning")
        os.link(temporary, DESTINATION)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"provisioned pinned LIFX registry: {DESTINATION}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, urllib.error.URLError) as error:
        print(f"LIFX registry provisioning failed: {error}", file=sys.stderr)
        raise SystemExit(1)
