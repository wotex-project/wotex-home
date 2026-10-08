# Final power admission, claim and handoff commit guards v1

Version: 0.1.5. Implemented schema-27 enclosing Store guards, 2026-10-08.
WOH.14 owns durable execution and WOH.16 retained history and recovery.

The single Store repeats the current power execution basis after the writer's
queue, no-send, claim or handoff publication, sticky schedule withdrawal and
complete authority history validation. Only a successful final repeat can
return a claimed token
or a committed `dispatching` receipt. The existing power executor sends only
after that receipt. A refusal produces no packet, protocol acknowledgement or
physical outcome. Physical dispatch remains disabled by default.

Queue and no-send commit contexts are derived from the writer's actual receipt
inside the same transaction. The context pins that exact receipt and, for
no-send closure, the sealed request row, reported baseline and unchanged causal
root. No caller supplies these commitments; they belong only to that call and
cannot be reused after a lost reply or restart.
Public admission reauthenticates the original credential at the final guard;
trusted scheduled advancement derives the original author without a bearer.
[Original explicit advancement](explicit-power-advance-v1.md) checks a retained
explicit root and repeats that origin and its current author at the same final
queue/no-send boundary. Credential withdrawal cannot be bypassed.

No-send closure repeats the existing current principal/target/policy/profile,
fresh matching report and idle effect-domain checks, plus applicable rule and
temporal guards. It retains its existing ability to close an already reported
value without control qualification. It creates no execution row, handoff,
packet or new causal spend. Manual and legacy closure retains its existing
adapter clock semantics; temporal closure uses the exact Store-stamped report.

For queued, claimed and handed work, the final repeat validates the exact
principal/epoch/operation receipt,
execution state, token, claim boot, sealed mutation and original admission
basis. Maintenance, current original-principal permissions and target grants,
declaration/resource/profile/qualification, current reported baseline,
invariant, override, rule generation, causal provenance and attempt limits
remain mandatory. Scheduled work additionally repeats its original activation,
current author and artifact, Store-owned qualified clock scope, installed
timezone and whole half-open due/late window. Its exact reported baseline uses
Store-stamped receipt freshness and is checked after the last clock read.
Manual and legacy requests retain their existing adapter clock semantics.

The final attempt-history read excludes only this transaction's own tentative
handoff identity, including principal, authority epoch and operation ID. It
does not charge the same tentative attempt twice. Every other committed
handoff still counts, including different principals or epochs with the same
operation ID, old-boot history and uncertain outcomes. Existing spacing, rate,
cold-start and damaged-history refusals remain effective.

A savepoint begins before tentative power admission, claim or handoff. A policy
refusal restores the original held, queued or claimed phase, discarding its
tentative reservation, closure, token,
handoff marker, attempt timestamp and journals. The Store then observes current
sticky schedule withdrawal again against that original durable phase and
validates history before committing the typed refusal. This allows a necessary
generation barrier to survive without treating a never-committed handoff as a
possible physical effect. Refused claims return no token; invalidated claims
lose their in-memory owner monitor. Failure of SQL or historical integrity rolls
back the entire transaction and retains the existing fail-closed Store behavior.

Before restoration, Store captures any actually published withdrawal from
validated lifecycle history. This transient, borrowed-call receipt binds the
original activation and the observed withdrawal; no route accepts caller-made
loss or receipt values. After restoration, an already retained exact withdrawal
needs no new event. Otherwise the exact original activation, authority epoch and
generation must still match. Store republishes the detected reason against the
restored durable phase and recalculates its affected/unknown counts. Returning
runtime custody during this same call cannot erase a detected loss or resume
its generation. The old tentative barrier's counts, revision, operation identity
and possible handoff are not copied into the rebuilt history. A mismatched
successor activation or damaged history fails closed.

The same restoration and withdrawal runs when a power writer refuses current
authority before publishing a positive transition. Only the closed current-basis
denial set permits this path; SQL failures and damaged history remain rollback
errors. Missing runtime or profile custody can therefore suspend the original
activation even on an early refusal. Restoring the bytes after the call does
not reactivate the old generation. Failure while publishing this early barrier
rolls back every change and disables the writer.

