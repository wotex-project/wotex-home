"""Independent raw JSON/identity vectors for composed mapping claims.

Uses only Python's JSON, Base64 and SHA-256 implementations. No Home or producer
constructor, digest helper, compiler, schema loader or code import participates.
"""

import base64
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNTIME = "8" * 64
OBLIGATIONS = [
    ("wotex-home.composed-security", ["current_authenticated_actor", "current_original_author",
     "exact_input_target_grants", "exact_output_target_grants", "current_installed_basis", "single_store_commit"]),
    ("wotex-home.composed-lifecycle", ["inert_proposal", "held_before_queue", "root_step_reservation_before_queue",
     "handoff_before_transport", "no_uncertain_retry", "no_refund", "preserve_partial_unknown"]),
    ("wotex-home.composed-scalar-report", ["current_qualified_device_report", "exact_typed_equality",
     "exclusive_original_receipt_expiry", "no_protocol_inference", "no_causation_inference"]),
]


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha(bytes_):
    return hashlib.sha256(bytes_.encode("utf-8")).hexdigest()


def digest(value):
    return "sha256:" + sha(canonical(value))


def separated(prefix, value):
    return sha(prefix + "\n" + canonical(value))


def iri(target):
    return "urn:wotex-home:thing:" + base64.urlsafe_b64encode(target.encode()).decode().rstrip("=")


def contracts():
    return [{"id": name, "version": "1", "requires": [], "semantic_digest": digest({
        "format": "wotex-home.routine-contract.v1", "id": name, "version": "1", "obligations": ordered
    })} for name, ordered in OBLIGATIONS]


def reference(record):
    return {key: record[key] for key in ("id", "version", "semantic_digest")}


def unit(kind, constraints):
    if kind == "fraction":
        return {"type": "integer", "enum": [], "unit": {
            "dimension": "fraction", "name": "ppm", "scale_n": 1, "scale_d": 1000000,
            "offset_n": 0, "offset_d": 1, "min": 0, "max": 1000000}}
    if kind == "kelvin":
        return {"type": "integer", "enum": [], "unit": {
            "dimension": "temperature", "name": "K", "scale_n": 1, "scale_d": 1,
            "offset_n": 0, "offset_d": 1, "min": constraints["min"], "max": constraints["max"]}}
    if kind == "smoke_state":
        return {"type": "enum", "enum": ["clear", "alarm"], "unit": None}
    assert kind == "boolean"
    return {"type": "boolean", "enum": [], "unit": None}


def basis(selector, capability, runtime):
    refs = [reference(record) for record in contracts()]
    write = selector["kind"] == "native_write"
    identity = ["wotex-home.native-routine-basis@1", selector["target_id"], selector["capability_key"],
                selector["kind"], selector["declaration_sha256"], runtime]
    body = {
        "format": "wotex.routines.basis@1", "id": "urn:wotex-home:routine-basis:" + sha(canonical(identity)),
        "version": "1", "affordance": {"type": "property", "name": selector["capability_key"],
        "operation": "writeproperty" if write else "readproperty"},
        "value": unit(capability["value_kind"], capability["constraints"]), "output": None,
        "security_contract": refs[0], "lifecycle_contract": refs[1], "required_contracts": [],
        "evidence": {"sources": ["device_report"], "freshness_ms": capability["freshness_ms"],
        "require_source_time": False, "continuity": "snapshot", "completion": "reported_match",
        "report_contract": refs[2]},
        "effects": {"resource_roles": ["target"] if write else [], "repeat": "never",
        "stop": "separate_effect" if write else "unsupported", "supersession": "block_until_known",
        "partial_possible": True, "unknown_possible": True},
        "timing": {"deadline_ms": 86400000, "duration_ms": 0, "dwell_ms": 0, "cooldown_ms": 0,
                   "uncertainty": "block"},
        "analysis": {"classification": "unsupported", "profile": None, "properties": []}, "annotations": {}}
    result = dict(body, byte_digest=digest(body), semantic_digest=digest(body),
                  implementation_digest="sha256:" + runtime, compiler_digest="sha256:" + runtime)
    return result, dict(reference(result), requires=refs)


