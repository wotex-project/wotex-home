# Independent durable schedule trace corpus v1

Version: 0.1.3. Fixed-UTC-interval software correspondence, 2026-10-08.
WOH.04 owns temporal admission, WOH.14 durable transitions and WOH.16 recovery.

`WotexHome.Schedules.DurableModel` is an independent reference machine. It
imports no Home planner, window, guard, writer, transport or credential code.
It predicts one active fixed-UTC-interval schedule's considered watermark,
original occurrence dispositions, causal spend, committed handoff history,
generation, suspension, author status, target grants, overrides, maintenance
and restart. Its values grant no authority and are not accepted by a Store route. The model is
not an application supervisor or timer.

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
`single_utc_interval_durable_software_correspondence`. Sixty-four traces cover
empty/duplicate/backward polling, uncertain consumption without later retry,
bounded downtime, matching-report no-send with and without control qualification,
qualification loss, held/queued/claimed expiry, untouched handed work, ACK and
synthetic report settlement, cancellation, all four suspension phases, explicit
reactivation, all four restart phases and a fresh post-restart coordinate.
Five traces inject SQL failure at occurrence, queue, claim, handoff or suspension
publication and then inspect rollback and same-owner restart.
Ten further traces remove the original author's target grant before polling,
at held, queued, claimed, handed, ACK-accepted, observed and uncertain-coordinate
states. Restoring the grant rotates the actual credential but leaves the
withdrawn generation inactive. Explicit activation excludes the old coordinate;
a later coordinate can acquire its own root. An injected failure at withdrawal
publication rolls back grant removal, request invalidation and the generation
barrier together, preserving the original activation and committed spend.
Nineteen further traces cover operator overrides and host maintenance. An
override at consumption records a terminal blocked occurrence without a root;
later advancement rejects unsent work without refunding prior spend. A refused
claim or handoff leaves its original phase intact; releasing the override may
allow that same still-eligible identity. Handed work remains distinct from
unsent work. Restart expires the old-boot override. Maintenance fences the
generation and persists across restart; ending it cannot reactivate the old
generation. Explicit later activation establishes a new considered boundary.
SQL faults at override issue and maintenance begin/end publication preserve
the previous lease/barrier, generation and request history atomically.
Six further traces revoke the original author before polling and at held,
queued, claimed, handed and ACK-accepted phases. Revocation clears that author's
override, fences the active generation and preserves original identities,
spent roots and committed handoff uncertainty. Historical grant rows do not
make a revoked author current. Activation and private original lookup reject
the revoked credential; restart cannot silently replace the author. A failure
at withdrawal publication rolls back principal revocation, pending invalidation
and the generation barrier before a same-owner restart and later successful
revocation.

The live harness calls the real Authority preparation/calculation/commit path,
bearer-free Store advancement and public Store execution/lifecycle operations.
It compares actual SQLite state after every step with the independent model.
Comparison includes actual original-author status, target grant, current
boot-scoped override, maintenance barrier, latest generation/activation,
current considered watermark, total considerations, original per-coordinate receipt disposition and
reason, causal reservation and presence of a committed handoff journal.
Whole-snapshot integrity and immutable original public receipts are checked
separately. After author revocation, the public lookup must return unauthorized.
Private read-only fixture comparisons still establish that the entire original
consideration/effect rows remain byte-for-byte unchanged. Those row comparisons
now run after every event in every trace, separately from current dispositions.
Empty polling/advancement and failed publications preserve revision.
Failed handoff publication remains unsent; only a committed handoff becomes
uncertain on restart. Old claim tokens acquire no new owner after restart.
An activation is current only when its epoch and generation equal the current
metadata; a retained pre-maintenance activation is historical. A blocked effect
without a request contributes its own retained reason rather than borrowing
the consideration's time decision. These projections are read independently
from SQLite; they do not call Home's corresponding guard helpers.

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

Seventeen pure tests separately exercise the corpus format/events and reference's
closed input bounds,
uncertain no-retry, empty/backward polling, long downtime, no-send/spend,
uncommitted versus committed handoff, suspension/reactivation, boot recovery,
grant-loss spend/uncertainty, explicit grant-restoration activation and atomic
withdrawal publication failure, override no-retry/phase conservation,
maintenance restart/reactivation, lease/barrier rollback, author revocation and
atomic authority-loss rollback.
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

The target-grant extension passed all thirty-nine live traces in 112.5 seconds
and all twenty-eight pure-reference/lifecycle tests in 14.3 seconds on
2026-10-08: sixty-seven affected tests, zero failures. The actual grant is now
part of every projected state, including rollback and restart. All twelve pure
reference tests ran. Locked formatting, warnings-as-errors compilation,
twenty-contract workspace/nineteen-contract staged metadata, thirty-three local
references and Git whitespace passed. This slice changes the independent model,
corpus and test harness; the existing production authority transitions needed
no change. It runs no physical packets, installed-host checks or socket suites.

The override/maintenance extension passed all fifty-eight live traces in
214.0 seconds and all fifty-seven pure-reference, lifecycle, override and
maintenance tests in 25.0 seconds on 2026-10-08: 115 affected tests, zero
failures. All fifteen pure-reference tests and the existing maintenance socket
case ran; no socket exclusion was used. An initial fixture macro was placed in
an unrelated generated test and failed test compilation; its placement was
corrected before this passing run. The actual override-blocked reason and
generation-scoped activation projection were extended in the read-only harness,
with no production writer change. Locked formatting, warnings-as-errors
compilation, twenty-contract workspace/nineteen-contract staged metadata,
thirty-three local references, no held Home BEAM files and Git whitespace
passed. No hardware or installed-host qualification is inferred.

The original-author extension passed all sixty-four live traces in 273.1 seconds
and all forty-eight pure-reference, lifecycle and Store tests in 30.1 seconds
on 2026-10-08: 112 affected tests, zero failures. All seventeen pure-reference
tests ran. Every trace now separately compares full immutable consideration and
effect rows after each event, while the author-loss traces require unauthorized
public lookup. The closed corpus remains bounded to sixty-four traces and
65,536 bytes (14,812 bytes retained). Locked formatting, warnings-as-errors
compilation, twenty-contract workspace/nineteen-contract staged metadata,
thirty-three local references, no held Home BEAM files and Git whitespace
passed. The existing production writer needed no change. This affected run
adds no socket, installed-host or physical qualification evidence.
