"""Independent canonical decoded receipt bytes and hashes; no Elixir invoked."""
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "test/fixtures/profiles"


def read(name):
    return json.loads((ROOT / (name + ".json")).read_text())


def wire(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


vectors = {}
for family in ("temperature", "research", "multi"):
    base = "research" if family == "multi" else family
    report = copy.deepcopy(read("authoring-fixtures")[base]["fixtures"][0]["report"])
    source = read("external-source-selections")[family]
    report.update(source_ref=source["inputs"]["source"]["source_ref"],
                  source_epoch=source["inputs"]["source"]["source_epoch"],
                  receipt_time={"epoch": "f" * 32, "monotonic_us": "-5"})
    if family == "multi":
        report.update(channel_id="density", profile_sha256=read("generic-read-semantics")["multi"]["fixture"]["envelope"]["profile"]["sha256"])
    document = wire(report)
    digest = hashlib.sha256(("wotex-home.external-transport-report@1\n" + document).encode()).hexdigest()
    vectors[family] = {"report": report, "document": document, "report_sha256": digest,
                       "source_selection_sha256": source["sha256"]}
vectors["oracle"] = "Python sorted compact UTF-8 JSON and hashlib; exact WPF report decimal strings, prior independent fixtures; no Home or WoTEx called."
(ROOT / "external-transport-reports.json").write_text(json.dumps(vectors, indent=2, sort_keys=True) + "\n")
