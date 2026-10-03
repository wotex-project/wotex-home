#!/usr/bin/env python3
"""Cold one-shot desktop measurement, not a production capacity claim."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import resource
import statistics
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--runner", type=Path, default=ROOT / "_build/component-native/debug/woh-component-runner")
args = parser.parse_args()
EXE = args.runner.resolve()
wit = (ROOT / "native/components/wit/profile.wit").read_bytes()
records = {}
for name in ["reference", "rust"]:
    binary = (ROOT / f"_build/component-fixtures/{name}.wasm").read_bytes()
    body = b"\x01\x00" + hashlib.sha256(binary).digest() + hashlib.sha256(wit).digest()
    body += struct.pack(">I", len(binary)) + binary + b"\xff\xff"
    frame = struct.pack(">I", len(body)) + body
    timings = []
    for _ in range(20):
        before = time.monotonic()
        with subprocess.Popen([str(EXE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env={}) as process:
            process.stdin.write(frame)
            process.stdin.flush()
            response = process.stdout.read(7)
            status = process.wait(timeout=6)
            stderr = process.stderr.read()
            if status != 0 or response != b"\0\0\0\3\1\0\1" or stderr:
                raise SystemExit(f"unexpected benchmark outcome: {status}, {response.hex()}")
        timings.append((time.monotonic() - before) * 1000)
    records[name] = {"samples": 20, "bytes": len(binary),
                     "component_sha256": hashlib.sha256(binary).hexdigest(),
                     "median_ms": round(statistics.median(timings), 3),
                     "max_ms": round(max(timings), 3)}
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
rss_bytes = rss if platform.system() == "Darwin" else rss * 1024
report = {"host": platform.system(), "architecture": platform.machine(),
          "mode": f"{EXE.parent.name} native runner, fresh process and compilation per call",
          "runner_sha256": hashlib.sha256(EXE.read_bytes()).hexdigest(),
          "wit_sha256": hashlib.sha256(wit).hexdigest(), "calls": records,
          "maximum_child_rss_mib": round(rss_bytes / 1024**2, 2)}
(ROOT / f"_build/component-fixtures/benchmark-{EXE.parent.name}.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
