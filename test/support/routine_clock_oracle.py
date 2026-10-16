"""Independent canonical clock bytes, hashes and exact interval arithmetic.

Only Python JSON, hashlib and integer arithmetic are used; no Home or producer
implementation participates in these expected results.
"""

import base64
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
MAXIMUM = 2**63 - 1
MINIMUM = -(2**63)
POLICY_FIELDS = [
    "source_id", "reference_id", "procedure_ref", "qualification_digest", "runtime_digest",
    "source_digest", "approval_timeout_ms", "maximum_sample_ms", "maximum_discontinuity_ms",
    "drift_ppm", "qualified_run_ms", "monotonic_policy", "suspend_policy",
]
REQUEST_FIELDS = [
    "deployment_id", "owner_id", "authority_epoch", "store_boot_epoch", "elapsed_generation",
    "runtime_digest", "monotonic_origin_ms", "policy_sha256", "source_digest", "reference_epoch",
    "reference_started_ms", "lifecycle_generation", "lifecycle_started_ms", "challenge_nonce",
]


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def policy(**changes):
    return dict({
        "source_id": "fixture:continuous", "reference_id": "fixture:reference",
        "procedure_ref": "fixture:elapsed-procedure:1", "qualification_digest": "1" * 64,
        "runtime_digest": "2" * 64, "source_digest": "3" * 64,
        "approval_timeout_ms": 60000, "maximum_sample_ms": 1000,
        "maximum_discontinuity_ms": 10, "drift_ppm": 0, "qualified_run_ms": 86400000,
        "monotonic_policy": "invalidate_on_discontinuity",
        "suspend_policy": "invalidate_on_lifecycle_change",
    }, **changes)


def observation(lower, upper, continuous):
    return {
        "source_id": "fixture:continuous", "reference_id": "fixture:reference",
        "source_digest": "3" * 64, "reference_epoch": "4" * 32,
        "reference_started_ms": -10000, "lifecycle_generation": 1,
        "lifecycle_started_ms": -10000, "primary_lower_ms": lower,
        "primary_upper_ms": upper, "continuous_ms": continuous,
    }


def relation(old, new, p):
    delta = new["continuous_ms"] - old["continuous_ms"]
    allowance = p["maximum_discontinuity_ms"] + (delta * p["drift_ppm"] + 999999) // 1000000
    low = new["primary_lower_ms"] - old["primary_upper_ms"]
    high = new["primary_upper_ms"] - old["primary_lower_ms"]
    values = (delta, allowance, low, high, delta - allowance, delta + allowance)
    if any(v < MINIMUM or v > MAXIMUM for v in values):
        outcome = "routine_clock_limit"
    elif delta < 0 or new["primary_lower_ms"] < old["primary_upper_ms"]:
        outcome = "routine_clock_unavailable"
    elif low < delta - allowance or high > delta + allowance:
        outcome = "routine_clock_unavailable"
    else:
        outcome = "ok"
    return {"delta": delta, "allowance": allowance, "primary_delta_low": low,
            "primary_delta_high": high, "outcome": outcome}


