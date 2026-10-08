"""Independent calendar execution event corpus over frozen bounded timelines.

Run from the repository root. All coordinates come from the separate Python
calendar oracle. This calls no Home code, live clock, transport or device.
"""
import json
from pathlib import Path

corpus = json.loads(Path("test/fixtures/schedules/calendar_durable_trace_vectors.json").read_text())
sources = {vector["id"]: vector for vector in corpus["vectors"]}
vectors = []


def time(due, delta=1, width=0):
    return ["time", due + delta, due + delta + width]


for source_id in ["stockholm_daily_fold", "new_york_weekly_fold", "once_fold_second"]:
    source = sources[source_id]
    due = source["instants"][0]
    initial = [time(due), "poll"]
    queued = initial + ["advance"]
    claimed = queued + ["claim"]
    handed = claimed + ["handoff"]
    cases = {
        "ack_and_observed": handed + ["ack", "observed", "poll", "advance"],
        "caller_exit_after_commit": [time(due), "poll_lost_reply", "poll", "advance", "restart"],
        "matching_no_send": ["report_matches"] + initial + ["advance", "advance"],
        "queued_cancel_spend": queued + ["cancel", "poll", "restart"],
        "held_expiry": initial + [time(due, 10000), "advance", "poll"],
        "queued_expiry": queued + [time(due, 10000), "advance", "poll"],
        "claimed_expiry": claimed + [time(due, 10000), "advance", "poll"],
        "handed_expiry_restart": handed + [time(due, 10000), "advance", "restart"],
        "backward_then_original_handoff": queued + [time(due, -1000), "claim", time(due), "claim", "handoff"],
        "uncertain_consumed_no_retry": [time(due, 0, 2001), "poll", time(due), "poll", "advance"],
        "held_restart": initial + ["restart", time(due), "advance", "poll"],
        "queued_restart": queued + ["restart", time(due), "advance", "poll"],
        "claimed_restart": claimed + ["restart", time(due), "handoff", "advance", "poll"],
        "handed_restart_no_repeat": handed + ["restart", time(due), "poll", "advance"],
        "grant_loss_claimed": claimed + ["grant_lost", "grant_restored", "activate", "poll"],
        "author_loss_ack": handed + ["ack", "author_lost", "restart"],
        "override_consumed": ["override_on"] + initial + ["override_off", "advance", "poll"],
        "maintenance_claimed": claimed + ["maintenance_begin", "maintenance_end", "activate", "poll"],
        "fault_poll_restart": [time(due), ["fault", "poll"], "restart", time(due), "poll"],
        "fault_queue_restart": initial + [["fault", "advance"], "restart", time(due), "advance", "poll"],
        "fault_claim_restart": queued + [["fault", "claim"], "restart", time(due), "advance", "poll"],
        "fault_handoff_restart": claimed + [["fault", "handoff"], "restart", time(due), "advance", "poll"],
    }
    for name, steps in cases.items():
        vectors.append({"id": source_id + "_" + name, "source": source_id,
                        "coordinate": due, "steps": steps})

for source_id in ["stockholm_daily_gap", "new_york_daily_gap"]:
    source = sources[source_id]
    # Select the first valid instant after the nonexistent local date.
    due = source["instants"][1]
    vectors.append({"id": source_id + "_after_gap_handoff", "source": source_id,
                    "coordinate": due,
                    "steps": [time(due), "poll", "advance", "claim", "handoff", "ack", "restart"]})

assert len(vectors) == 68
document = {"format": "wotex-home.calendar-execution-traces.v1",
            "scope": "single_calendar_execution_durable_software_correspondence", "vectors": vectors}
destination = Path("test/fixtures/schedules/calendar_execution_trace_vectors.json")
destination.write_text(json.dumps(document, indent=2) + "\n")
assert destination.stat().st_size <= 65536
print(f"wrote {len(vectors)} bounded calendar execution traces")
