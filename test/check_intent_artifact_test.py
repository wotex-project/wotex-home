import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "bin/check_intent_artifact.py"
SPEC = importlib.util.spec_from_file_location("check_intent_artifact", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_manifest(slot: Path) -> None:
    manifest = {
        "schema": "wotex-home.intent-artifact.v1",
        "files": {name: digest(slot / name) for name in MODULE.FILES},
    }
    (slot / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")


class IntentArtifactCheckTest(unittest.TestCase):
    def test_rejects_duplicate_manifest_members_and_label_swap_even_with_new_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            slot = root / "slot"
            slot.mkdir()
            corpus = root / "corpus.json"
            corpus.write_bytes(b"corpus")
            for name in MODULE.FILES - {"config.json", "tokenizer_config.json", "evaluation.json"}:
                (slot / name).write_bytes(b"fixture")
            config = {
                "model_type": "distilbert",
                "architectures": ["DistilBertForSequenceClassification"],
                "id2label": {str(index): label for index, label in enumerate(MODULE.LABELS)},
                "label2id": {label: index for index, label in enumerate(MODULE.LABELS)},
            }
            (slot / "config.json").write_text(json.dumps(config), encoding="utf-8")
            (slot / "tokenizer_config.json").write_text(json.dumps({
                "tokenizer_class": "DistilBertTokenizer",
                "do_lower_case": True,
                "model_max_length": 512,
            }), encoding="utf-8")
            (slot / "evaluation.json").write_text(json.dumps({
                "schema": "wotex-home.intent-evaluation.v1",
                "labels": MODULE.LABELS,
                "corpus_sha256": digest(corpus),
                "base_revision": MODULE.BASE_REVISION,
                "supported_profile": "exact-english-light-v1",
                "language": "en",
                "max_tokens": 48,
                "production_admitted": False,
            }), encoding="utf-8")
            write_manifest(slot)
            self.assertFalse(MODULE.check(slot, corpus)["production_admitted"])

            manifest = (slot / "manifest.json").read_text(encoding="utf-8")
            (slot / "manifest.json").write_text(manifest[:-1] + ', "files": {}}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate JSON member"):
                MODULE.check(slot, corpus)

            config["id2label"]["1"] = "light_power_off"
            (slot / "config.json").write_text(json.dumps(config), encoding="utf-8")
            write_manifest(slot)
            with self.assertRaisesRegex(ValueError, "label contract changed"):
                MODULE.check(slot, corpus)


if __name__ == "__main__":
    unittest.main()
