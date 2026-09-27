#!/usr/bin/env python3
"""Check the local candidate slot's file integrity and evaluation disposition.

The manifest is self-contained. A trusted release must additionally pin its
manifest digest; this check alone does not authenticate a model or admit it.
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

FILES = {
    "LICENSE.base", "config.json", "evaluation.json", "model.safetensors",
    "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.txt",
}
LABELS = ["other", "light_power_on", "light_power_off"]
FILE_LIMITS = {
    "LICENSE.base": 65_536,
    "config.json": 65_536,
    "evaluation.json": 1_048_576,
    "model.safetensors": 536_870_912,
    "special_tokens_map.json": 65_536,
    "tokenizer.json": 8_388_608,
    "tokenizer_config.json": 65_536,
    "vocab.txt": 2_097_152,
    "manifest.json": 65_536,
}
HEX64 = re.compile(r"\A[0-9a-f]{64}\Z")
BASE_REVISION = "12040accade4e8a0f71eabdb258fecc2e7e948be"


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON member: {key}")
        result[key] = value
    return result


def bounded_json(path: Path, limit: int):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= limit:
        raise ValueError(f"artifact JSON file is unavailable or overlong: {path.name}")
    try:
        return json.loads(path.read_bytes().decode("utf-8"), object_pairs_hook=strict_object)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError(f"invalid artifact JSON: {path.name}") from error


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def check(slot: Path, corpus: Path) -> dict:
    if not slot.is_dir() or slot.is_symlink():
        raise ValueError("candidate slot is missing or a symlink")
    files = set()
    for path in slot.iterdir():
        files.add(path.name)
        if len(files) > len(FILE_LIMITS):
            raise ValueError("candidate slot has extra files")
    if files != FILES | {"manifest.json"}:
        raise ValueError("candidate slot file set changed")
    manifest = bounded_json(slot / "manifest.json", FILE_LIMITS["manifest.json"])
    if not isinstance(manifest, dict) or set(manifest) != {"schema", "files"} or \
            manifest["schema"] != "wotex-home.intent-artifact.v1" or \
            not isinstance(manifest["files"], dict) or set(manifest["files"]) != FILES or \
            not all(isinstance(value, str) and HEX64.fullmatch(value)
                    for value in manifest["files"].values()):
        raise ValueError("invalid artifact manifest")
    for name, expected in manifest["files"].items():
        path = slot / name
        if path.is_symlink() or not path.is_file() or \
                not 0 < path.stat().st_size <= FILE_LIMITS[name] or sha256(path) != expected:
            raise ValueError(f"artifact file missing or changed: {name}")
    if corpus.is_symlink() or not corpus.is_file() or \
            not 0 < corpus.stat().st_size <= 1_048_576:
        raise ValueError("intent corpus is unavailable or overlong")
    config = bounded_json(slot / "config.json", FILE_LIMITS["config.json"])
    tokenizer = bounded_json(slot / "tokenizer_config.json", FILE_LIMITS["tokenizer_config.json"])
    if not isinstance(config, dict) or config.get("model_type") != "distilbert" or \
            config.get("architectures") != ["DistilBertForSequenceClassification"] or \
            config.get("id2label") != {str(index): label for index, label in enumerate(LABELS)} or \
            config.get("label2id") != {label: index for index, label in enumerate(LABELS)} or \
            not isinstance(tokenizer, dict) or \
            tokenizer.get("tokenizer_class") != "DistilBertTokenizer" or \
            tokenizer.get("do_lower_case") is not True or \
            tokenizer.get("model_max_length") != 512:
        raise ValueError("model or tokenizer label contract changed")
    evaluation = bounded_json(slot / "evaluation.json", FILE_LIMITS["evaluation.json"])
    if not isinstance(evaluation, dict) or \
            evaluation.get("schema") != "wotex-home.intent-evaluation.v1" or \
            evaluation.get("labels") != LABELS or \
            evaluation.get("corpus_sha256") != sha256(corpus) or \
            evaluation.get("base_revision") != BASE_REVISION or \
            evaluation.get("supported_profile") != "exact-english-light-v1" or \
            evaluation.get("language") != "en" or \
            evaluation.get("max_tokens") != 48 or \
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
