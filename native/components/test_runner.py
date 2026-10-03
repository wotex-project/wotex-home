#!/usr/bin/env python3
"""Exercise native retirement and framing through actual OS processes."""
import hashlib
from pathlib import Path
import struct
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
EXE = ROOT / "_build/component-native/debug/woh-component-runner"


def start():
    return subprocess.Popen([str(EXE)], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={})


def request(component, operation=0, value=b"\0\0"):
    body = bytes([1, operation]) + hashlib.sha256(component).digest()
    body += hashlib.sha256((ROOT / "native/components/wit/profile.wit").read_bytes()).digest()
    body += struct.pack(">I", len(component)) + component + value
    return struct.pack(">I", len(body)) + body


class RunnerTests(unittest.TestCase):
    def test_native_watchdog_covers_stalled_input_before_compilation(self):
        with start() as process:
            before = time.monotonic()
            self.assertEqual(process.wait(timeout=7), 124)
            self.assertLess(time.monotonic() - before, 6.5)

    def test_eof_retires_actual_compilation_process(self):
        component = (ROOT / "_build/component-fixtures/compile-heavy.wasm").read_bytes()
        with start() as process:
            process.stdin.write(request(component))
            process.stdin.flush()
            before = time.monotonic()
            process.stdin.close()
            self.assertEqual(process.wait(timeout=2), 125)
            self.assertLess(time.monotonic() - before, 1.5)
            self.assertEqual(process.stderr.read(), b"")

    def test_invalid_and_oversize_frame_never_allocate_requested_length(self):
        for frame in [struct.pack(">I", 0xFFFFFFFF), struct.pack(">I", 1) + b"\x01"]:
            with start() as process:
                process.stdin.write(frame)
                process.stdin.flush()
                self.assertEqual(process.stdout.read(7), b"\0\0\0\3\1\3\0")
                self.assertEqual(process.wait(timeout=2), 0)

    def test_component_state_and_credentials_have_no_ambient_channel(self):
        # The reference needs only its declared import-free world, under env={}.
        binary = (ROOT / "_build/component-fixtures/reference.wasm").read_bytes()
        with start() as process:
            process.stdin.write(request(binary))
            process.stdin.flush()
            self.assertEqual(process.stdout.read(7), b"\0\0\0\3\1\0\0")
            self.assertEqual(process.wait(timeout=2), 0)
            self.assertEqual(process.stderr.read(), b"")


if __name__ == "__main__":
    unittest.main()