def vectors():
    p = policy()
    document = canonical(["wotex-home.routine-elapsed-policy.v1"] + [p[k] for k in POLICY_FIELDS])
    request = {
        "deployment_id": "a" * 64, "owner_id": "b" * 64, "authority_epoch": 1,
        "store_boot_epoch": "fixture:boot", "elapsed_generation": 2,
        "runtime_digest": p["runtime_digest"], "monotonic_origin_ms": str(MINIMUM),
        "policy_sha256": sha(document), "source_digest": p["source_digest"],
        "reference_epoch": "4" * 32, "reference_started_ms": str(MINIMUM),
        "lifecycle_generation": 1, "lifecycle_started_ms": str(MINIMUM),
        "challenge_nonce": base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip("="),
    }
    request_array = ["wotex-home.routine-elapsed-request.v1"] + [request[k] for k in REQUEST_FIELDS]
    token_array = ["wotex-home.routine-elapsed-basis@1"] + request_array[1:]
    pairs = []
    for name, old, new, changes in [
        ("zero-drift-exact", observation(0, 0, 0), observation(1000, 1000, 1000), {}),
        ("exact-positive-allowance", observation(0, 0, 0), observation(1010, 1010, 1000), {}),
        ("one-over-positive", observation(0, 0, 0), observation(1011, 1011, 1000), {}),
        ("exact-negative-allowance", observation(0, 0, 0), observation(990, 990, 1000), {}),
        ("one-over-negative", observation(0, 0, 0), observation(989, 989, 1000), {}),
        ("whole-interval-counts", observation(0, 5, 0), observation(1000, 1006, 1000), {}),
        ("one-over-whole-interval", observation(0, 5, 0), observation(1000, 1011, 1000), {}),
        ("ceiling-one-ppm", observation(0, 0, 0), observation(2, 2, 1),
         {"drift_ppm": 1, "maximum_discontinuity_ms": 0}),
        ("ceiling-one-over", observation(0, 0, 0), observation(3, 3, 1),
         {"drift_ppm": 1, "maximum_discontinuity_ms": 0}),
        ("primary-regression", observation(100, 100, 0), observation(99, 99, 1), {}),
        ("reference-regression", observation(0, 0, 10), observation(1, 1, 9), {}),
        ("touching-pairs", observation(0, 1, 0), observation(1, 2, 1), {}),
        ("overlapping-pairs", observation(0, 2, 0), observation(1, 3, 1), {}),
        ("negative-raw-origin", observation(-1000, -1000, 0), observation(-1, -1, 1000), {}),
        ("checked-reference-upper", observation(0, 0, 0), observation(MAXIMUM, MAXIMUM, MAXIMUM),
         {"drift_ppm": 1000}),
    ]:
        selected = policy(**changes)
        pairs.append({"name": name, "policy": selected, "old": old, "new": new,
                      "expected": relation(old, new, selected)})
    coordinates = []
    for raw, origin in [(-1, MINIMUM), (0, MINIMUM), (MINIMUM, MINIMUM), (-1001, -1000),
                        (MAXIMUM, MAXIMUM), (MAXIMUM, MINIMUM), (-20, -1000)]:
        n = raw - origin
        outcome = "ok" if 0 <= n <= MAXIMUM else (
            "routine_clock_limit" if n > MAXIMUM or n < MINIMUM else "routine_clock_unavailable")
        coordinates.append({"raw": raw, "origin": origin, "expected": n, "outcome": outcome})
    utc_scope = {key: request[key] for key in
                 ("deployment_id", "owner_id", "authority_epoch", "store_boot_epoch")}
    utc_scope.update(clock_generation=5, runtime_digest="c" * 64)
    utc_sample = {
        "source_id": "fixture:utc", "qualification_digest": "d" * 64,
        "boot_epoch": request["store_boot_epoch"], "generation": 5,
        "sampled_monotonic_ms": 100, "utc_lower_ms": 1700000000000,
        "utc_upper_ms": 1700000000002, "maximum_age_ms": 1000,
        "drift_ppm": 1, "wall_confidence": "qualified", "monotonic_continuous": True,
    }
    utc_token_array = ["wotex-home.routine-utc-basis@1", utc_scope,
                       utc_sample["source_id"], utc_sample["qualification_digest"],
                       utc_sample["sampled_monotonic_ms"], utc_sample["utc_lower_ms"],
                       utc_sample["utc_upper_ms"], utc_sample["maximum_age_ms"],
                       utc_sample["drift_ppm"], 10, "4" * 32, 1, "-10000"]
    utc = {"scope": utc_scope, "sample": utc_sample, "started_ms": 10,
           "observation": observation(-9900, -9900, 100), "origin": -10000,
           "token": "home:utc:" + sha(canonical(utc_token_array)),
           "projections": []}
    for now in [99, 100, 101, 1099, 1100, 1101]:
        elapsed = now - utc_sample["sampled_monotonic_ms"]
        if elapsed < 0:
            expected = {"outcome": "routine_clock_unavailable"}
        elif elapsed >= utc_sample["maximum_age_ms"]:
            expected = {"outcome": "routine_clock_snapshot_stale"}
        else:
            drift = (elapsed * utc_sample["drift_ppm"] + 999999) // 1000000
            expected = {"outcome": "ok", "lower": utc_sample["utc_lower_ms"] + elapsed - drift,
                        "upper": utc_sample["utc_upper_ms"] + elapsed + drift}
        utc["projections"].append(dict(now=now, **expected))
    return {"scope": "synthetic_clock_claims_only", "policy": p, "policy_document": document,
            "policy_sha256": sha(document), "request": request,
            "request_document": canonical(request_array), "request_sha256": sha(canonical(request_array)),
            "elapsed_token": "home:elapsed:" + sha(canonical(token_array)),
            "pairs": pairs, "coordinates": coordinates, "utc": utc}