def expected(bundle, environment, external_definition=None):
    records = {record["id"]: record for record in contracts()}
    bases, bindings, origins = {}, {}, []
    things = {row["target_id"]: row for row in environment["targets"]}
    for selector in bundle["bindings"]:
        target = things[selector["target_id"]]
        thing = json.loads(target["thing_document"])
        cap = next(c for c in thing["capabilities"]
                   if c.get("key") == selector["capability_key"]) if selector["kind"] != "external_read" else None
        if cap is not None:
            installed, record = basis(selector, cap, environment["runtime_sha256"])
            records[record["id"]] = record
        else:
            assert external_definition is not None
            installed = external_definition["mapping"]["basis"]
            for record in external_definition["registry"]:
                assert record["id"] not in records or records[record["id"]] == record
                records[record["id"]] = record
        bases[installed["id"]] = installed
        bindings[selector["name"]] = {"basis": reference(installed), "thing_id": iri(selector["target_id"]),
            "resource_roles": {"target": iri(selector["target_id"])} if selector["kind"] == "native_write" else {}}
        input_ = selector["input"]
        origins.append({key: selector[key] for key in
                        ("name", "kind", "target_id", "capability_key", "declaration_sha256")})
        origins[-1].update(resource_revision=target["resource_revision"],
            input_install_revision=input_["install_revision"] if input_ else None,
            input_generation=input_["generation"] if input_ else None,
            definition_sha256=input_["definition_sha256"] if input_ else None)
    registry = sorted(records.values(), key=lambda record: record["id"])
    bases = sorted(bases.values(), key=lambda record: record["id"])
    source_hash = separated("wotex-home.routine-source@1", bundle)
    mapping_hash = separated("wotex-home.composed-mapping-basis@1",
        [source_hash, environment["runtime_sha256"], origins, registry, bases, bindings])
    return {"source_sha256": source_hash, "mapping_sha256": mapping_hash, "bindings": origins,
        "context": {"registry": registry, "bases": bases, "bindings": bindings,
            "definitions": bundle["definitions"], "arguments": bundle["arguments"],
            "compiler_basis": "sha256:" + mapping_hash}}


def source(id_, binding, write, value):
    return {"format": "wotex.routines.source@1", "profile": "bounded-composition@1", "id": id_,
        "revision": "1", "parameters": {}, "bindings": [binding] if binding else [],
        "trigger": {"kind": "manual"},
        "condition": {"op": "literal", "value": True} if write or not binding else
                     {"op": "eq", "binding": binding, "value": value},
        "steps": {"id": "apply", "kind": "effect", "binding": binding, "input": value,
                  "completion": "reported_match"} if write else {"id": "nothing", "kind": "noop"},
        "overlap": "reject", "run_ms": 1000}


def capability(target, role, key, kind, constraints=None):
    return {"thing_id": target, "role": role, "key": key, "value_kind": kind,
        "unit": {"boolean": "none", "smoke_state": "none", "fraction": "ppm", "kelvin": "K"}[kind],
        "operations": ["read", "write"] if role == "Light" else ["read"],
        "risk_class": "ordinary" if role == "Light" else "sensitive", "profile_ref": "fixture:scalar:1",
        "evidence_ref": "fixture:scalar-report:1", "freshness_ms": 5000,
        "constraints": constraints or {}, "extensions": {}}


