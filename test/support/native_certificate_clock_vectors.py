"""Generate synthetic public clock vectors with independent OpenSSL signatures.

Fixed disposable seeds are fixture inputs, never installed issuer custody.
Only public documents, signatures and independently calculated results persist.
"""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def canonical(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def b64(value):
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def digest(value):
    return hashlib.sha256(value).hexdigest()


def generate():
    prefix = "wotex-home.native-certificate-clock-"
    runtime = digest(canonical([prefix + "runtime.v1", "FIXTURE001", b64(b"1" * 20), b64(b"2" * 20)]))
    specifications = [
        ("ordinary", 1000, 10000, 10, 100, 5, 1792065600000, 0, [0, 1, 9999]),
        ("delayed", 1000, 10000, 10, 100, 5, 1792065600000, 37, [37, 38, 1043, 9999]),
        ("zero-error", 1, 15000, 0, 0, 0, 1792065600000, 0, [0, 1, 14999]),
        ("maximum", 60000, 600000, 1000, 1000, 1000, 1792065600000, 59999, [59999, 60000, 599999]),
        ("upper-limit", 60000, 600000, 1000, 1000, 1000, 253402300199000, 0, [0, 1, 597000, 599999]),
        ("underflow", 1000, 10000, 0, 0, 0, 0, 0, [0]),
    ]
    vectors = []
    with tempfile.TemporaryDirectory(prefix="woh-certificate-clock-vectors-") as temp:
        root = Path(temp)
        key = root / "disposable.der"
        message = root / "message"
        for index, (name, response, age, error, ppm, discontinuity, utc, received, samples) in enumerate(specifications):
            key.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + bytes([17 + index]) * 32)
            key.chmod(0o600)
            public = subprocess.check_output(["openssl", "pkey", "-inform", "DER", "-in", str(key), "-pubout", "-outform", "DER"])
            assert public[:12] == bytes.fromhex("302a300506032b6570032100") and len(public) == 44
            policy = [prefix + "policy.v1", "fixture:source", "fixture:issuer", b64(public[12:]), 1,
                      "fixture:unqualified", "a" * 64, runtime, response, age, error, ppm, discontinuity]
            request = [prefix + "request.v1", "org.wotex.home", runtime, b64(bytes([33 + index]) * 32), digest(canonical(policy))]
            record = [prefix + "record.v1", *request[1:], utc]
            message.write_bytes((prefix + "record.v1").encode("ascii") + b"\0" + canonical(record))
            signature = subprocess.check_output(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(key), "-keyform", "DER", "-in", str(message)])
            assert len(signature) == 64
            package = [prefix + "package.v1", record, b64(signature)]
            lookups = []
            for elapsed in samples:
                drift = (elapsed * ppm + 999999) // 1000000
                allowance = error + discontinuity + 2
                first, last = utc + elapsed - received - allowance - drift, utc + elapsed + allowance + drift
                expected = [first, last] if 0 <= first <= last <= 253402300799000 else "clock_unavailable"
                lookups.append({"elapsed": elapsed, "expected": expected})
            continuity = []
            for continuous, wall in [(0, 0), (1, 1), (1000, 1002), (1000, 1008), (1000, 1009),
                                     (5000, 5002), (5000, 5010), (9999, 9990), (age, age), (0, -1), (0, 9223372036854775807)]:
                tolerance = discontinuity + (continuous * ppm + 999999) // 1000000 + 2
                continuity.append({"continuous": continuous, "wall": wall,
                                   "expected": 0 <= continuous < age and wall >= 0 and abs(wall - continuous) <= tolerance})
            vectors.append({"name": name, "policy": canonical(policy).decode(), "request": canonical(request).decode(),
                            "package": canonical(package).decode(), "response_elapsed": received,
                            "accepted": isinstance(lookups[0]["expected"], list), "lookups": lookups, "continuity": continuity})
    return {"evidence": "Synthetic public fixtures; no source or host accuracy qualified", "runtime": runtime, "vectors": vectors}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(generate(), indent=2) + "\n")
