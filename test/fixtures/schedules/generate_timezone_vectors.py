"""Independent Python zoneinfo oracle over authored inert TZif fixtures.

Run from the repository root. This never reads OS timezone files or clocks.
The Fixture/* labels are test identities, not qualified IANA datasets.
"""
import datetime as dt
import hashlib
import io
import json
import struct
import os
import platform
import subprocess
import sys
from base64 import b64encode
from pathlib import Path
from zoneinfo import ZoneInfo


def tzif(footer, version=b"2", transitions=()):
    types = [(0, 0, 0), (3600, 1, 4)]
    chars = b"STD\0DST\0"
    legacy = b"TZif" + version + bytes(15) + struct.pack(">6I", 0, 0, 0, 0, 1, 4)
    legacy += struct.pack(">iBB", 0, 0, 0) + b"STD\0"
    header = b"TZif" + version + bytes(15) + struct.pack(">6I", 0, 0, 0, len(transitions), len(types), len(chars))
    block = b"".join(struct.pack(">q", time) for time, _ in transitions)
    block += bytes(index for _, index in transitions)
    block += b"".join(struct.pack(">iBB", *record) for record in types) + chars
    return legacy + header + block + b"\n" + footer.encode("ascii") + b"\n"


def valid_instants(zone, local):
    values = set()
    for fold in (0, 1):
        utc = local.replace(tzinfo=zone, fold=fold).astimezone(dt.timezone.utc)
        if utc.astimezone(zone).replace(tzinfo=None) == local:
            values.add(int(utc.timestamp()) * 1000)
    return sorted(values)


def ordinal_libc_vectors(footer, labels):
    # A separate process establishes no OS preference or clock. Candidate UTC
    # offsets are the fixture's explicit standard/daylight offsets (0 and 3600).
    script = """
import calendar,json,sys,time
time.tzset()
output=[]
for label in json.load(sys.stdin):
    local=time.strptime(label, '%Y-%m-%dT%H:%M:%S')
    nominal=calendar.timegm(local)
    values=[(nominal-offset)*1000 for offset in [0,3600]
            if time.localtime(nominal-offset)[:6] == local[:6]]
    output.append({'local':label,'utc_ms':sorted(set(values))})
print(json.dumps(output))
"""
    result = subprocess.run([sys.executable, "-c", script],
        env={**os.environ, "TZ": footer}, input=json.dumps(labels),
        text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def next_occurrence(zone, time, days, after, start, finish):
    seed = max(after + 1, start)
    date = dt.datetime.fromtimestamp(seed / 1000, dt.timezone.utc).astimezone(zone).date()
    for offset in range(32):
        current = date + dt.timedelta(days=offset)
        if current.isoweekday() not in days:
            continue
        instants = valid_instants(zone, dt.datetime.combine(current, dt.time.fromisoformat(time)))
        if instants:
            first = instants[0]
            if finish is not None and first >= finish:
                return None
            if first > after and first >= start:
                return first
    return None


zones = [
    ("Fixture/Stockholm", "CET-1CEST,M3.5.0,M10.5.0/3", b"2"),
    ("Fixture/New_York", "EST5EDT,M3.2.0,M11.1.0", b"2"),
    ("Fixture/Lord_Howe", "<+1030>-10:30<+11>-11,M10.1.0,M4.1.0", b"2"),
    ("Fixture/Dublin", "IST-1GMT0,M10.5.0,M3.5.0/1", b"2"),
    ("Fixture/UTC", "UTC0", b"2"),
    ("Fixture/Seconds", "FIX-5:30:15", b"2"),
    ("Fixture/Signed", "<-03>3<-02>,M3.5.0/-2,M10.5.0/-1", b"3"),
    ("Fixture/Julian", "STD0DST,J60/0,J300/0", b"2"),
    ("Fixture/Ordinal", "STD0DST,59/0,300/0", b"2"),
    ("Fixture/All_Year", "XXX3EDT4,0/0,J365/23", b"2"),
]
labels = [
    "2000-02-29T00:30:00", "2024-02-29T00:30:00", "2024-03-01T00:30:00",
    "2026-01-01T00:00:00", "2026-03-08T02:30:00", "2026-03-29T01:30:00",
    "2026-03-29T02:30:00", "2026-03-29T03:30:00", "2026-04-05T01:45:00",
    "2026-04-05T02:15:00", "2026-10-04T02:15:00", "2026-10-25T01:30:00",
    "2026-10-25T02:30:00", "2026-10-25T03:30:00", "2026-11-01T01:30:00",
    "2026-11-01T02:30:00", "2026-12-31T23:30:00", "2038-01-19T03:14:07",
    "2040-02-29T00:30:00", "2040-03-25T02:30:00", "2040-10-28T02:30:00",
    "2100-03-01T00:30:00", "9998-12-31T12:00:00",
]
records = []
next_cases = []
for name, footer, version in zones:
    data = tzif(footer, version)
    zone = ZoneInfo.from_file(io.BytesIO(data), key=name)
    vectors = [{"local": text, "utc_ms": valid_instants(zone, dt.datetime.fromisoformat(text))} for text in labels]
    oracle = "Python stdlib zoneinfo.from_file"
    disagreements = []
    if name == "Fixture/Ordinal":
        reference = ordinal_libc_vectors(footer, labels)
        disagreements = [{"local": py["local"], "zoneinfo_utc_ms": py["utc_ms"], "libc_utc_ms": c["utc_ms"]}
                         for py, c in zip(vectors, reference) if py != c]
        vectors = reference
        oracle = "POSIX zero-based ordinal; process-local libc localtime round-trip"
    records.append({
        "name": name, "data_base64": b64encode(data).decode("ascii"),
        "sha256": hashlib.sha256(data).hexdigest(),
        "oracle": oracle, "zoneinfo_disagreements": disagreements, "vectors": vectors,
    })
    if name in ["Fixture/Stockholm", "Fixture/New_York", "Fixture/Lord_Howe", "Fixture/UTC"]:
        for after_text in ["2026-03-28T23:00:00+00:00", "2026-03-29T00:31:00+00:00",
                           "2026-10-25T00:31:00+00:00", "2026-03-08T06:55:00+00:00",
                           "2026-11-01T05:31:00+00:00", "2026-04-04T14:46:00+00:00",
                           "2026-10-03T14:00:00+00:00"]:
            after = int(dt.datetime.fromisoformat(after_text).timestamp()) * 1000
            for time in ["01:45:00", "02:30:00"]:
                for days in [list(range(1, 8)), [1, 3, 7]]:
                    finish = after + 86_400_000 if days == [1, 3, 7] else None
                    next_cases.append({"zone": name, "time": time, "days": days,
                        "after_ms": after, "start_ms": after - 86_400_000, "end_ms": finish,
                        "next_ms": next_occurrence(zone, time, days, after, after - 86_400_000, finish)})
document = {"format": "wotex-home.synthetic-tzif-oracle.v1", "python_version": platform.python_version(), "libc_host": platform.system(), "zones": records, "next_cases": next_cases}
destination = Path("test/fixtures/schedules/timezone_vectors.json")
destination.write_text(json.dumps(document, indent=2) + "\n")
print(f"wrote {len(records)} inert zones, {len(records) * len(labels)} resolution vectors and {len(next_cases)} recurrence vectors")
