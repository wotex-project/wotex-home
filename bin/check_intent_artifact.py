#!/usr/bin/env python3
"""Check the local candidate slot's file integrity and evaluation disposition.

The manifest is self-contained. A trusted release must additionally pin its
manifest digest; this check alone does not authenticate a model or admit it.
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

FILES = {
    "LICENSE.base", "config.json", "evaluation.json", "model.safetensors",
    "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.txt",
}
LABELS = ["other", "light_power_on", "light_power_off"]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def check(slot: Path, corpus: Path) -> dict:
    if not slot.is_dir() or slot.is_symlink():
        raise ValueError("candidate slot is missing or a symlink")
    files = {path.name for path in slot.iterdir()}
    if files != FILES | {"manifest.json"}:
        raise ValueError("candidate slot file set changed")
    manifest = json.loads((slot / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schema") != "wotex-home.intent-artifact.v1" or \
            set(manifest.get("files", {})) != FILES:
        raise ValueError("invalid artifact manifest")
    for name, expected in manifest["files"].items():
        path = slot / name
        if path.is_symlink() or not path.is_file() or sha256(path) != expected:
            raise ValueError(f"artifact file missing or changed: {name}")
    evaluation = json.loads((slot / "evaluation.json").read_text(encoding="utf-8"))
    if evaluation.get("schema") != "wotex-home.intent-evaluation.v1" or \
            evaluation.get("labels") != LABELS or \
            evaluation.get("corpus_sha256") != sha256(corpus) or \
            evaluation.get("production_admitted") is not False:
        raise ValueError("candidate evaluation metadata changed")
    return {
        "manifest_sha256": sha256(slot / "manifest.json"),
        "production_admitted": False,
        "outperforms_baselines_on_authored_set": evaluation.get(
            "outperforms_baselines_on_authored_set"
        ),
        "gate_test": evaluation.get("gate_test"),
        "grammar_test": evaluation.get("grammar_test"),
        "compact_baseline_gate_test": evaluation.get("baseline", {}).get("gate_test"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slot", type=Path)
    parser.add_argument("--corpus", type=Path, default=Path("priv/intent/corpus-v2.json"))
    args = parser.parse_args()
    try:
        print(json.dumps(check(args.slot, args.corpus), sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"intent artifact error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
