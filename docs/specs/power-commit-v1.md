# Final power claim and handoff commit guards v1

Version: 0.1.0. Implemented schema-27 enclosing Store guard, 2026-10-08.
WOH.14 owns durable execution and WOH.16 retained history and recovery.

The single Store repeats the current power execution basis after the writer's
claim or handoff publication, sticky schedule withdrawal and complete authority
history validation. Only a successful final repeat can return a claimed token
or a committed `dispatching` receipt. The existing power executor sends only
after that receipt. A refusal produces no packet, protocol acknowledgement or
physical outcome. Physical dispatch remains disabled by default.

The final repeat validates the exact principal/epoch/operation receipt,
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

A savepoint begins before the tentative claim or handoff. A final policy refusal
restores the original queued or claimed phase, discarding its tentative token,
handoff marker, attempt timestamp and journals. The Store then observes current
sticky schedule withdrawal again against that original durable phase and
validates history before committing the typed refusal. This allows a necessary
generation barrier to survive without treating a never-committed handoff as a
possible physical effect. Refused claims return no token; invalidated claims
lose their in-memory owner monitor. Failure of SQL or historical integrity rolls
back the entire transaction and retains the existing fail-closed Store behavior.

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

Software cases use actual public Store claim/handoff operations and SQLite
history. A private clock fixture changes only at the enclosing guard to check
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

On 2026-10-08 the locked full Mix suite passed 1170 tests with zero failures
in 366.0 seconds; four opt-in component cases were skipped. Real socket and
foreground-host cases ran. The six targeted withdrawal, handed-restart and
executor cases passed after correcting lifecycle reason correspondence.
Warnings-as-errors compilation, formatting, all 20 workspace and 19 staged
contract metadata checks, changed-document references and Git whitespace
validation passed.
The existing support-file load-filter warning remains unrelated to this change.
