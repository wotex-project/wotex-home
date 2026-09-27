#!/usr/bin/env python3
"""Create or verify a file-level SPDX 2.3 JSON document for the complete macOS app."""

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import sys
import uuid
from pathlib import Path

import macos_app_inventory
import release_spdx

REPORT = "Contents/Resources/app.spdx.json"
EXCLUDED = {REPORT, macos_app_inventory.REPORT}
EMBEDDED = macos_app_inventory.RELEASE
RELEASE_REPORTS = {"release-components.json", "release.spdx.json", "release-inventory.json"}
NATIVE = {
    "Contents/MacOS/WotexHome": "macos-ui",
    "Contents/MacOS/WotexHomeAgent": "macos-agent",
    "Contents/Library/LaunchAgents/org.wotex.home.agent.plist": "macos-agent",
    "Contents/Info.plist": "app-wrapper",
}
CREATED = re.compile(r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")


def embedded_packages(app: Path, files_by_path: dict[str, dict]) -> tuple[str, dict[str, str]]:
    release_root = app / EMBEDDED
    inventory = json.loads((release_root / "release-inventory.json").read_text(encoding="utf-8"))
    document = json.loads((release_root / "release.spdx.json").read_text(encoding="utf-8"))
    if not isinstance(inventory, dict) or not isinstance(document, dict):
        raise ValueError("invalid embedded release reports")
    revision = inventory.get("source_revision")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision) or \
            document.get("spdxVersion") != "SPDX-2.3":
        raise ValueError("invalid embedded release identity")
    macos_app_inventory.release_inventory.verify(release_root)

    spdx_files = {}
    for item in document["files"]:
        spdx_id = item["SPDXID"]
        name = item["fileName"]
        checksum = item["checksums"]
        if not isinstance(name, str) or not name.startswith("./") or \
                len(checksum) != 1 or checksum[0]["algorithm"] != "SHA256":
            raise ValueError("invalid embedded SPDX file")
        path = f"{EMBEDDED}/{name[2:]}"
        if spdx_id in spdx_files or path not in files_by_path or \
                checksum[0]["checksumValue"] != files_by_path[path]["sha256"]:
            raise ValueError("embedded SPDX differs from app payload")
        spdx_files[spdx_id] = path

    assignments = {}
    package_names = set()
    for package in document["packages"]:
        name = package["name"]
        if not isinstance(name, str) or not name or name in package_names or \
                package.get("licenseConcluded") != "NOASSERTION":
            raise ValueError("invalid embedded SPDX package")
        package_names.add(name)
        for spdx_id in package["hasFiles"]:
            if spdx_id not in spdx_files or spdx_files[spdx_id] in assignments:
                raise ValueError("embedded SPDX package coverage is invalid")
            assignments[spdx_files[spdx_id]] = f"embedded-{name}"

    payload_paths = {
        path for path in files_by_path
        if path.startswith(f"{EMBEDDED}/") and
        path.removeprefix(f"{EMBEDDED}/") not in RELEASE_REPORTS
    }
    if set(assignments) != payload_paths:
        raise ValueError("embedded SPDX does not cover release payload")
    return revision, assignments


def document(app: Path, created: str) -> dict:
    if not CREATED.fullmatch(created):
        raise ValueError("invalid SPDX creation timestamp")
    inventory = [item for item in macos_app_inventory.entries(app) if item["path"] not in EXCLUDED]
    files_by_path = {item["path"]: item for item in inventory}
    revision, assignments = embedded_packages(app, files_by_path)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if not isinstance(info, dict) or info.get("WotexHomeSourceRevision") != revision:
        raise ValueError("app and release revisions differ")
    for path in files_by_path:
        if path in assignments:
            continue
        if path in NATIVE:
            assignments[path] = NATIVE[path]
        elif path.startswith(f"{EMBEDDED}/") and path.removeprefix(f"{EMBEDDED}/") in RELEASE_REPORTS:
            assignments[path] = "embedded-release-reports"
        else:
            raise ValueError(f"unmapped app file: {path}")

    file_records = []
    relationships = []
    package_members = {}
    for number, item in enumerate(inventory, 1):
        path = item["path"]
        file_id = f"SPDXRef-AppFile-{number}"
        package_name = assignments[path]
        package_members.setdefault(package_name, []).append(file_id)
        file_records.append({
            "SPDXID": file_id,
            "fileName": f"./{path}",
            "checksums": [{"algorithm": "SHA256", "checksumValue": item["sha256"]}],
            "licenseConcluded": "NOASSERTION",
            "licenseInfoInFiles": ["NOASSERTION"],
            "copyrightText": "NOASSERTION",
        })
        relationships.append({
            "spdxElementId": release_spdx.package_id(package_name),
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": file_id,
        })

    packages = []
    for name, members in sorted(package_members.items()):
        package_id = release_spdx.package_id(name)
        packages.append({
            "SPDXID": package_id,
            "name": name,
            "downloadLocation": "NOASSERTION",
            "filesAnalyzed": True,
            "hasFiles": members,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "licenseInfoFromFiles": ["NOASSERTION"],
            "copyrightText": "NOASSERTION",
        })
        relationships.append({
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": package_id,
        })

    identity = hashlib.sha256(
        (revision + json.dumps([(item["path"], item["sha256"]) for item in inventory],
                               separators=(",", ":"))).encode("utf-8")
    ).digest()
    namespace = f"urn:uuid:{uuid.UUID(bytes=identity[:16], version=5)}"
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"WoTEx Home macOS app {revision[:12]}",
        "documentNamespace": namespace,
        "creationInfo": {"created": created, "creators": ["Tool: wotex-home-macos-spdx-1"]},
        "comment": "Unsigned app file inventory. All license conclusions are NOASSERTION.",
        "documentDescribes": [item["SPDXID"] for item in packages],
        "packages": packages,
        "files": file_records,
        "relationships": relationships,
    }


def run(action: str, app: Path) -> None:
    if app.is_symlink() or not app.is_dir():
        raise ValueError("app must be a real directory")
    destination = app / REPORT
    if action == "create":
        created = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        contents = document(app, created)
        temporary = destination.with_name(destination.name + ".tmp")
        try:
            with temporary.open("x", encoding="utf-8") as stream:
                json.dump(contents, stream, sort_keys=True, separators=(",", ":"))
                stream.write("\n")
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
        print(f"created macOS SPDX document for {len(contents['files'])} app files")
    else:
        saved = json.loads(destination.read_text(encoding="utf-8"))
        created = saved["creationInfo"]["created"]
        if saved != document(app, created):
            raise ValueError("app differs from SPDX document")
        print(f"verified macOS SPDX document for {len(saved['files'])} app files")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["create", "verify"])
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        run(args.action, args.app.absolute())
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError,
            plistlib.InvalidFileException) as error:
        print(f"macOS SPDX error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
