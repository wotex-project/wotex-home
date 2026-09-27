#!/usr/bin/env python3
"""Check Swift and CLI receipts against one live private Home host."""

import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path


OPERATION_ID = "op:parity:1"


def result_json(command: list[str], *, cwd: Path, env: dict[str, str],
                input_text: str | None = None) -> dict:
    result = subprocess.run(command, cwd=cwd, env=env, input=input_text, text=True,
                            capture_output=True, timeout=20)
    if result.returncode:
        raise RuntimeError(f"parity client exited with {result.returncode}: {result.stderr[:500]}")
    lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
    if len(lines) != 1:
        raise RuntimeError("parity client returned no single JSON result")
    return json.loads(lines[0])


def receipt(result: dict) -> dict:
    item = result.get("receipt", result)
    return {key: item[key] for key in
            ("authority_epoch", "operation_id", "disposition", "reason", "revision")}


def wait_for_socket(path: Path, host: subprocess.Popen) -> None:
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if host.poll() is not None:
            raise RuntimeError("foreground Home host exited before socket startup")
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                probe.settimeout(0.2)
                probe.connect(str(path))
            return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError("private Home socket did not start")


def main() -> None:
    project = Path(__file__).resolve().parent.parent
    environment = os.environ.copy()
    environment.pop("WOTEX_HOME_DATA_DIR", None)
    with tempfile.TemporaryDirectory(prefix="wh-parity-", dir="/tmp") as temporary:
        root = Path(temporary)
        data_dir = root / "private"
        credential_file = root / "credential"
        subprocess.run(
            ["mix", "run", "--no-start", "bin/bootstrap_native_cli_parity.exs",
             str(data_dir), str(credential_file)],
            cwd=project, env=environment, check=True, capture_output=True, timeout=90,
        )
        credential = credential_file.read_text(encoding="ascii")
        if len(credential) != 43:
            raise RuntimeError("fixture credential is malformed")

        executable = root / "native-cli-parity"
        subprocess.run(
            ["swiftc", "-parse-as-library", "-swift-version", "6", "-framework",
             "Security", str(project / "native/macos/Sources/LocalHealthClient.swift"),
             str(project / "native/macos/Tests/LiveCLIParitySmoke.swift"),
             "-o", str(executable)],
            check=True, capture_output=True, timeout=60,
        )

        host_environment = environment.copy()
        host_environment["WOTEX_HOME_DATA_DIR"] = str(data_dir)
        host = subprocess.Popen(
            ["mix", "run", "--no-compile", "--no-halt"], cwd=project,
            env=host_environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            socket_path = data_dir / "ipc/home.sock"
            wait_for_socket(socket_path, host)
            cli = [
                "mix", "run", "--no-start", "--no-compile", "-e",
                "System.halt(WotexHome.CLI.main(System.argv()))", "--",
                "--socket", str(socket_path), "--credential-file", str(credential_file),
            ]
            native = [str(executable), str(socket_path)]
            staged = receipt(result_json(native + ["stage"], cwd=project, env=environment,
                                         input_text=credential + "\n"))
            seen_by_cli = receipt(result_json(cli + ["receipt", "1", OPERATION_ID],
                                              cwd=project, env=environment))
            if staged != seen_by_cli or staged["disposition"] != "held":
                raise RuntimeError("Swift and CLI disagree on the held receipt")

            cancelled = receipt(result_json(cli + ["cancel", "1", OPERATION_ID],
                                            cwd=project, env=environment))
            seen_by_native = receipt(result_json(native + ["status"], cwd=project,
                                                 env=environment,
                                                 input_text=credential + "\n"))
            if cancelled != seen_by_native or cancelled["disposition"] != "rejected" or \
                    cancelled["reason"] != "cancelled":
                raise RuntimeError("CLI and Swift disagree on the cancelled receipt")
        finally:
            host.terminate()
            try:
                host.wait(timeout=10)
            except subprocess.TimeoutExpired:
                host.kill()
                host.wait(timeout=5)

    print("native and CLI live held/cancelled receipt parity passed")


if __name__ == "__main__":
    main()
