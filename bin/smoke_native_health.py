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
from pathlib import Path


def serve(path: Path, response: dict, errors: list[BaseException]) -> None:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(path))
            os.chmod(path, 0o600)
            listener.listen(1)
            listener.settimeout(10)
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
                        "active_things": 3,
                        "active_principals": 1,
                        "writable": True,
                        "dispatch_enabled": False,
                    },
                },
            ),
            ("invalid", {"api_version": 2, "outcome": "ok", "health": {}}),
        ]:
            path = directory / "home.sock"
            errors: list[BaseException] = []
            thread = threading.Thread(target=serve, args=(path, response, errors))
            thread.start()
            try:
                subprocess.run([str(executable), str(path), mode], check=True, timeout=10)
            finally:
                thread.join(timeout=11)
            if thread.is_alive():
                raise RuntimeError("mock health peer did not finish")
            if errors:
                raise errors[0]
            path.unlink()

    print("native health frame, same-user peer check, and response validation passed")


if __name__ == "__main__":
    main()
