#!/usr/bin/env python3
"""Exercise the Swift health client against an independent same-user socket peer."""

import base64
import json
import os
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path


def serve(path: Path, response: dict, errors: list[BaseException], ready: threading.Event,
          slow: bool = False) -> None:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(path))
            os.chmod(path, 0o600)
            listener.listen(1)
            listener.settimeout(10)
            ready.set()
            with listener.accept()[0] as peer:
                header = read_exact(peer, 4)
                size = struct.unpack(">I", header)[0]
                assert 0 < size <= 65_536
                request = json.loads(read_exact(peer, size))
                expected = base64.urlsafe_b64encode(bytes([7]) * 32).rstrip(b"=").decode()
                assert request == {
                    "api_version": 1,
                    "operation": "health",
                    "credential": expected,
                }
                if slow:
                    for byte in struct.pack(">I", 20) + b"partial-response":
                        try:
                            peer.sendall(bytes([byte]))
                        except (BrokenPipeError, ConnectionResetError):
                            break
                        time.sleep(1.1)
                else:
                    body = json.dumps(response, separators=(",", ":")).encode()
                    peer.sendall(struct.pack(">I", len(body)) + body)
    except BaseException as error:
        errors.append(error)


def read_exact(peer: socket.socket, size: int) -> bytes:
    data = b""
    while len(data) < size:
        part = peer.recv(size - len(data))
        if not part:
            raise EOFError("client closed early")
        data += part
    return data


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="wotex-native-health-") as temporary:
        directory = Path(temporary)
        os.chmod(directory, 0o700)
        executable = directory / "health-smoke"
        subprocess.run(
            [
                "swiftc",
                "-parse-as-library",
                "-swift-version",
                "6",
                "-framework",
                "Security",
                str(root / "native/macos/Sources/LocalHealthClient.swift"),
                str(root / "native/macos/Tests/LocalHealthSmoke.swift"),
                "-o",
                str(executable),
            ],
            check=True,
        )

        for mode, response in [
            (
                "valid",
                {
                    "api_version": 1,
                    "outcome": "ok",
                    "health": {
                        "store_revision": 12,
                        "authority_epoch": 1,
                        "held_requests": 2,
                        "rule_generation": 4,
                        "queued_requests": 1,
                        "claimed_requests": 1,
                        "unknown_outcomes": 1,
                        "active_things": 3,
                        "active_principals": 1,
                        "writable": True,
                        "dispatch_enabled": False,
                    },
                },
            ),
            ("invalid", {"api_version": 2, "outcome": "ok", "health": {}}),
            ("slow", {}),
        ]:
            path = directory / "home.sock"
            errors: list[BaseException] = []
            ready = threading.Event()
            thread = threading.Thread(target=serve, args=(path, response, errors, ready,
                                                          mode == "slow"))
            thread.start()
            if not ready.wait(timeout=10):
                raise RuntimeError("mock health peer did not listen")
            try:
                subprocess.run([str(executable), str(path), mode], check=True, timeout=8)
            finally:
                thread.join(timeout=11)
            if thread.is_alive():
                raise RuntimeError("mock health peer did not finish")
            if errors:
                raise errors[0]
            path.unlink()

    print("native health framing, peer check, response validation, and drip deadline passed")


if __name__ == "__main__":
    main()
