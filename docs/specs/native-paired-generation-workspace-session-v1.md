# Existing paired generation workspace session

Version: 0.1.4. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-09/H08-T9; WOH.15 H15-07/H15-T8;
WOH.18 H18A-04/05, H18-T16/T17 and paired composition NPA-03/04.
Implementation: fixed existing-only purpose, closed workspace operations and
private transitions implemented. Evidence: [native/private-file and raw TLS/Store
checks](../provenance/native-paired-workspace-session-2026-10.md); installed signed
success remains unexecuted. Selected driver/presentation and cancellation lookup
now have [bounded composition evidence](../provenance/native-paired-generation-ui-2026-10.md).

## Purpose and fixed inputs

An explicit action on a retained paired generation workspace uses its original
controller and principal even when another controller is selected. This contract
owns the existing-only signed purpose and closed operations. It does not enable
a first preparation/attempt submission or authorize an automatic repair. Its
[composition owner](native-paired-authoring-generation-v1.md) owns fresh selected
authorization, workspace-before-pending-before-send and subsequent presentation.

Require one exact checked [v2 workspace](native-generation-workspace-v2.md) entry,
its complete private file snapshot, a full controller-association snapshot, a full
pending-journal snapshot and one closed action. Actions are status, cancel, lookupCancellation,
restorePending, assessDraft(operation ID,instruction), or archive(acceptUncertainty).
An assessment ID obeys the 1–128 ASCII Home ID grammar; instruction is at most4096
UTF-8 bytes with no Cc controls except LF/TAB. Unknown actions have no fallback.
Other actions accept no editable original, input, credential or callback.

The entry has exact deployment/owner/epoch/principal and paired association,
controller, creation revision and verifier. Match its original public association,
including the same context/creation/verifier and approved profile:manage. The entry
must occur exactly in the supplied workspace snapshot. Retained originals and
attempt links must pass their owning codec. Public values provide correspondence
only. The factory first obtains the actual signed app access, then checks current
private file witnesses and existing Keychain custody. It imports no key and
resolves no alternative association. Current pinned-TLS controller scope must match
that original and include profile:manage. Clock uncertainty refuses.

## Lifetime and operations

**PGW-01.** Acquisition, all exchanges, private publication and final delivery
share the original five-second continuous lifetime. Reuse that actual app/custody
seal; never reacquire or renew it. Check full workspace/pending/association CAS,
current app/custody and current scope before/after exchanges and publications.
Permission/target changes within the action, wrong principal/epoch, regressing
revision, stale or unsafe files, clock/deadline/cancellation fail closed. A possible
write/send retains uncertainty and requires explicit reload. No callback can
supply a successful signing result. Redact private reflection.

**PGW-02.** Status reads the exact preparation and latest attempt by retained
identity through the typed generation SDK. Verify their complete original/result
correspondence and final controller revision at least every known result revision.
Missing is distinct from a row in prepared/running/unknown/candidate/retired or
cancelled state. Status writes no file and never submits a missing operation.

Cancellation reads the existing root first. Missing refuses without intent/send.
Before cancellation send, publish the exact false-to-true cancellation intent CAS;
if already true, verify that same snapshot without a new revision. Continue only
that permitted successor under the same seal/deadline. Call the typed idempotent
root cancellation once. Only a matching cancelled root may publish true-to-false;
other/missing/refused/lost responses retain intent. It claims no stopped model.

Explicit lookupCancellation requires retained cancellation intent and reads the
same exact root/latest status without sending cancellation. Only a matching
cancelled root may publish the exact true-to-false intent successor under the
same seal/deadline; missing or another state retains intent. The fixed lookup
and selected consumer are implemented; positive installed signing remains open.

Restoration refuses cancellation intent or any pending operation in that same
deployment/owner/epoch. Read exact root/latest status first. A missing root is
allowed only when no attempt exists, for an interrupted first publication. With
attempts, require the root to exist; latest absence is retained as uncertainty.
Publish only the latest attempt or, if none, the preparation, in pending phase
with unchanged workspace custody/context. Exact before+entry/revision+1 and the
required retained v8 version must correspond. No generation mutation follows.

