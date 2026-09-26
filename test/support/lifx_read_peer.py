#!/usr/bin/env python3
"""One-shot independent LIFX GetColor peer for loopback integration evidence."""

import socket
import struct

TARGET = bytes.fromhex("d073d5001337")


def main() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as peer:
        peer.bind(("127.0.0.1", 0))
        peer.settimeout(5)
        print(peer.getsockname()[1], flush=True)
        request, address = peer.recvfrom(1024)
        assert len(request) == 36
        size, frame, source = struct.unpack_from("<HHI", request)
        assert size == 36 and frame == 0x1400 and source >= 2
        assert request[8:16] == TARGET + b"\x00\x00"
        assert struct.unpack_from("<H", request, 32)[0] == 101
        sequence = request[23]

        label = b"scripted-peer".ljust(32, b"\x00")
        payload = (
            struct.pack("<HHHH", 12_000, 40_000, 50_000, 3_500)
            + b"\x00\x00"
            + struct.pack("<H", 65_535)
            + label
            + bytes(8)
        )
        assert len(payload) == 52
        header = (
            struct.pack("<HHI", 36 + len(payload), 0x1400, source)
            + TARGET
            + bytes(2 + 6 + 1)
            + bytes([sequence])
            + bytes(8)
            + struct.pack("<H", 107)
            + bytes(2)
        )
        assert len(header) == 36
        peer.sendto(header + payload, address)


if __name__ == "__main__":
    main()