Initial held-power admission and power/colour no-send inspection classify only
a closed semantic denial set as policy. Missing, stale and wrong-boot reports,
unqualified control, an effect still required and unavailable coherent colour
planning leave the writer usable. Decoded enrollment/value/history damage and
SQL failures remain raw rollback errors. Initial authentication and no-send's
outer guards use the same distinction. The enclosing Store disables writes,
keeps typed corruption results and normalizes raw SQL errors to
`store_unavailable` rather than returning database error strings as policy.
An inspection failure creates no tentative closure, reservation, execution,
attempt or handoff. Repairing the fixture data does not reenable a stopped
writer; a fresh startup must validate the complete history. Read-only advisory
inspection is a separate route and this change supplies no new control authority.

[Scheduled advancement](schedule-advance-v1.md) repeats the ordinary guards for
retained queued/claimed work even in a pass that would otherwise change nothing.
Its final enclosing guard checks actual bounded queue/no-send and retained
unsent receipts. On a final policy refusal it restores the whole tentative batch,
observes current sticky withdrawal and terminalizes the failed unsent identity.
It then returns actual current receipts, including any other work restored to
its original phase, and recalculates whether unprocessed pending work remains.
The failed coordinate cannot reopen. Prior spend stays consumed; failed new
queue publication leaves its root unspent. A failure in final terminalization
rolls back the complete batch and leaves the Store fail closed.

An already committed queue reservation stays spent. No original receipt,
consideration, causal identity, watermark or committed attempt is rewritten.
Previously durable handoffs retain their uncertainty and restart behavior;
this savepoint never makes handed work unsent or refunds a root. No schema,
archive shape, public route, timer, admission profile or temporal proof scope
changes. Autonomous polling and composed runtime proof remain separate work.

Lifecycle history also checks the exact distinct invalidation reasons for
unsent rejection and handed uncertainty when rebuilding affected/unknown
counts. It accepts the actual committed after-handoff journal rather than
mistaking that suffix for damage, and refuses a handed event with an unsent
reason. This preserves the existing distinction without changing row shapes.

Software cases use actual public Store queue, no-send, claim/handoff and trusted
advancement operations and SQLite history. A private clock fixture changes only
at the enclosing guard to check
early, expired and uncertain windows, lost clock trust and Store report-age
expiry. Missing actual synthetic qualification custody is checked after
publication. Separate synchronous cases temporarily remove one already-loaded
Home artifact after writer publication and restore it before later calls;
withdrawal commits without tentative handoff history, and an injected immutable
withdrawal-publication failure rolls back all changes. Original provenance,
causal spend, Store health and snapshot integrity are checked. The real power
executor is connected to these Store operations with an observable transport
fixture and sends no packet after final refusal. Independent attempt histories
check exact exclusion, other-principal/epoch identities, remaining rate limits,
old-boot and corrupt history. Actual suspension and restart retain an already
committed handoff; damage to its distinct reason fails lifecycle validation.
These cases do not qualify installed storage,
clock custody, a physical device or target-storage power loss.

Further cases remove runtime custody before the actual initial queue, no-send,
claim or handoff call. Each checks durable suspension after exact restoration,
no tentative handoff/no-send journal, unchanged original provenance and conserved
spend; injected withdrawal failure rolls back all rows. Bounded advancement
cases check policy loss on retained queued/claimed work and final batch rollback
with a second occurrence's discarded tentative closure. Returned receipts match
the actual restored phases. Qualification-free matching-report closure remains
covered through admission, explicit no-send settlement and advancement.

Twelve additional public-operation cases return actual runtime bytes during
the first withdrawal publication, before the enclosing guard and savepoint
restoration. A private SQLite update observer owns no Store or database; a
bounded fixture-only SQL delay makes that race observable. Queue, no-send,
their two advancement paths, claim and handoff retain exactly one rebuilt
withdrawal with the original unsent phase's counts and conserved spend.
Separate faults abort only the rebuilt publication, rolling back the entire
transaction and disabling the writer. Returning custody never creates a token,
committed handoff, new attempt or physical confidence.
An actual lifecycle case also keeps an already retained withdrawal unchanged,
then rejects its reuse after a newly admitted successor activation. The
successor's generation and revision remain intact.

