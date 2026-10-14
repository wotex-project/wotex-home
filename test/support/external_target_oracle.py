"""Freeze external target wire examples without calling Home or WoTEx."""
import copy
import hashlib
import json
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[2] / "test/fixtures/profiles"


def wire(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def chunks(value):
    data, result = value.encode(), []
    while data:
        size = min(4096, len(data))
        while True:
            try:
                result.append(data[:size].decode())
                break
            except UnicodeDecodeError:
                size -= 1
        data = data[size:]
    return result


def read(name):
    return json.loads((FIXTURES / (name + ".json")).read_text())


FIELDS = "authority_epoch operation_id expected_revision action target_id artifact_digest expected_trust_revision expected_policy_generation expected_selection_revision expected_resource_revision source_ref source_owner_epoch source_selection_sha256 objects acknowledgement".split()
RECEIPT = "authority_epoch operation_id revision input_sha256 action target_id artifact_digest previous_selection_revision selection_generation resource_revision binding_revision trust_revision policy_generation source_selection_sha256 outcome_sha256 withdrawn_grants".split()
result = {}
for family in ("temperature", "research", "multi"):
    if family == "multi":
        import struct
        generic = read("generic-read-semantics")[family]
        source = read("external-source-selections")[family]
        v = generic["fixture"]
        docs = [("envelope", v["envelope"], None), ("profile", v["profile"], v["envelope"]["profile"])] + [("definition", d, r) for d, r in zip(v["definitions"], v["envelope"]["definitions"])]
        rows, refs = [], []
        for index, (kind, data, ref) in enumerate(docs):
            payload = wire(data).encode()
            raw = hashlib.sha256(payload).digest()
            frame = b"WOHA" + struct.pack(">BBI", 1, {"envelope": 6, "profile": 7, "definition": 8}[kind], len(payload)) + raw + payload
            rows.append([kind, [ref[k] for k in ("id", "version", "sha256")] if ref else None, hashlib.sha256(frame).hexdigest(), raw.hex(), len(payload)])
            refs.append({"object_digest": rows[-1][2], "first_revision": index + 2})
        artifact_doc = wire(["wotex-home.external-artifact@1", v["envelope"]["id"], v["envelope"]["version"], rows])
        objects = {"envelope_ref": refs[0], "profile": {"reference": v["envelope"]["profile"], "object_ref": refs[1]}, "definitions": [{"reference": r, "object_ref": h} for r, h in zip(v["envelope"]["definitions"], refs[2:])]}
        object_array = [[refs[0]["object_digest"], refs[0]["first_revision"]], [rows[1][1], [refs[1]["object_digest"], refs[1]["first_revision"]]], [[row[1], [h["object_digest"], h["first_revision"]]] for row, h in zip(rows[2:], refs[2:])]]
        decl = json.loads(generic["records"][0]["declaration_document"])
        env = ["wotex-home.external-profile-inspection@1", rows[0][3], [[row[1], row[3]] for row in rows[1:]], decl["projection_sha256"], decl["consumption_sha256"], [[c["channel_id"], [c["contract_ref"][k] for k in ("id", "version", "sha256")]] for c in v["envelope"]["home_contracts"]], [], [decl["producer"][k] for k in ("core_archive_sha256", "runtime_archive_sha256", "profiles_archive_sha256")]]
        inspection_doc = wire(["wotex-home.external-inspection-result@1", [source["data"]["reader_basis_sha256"], source["inputs"]["reader"]["capture"]["digest"]], env])
        trust = {"input": {"artifact_digest": generic["artifact_digest"]}, "outcome": {"artifact_document": artifact_doc, "inspection_document": inspection_doc}}
    else:
        trust = read("external-trust")[family]["approve"]
        inspection = read("external-inspections")[family]
        objects = copy.deepcopy(inspection["input"]["inspection"])
        objects.pop("reader_basis_sha256")
        object_array = json.loads(inspection["input_document"])[1][3][1:]
    source = read("external-source-selections")[family]
    generic = read("generic-read-semantics")[family]
    i = dict(zip(FIELDS, [1, "selection:1", 6, "select", generic["thing"]["id"], trust["input"]["artifact_digest"], 6, 1, 0, 0, source["inputs"]["source"]["source_ref"], "f" * 32, source["sha256"], objects, "operator_external_selection"]))
    # Reuse only the independently specified inspection array layout.
    values = [i[k] for k in FIELDS]
    values[13] = object_array
    input_document = wire(["wotex-home.external-target.v1", values])
    source_document = wire(["wotex-home.retained-source@1", "f" * 32, source["sha256"], chunks(source["input_document"]), chunks(wire(source["inputs"]["reader"])), chunks(wire(source["inputs"]["channels"]))])
    outcome = {"format": "wotex-home.external-target-result@1", "action": "select", "target_id": i["target_id"], "artifact_document": trust["outcome"]["artifact_document"], "inspection_document": trust["outcome"]["inspection_document"], "thing_document": generic["thing_document"], "source_document": source_document}
    # Registry's top-level map has stable Elixir map ordering; freeze that owner layout.
    thing = generic["thing"]
    if family == "multi":
        thing = copy.deepcopy(thing)
        policies = {c["channel_id"]: c["policy"] for c in source["inputs"]["channels"]}
        for record in thing["capabilities"]:
            declaration = json.loads(record["declaration_document"])
            declaration.update(policies[declaration["channel_id"]])
            record["declaration_document"] = wire(declaration)
            record["declaration_sha256"] = sha("wotex-home.external-read-declaration@1\n" + record["declaration_document"])
    outcome["thing_document"] = json.dumps({k: thing[k] for k in ("capabilities", "id", "profile_ref", "role")}, separators=(",", ":"), ensure_ascii=False)
    outcome_document = wire([outcome[k] if k in ("format", "action", "target_id") else chunks(outcome[k]) for k in outcome])
    receipt = dict(zip(RECEIPT, [1, "selection:1", 7, sha(input_document), "select", i["target_id"], i["artifact_digest"], 0, 1, 0, 7, 6, 1, source["sha256"], sha(outcome_document), 0]))
    revoke = copy.deepcopy(i)
    revoke.update(operation_id="selection:2", action="revoke", expected_revision=7, expected_selection_revision=7)
    for k in ("source_ref", "source_owner_epoch", "source_selection_sha256", "objects", "acknowledgement"):
        revoke[k] = None
    rev_doc = wire(["wotex-home.external-target.v1", [revoke[k] for k in FIELDS]])
    rev_outcome = {**outcome, "action": "revoke"}
    rev_out_doc = wire([rev_outcome[k] if k in ("format", "action", "target_id") else chunks(rev_outcome[k]) for k in rev_outcome])
    rev_receipt = {**receipt, "operation_id": "selection:2", "revision": 8, "input_sha256": sha(rev_doc), "action": "revoke", "previous_selection_revision": 7, "selection_generation": 2, "resource_revision": 1, "outcome_sha256": sha(rev_out_doc)}
    result[family] = {"select": {"input": i, "input_document": input_document, "outcome": outcome, "outcome_document": outcome_document, "receipt": receipt, "receipt_document": wire([receipt[k] for k in RECEIPT])}, "revoke": {"input": revoke, "input_document": rev_doc, "outcome": rev_outcome, "outcome_document": rev_out_doc, "receipt": rev_receipt, "receipt_document": wire([rev_receipt[k] for k in RECEIPT])}}
result["chunk_vectors"] = [{"document": value, "chunks": chunks(value)} for value in ("x" * 4096, "x" * 4095 + "é" + "z", "x" * 4093 + "😀" + "å", "€" * 3000)]
result["oracle"] = "Python json/hashlib and maximal UTF-8 byte splits; frozen predecessor vectors, no Home or WoTEx invoked."
(FIXTURES / "external-target-selections.json").write_text(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
