#!/usr/bin/env python3
"""Check one-time read-only health bootstrap without displaying its secret."""

import os
import re
import subprocess
import tempfile
from pathlib import Path


def main() -> None:
    project = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="wh-", dir="/tmp") as temporary:
        data = Path(temporary) / "private"
        environment = os.environ.copy()
        environment["WOTEX_HOME_DATA_DIR"] = str(data)
        command = ["mix", "run", "bin/bootstrap_health.exs"]

        first = subprocess.run(
            command,
            cwd=project,
            env=environment,
            capture_output=True,
            text=True,
            check=True,
        )
        credentials = [
            line for line in first.stdout.splitlines()
            if re.fullmatch(r"[A-Za-z0-9_-]{43}", line)
        ]
        assert len(credentials) == 1
        credential = credentials[0]
        assert credential not in first.stderr
        assert data.stat().st_mode & 0o777 == 0o700
        assert (data / "home.sqlite").stat().st_mode & 0o777 == 0o600
        assert not (data / "ipc/home.sock").exists()

        repeated = subprocess.run(
            command, cwd=project, env=environment, capture_output=True, text=True
        )
        assert repeated.returncode != 0
        assert "principal_exists" in repeated.stderr
        assert credential not in repeated.stdout + repeated.stderr

    print("one-time read-only health bootstrap and private file modes passed")


if __name__ == "__main__":
    main()