def vectors():
    cases = []
    for role, key, kind, value in [("Light", "power", "boolean", True),
            ("Light", "brightness", "fraction", 1), ("Light", "colour_temperature", "kelvin", 6500),
            ("SmokeDetector", "smoke_state", "smoke_state", "clear"),
            ("SmokeDetector", "fault", "boolean", False), ("SmokeDetector", "self_test", "boolean", False),
            ("SmokeDetector", "battery_fraction", "fraction", 1)]:
        target = "fixture:light" if role == "Light" else "fixture:smoke"
        caps = {key: capability(target, role, key, kind, {"min": 1500, "max": 9000} if kind == "kelvin" else {})}
        baseline = "power" if role == "Light" else "smoke_state"
        caps.setdefault(baseline, capability(target, role, baseline, "boolean" if role == "Light" else "smoke_state"))
        thing = {"id": target, "role": role, "profile_ref": "fixture:scalar:1",
                 "capabilities": [caps[k] for k in sorted(caps)]}
        document = canonical(thing)
        for write in ([False, True] if role == "Light" else [False]):
            kind_ = "native_write" if write else "native_read"
            name = kind_ + ":" + key
            bundle = {"format": "wotex-home.routine-source@1", "source": source(name, "selected", write, value),
                "definitions": [], "arguments": {}, "bindings": [{"name": "selected", "kind": kind_,
                "target_id": target, "capability_key": key, "declaration_sha256": sha(document), "input": None}]}
            environment = {"runtime_sha256": RUNTIME, "targets": [{"target_id": target,
                "resource_revision": 3, "thing_document": document}], "external_inputs": []}
            cases.append({"name": name, "bundle": bundle, "environment": environment,
                          "expected": expected(bundle, environment)})
    bundle = {"format": "wotex-home.routine-source@1", "source": source("noop", None, False, None),
              "definitions": [], "arguments": {}, "bindings": []}
    environment = {"runtime_sha256": RUNTIME, "targets": [], "external_inputs": []}
    cases.append({"name": "zero-binding-noop", "bundle": bundle, "environment": environment,
                  "expected": expected(bundle, environment)})
    retained = json.loads((ROOT / "test/fixtures/profiles/routine-external-inputs.json").read_text())
    definition = retained["definition"]
    declaration = definition["context"]["declaration"]
    declaration_document = canonical(declaration)
    record = {"format": "wotex-home.retained-read-declaration@1", "artifact_digest": "b" * 64,
        "declaration_document": declaration_document,
        "declaration_sha256": sha("wotex-home.external-read-declaration@1\n" + declaration_document)}
    target, key = declaration["thing_id"], declaration["capability_key"]
    thing = {"id": target, "role": "EnvironmentalSensor", "profile_ref": "external:" + "b" * 64,
             "capabilities": [record]}
    document = canonical(thing)
    bundle = {"format": "wotex-home.routine-source@1", "source": source("external:temperature", "reading", False, 2000),
        "definitions": [], "arguments": {}, "bindings": [{"name": "reading", "kind": "external_read",
        "target_id": target, "capability_key": key, "declaration_sha256": sha(document),
        "input": {"install_revision": 13, "generation": 2, "definition_sha256": retained["definition_sha256"]}}]}
    environment = {"runtime_sha256": RUNTIME, "targets": [{"target_id": target, "resource_revision": 1,
        "thing_document": document}], "external_inputs": [{"target_id": target, "capability_key": key,
        "install_revision": 13, "generation": 2, "definition_document": retained["definition_document"]}]}
    cases.append({"name": "external-temperature", "bundle": bundle, "environment": environment,
                  "expected": expected(bundle, environment, definition)})
    return {"scope": "synthetic_mapping_claims_only", "cases": cases}


if __name__ == "__main__":
    destination = ROOT / "test/fixtures/routines/composed-mapping.json"
    document = canonical(vectors()) + "\n"
    if sys.argv[1:] == ["--write"]:
        destination.write_text(document)
    else:
        assert sys.argv[1:] == ["--check"]
        assert destination.read_text() == document
    print(f"{len(vectors()['cases'])} independent mapping input/hash/Basis vectors agree")
