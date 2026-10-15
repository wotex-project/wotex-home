#!/usr/bin/env python3
"""Verify frozen collection arithmetic and report precedence without Home/WoTEx.

This checks synthetic software entry vectors only. It writes no fixture, launches
no producer, signs no evidence and establishes no current Store or device fact.
"""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAX_I64 = (1 << 63) - 1
MIN_I64 = -(1 << 63)
MAX_U64 = (1 << 64) - 1


def coordinates(case):
    origin = case["origin_ms"]
    received = int(case["receipt_us"])
    deadline = int(case["deadline_us"])
    if not all(MIN_I64 <= x <= MAX_I64 for x in (origin * 1000, received, deadline)):
        return {"error": "external_input_limit"}
    receipt_ms = received // 1000 - origin
    owner_ms = deadline // 1000 - origin
    declaration = receipt_ms + case["declaration_freshness_ms"]
    mapping = receipt_ms + case["mapping_freshness_ms"]
    if any(x > MAX_I64 or x < MIN_I64 for x in (receipt_ms, owner_ms, declaration, mapping)):
        return {"error": "external_input_limit"}
    if receipt_ms < 0 or owner_ms < 0 or receipt_ms > case["sampled_ms"]:
        return {"error": "invalid"}
    expires = min(owner_ms, declaration, mapping)
    return {
        "received_store_ms": receipt_ms,
        "owner_expires_ms": owner_ms,
        "expires_ms": expires,
        "reason": "expired" if case["sampled_ms"] >= expires else None,
    }


def report_reason(case):
    if not case["clock_valid"]:
        return "invalid"
    if case["expired"]:
        return "expired"
    if case["quality"] != "usable":
        return case["quality"]
    if case["sequence"] is None:
        return "missing_sequence"
    if int(case["sequence"]) > MAX_I64:
        return "unsupported_external_input"
    if case["continuity"] in ("retained", "replayed", "gap"):
        return case["continuity"]
    if case["continuity"] == "unknown":
        return "baseline_required"
    assert case["continuity"] in ("baseline", "continuous")
    return None


def fact_id(identity):
    data = json.dumps(identity, ensure_ascii=False, separators=(",", ":")).encode()
    return "home:external-input:" + hashlib.sha256(
        b"wotex-home.external-input-fact@1\n" + data
    ).hexdigest()


def main():
    vectors = json.loads(
        (ROOT / "test/fixtures/profiles/external-input-collection.json").read_text()
    )
    assert vectors["scope"] == "synthetic_software_entry_only"
    for case in vectors["clock_cases"]:
        assert coordinates(case) == case["expected"], case["id"]
    for case in vectors["report_cases"]:
        assert report_reason(case) == case["expected"], case["id"]
    for case in vectors["uncertainty_cases"]:
        micros = int(case["uncertainty_us"])
        assert 0 <= micros <= MAX_U64
        millis = micros // 1000 + (micros % 1000 != 0)
        assert millis == case["expected_ms"] and millis <= MAX_I64

    entry = json.loads(
        (ROOT / "test/fixtures/profiles/routine-external-inputs.json").read_text()
    )
    item = entry["snapshot"]["items"][0]
    ref = item["report_ref"]
    identity = [
        item["target_id"], item["capability_key"], item["install_revision"],
        ref["owner_epoch"], ref["report_id"], ref["report_sha256"],
    ]
    assert fact_id(identity) == item["projection"]["fact"]["id"]
    changed = identity.copy()
    changed[2] += 1
    assert fact_id(changed) != fact_id(identity)
    counts = [len(vectors[key]) for key in ("clock_cases", "report_cases", "uncertainty_cases")]
    print(f"Verified {counts[0]} clock, {counts[1]} report and {counts[2]} uncertainty vectors plus the original frozen Fact ID")


if __name__ == "__main__":
    main()
