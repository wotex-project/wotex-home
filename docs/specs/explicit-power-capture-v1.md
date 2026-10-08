# Original explicit power selection and report capture v1

Version: 0.1.0. Implemented trusted Store boundaries, 2026-10-08.
WOH.14 owns retained requests and transactions; WOH.03 owns device reports.

The controller can ask Authority for at most sixteen pending explicit power
originals after an advisory creation-revision cursor. Selection validates the
actual SQLite history and maintenance barrier. It derives principal, epoch,
operation and creation revision from retained receipts and causal roots;
no caller provides an author for a newly constructed request. Held and queued
boolean-power originals are returned in immutable creation order. Queueing
changes no position. Scheduled, migrated legacy, cancelled, terminal, claimed
and handed-off work are excluded. The cursor is not a durable watermark,
authorization or dispatch token. Reads change no revision or causal spend.

For one held original, the Store prepares a private refresh scope with the
original receipt, enrolled Thing, stable identity, binding and resource
revisions. Current ordinary-control permission, exact target grant, authority
epoch, request profile pin, declaration/resource and applicable explicit-rule
guards are required. The scope reuses the existing enrolled-LIFX read basis;
it exposes no routing endpoint or operator bearer and is not a wire route.
The existing authenticated refresh continues to authenticate before composing
that same enrolled read basis.

Before accepting reports, the Store reconstructs and compares the complete
scope under the original author. It validates the batch against the exact
Thing and commits through the existing identity-scoped LIFX refresh writer.
Freshly captured source epochs use that writer's existing requalification
rules. Receipt timestamps come from the actual Store clock, not adapter
coordinates. After report publication and history checks, the enclosing guard
repeats the original and scope again. A policy loss rolls back the full report,
journal, revision and source-custody transaction. SQL/history failures disable
the writer; they are not classified as ordinary authority loss.

A prepared scope grants no effect authority. Qualification, freshness,
serialization, invariant, override, generation, causal and attempt guards
still apply at the separate [original advancement](explicit-power-advance-v1.md),
claim and final handoff boundaries. Matching-report no-send closure retains its
existing qualification-free behavior. Reports cannot themselves settle a
physical command. All new calls are trusted internal operations without public
API or CLI routes.

Queued originals are selectable for recovery but cannot use held refresh.
Their sealed report revision must survive the separate claim and handoff
guards; refreshing it would replace that basis. Claimed or handed work cannot
be selected for blind replay. This implementation does not yet provide the
controller delivery consumer, fresh private routing, timers or device sends.
Those remain required for the product path. Physical dispatch stays disabled
by default and exact installed/device qualification remains separate.

The focused SQLite cases cover sixteen-row paging across nineteen originals,
immutable ordering after queue, exclusion after actual claim/handoff and of a
scheduled root, wrong original and malformed inputs, changed stable/binding/
resource scope, Store-stamped fresh-source reports, current author/grant/
credential withdrawal during capture, final author/grant loss during report
publication, and injected report-publication rollback. These synthetic signed
fixtures establish software guard behavior only.

On 2026-10-08, 87 selected direct-power and causal-history cases passed,
including all ten capture cases and the original advancement cases. Separate
fresh-Home runs passed 21 authenticated enrollment/refresh and durable-profile
cases, five capture-owner/API cases and 80 authority/request/maintenance/power
executor cases. The suites retained real local socket tests. The profile run
initially refused macOS's noncanonical `/tmp` alias; its successful rerun used
a short private canonical `/private/tmp` directory. No socket-free exclusion
was used. Formatting, warnings-as-errors compilation, contract/catalogue,
changed-document references and Git whitespace checks passed. This supplies
software evidence, with no installed or physical qualification claim.
