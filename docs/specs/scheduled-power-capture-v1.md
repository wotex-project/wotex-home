# Original scheduled power selection and report capture v1

Version: 0.1.1. Implemented trusted Store boundaries, 2026-10-08.
WOH.04 owns temporal authority, WOH.14 transactions and WOH.03 device reports.

Authority can select at most sixteen retained held or queued boolean-power
occurrence originals after an advisory immutable creation-revision cursor.
Selection validates the complete SQLite history and maintenance barrier and
returns only `schedule_occurrence` roots. Explicit, migrated legacy, cancelled,
terminal, claimed and handed-off work are excluded. The original principal,
epoch, operation and creation revision come from retained rows. A Store revision
cutoff bounds the caller's scan; selection, cursor and cutoff grant no authority
and change no revision, receipt or causal spend.

The Store prepares a private read scope for one held original. A separate
delivery scope also accepts a sealed queued original, without permitting that
original to refresh its baseline. Both require current original-author review,
management and ordinary-control permissions, exact target grant, authority
epoch, request profile pin, declaration/resource, enrolled stable identity and
binding. The common borrowed LIFX read-basis collaborator retains separately
required explicit and temporal root kinds; neither can borrow the other's
original. These internal operations expose no bearer or public API/CLI route.

The existing temporal execution guard additionally repeats the exact retained
occurrence and current activation/artifact, Store clock scope/confidence,
installed timezone, entire due/late window, current invariant and override.
Boot-local countdowns keep their continuous-clock/generation requirements;
UTC occurrences keep qualified wall-time requirements. A captured report,
adapter clock or caller timestamp cannot replace this Store-owned basis.

Report publication reconstructs and compares the whole original read scope
before using the existing enrolled-LIFX batch writer. Reports are validated
against the exact immutable Thing. Receipt coordinates come from the actual
Store clock. After report/history publication and sticky basis withdrawal, the
enclosing typed guard reconstructs the scope again, including current temporal
window and clock confidence. Expiry or author, grant, activation, profile,
resource or clock loss rolls back the complete report, journal, revision and
source-custody transaction. A generation withdrawal may already have closed the
held request inside the tentative transaction, yielding `request_not_held` at
the final scope check. SQL/history failure rolls back and disables the writer.

Publication never queues or sends. Existing
[schedule advancement](schedule-advance-v1.md), claim and committed handoff
still require current qualification, exact fresh baseline, temporal window,
serialization, causal and attempt guards. Matching-report no-send closure
retains its separate qualification-free semantics. A queued original's sealed
report cannot be replaced through held refresh; claimed or uncertain work is
absent from selection. There is no new schema or persistent receipt shape.

These boundaries supply the fresh-report prerequisite for autonomous temporal
delivery. The separate [private delivery composition](scheduled-power-delivery-v1.md)
now consumes this scope. Queued delivery privately joins its sealed baseline
to the current report producer; it grants no source reset. The controller timer
and installed clock custody remain subsequent work; the separate explicit consumer
does not select these roots. Physical dispatch remains disabled by default,
and synthetic signed fixtures do not qualify hardware or an installed host.

Focused software cases use actual Authority/Store calls, private controlled
clock peers and SQLite transactions. They check seventeen-original paging,
unchanged revision, cancellation exclusion, original/root separation,
substituted binding refusal, Store-stamped fresh-source publication, final
expiry/confidence/uncertainty loss, final author/grant withdrawal, queued
baseline preservation, claim exclusion, damaged creation provenance and
injected report-publication rollback. Complete snapshot integrity and unchanged
causal spend are checked at those boundaries.

On 2026-10-08 all ten focused capture cases passed, followed by 52 occurrence,
clock-owner and consideration cases. The separate 99-case direct-power and
causal-history regression retained real local socket tests. The focused filter
excluded 422 unrelated cases; no socket-free option was used. The initial run
used a wrong source-grant column name and expected grant refusal before the
existing sticky withdrawal terminalized the request; the corrected ten-case
run passed. Formatting, warnings-as-errors compilation, contract/catalogue,
changed-document references and Git whitespace checks passed. These are
software checks, with no installed or physical qualification claim.
