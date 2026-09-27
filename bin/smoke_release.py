#!/usr/bin/env python3
"""Local, hardware-free smoke check for an already assembled OTP release."""

from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time


CHECK_VERIFIER = '''
path = ExMaude.Binary.find()
root = System.fetch_env!("WOTEX_EXPECT_RELEASE_ROOT")
unless is_binary(path) and String.starts_with?(Path.expand(path), root <> "/") do
  raise "Maude binary is not inside the release"
end
rules = [%{id: "r1", thing_id: "light:desk", trigger: {:always},
           actions: [{:set_prop, "light:desk", "power", true}], priority: 1}]
case ExMaude.IoT.detect_conflicts_with_receipt(rules,
       conflict_types: [:state_conflict], timeout: 5_000) do
  {:ok, %{execution: %{completion: :bounded_complete, findings: []}}} ->
    IO.puts("VERIFIER_OK")
  other ->
    raise "bundled verifier did not complete: #{inspect(other)}"
end
'''


def check_mode(path: Path, expected: int) -> None:
    actual = stat.S_IMODE(path.stat().st_mode)
    if actual != expected:
        raise RuntimeError(f"{path.name} mode {actual:o}, expected {expected:o}")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: smoke_release.py PATH_TO_RELEASE_BIN", file=sys.stderr)
        return 2

    release = Path(sys.argv[1]).resolve()
    if not release.is_file():
        raise RuntimeError(f"release executable missing: {release}")

    root = release.parent.parent
    env = os.environ.copy()
    env["WOTEX_EXPECT_RELEASE_ROOT"] = str(root)

    verifier = subprocess.run(
        [str(release), "eval", CHECK_VERIFIER],
        env=env,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    if verifier.returncode != 0 or "VERIFIER_OK" not in verifier.stdout:
        raise RuntimeError(
            f"release verifier failed:\n{verifier.stdout}\n{verifier.stderr}"
        )

    with tempfile.TemporaryDirectory(prefix="wotex-home-release-") as directory:
        data_dir = Path(directory)
        env["WOTEX_HOME_DATA_DIR"] = directory
        socket = data_dir / "ipc" / "home.sock"
        database = data_dir / "home.sqlite"
        log_path = data_dir / "release.log"

        with log_path.open("w") as log:
            process = subprocess.Popen(
                [str(release), "start"], env=env, stdout=log, stderr=subprocess.STDOUT
            )
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and not socket.exists():
                    if process.poll() is not None:
                        break
                    time.sleep(0.1)

                if not socket.exists() or not database.exists():
                    raise RuntimeError(
                        f"release host did not start (exit={process.poll()}):\n"
                        + log_path.read_text()
                    )

                check_mode(data_dir, 0o700)
                check_mode(socket.parent, 0o700)
                check_mode(socket, 0o600)
                check_mode(database, 0o600)
                if not stat.S_ISSOCK(socket.lstat().st_mode):
                    raise RuntimeError("local API path is not a socket")
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

        if socket.exists():
            raise RuntimeError("release shutdown left its socket behind")

    print("release verifier, private host startup, and shutdown passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"release smoke failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
