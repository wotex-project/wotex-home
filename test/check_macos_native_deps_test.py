import importlib.util
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "bin/check_macos_native_deps.py"
SPEC = importlib.util.spec_from_file_location("check_macos_native_deps", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


@unittest.skipUnless(all(shutil.which(name) for name in ("clang", "lipo", "otool")),
                     "macOS native tools unavailable")
class MacOSNativeDependenciesTest(unittest.TestCase):
    def test_system_loads_pass_self_id_is_not_dependency_and_external_load_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            macos = root / "Test.app/Contents/MacOS"
            macos.mkdir(parents=True)
            simple = root / "simple.c"
            simple.write_text("int main(void) { return 0; }\n", encoding="ascii")
            (app := root / "Test.app").joinpath("Contents/Info.plist").write_bytes(
                plistlib.dumps({"LSMinimumSystemVersion": "15.0"})
            )
            subprocess.run(["clang", "-mmacosx-version-min=15.0", str(simple),
                            "-o", str(macos / "WotexHome")], check=True)
            shutil.copy2(macos / "WotexHome", macos / "WotexHomeAgent")
            self.assertEqual(MODULE.check(app)["native_files"], 2)

            (app / "Contents/Info.plist").write_bytes(
                plistlib.dumps({"LSMinimumSystemVersion": "14.0"})
            )
            with self.assertRaisesRegex(ValueError, "requires newer macOS"):
                MODULE.check(app)
            (app / "Contents/Info.plist").write_bytes(
                plistlib.dumps({"LSMinimumSystemVersion": "15.0"})
            )

            library_source = root / "outside.c"
            library_source.write_text("int outside(void) { return 0; }\n", encoding="ascii")
            library = root / "liboutside.dylib"
            subprocess.run(["clang", "-mmacosx-version-min=15.0", "-dynamiclib",
                            str(library_source), "-install_name",
                            str(library), "-o", str(library)], check=True)
            packaged = app / "Contents/Resources/liboutside.dylib"
            packaged.parent.mkdir(parents=True)
            shutil.copy2(library, packaged)
            report = MODULE.check(app)
            self.assertEqual(report["nonportable_self_install_ids"], 1)

            foreign = app / "Contents/Resources/foreign"
            subprocess.run(["clang", "-arch", "x86_64", "-mmacosx-version-min=15.0",
                            str(simple), "-o", str(foreign)], check=True)
            with self.assertRaisesRegex(ValueError, "unsupported native architecture"):
                MODULE.check(app)
            foreign.unlink()

            linked = root / "linked.c"
            linked.write_text("extern int outside(void); int main(void) { return outside(); }\n",
                              encoding="ascii")
            subprocess.run(["clang", "-mmacosx-version-min=15.0", str(linked), str(library), "-o",
                            str(macos / "WotexHomeAgent")], check=True)
            with self.assertRaisesRegex(ValueError, "unbundled native dependency"):
                MODULE.check(app)


if __name__ == "__main__":
    unittest.main()
