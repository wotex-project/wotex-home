"""Independent ordered preparation/policy/receipt identities; no BEAM calls."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "fixtures/profiles"
LIMITS = ["max_passages", "max_passage_bytes", "max_passages_bytes", "max_examples", "max_examples_bytes", "max_input_bytes"]


def wire(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def ref(value):
    return [value["object_digest"], value["first_revision"]]


def projection(value):
    return [value["contract_digest"], value["instruction"],
            [ref(p["reference"]) + [p["offset"], p["length"]] for p in value["passages"]],
            [ref(r) for r in value["examples"]], [value["limits"][k] for k in LIMITS]]


inputs = json.loads((ROOT / "generation-inputs.json").read_text())
mechanics = json.loads((ROOT / "authoring-mechanics.json").read_text())
vectors = {}
for family in ("temperature", "research"):
    p = inputs[family]["request"]
    provider = dict(id="generator:fixture", model_id="model:fixture", adapter_sha256="a" * 64, locality="remote")
    provider_values = [provider[k] for k in ("id", "model_id", "adapter_sha256", "locality")]
    provider_sha = sha("wotex-home.generation-provider@1\n" + wire(provider_values))
    policy = dict(principal_id="author:fixture", provider=provider, remote_export=True,
                  passages=p["passages"], examples=p["examples"], limits=p["limits"])
    policy_values = [policy["principal_id"], provider_values, True, projection(p)[2], projection(p)[3], projection(p)[4]]
    policy_sha = sha("wotex-home.generation-policy@1\n" + wire(policy_values))
    budget = dict(attempts=2, attempt_ms=30000, total_ms=60000)
    request = dict(authority_epoch=1, operation_id="generation:fixture", expected_revision=9,
                   provider_sha256=provider_sha, policy_sha256=policy_sha, remote_export=True,
                   projection=p, budget=budget)
    document = wire(["wotex-home.generation-preparation.v1", [1, request["operation_id"], 9,
                     provider_sha, policy_sha, True, projection(p), [2, 30000, 60000]]])
    receipt = dict(authority_epoch=1, operation_id=request["operation_id"], revision=10,
                   input_sha256=sha(document), projection_sha256=inputs[family]["sha256"],
                   basis_sha256=mechanics[family]["basis_sha256"], provider_sha256=provider_sha,
                   policy_sha256=policy_sha, disposition="prepared")
    receipt_document = wire([receipt[k] for k in ("authority_epoch", "operation_id", "revision", "input_sha256", "projection_sha256", "basis_sha256", "provider_sha256", "policy_sha256", "disposition")])
    vectors[family] = dict(policy=policy, policy_document=wire(policy_values), policy_sha256=policy_sha,
                            provider_sha256=provider_sha, request=request, document=document,
                            receipt=receipt, receipt_document=receipt_document)
vectors["oracle"] = "Python explicit ordered arrays, previous independent exact projection/mechanics vectors and hashlib; no Home/WoTEx invocation."
(ROOT / "generation-preparations.json").write_text(json.dumps(vectors, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
