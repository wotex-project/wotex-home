# Retained single-schedule lifecycle v1

Version: 0.1.3. Implemented schema-25 Store lifecycle and adapters, 2026-10-08. WOH.04
owns the temporal profile, WOH.14 the transaction and WOH.16 recovery.

This slice implements durable activation and suspension of one separately
admitted ordinary Boolean-light schedule. It creates no occurrence, held
effect, timer or device command. Separate [schema-26 occurrence retention](schedule-occurrences-v1.md)
now follows this lifecycle. Held intent and claim/handoff temporal guards
are separately implemented in [schema 27](schedule-effects-v1.md). Autonomous
polling/queueing and composed runtime proof remain work.
The existing explicit-request admission profile
does not gain temporal authority. Composed active sets remain unsupported.

The single Store owns `schedule_lifecycle_operations`. Its ordered columns
are principal ID, authority epoch, operation ID, kind (`activate`, `suspend`
or internal `withdraw`), expected revision, exact input document, admission
revision, previous generation, generation, barrier revision, publication
revision, affected requests, unknown outcomes, reason, activation-clock
document and initial considered-through watermark. Principal/epoch/operation
is the primary key. Barrier and publication revisions each uniquely reference
the authority journal. No mutable active pointer can recreate old activation.
The latest lifecycle operation is eligible only while its original epoch and
generation equal the current Store and its current admission remains valid.

Public activation/suspension use the existing closed
[schedule-operation codec](schedule-operation-v1.md). Both require current
review, management and ordinary-control permissions plus original epoch and
revision CAS. New activation additionally requires the admission's original
author, all current target/declaration/profile/invariant/runtime joins and
absence of maintenance. Reviewed content cannot activate. Calendar bytes must
still match the bounded host-owned installed timezone; no caller timezone
document or client timestamp establishes an activation basis.

Activation requires an actual attached [private clock owner](schedule-clock-owner-v1.md)
through the [Store clock context](schedule-clock-context-v1.md). The complete
UTC interval must fit the admitted uncertainty tolerance. The canonical
`wotex-home.schedule-activation-clock.v1` record contains an ordered original
deployment/owner/epoch/boot/clock-generation/runtime scope, complete clock sample,
Store monotonic observation and initial watermark. Retained scope joins the
actual ownership history at admission. The document is bounded to 4096 bytes;
decoding proves correspondence, never current clock trust.

Activation advances the existing global generation fence, clears the explicit
rule pointer and applies the ordinary held/pending invalidation mechanism.
Unsent work is rejected; handed work becomes `outcome_unknown`. Causal roots
and prior receipts remain spent/retained. Clock, current admission and timezone
are sampled again after the barrier, before lifecycle publication, and repeated
before returning the transaction's commit decision. The UTC watermark is that
post-barrier interval's upper endpoint, excluding every coordinate possibly at
or before the recorded activation boundary. A future countdown activation
calculation must bind the original boot/generation, a past start and strictly
future due coordinate; countdown admission remains unavailable in this slice.
Any failed repeat or publication rolls back barrier, invalidations and history.

The immutable receipt returns original kind/state, principal/epoch/operation,
complete input digest, admission revision, previous/current generation, barrier
and publication revisions, affected/unknown counts, reason and initial watermark.
Exact retries resolve before current CAS, grant, clock, maintenance or capacity
checks and retain this receipt. Changed kind/input and operation identity reuse
across admission/lifecycle ledgers conflict. Original lookup requires current
review authority for that same principal; it creates no operation or revision.
An original activated receipt remains historical after later suspension.
The [local API and CLI](schedule-api-v1.md) expose closed activation/suspension,
original lookup and read-only current readiness. Readiness selects the latest
operation for the authenticated principal, retaining the old author's visible
superseded generation when another authorized manager suspends the set.

An ordinary Store transaction that observes loss of the current admission or
timezone basis withdraws the schedule inside the same transaction. Internal
withdrawal records bind the previous activation, current epoch/revision and
reason; `schedule-withdraw:` is reserved from new public operations. Its barrier
prevents restoring a principal/grant/profile from silently resuming that
activation. If an existing maintenance, transfer or rule-generation barrier
already supersedes the activation, no second fence is added: the replacement
generation remains intact. Current readiness reads can report a missing clock
without changing historical activation; an occurrence runner must separately
observe and retain terminal assumption loss before creating work.

An ordinary same-owner restart retains definitions, original activation and
watermark but starts with no qualified temporal source. Readiness requires new
boot-bound private clock custody and current admission/timezone validation.
This is readiness of retained lifecycle data, not evidence of autonomous restart
execution. Transfer retains the immutable rows while changing epoch/generation
and revoking the old author. Restore remains quarantined and includes no active
clock-source custody. Historical clocks do not authorize the receiving owner.

History is bounded to 1024 rows and 8,388,608 combined UTF-8 input/clock-document
bytes. New public operations stop at 960 total rows, leaving space for withdrawal.
Exact recovery remains available at capacity. No history is truncated or
compacted. Validation checks closed canonical documents, source/author/ownership/
clock/watermark joins, generation counts, disjoint original identities, complete
barrier/publication journal links and the exact intervening rejected/unknown
request counts. Current active schedule generation cannot coexist with an
explicit-rule pointer. Damage disables writing and fails startup/archive checks.

Actual schema 24 migration adds only an empty table, with no authority revision,
epoch, generation, rule-pointer, receipt or clock-confidence changes. Unexplained
lifecycle journals roll back the actual DDL and version. Retired sources are
refused before normal migration. Archive verification accepts exact table sets
for schemas 4–26; guarded transfer normalizes an empty lifecycle table for older
supported sources and preserves nonempty history. Archive dependencies report
retained schedule rows separately and explicitly exclude temporal clock authority.

Fifteen actual SQLite cases cover original retry/conflict/private lookup,
current author/CAS/clock refusal, held-work fencing and root retention, sticky
grant withdrawal/restoration, an existing replacement barrier, injected SQL
publication failure, post-barrier clock failure, same-owner restart, clock
withdrawal, installed calendar bytes, encrypted/quarantined restore, migration/
DDL rollback, historical damage and the real 960-row public ceiling with reserved
withdrawal. A guarded owner-transfer case retains admission and activation.
An independent pure boundary oracle covers 72 UTC interval cases and 32 countdown
cases, canonical round-trip and malformed/unqualified/cross-scope refusal.
These are software results; no installed-clock, storage power-loss, signed-host
or physical qualification is claimed.
