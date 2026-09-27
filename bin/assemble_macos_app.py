#!/usr/bin/env python3
"""Assemble an unsigned development macOS app around an inventoried release."""

import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path



def run(arguments: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(arguments, cwd=cwd, check=True)


def main() -> int:
    project = Path(__file__).resolve().parent.parent
    native = project / "native/macos"
    release = project / "_build/prod/rel/wotex_home"
    if not (release / "bin/wotex_home").is_file():
        print("assemble the production release first", file=sys.stderr)
        return 1

    run(["mix", "woh.release.inventory", "verify", str(release)], cwd=project)
    status = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=normal"],
        cwd=project,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if status.strip():
        raise ValueError("source tree is dirty; commit before app assembly")
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=project,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    inventory = json.loads((release / "release-inventory.json").read_text(encoding="utf-8"))
    if inventory["source_revision"] != revision:
        raise ValueError("release inventory source revision differs from current source")

    generated = native / "WotexHome.xcodeproj"
    run(["xcodegen", "generate", "--spec", str(native / "project.yml"), "--project", str(native)])
    if not generated.is_dir():
        raise ValueError("XcodeGen did not produce the project")

    assembled = project / "_build/macos/WotexHome.app"
    if assembled.exists():
        shutil.rmtree(assembled)
    macos = assembled / "Contents/MacOS"
    macos.mkdir(parents=True)
    with (assembled / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(
            {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleDisplayName": "WoTEx Home",
                "CFBundleExecutable": "WotexHome",
                "CFBundleIdentifier": "org.wotex.home",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "WotexHome",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "1",
                "LSMinimumSystemVersion": "15.0",
                "NSPrincipalClass": "NSApplication",
                "WotexHomeSourceRevision": revision,
            },
            stream,
        )

    run(
        [
            "swiftc",
            "-parse-as-library",
            "-swift-version",
            "6",
            "-target",
            "arm64-apple-macos15.0",
            "-framework",
            "SwiftUI",
            "-framework",
            "ServiceManagement",
            "-framework",
            "Security",
            str(native / "Sources/WotexHomeApp.swift"),
            str(native / "Sources/LocalHealthClient.swift"),
            "-o",
            str(macos / "WotexHome"),
        ]
    )

    helper = macos / "WotexHomeAgent"
    run(
        [
            "swiftc",
            "-swift-version",
            "5",
            "-target",
            "arm64-apple-macos15.0",
            str(native / "Agent/main.swift"),
            "-o",
            str(helper),
        ]
    )

    launch_agents = assembled / "Contents/Library/LaunchAgents"
    launch_agents.mkdir(parents=True, exist_ok=True)
    plist = launch_agents / "org.wotex.home.agent.plist"
    shutil.copy2(native / "LaunchAgents/org.wotex.home.agent.plist", plist)
    with plist.open("rb") as stream:
        agent = plistlib.load(stream)
    if agent.get("BundleProgram") != "Contents/MacOS/WotexHomeAgent":
        raise ValueError("agent plist points outside the bundled helper")

    resources = assembled / "Contents/Resources/WotexHomeRelease"
    shutil.copytree(release, resources)
    if not (resources / "bin/wotex_home").is_file():
        raise ValueError("release executable missing from app")

    native_check = subprocess.run(
        ["mix", "woh.macos.native.deps.check", str(assembled)],
        cwd=project, check=True, capture_output=True, text=True,
    )
    native_closure = json.loads(native_check.stdout.splitlines()[-1])
    print(f"checked direct native loads for {native_closure['native_files']} Mach-O files")

    run(["mix", "woh.macos.app.spdx", "create", str(assembled)], cwd=project)
    run(["mix", "woh.macos.app.spdx", "verify", str(assembled)], cwd=project)
    run(["mix", "woh.macos.app.inventory", "create", str(assembled)], cwd=project)
    run(["mix", "woh.macos.app.inventory", "verify", str(assembled)], cwd=project)

    print(f"assembled unsigned development app: {assembled}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"macOS assembly failed: {error}", file=sys.stderr)
        raise SystemExit(1)
