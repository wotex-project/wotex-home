#!/usr/bin/env python3
"""Inventory the components and local license inputs of an assembled release.

This is source and package evidence, not a license determination or a complete
SBOM. Missing inputs remain explicit and cannot be interpreted as clearance.
"""

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

REPORT = "release-components.json"
EXCLUDED = {REPORT, "release-inventory.json", "release.spdx.json"}
MAX_FILES = 10_000
MAX_BYTES = 1_073_741_824
APP_DIRECTORY = re.compile(r"\A(.+)-([0-9][A-Za-z0-9.+-]*)\Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def source_revision(source: Path, require_clean: bool) -> str:
    if require_clean:
        status = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=normal"],
            cwd=source,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        if status.strip():
            raise ValueError("source tree is dirty; commit before creating a component report")
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=source,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("invalid source revision")
    return revision


def component_for(relative: str) -> str:
    parts = relative.split("/")
    if len(parts) >= 3 and parts[0] == "lib":
        app = parts[1]
        if app.startswith("ex_maude-") and parts[2:5] == ["priv", "maude", "bin"]:
            return "maude-bundled"
        return app
    if parts[0].startswith("erts-"):
        return parts[0]
    return "release-wrapper"


def packaged_components(root: Path) -> dict[str, dict]:
    groups: dict[str, dict] = {}
    count = 0
    total_bytes = 0

    for directory, names, files in os.walk(root, followlinks=False):
        names.sort()
        files.sort()
        for name in names + files:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise ValueError(f"symlink in release: {relative}")
            if stat.S_ISDIR(mode):
                continue
            if not stat.S_ISREG(mode):
                raise ValueError(f"nonregular release entry: {relative}")
            if relative in EXCLUDED:
                continue
            count += 1
            total_bytes += path.stat().st_size
            if count > MAX_FILES or total_bytes > MAX_BYTES:
                raise ValueError("release component limit exceeded")
            component = component_for(relative)
            group = groups.setdefault(component, {"files": [], "bytes": 0})
            group["files"].append((relative, sha256(path)))
            group["bytes"] += path.stat().st_size

    if count == 0:
        raise ValueError("empty release")
    return groups


def license_inputs(source: Path, component: str) -> list[dict]:
    candidate_paths: list[Path] = []
    match = APP_DIRECTORY.fullmatch(component)
    name = match.group(1) if match else component

    if name == "maude-bundled":
        candidate_paths = [source / "vendor/ex_maude/THIRD_PARTY_NOTICES.md"]
    elif name == "ex_maude":
        candidate_paths = [source / "vendor/ex_maude/LICENSE", source / "vendor/ex_maude/THIRD_PARTY_NOTICES.md"]
    elif name == "wotex_home":
        candidate_paths = [source / "LICENSE"]
    elif (source / "deps" / name).is_dir():
        package = source / "deps" / name
        candidate_paths = sorted(
            path for path in package.iterdir()
            if path.is_file() and re.match(r"(?i)\A(?:LICENSE|LICENCE|COPYING|NOTICE)(?:[._-].*)?\Z", path.name)
        )

    return [
        {"path": path.relative_to(source).as_posix(), "sha256": sha256(path)}
        for path in candidate_paths
        if path.is_file() and not path.is_symlink()
    ]


def report(root: Path, source: Path, revision: str) -> dict:
    groups = packaged_components(root)
    components = []
    for name, group in sorted(groups.items()):
        files = sorted(group["files"])
        fingerprint = hashlib.sha256(
            json.dumps(files, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        inputs = license_inputs(source, name)
        input_status = "notice_only" if name == "maude-bundled" and inputs else (
            "present" if inputs else "missing"
        )
        components.append(
            {
                "name": name,
                "file_count": len(files),
                "bytes": group["bytes"],
                "files_sha256": fingerprint,
                "license_inputs": inputs,
                "license_input_status": input_status,
            }
        )
    return {
        "schema_version": 2,
        "source_revision": revision,
        "scope": "packaged_regular_files_and_local_license_inputs",
        "license_review": "unresolved",
        "excluded_reports": sorted(EXCLUDED),
        "file_count": sum(component["file_count"] for component in components),
        "components": components,
    }


def run(action: str, root: Path, source: Path) -> None:
    if root.is_symlink() or not root.is_dir():
        raise ValueError("release_root must be a real directory")
    revision = source_revision(source, require_clean=action == "create")
    expected = report(root, source, revision)
    destination = root / REPORT
    if action == "create":
        temporary = root / (REPORT + ".tmp")
        try:
            with temporary.open("x", encoding="utf-8") as stream:
                json.dump(expected, stream, sort_keys=True, separators=(",", ":"))
                stream.write("\n")
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
        print(f"mapped {expected['file_count']} release files to {len(expected['components'])} components")
    else:
        actual = json.loads(destination.read_text(encoding="utf-8"))
        if actual != expected:
            raise ValueError("release components or license inputs differ from report")
        print(f"verified {expected['file_count']} component-mapped release files")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["create", "verify"])
    parser.add_argument("release_root", type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    try:
        run(args.action, args.release_root.absolute(), source)
    except (ValueError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"release component error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
