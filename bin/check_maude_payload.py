#!/usr/bin/env python3
"""Check the exact Maude 3.5.1 macOS arm64 payload against its tagged release asset.

The archive itself is optional and never copied into this repository. The
vendored and assembled release files can be checked offline from pinned hashes.
This is byte provenance, not a license or corresponding-source determination.
"""

import argparse
import hashlib
import sys
import zipfile
from pathlib import Path

ASSET_URL = "https://github.com/maude-lang/Maude/releases/download/Maude3.5.1/Maude-3.5.1-macos-arm64.zip"
ASSET_SHA256 = "95851274f57b3853aab833674e2b770ed800f38fb1f3d03c97dcac56346c13dc"
FILE_SHA256 = {
    "maude": "266eed04679fde6029a18e5e2b1828223d4a7169ac55503aa15d67e126792fbf",
    "file.maude": "6c579bc7799e08adafeb1813abd6f7f8e46cf2c6b6e7542559f38cbd331d28d0",
    "linear.maude": "5b01df9ee29d875a1cb3fd47c0fd4fce0e8de98aa694b39fad406aa7fc51f9c9",
    "machine-int.maude": "79184b2f0096d5c46ec7042bcb9d4393c4714090cf0da5fae9e7087c0ab6a6a0",
    "metaInterpreter.maude": "9da39cd94099139514bdbf22f633fbb36371568a2d99b944c8f050710c9074c6",
    "model-checker.maude": "be53123786b18da5a91ac0fa0436e1d72ec87fc76076c1a12398d4d8166948d0",
    "prelude.maude": "8f03c0be1999dfedff5fbabc1473b20359681d6cfa1dece6f47626e1a827de75",
    "prng.maude": "32735b8096c0fa034eeedabdca44ff4c460189295dd330ad50243e38518b493b",
    "process.maude": "ab3497ba8a569f7605b47f226d15f348a71ef7bea156aa9f46dc8f61a9c3f1e9",
    "smt.maude": "c711af83c8eeb29498b7885fb50cfafe95f33900659bf8405bd8d4bca63d561f",
    "socket.maude": "6f0eaaa70ff87cb49e4e1778189e4dd5a146ca75310a8691cdc10a6944f7b0c5",
    "term-order.maude": "f29c722972c95b3e698400403fb97b12b9657f202c8845d7b71baede47d88556",
    "time.maude": "19612ea37c4bff289baf70bceae38c4305c2519cb36e07c55b82a80d76be18d1",
    "maude.sty": "d8c75d6cacb478a28901c25b8a820fd8a7b28ad0672c1c77d5122e2917b83cc5",
}
MAX_FILE_BYTES = 8_000_000
MAX_ASSET_BYTES = 8_000_000


def digest(path: Path, limit: int) -> str:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise ValueError(f"missing, linked or oversized Maude file: {path.name}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_directory(directory: Path, release: bool = False) -> int:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("Maude payload directory missing or linked")
    allowed = {"maude-darwin-arm64" if name == "maude" else name for name in FILE_SHA256}
    if not release:
        allowed |= {"maude-darwin-x64", "maude-linux-x64"}
    if {path.name for path in directory.iterdir()} != allowed:
        raise ValueError("Maude payload file set differs from pinned asset")
    for name, expected in FILE_SHA256.items():
        local = directory / ("maude-darwin-arm64" if name == "maude" else name)
        if digest(local, MAX_FILE_BYTES) != expected:
            raise ValueError(f"Maude payload hash differs: {name}")
    return len(FILE_SHA256)


def check_archive(path: Path) -> int:
    if digest(path, MAX_ASSET_BYTES) != ASSET_SHA256:
        raise ValueError("Maude release archive hash differs")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(FILE_SHA256) or set(names) != set(FILE_SHA256):
            raise ValueError("Maude release archive members differ")
        for info in archive.infolist():
            if info.file_size > MAX_FILE_BYTES:
                raise ValueError("oversized Maude release archive member")
            if hashlib.sha256(archive.read(info)).hexdigest() != FILE_SHA256[info.filename]:
                raise ValueError(f"Maude release archive member differs: {info.filename}")
    return len(names)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="vendored or released priv/maude/bin")
    parser.add_argument("--release", action="store_true", help="require only arm64 files")
    parser.add_argument("--archive", type=Path, help="optional downloaded tagged release zip")
    args = parser.parse_args()
    try:
        count = check_directory(args.directory, release=args.release)
        if args.archive:
            check_archive(args.archive)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"Maude payload check failed: {error}", file=sys.stderr)
        return 1
    print(f"verified {count} Maude 3.5.1 macOS arm64 payload files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
