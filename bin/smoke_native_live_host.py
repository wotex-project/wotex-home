#!/usr/bin/env python3
"""Bootstrap a private host and read its real health route with the Swift client."""

import os
import re
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def main() -> None:
    project = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="wh-", dir="/tmp") as temporary:
        directory = Path(temporary)
        data = directory / "private"
        environment = os.environ.copy()
        environment["WOTEX_HOME_DATA_DIR"] = str(data)
        bootstrap = subprocess.run(
            ["mix", "run", "bin/bootstrap_health.exs"],
            cwd=project,
            env=environment,
            capture_output=True,
            text=True,
            check=True,
        )
        credentials = [
            line for line in bootstrap.stdout.splitlines()
            if re.fullmatch(r"[A-Za-z0-9_-]{43}", line)
        ]
        assert len(credentials) == 1
        credential = credentials[0]
        socket_path = data / "ipc/home.sock"

        executable = directory / "live-health"
        subprocess.run(
            [
                "swiftc",
                "-parse-as-library",
                "-swift-version",
                "6",
                "-framework",
                "Security",
                str(project / "native/macos/Sources/LocalHealthClient.swift"),
                str(project / "native/macos/Tests/LiveHealthSmoke.swift"),
                "-o",
                str(executable),
            ],
            check=True,
        )

        host = subprocess.Popen(
            ["mix", "run", "--no-halt"],
            cwd=project,
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.monotonic() + 10
            ready = False
            while time.monotonic() < deadline:
                if host.poll() is not None:
                    raise RuntimeError("foreground Home host exited before socket startup")
                try:
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                        probe.settimeout(0.2)
                        probe.connect(str(socket_path))
                    ready = True
                    break
                except OSError:
                    pass
                time.sleep(0.05)
            if not ready:
                raise TimeoutError("foreground Home socket did not start")

            native = subprocess.run(
                [str(executable), str(socket_path)],
                input=credential + "\n",
                text=True,
                capture_output=True,
                timeout=10,
            )
            if native.returncode != 0:
                raise RuntimeError(native.stderr[:1000] or "native health client failed")
        finally:
            host.terminate()
            try:
                host.wait(timeout=10)
            except subprocess.TimeoutExpired:
                host.kill()
                host.wait(timeout=5)

    print("native client authenticated to the live private Home host")


if __name__ == "__main__":
    main()
