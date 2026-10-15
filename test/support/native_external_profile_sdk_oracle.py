"""Freeze original/receipt correspondence without importing Home or Swift."""

import hashlib
import json
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures/profiles"
MAX = 9223372036854775807


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def load(name):
    return json.loads((FIXTURES / (name + ".json")).read_text())


def allocate():
    cases = []

    def add(name, kind, document, receipt, accepted):
        cases.append(dict(name=name, kind=kind, document=document,
                          receipt=receipt, accepted=accepted))

    for family in ["temperature", "research", "multi"]:
        samples = []
        if family != "multi":
            samples.append(("inspection", "inspection", load("external-inspections")[family]))
            samples += [("trust", action, load("external-trust")[family][action])
                        for action in ["approve", "revoke"]]
        samples += [("target", action, load("external-target-selections")[family][action])
                    for action in ["select", "revoke"]]
        for kind, action, sample in samples:
            document, receipt = sample["input_document"], sample["receipt"]
            name = family + "-" + kind + "-" + action
            assert receipt["input_sha256"] == hashlib.sha256(document.encode()).hexdigest()
            add(name, kind, document, receipt, True)
            bad_fields = {"input_sha256": "0" * 64, "operation_id": "other:original",
                          "authority_epoch": 2}
            if kind == "inspection":
                bad_fields["reader_basis_sha256"] = "0" * 64
            if kind == "trust":
                bad_fields.update(artifact_digest="0" * 64,
                                  policy_generation=receipt["policy_generation"] + 1)
            if kind == "target":
                bad_fields.update(target_id="other:target", artifact_digest="0" * 64,
                                  trust_revision=receipt["trust_revision"] - 1,
                                  policy_generation=receipt["policy_generation"] + 1)
                if action == "select":
                    bad_fields["source_selection_sha256"] = "0" * 64
            for field, value in bad_fields.items():
                altered = dict(receipt, **{field: value})
                add(name + "-wrong-" + field, kind, document, altered, False)
            altered = dict(receipt, revision=receipt["revision"] + 1)
            if kind == "trust" and receipt["trust_generation"] == 1:
                altered["artifact_first_approval_revision"] = altered["revision"]
            if kind == "target" and action == "select":
                altered["binding_revision"] = altered["revision"]
            add(name + "-wrong-revision", kind, document, altered, False)

            # Keep a structurally valid typed receipt; change only an original
            # counter and rebind its complete input SHA independently.
            indexes = {"trust": {"expected_trust": 5, "expected_policy": 6},
                       "target": {"expected_selection": 8, "expected_resource": 9}}
            for label, index in indexes.get(kind, {}).items():
                for suffix, counter in [("", json.loads(document)[1][index] + 1), ("-max", MAX)]:
                    value = json.loads(document)
                    value[1][index] = counter
                    changed_document = canonical(value)
                    altered = dict(receipt, input_sha256=hashlib.sha256(changed_document.encode()).hexdigest())
                    add(name + "-wrong-" + label + suffix, kind, changed_document, altered, False)
            if action in ["approve", "select"]:
                value = json.loads(document)
                value[1][3] = "revoke"
                for index in ([7, 8] if kind == "trust" else range(10, 15)):
                    value[1][index] = None
                changed_document = canonical(value)
                altered = dict(receipt, input_sha256=hashlib.sha256(changed_document.encode()).hexdigest())
                add(name + "-wrong-action", kind, changed_document, altered, False)
            value = json.loads(document)
            value[1][2] = MAX
            changed_document = canonical(value)
            altered = dict(receipt, input_sha256=hashlib.sha256(changed_document.encode()).hexdigest())
            add(name + "-revision-no-room", kind, changed_document, altered, False)

            # These outputs cannot be derived from the original. Refusing an
            # otherwise valid identity invents knowledge the client lacks.
            opaque = {"inspection": ["result_sha256", "capture_digest", "envelope_sha256"],
                      "trust": ["outcome_sha256"], "target": ["outcome_sha256"]}[kind]
            if kind == "trust" and action == "approve":
                opaque += ["reader_basis_sha256"]
            if kind == "target" and action == "revoke":
                opaque += ["source_selection_sha256"]
            for field in opaque:
                add(name + "-opaque-" + field, kind, document, dict(receipt, **{field: "9" * 64}), True)
    sample = load("external-inspections")["temperature"]
    value = json.loads(sample["input_document"])
    value[1][2] = MAX - 1
    document = canonical(value)
    receipt = dict(sample["receipt"], revision=MAX, input_sha256=hashlib.sha256(document.encode()).hexdigest())
    add("inspection-signed-maximum-receipt", "inspection", document, receipt, True)
    return dict(oracle="independent Python original-derived joins over frozen owning receipts", cases=cases)


if __name__ == "__main__":
    path = FIXTURES / "native-external-profile-sdk.json"
    value = allocate()
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    valid = sum(case["accepted"] for case in value["cases"])
    print(f'{valid} accepted, {len(value["cases"]) - valid} refused; SHA256 {hashlib.sha256(path.read_bytes()).hexdigest()}')
