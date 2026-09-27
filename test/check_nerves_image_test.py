import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "bin/check_nerves_image.py"
SPEC = importlib.util.spec_from_file_location("check_nerves_image", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def elf(machine: int) -> bytes:
    return b"\x7fELF\x02\x01" + b"\0" * 12 + machine.to_bytes(2, "little")


class NervesImageCheckTest(unittest.TestCase):
    def test_accepts_arm_release_and_rejects_foreign_or_networked_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root / "release"
            firmware = root / "home.fw"
            firmware.write_bytes(b"firmware")
            beam = release / "erts-1/bin/beam.smp"
            beam.parent.mkdir(parents=True)
            beam.write_bytes(elf(183))
            vm_args = release / "releases/0.1.0/vm.args"
            vm_args.parent.mkdir(parents=True)
            vm_args.write_text("-noshell\n", encoding="utf-8")
            priv = release / "lib/ex_maude-1/priv"
            priv.mkdir(parents=True)

            self.assertEqual(MODULE.check(release, firmware)["aarch64_elf_files"], 1)

            vm_args.write_text("-sname home\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Erlang network node"):
                MODULE.check(release, firmware)
            vm_args.write_text("-noshell\n", encoding="utf-8")

            foreign = priv / "maude-darwin-arm64"
            foreign.write_bytes(b"native")
            with self.assertRaisesRegex(ValueError, "foreign Maude"):
                MODULE.check(release, firmware)
            foreign.unlink()

            beam.write_bytes(elf(62))
            with self.assertRaisesRegex(ValueError, "ERTS is not AArch64"):
                MODULE.check(release, firmware)


if __name__ == "__main__":
    unittest.main()
