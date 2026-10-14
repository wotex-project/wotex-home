"""Independent durable observation bytes: normative WPF identities and prior rational vectors."""
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "test/fixtures/profiles"


def read(name):
    return json.loads((ROOT / (name + ".json")).read_text())


def wire(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def identity(prefix, value):
    return sha(prefix + "\n" + wire(value))


def chunks(value):
    data, result = value.encode(), []
    while data:
        length = min(4096, len(data))
        while True:
            try:
                result.append(data[:length].decode())
                break
            except UnicodeDecodeError:
                length -= 1
        data = data[length:]
    return result


compiler = {"arithmetic": "wotex.profile.rational@1", "capture": "wotex.profile.capture@1",
            "definition": "wotex.semantic@1", "format": "wotex.profile.compiler@1",
            "mechanical_schema": "wotex.profile.schema@1", "profile": "wotex.profile@1",
            "projection": "wotex.profile.projection@1", "version": "1.0.0"}
receipt_fields = "authority_epoch report_owner_epoch report_id revision input_sha256 target_id capability_key selection_revision resource_revision trust_revision policy_generation source_selection_sha256 report_sha256 value_sha256 outcome_sha256 store_boot_epoch received_store_ms".split()
result = {}
for family in ("temperature", "research", "multi"):
    base = "research" if family == "multi" else family
    v = read("generic-read-semantics")["multi"]["fixture"] if family == "multi" else read(family)
    source = read("external-source-selections")[family]
    report_vector = read("external-transport-reports")[family]
    report = report_vector["report"]
    channel = next(c for c in v["profile"]["channels"] if c["id"] == report["channel_id"])
    consumer = next(c["consumer"] for c in source["inputs"]["channels"] if c["channel_id"] == report["channel_id"])
    refs = [v["envelope"]["profile"], v["profile"]["binding"]] + v["contracts"] + v["envelope"]["definitions"]
    data = {k: report[k] for k in ("channel_id", "quality", "quality_reason", "continuity", "source_ref", "source_epoch", "sequence", "source_time", "receipt_time", "profile_sha256")}
    data.update(affordance=channel["affordance"], semantic=channel["semantic"], unit=consumer["unit"], normalized_value=read("external-values")[base]["expected_value"],
                closure_sha256=identity("wotex.profile.closure@1", sorted(refs, key=lambda r: (r["id"], r["version"]))),
                capture_digest=v["capture"]["digest"], compiler_ref={"id": "urn:wotex:profiles:compiler", "version": "1.0.0", "sha256": identity("wotex.profile.compiler@1", compiler)},
                interpretation="profile_declared", format="wotex-home.external-value@1",
                contract_ref=consumer["reference"], contract_sha256=identity("wotex-home.external-consumer@1", consumer), value_kind=consumer["value_kind"],
                consumption_sha256=None)
    thing = json.loads(read("external-target-selections")[family]["select"]["outcome"]["thing_document"])
    record = next(r for r in thing["capabilities"] if json.loads(r["declaration_document"])["channel_id"] == report["channel_id"])
    declaration = json.loads(record["declaration_document"])
    data["consumption_sha256"] = declaration["consumption_sha256"]
    value_doc = wire(data)
    value_sha = sha("wotex-home.external-value@1\n" + value_doc)
    original = {"report_owner_epoch": "f" * 32, "report_id": "packet:1"}
    input_doc = wire(["wotex-home.external-observation.v1", original["report_owner_epoch"], original["report_id"]])
    outcome = {"format": "wotex-home.external-observation-result@1", "report_document": report_vector["document"], "value_document": value_doc, "value_sha256": value_sha, "target_selection_revision": 7, "declaration_sha256": record["declaration_sha256"], "source_selection_sha256": source["sha256"]}
    outcome_doc = wire([outcome["format"], chunks(outcome["report_document"]), chunks(value_doc), value_sha, 7, outcome["declaration_sha256"], source["sha256"]])
    receipt = dict(zip(receipt_fields, [1, "f" * 32, "packet:1", 8, sha(input_doc), thing["id"], declaration["capability_key"], 7, 0, 6, 1, source["sha256"], report_vector["report_sha256"], value_sha, sha(outcome_doc), "boot:fixture", 10]))
    result[family] = {"input": original, "input_document": input_doc, "outcome": outcome, "outcome_document": outcome_doc, "receipt": receipt, "receipt_document": wire([receipt[k] for k in receipt_fields]), "value": data}
result["schema_columns"] = {"profile_external_observations": ["report_owner_epoch", "report_id", "input_document", "outcome_document", "receipt_document", "revision"], "profile_external_observation_current": ["target_id", "capability_key", "revision"], "profile_external_observation_sequences": ["target_id", "channel_id", "source_epoch", "sequence", "revision"]}
result["oracle"] = "Python json/hashlib and independent prior rational/reference/closure/compiler vectors; no Home/WoTEx invoked."
(ROOT / "external-observations.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
