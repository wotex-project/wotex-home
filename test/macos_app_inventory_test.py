import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent / "bin"
sys.path.insert(0, str(SCRIPTS))
import macos_app_inventory
import release_inventory


class MacOSAppInventoryTest(unittest.TestCase):
    def test_outer_and_embedded_inventory_reject_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "WotexHome.app"
            release = app / macos_app_inventory.RELEASE
            revision = "a" * 40
            for relative, data in {
                "Contents/MacOS/WotexHome": b"swift",
                "Contents/MacOS/WotexHomeAgent": b"helper",
                f"{macos_app_inventory.RELEASE}/bin/wotex_home": b"otp",
                f"{macos_app_inventory.RELEASE}/release-components.json": b"{}",
                f"{macos_app_inventory.RELEASE}/release.spdx.json": b"{}",
            }.items():
                destination = app / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            for executable in ["Contents/MacOS/WotexHome", "Contents/MacOS/WotexHomeAgent",
                               f"{macos_app_inventory.RELEASE}/bin/wotex_home"]:
                (app / executable).chmod(0o755)
            with (app / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump({"WotexHomeSourceRevision": revision,
                               "CFBundleIdentifier": "org.wotex.home"}, stream)
            (app / "Contents/Library/LaunchAgents").mkdir(parents=True)
            with (app / "Contents/Library/LaunchAgents/org.wotex.home.agent.plist").open("wb") as stream:
                plistlib.dump({"BundleProgram": "Contents/MacOS/WotexHomeAgent"}, stream)
            (release / "release-inventory.json").write_text(
                json.dumps({
                    "schema_version": 1,
                    "source_revision": revision,
                    "files": release_inventory.entries(release),
                })
            )
            contents = macos_app_inventory.checked_contents(app, revision)
            self.assertIn("Contents/MacOS/WotexHome", [item["path"] for item in contents["files"]])
            (app / macos_app_inventory.REPORT).write_text(json.dumps(contents))
            macos_app_inventory.verify(app)

            (app / "Contents/MacOS/WotexHome").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "app differs from inventory"):
                macos_app_inventory.verify(app)

    def test_symlink_cannot_enter_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            (app / "shortcut").symlink_to("elsewhere")
            with self.assertRaisesRegex(ValueError, "symlink in app"):
                macos_app_inventory.entries(app)


if __name__ == "__main__":
    unittest.main()
