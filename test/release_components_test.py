import importlib.util
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "bin/release_components.py"
SPEC = importlib.util.spec_from_file_location("release_components", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
sys.path.insert(0, str(SCRIPT.parent))
import release_spdx


class ReleaseComponentsTest(unittest.TestCase):
    def test_pinned_runtime_license_inputs_require_exact_component_and_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            for family, (relative, _digest) in MODULE.PINNED_LICENSE_INPUTS.items():
                destination = source / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(SCRIPT.parent.parent / relative, destination)

            for component, family in [
                ("erts-16.4.0.6", "otp"),
                ("compiler-9.0.6.2", "otp"),
                ("elixir-1.19.6", "elixir"),
                ("logger-1.19.6", "elixir"),
            ]:
                inputs = MODULE.license_inputs(source, component)
                self.assertEqual(len(inputs), 1)
                self.assertEqual(inputs[0]["sha256"], MODULE.PINNED_LICENSE_INPUTS[family][1])

            self.assertEqual(MODULE.license_inputs(source, "erts-16.4.0.7"), [])
            wrapper_inputs = MODULE.license_inputs(source, "release-wrapper")
            self.assertEqual(
                {item["sha256"] for item in wrapper_inputs},
                {digest for _, digest in MODULE.PINNED_LICENSE_INPUTS.values()},
            )
            self.assertEqual(MODULE.component_for("bin/wotex_home_cli"), "home-cli")
            self.assertEqual(
                MODULE.component_for("lib/ex_maude-0.4.3/priv/maude/COPYING"),
                "maude-bundled",
            )
            self.assertEqual(
                MODULE.component_for("lib/ex_maude-0.4.3/priv/maude/THIRD_PARTY_NOTICES.md"),
                "maude-bundled",
            )
            self.assertEqual(MODULE.license_inputs(source, "home-cli"), [])
            path = source / MODULE.PINNED_LICENSE_INPUTS["otp"][0]
            path.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "pinned otp license input differs"):
                MODULE.license_inputs(source, "erts-16.4.0.6")

    def test_package_readme_notice_is_distinct_from_full_license_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            release = source / "release"
            for component, files in MODULE.PACKAGE_NOTICE_INPUTS.items():
                name = component.rsplit("-", 1)[0]
                directory = source / "deps" / name
                directory.mkdir(parents=True)
                for filename in files:
                    shutil.copyfile(SCRIPT.parent.parent / "deps" / name / filename,
                                    directory / filename)
                payload = release / "lib" / component / "ebin" / "package.beam"
                payload.parent.mkdir(parents=True)
                payload.write_bytes(b"beam")

            components = MODULE.report(release, source, "a" * 40)["components"]
            self.assertEqual({item["license_input_status"] for item in components},
                             {"notice_only"})
            changed = source / "deps/db_connection/README.md"
            changed.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "pinned db_connection-2.10.2 notice"):
                MODULE.report(release, source, "a" * 40)

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

            relative, digest = MODULE.MAUDE_LICENSE_INPUT
            pinned = source / relative
            pinned.parent.mkdir(parents=True)
            shutil.copyfile(SCRIPT.parent.parent / relative, pinned)
            with_license = MODULE.report(release, source, "a" * 40)
            maude = {item["name"]: item for item in with_license["components"]}["maude-bundled"]
            self.assertEqual(maude["license_input_status"], "present")
            self.assertEqual(maude["license_inputs"][0], {"path": relative, "sha256": digest})
            pinned.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "pinned Maude license input differs"):
                MODULE.report(release, source, "a" * 40)

            (release / "lib/foo-1.0/ebin/foo.beam").write_bytes(b"changed")
            pinned.unlink()
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

    def test_spdx_enumerates_every_payload_file_without_license_claims(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source"
            release = base / "release"
            source.mkdir()
            (release / "lib/foo-1.0/ebin").mkdir(parents=True)
            (release / "lib/foo-1.0/ebin/foo.beam").write_bytes(b"beam")
            (release / "release-inventory.json").write_text("{}", encoding="utf-8")
            components = MODULE.report(release, source, "a" * 40)
            document = release_spdx.document(release, components, "2026-09-27T00:00:00Z")

            self.assertEqual(document["spdxVersion"], "SPDX-2.3")
            self.assertEqual(len(document["packages"]), 1)
            self.assertEqual(len(document["files"]), 1)
            self.assertEqual(document["packages"][0]["licenseConcluded"], "NOASSERTION")
            self.assertEqual(document["files"][0]["fileName"], "./lib/foo-1.0/ebin/foo.beam")
            self.assertEqual(
                {relationship["relationshipType"] for relationship in document["relationships"]},
                {"DESCRIBES", "CONTAINS"},
            )

            (release / "lib/foo-1.0/ebin/foo.beam").write_bytes(b"changed")
            changed = release_spdx.document(
                release, MODULE.report(release, source, "a" * 40), "2026-09-27T00:00:00Z"
            )
            self.assertNotEqual(document["documentNamespace"], changed["documentNamespace"])


if __name__ == "__main__":
    unittest.main()
