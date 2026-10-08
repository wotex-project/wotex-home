"""Frozen calendar inputs for an independent durable reference machine.

Run from the repository root. Only the authored TZif bytes in timezone_vectors
are read. Python zoneinfo enumerates the complete, source-bounded UTC timeline;
no Home code, OS timezone dataset, live clock or hardware is used.
"""
import base64
import datetime as dt
import hashlib
import io
import json
import sys
from pathlib import Path
from zoneinfo import ZoneInfo


corpus = json.loads(Path("test/fixtures/schedules/timezone_vectors.json").read_text())
zones = {record["name"]: record for record in corpus["zones"]}
vectors = []


def utc(label):
    return int(dt.datetime.fromisoformat(label).replace(tzinfo=dt.timezone.utc).timestamp()) * 1000


def instants(zone, label):
    local = dt.datetime.fromisoformat(label)
    result = set()
    for fold in (0, 1):
        candidate = local.replace(tzinfo=zone, fold=fold).astimezone(dt.timezone.utc)
        if candidate.astimezone(zone).replace(tzinfo=None) == local:
            result.add(int(candidate.timestamp()) * 1000)
    return sorted(result)


# The SQLite harness binds its source to the actual installed bytes. Verify
# that complete bounded timeline independently before using a frozen trace.
# This reads only the explicit private fixture input, never an OS clock/zone.
if len(sys.argv) == 3 and sys.argv[1] == "--verify-installed-input":
    supplied = json.loads(Path(sys.argv[2]).read_text())
    assert set(supplied) == {"data_base64", "trigger"}
    trigger = supplied["trigger"]
    data = base64.b64decode(supplied["data_base64"], validate=True)
    assert 0 < len(data) <= 65536
    assert hashlib.sha256(data).hexdigest() == trigger[2]
    zone = ZoneInfo.from_file(io.BytesIO(data), key=trigger[1])
    if trigger[0] == "once":
        assert trigger[5] in instants(zone, trigger[3] + "T" + trigger[4])
        result = [trigger[5]]
    else:
        assert trigger[0] in {"daily", "weekdays"}
        time_label = trigger[3]
        days = list(range(1, 8)) if trigger[0] == "daily" else trigger[4]
        start, finish = trigger[-2:]
        date = dt.datetime.fromtimestamp(start / 1000, dt.timezone.utc).astimezone(zone).date()
        end_date = dt.datetime.fromtimestamp(finish / 1000, dt.timezone.utc).astimezone(zone).date()
        assert 0 <= (end_date - date).days <= 34
        result = []
        for offset in range((end_date - date).days + 1):
            current = date + dt.timedelta(days=offset)
            choices = instants(zone, current.isoformat() + "T" + time_label)
            if current.isoweekday() in days and choices and start <= choices[0] < finish:
                result.append(choices[0])
    print(json.dumps(result))
    sys.exit(0)
assert len(sys.argv) == 1


def source(name, first_date, days_count=8, days=None, once=None, start=None):
    record = zones[name]
    data = base64.b64decode(record["data_base64"], validate=True)
    assert hashlib.sha256(data).hexdigest() == record["sha256"]
    zone = ZoneInfo.from_file(io.BytesIO(data), key=name)
    date = dt.date.fromisoformat(first_date)
    local_time = "01:30:00" if "New_York" in name else "02:30:00"
    lower = utc(first_date + "T00:00:00") - 43_200_000 if start is None else start
    finish = utc((date + dt.timedelta(days=days_count)).isoformat() + "T00:00:00")
    timeline = []
    for offset in range(-1, days_count + 1):
        current = date + dt.timedelta(days=offset)
        choices = instants(zone, current.isoformat() + "T" + local_time)
        if choices and (days is None or current.isoweekday() in days):
            due = choices[0]
            if lower <= due < finish:
                timeline.append(due)
    kind = "daily" if days is None else "weekdays"
    trigger = [kind, name, record["sha256"], local_time]
    if days is not None:
        trigger.append(days)
    trigger += [lower, finish]
    if once is not None:
        chosen = instants(zone, first_date + "T" + local_time)[once]
        timeline = [chosen]
        trigger = ["once", name, record["sha256"], first_date, local_time, chosen]
        finish = chosen + 10_000
    return zone, {"zone": name, "trigger": trigger, "instants": timeline,
                  "finish": finish, "watermark": timeline[0] - 1000}


