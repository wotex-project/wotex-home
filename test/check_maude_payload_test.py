import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "bin/check_maude_payload.py"
SPEC = importlib.util.spec_from_file_location("check_maude_payload", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SOURCE = SCRIPT.parent.parent / "vendor/ex_maude/priv/maude/bin"


class MaudePayloadTest(unittest.TestCase):
    def test_exact_vendor_payload_and_changed_byte(self):
        self.assertEqual(MODULE.check_directory(SOURCE), 14)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in MODULE.FILE_SHA256:
                shutil.copyfile(SOURCE / ("maude-darwin-arm64" if name == "maude" else name),
                                directory / ("maude-darwin-arm64" if name == "maude" else name))
            self.assertEqual(MODULE.check_directory(directory, release=True), 14)
            (directory / "prelude.maude").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "payload hash differs: prelude.maude"):
                MODULE.check_directory(directory, release=True)

    def test_release_rejects_foreign_or_linked_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for name in MODULE.FILE_SHA256:
                local = "maude-darwin-arm64" if name == "maude" else name
                (directory / local).symlink_to(SOURCE / local)
            with self.assertRaisesRegex(ValueError, "linked"):
                MODULE.check_directory(directory, release=True)
            (directory / "maude-darwin-arm64").unlink()
            shutil.copyfile(SOURCE / "maude-darwin-arm64", directory / "maude-darwin-arm64")
            (directory / "maude-linux-x64").write_bytes(b"foreign")
            with self.assertRaisesRegex(ValueError, "file set differs"):
                MODULE.check_directory(directory, release=True)


if __name__ == "__main__":
    unittest.main()
