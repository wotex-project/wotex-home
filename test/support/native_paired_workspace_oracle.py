"""Freeze paired workspace action transitions without Home, BEAM or Swift."""
import copy
import hashlib
import json
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures/profiles"


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def allocate():
    source = json.loads((FIXTURES / "native-generation-workspace-v2.json").read_text())
    cases = []
    for vector in source["cases"]:
        before = json.loads(vector["document"])
        if before[1] == 9223372036854775807:
            continue
        for index, entry in enumerate(before[2]):
            if entry[1][0] != "paired":
                continue
            for action in ["retain", "intent", "clear", "archive", "restore"]:
                after = copy.deepcopy(before)
                if action in ["intent", "clear"]:
                    changed = action == "intent"
                    if entry[5] != changed:
                        after[1] += 1
                        after[2][index][5] = changed
                elif action == "archive":
                    after[1] += 1
                    del after[2][index]
                pending_before = ["wotex-home.native-pending.v8", 7, []]
                pending_after = copy.deepcopy(pending_before)
                if action == "restore":
                    original = entry[4][-1] if entry[4] else entry[3]
                    kind = "attempt" if entry[4] else "preparation"
                    pending_after[1] += 1
                    pending_after[2] = [["generation", entry[0], entry[1],
                                          ["generation_operation", kind, original], ["pending"]]]
                body = {"case": vector["case"] + "-" + action, "action": action, "index": index,
                        "before": canonical(before), "after": canonical(after),
                        "pending_before": canonical(pending_before), "pending_after": canonical(pending_after)}
                body["after_sha256"] = hashlib.sha256(body["after"].encode()).hexdigest()
                body["pending_sha256"] = hashlib.sha256(body["pending_after"].encode()).hexdigest()
                cases.append(body)
    return {"oracle": "Independent Python intent/removal/pending transitions from frozen v2 roots; no owner invocation", "cases": cases}


if __name__ == "__main__":
    target = FIXTURES / "native-paired-workspace-transitions.json"
    target.write_text(json.dumps(allocate(), ensure_ascii=False, indent=2) + "\n")
    print(f"{len(allocate()['cases'])} transitions; {target.name}: {hashlib.sha256(target.read_bytes()).hexdigest()}")
