#!/usr/bin/env python3
"""Independent catalogue/snapshot peer for the Swift revision-stable read view."""

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


def thing(index: int) -> dict:
    return {
        "id": f"light:{index:02}",
        "role": "Light",
        "profile_ref": "fixture:light:1",
        "capabilities": [{"key": "power"}],
        "resource_revision": 0,
    }


def serve(path: Path, mode: str, errors: list[BaseException]) -> None:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(path))
            os.chmod(path, 0o600)
            listener.listen(3)
            listener.settimeout(10)
            credential = base64.urlsafe_b64encode(bytes([7]) * 32).rstrip(b"=").decode()
            for index in range(3):
                with listener.accept()[0] as peer:
                    size = struct.unpack(">I", read_exact(peer, 4))[0]
                    assert 0 < size <= 65_536
                    request = json.loads(read_exact(peer, size))
                    if index < 2:
                        assert request == {
                            "api_version": 1,
                            "operation": "catalogue",
                            "credential": credential,
                            "watermark": None if index == 0 else 12,
                            "after": None if index == 0 else "light:09",
                            "page_size": 10,
                        }
                        response = {
                            "api_version": 1,
                            "outcome": "ok",
                            "catalogue": {
                                "authority_epoch": 1,
                                "watermark": 12,
                                "items": [thing(n) for n in range(10)]
                                if index == 0 else [thing(10)],
                                "next_after": "light:09" if index == 0 else None,
                            },
                        }
                    else:
                        assert request == {
                            "api_version": 1,
                            "operation": "snapshot",
                            "credential": credential,
                            "watermark": 12,
                            "after": None,
                            "page_size": 100,
                        }
                        response = (
                            {"api_version": 1, "outcome": "error",
                             "reason": "resnapshot_required"}
                            if mode == "changed" else
                            {"api_version": 1, "outcome": "ok",
                             "snapshot": {"authority_epoch": 1, "watermark": 12,
                                          "items": [], "next_after": None}}
                        )
                    body = json.dumps(response, separators=(",", ":")).encode()
                    peer.sendall(struct.pack(">I", len(body)) + body)
    except BaseException as error:
        errors.append(error)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="wotex-native-read-view-") as temporary:
        directory = Path(temporary)
        os.chmod(directory, 0o700)
        executable = directory / "read-view-smoke"
        subprocess.run(
            ["swiftc", "-parse-as-library", "-swift-version", "6", "-framework", "Security",
             str(root / "native/macos/Sources/LocalHealthClient.swift"),
             str(root / "native/macos/Tests/LocalReadViewSmoke.swift"), "-o", str(executable)],
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
                raise RuntimeError("mock read-view peer did not finish")
            if errors:
                raise errors[0]
            path.unlink()

    print("native catalogue and snapshot use one watermark; changed revision rejected")


if __name__ == "__main__":
    main()
