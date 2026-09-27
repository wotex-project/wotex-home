#!/usr/bin/env python3
"""Create or verify a file-level SPDX 2.3 JSON SBOM for a Home release.

Licenses remain NOASSERTION until independent review. Generated report files
are excluded from this document and covered by release-inventory.json.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path

import release_components

REPORT = "release.spdx.json"
CREATED = re.compile(r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")


def package_id(name: str) -> str:
    clean = re.sub(r"[^A-Za-z0-9.-]", "-", name)
    suffix = hashlib.sha256(name.encode("utf-8")).hexdigest()[:12]
    return f"SPDXRef-Package-{clean}-{suffix}"


def document(root: Path, component_report: dict, created: str) -> dict:
    if not CREATED.fullmatch(created):
        raise ValueError("invalid SPDX creation timestamp")
    groups = release_components.packaged_components(root)
    reported = {item["name"] for item in component_report["components"]}
    if reported != set(groups):
        raise ValueError("component report does not cover release payload")

    packages = []
    files = []
    relationships = []
    file_number = 0

    for component in component_report["components"]:
        name = component["name"]
        group = groups[name]
        package_spdx_id = package_id(name)
        match = release_components.APP_DIRECTORY.fullmatch(name)
        version = match.group(2) if match else "NOASSERTION"
        package_files = []

        for path, checksum in sorted(group["files"]):
            file_number += 1
            file_spdx_id = f"SPDXRef-File-{file_number}"
            package_files.append(file_spdx_id)
            files.append(
                {
                    "SPDXID": file_spdx_id,
                    "fileName": f"./{path}",
                    "checksums": [{"algorithm": "SHA256", "checksumValue": checksum}],
                    "licenseConcluded": "NOASSERTION",
                    "licenseInfoInFiles": ["NOASSERTION"],
                    "copyrightText": "NOASSERTION",
                }
            )
            relationships.append(
                {
                    "spdxElementId": package_spdx_id,
                    "relationshipType": "CONTAINS",
                    "relatedSpdxElement": file_spdx_id,
                }
            )

        packages.append(
            {
                "SPDXID": package_spdx_id,
                "name": name,
                "versionInfo": version,
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": True,
                "hasFiles": package_files,
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "licenseInfoFromFiles": ["NOASSERTION"],
                "copyrightText": "NOASSERTION",
                "comment": (
                    "License review unresolved; local input status: "
                    + component["license_input_status"]
                ),
            }
        )
        relationships.append(
            {
                "spdxElementId": "SPDXRef-DOCUMENT",
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": package_spdx_id,
            }
        )

    if file_number != component_report["file_count"]:
        raise ValueError("component report file count differs from release")
    identity = hashlib.sha256(
        (component_report["source_revision"] + json.dumps([(f["fileName"], f["checksums"]) for f in files], separators=(",", ":"))).encode("utf-8")
    ).digest()
    namespace = f"urn:uuid:{uuid.UUID(bytes=identity[:16], version=5)}"

    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"WoTEx Home release {component_report['source_revision'][:12]}",
        "documentNamespace": namespace,
        "creationInfo": {
            "created": created,
            "creators": ["Tool: wotex-home-release-spdx-1"],
        },
        "comment": (
            "Packaged regular payload files are enumerated. Generated reports are excluded "
            "and covered by release-inventory.json. All license conclusions are NOASSERTION."
        ),
        "documentDescribes": [package["SPDXID"] for package in packages],
        "packages": packages,
        "files": files,
        "relationships": relationships,
    }


def component_report(root: Path, source: Path, action: str) -> dict:
    revision = release_components.source_revision(source, require_clean=action == "create")
    path = root / release_components.REPORT
    saved = json.loads(path.read_text(encoding="utf-8"))
    expected = release_components.report(root, source, revision)
    if saved != expected:
        raise ValueError("component report must be created and verified first")
    return saved


def run(action: str, root: Path, source: Path) -> None:
    if root.is_symlink() or not root.is_dir():
        raise ValueError("release_root must be a real directory")
    components = component_report(root, source, action)
    destination = root / REPORT

    if action == "create":
        created = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        contents = document(root, components, created)
        temporary = root / (REPORT + ".tmp")
        try:
            with temporary.open("x", encoding="utf-8") as stream:
                json.dump(contents, stream, sort_keys=True, separators=(",", ":"))
                stream.write("\n")
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
        print(f"created SPDX 2.3 document for {len(contents['files'])} payload files")
    else:
        saved = json.loads(destination.read_text(encoding="utf-8"))
        try:
            created = saved["creationInfo"]["created"]
        except (KeyError, TypeError):
            raise ValueError("invalid SPDX document creation info") from None
        if saved != document(root, components, created):
            raise ValueError("release payload differs from SPDX document")
        print(f"verified SPDX 2.3 document for {len(saved['files'])} payload files")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["create", "verify"])
    parser.add_argument("release_root", type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    try:
        run(args.action, args.release_root.absolute(), source)
    except (ValueError, OSError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"release SPDX error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
