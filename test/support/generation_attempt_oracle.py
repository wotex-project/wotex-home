"""Frozen ordered attempt identities from independent fixtures; no BEAM calls."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "fixtures/profiles"


def wire(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


preparations = json.loads((ROOT / "generation-preparations.json").read_text())
inputs = json.loads((ROOT / "generation-inputs.json").read_text())
vectors = {}
for family in ("temperature", "research"):
    p = preparations[family]
    request = dict(authority_epoch=1, operation_id="attempt:fixture", expected_revision=10,
                   preparation_operation_id="generation:fixture",
                   preparation_sha256=p["receipt"]["input_sha256"], attempt=1,
                   previous_operation_id=None, repair_export=False)
    document = wire(["wotex-home.generation-attempt.v1", [1, "attempt:fixture", 10,
                    "generation:fixture", request["preparation_sha256"], 1, None, False]])
    handoff = wire(["wotex-home.generation-attempt-input@1",
                    json.loads(inputs[family]["document"]), None])
    receipt = dict(authority_epoch=1, operation_id="attempt:fixture", revision=11,
                   input_sha256=sha(document), preparation_sha256=request["preparation_sha256"],
                   attempt=1, handoff_sha256=sha(handoff), provider_sha256=p["provider_sha256"],
                   disposition="handoff_reserved")
    fields = ("authority_epoch", "operation_id", "revision", "input_sha256",
              "preparation_sha256", "attempt", "handoff_sha256", "provider_sha256", "disposition")
    result = dict(disposition="unknown", reason=None, draft_ref=None,
                  bundle_ref=None, assessment=None)
    object_ops = {kind: "ga:" + sha("wotex-home.generation-object-operation@1\n" +
                  wire(["author:fixture", 1, "attempt:fixture", kind]))
                  for kind in ("draft", "bundle")}
    vectors[family] = dict(request=request, document=document, handoff_document=handoff,
                           receipt=receipt, receipt_document=wire([receipt[k] for k in fields]),
                           result=result, result_document=wire(["unknown", None, None, None, None]),
                           object_operations=object_ops)
vectors["oracle"] = "Python ordered arrays/hashlib and independently frozen projection/policy bytes; no Home or producer invocation."
(ROOT / "generation-attempts.json").write_text(json.dumps(vectors, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
