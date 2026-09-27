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
OTP_COMPONENTS = {
    "asn1-5.4.3", "compiler-9.0.6.2", "crypto-5.8.3.3", "erts-16.4.0.6",
    "inets-9.6.2.3", "kernel-10.6.3.4", "public_key-1.20.3.4",
    "sasl-4.3.2", "ssl-11.6.0.5", "stdlib-7.3.0.2",
}
ELIXIR_COMPONENTS = {"elixir-1.19.6", "iex-1.19.6", "logger-1.19.6"}
PINNED_LICENSE_INPUTS = {
    "otp": (
        "docs/provenance/license-inputs/otp-28.5.0.6-LICENSE.txt",
        "809fa1ed21450f59827d1e9aec720bbc4b687434fa22283c6cb5dd82a47ab9c0",
    ),
    "elixir": (
        "docs/provenance/license-inputs/elixir-1.19.6-LICENSE",
        "a6cba85bc92e0cff7a450b1d873c0eaa2e9fc96bf472df0247a26bec77bf3ff9",
    ),
}
PACKAGE_NOTICE_INPUTS = {
    "db_connection-2.10.2": {
        "README.md": "457f9fa82cc8f0df65a7e294d5d9f04e487b265ecb5e592309601f72f637f707",
        "hex_metadata.config": "e4b67e7e2e28998a24fded745ebbc9dfebc051a532f4b597fca581039535fced",
    },
    "rustler_precompiled-0.9.0": {
        "README.md": "4eb98404fd972d657361ca4a3e3f7caf155ae0f90dcbbb64bc7a58640622e76e",
        "hex_metadata.config": "2dd54885675a4ace0e1125e5d2d459c8261873d89917ba200194bbbfb12c14a2",
    },
}


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
    if relative == "bin/wotex_home_cli":
        return "home-cli"
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

    if component in PACKAGE_NOTICE_INPUTS:
        paths = []
        package = source / "deps" / name
        for filename, expected_hash in PACKAGE_NOTICE_INPUTS[component].items():
            path = package / filename
            if not path.is_file() or path.is_symlink():
                return []
            if sha256(path) != expected_hash:
                raise ValueError(f"pinned {component} notice input differs: {filename}")
            paths.append({"path": path.relative_to(source).as_posix(), "sha256": expected_hash})
        return paths
    elif component in OTP_COMPONENTS or component in ELIXIR_COMPONENTS or component == "release-wrapper":
        families = (
            ["otp", "elixir"] if component == "release-wrapper" else
            ["otp" if component in OTP_COMPONENTS else "elixir"]
        )
        inputs = []
        for family in families:
            relative, expected_hash = PINNED_LICENSE_INPUTS[family]
            path = source / relative
            if not path.is_file() or path.is_symlink():
                return []
            if sha256(path) != expected_hash:
                raise ValueError(f"pinned {family} license input differs: {relative}")
            inputs.append({"path": relative, "sha256": expected_hash})
        return inputs
    elif name == "maude-bundled":
        candidate_paths = [source / "vendor/ex_maude/THIRD_PARTY_NOTICES.md"]
    elif name == "ex_maude":
        candidate_paths = [source / "vendor/ex_maude/LICENSE", source / "vendor/ex_maude/THIRD_PARTY_NOTICES.md"]
    elif name == "wotex_home" or component == "home-cli":
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
        notice_only = name == "maude-bundled" or name in PACKAGE_NOTICE_INPUTS
        input_status = "notice_only" if notice_only and inputs else (
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
