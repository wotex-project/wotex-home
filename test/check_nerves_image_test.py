import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "bin/check_nerves_image.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("check_nerves_image", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def elf(machine: int) -> bytes:
    return b"\x7fELF\x02\x01" + b"\0" * 12 + machine.to_bytes(2, "little")


def write_firmware(path: Path, *, tryboot: bool = True, valid_source: bool = True,
                   rootfs: bytes | None = None, writable_mount: str = "/root") -> None:
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
    metadata += (
        f'a.nerves_fw_application_part0_target,"{writable_mount}"\n'
        f'b.nerves_fw_application_part0_target,"{writable_mount}"\n'
    )
    if not valid_source:
        metadata = metadata.replace("b.nerves_fw_validated,1", "b.nerves_fw_validated,0")
    autoboot = "tryboot_a_b=1\n[tryboot]\n" if tryboot else "[all]\n"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("meta.conf", metadata)
        archive.writestr("data/autoboot-a.txt", autoboot)
        archive.writestr("data/autoboot-b.txt", autoboot)
        if rootfs is not None:
            archive.writestr("data/rootfs.img", rootfs)


class NervesImageCheckTest(unittest.TestCase):
    def test_accepts_arm_release_and_rejects_foreign_or_networked_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            release = root / "release"
            firmware = root / "home.fw"
            write_firmware(firmware)
            patch = mock.patch.object(MODULE, "firmware_data_path", return_value="fixture")
            patch.start()
            self.addCleanup(patch.stop)
            beam = release / "erts-1/bin/beam.smp"
            beam.parent.mkdir(parents=True)
            beam.write_bytes(elf(183))
            vm_args = release / "releases/0.1.0/vm.args"
            vm_args.parent.mkdir(parents=True)
            vm_args.write_text("-noshell\n", encoding="utf-8")
            priv = release / "lib/ex_maude-1/priv"
            priv.mkdir(parents=True)
            maude_dir = priv / "maude"
            maude_dir.mkdir()
            source = SCRIPT.parent.parent
            shutil.copyfile(source / "docs/provenance/license-inputs/maude-3.5.1-COPYING",
                            maude_dir / "COPYING")
            shutil.copyfile(source / "vendor/ex_maude/THIRD_PARTY_NOTICES.md",
                            maude_dir / "THIRD_PARTY_NOTICES.md")
            for package in ("db_connection-2.10.2", "rustler_precompiled-0.9.0"):
                license_path = release / "lib" / package / "priv/LICENSE"
                license_path.parent.mkdir(parents=True)
                shutil.copyfile(source / "docs/provenance/license-inputs/apache-2.0-LICENSE.txt",
                                license_path)
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

            maude_license = maude_dir / "COPYING"
            maude_license.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "Maude standard-library legal inputs"):
                MODULE.check(release, firmware)
            shutil.copyfile(source / "docs/provenance/license-inputs/maude-3.5.1-COPYING",
                            maude_license)

            apache_license = release / "lib/db_connection-2.10.2/priv/LICENSE"
            apache_license.unlink()
            with self.assertRaisesRegex(ValueError, "Apache license input"):
                MODULE.check(release, firmware)
            shutil.copyfile(source / "docs/provenance/license-inputs/apache-2.0-LICENSE.txt",
                            apache_license)

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

    @unittest.skipUnless(shutil.which("mksquashfs") and shutil.which("unsquashfs"),
                         "SquashFS tools unavailable")
    def test_home_data_path_requires_writable_mount_and_rootfs_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tree = root / "tree"
            tree.mkdir()
            (tree / "root").mkdir()
            os.symlink("root", tree / "data")
            image = root / "rootfs.img"
            subprocess.run(["mksquashfs", str(tree), str(image), "-noappend", "-quiet"],
                           check=True, capture_output=True)
            archive = root / "home.fw"
            write_firmware(archive, rootfs=image.read_bytes())
            self.assertEqual(
                MODULE.firmware_data_path(archive),
                "data_symlink_to_root_writable_application_mount",
            )

            write_firmware(archive, rootfs=image.read_bytes(), writable_mount="/data")
            with self.assertRaisesRegex(ValueError, "writable application mount"):
                MODULE.firmware_data_path(archive)

            (tree / "data").unlink()
            (tree / "data").mkdir()
            image.unlink()
            subprocess.run(["mksquashfs", str(tree), str(image), "-noappend", "-quiet"],
                           check=True, capture_output=True)
            write_firmware(archive, rootfs=image.read_bytes())
            with self.assertRaisesRegex(ValueError, "/data does not resolve"):
                MODULE.firmware_data_path(archive)


if __name__ == "__main__":
    unittest.main()
