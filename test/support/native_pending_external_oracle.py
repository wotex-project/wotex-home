"""Freeze v9 pending roots independently of Home, BEAM and Swift."""

import base64
import copy
import hashlib
import json
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures/profiles"
MAX = 9223372036854775807


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def row(vector, custody="manual"):
    epoch = vector["input"]["authority_epoch"]
    principal = "operator:fixture"
    reference = ["manual", "c" * 64]
    if custody == "native":
        principal = f"native-setup-v1:{epoch}:operator"
        reference = ["native", "operator", 1, "c" * 64]
    if custody == "paired":
        principal = f"paired-controller-v1:{epoch}:" + "6" * 64
        reference = ["paired", "1" * 64, "2" * 64, 1, "c" * 64]
    return ["external_profile", ["a" * 64, "b" * 64, epoch, principal], reference,
            ["external_profile_operation", vector["kind"], vector["document"]], ["pending"]]


def root(rows, revision=1, version=9):
    rows = sorted(rows, key=lambda item: canonical(item[1] + [item[0]]).encode())
    return [f"wotex-home.native-pending.v{version}", revision, rows]


def allocate():
    originals = json.loads((FIXTURES / "native-external-profile-originals-v1.json").read_text())
    valid, invalid = [], []

    def accepted(name, value):
        document = canonical(value)
        valid.append(dict(name=name, document=document,
                          sha256=hashlib.sha256(document.encode()).hexdigest()))

    def refused(name, value):
        invalid.append(dict(name=name, document=canonical(value)))

    for vector in originals["valid"]:
        for custody in ["manual", "native", "paired"]:
            accepted(f'{vector["kind"]}-{vector["id"]}-{custody}', root([row(vector, custody)]))
    for kind in ["inspection", "trust", "target"]:
        vector = next(v for v in originals["valid"] if v["kind"] == kind)
        for custody in ["manual", "native", "paired"]:
            entry = row(vector, custody)
            for version in range(1, 9):
                refused(f"{kind}-{custody}-old-v{version}", root([entry], version=version))
            changes = [
                ("category", lambda r: r.__setitem__(0, "profile")),
                ("marker", lambda r: r[3].__setitem__(0, "external_operation")),
                ("kind", lambda r: r[3].__setitem__(1, "import")),
                ("epoch", lambda r: r[1].__setitem__(2, 2)),
                ("epoch-bool", lambda r: r[1].__setitem__(2, True)),
                ("phase", lambda r: r.__setitem__(4, ["review", "token", "d" * 64])),
                ("extra-input", lambda r: r[3].append(None)),
                ("missing-input", lambda r: r[3].pop()),
                ("original-object", lambda r: r[3].__setitem__(2, json.loads(r[3][2]))),
                ("original-space", lambda r: r[3].__setitem__(2, r[3][2] + " ")),
                ("ordinary-slot", lambda r: r[1].__setitem__(3, "x" * 129)),
            ]
            if custody != "manual":
                creation = 2 if custody == "native" else 3
                changes += [
                    ("creation-over-floor", lambda r, i=creation: r[2].__setitem__(i, MAX)),
                    ("creation-bool", lambda r, i=creation: r[2].__setitem__(i, True)),
                    ("creation-zero", lambda r, i=creation: r[2].__setitem__(i, 0)),
                    ("principal", lambda r: r[1].__setitem__(3, "operator:wrong")),
                ]
                floor = copy.deepcopy(entry)
                floor[2][creation] = vector["input"]["expected_revision"]
                accepted(f"{kind}-{custody}-creation-floor", root([floor]))
            if custody == "native":
                changes.append(("controller-role", lambda r: (
                    r[2].__setitem__(1, "controller"),
                    r[1].__setitem__(3, "native-setup-v1:1:controller"))))
            if custody == "manual":
                changes.append(("native-principal", lambda r: r[1].__setitem__(3, "native-setup-v1:1:operator")))
            for label, change in changes:
                altered = copy.deepcopy(entry)
                change(altered)
                refused(f"{kind}-{custody}-{label}", root([altered]))
    for vector in originals["invalid_wire"]:
        try:
            document = base64.b64decode(vector["payload_base64"]).decode()
        except UnicodeDecodeError:
            continue
        entry = row(next(v for v in originals["valid"] if v["kind"] == vector["kind"]))
        entry[3][2] = document
        refused("nested-" + vector["id"], root([entry]))

    legacy = json.loads((FIXTURES / "native-pending-paired-authoring.json").read_text())["cases"]
    for vector in legacy:
        value = json.loads(vector["document"])
        value[0] = "wotex-home.native-pending.v9"
        accepted("retained-" + vector["name"], value)
    mixed = json.loads(legacy[0]["document"])[2]
    external = row(originals["valid"][0])
    external[1][1] = "e" * 64
    accepted("mixed-external-paired-authoring", root(mixed + [external], revision=12))
    accepted("empty-retained", root([], revision=MAX))
    accepted("root-revision-max", root([external], revision=MAX))
    for i in range(1, 9):
        accepted(f"legacy-empty-v{i}", root([], version=i))
    capacity = []
    for i in range(17):
        entry = copy.deepcopy(external)
        entry[1][1] = f"{i:064x}"
        capacity.append(entry)
    accepted("capacity-sixteen", root(capacity[:16]))
    refused("capacity-seventeen", root(capacity))
    refused("duplicate", root([external, external]))
    other = copy.deepcopy(external)
    other[1][3] = "operator:other"
    refused("same-category-other-principal", root([external, other]))
    for label, revision in [("zero", 0), ("bool", True), ("float", 1.0), ("overflow", MAX + 1)]:
        refused("root-revision-" + label, root([external], revision=revision))
    refused("future-root", root([external], version=10))
    return dict(oracle="independent Python pending arrays from frozen owning originals", valid=valid, invalid=invalid)


if __name__ == "__main__":
    target = FIXTURES / "native-pending-external-profiles.json"
    target.write_text(json.dumps(allocate(), ensure_ascii=False, indent=2) + "\n")
    value = json.loads(target.read_text())
    print(f'{len(value["valid"])} valid, {len(value["invalid"])} invalid; SHA256 {hashlib.sha256(target.read_bytes()).hexdigest()}')