Before detected-withdrawal retention, the locked full Mix suite passed 1218
tests with zero failures
in 715.7 seconds; four opt-in component cases were skipped. Real socket and
foreground-host cases ran. The earlier full run found two fixture baselines
that expired during setup before the intended fault. The fixture now accepts
its fresh report after admission/activation setup and before queue sealing;
production's five-second freshness bound is unchanged. All 28 targeted final
claim/handoff, admission-withdrawal and initial-refusal cases then passed in
84.8 seconds before the successful full rerun. Warnings-as-errors compilation,
formatting, all 20 workspace and 19 staged contract metadata checks, changed-document
references and Git whitespace validation passed.
The existing support-file load-filter warning remains unrelated to this change.

On 2026-10-08, detected-withdrawal retention passed all twelve focused public
race/fault cases in 33.5 seconds and the separate retained/successor lifecycle
case in 2.0 seconds. The locked full Mix suite then passed 1269 tests with zero
failures in 759.0 seconds; four opt-in component cases were skipped. Real socket
and foreground-host cases ran. The initial regression failed before the fix:
restored bytes caused the original barrier to disappear and the replay-only
publication fault was never reached. This establishes software rollback and
same-call custody behavior, not installed-host or physical qualification.
Formatting, warnings-as-errors compilation, all twenty workspace and nineteen
staged contract metadata checks, thirty-two changed-document local references
and Git whitespace checks passed. No temporarily held runtime bytes remained.

The initial-inspection regressions first failed all six public power cases:
damaged declaration/value rows left the writer enabled and missing SQL tables
escaped as database strings. After the classification fix, the locked request
and colour suites passed all 54 tests in 3.8 seconds. Eighteen added cases cover
nine actual public corruption/SQL refusals with untouched original receipts,
zero spend, no no-send/execution publication, stopped-writer persistence after
repair and unchanged history after fresh startup; eight healthy policy
refusals with subsequent cancellation; and one actual borrowed-Store SQL
authorization fault at initial admission authentication. That last case checks
the raw transaction error classification rather than asserting a public writer
health change. A missing-principal-table fixture hit the earlier controller
guard, and a blanket no-send read fault hit maintenance validation; neither
was used as evidence of the later authentication boundary.

The thirteen-suite affected run then passed 377 tests with zero failures in
501.9 seconds, including temporal enrollment/advancement, lifecycle and
occurrence history, the independent durable traces, direct requests/colour,
Store, causal roots, invariants, rule activation, maintenance, power execution
and framed local API routing. The route tests exercise `route_frame` directly;
this run did not repeat the preceding full suite's socket or host processes.
No socket-free exclusion flag was used. Formatting, warnings-as-errors
compilation, changed-document references and Git whitespace checks passed;
no held runtime artifacts remained.
All twenty workspace and nineteen staged contract metadata checks also passed.

Advisory held-power/colour inspection now shares that exact closed policy set.
It preserves successful transient decisions/plans and ordinary semantic
refusals without writing. Malformed guard input remains a caller refusal.
Errors outside the closed set stop writes; typed atom errors remain typed and
raw nonatom SQL errors become `store_unavailable`. Repair alone does not resume
that Store instance. This adds no plan, receipt, clock confidence or effect
authority and changes no wire shape. Six added public-reader cases cover
damaged declaration/value and missing SQL-table reads for power and colour,
unchanged originals/revisions/spend, disabled writes after repair and validated
restart. Existing report/boot/coherence and invalid-input cases keep the writer
usable. Before this change, both new SQL reader cases leaked the database string.
The locked five-suite affected run passed all 99 tests in 11.4 seconds,
including request/colour readers, Store, causal roots and direct framed API
routing. These are software checks; no host or physical qualification is added.
Formatting, warnings-as-errors compilation, all twenty workspace and nineteen
staged contract metadata checks, thirty-two local references and Git whitespace
validation passed. No held runtime files remained.
