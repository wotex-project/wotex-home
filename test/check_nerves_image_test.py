import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "bin/check_nerves_image.py"
SPEC = importlib.util.spec_from_file_location("check_nerves_image", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def elf(machine: int) -> bytes:
    return b"\x7fELF\x02\x01" + b"\0" * 12 + machine.to_bytes(2, "little")


def write_firmware(path: Path, *, tryboot: bool = True, valid_source: bool = True) -> None:
    metadata = """meta-platform=rpi4
task "upgrade.a" {
reqlist={b.nerves_fw_validated,1}
on-init {funlist={a.nerves_fw_validated,0}}
on-finish {funlist={reboot_param,"0 tryboot"}}
}
task "upgrade.b" {
reqlist={a.nerves_fw_validated,1}
on-init {funlist={b.nerves_fw_validated,0}}
on-finish {funlist={reboot_param,"0 tryboot"}}
}
"""
    if not valid_source:
        metadata = metadata.replace("b.nerves_fw_validated,1", "b.nerves_fw_validated,0")
    autoboot = "tryboot_a_b=1\n[tryboot]\n" if tryboot else "[all]\n"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("meta.conf", metadata)
        archive.writestr("data/autoboot-a.txt", autoboot)
        archive.writestr("data/autoboot-b.txt", autoboot)


class NervesImageCheckTest(unittest.TestCase):
    def test_accepts_arm_release_and_rejects_foreign_or_networked_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root / "release"
            firmware = root / "home.fw"
            write_firmware(firmware)
            beam = release / "erts-1/bin/beam.smp"
            beam.parent.mkdir(parents=True)
            beam.write_bytes(elf(183))
            vm_args = release / "releases/0.1.0/vm.args"
            vm_args.parent.mkdir(parents=True)
            vm_args.write_text("-noshell\n", encoding="utf-8")
            priv = release / "lib/ex_maude-1/priv"
            priv.mkdir(parents=True)
            (release / "lib/vintage_net-1").mkdir()
            (release / "lib/vintage_net_ethernet-1").mkdir()
            sys_config = release / "releases/0.1.0/sys.config"
            sys_config.write_text(
                "[{'Elixir.VintageNetEthernet',eth0,method=>dhcp},"
                "{internet_host_list,[{{127,0,0,1},1}]},"
                "{persistence,'Elixir.VintageNet.Persistence.Null'}].",
                encoding="utf-8",
            )

            self.assertEqual(MODULE.check(release, firmware)["aarch64_elf_files"], 1)

            write_firmware(firmware, tryboot=False)
            with self.assertRaisesRegex(ValueError, "lacks tryboot selection"):
                MODULE.check(release, firmware)
            write_firmware(firmware, valid_source=False)
            with self.assertRaisesRegex(ValueError, "validated-source tryboot plan"):
                MODULE.check(release, firmware)
            write_firmware(firmware)

            vm_args.write_text("-sname home\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Erlang network node"):
                MODULE.check(release, firmware)
            vm_args.write_text("-noshell\n", encoding="utf-8")

            sys_config.write_text(sys_config.read_text().replace("127,0,0,1", "1,1,1,1"))
            with self.assertRaisesRegex(ValueError, "local-only probe"):
                MODULE.check(release, firmware)
            sys_config.write_text(sys_config.read_text().replace("1,1,1,1", "127,0,0,1"))

            sys_config.write_text(
                sys_config.read_text().replace(
                    "{{127,0,0,1},1}", "{{127,0,0,1},1},{{1,1,1,1},80}"
                )
            )
            with self.assertRaisesRegex(ValueError, "local-only probe"):
                MODULE.check(release, firmware)
            sys_config.write_text(
                sys_config.read_text().replace(
                    "{{127,0,0,1},1},{{1,1,1,1},80}", "{{127,0,0,1},1}"
                )
            )

            (release / "lib/nerves_ssh-1").mkdir()
            with self.assertRaisesRegex(ValueError, "remote administration"):
                MODULE.check(release, firmware)
            (release / "lib/nerves_ssh-1").rmdir()

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
