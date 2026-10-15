# Fixed native external-profile mutation and recovery

Version: 0.1.0. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-03/09 and H08-T1/T5/T9; WOH.15 H15-07/H15-T8;
WOH.18 H18-07/08 and H18-T6/T8/T11/T12.
Implementation: planned. Evidence: missing.

## Result and boundaries

An explicit native decision sends or recovers exactly one retained external
inspection, trust or target original. Lost replies retain that identity; lookup
does not replay, and retry checks history before sending the same complete input.
This owns the fixed typed SDK and ordinary local pending recovery. Selected first
confirmations and signed paired consumers remain separate composition work; paired
metadata cannot authorize this local runner. External target selection is distinct
from controller access grants and grants no permission to read a target.

Use [complete originals](native-external-profile-originals-v1.md),
[typed original reads](native-external-profile-reads-v1.md),
[v9 private custody](native-pending-external-profiles-v9.md) and unchanged
[closed operator routes](external-profile-operators-v1.md). Authority/Store own
current grants, actor scoping, maintenance, epoch/CAS, immutable imported bytes,
reader/source checkout, trust/policy and transaction/invalidation effects.
Inspection establishes no approval; approval establishes no selection;
selection establishes no grant, fresh observation or physical qualification.

## Inputs and closed delivery

**NXS-01.** SDK input is one checked immutable complete original, a 32-byte
credential, explicit local socket, expected controller identity and lookup/retry
intent. Expected identity has lower hex64 deployment/owner, positive signed-64
epoch, Home principal ID and nonnegative signed-64 revision. It is a comparison
basis, not a signing seal or credential. Revalidate it and the original before
I/O. Never accept caller-authored operation names, wrapper members, replacement
IDs/revisions, raw source/capture objects or a successful runner callback.

Every delivery fetches authenticated identity first. Require the same deployment,
owner, active epoch and principal as the expected identity, with revision at least
the expected watermark. Then read the exact kind's original status with the
original epoch/operation. Verify a found receipt against the entire original.
Lookup ends there. Retry with a found receipt also ends there, without mutation.
Only retry plus exact not_found may send one fixed mutation, and only if original
epoch still equals this authenticated active epoch. A missing original from an
older epoch cannot become a new request. Never rebase CAS or allocate a new ID.

| Original kind | Mutation operation | Sole additional member |
| --- | --- | --- |
| inspection | external_profile_inspect | inspection: complete native original |
| trust | external_trust_change | change: complete native original |
| target | external_target_change | change: complete native original |

The transport builds only those wrappers and preflights its complete JSON request
against the existing 65536-byte body limit before opening a socket. Four-byte
framing, at most1048576 response bytes, depth/duplicate/type rules, private socket
and same-user peer checks remain the existing LocalHealthClient boundary. There
is no chunk upload, source recapture, provider call, implicit fallback or polling.
Each exchange retains its five-second local bound. Delivery has at most four
exchanges (identity/status/optional mutation/identity), at most20 seconds of network
waiting plus bounded decoding. A future paired owner must fit these exchanges in
its original shorter lease; this SDK creates or renews no lease.

After successful found/missing handling, fetch identity again. Require the same
authority/principal, nonregressing revision and watermark at least the receipt
revision. An unrelated concurrent commit may increase the watermark. Identity
substitution at the first read refuses before domain work. Substitution/regression
after a possible send leaves delivery uncertain. A found historical receipt does
not establish that its approval or target selection is current.

## Complete-original receipt correspondence

**NXS-02.** Decode the exact owning reply through the implemented typed reader:
closed api_version/outcome/member, exact fields, signed integers without boolean/
float coercion, lower hex digests and owning generation/action invariants. A found
receipt must match kind, original epoch, operation and SHA of the complete canonical
input. Expected revision must leave room for one increment; receipt revision is
exactly expected_revision+1. Apply these further checks, on both status and mutation:

- Inspection reader_basis_sha256 equals the original inspection reader basis.
  Its result_sha256, capture_digest and envelope_sha256 are checked opaque output
  identities. The envelope hash is a raw document hash, not an object frame digest;
  do not compare those different namespaces or claim to reconstruct the result.
