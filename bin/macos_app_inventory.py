#!/usr/bin/env python3
"""Create or verify the unsigned macOS app's complete regular-file inventory."""

import argparse
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
from pathlib import Path

import release_inventory

REPORT = "Contents/Resources/app-inventory.json"
RELEASE = "Contents/Resources/WotexHomeRelease"
REQUIRED = {
    "Contents/Info.plist",
    "Contents/Resources/app.spdx.json",
    "Contents/MacOS/WotexHome",
    "Contents/MacOS/WotexHomeAgent",
    "Contents/Library/LaunchAgents/org.wotex.home.agent.plist",
    f"{RELEASE}/release-inventory.json",
    f"{RELEASE}/release-components.json",
    f"{RELEASE}/release.spdx.json",
    f"{RELEASE}/bin/wotex_home",
}
MAX_FILES = 20_000
MAX_BYTES = 2_147_483_648


def source_revision(source: Path) -> str:
    status = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=normal"],
        cwd=source, check=True, capture_output=True, text=True,
    ).stdout
    if status.strip():
        raise ValueError("source tree is dirty; commit before app inventory creation")
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=source, check=True,
        capture_output=True, text=True,
    ).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("invalid source revision")
    return revision


def entries(app: Path) -> list[dict]:
    found = []
    total_bytes = 0
    for directory, names, files in os.walk(app, followlinks=False):
        names.sort()
        files.sort()
        for name in names + files:
            path = Path(directory) / name
            relative = path.relative_to(app).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise ValueError(f"symlink in app: {relative}")
            if stat.S_ISDIR(info.st_mode):
                continue
            if not stat.S_ISREG(info.st_mode):
                raise ValueError(f"nonregular app entry: {relative}")
            if relative == REPORT:
                continue
            total_bytes += info.st_size
            if len(found) >= MAX_FILES or total_bytes > MAX_BYTES:
                raise ValueError("app inventory limit exceeded")
            found.append({
                "path": relative,
                "size": info.st_size,
                "mode": stat.S_IMODE(info.st_mode),
                "sha256": release_inventory.sha256(path),
            })
    return sorted(found, key=lambda item: item["path"])


def checked_contents(app: Path, revision: str) -> dict:
    if app.is_symlink() or not app.is_dir():
        raise ValueError("app must be a real directory")
    files = entries(app)
    paths = {item["path"] for item in files}
    if not REQUIRED <= paths:
        raise ValueError("app is missing required payload")
    by_path = {item["path"]: item for item in files}
    for executable in ["Contents/MacOS/WotexHome", "Contents/MacOS/WotexHomeAgent",
                       f"{RELEASE}/bin/wotex_home"]:
        if not by_path[executable]["mode"] & 0o111:
            raise ValueError(f"app executable has no execute permission: {executable}")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if not isinstance(info, dict) or info.get("WotexHomeSourceRevision") != revision or \
            info.get("CFBundleIdentifier") != "org.wotex.home":
        raise ValueError("app source revision differs from inventory")
    agent = plistlib.loads((app / "Contents/Library/LaunchAgents/org.wotex.home.agent.plist").read_bytes())
    if not isinstance(agent, dict) or agent.get("BundleProgram") != "Contents/MacOS/WotexHomeAgent":
        raise ValueError("agent plist points outside the bundled helper")
    release = app / RELEASE
    embedded = json.loads((release / "release-inventory.json").read_text(encoding="utf-8"))
    if not isinstance(embedded, dict) or embedded.get("source_revision") != revision:
        raise ValueError("embedded release revision differs from app")
    release_inventory.verify(release)
    return {"schema_version": 1, "source_revision": revision, "files": files}


def create(app: Path, source: Path) -> None:
    revision = source_revision(source)
    report = checked_contents(app, revision)
    destination = app / REPORT
    temporary = destination.with_name(destination.name + ".tmp")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            json.dump(report, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"inventoried {len(report['files'])} macOS app files at {revision}")


def verify(app: Path) -> None:
    destination = app / REPORT
    if destination.is_symlink() or not destination.is_file():
        raise ValueError("missing real app inventory")
    saved = json.loads(destination.read_text(encoding="utf-8"))
    if not isinstance(saved, dict) or set(saved) != {"schema_version", "source_revision", "files"} or \
            saved["schema_version"] != 1 or not isinstance(saved["source_revision"], str) or \
            not re.fullmatch(r"[0-9a-f]{40}", saved["source_revision"]):
        raise ValueError("invalid app inventory")
    if saved != checked_contents(app, saved["source_revision"]):
        raise ValueError("app differs from inventory")
    print(f"verified {len(saved['files'])} macOS app files")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["create", "verify"])
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    app = args.app.absolute()
    try:
        if args.action == "create":
            create(app, Path(__file__).resolve().parent.parent)
        else:
            verify(app)
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError,
            plistlib.InvalidFileException, TypeError) as error:
        print(f"macOS app inventory error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
