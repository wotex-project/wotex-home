# Independent bounded calendar execution traces v1

Version: 0.1.0. Software correspondence, 2026-10-08. WOH.04 owns temporal
admission, WOH.14 owns durable execution and WOH.16 owns recovery. This extends
calendar execution evidence without changing a writer, schema, public route,
temporal admission scope or physical dispatch.

The closed
[sixty-eight-trace corpus](../../test/fixtures/schedules/calendar_execution_trace_vectors.json)
uses coordinates from the existing independent
[finite calendar timelines](calendar-durable-traces-v1.md). Its
[Python generator](../../test/fixtures/schedules/generate_calendar_execution_vectors.py)
imports no Home code, clock or device. Twenty-two event sequences each cover a
Stockholm daily fold, New York selected-weekday fold and an explicitly reviewed
second one-shot fold instant. Two further sequences execute the first valid
instant after a Stockholm or New York local-time gap. Each trace binds one
known source and coordinate and at most thirty-two closed events. The complete
corpus remains bounded to 65,536 bytes.

The shared
[installed-input fixture](../../test/support/calendar_trace_inputs.exs)
selects actual read-only installed IANA bytes. Before admission, a separate
Python process independently enumerates the entire finite timeline from those
bytes and the exact trigger and compares it with the frozen expected timeline.
Absent or changed bytes fail this check; authored `Fixture/*` zones acquire no
installed authority. The calendar consumption and execution suites share this
input check, not Home planner results.

The live SQLite harness uses actual Authority preparation/calculation/commit,
bearer-free Store advancement and public Store claim, final handoff,
acknowledgement and reported settlement. Its reference is the independently
closed finite-calendar mode of `Schedules.DurableModel`. After every event, a
read-only SQLite projection checks original author/grant, generation,
activation, considered watermark, current phase, root spend, committed handoff
and immutable consideration/effect history.
Missed counts enumerate only the independently obtained calendar instants in
retained ranges. Full snapshot integrity and private original lookup are
checked separately.

Sequences include ACK followed by synthetic reported settlement, matching-report
no-send, queued cancellation, held/queued/claimed expiry at the exclusive late
boundary, unchanged handed work, backward clock refusal followed by the same
original handoff, uncertainty consumption without later retry and restart in
each held, queued, claimed and handed phase. Target-grant loss at claim and
original-author revocation after ACK preserve original identities, committed
spend and handed uncertainty. Restored grants require explicit activation.
Override consumption is terminal and unspent. Maintenance fences the original
generation; ending maintenance does not revive it. SQL failures at occurrence,
queue, claim and handoff publication roll back tentative work before an actual
same-owner Store restart.

Three sequences deliberately discard a completed poll result: a monitored
in-process Authority caller commits one held occurrence and exits normally
without delivering its receipt. The parent observes actual caller exit and
independently reads the published identity and clock input. A fresh public
Authority poll creates no second request; advancement and restart conserve the
original. This checks internal caller-result loss after commit, not loss over a
public socket route. No database handle, credential or transport is given to
that caller.

Clock ownership and LIFX qualification inputs are synthetic private software
fixtures. ACK and reported settlement are retained software dispositions, not
physical packets or observations. Restart is actual Store restart, not target
power loss. Physical dispatch remains disabled. The existing interval corpus
also runs after the common harness extraction, retaining its own fixed-grid
missed-count projection.

A complete source-bound autonomous runtime admission argument, countdown
lifecycle, composed active sets, cursor compaction and installed clock/sleep
qualification remain separate obligations. These bounded single-source traces
do not establish them or enable timers, services, credentials or hardware I/O.

On 2026-10-08, the complete tagged calendar matrix passed all sixty-eight cases
in 311.6 seconds, with 200 unrelated module cases excluded by the tag filter.
All thirty-five pure-reference and calendar-consumption cases passed in 35.3
seconds. Six focused caller-exit/handoff-fault cases also passed in 36.4 seconds.
The preceding combined 132-case calendar/interval run passed all sixty-four
interval regressions but had one calendar claim-phase mismatch. Its exact
targeted rerun passed, followed by the clean complete calendar run above.
Claim-refusal diagnostics and failure-safe read-only connection cleanup were
added to the harness; no production guard or writer was changed. The sixty-eight
vectors regenerate byte-for-byte as 28,381 bytes. These tag-selected checks are
not a full application suite or installed-host qualification.
