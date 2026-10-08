"""Independent bounded boot-local countdown execution event corpus.

Run from the repository root. Monotonic offsets are relative to the original
source due coordinate, never a Home planner result. This imports no Home code,
live clock, credentials, transport or device. The harness binds the parametric
start to the actual Store-owned source input before admission.
"""
import json
from pathlib import Path


def monotonic(offset=1):
    return ["monotonic", offset]


# A held intent has not sealed an observation revision. Accept the new report
# immediately before queue admission; never replace it after queueing.
initial = [monotonic(), "poll", "refresh_report"]
queued = initial + ["advance"]
claimed = queued + ["claim"]
handed = claimed + ["handoff"]
cases = {
    "ack_and_observed": handed + ["ack", "observed", "poll", "advance"],
    "caller_exit_after_commit": [monotonic(), "poll_lost_reply", "poll", "refresh_report", "advance", "restart"],
    "matching_no_send": [monotonic(), "poll", "report_matches", "advance", "advance"],
    "queued_cancel_spend": queued + ["cancel", "poll", "restart"],
    "late_consumed_no_retry": [monotonic(10000), "refresh_report", "poll", "poll", "advance"],
    "early_then_due": [monotonic(-10000), "poll"] + initial + ["advance", "claim", "handoff"],
    "held_expiry": initial + [monotonic(10000), "advance", "poll"],
    "queued_expiry": queued + [monotonic(10000), "advance", "poll"],
    "claimed_expiry": claimed + [monotonic(10000), "advance", "poll"],
    "handed_expiry_restart": handed + [monotonic(10000), "advance", "restart"],
    "held_restart": initial + ["restart", "clock_restored", "activate", "advance", "poll"],
    "queued_restart": queued + ["restart", "clock_restored", "activate", "advance", "poll"],
    "claimed_restart": claimed + ["restart", "clock_restored", "activate", "handoff", "advance", "poll"],
    "handed_restart_no_repeat": handed + ["restart", "clock_restored", "poll", "advance"],
    "ack_restart": handed + ["ack", "restart", "clock_restored", "activate", "poll"],
    "observed_restart": handed + ["ack", "observed", "restart", "clock_restored", "poll"],
    "clock_loss_held": initial + ["clock_lost", "advance", "clock_restored", "activate", "poll"],
    "clock_loss_queued": queued + ["clock_lost", "claim", "clock_restored", "activate", "poll"],
    "clock_loss_claimed": claimed + ["clock_lost", "handoff", "clock_restored", "activate", "poll"],
    "clock_loss_handed": handed + ["clock_lost", "advance", "clock_restored", "poll", "restart"],
    "clock_withdrawn_claimed": claimed + ["clock_withdrawn", "clock_restored", "activate", "poll"],
    "clock_loss_before_due": ["clock_lost", "poll", "clock_restored", "activate", "poll", "restart"],
    "suspend_resume_before_due": ["suspend", "activate"] + initial + ["advance", "claim", "handoff"],
    "suspend_due_refuses": ["suspend", monotonic(), "activate", "poll"],
    "grant_loss_claimed": claimed + ["grant_lost", "grant_restored", "activate", "poll"],
    "author_loss_ack": handed + ["ack", "author_lost", "restart"],
    "override_consumed": [monotonic(), "refresh_report", "override_on", "poll", "override_off", "advance", "poll"],
    "maintenance_claimed": claimed + ["maintenance_begin", "maintenance_end", "activate", "poll"],
    "fault_poll_restart": [monotonic(), "refresh_report", ["fault", "poll"], "restart", "clock_restored", "poll"],
    "fault_queue_restart": initial + [["fault", "advance"], "restart", "clock_restored", "advance", "poll"],
    "fault_claim_restart": queued + [["fault", "claim"], "restart", "clock_restored", "advance", "poll"],
    "fault_handoff_restart": claimed + [["fault", "handoff"], "restart", "clock_restored", "advance", "poll"],
    "fault_clock_withdrawal": claimed + [["fault", "clock_withdrawn"], "restart", "clock_restored", "activate", "poll"],
}

vectors = []
for wall in ["qualified", "unqualified"]:
    for name, steps in cases.items():
        vectors.append({"id": wall + "_" + name, "wall": wall,
                        "duration": 60000, "steps": steps})
    vectors.append({"id": wall + "_maximum_duration", "wall": wall,
                    "duration": 86400000, "steps": handed + ["ack", "observed", "restart"]})

assert len(vectors) == 68
assert all(len(vector["steps"]) <= 32 for vector in vectors)
document = {"format": "wotex-home.countdown-execution-traces.v1",
            "scope": "single_countdown_execution_durable_software_correspondence",
            "vectors": vectors}
destination = Path("test/fixtures/schedules/countdown_execution_trace_vectors.json")
destination.write_text(json.dumps(document, indent=2) + "\n")
assert destination.stat().st_size <= 65536
print(f"wrote {len(vectors)} bounded countdown execution traces")
