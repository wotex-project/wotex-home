"""Independent inert recovery inventory bytes; no Home or WoTEx invoked."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "test/fixtures/profiles"
selections = json.loads((ROOT / "external-target-selections.json").read_text())
result = {}
for family in ("temperature", "research", "multi"):
    document = selections[family]["select"]["outcome"]["thing_document"]
    thing = json.loads(document)
    capabilities = sorted(
        [["external_read", json.loads(c["declaration_document"])["capability_key"],
          c["declaration_sha256"]] for c in thing["capabilities"]], key=lambda c: c[1])
    record = [thing["id"], "active", thing["profile_ref"], 0,
              hashlib.sha256(document.encode()).hexdigest(), capabilities,
              None, [], [], ["unknown"]]
    value = ["wotex-home.controller-domains.v3", "e" * 64, [2, 2, 0, 0, 1, 0, 0], [record]]
    canonical = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    result[family] = {"record": record, "document": canonical,
                      "domain_digest": hashlib.sha256(canonical.encode()).hexdigest()}
result["oracle"] = "Python json/hashlib and prior independent retained Thing bytes; snapshot/count slots are inert fixture assertions, not an archive."
(ROOT / "external-recovery-domains.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
