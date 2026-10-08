# Native pending-operation custody v4

Version: 0.1.1. Accepted schedule-original extension, 2026-10-08.
WOH.08 owns the private client journal; WOH.14/15 retain schedule, Store and
current authorization semantics. This extends [v3](native-pending-custody-v3.md)
with the [schedule client correspondence](native-schedule-client-v1.md).

The root is `["wotex-home.native-pending.v4",revision,entries]`. Preserve every
v1/v2/v3 entry, ordering and one category per controller owner, the fixed private
file/lock paths, full-content/revision/inode CAS and existing 65,536-byte,
depth-four, member-thirty-two and sixteen-entry bounds. Older roots refuse
schedule input; unknown versions and records fail closed without reset.

A new `schedule` category has exactly one input:
`["schedule_operation",original_document]`. Its second member is the complete
canonical schedule-operation document, including source and rule documents for
review/admission. Only this v4 string slot permits up to 8,192 decoded ASCII
bytes and canonical quote/backslash escapes. Every other string keeps the
128-byte unescaped ASCII bound; neither older roots nor existing entry grammars
expand. The original codec separately enforces its source/rule/record bounds,
exact syntax, complete source joins and signed-64-bit scalar identity.

The only phase is `["pending"]`. Original epoch equals the retained context;
content author equals its principal. Manual custody remains the fixed account
and verifier. Native custody is the original Operator role and the expected
revision is at least its creation revision. The record contains no credential,
clock sample, proof, timer or approval renewal. Rule and schedule originals
remain distinct categories; the shared coordinator requires current originals
to resolve before new work.

Read and unchanged confirmation never rewrite a root. First schedule publication
upgrades an older root under the existing shared CAS, advances revision once
and preserves old originals. Keep v4 after resolution, when empty and on later
ordinary publication. Concurrent ordinary/upgrade publications have one winner;
the stale process cannot discard, overwrite or silently upgrade another result.

Publish the complete original before each recorded review, admission, activation
or suspension mutation. Shared recovery opens existing original custody, checks
credential bytes and authenticated controller/principal, then uses the exact
original-status join or exact typed retry. Verify the complete original and
principal plus closed kind/digest/receipt correspondence before durable removal.
Missing result, later refusal, changed custody/controller or malformed reply
retains the original. An uncertain publication must reload and publish the same
original before retry. Load sends no automatic lookup, retry or replacement.

Review/admission, active readiness and immutable lifecycle status remain separate.
Recovery changes no device observation and grants no clock, autonomous timer or
physical qualification. Default-disabled dispatch remains unchanged. The [native schedule panel](native-schedule-panel-v1.md) now composes the
reviewed client decisions; source-bound autonomous runtime admission remains
a separate delivery obligation.

Required evidence includes all fifteen independently serialized original vectors,
sixty-one malformed original refusals, unchanged old-root vectors, wrong epoch,
author, native role, phase, revision and category-conflict refusal; allocation and
escape bounds confined to the one new slot; actual file/version preservation,
no-op bytes, stale CAS, mixed old originals and competing-process upgrade;
actual Store lost replies, exact lookup/retry, missing or unsubmitted requests,
later revocation, custody/controller mismatch, malformed receipts, publication
uncertainty and separate client-process restart. Signed installed custody and
storage survival require their own evidence.

The implemented Swift codec checks all fifteen independent original vectors and
sixty-one malformed originals through the journal, plus older roots, mixed
originals, custody/context/phase/conflict and slot-specific bounds. Actual file
tests preserve old power/access/rule originals through v3-to-v4 publication,
no-op bytes, stale CAS and resolution; empty and ordinary later documents keep
v4. Two actual processes race ordinary and schedule publication from the same
v3 snapshot, with exactly one winner and a fresh-process read of all originals.

`mix woh.native.schedule.recovery.smoke` passed fourteen real private-Store
workflows: every operation kind's lost reply followed by lookup or retry in a
separate client process, unsubmitted/missing requests, later principal revocation,
wrong custody/controller, a damaged digest followed by valid lookup, and failed
publication followed by reload and exact retry. The proxy checks complete v4
publication before every mutation and exact original bytes on every retry. A
third process reads the final journal without sending a request. Actual host
clock custody is a signed software fixture for activation; it neither qualifies
an installed clock nor registers a timer or device worker.

The existing coordinator restart checks, thirty-four session workflows and
twenty-two rule-panel workflows also passed. Twenty affected schedule codec/API/
macOS inventory/SPDX/dependency tests passed in 8.1 seconds, including real socket
and private-file cases with no exclusion. Full native app source typechecking,
locked compilation with warnings as errors, formatting, contract metadata,
relative references and Git whitespace passed. The narrow schedule pending view
was rendered and inspected at the supported 480-point width. No new app artifact,
remote CI, Keychain installation, signing or physical qualification was tested.
