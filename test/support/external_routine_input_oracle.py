"""Independent entry oracle; generated claims are synthetic software fixtures only.

Only public keys/signatures are emitted. Random signing keys live solely in an
isolated OTP crypto process and disappear on exit. No production Home module is
loaded to calculate expected documents, hashes, ETF payloads or clock values.
Run without arguments to verify frozen data; --write intentionally rotates the
synthetic public keys/signatures and rewrites the entry fixture.
"""

import base64
import copy
import hashlib
import json
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAX_I64 = 9223372036854775807


def read(name):
    return json.loads((ROOT / "test/fixtures/profiles" / (name + ".json")).read_text())


def compact(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha(value):
    return hashlib.sha256(value if isinstance(value, bytes) else value.encode()).hexdigest()


def identity(prefix, value):
    return sha(prefix + "\n" + compact(value))


def chunks(document):
    data = document.encode()
    result = []
    while data:
        size = min(4096, len(data))
        while True:
            try:
                part = data[:size].decode()
                break
            except UnicodeDecodeError:
                size -= 1
        result.append(part)
        data = data[size:]
    return result


def etf(value):
    """ETF v2 subset, with binary-key maps independently sorted by term order."""
    def term(v):
        if v is None or isinstance(v, bool):
            name = {None: b"nil", True: b"true", False: b"false"}[v]
            return bytes([119, len(name)]) + name
        if isinstance(v, str):
            data = v.encode()
            return b"m" + struct.pack(">I", len(data)) + data
        if isinstance(v, tuple):
            return bytes([104, len(v)]) + b"".join(term(x) for x in v)
        if isinstance(v, list):
            return b"j" if not v else b"l" + struct.pack(">I", len(v)) + b"".join(term(x) for x in v) + b"j"
        if isinstance(v, dict):
            return b"t" + struct.pack(">I", len(v)) + b"".join(term(k) + term(v[k]) for k in sorted(v))
        if isinstance(v, int) and 0 <= v <= 255:
            return bytes([97, v])
        raise ValueError("Entry ETF subset changed")
    return bytes([131]) + term(value)


def main():
    assert sys.argv[1:] in [[], ["--write"]], "Use no arguments or --write"
    saved = None if sys.argv[1:] == ["--write"] else read("routine-external-inputs")
    source = read("temperature")
    original = read("routine-external-facts")
    producer = {"format": "wotex-home.profile-producer-runtime@1",
                "source_revision": "687a5cd70267fa47dbfb36e28eccad6ef2964fdf",
                "core_runtime_sha256": "1" * 64, "runtime_runtime_sha256": "2" * 64,
                "profiles_runtime_sha256": "3" * 64}
    runtime = {"format": "wotex-home.external-input-runtime@1", "routines_sha256": "4" * 64,
               "profiles": producer, "transport_sha256": "5" * 64, "storage_sha256": "6" * 64}
    runtime_hash = identity(runtime["format"], [runtime["routines_sha256"],
        [producer[k] for k in ["format", "source_revision", "core_runtime_sha256", "runtime_runtime_sha256", "profiles_runtime_sha256"]],
        runtime["transport_sha256"], runtime["storage_sha256"]])

    basis = {"envelope_sha256": sha(compact(source["envelope"])),
             "document_identities": [{"reference": ref, "raw_sha256": sha(compact(doc))}
                 for doc, ref in zip([source["profile"]] + source["definitions"],
                                    [source["envelope"]["profile"]] + source["envelope"]["definitions"])],
             "projection_sha256": source["expected"]["projection_sha256"],
             "producer": producer, "home_contracts": source["envelope"]["home_contracts"], "exclusions": []}
    consumption = identity("wotex-home.external-consumption@1", basis)
    declaration = json.loads(read("generic-read-semantics")["temperature"]["record"]["declaration_document"])
    declaration.update(producer=producer, consumption_sha256=consumption)

    selection = copy.deepcopy(read("external-source-selections")["temperature"]["inputs"])
    selection["reader"]["installed"]["producer"] = producer
    selection["source"].update(source_ref=original["mapping"]["observation"]["source_ref"], trust="authenticated_device")
    clock = {"format": "wotex.routines.receipt-clock@1", "projection": "floor_millisecond",
             "source_epoch": "f" * 32, "source_origin_us": "-10000000",
             "target_epoch": "store:entry", "target_origin_ms": 0}
    reader = {k: original["mapping"][k] for k in ["profile_sha256", "closure_sha256", "capture_digest", "compiler_ref", "reader_contract_ref", "semantic_ref", "channel_id", "affordance", "external_unit"]}
    reader["value_schema"] = source["definitions"][0]["value_schema"]
    context = {"format": "wotex-home.external-input-context@1", "authority_epoch": 1,
        "store_boot_epoch": "store:entry", "target_id": declaration["thing_id"], "capability_key": "sample",
        "selection_revision": 11, "resource_revision": 1, "binding_revision": 11,
        "trust_revision": 7, "policy_generation": 4, "selection_author": "operator:entry",
        "trust_author": "operator:entry", "source_owner_epoch": "a" * 32,
        "source_selection_sha256": identity("wotex-home.external-source-selection@1", selection),
        "source_ref": selection["source"]["source_ref"], "source_epoch": "e" * 32,
        "source_generation": 1, "source_method": "operator_configured", "source_trust": "authenticated_device",
        "stable_id_sha256": sha("wotex-home.external-stable-id@1\n" + selection["source"]["stable_id"]),
        "report_owner_epoch": "f" * 32, "reader_limits": source["reader_limits"],
        "declaration": declaration, "reader": reader, "receipt_clock": clock,
        "runtime": runtime, "runtime_sha256": runtime_hash}
    mapping = copy.deepcopy(original["mapping"])
    registry = copy.deepcopy(original["registry"])
    mapping["receipt_clock"] = clock
    mapping["basis"]["output"] = None
    for k in ["implementation_digest", "compiler_digest"]:
        mapping["basis"][k] = "sha256:" + runtime_hash
    semantic = {k: v for k, v in mapping["basis"].items()
                if k not in ["byte_digest", "semantic_digest", "implementation_digest", "compiler_digest"]}
    digest = "sha256:" + sha(compact(semantic))
    mapping["basis"]["semantic_digest"] = digest
    mapping["basis"]["byte_digest"] = digest
    mapping["legacy_basis_ref"]["semantic_digest"] = digest
    for row in registry:
        if row["id"] == mapping["basis"]["id"]:
            row["semantic_digest"] = digest
        for ref in row["requires"]:
            if ref["id"] == mapping["basis"]["id"]:
                ref["semantic_digest"] = digest
    mapping["sha256"] = identity("wotex.routines.input-mapping@1", {k: v for k, v in mapping.items() if k != "sha256"})
    for row in registry:
        if row["id"] == mapping["id"]:
            row["semantic_digest"] = "sha256:" + mapping["sha256"]
    limits = {**original["limits"], "max_depth": 16}
    definition = {"format": "wotex-home.external-input-definition@1", "context": context,
                  "mapping": mapping, "registry": registry, "limits": limits}
    limit_order = ["max_bytes", "max_depth", "max_nodes", "max_string_bytes", "max_collection_size", "max_integer"]
    document = compact(["wotex-home.external-input-definition.v1", *[chunks(compact(x)) for x in [context, mapping, registry]], [limits[k] for k in limit_order]])
    definition_hash = sha(definition["format"] + "\n" + document)

    programme_path = ROOT / "priv/qualification/external-routine-input-v1.json"
    programme = json.loads(programme_path.read_text())
    programme_hash = sha(programme_path.read_bytes())
    cohort = {k: "synthetic:entry" for k in ["hardware_sku", "hardware_revision", "firmware", "adapter_profile", "native_stack", "host_os", "runtime", "network_topology", "application", "model"]}
    cohort["source_identity_ref"] = "9" * 64
    cohort_hash = sha(etf(cohort))
    crypto = '''
    {case_pub, case_priv} = :crypto.generate_key(:eddsa, :ed25519)
    {decision_pub, decision_priv} = :crypto.generate_key(:eddsa, :ed25519)
    IO.puts(JSON.encode!([Base.url_encode64(case_pub, padding: false), Base.url_encode64(decision_pub, padding: false)]))
    for _ <- 1..8 do
      payload = IO.read(:stdio, :line) |> String.trim() |> Base.decode64!()
      signature = :crypto.sign(:eddsa, :none, payload, [case_priv, :ed25519])
      IO.puts(Base.url_encode64(signature, padding: false))
    end
    payload = IO.read(:stdio, :line) |> String.trim() |> Base.decode64!()
    IO.puts(Base.url_encode64(:crypto.sign(:eddsa, :none, payload, [decision_priv, :ed25519]), padding: false))
    '''
    process = subprocess.Popen(["elixir", "-e", crypto], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) if saved is None else None
    try:
        public_keys = json.loads(process.stdout.readline()) if process else [saved["case_public_key"], saved["decision_public_key"]]
        attestations, payload_vectors = [], []
        for index, case in enumerate(sorted(programme["cases"], key=lambda x: x["case_id"])):
            receipt = {**case, "receipt_id": case["case_id"] + ":synthetic", "status": "passed",
                "cohort": cohort, "source_identity_ref": cohort["source_identity_ref"],
                "command_sequence": ["synthetic-entry-only"], "assertions": [{"id": "synthetic-entry-only", "expected": True, "actual": True}],
                "artifact_digests": ["8" * 64], "exclusions": [], "blockers": [], "reviewer_ref": "case-entry"}
            payload = b"WOH11-reviewer-receipt-v1\0" + etf(("case-entry", programme_hash, receipt))
            if process:
                process.stdin.write(base64.b64encode(payload).decode() + "\n"); process.stdin.flush()
                signature = process.stdout.readline().strip()
            else:
                signature = saved["package"]["attestations"][index]["signature"]
            attestations.append({"receipt": receipt, "reviewer_key_id": "case-entry", "programme_digest": programme_hash, "signature": signature})
            payload_vectors.append(base64.b64encode(payload).decode())
        decision = {"format": "wotex-home.external-input-decision@1", "outcome": "allow_external_input",
            "definition_sha256": definition_hash, "programme_sha256": programme_hash, "cohort_sha256": cohort_hash,
            "evidence_set_sha256": sha(etf(attestations)), "reviewer_key_id": "decision-entry"}
        payload = b"WOH11-external-input-decision-v1\0" + etf(decision)
        if process:
            process.stdin.write(base64.b64encode(payload).decode() + "\n"); process.stdin.flush()
            signature = process.stdout.readline().strip()
            process.stdin.close()
            assert process.wait(timeout=10) == 0
        else:
            signature = saved["package"]["signed"]["signature"]
        signed = {"decision": decision, "signature": signature}
    finally:
        if process is not None and process.poll() is None:
            process.kill(); process.wait()
    package = {"format": "wotex-home.external-input-package@1", "definition_document": document,
               "signed": signed, "cohort": cohort, "attestations": attestations}
    package_document = compact(["wotex-home.external-input-package.v1", chunks(document), *[chunks(compact(x)) for x in [signed, cohort, attestations]]])
    change = {"authority_epoch": 1, "operation_id": "install:entry", "target_id": context["target_id"],
              "capability_key": "sample", "expected_install_revision": 0, "expected_generation": 0,
              "action": "install", "package_document": package_document}
    change_document = compact(["wotex-home.external-input.v1", 1, "install:entry", context["target_id"],
                               "sample", 0, 0, "install", chunks(package_document)])
    outcome = {"format": "wotex-home.external-input-result@1", "action": "install",
               "target_id": context["target_id"], "capability_key": "sample",
               "definition_sha256": definition_hash, "package_document": package_document}
    outcome_document = compact(["wotex-home.external-input-result.v1", "install", context["target_id"], "sample", definition_hash, chunks(package_document)])
    receipt = {"format": "wotex-home.external-input-receipt@1", "authority_epoch": 1,
               "operation_id": "install:entry", "target_id": context["target_id"], "capability_key": "sample",
               "revision": 21, "generation": 1, "install_revision": 21, "action": "install",
               "input_sha256": sha("wotex-home.external-input.v1\n" + change_document),
               "outcome_sha256": sha("wotex-home.external-input-result.v1\n" + outcome_document),
               "store_boot_epoch": "store:entry"}
    receipt_document = compact(["wotex-home.external-input-receipt.v1", *[receipt[k] for k in
        ["authority_epoch", "operation_id", "target_id", "capability_key", "revision", "generation", "install_revision", "action", "input_sha256", "outcome_sha256", "store_boot_epoch"]]])
    projection = copy.deepcopy(original["expected_result"])
    home_value = {**original["home_value_data"], "consumption_sha256": consumption}
    projection["external_value_sha256"] = identity("wotex-home.external-value@1", home_value)
    report_hash = identity("wotex-home.external-transport-report@1", original["report"])
    report_ref = {"owner_epoch": "f" * 32, "report_id": "report:7", "report_sha256": report_hash}
    fact = projection["fact"]
    fact["thing_id"] = "urn:wotex-home:thing:" + base64.urlsafe_b64encode(context["target_id"].encode()).decode().rstrip("=")
    fact["id"] = "home:external-input:" + identity("wotex-home.external-input-fact@1", [context["target_id"], "sample", 21, "f" * 32, "report:7", report_hash])
    fact["receipt_epoch"] = "store:entry"
    projection["mapping_ref"] = {k: mapping[k] for k in ["id", "version", "sha256"]}
    projection["binding_basis"]["input_mapping"] = mapping
    snapshot = {"format": "wotex-home.external-input-snapshot@1", "scope": "qualified_external_input_snapshot_only",
                "authority_epoch": 1, "store_revision": 23, "store_boot_epoch": "store:entry", "sampled_ms": 10000,
                "items": [{"target_id": context["target_id"], "capability_key": "sample", "install_revision": 21,
                           "selection_revision": 11, "resource_revision": 1, "report_revision": 23,
                           "report_ref": report_ref, "owner_expires_ms": (-1001 + 60000000 + 10000000) // 1000,
                           "binding_basis": projection["binding_basis"], "projection": projection, "reason": None}]}
    result = {"scope": "synthetic_software_entry_only", "oracle": "Python sorted JSON/SHA/ETF/integer arithmetic; OTP crypto signs independent bytes without Home modules",
        "definition": definition, "definition_document": document, "definition_sha256": definition_hash,
        "programme_sha256": programme_hash, "package": package, "package_document": package_document,
        "package_sha256": sha(package["format"] + "\n" + package_document),
        "change": change, "change_document": change_document, "outcome": outcome, "outcome_document": outcome_document,
        "receipt": receipt, "receipt_document": receipt_document, "snapshot": snapshot,
        "case_public_key": public_keys[0], "decision_public_key": public_keys[1],
        "case_signing_payloads_base64": payload_vectors, "decision_signing_payload_base64": base64.b64encode(payload).decode()}
    assert len(document.encode()) <= 262144 and len(package_document.encode()) <= 262144
    path = ROOT / "test/fixtures/profiles/routine-external-inputs.json"
    if saved is not None:
        assert result == saved, "Frozen entry data changed; inspect before explicit --write"
    else:
        path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    rows = [[public_keys[0], message, attestation["signature"]] for message, attestation in zip(payload_vectors, attestations)]
    rows.append([public_keys[1], base64.b64encode(payload).decode(), signed["signature"]])
    verify = '''
    for [key, payload, signature] <- IO.read(:stdio, :eof) |> JSON.decode!() do
      true = :crypto.verify(:eddsa, :none, Base.decode64!(payload), Base.url_decode64!(signature, padding: false),
        [Base.url_decode64!(key, padding: false), :ed25519])
    end
    '''
    subprocess.run(["elixir", "-e", verify], input=json.dumps(rows), text=True, check=True)
    print("Verified synthetic Definition", definition_hash, "and nine independent signature payloads; no signing keys retained")


if __name__ == "__main__":
    main()