def add(identifier, source_record, steps):
    vectors.append({"id": identifier, **source_record, "steps": steps})


def time(value, width=0):
    return ["time", value, value + width]


for name, date, label in [("Fixture/Stockholm", "2026-10-25", "stockholm"),
                          ("Fixture/New_York", "2026-11-01", "new_york")]:
    zone, record = source(name, date)
    first, second = instants(zone, date + "T" + record["trigger"][3])
    following = record["instants"][1]
    add(label + "_daily_fold", record,
        [time(first + 1), "poll", "poll", time(second + 1), "poll",
         time(first + 1), "poll", time(following + 1), "poll"])
    add(label + "_uncertain_no_retry", record,
        [time(first, 2001), "poll", time(first + 1), "poll",
         time(following + 1), "poll"])
    add(label + "_restart_consumed_fold", record,
        [time(first + 1), "poll", "restart", time(first + 1), "poll",
         time(second + 1), "poll", time(following + 1), "poll"])
    _, weekly = source(name, date, 15, [7])
    add(label + "_weekly_fold", weekly,
        [time(first + 1), "poll", time(second + 1), "poll",
         time(weekly["instants"][1] + 1), "poll"])

for choice in (0, 1):
    zone, record = source("Fixture/Stockholm", "2026-10-25", once=choice)
    first, second = instants(zone, "2026-10-25T02:30:00")
    record["watermark"] = first - 1000
    add("once_fold_" + ("first" if choice == 0 else "second"), record,
        [time(first + 1), "poll", time(second + 1), "poll", "poll"])

for name, first_date, gap_date, label, local_time in [
    ("Fixture/Stockholm", "2026-03-28", "2026-03-29", "stockholm", "02:30:00"),
    ("Fixture/New_York", "2026-03-07", "2026-03-08", "new_york", "02:30:00")]:
    zone, record = source(name, first_date)
    if name == "Fixture/New_York":
        record["trigger"][3] = local_time
        record["instants"] = []
        for offset in range(-1, 9):
            date = dt.date.fromisoformat(first_date) + dt.timedelta(days=offset)
            choices = instants(zone, date.isoformat() + "T" + local_time)
            if choices and record["trigger"][-2] <= choices[0] < record["finish"]:
                record["instants"].append(choices[0])
        record["watermark"] = record["instants"][0] - 1000
    assert instants(zone, gap_date + "T" + local_time) == []
    previous = max(due for due in record["instants"] if due < utc(gap_date + "T00:00:00"))
    following = min(due for due in record["instants"] if due > utc(gap_date + "T23:59:59"))
    add(label + "_daily_gap", record,
        [time(previous + 1), "poll", time(utc(gap_date + "T12:00:00")), "poll",
         time(following + 1), "poll"])

zone, record = source("Fixture/Stockholm", "2026-03-28", 32)
add("bounded_month_downtime", record,
    [time(record["instants"][-1] + 1), "poll", "poll",
     time(record["finish"] + 1000), "poll"])

zone, record = source("Fixture/Stockholm", "2026-10-25", start=utc("2026-10-25T00:30:00") + 1)
second = instants(zone, "2026-10-25T02:30:00")[1]
record["watermark"] = record["trigger"][-2]
add("start_between_fold_instants", record,
    [time(second + 1), "poll", time(record["instants"][0] + 1), "poll"])

document = {"format": "wotex-home.calendar-durable-traces.v1",
            "scope": "bounded_calendar_consumption_software_correspondence",
            "oracle": "Python stdlib zoneinfo.from_file over frozen authored TZif",
            "vectors": vectors}
destination = Path("test/fixtures/schedules/calendar_durable_trace_vectors.json")
destination.write_text(json.dumps(document, indent=2) + "\n")
print(f"wrote {len(vectors)} bounded inert calendar traces")