**PGW-03.** assessDraft requires a latest attempt with a checked candidate result
and mechanics assessment. Read its exact owned draft and stable generated import
receipt: import ID is ga: plus SHA256 of UTF-8 domain
`wotex-home.generation-object-operation@1` followed by LF and canonical JSON array
[principal,epoch,attemptOperation,"draft"]. Match draft kind/digest/first revision,
payload SHA and bytes against the generation result. Derive source handles from
explicit root passages and fixture handles from root examples, deduplicated and
sorted by digest; conflicting first revisions refuse. The derived handle join
accepts at most32 exact object_digest/first_revision rows per category, lower hex64
digests and positive signed-64 revisions, without bool/float coercion. Duplicate
identical handles collapse; output is strictly digest-sorted. Source/fixture kinds
remain separate and each retained object must have its exact declared kind and
first revision. No mismatch can become a prepared manual original. Read those owned objects,
current authoring contract and stable current identity. Require the original
workspace basis SHA and exact controller/principal/epoch; no generation row is
cast to a manual candidate. Build a fresh complete manual candidate using that
contract's reader/authoring limits, the given ID/instruction and checked handles.
Return only private decision metadata (original, identity, contract/basis and
original association/scope). Never retain bearer, seal or session for human review.
Selection correspondence and fresh confirmation belong to the composition owner.
No candidate mutation, approval or file write occurs here.

**PGW-04.** Archive refuses cancellation intent, same-scope pending and running
latest attempt. Read root/latest status. Missing root or attempt and unknown/null
result require explicit acceptUncertainty; a checked non-running settled history
may archive without it. Remove only this exact workspace entry under full CAS,
revision+1 and retained v2 version, preserving every other row. This forgets client
metadata only: no cancellation, new attempt, budget refund or provider-stop claim.

Every successful result carries the exact resulting workspace/pending snapshots
and checked status or assessment metadata. Only the actual fixed-purpose consumer
can deliver a production result; late completion cannot deliver a usable seal.
Coordinator memory consumes those exact snapshots or requires reload after failure.

## Acceptance and evidence

Freeze independent Python workspace intent/removal/pending-publication vectors
before implementation. Do not allocate expected valid bytes with the Swift owner.

| Case | Requirements | Falsifying trace | Evidence level |
| --- | --- | --- | --- |
| PGW-T1 | 01 | Wrong association/context/creation/verifier/grants/action/snapshot; actual unsigned factory reaches account/clock/network; raw fixture constructs a signed purpose. | Metadata/native refusal |
| PGW-T2 | 01/02/04 | Independent exact no-op/intent/removal/restore transitions, other rows changed, version downgrade, stale inode/revision, late publication or multiple publisher winners. | Private file/process |
| PGW-T3 | 02/03/04 | Real pinned TLS/Store original status, cancellation intent before send, dropped reply, restore without mutation, owned generated draft to fresh manual candidate, archive uncertainty and restart. Replay, false clear or borrowed principal fails. | Transport/Store only |
| PGW-T3a | 03 | Independent handle-join cases include identical duplicates, unordered digests,32 handles and conflicting first revisions. Real paired TLS/Store uses two disjoint passages of one owned source plus an owned fixture, verifies the one-source/one-fixture manual join and refuses wrong actual kind/first revision. Lost replies/restart retain unchanged originals; fixtures supply no successful seal. | Pure metadata and raw transport/Store |
| PGW-T4 | 01–04 | Actual installed signing/Keychain, original five-second lease, purpose/snapshot drift and late delivery. Reacquisition or usable late result fails. | Installed signed host |

No schema, dependency or sibling producer change is required. Pure vectors, raw-key
TLS fixtures and compilation do not satisfy signed host, live provider, confinement,
physical qualification or storage power-loss obligations.
