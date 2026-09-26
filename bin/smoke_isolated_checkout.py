#!/usr/bin/env python3
"""Build and smoke the committed Home tree from a temporary isolated checkout."""

from io import BytesIO
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile


def main() -> int:
    project = Path(__file__).resolve().parent.parent
    status = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=normal"],
        cwd=project,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if status.strip():
        raise ValueError("commit the source tree before the isolated smoke check")

    archive = subprocess.run(
        ["git", "archive", "--format=tar", "HEAD"],
        cwd=project,
        check=True,
        capture_output=True,
    ).stdout

    with tempfile.TemporaryDirectory(prefix="wotex-home-clean-") as temporary:
        checkout = Path(temporary) / "home"
        checkout.mkdir()
        with tarfile.open(fileobj=BytesIO(archive), mode="r:") as source:
            source.extractall(checkout, filter="data")

        environment = dict(os.environ, HEX_OFFLINE="1", MIX_ENV="prod")
        for command in (
            ["mix", "deps.get"],
            ["mix", "release", "--overwrite"],
            ["python3", "bin/smoke_release.py", "_build/prod/rel/wotex_home/bin/wotex_home"],
        ):
            subprocess.run(command, cwd=checkout, env=environment, check=True)

    print("isolated committed checkout passed offline-cache release smoke")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"isolated checkout smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1)
