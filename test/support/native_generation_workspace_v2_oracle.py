"""Freeze v2 workspace roots without invoking Home, BEAM or Swift."""

import copy
import hashlib
import json
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures/profiles"


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def ordered(rows):
    return sorted(rows, key=lambda row: canonical(row[0][:3]).encode())


def allocate():
    source = json.loads((FIXTURES / "native-generation-workspace.json").read_text())
    valid, invalid = [], []
    for index, vector in enumerate(source["cases"]):
        root = json.loads(vector["document"])
        root[0] = "wotex-home.native-generation-workspace.v2"
        row = root[2][0]
        epoch = row[0][2]
        row[0][3] = f"paired-controller-v1:{epoch}:" + "6" * 64
        row[1] = ["paired", "1" * 64, "2" * 64, 1, "c" * 64]
        valid.append((f"paired-{index}", copy.deepcopy(root)))
        expected = json.loads(row[3])[1][2]
        at_floor = copy.deepcopy(root)
        at_floor[2][0][1][3] = expected
        valid.append((f"creation-floor-{index}", at_floor))
        old = copy.deepcopy(root)
        old[0] = "wotex-home.native-generation-workspace.v1"
        invalid.append((f"old-marker-{index}", old))
        for name, change in [
            ("principal", lambda r: r[0].__setitem__(3, "operator:wrong")),
            ("epoch-bool", lambda r: r[0].__setitem__(2, True)),
            ("creation-bool", lambda r: r[1].__setitem__(3, True)),
            ("creation-float", lambda r: r[1].__setitem__(3, 1.0)),
            ("creation-overflow", lambda r: r[1].__setitem__(3, 9223372036854775808)),
            ("creation-future", lambda r: r[1].__setitem__(3, expected + 1)),
            ("association", lambda r: r[1].__setitem__(1, "A" * 64)),
            ("custody-extra", lambda r: r[1].append(None)),
            ("intent", lambda r: r.__setitem__(5, 1)),
        ]:
            altered = copy.deepcopy(root)
            change(altered[2][0])
            invalid.append((f"{name}-{index}", altered))

    local = json.loads(source["cases"][0]["document"])[2][0]
    local[0][1] = "e" * 64
    mixed = copy.deepcopy(valid[0][1])
    mixed[2] = ordered(mixed[2] + [local])
    valid.append(("mixed-local-paired", mixed))
    valid.append(("empty-retained", ["wotex-home.native-generation-workspace.v2", 9223372036854775807, []]))
    duplicate = copy.deepcopy(valid[0][1])
    other = copy.deepcopy(duplicate[2][0])
    other[0][3] = "paired-controller-v1:1:" + "7" * 64
    duplicate[2].append(other)
    invalid.append(("same-scope-other-principal", duplicate))
    return {
        "oracle": "Independent Python v2 roots from frozen v1 originals; no owner invocation",
        "cases": [{"case": name, "document": canonical(root),
                   "sha256": hashlib.sha256(canonical(root).encode()).hexdigest()} for name, root in valid],
        "invalid": [{"case": name, "document": canonical(root)} for name, root in invalid],
    }


if __name__ == "__main__":
    target = FIXTURES / "native-generation-workspace-v2.json"
    target.write_text(json.dumps(allocate(), ensure_ascii=False, indent=2) + "\n")
    print(f"{target.name}: {hashlib.sha256(target.read_bytes()).hexdigest()}")
