"""Allocate v8 pending roots independently of Home, BEAM and Swift."""

import base64
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "test/fixtures/profiles"


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def sha(value):
    return hashlib.sha256(value).hexdigest()


def row(category, kind, original, payload=None):
    epoch = json.loads(original)[1][0]
    return [
        category,
        ["a" * 64, "b" * 64, epoch, f"paired-controller-v1:{epoch}:" + "6" * 64],
        ["paired", "1" * 64, "2" * 64, 1, "c" * 64],
        [category + "_operation", kind, original]
        + ([payload] if category == "authoring" else []),
        ["pending"],
    ]


def root(rows, version=8, revision=1):
    ordered = sorted(rows, key=lambda r: canonical(r[1] + [r[0]]).encode())
    return [f"wotex-home.native-pending.v{version}", revision, ordered]


def allocate():
    rows = []
    payload = "Paired source Ω\n".encode()
    digest = hashlib.sha256(payload).digest()
    frame = b"WOHA" + bytes([1, 1]) + len(payload).to_bytes(4, "big") + digest + payload
    original = canonical([
        "wotex-home.authoring-import.v1",
        [1, "import:paired-oracle", 2, ["source", sha(frame), digest.hex(), len(payload)]],
    ])
    rows.append(("import", row("authoring", "import", original,
                              base64.urlsafe_b64encode(payload).decode().rstrip("="))))
    for kind in ["candidate", "review"]:
        original = json.loads((FIXTURES / f"authoring-{kind}.json").read_text())["input_document"]
        rows.append((kind, row("authoring", kind, original)))
    vectors = json.loads((FIXTURES / "native-generation-originals.json").read_text())["cases"]
    for index, vector in enumerate(vectors):
        rows.append((f"generation-{index}", row("generation", vector["kind"], vector["document"])))

    local = ["power", ["d" * 64, "e" * 64, 1, "operator:local"],
             ["manual", "f" * 64], ["submit", "power:local", "lamp:fixture", 9, True], ["pending"]]
    valid = [(name, root([record])) for name, record in rows]
    for name, record in rows:
        if json.loads(record[3][2])[1][2] == 9223372036854775807:
            at_floor = copy.deepcopy(record)
            at_floor[2][3] = 9223372036854775807
            valid.append((name + "-creation-at-floor", root([at_floor])))
    valid.append(("mixed", root([local, rows[0][1], rows[3][1]])))
    valid.append(("empty-retained", root([], revision=9223372036854775807)))
    cases = [{"name": name, "document": canonical(value),
              "sha256": sha(canonical(value).encode())} for name, value in valid]
    invalid = []
    for name, record in rows:
        for version in [5, 6, 7]:
            invalid.append({"name": f"{name}-old-v{version}",
                            "document": canonical(root([record], version=version))})
        for label, change in [
            ("epoch-bool", lambda r: r[1].__setitem__(2, True)),
            ("creation-float", lambda r: r[2].__setitem__(3, 1.0)),
            ("creation-overflow", lambda r: r[2].__setitem__(3, 9223372036854775808)),
            ("creation-outside-floor", lambda r: r[2].__setitem__(3,
                0 if json.loads(r[3][2])[1][2] == 9223372036854775807 else 9223372036854775807)),
            ("principal", lambda r: r[1].__setitem__(3, "operator:wrong")),
            ("phase", lambda r: r.__setitem__(4, ["review", "token", "a" * 64])),
            ("extra-input", lambda r: r[3].append(None)),
        ]:
            altered = copy.deepcopy(record)
            change(altered)
            invalid.append({"name": f"{name}-{label}", "document": canonical(root([altered]))})
    duplicate = copy.deepcopy(rows[0][1])
    duplicate[1][3] = "paired-controller-v1:1:" + "7" * 64
    invalid.append({"name": "same-category-other-principal", "document": canonical(root([rows[0][1], duplicate]))})
    return {"format": "wotex-home.native-pending-paired-oracle.v1", "cases": cases, "invalid": invalid}


if __name__ == "__main__":
    target = FIXTURES / "native-pending-paired-authoring.json"
    target.write_text(json.dumps(allocate(), ensure_ascii=False, indent=2) + "\n")
    print(f"{target.name}: {sha(target.read_bytes())}")
