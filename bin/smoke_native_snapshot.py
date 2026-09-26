#!/usr/bin/env python3
"""Independent two-page local snapshot peer for the Swift read-only client."""

import base64
import json
import os
import socket
import struct
import subprocess
import tempfile
import threading
from pathlib import Path


def read_exact(peer: socket.socket, size: int) -> bytes:
    data = b""
    while len(data) < size:
        part = peer.recv(size - len(data))
        if not part:
            raise EOFError("client closed early")
        data += part
    return data


def serve(path: Path, mode: str, errors: list[BaseException]) -> None:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(path))
            os.chmod(path, 0o600)
            listener.listen(2)
            listener.settimeout(10)
            cursor = {"thing_id": "light:desk", "capability_key": "power"}
            credential = base64.urlsafe_b64encode(bytes([7]) * 32).rstrip(b"=").decode()
            for index in range(2):
                with listener.accept()[0] as peer:
                    size = struct.unpack(">I", read_exact(peer, 4))[0]
                    assert 0 < size <= 65_536
                    request = json.loads(read_exact(peer, size))
                    assert request == {
                        "api_version": 1,
                        "operation": "snapshot",
                        "credential": credential,
                        "watermark": None if index == 0 else 12,
                        "after": None if index == 0 else cursor,
                        "page_size": 100,
                    }
                    if index == 1 and mode == "changed":
                        response = {
                            "api_version": 1,
                            "outcome": "error",
                            "reason": "resnapshot_required",
                        }
                    else:
                        capability = "power" if index == 0 else "brightness"
                        value = (
                            {"type": "boolean", "value": True}
                            if index == 0
                            else {"type": "fraction", "ppm": 400_000}
                        )
                        response = {
                            "api_version": 1,
                            "outcome": "ok",
                            "snapshot": {
                                "authority_epoch": 1,
                                "watermark": 12,
                                "items": [
                                    {
                                        "thing_id": "light:desk" if index == 0 else "light:next",
                                        "capability_key": capability,
                                        "quality": "reported",
                                        "trust": "unauthenticated_local",
                                        "value": value,
                                        "revision": 10 + index,
                                    }
                                ],
                                "next_after": cursor if index == 0 else None,
                            },
                        }
                    body = json.dumps(response, separators=(",", ":")).encode()
                    peer.sendall(struct.pack(">I", len(body)) + body)
    except BaseException as error:
        errors.append(error)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="wotex-native-snapshot-") as temporary:
        directory = Path(temporary)
        os.chmod(directory, 0o700)
        executable = directory / "snapshot-smoke"
        subprocess.run(
            [
                "swiftc",
                "-parse-as-library",
                "-swift-version",
                "6",
                "-framework",
                "Security",
                str(root / "native/macos/Sources/LocalHealthClient.swift"),
                str(root / "native/macos/Tests/LocalSnapshotSmoke.swift"),
                "-o",
                str(executable),
            ],
            check=True,
        )

        for mode in ("valid", "changed"):
            path = directory / "home.sock"
            errors: list[BaseException] = []
            thread = threading.Thread(target=serve, args=(path, mode, errors))
            thread.start()
            try:
                subprocess.run([str(executable), str(path), mode], check=True, timeout=10)
            finally:
                thread.join(timeout=11)
            if thread.is_alive():
                raise RuntimeError("mock snapshot peer did not finish")
            if errors:
                raise errors[0]
            path.unlink()

    print("native snapshot paging and resnapshot-required rejection passed")


if __name__ == "__main__":
    main()
