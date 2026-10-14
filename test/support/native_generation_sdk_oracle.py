"""Allocate native SDK expectations from frozen inputs without Home/Swift calls."""

import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "test/fixtures/profiles"


def load(name):
    return json.loads((FIXTURES / (name + ".json")).read_text())


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def assessment_values(a):
    r = a["report"]
    return [a[k] for k in ("format", "basis_sha256", "draft_sha256", "bundle_sha256", "phase", "disposition", "capture_status")] + [
        [r[k] for k in ("format", "contract_sha256", "candidate_sha256", "disposition", "capture_status")] + [
            [[d[k] for k in ("phase", "code", "instance_path", "rule_id", "repair")] for d in r["diagnostics"]], r["truncated"]
        ]
    ] + [a[k] for k in ("home_consumption", "source_review", "fixture_status")]


def result_values(r):
    def ref(v):
        return None if v is None else [v["object_digest"], v["first_revision"]]
    return [r["disposition"], r["reason"], ref(r["draft_ref"]), ref(r["bundle_ref"]),
            None if r["assessment"] is None else assessment_values(r["assessment"])]


cases = []


def case(family, operation, member, value, original=None, result=None):
    v = {"family": family, "operation": operation, "response": {"api_version": 1, "outcome": "ok", member: value}}
    if original:
        v.update(original=original["document"], kind=original["kind"])
    if result:
        v["result_document"] = encode(result_values(result))
        if result["assessment"]:
            v["assessment_document"] = encode(assessment_values(result["assessment"]))
    cases.append(v)


preparations, attempts, operators, mechanics = [load(n) for n in
    ("generation-preparations", "generation-attempts", "generation-operators", "authoring-mechanics")]
for family in ("temperature", "research"):
    prep, attempt = preparations[family], attempts[family]
    originals = {"preparation": {"kind": "preparation", "document": prep["document"]},
                 "attempt": {"kind": "attempt", "document": attempt["document"]}}
    case(family, "authoring_generation_options", "authoring_generation_options", operators[family]["options"])
    case(family, "authoring_generation_prepare", "authoring_generation_receipt", prep["receipt"], originals["preparation"])
    case(family, "authoring_generation_start", "authoring_generation_attempt_receipt", attempt["receipt"], originals["attempt"])
    for state in ("prepared", "expired", "retired", "cancelled"):
        status = {"original": prep["receipt"], "state": state, "cancellation_revision": 12 if state == "cancelled" else None}
        case(family, "authoring_generation_status", "authoring_generation", status, originals["preparation"])
        if state == "cancelled":
            case(family, "authoring_generation_cancel", "authoring_generation", status, originals["preparation"])
    for state in ("running", "unknown", "cancelled"):
        status = {"original": attempt["receipt"], "state": state, "result": None, "result_revision": None}
        case(family, "authoring_generation_attempt_status", "authoring_generation_attempt", status, originals["attempt"])
    results = []
    for state in ("unavailable", "invalid_response", "unknown", "deadline_expired", "cancelled", "capacity"):
        results.append({"disposition": state, "reason": None, "draft_ref": None, "bundle_ref": None, "assessment": None})
    for reason in ("actor", "epoch", "maintenance", "policy", "basis", "source", "store"):
        results.append({"disposition": "withdrawn", "reason": reason, "draft_ref": None, "bundle_ref": None, "assessment": None})
    for phase, disposition, count in (("validate", "compatible", 0), ("validate", "invalid", 1), ("finalize", "invalid", 1), ("finalize", "invalid", 64)):
        m = mechanics[family]
        bundle = m["bundle_sha256"] if phase == "validate" else None
        a = {"format": "wotex-home.authoring-mechanics@1", "basis_sha256": m["basis_sha256"], "draft_sha256": m["draft_sha256"],
             "bundle_sha256": bundle, "phase": phase, "disposition": disposition, "capture_status": "not_supplied",
             "home_consumption": "not_assessed", "source_review": "not_assessed", "fixture_status": "not_supplied",
             "report": {"format": "wotex.profile.validation-report@1", "contract_sha256": m["contract_sha256"],
                        "candidate_sha256": bundle or m["draft_sha256"], "disposition": disposition, "capture_status": "not_supplied",
                        "diagnostics": [{"phase": "syntax", "code": "invalid_input", "instance_path": "/profile/binding",
                                         "rule_id": "SOURCE_SYNTAX", "repair": "Edit α é é \\\"quoted\\\" " + str(i)} for i in range(count)],
                        "truncated": count == 64}}
        results.append({"disposition": "candidate", "reason": None,
                        "draft_ref": {"object_digest": digest("frozen draft handle " + family), "first_revision": 12},
                        "bundle_ref": None if bundle is None else {"object_digest": digest("frozen bundle handle " + family), "first_revision": 13},
                        "assessment": a})
    for result in results:
        status = {"original": attempt["receipt"], "state": result["disposition"], "result": result, "result_revision": 14}
        case(family, "authoring_generation_attempt_status", "authoring_generation_attempt", status, originals["attempt"], result)

(FIXTURES / "native-generation-sdk.json").write_text(json.dumps({"oracle": "Independent Python field allocation from frozen owning vectors; no Home/Swift calls.", "cases": cases}, ensure_ascii=False, indent=2) + "\n")
print(len(cases), "independent native SDK responses")
