# Retained schedule occurrence consumption v1

Version: 0.1.4. Implemented schema-26 calculation ledger, 2026-10-08.
WOH.04 owns temporal admission, WOH.14 the single writer and WOH.16 recovery.

The single Store can consume an occurrence of the retained
[single active schedule](schedule-lifecycle-v1.md). This establishes durable
identity and a considered-through watermark. Schema 26 eligible candidates
return `blocked` with `temporal_execution_unavailable`; uncertain candidates
return `blocked` with `clock_uncertain`. Schema 27 separately adds
[held-request provenance and temporal execution guards](schedule-effects-v1.md)
for newly eligible consumption, without retrofitting old calculation-only rows.
[Store-owned advancement](schedule-advance-v1.md) separately handles retained
unsent intent without bearer credentials. Autonomous polling, composed runtime
proof and cursor-preserving
compaction remain work. The explicit-request profile gains no temporal authority.

The [prepared Authority poll](schedule-poll-v1.md) now calculates outside the
writer from one retained Store snapshot and commits through the same publication
path. Its ephemeral caller-bound reference cannot supply a new clock, survive
restart or make a consumed coordinate eligible again.

`schedule_considerations` has twelve ordered columns: activation revision,
previous watermark, watermark, canonical clock document, decision, canonical
occurrence document, occurrence ID, causal ID, missed-range lower and upper,
reason and publication revision. The immutable row references the original
activation and its unique authority-journal revision. Nullable occurrence fields
are all absent only for a missed-range record. Occurrence and causal IDs are
unique. `schedule_watermarks` contains activation revision, considered-through
coordinate and unique head consideration revision; it is a checked projection
of the immutable chain, never independent authority.

The internal Store poll takes no caller clock, source, operation ID or bearer.
It first validates history, observes current admission/timezone loss through
the existing sticky withdrawal mechanism and requires the original active
epoch/generation with current author, target, declaration, profile, invariant
and complete runtime correspondence. Its lazy owned clock and installed timezone
callbacks supply the actual calculation inputs. Unqualified time refuses before
consumption. Original deployment, owner, epoch and runtime must match activation.
A UTC definition can use a fresh qualified boot/clock generation; that change
does not enter the occurrence identity. Countdown sources instead retain their
original boot/generation through [durable countdown expiry](schedule-countdown-lifecycle-v1.md).

The retained clock document uses the closed 4096-byte
[activation-clock encoding](schedule-lifecycle-v1.md). The pure planner selects
at most one due coordinate inside the late window and advances the watermark
to the qualified interval's lower endpoint. Eligibility requires the entire
interval to be at or after due and strictly before due plus the late window,
with admitted uncertainty tolerance. A candidate considered uncertain is still
consumed: later narrowing cannot retry it. Canonical occurrence identity binds
source revision/digest, authority epoch, global rule generation and coordinate;
its separately derived causal ID identifies the calculation. The schema-26
ledger alone opens no causal root; schema 27 records a distinct temporal request
origin separately.

Earlier coordinates are summarized by at most one half-open-left, closed-right
missed range `(previous watermark, cutoff]`, without enumerating overdue work.
A poll with neither a candidate nor an actual recurrence inside that range
retains nothing and changes no revision. Frequent early polling therefore cannot
fill authoritative history. Repeated polls and backward corrections cannot
consume a coordinate at or below the retained watermark. Forward jumps consume
one candidate or one bounded missed range, with no catch-up or replay.

One transaction publishes `schedule_occurrence_considered`, its immutable row
and the cursor CAS. It repeats current activation, qualified clock scope,
nondecreasing Store monotonic observation and exact installed timezone before
returning a commit decision. Any failed repeat, row or cursor publication rolls
back the complete publication. A poll that discovers withdrawal commits that existing barrier
and returns inactive. No transport operation occurs inside this transaction.

Existing-only occurrence lookup requires a current authenticated review
permission for the activation's original principal. It returns the immutable
consumption receipt without current target grant or clock confidence. Another
principal sees absence; malformed IDs are rejected. Retired-source original
reads remain allowed. There is no public clock upload or polling adapter.

History is bounded to 4096 considerations and 4,194,304 combined UTF-8 bytes of
clock/occurrence documents, IDs and reasons. Capacity refusal preserves every
original, cursor and revision. No truncation, automatic resume at capacity or
cursor compaction is implemented. Validation rebuilds every closed calculation,
checks the exact cursor chain and head projection, source/activation bindings,
unique journal links and event counts, preceding active generation/lifecycle,
revision ceilings and nondecreasing clock observations within each retained boot.
Damage disables ordinary writes and fails startup and authenticated verification.

Actual schema 25 migration adds empty tables without a journal, authority epoch,
generation, receipt, pointer or time-confidence change. Unexplained consideration
events roll back the actual DDL/version transition. Retired sources remain
refused before migration. Archives use exact schema-specific table sets 4–27,
report consideration/watermark counts separately and include no temporal source
custody. Transfer normalizes empty tables for older supported sources and retains
nonempty occurrence/cursor history while revoking the old epoch/author. Restore
remains quarantined. Same-owner restart requires fresh private boot-bound time
and current admission; its retained UTC watermark cannot replay consumed work.

An independent arithmetic oracle covers 96 interval/cursor/uncertainty cases,
empty polling, long downtime, canonical damage and UTC identity across fresh
clock/boot scopes. Actual SQLite/private-clock cases cover due polling, serialized
competing polls, backward correction, uncertain consumption, bounded missed
ranges, fresh-clock restart, sticky grant withdrawal, cursor and repeated-clock
rollback, encrypted quarantine, actual migration/DDL rollback, damaged live/
startup/archive links and the real 4096-row ceiling. A guarded transfer carries
nonempty considerations and their cursor. These are software integrity results;
installed-clock, target-storage power-loss, signed-host and physical qualification
remain separate obligations.

On 2026-10-08 the schema-26 locked Mix suite passed 1107 tests with zero failures;
four opt-in component cases were skipped. Real socket and foreground-host cases
ran. Warnings-as-errors compilation, formatting, all 20 workspace contract
metadata checks and Git whitespace validation passed. The support-file
load-filter warning remains unrelated to this mechanism.
