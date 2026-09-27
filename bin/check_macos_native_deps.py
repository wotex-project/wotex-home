#!/usr/bin/env python3
"""Check direct dynamic loads of every Mach-O file in a macOS app bundle."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


MACHO_MAGIC = {bytes.fromhex(value) for value in
               ("feedfacf", "cffaedfe", "cafebabe", "bebafeca")}
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
LOAD_COMMANDS = {
    "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
    "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB", "LC_LOAD_DYLINKER",
}
MAX_FILES = 10_000
MAX_MACHO = 100
MAX_TOOL_OUTPUT = 1_048_576


def tool(*arguments: str) -> str:
    result = subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=10)
    if len(result.stdout) > MAX_TOOL_OUTPUT:
        raise ValueError("native tool output exceeds the development bound")
    return result.stdout


def loads(output: str) -> tuple[list[str], int]:
    dependencies = []
    nonportable_ids = 0
    command = None
    found_name = False
    for line in output.splitlines():
        if line.startswith("Load command "):
            if command in LOAD_COMMANDS and not found_name:
                raise ValueError("Mach-O load command has no library name")
            command = None
            found_name = False
        match = re.fullmatch(r"\s*cmd (LC_[A-Z_]+)", line)
        if match:
            command = match.group(1)
            if command.endswith("DYLIB") and command not in LOAD_COMMANDS | {"LC_ID_DYLIB"}:
                raise ValueError(f"unsupported Mach-O dylib command: {command}")
        match = re.fullmatch(r"\s*name (.+) \(offset \d+\)", line)
        if match and command in LOAD_COMMANDS | {"LC_ID_DYLIB"}:
            name = match.group(1)
            found_name = True
            if command == "LC_ID_DYLIB":
                nonportable_ids += not name.startswith(SYSTEM_PREFIXES)
            else:
                dependencies.append(name)
    if command in LOAD_COMMANDS and not found_name:
        raise ValueError("Mach-O load command has no library name")
    return dependencies, nonportable_ids


def check(app: Path) -> dict:
    if app.is_symlink() or not app.is_dir():
        raise ValueError("app bundle is unavailable")
    binaries = []
    files = 0
    for path in app.rglob("*"):
        if path.is_symlink():
            raise ValueError("app bundle contains a symlink")
        if not path.is_file():
            continue
        files += 1
        if files > MAX_FILES:
            raise ValueError("app bundle has too many files")
        with path.open("rb") as stream:
            if stream.read(4) in MACHO_MAGIC:
                binaries.append(path)
        if len(binaries) > MAX_MACHO:
            raise ValueError("app bundle has too many Mach-O files")

    required = {"Contents/MacOS/WotexHome", "Contents/MacOS/WotexHomeAgent"}
    relative = {path.relative_to(app).as_posix() for path in binaries}
    if not required <= relative:
        raise ValueError("native app or agent executable is missing")

    architectures = {}
    system_loads = set()
    nonportable_ids = 0
    for path in sorted(binaries):
        name = path.relative_to(app).as_posix()
        archs = set(tool("lipo", "-archs", str(path)).strip().split())
        if not archs or not archs <= {"arm64", "x86_64"} or \
                (name in required and "arm64" not in archs):
            raise ValueError(f"unsupported native architecture: {name}")
        architectures[name] = sorted(archs)
        dependencies, ids = loads(tool("otool", "-l", str(path)))
        nonportable_ids += ids
        for dependency in dependencies:
            if not dependency.startswith(SYSTEM_PREFIXES):
                raise ValueError(f"unbundled native dependency in {name}: {dependency}")
            system_loads.add(dependency)

    return {
        "scope": "direct_macho_load_commands_only",
        "native_files": len(binaries),
        "architectures": architectures,
        "system_library_count": len(system_loads),
        "nonportable_self_install_ids": nonportable_ids,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(check(args.app), sort_keys=True))
    except (OSError, ValueError, subprocess.CalledProcessError,
            subprocess.TimeoutExpired) as error:
        print(f"macOS native dependency check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
