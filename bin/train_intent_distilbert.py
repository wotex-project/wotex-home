#!/usr/bin/env python3
"""Fine-tune and evaluate an offline English Light-intent DistilBERT candidate.

The authored corpus has a template-family and target-alias split. Evaluation
stays aggregate; no raw utterance is written to the artifact. The model has no
device registry, credential, command endpoint or authorization authority.
"""

import argparse
import hashlib
import json
import math
import os
import random
import re
import shutil
import sys
from pathlib import Path

import numpy as np
import sklearn
import torch
import transformers
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import make_pipeline
from transformers import AutoModelForSequenceClassification, AutoTokenizer

BASE_REVISION = "12040accade4e8a0f71eabdb258fecc2e7e948be"
BASE_SHA256 = {
    "LICENSE": "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1",
    "config.json": "69c94b0222d5d1f4b0ad027ca7416cdafb98378cbbb8305d0bf47c9365c60c83",
    "model.safetensors": "5e3f1108e3cb34ee048634875d8482665b65ac713291a7e32396fb18f6ff0063",
    "tokenizer.json": "ce64fce797c24f68df90b40a3f74f579b336a493db14bd583fd520ea0d8c9a98",
    "tokenizer_config.json": "a025160ef0431f1a392f6f050c1310f4c5d9fb6f275932dbccba73c4d214bf10",
    "vocab.txt": "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3",
}
LABELS = ["other", "light_power_on", "light_power_off"]
MAX_TOKENS = 48
SEED = 44
GRAMMAR = re.compile(r"\A(?:(?:please|could you|can you) )?(?:turn|switch) (on|off) (?:the )?([a-z0-9][a-z0-9 ._-]{0,79})\Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load_corpus(path: Path) -> dict[str, list[tuple[str, int]]]:
    corpus = json.loads(path.read_text(encoding="utf-8"))
    if corpus.get("schema") != "wotex-home.intent-corpus.v1" or \
            corpus.get("language") != "en" or corpus.get("labels") != LABELS or \
            set(corpus.get("splits", {})) != {"train", "validation", "test"}:
        raise ValueError("invalid intent corpus")
    result = {}
    used_texts = set()
    used_templates = set()
    used_targets = set()
    for split in ["train", "validation", "test"]:
        source = corpus["splits"][split]
        if set(source) != {"targets", *LABELS}:
            raise ValueError("invalid split fields")
        targets = source["targets"]
        if not targets or len(set(targets)) != len(targets) or used_targets.intersection(targets):
            raise ValueError("target aliases leak across splits")
        used_targets.update(targets)
        examples = []
        for label in LABELS:
            templates = source[label]
            if not templates or len(set(templates)) != len(templates):
                raise ValueError("empty or duplicate template family")
            for template in templates:
                if not isinstance(template, str) or len(template.encode("utf-8")) > 256:
                    raise ValueError("invalid template")
                if label != "other":
                    if template.count("{target}") != 1 or template in used_templates:
                        raise ValueError("template family leaks across splits")
                    used_templates.add(template)
                    rendered = [template.replace("{target}", target) for target in targets]
                else:
                    if "{target}" in template:
                        if template.count("{target}") != 1 or template in used_templates:
                            raise ValueError("negative template family leaks across splits")
                        used_templates.add(template)
                        rendered = [template.replace("{target}", target) for target in targets]
                    else:
                        rendered = [template]
                for phrase in rendered:
                    if phrase in used_texts or not phrase or len(phrase.encode("utf-8")) > 256:
                        raise ValueError("duplicate or overlong example")
                    used_texts.add(phrase)
                    examples.append((phrase, LABELS.index(label)))
        authorized_aliases = set(targets)
        if any(grammar_intent(phrase, authorized_aliases) != label for phrase, label in examples):
            raise ValueError(f"corpus label disagrees with exact grammar/alias gate: {split}")
        result[split] = examples
    return result


def predict_model(model, encodings: dict, device: str) -> np.ndarray:
    model.eval()
    chunks = []
    with torch.inference_mode():
        for offset in range(0, encodings["input_ids"].shape[0], 16):
            batch = {
                name: tensor[offset:offset + 16].to(device)
                for name, tensor in encodings.items()
            }
            logits = model(**batch).logits
            chunks.append(torch.softmax(logits, dim=-1).cpu().numpy())
    return np.concatenate(chunks)


def calibrate(probabilities: np.ndarray, labels: list[int]) -> dict[str, float]:
    top = probabilities.argmax(axis=1)
    thresholds = {}
    for label in [1, 2]:
        incorrect = [
            float(probabilities[index, label])
            for index, truth in enumerate(labels)
            if top[index] == label and truth != label
        ]
        thresholds[LABELS[label]] = min(1.0, max(0.5, max(incorrect, default=0.0) + 0.001))
    return thresholds


def metrics(probabilities: np.ndarray, labels: list[int], thresholds: dict[str, float]) -> dict:
    top = probabilities.argmax(axis=1)
    accepted = []
    for index, label in enumerate(top):
        ranked = np.sort(probabilities[index])
        if label == 0 or float(ranked[-1] - ranked[-2]) < 0.15 or \
                float(probabilities[index, label]) < thresholds[LABELS[label]]:
            accepted.append(0)
        else:
            accepted.append(int(label))
    positives = sum(label != 0 for label in labels)
    correct = sum(prediction == truth and truth != 0 for prediction, truth in zip(accepted, labels))
    false = sum(prediction != 0 and prediction != truth for prediction, truth in zip(accepted, labels))
    return {
        "examples": len(labels),
        "allowed_examples": positives,
        "other_examples": len(labels) - positives,
        "correct_allowed_accepted": correct,
        "false_accepted": false,
        "abstained": sum(prediction == 0 for prediction in accepted),
        "allowed_recall": round(correct / positives, 4) if positives else 0.0,
        "raw_confusion": [
            [int(sum(truth == row and predicted == column for truth, predicted in zip(labels, top)))
             for column in range(3)]
            for row in range(3)
        ],
    }


def grammar_intent(text: str, targets: set[str]) -> int:
    if len(text.encode("utf-8")) > 256 or any(char in text for char in "\n\r\t\0"):
        return 0
    normalized = re.sub(r" +", " ", text.strip().lower())
    match = GRAMMAR.fullmatch(normalized)
    if not match:
        return 0
    phrase = match.group(2).strip()
    if phrase not in targets or phrase in {"it", "them", "this", "that", "everything", "all"} or \
            any(fragment in phrase for fragment in [" and ", " or ", " then ", " not ", ".", ","]) or \
            phrase.endswith(" please"):
        return 0
    return 1 if match.group(1) == "on" else 2


def gate_metrics(probabilities: np.ndarray, examples: list[tuple[str, int]],
                 targets: set[str], threshold: float, margin: float) -> dict:
    decisions = []
    for (text, _truth), scores in zip(examples, probabilities):
        grammar = grammar_intent(text, targets)
        top = int(scores.argmax())
        ranked = np.sort(scores)
        decisions.append(
            top if grammar == top and top != 0 and float(scores[top]) >= threshold and
            float(ranked[-1] - ranked[-2]) >= margin else 0
        )
    labels = [label for _text, label in examples]
    positives = sum(label != 0 for label in labels)
    correct = sum(decision == truth and truth != 0 for decision, truth in zip(decisions, labels))
    false = sum(decision != 0 and decision != truth for decision, truth in zip(decisions, labels))
    return {
        "examples": len(labels),
        "allowed_examples": positives,
        "other_examples": len(labels) - positives,
        "correct_allowed_accepted": correct,
        "false_accepted": false,
        "abstained": sum(decision == 0 for decision in decisions),
        "allowed_recall": round(correct / positives, 4) if positives else 0.0,
    }


def calibrate_gate(probabilities: np.ndarray, examples: list[tuple[str, int]],
                   targets: set[str]) -> tuple[float, float]:
    candidates = []
    for threshold in [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]:
        for margin in [0.0, 0.05, 0.1, 0.15, 0.2]:
            result = gate_metrics(probabilities, examples, targets, threshold, margin)
            if result["false_accepted"] == 0:
                candidates.append((result["correct_allowed_accepted"], threshold, margin))
    if not candidates:
        raise ValueError("no safe model gate calibration")
    _, threshold, margin = max(candidates)
    return threshold, margin


def tokenize(tokenizer, examples: list[tuple[str, int]]) -> dict:
    return tokenizer(
        [text for text, _label in examples],
        padding="max_length", truncation=True, max_length=MAX_TOKENS,
        return_tensors="pt",
    )


def train(base: Path, corpus_path: Path, output: Path, epochs: int) -> None:
    if output.exists():
        raise ValueError("output model slot already exists")
    for name, expected in BASE_SHA256.items():
        path = base / name
        if not path.is_file() or sha256(path) != expected:
            raise ValueError(f"pinned base model file missing or changed: {name}")
    examples = load_corpus(corpus_path)
    corpus = json.loads(corpus_path.read_text(encoding="utf-8"))
    targets = {split: set(corpus["splits"][split]["targets"]) for split in examples}
    torch.manual_seed(SEED)
    random.seed(SEED)
    np.random.seed(SEED)
    torch.set_num_threads(4)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    tokenizer = AutoTokenizer.from_pretrained(base, local_files_only=True, use_fast=True)
    model = AutoModelForSequenceClassification.from_pretrained(
        base, local_files_only=True, use_safetensors=True, num_labels=3,
        id2label=dict(enumerate(LABELS)), label2id={label: index for index, label in enumerate(LABELS)},
    ).to(device)
    encoded = {split: tokenize(tokenizer, values) for split, values in examples.items()}
    labels = {split: [label for _text, label in values] for split, values in examples.items()}
    baseline = make_pipeline(
        TfidfVectorizer(analyzer="char_wb", ngram_range=(3, 5), min_df=1),
        LogisticRegression(max_iter=1_000, random_state=SEED),
    )
    baseline.fit([text for text, _ in examples["train"]], labels["train"])
    baseline_val = baseline.predict_proba([text for text, _ in examples["validation"]])
    baseline_test = baseline.predict_proba([text for text, _ in examples["test"]])
    baseline_thresholds = calibrate(baseline_val, labels["validation"])

    optimizer = torch.optim.AdamW(model.parameters(), lr=3e-5, weight_decay=0.01)
    best_state = None
    best_score = -math.inf
    history = []
    for epoch in range(1, epochs + 1):
        model.train()
        order = torch.randperm(len(labels["train"]))
        losses = []
        for indices in order.split(16):
            batch = {name: tensor[indices].to(device) for name, tensor in encoded["train"].items()}
            batch["labels"] = torch.tensor([labels["train"][index] for index in indices], device=device)
            optimizer.zero_grad(set_to_none=True)
            loss = model(**batch).loss
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimizer.step()
            losses.append(float(loss.detach().cpu()))
        val_probability = predict_model(model, encoded["validation"], device)
        val_thresholds = calibrate(val_probability, labels["validation"])
        val_metrics = metrics(val_probability, labels["validation"], val_thresholds)
        gate_threshold, gate_margin = calibrate_gate(
            val_probability, examples["validation"], targets["validation"]
        )
        gate_validation = gate_metrics(
            val_probability, examples["validation"], targets["validation"],
            gate_threshold, gate_margin
        )
        score = gate_validation["correct_allowed_accepted"] - 100 * gate_validation["false_accepted"]
        history.append({"epoch": epoch, "loss": round(sum(losses) / len(losses), 5),
                        "validation": val_metrics, "gate_validation": gate_validation})
        print(json.dumps(history[-1], sort_keys=True), flush=True)
        if score > best_score:
            best_score = score
            best_state = {key: tensor.detach().cpu().clone() for key, tensor in model.state_dict().items()}
    model.load_state_dict(best_state)
    val_probability = predict_model(model, encoded["validation"], device)
    test_probability = predict_model(model, encoded["test"], device)
    thresholds = calibrate(val_probability, labels["validation"])
    gate_threshold, gate_margin = calibrate_gate(
        val_probability, examples["validation"], targets["validation"]
    )
    gate_val = gate_metrics(
        val_probability, examples["validation"], targets["validation"],
        gate_threshold, gate_margin
    )
    gate_test = gate_metrics(
        test_probability, examples["test"], targets["test"], gate_threshold, gate_margin
    )
    baseline_gate_threshold, baseline_gate_margin = calibrate_gate(
        baseline_val, examples["validation"], targets["validation"]
    )
    evaluation = {
        "schema": "wotex-home.intent-evaluation.v1",
        "base_repository": "distilbert/distilbert-base-uncased",
        "base_revision": BASE_REVISION,
        "base_license": "Apache-2.0",
        "corpus_sha256": sha256(corpus_path),
        "language": "en",
        "supported_profile": "exact-english-light-v1",
        "gate": "model_top_agrees_with_exact_grammar_and_authorized_alias",
        "labels": LABELS,
        "device": device,
        "libraries": {"torch": torch.__version__, "transformers": transformers.__version__,
                      "sklearn": sklearn.__version__},
        "seed": SEED,
        "epochs_requested": epochs,
        "max_tokens": MAX_TOKENS,
        "split_sizes": {split: len(values) for split, values in examples.items()},
        "thresholds": thresholds,
        "margin": 0.15,
        "gate_threshold": gate_threshold,
        "gate_margin": gate_margin,
        "gate_validation": gate_val,
        "gate_test": gate_test,
        "grammar_validation": gate_metrics(
            np.eye(3)[[grammar_intent(text, targets["validation"]) for text, _ in examples["validation"]]],
            examples["validation"], targets["validation"], 0.3, 0.0
        ),
        "grammar_test": gate_metrics(
            np.eye(3)[[grammar_intent(text, targets["test"]) for text, _ in examples["test"]]],
            examples["test"], targets["test"], 0.3, 0.0
        ),
        "validation": metrics(val_probability, labels["validation"], thresholds),
        "test": metrics(test_probability, labels["test"], thresholds),
        "baseline": {
            "thresholds": baseline_thresholds,
            "validation": metrics(baseline_val, labels["validation"], baseline_thresholds),
            "test": metrics(baseline_test, labels["test"], baseline_thresholds),
            "gate_threshold": baseline_gate_threshold,
            "gate_margin": baseline_gate_margin,
            "gate_test": gate_metrics(
                baseline_test, examples["test"], targets["test"],
                baseline_gate_threshold, baseline_gate_margin
            ),
        },
        "training_history": history,
    }
    evaluation["outperforms_baselines_on_authored_set"] = (
        gate_val["false_accepted"] == 0 and gate_test["false_accepted"] == 0 and
        gate_test["correct_allowed_accepted"] >= max(
            evaluation["grammar_test"]["correct_allowed_accepted"],
            evaluation["baseline"]["gate_test"]["correct_allowed_accepted"]
        )
    )
    evaluation["production_admitted"] = False
    temporary = output.with_name(output.name + ".tmp")
    if temporary.exists():
        raise ValueError("temporary model slot already exists")
    temporary.mkdir(parents=True)
    model.to("cpu").save_pretrained(temporary, safe_serialization=True)
    tokenizer.save_pretrained(temporary)
    shutil.copy2(base / "LICENSE", temporary / "LICENSE.base")
    (temporary / "evaluation.json").write_text(json.dumps(evaluation, sort_keys=True, indent=2) + "\n")
    manifest = {
        "schema": "wotex-home.intent-artifact.v1",
        "files": {path.name: sha256(path) for path in sorted(temporary.iterdir()) if path.is_file()},
    }
    (temporary / "manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, output)
    print(json.dumps({"output": str(output), "outperforms_baselines_on_authored_set":
                      evaluation["outperforms_baselines_on_authored_set"], "gate_test": gate_test,
                      "raw_test": evaluation["test"], "baseline_gate_test":
                      evaluation["baseline"]["gate_test"]}, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=Path("_build/intent-base"))
    parser.add_argument("--corpus", type=Path, default=Path("priv/intent/corpus-v2.json"))
    parser.add_argument("--output", type=Path, default=Path("_build/intent-model-candidate"))
    parser.add_argument("--epochs", type=int, default=5)
    args = parser.parse_args()
    if args.epochs not in range(1, 9):
        parser.error("epochs must be between 1 and 8")
    try:
        train(args.base, args.corpus, args.output, args.epochs)
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print(f"intent training error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