- Trust action/artifact_digest match input. previous_trust_revision equals
  expected_trust_revision. policy_generation equals expected_policy_generation+1
  with checked arithmetic. Approve/revoke basis nullability and first-approval/
  generation relations remain the typed reader's rules. The approval basis and
  outcome hash are retained output identities, not a reconstructed inspection.
- Target action/target_id/artifact_digest match input; previous_selection_revision,
  trust_revision and policy_generation equal their expected input counters.
  If expected selection revision is zero, require expected resource revision zero
  and receipt resource revision zero; otherwise resource equals expected resource+1
  with checked arithmetic. Select's source_selection_sha256 equals input and binding
  revision equals receipt revision. Revoke retains its checked historical source
  identity/binding; its input deliberately contains no source to reconstruct.

Do not infer a target's current generation from an old receipt or compare its
post-transaction global watermark to receipt revision for equality: target and
trust invalidations may append later events in the same transaction. Full original
SHA correspondence never substitutes for these derivable field checks. Opaque
output hashes are not proofs of current source presence or physical behavior.

## Failure and pending recovery

**NXS-03.** Before mutation, malformed input, identity mismatch, malformed status,
missing old-epoch original or bounded owning refusal is a definite refusal of this
attempt. Preserve payload-free error families; error reasons are at most128 ASCII
bytes, initial lowercase letter, then lowercase/digit/underscore. Malformed peer
reasons never enter UI/log text.

Once the mutation exchange is invoked, transport loss, not_found, malformed reply,
receipt mismatch or failure of the final identity check is outcomeUnknown. Preserve
the pending original and direct the operator to exact lookup. A well-formed owning
error remains its definite bounded refusal except outcome_unknown, which is unknown.
No error automatically removes an existing pending record. No retry happens in a
catch block; the next explicit retry again starts with original status.

**NXS-04.** Ordinary manual/native operator pending entries enable lookup, retry
and separately confirmed acknowledgeAbsent. Paired entries keep all actions disabled
until the closed signed consumer exists. CancelReview/acknowledgeUnknown are never
external actions. Local first capture now uses the existing authenticated coordinator:
retain complete input under v9 file CAS before any send, remember uncertainty and
refuse new work for an occupied deployment/owner/epoch. Caller must pass the actual
authenticated expected identity into this SDK, not rebuild it from editable UI.

Recovery opens only existing recorded custody, checks its verifier and exact
deployment/owner/epoch/principal, and passes that authenticated identity to the
fixed SDK. Paired custody never enters ordinary recovery. Found verified receipts
resolve only that original through full file CAS; missing lookup/retry remains
retained. AcknowledgeAbsent performs only exact lookup and final identity validation.
If missing, resolve client metadata with explicit text that a request/result may
arrive later and no operation, cancellation or rollback was sent. If found, resolve
as the verified original. Failure retains input/custody and requires explicit
recovery; publication failure cannot erase it or permit a new operation.

Startup/display performs no request. No Store schema, dependency, producer API,
permission expansion, source publisher or dispatch-flag change is required.

## Acceptance and implementation entry

Freeze independent receipt correspondence from existing owning two-family and
multichannel fixtures before runtime implementation; include structurally valid
receipts whose original-derived fields disagree, S64 arithmetic edges and opaque
output identities. Native code under test cannot allocate expected receipt values.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NXS-T1 | 01/02 | Independent accepted/mismatching originals and receipts for all kinds/actions/families, exact request wrappers, fields/hash/revision/counter boundaries. Wrong namespace comparison, unchecked field, coercion or widened wrapper fails. | Pure/native framed peer |
| NXS-T2 | 01/03 | Status-first found/missing/retry, permission refusal, malformed error, owner/principal/epoch/revision races, lost/malformed mutation/final identity. Mutation on found status, automatic replay, cleared uncertainty or private diagnostics fails. | Actual framed socket |
| NXS-T3 | 01–04 | Real SQLite/UDS both-family import/inspection/approval/selection/revocation, lost reply and separate-process recovery, current grant withdrawal, stale CAS/source, failed private publication, explicit absent acknowledgement. Lost original, extra mutation, revived source or unchanged-grant assumption fails. | Store/private file/process |

Record actual source/toolchain/fixture/commands/results. These checks establish
software delivery/recovery only; installed signing, Keychain, physical dispatch,
power-loss survival and source/device qualification require their own evidence.
