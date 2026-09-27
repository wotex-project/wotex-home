import importlib.util
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parent.parent / "bin/smoke_release.py"
SPEC = importlib.util.spec_from_file_location("smoke_release", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SmokeReleaseTest(unittest.TestCase):
    def test_host_ready_waits_for_private_socket_and_database(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            endpoint = root / "home.sock"
            database = root / "home.sqlite"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(endpoint))
                database.write_bytes(b"sqlite")
                os.chmod(database, 0o600)
                os.chmod(endpoint, 0o755)
                self.assertFalse(MODULE.host_ready(endpoint, database))

                os.chmod(endpoint, 0o600)
                self.assertFalse(MODULE.host_ready(endpoint, database))
                with patch.object(MODULE, "host_responds", return_value=True):
                    self.assertTrue(MODULE.host_ready(endpoint, database))

                os.chmod(database, 0o644)
                self.assertFalse(MODULE.host_ready(endpoint, database))

    def test_health_probe_reads_fragmented_framed_rejection(self):
        with tempfile.TemporaryDirectory() as temporary:
            endpoint = Path(temporary) / "home.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(endpoint))
                listener.listen(1)
                listener.settimeout(2)

                def answer():
                    with listener.accept()[0] as peer:
                        peer.settimeout(2)
                        size = int.from_bytes(MODULE.recv_exact(peer, 4), "big")
                        request = json.loads(MODULE.recv_exact(peer, size))
                        self.assertEqual(request["operation"], "health")
                        body = json.dumps({
                            "api_version": 1,
                            "outcome": "error",
                            "reason": "unauthorized",
                        }).encode()
                        frame = len(body).to_bytes(4, "big") + body
                        peer.sendall(frame[:2])
                        time.sleep(0.01)
                        peer.sendall(frame[2:])

                worker = threading.Thread(target=answer)
                worker.start()
                self.assertTrue(MODULE.host_responds(endpoint))
                worker.join(timeout=2)
                self.assertFalse(worker.is_alive())


if __name__ == "__main__":
    unittest.main()
