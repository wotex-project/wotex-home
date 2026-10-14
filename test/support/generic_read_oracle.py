"""Freeze retained read records independently of the Elixir implementation."""
import copy
import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "test/fixtures/profiles"


def read(name):
    return json.loads((FIXTURES / f"{name}.json").read_text())


def wire(data):
    return json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def identity(prefix, data):
    return sha((prefix + "\n" + wire(data)).encode())


def reference(profile):
    semantic = {k: v for k, v in profile.items() if k != "annotations"}
    return {"id": profile["id"], "version": profile["version"],
            "sha256": identity("wotex.profile.semantic@1", semantic)}


def retained(data, artifact):
    return {"format": "wotex-home.retained-read-declaration@1",
            "artifact_digest": artifact, "declaration_document": wire(data),
            "declaration_sha256": identity("wotex-home.external-read-declaration@1", data)}


declarations = read("external-read-declarations")
trust = read("external-trust")
result = {}
for family in ("temperature", "research"):
    record = retained(declarations[family]["data"], trust[family]["artifact_digest"])
    thing = {"id": record and declarations[family]["policy"]["thing_id"],
             "role": "EnvironmentalSensor", "profile_ref": "external:" + record["artifact_digest"],
             "capabilities": [record]}
    result[family] = {"record": record, "thing": thing, "thing_document": wire(thing)}

v = copy.deepcopy(read("temperature"))
r = read("research")
assert v["bindings"] == r["bindings"] and v["capture"] == r["capture"]
assert reference(v["profile"]) == v["envelope"]["profile"]
assert reference(r["profile"]) == r["envelope"]["profile"]
channel = copy.deepcopy(r["profile"]["channels"][0])
channel.update(id="density", affordance={"kind": "property", "name": "density"})
v["profile"].update(id="urn:example:profile:multi", channels=[channel, v["profile"]["channels"][0]])
v["definitions"] += r["definitions"]
v["envelope"].update(id="synthetic-multi", profile=reference(v["profile"]),
                      definitions=v["envelope"]["definitions"] + r["envelope"]["definitions"],
                      home_contracts=[{"channel_id": "density", "contract_ref": declarations["research"]["contract"]["reference"]},
                                      v["envelope"]["home_contracts"][0]])

compiler = {"arithmetic": "wotex.profile.rational@1", "capture": "wotex.profile.capture@1",
            "definition": "wotex.semantic@1", "format": "wotex.profile.compiler@1",
            "mechanical_schema": "wotex.profile.schema@1", "profile": "wotex.profile@1",
            "projection": "wotex.profile.projection@1", "version": "1.0.0"}
refs = [v["envelope"]["profile"], v["profile"]["binding"]] + v["contracts"] + v["envelope"]["definitions"]
definition_index = {d["id"]: {k: value for k, value in d.items() if k != "annotations"} for d in v["definitions"]}
plans = []
for c in v["profile"]["channels"]:
    plan = {k: c[k] for k in ("affordance", "semantic", "selector", "conversion", "invalid_values", "required", "operations")}
    plan.update(channel_id=c["id"], definition=definition_index[c["semantic"]["id"]], disposition="supported", reason=None)
    plans.append(plan)
projection = {"profile_sha256": v["envelope"]["profile"]["sha256"],
              "closure_sha256": identity("wotex.profile.closure@1", sorted(refs, key=lambda x: (x["id"], x["version"]))),
              "compiler_ref": {"id": "urn:wotex:profiles:compiler", "version": "1.0.0",
                               "sha256": identity("wotex.profile.compiler@1", compiler)},
              "binding": v["profile"]["binding"], "channel_plans": plans,
              "capture_digest": v["capture"]["digest"], "capture_epoch": v["capture"]["capture_epoch"]}
documents = [("envelope", v["envelope"], None), ("profile", v["profile"], v["envelope"]["profile"])]
documents += [("definition", d, ref) for d, ref in zip(v["definitions"], v["envelope"]["definitions"])]
objects = []
doc_ids = []
for kind, data, ref in documents:
    payload = wire(data).encode()
    raw = hashlib.sha256(payload).digest()
    frame = b"WOHA" + struct.pack(">BBI", 1, {"envelope": 6, "profile": 7, "definition": 8}[kind], len(payload)) + raw + payload
    array_ref = [ref["id"], ref["version"], ref["sha256"]] if ref else None
    objects.append([kind, array_ref, sha(frame), raw.hex(), len(payload)])
    if ref:
        doc_ids.append({"reference": ref, "raw_sha256": raw.hex()})
artifact = identity("wotex-home.external-artifact@1", objects)
basis = {"envelope_sha256": objects[0][3], "document_identities": doc_ids,
         "projection_sha256": identity("wotex-home.external-projection@1", projection),
         "producer": declarations["temperature"]["data"]["producer"],
         "home_contracts": v["envelope"]["home_contracts"], "exclusions": []}
records = []
for family, channel_id in (("research", "density"), ("temperature", "sample")):
    data = copy.deepcopy(declarations[family]["data"])
    data.update(thing_id="sensor:multi", capability_key=channel_id, channel_id=channel_id,
                evidence_ref="fixture:multi:1", **{k: basis[k] for k in ("envelope_sha256", "projection_sha256", "producer")},
                consumption_sha256=identity("wotex-home.external-consumption@1", basis))
    records.append(retained(data, artifact))
thing = {"id": "sensor:multi", "role": "EnvironmentalSensor", "profile_ref": "external:" + artifact, "capabilities": records}
result["multi"] = {"fixture": v, "records": records, "thing": thing, "thing_document": wire(thing), "artifact_digest": artifact}
result["oracle"] = "Python hashlib/struct and sorted compact JSON; frozen normative semantic, projection, closure, frame and declaration prefixes; no Elixir code invoked."
(FIXTURES / "generic-read-semantics.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
