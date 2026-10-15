# Last resolved paired power receipt

Version: 0.1.1. Updated: 2026-10-15. Status: accepted implementation contract.
Owner: WOH.08 H08-09/H08-T9, WOH.15 H15-07/H15-T8. Implementation/evidence: planned.

## Observable result

After explicit paired power submission/recovery confirms resolution, Activity
retains one last resolved power/cancellation entry as in-memory metadata, without
bearer, session or new durable file. An explicit Use Last Paired Original action
copies its exact epoch/operation into the receipt fields. A matching lookup uses
the recorded paired controller even if another controller is selected. It does
not retry, cancel, publish, remember or remove a pending operation, update a
reported state, or require historical control permission. App restart discards
this convenience reference; durable unresolved recovery remains unchanged.

## Input, custody and fixed request

**PR-01 — Exact original reference.** Accept only an existing closed
NativePendingEntry of category power, input power or cancel, phase pending and
paired custody. Revalidate its complete existing encoding. Resolve its recorded
association ID from the exact current public association snapshot, then require
matching controller identity, deployment, owner, epoch, principal, creation
revision and verifier. Current UI selection does not choose its destination.
Missing/replaced association refuses; no new account, endpoint or local fallback.
Metadata is a read query, never a successful signing or authorization seal.
A fully self-consistent different reference is a different read query, not proof
that its association created an earlier operation. The presentation owner keeps
its exact resolved entry immutable and never substitutes another association
after a refusal. Identical verifier/principal values in two saved associations
do not make their association IDs interchangeable for that retained entry.

**PR-02 — Fresh read-only purpose.** Add a distinct actual paired-session
purpose usable only for the fixed status read. The factory acquires actual
protected-app identity, existing exact Keychain custody, pinned TLS and fresh
authenticated scope through the existing production gate. One original
five-second continuous lease includes acquisition, current scope, receipt,
final current scope and delivery. Repeat full association inode/content CAS,
actual signing/custody and original deadline around every exchange. There is no
pending-file requirement after confirmed resolution, no arbitrary SDK callback
and no selected/recovery/mutation capability exposed by this purpose.

Current scope must match original deployment/owner/principal/epoch and contain
read. Historical control or target grants do not authorize this read. The
server's existing principal-scoped status route decides visibility. Compare
scope identity, exact permissions/targets and nondecreasing revision before/after
the status read. Existing closed receipt decoding checks epoch and operation;
found receipt revision must not exceed final authenticated Store revision.
Not found means absent in that current authenticated original scope, not proof
that the earlier submission was never sent. No API or Store schema changes.

**PR-03 — Presentation and concurrent changes.** Return only original metadata,
typed found/not-found receipt and original absolute delivery deadline. It has no
credential or reusable session. Check the deadline after projection and again
at driver and MainActor delivery. Preserve the original driver selection snapshot
and in-process generation through the read even when its selected row differs
from the recorded destination; reload/change/wake/cancel/expiry discards late
presentation. Capture exact input epoch/operation and last-reference identity;
editing fields or replacing that reference invalidates completion. Duplicate
clicks cannot queue work. Receipt reads share the application's busy guards.

Resolution callbacks and confirmed first-publication results may retain that
one reference. The convenience button starts no I/O. Caption the recorded
paired source and keep held/queued/ACK/observed dispositions distinct. Matched
paired reads never touch local credential/UDS, including on error or absence.
Local receipt behavior remains guarded by actual local selection. Cancel and
Retry controls cannot use this read-only paired reference; unresolved paired
decisions stay in their existing original recovery workflow.

## Acceptance and remaining installed gates

| Case | Required executable evidence |
| --- | --- |
| PR-T1 | Independent metadata checks reject local/non-power/phase/association/controller/verifier/context substitutions; selection of another saved controller still resolves only the recorded one. Fresh read-only scope is sufficient; scope drift, receipt identity and future revision refuse. |
| PR-T2 | Actual unsigned production factory refuses before Keychain/clock/transport; missing clock and missing association remain bounded refusal, with no fallback. Raw credential TLS/real Store fixtures separately check current scope and immutable receipt/not-found/other-principal visibility without claiming a signed seal. |
| PR-T3 | Shared health model retains at most one last paired original, explicit field copy and lookup; repeated click, changed input/reference, generation invalidation, expiry, not-found and failure never call local custody or mutation/recovery. Inspect the Activity source label/control layout. |
| PR-T4 | Existing local receipt/retry/cancel, shared controller reads and paired recovery/first-publication regressions pass. Positive installed app/Keychain, trusted certificate clock and supported macOS TLS remain actual delivery requirements. |

No fixture can mint a successful production session. Metadata/transport/model
evidence remains separate from signing, host storage and physical qualification.
Keep default-disabled physical dispatch and unchanged dependency pins.
