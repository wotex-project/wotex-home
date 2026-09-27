import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "bin/check_nerves_serial_modules.py"
SPEC = importlib.util.spec_from_file_location("check_nerves_serial_modules", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NervesSerialModuleCheckTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("mksquashfs") and shutil.which("unsquashfs"),
                         "SquashFS tools unavailable")
    def test_inventory_uses_built_rootfs_and_rejects_missing_selected_driver(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            module_dir = root / "tree/lib/modules/1/kernel/drivers/usb/serial"
            module_dir.mkdir(parents=True)
            (module_dir / "cp210x.ko").write_bytes(b"module fixture")
            rootfs = root / "system.squashfs"
            subprocess.run(["mksquashfs", str(root / "tree"), str(rootfs), "-noappend", "-quiet"],
                           check=True, capture_output=True)

            report = MODULE.check(rootfs, ["cp210x"])
            self.assertEqual(report["serial_modules"]["cp210x"], True)
            self.assertEqual(report["serial_modules"]["cdc_acm"], False)
            with self.assertRaisesRegex(ValueError, "selected USB serial modules missing"):
                MODULE.check(rootfs, ["cdc_acm"])


if __name__ == "__main__":
    unittest.main()