def schema():
    identifier = {"type": "string", "pattern": r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"}
    digest = {"type": "string", "pattern": "^[0-9a-f]{64}$"}
    epoch = {"type": "string", "pattern": "^[0-9a-f]{32}$"}
    signed_text = {"type": "string", "maxLength": 20, "pattern": r"^(0|-?[1-9][0-9]*)$"}

    def integer(low=0, high=MAXIMUM):
        return {"type": "integer", "minimum": low, "maximum": high}

    def closed(properties):
        return {"type": "object", "additionalProperties": False,
                "properties": properties, "required": sorted(properties)}

    policy_props = {key: digest for key in ("qualification_digest", "runtime_digest", "source_digest")}
    policy_props.update({key: identifier for key in ("source_id", "reference_id", "procedure_ref")})
    policy_props.update(approval_timeout_ms=integer(1, 60000), maximum_sample_ms=integer(1, 1000),
                        maximum_discontinuity_ms=integer(0, 1000), drift_ppm=integer(0, 1000),
                        qualified_run_ms={"const": 86400000},
                        monotonic_policy={"const": "invalidate_on_discontinuity"},
                        suspend_policy={"const": "invalidate_on_lifecycle_change"})
    binding = closed({"deployment_id": digest, "owner_id": digest, "authority_epoch": integer(1),
                      "store_boot_epoch": identifier, "elapsed_generation": integer(1),
                      "runtime_digest": digest, "monotonic_origin_ms": signed_text})
    request_props = dict(binding["properties"], policy_sha256=digest, source_digest=digest,
                         reference_epoch=epoch, reference_started_ms=signed_text,
                         lifecycle_generation=integer(1), lifecycle_started_ms=signed_text,
                         challenge_nonce={"type": "string", "pattern": "^[A-Za-z0-9_-]{43}$"})
    observation_props = {key: identifier for key in ("source_id", "reference_id")}
    observation_props.update(source_digest=digest, reference_epoch=epoch,
                             lifecycle_generation=integer(1), continuous_ms=integer())
    observation_props.update({key: integer(MINIMUM) for key in
                              ("reference_started_ms", "lifecycle_started_ms",
                               "primary_lower_ms", "primary_upper_ms")})
    def wire(format_, fields, properties):
        return {"type": "array", "additionalItems": False, "minItems": len(fields) + 1,
                "maxItems": len(fields) + 1,
                "items": [{"const": format_}] + [properties[key] for key in fields]}

    utc_scope = dict(binding["properties"])
    del utc_scope["elapsed_generation"]
    del utc_scope["monotonic_origin_ms"]
    utc_scope["clock_generation"] = integer(1)
    return {"$schema": "http://json-schema.org/draft-07/schema#",
            "title": "Pure routine clock claims; no current qualification",
            "definitions": {"policy": closed(policy_props), "request": closed(request_props),
                            "binding": binding, "observation": closed(observation_props),
                            "utc_scope": closed(utc_scope),
                            "policy_wire": wire("wotex-home.routine-elapsed-policy.v1", POLICY_FIELDS, policy_props),
                            "request_wire": wire("wotex-home.routine-elapsed-request.v1", REQUEST_FIELDS, request_props)}}


def main():
    outputs = {
        ROOT / "test/fixtures/routines/clock-bases.json": canonical(vectors()) + "\n",
        ROOT / "priv/profiles/routine-clock.schema.json": json.dumps(schema(), indent=2, sort_keys=True) + "\n",
    }
    if sys.argv[1:] == ["--write"]:
        for path, expected in outputs.items():
            path.write_text(expected)
    elif sys.argv[1:] == ["--check"]:
        if any(path.read_text() != expected for path, expected in outputs.items()):
            raise SystemExit("clock vectors/schema differ")
        print("15 independent interval cases and 7 exact-coordinate cases agree")
    else:
        raise SystemExit("usage: routine_clock_oracle.py --write|--check")


if __name__ == "__main__":
    main()
