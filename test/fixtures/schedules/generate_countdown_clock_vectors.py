"""Independent inert monotonic activation bytes and integer boundary oracle.

Run from the repository root. This reads no Home code, clock, key or device.
"""
import hashlib
import json
from pathlib import Path


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def canonical(value):
    return json.dumps(value, separators=(",", ":"))


scope = {
    "deployment_id": digest("synthetic deployment"),
    "owner_id": digest("synthetic owner"),
    "authority_epoch": 1,
    "store_boot_epoch": "boot:one",
    "clock_generation": 1,
    "runtime_digest": digest("synthetic runtime"),
}
sample = ["wotex-home.schedule-clock.v1", "clock:synthetic", "b" * 64,
          "boot:one", 1, 1000, None, None, 10000, 0, "unqualified", True]
record = canonical(["wotex-home.schedule-activation-monotonic-clock.v1",
                    list(scope.values()), sample, 1000, 1000])
cases = []
for boot in ["boot:one", "boot:other"]:
    for generation in [1, 2]:
        for start in [0, 999, 1000, 1001]:
            for duration in [1000, 2000]:
                if boot != "boot:one":
                    expected = ["error", "old_boot"]
                elif generation != 1:
                    expected = ["error", "clock_changed"]
                elif start > 1000:
                    expected = ["error", "schedule_basis_changed"]
                elif start + duration <= 1000:
                    expected = ["error", "schedule_elapsed"]
                else:
                    expected = ["ok", 1000]
                cases.append({"trigger": ["countdown", boot, generation, start, duration],
                              "expected": expected})

document = {"format": "wotex-home.countdown-activation-vectors.v1",
            "scope": "inert_monotonic_clock_correspondence",
            "scope_fields": scope, "sample_document": canonical(sample),
            "now_ms": 1000, "clock_document": record,
            "clock_sha256": digest(record), "cases": cases}
destination = Path("test/fixtures/schedules/countdown_clock_vectors.json")
destination.write_text(json.dumps(document, indent=2) + "\n")
assert len(cases) == 32 and destination.stat().st_size <= 16384
print("wrote 32 inert countdown clock cases")
