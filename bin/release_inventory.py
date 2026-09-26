#!/usr/bin/env python3
"""Create or verify a deterministic inventory of an assembled Home release.

The inventory is an integrity input for a later signed artifact, not a signature
or license SBOM. The manifest itself is excluded from the file list.
"""

import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

MANIFEST = "release-inventory.json"
MAX_FILES = 10_000
MAX_BYTES = 1_073_741_824


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def entries(root: Path) -> list[dict]:
    found = []
    total_bytes = 0

    for directory, names, files in os.walk(root, followlinks=False):
        names.sort()
        files.sort()
        for name in names + files:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise ValueError(f"symlink in release: {relative}")
            if stat.S_ISDIR(info.st_mode):
                continue
            if not stat.S_ISREG(info.st_mode):
                raise ValueError(f"nonregular file in release: {relative}")
            if relative == MANIFEST:
                continue
            total_bytes += info.st_size
            if len(found) >= MAX_FILES or total_bytes > MAX_BYTES:
                raise ValueError("release inventory limit exceeded")
            found.append(
                {
                    "path": relative,
                    "size": info.st_size,
                    "mode": stat.S_IMODE(info.st_mode),
                    "sha256": sha256(path),
                }
            )

    return sorted(found, key=lambda item: item["path"])


def source_revision() -> str:
    project = Path(__file__).resolve().parent.parent
    status = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=normal"],
        cwd=project,
        check=True,
        capture_output=True,
        text=True,
    )
    if status.stdout.strip():
        raise ValueError("source tree is dirty; commit before inventory creation")
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=project,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if len(revision) != 40:
        raise ValueError("invalid source revision")
    return revision


def create(root: Path) -> None:
    manifest = root / MANIFEST
    contents = {
        "schema_version": 1,
        "source_revision": source_revision(),
        "files": entries(root),
    }
    if not contents["files"]:
        raise ValueError("empty release")
    temporary = root / (MANIFEST + ".tmp")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            json.dump(contents, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
        os.replace(temporary, manifest)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"inventoried {len(contents['files'])} release files at {contents['source_revision']}")


def verify(root: Path) -> None:
    manifest = root / MANIFEST
    data = json.loads(manifest.read_text(encoding="utf-8"))
    if (
        not isinstance(data, dict)
        or set(data) != {"schema_version", "source_revision", "files"}
        or data["schema_version"] != 1
        or not isinstance(data["source_revision"], str)
        or len(data["source_revision"]) != 40
        or not isinstance(data["files"], list)
        or not data["files"]
    ):
        raise ValueError("invalid release inventory")
    if data["files"] != entries(root):
        raise ValueError("release differs from inventory")
    print(f"verified {len(data['files'])} release files")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["create", "verify"])
    parser.add_argument("release_root", type=Path)
    args = parser.parse_args()
    root = args.release_root.absolute()
    if root.is_symlink() or not root.is_dir():
        parser.error("release_root must be a real directory")
    try:
        if args.action == "create":
            create(root)
        else:
            verify(root)
    except (ValueError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"release inventory error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
