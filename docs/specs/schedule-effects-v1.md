# Scheduled held intent and temporal execution guards v1

Version: 0.1.1. Implemented schema-27 Store provenance and advancement, 2026-10-08.
WOH.04 owns admission, WOH.14 the transaction and WOH.16 recovery.

A newly consumed eligible [occurrence](schedule-occurrences-v1.md) can create
one ordinary absolute Boolean power request under its retained original author.
This is a distinct `schedule_occurrence` causal origin with the deterministic
occurrence ID as operation ID. It does not inherit the explicit-request profile.
The separate `home-single-schedule-cause-v1` root has one effect and depth one;
queue admission spends it once. Cancellation, fencing, restart and settlement
cannot refund it. Holding intent is separate from queue admission, handoff,
protocol acknowledgement and reported state. Physical dispatch remains disabled.

The Store borrows its one connection and supplies its private lazy clock context.
No runner or device worker receives a bearer or SQLite handle. Separate
[Store-owned advancement](schedule-advance-v1.md) now queues or terminalizes
retained unsent work without bearer credentials or caller timestamps. This slice
has no autonomous timer, cursor compaction or physical command.
Multiple active schedules, countdown admission, composed runtime proof and
installed-clock qualification remain separate work. Calculation/guard evidence
in the existing temporal admission artifact retains its declared scope.

`schedule_effect_operations` has nine ordered columns: consideration revision,
original principal, epoch, operation ID, decision (`held` or `blocked`), reason,
nullable original request revision, runtime digest and publication revision.
The consideration is its primary key; scoped identity, request revision and
publication revision are unique. Foreign keys link consideration, principal,
request journal and authority journal. Held requires a request and no reason;
blocked requires a bounded reason. Publication uses `schedule_effect_held` or
`schedule_effect_blocked`, bound to the exact occurrence ID.

One Store transaction publishes the consideration and cursor, repeats current
maintenance/lifecycle/author/target/declaration/profile/invariant and qualified
clock/timezone guards, creates the normal held or rejected request and causal
root when possible, and publishes immutable temporal provenance. It repeats the
owned clock and current activation before commit. Any failed SQL publication,
cursor CAS or final repeat rolls back all requests, roots, journals and cursors.
Capacity or a stage policy refusal instead consumes one terminal blocked
occurrence; missing request capacity creates no new request or causal root.
Uncertain or expired calculations cannot create temporal intent. Later narrowing,
grant restoration or repeated polling cannot retry a consumed coordinate.

The normal request path preserves its existing outbox, declaration/profile pins,
immutable original receipt and policy checks. New public manual requests and new
explicit rule invocations cannot use the reserved `occ:` namespace. Existing
original lookup precedes that restriction: an older manual receipt in this
namespace retains its old origin and exact retry without temporal authority.

The shared execution guard distinguishes the retained causal origin at queue,
no-send closure, claim and final durable handoff. A scheduled request must match
its original canonical consideration, source/admission/activation, request creation
journal and distinct root. Current original-author permissions, target grants,
epoch, global rule generation, exact declarations/profile/invariant and runtime
remain mandatory. The current qualified temporal snapshot must match the original
request's deployment, owner, epoch, boot, clock generation and runtime, with
nondecreasing Store monotonic time. Installed timezone bytes must match admission.
The entire current UTC interval must be at or after due and strictly before the
late-window end, within admitted uncertainty tolerance. Early, uncertain, expired
or changed clock basis refuses at each boundary. Invariants and operator overrides
are checked again. Existing qualification, fresh reported baseline, effect-domain,
attempt, claim ownership and causal-spend guards still apply.

Current portable profile bytes are verified outside SQLite before schedule calls
and before unrelated calls while a schedule is active, because every committed
Store write repeats its authority basis. Those TEMP commitments are cleared on
every reply and worker-death transition. Missing actual bytes can permanently
withdraw current authority; an empty boot preflight cannot manufacture such a
loss during historical handed-work recovery. Original receipt reads use retained
history and need no current profile bytes or clock confidence.

Integrity rebuilds canonical calculation correspondence and validates every
operation/source/request/root/journal join, complete event counts and revision
ordering. A temporal root cannot be relabeled as explicit or detached from its
operation. Damage disables writes and fails startup and authenticated verification.
Effect rows are bounded by the existing 4096-consideration ceiling. Original
occurrence lookup returns immutable calculation and effect provenance; subsequent
execution or cancellation is obtained through normal request status.

Actual schema 26 migrates by copying every ordered causal-root column into the
new origin constraint and adding an empty effect table. Revision, epoch,
generation, grants, spent roots and receipt identities are unchanged. Historical
calculation-only occurrences acquire no request authority. An unexplained effect
journal rolls back the actual DDL and version. Archives use exact table sets for
schemas 4–27 and count effect rows separately; transfer normalizes empty effect
history for older sources and retains nonempty original provenance. Transfer
supersedes old epoch/author authority; restore remains quarantined. Copied clock
records grant no current confidence. Handed work becomes outcome unknown after
restart and keeps its spent root.

Software cases exercise actual private-clock polling, normal queue/claim/handoff,
an independent early/uncertain/expired boundary oracle at all three execution
boundaries, clock-generation refusal, cancellation without refund, handed restart,
publication rollback after root creation, terminal capacity refusal, namespace
reservation through the actual Unix socket, actual old-root migration and retry,
calculation-only upgrade,
damaged live/startup/archive provenance, selected-profile byte preflight and
sticky loss, and retained transfer/quarantine. Synthetic signatures establish
software correspondence only. No packet or hardware qualification is inferred.

On 2026-10-08 the locked full Mix suite passed 1119 tests with zero failures;
four opt-in component cases were skipped. Real socket and foreground-host cases
ran. The subsequently added Unix-socket namespace case passed its focused run
(one test, zero failures). Warnings-as-errors compilation, formatting, all 20 workspace
contract metadata checks and Git whitespace validation passed. The existing
support-file load-filter warning remains unrelated to this mechanism.
