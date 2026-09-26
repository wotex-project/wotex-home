#!/usr/bin/env python3
"""Independent one-shot LIFX identity peer over UDP loopback."""

import socket
import struct

TARGET = bytes.fromhex("d073d5001337")


def response(request: bytes, message_type: int, payload: bytes) -> bytes:
    source = struct.unpack_from("<I", request, 4)[0]
    sequence = request[23]
    header = (
        struct.pack("<HHI", 36 + len(payload), 0x1400, source)
        + TARGET
        + bytes(2 + 6 + 1)
        + bytes([sequence])
        + bytes(8)
        + struct.pack("<H", message_type)
        + bytes(2)
    )
    assert len(header) == 36
    return header + payload


def main() -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as peer:
        peer.bind(("127.0.0.1", 0))
        peer.settimeout(5)
        print(peer.getsockname()[1], flush=True)
        requests = {}
        addresses = set()
        for _ in range(2):
            packet, address = peer.recvfrom(1024)
            assert len(packet) == 36
            size, frame, source = struct.unpack_from("<HHI", packet)
            assert size == 36 and frame == 0x1400 and source >= 2
            assert packet[8:16] == TARGET + bytes(2)
            message_type = struct.unpack_from("<H", packet, 32)[0]
            assert message_type in (14, 32) and message_type not in requests
            requests[message_type] = packet
            addresses.add(address)
        assert len(addresses) == 1
        address = addresses.pop()

        unrelated = response(requests[32], 45, b"")
        firmware = response(
            requests[14],
            15,
            struct.pack("<Q", 1_700_000_000) + bytes(8) + struct.pack("<HH", 60, 3),
        )
        version = response(requests[32], 33, struct.pack("<III", 1, 27, 0))
        peer.sendto(unrelated, address)
        peer.sendto(firmware, address)
        peer.sendto(version, address)


if __name__ == "__main__":
    main()
