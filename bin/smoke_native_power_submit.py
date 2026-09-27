#!/usr/bin/env python3
"""Check exact typed Swift power submission and strict receipt decoding."""

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
        chunk = peer.recv(size - len(data))
        if not chunk:
            raise EOFError("client closed early")
        data += chunk
    return data


def serve(path: Path, response: dict, errors: list[BaseException]) -> None:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(path))
            os.chmod(path, 0o600)
            listener.listen(1)
            listener.settimeout(10)
            with listener.accept()[0] as peer:
                size = struct.unpack(">I", read_exact(peer, 4))[0]
                assert 0 < size <= 65_536
                request = json.loads(read_exact(peer, size))
                credential = base64.urlsafe_b64encode(bytes([7]) * 32).rstrip(b"=").decode()
                assert request == {
                    "api_version": 1,
                    "operation": "submit",
                    "credential": credential,
                    "mutation": {
                        "api_version": 1,
                        "operation_id": "op:17",
                        "authority_epoch": 3,
                        "expected_revision": 5,
                        "target_id": "light:desk",
                        "capability_key": "power",
                        "value": {"type": "boolean", "value": True},
                    },
                }
                body = json.dumps(response, separators=(",", ":")).encode()
                peer.sendall(struct.pack(">I", len(body)) + body)
    except BaseException as error:
        errors.append(error)


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="wotex-native-submit-") as temporary:
        directory = Path(temporary)
        os.chmod(directory, 0o700)
        executable = directory / "power-submit-smoke"
        subprocess.run(
            [
                "swiftc", "-parse-as-library", "-swift-version", "6", "-framework", "Security",
                str(root / "native/macos/Sources/LocalHealthClient.swift"),
                str(root / "native/macos/Tests/LocalPowerSubmitSmoke.swift"),
                "-o", str(executable),
            ],
            check=True,
        )
        subprocess.run(
            [str(executable), str(directory / "missing.sock"), "invalid-input"], check=True
        )

        receipt = {
            "principal_id": "operator:1",
            "authority_epoch": 3,
            "operation_id": "op:17",
            "disposition": "held",
            "reason": None,
            "revision": 19,
        }
        for mode, response in [
            ("valid", {"api_version": 1, "outcome": "ok", "receipt": receipt}),
            ("invalid", {"api_version": 1, "outcome": "ok", "receipt": {**receipt, "operation_id": "op:other"}}),
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
                raise RuntimeError("mock power peer did not finish")
            if errors:
                raise errors[0]
            path.unlink()

    print("native typed power submission and receipt checks passed")


if __name__ == "__main__":
    main()
