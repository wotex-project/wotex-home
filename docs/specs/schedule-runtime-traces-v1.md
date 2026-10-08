# Independent durable schedule trace corpus v1

Version: 0.1.0. Fixed-UTC-interval software correspondence, 2026-10-08.
WOH.04 owns temporal admission, WOH.14 durable transitions and WOH.16 recovery.

`WotexHome.Schedules.DurableModel` is an independent reference machine. It
imports no Home planner, window, guard, writer, transport or credential code.
It predicts one active fixed-UTC-interval schedule's considered watermark,
original occurrence dispositions, causal spend, committed handoff history,
generation, suspension and restart. Its values grant no authority and are not
accepted by a Store route. The model is not an application supervisor or timer.

The reference constructor has five exact integer attributes: UTC anchor,
period, late window, uncertainty tolerance and initial watermark. Bounds match
the closed interval source domain. The symbolic boot counter and supplied
qualified-clock interval are reference inputs, not a qualified clock source.
Initial watermark comes from independent integer reconstruction of the original
activation clock input. At consideration and reactivation, the harness reads
only clock inputs from the retained wire record and independently calculates
elapsed time and integer drift. It does not read that record's predicted
watermark to compute its expected result.

The closed executable corpus is
[`durable_trace_vectors.json`](../../test/fixtures/schedules/durable_trace_vectors.json).
Its format is `wotex-home.schedule-durable-traces.v1` and scope is
`single_utc_interval_durable_software_correspondence`. Twenty-nine traces cover
empty/duplicate/backward polling, uncertain consumption without later retry,
bounded downtime, matching-report no-send with and without control qualification,
qualification loss, held/queued/claimed expiry, untouched handed work, ACK and
synthetic report settlement, cancellation, all four suspension phases, explicit
reactivation, all four restart phases and a fresh post-restart coordinate.
Five traces inject SQL failure at occurrence, queue, claim, handoff or suspension
publication and then inspect rollback and same-owner restart.

The live harness calls the real Authority preparation/calculation/commit path,
bearer-free Store advancement and public Store execution/lifecycle operations.
It compares actual SQLite state after every step with the independent model.
Comparison includes the latest generation/activation, current considered
watermark, total considerations, original per-coordinate receipt disposition and
reason, causal reservation and presence of a committed handoff journal.
Whole-snapshot integrity and immutable original public receipts are checked
separately. Empty polling/advancement and failed publications preserve revision.
Failed handoff publication remains unsent; only a committed handoff becomes
uncertain on restart. Old claim tokens acquire no new owner after restart.

The comparison distinguishes retained range rows from actual missed instants.
A nonempty retained time range can contain zero recurrence instants, including
a gap between two on-time interval candidates. The reference counts missed
instants by cumulative interval ordinals; the live projection independently
uses the first included grid point and range length. Long downtime retains one
bounded range/candidate rather than enumerating or creating a catch-up burst.

The software peer is private to the synchronous fixture and owns no Store,
database, bearer or transport. It supplies source samples through the Store's
existing clock context, including the current boot/generation after simulated
reattachment. Original request scope remains immutable. The fixture assumes
that reader's qualified input contract; it does not qualify a source, installed
clock, sleep discontinuity or host. Device reports and qualification signatures
are synthetic. ACK and reported settlement establish software dispositions,
not a device packet or physical observation. Dispatch stays disabled.

Nine pure tests separately exercise the corpus format/events and reference's
closed input bounds,
uncertain no-retry, empty/backward polling, long downtime, no-send/spend,
uncommitted versus committed handoff, suspension/reactivation and boot recovery.
The real SQLite corpus supplies additional durable software evidence. It does
not widen the existing [temporal basis](schedule-admission-v1.md), whose scope
remains calculation and guard correspondence. A complete source-bound runtime
admission argument, calendar/countdown coverage, races, cursor compaction and
host qualification remain necessary before autonomous delivery. No schema,
archive shape, permission, dispatch switch or public API changes in this slice.

On 2026-10-08 the locked five-suite affected run passed 215 tests with zero
failures in 555.4 seconds, including all twenty-nine live traces, temporal
admission content, lifecycle and occurrence/restart suites. After adding the
corpus-format case and UTC upper-bound vectors, all nine pure reference tests
passed in 0.05 seconds. The first live harness run incorrectly expected a raw
document in the public original receipt; that was corrected to a private
read-only fixture query. Subsequent comparison distinguished empty retained
range geometry from actual missed instants. No production writer was changed
to satisfy either harness correction. Host qualification and autonomous
admission remain unclaimed.

The locked formatter, warnings-as-errors compiler, twenty-contract workspace
catalogue check, local document references and Git whitespace check also passed.
