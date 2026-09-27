import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "bin/release_components.py"
SPEC = importlib.util.spec_from_file_location("release_components", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseComponentsTest(unittest.TestCase):
    def test_payload_mapping_exposes_missing_inputs_and_file_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source"
            release = base / "release"
            (source / "deps/foo").mkdir(parents=True)
            (source / "deps/foo/LICENSE").write_text("license input", encoding="utf-8")
            (source / "vendor/ex_maude").mkdir(parents=True)
            (source / "vendor/ex_maude/THIRD_PARTY_NOTICES.md").write_text(
                "native notice", encoding="utf-8"
            )
            (release / "lib/foo-1.0/ebin").mkdir(parents=True)
            (release / "lib/foo-1.0/ebin/foo.beam").write_bytes(b"beam")
            (release / "lib/ex_maude-0.4.3/priv/maude/bin").mkdir(parents=True)
            (release / "lib/ex_maude-0.4.3/priv/maude/bin/maude").write_bytes(b"native")
            (release / "erts-1/bin").mkdir(parents=True)
            (release / "erts-1/bin/beam.smp").write_bytes(b"runtime")

            first = MODULE.report(release, source, "a" * 40)
            by_name = {component["name"]: component for component in first["components"]}
            self.assertEqual(first["file_count"], 3)
            self.assertEqual(by_name["foo-1.0"]["license_input_status"], "present")
            self.assertEqual(by_name["erts-1"]["license_input_status"], "missing")
            self.assertEqual(by_name["maude-bundled"]["license_input_status"], "notice_only")
            self.assertEqual(first["license_review"], "unresolved")

            (release / "lib/foo-1.0/ebin/foo.beam").write_bytes(b"changed")
            second = MODULE.report(release, source, "a" * 40)
            self.assertNotEqual(
                by_name["foo-1.0"]["files_sha256"],
                {item["name"]: item for item in second["components"]}["foo-1.0"]["files_sha256"],
            )

    def test_symlink_payload_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            release = Path(temporary)
            (release / "bin").mkdir()
            (release / "bin/link").symlink_to("missing")
            with self.assertRaisesRegex(ValueError, "symlink in release"):
                MODULE.packaged_components(release)


if __name__ == "__main__":
    unittest.main()
