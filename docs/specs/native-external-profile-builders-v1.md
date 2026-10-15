# Pure native external-profile decision builders

Version: 0.1.3. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-03/09/H08-T9; WOH.15 H15-07/H15-T8;
WOH.18 H18-07/08/H18-T6/T8/T11/T12.
Implementation: pure builders and checked object-reference values implemented.
Evidence: [independent native/owning-codec and actual Store checks](../provenance/native-external-profile-builders-2026-10.md).
The [selected guided consumer](native-external-profile-guided-v1.md) is implemented
with [executed evidence](../provenance/native-external-profile-guided-2026-10.md).
Signed paired delivery remains a subsequent consumer.

## Result and boundary

Five explicit builders construct inspection, trust approve/revoke and target
select/revoke originals from operator choices and the
[typed guidance reads](native-external-guidance-reads-v1.md). They produce the
existing immutable [complete original](native-external-profile-originals-v1.md),
including its exact canonical bytes and SHA. No complete decision file is needed
by a subsequent guided consumer. This owns pure construction, not selected-driver
composition, UI, credential acquisition, current authorization or delivery.

Construction performs no IO, clock, randomness, operation-ID allocation, pending
publication, source checkout, approval or Store change. Callers supply an explicit
operation ID and current metadata. Metadata remains advisory: the selected driver
must reacquire custody, recheck actual authority/current basis, confirm separately
and retain the original before using the fixed SDK. A builder value is not an
authorization seal and cannot bypass those later guards.

The internal surface is NativeExternalProfileBuilder.inspection, approve,
revokeTrust, select and revokeTarget; each returns HomeExternalProfileOriginal.
NativeExternalProfileObjects owns checked object-reference construction and
canonical encode/decode. These names expose no network or mutation entry point.

## Inputs and checks shared by all builders

**NB-01.** Require one context body from the guidance SDK and a Home operation ID:
1–128 ASCII bytes, first alphanumeric then alphanumeric/dot/underscore/colon/hyphen.
Set authority_epoch and expected_revision from that context, preserving positive
S64 epoch and nonnegative S64 revision. Validate current principal with the same
ID grammar and policy0–1024 not greater than Store revision. Never silently alter
an explicit operation ID or repair counters. Malformed fields return
invalidProfileRequest; mismatched comparison bases or unusable state return
nativeGuardConflict. Errors contain no input payload or credential.

For each supplied guidance body require equal principal, epoch, Store revision
and policy generation. A catalogue must have equal epoch/revision/policy; it has
no principal field, so a selected consumer must obtain it under the same captured
credential and bracketed principal. Compare all current metadata again at actual
confirmation. A read revision alone does not fence a live reader/source change.

Trust and target builders require context maintenance=true with a positive begin
revision no greater than Store revision. Inspection does not require maintenance.
Entering/leaving maintenance remains a separate authorized operation. A required
reader must be available with lowerhex64 basis and null unavailable reason.
Metadata-only revokes do not require a reader, source owner or raw bytes.

**NB-02.** A checked object-reference value contains exactly envelope_ref,profile,
definitions and no reader/CAS fields. Envelope_ref is object_digest/first_revision;
profile and each definition are reference/object_ref, where reference is exactly
id/version/sha256 and object_ref has that same handle shape. Digests are lowerhex64,
first revisions positive S64. Reference URI uses the existing pinned Home URI
grammar (2–256 printable ASCII bytes, valid scheme/components); version is three
canonical decimal UInt16 components. Definitions number0–32, strictly ordered by
reference id/version with unique IDs and unique definition object digests. Reuse
the complete-original codec's object grammar, never normalize or sort user input.

Store this checked value as immutable canonical arrays
[envelope-handle,profile-row,definition-rows], at most16384 bytes, redacting
reflection. Handle is [digest,first_revision], row is
[[id,version,sha256],handle]. Decoding requires byte-for-byte canonical
reconstruction, no duplicate/unknown fields, coercion or trailing material.
When used with context, every first revision must be no greater than current
Store revision. This establishes bounded references only; Store still verifies
actor ownership, exact kind/first revision and private bytes.

## Exact construction

**NB-03 — Inspection.** Inputs: context, operation ID and checked objects. Require
available reader. Produce only authority_epoch,operation_id,expected_revision,
inspection; inspection is reader_basis_sha256 plus the three exact object fields.
Use the context's reader basis. This creates no inspection result or trust.

**NB-04 — Approval.** Inputs: context, operation ID, catalogue, one exact inspection
receipt and its freshly derived artifact. The receipt must be inspection kind;
its five-field identity must equal the artifact reference, including input/result
SHA. Preserve its historical epoch. Receipt revision must not exceed current
Store revision and its reader basis must equal the available context reader.
Artifact body shares context basis. Recheck its canonical manifest and digest
with the existing strict decoder; do not substitute a supplied label or digest.

Find at most one catalogue item with the artifact digest. An existing item's
id/version must equal the manifest. Refuse approved and author_unavailable state:
author unavailability does not change the retained approve action. Only a revoked
item may be reapproved from this new current inspection. Previous
trust revision is the matching item's revision or0 when absent. Produce action
approve, derived artifact_digest, that previous trust revision, current policy,
the exact inspection_ref and acknowledgement=operator_digest_approval. Approval
does not select a target or grant access.

**NB-05 — Trust withdrawal.** Inputs: context, operation ID, catalogue and explicit
artifact digest. Require exactly one matching item in approved or
author_unavailable state, with positive trust revision not greater than current
Store revision. Produce action revoke, that digest/current trust/current policy,
inspection_ref=null and acknowledgement=null. Refuse missing/already-revoked
items. No reader, artifact reconstruction or source is required.

**NB-06 — Target selection.** Inputs: context, operation ID, catalogue, explicit
target basis, current source catalogue plus an explicit source_ref, checked
objects and the freshly derived artifact for the chosen approved digest. Require
available reader and source owner; exactly one matching source row and catalogue
artifact. Item state is approved, its reader basis equals context reader, and
source row reader basis equals that same digest. Artifact body/target/source
catalogue share context basis. The manifest must match the catalogue id/version
and digest. Checked envelope/profile/definition object digests and references
match the manifest's roles and complete ordered object set; first revisions still
come from checked imports, not from manifest payload digests.

Target may be absent, selected or revoked. A replacement may choose a different
approved artifact; the target contract separately requires the same private
physical stable_id, which this public metadata cannot establish. Store checks
that identity against actual host-held source custody. Require exact target ID
and current selection/resource counters; do not infer an absent target from a
missing catalogue item or infer physical continuity from an artifact digest.
Produce action select with those counters, current artifact trust/policy,
the explicitly chosen source_ref, source catalogue owner epoch, source selection
SHA, checked objects and acknowledgement=operator_external_selection. Selection
grants no access and replacement withdraws existing grants through Store.

**NB-07 — Target withdrawal.** Inputs: context, operation ID, catalogue and target
basis. Require selected target with retained artifact and exactly one matching
catalogue item whose current trust revision equals the target basis's trust
revision. Use target selection/resource counters and catalogue's current policy.
Produce action revoke; source_ref,source_owner_epoch,
source_selection_sha256,objects,acknowledgement are all explicit null. Missing or
already-revoked target refuses. No current reader/source/manifest is required.

All five results pass the existing complete-original encoder and its
inspection/trust/target16384/4096/32768-byte ceilings. No receipt is synthesized,
no current revision is incremented and no mutable native map is retained. Quotas,
private physical continuity, raw-byte ownership and current authorization remain
Store admission checks; these builders compare only explicitly exposed metadata.

## Failure, compatibility and acceptance

No state survives restart; retain the constructed original only through the
owning pending journal after separate review. A changed input or basis requires
a new explicit construction/review. Never silently regenerate an operation ID or
CAS after refusal. Complete-file entry, original encodings and receipt recovery
remain byte-compatible. Native typed Int64 inputs use their exact signed value;
this adds no JSON boolean/float/string/overflow coercion and changes no wire bytes. Signed/paired and physical requirements are unchanged.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NB-T1 | 01–07 | Both frozen quantity families and all five actions compare full canonical originals and SHA with independently written expectations and actual Elixir owning codecs. Self-generated expected bytes, changed nulls or namespace fails. | Pure native/independent parity |
| NB-T2 | 01/02 | Object-reference canonical round trips,32-definition/boundary cases, unsorted/duplicate refs, wrong types/versions/URI/digests, future import revisions and overflow. Coercion, repair or unsafe retained reflection fails. | Pure native |
| NB-T3 | 03–07 | Changed principal/epoch/revision/policy/reader, unavailable owner, wrong chosen source, wrong artifact/object closure, stale trust/target, already-revoked/approved and missing maintenance. A constructed unusable comparison basis fails. | Pure native adverse fixtures |
| NB-T4 | 01–07 | Builder outputs consumed by actual Store/Authority and compared to their actor-owned originals; no request or publication occurs during construction. Fixture-only schema success does not establish this level. | Native/actual local software |

These cases establish pure construction and owning consumption only. Selected
confirmation/lifetime races, guided layout/accessibility, installed signing,
actual protocol publishers and physical qualification remain separate gates.

## Reviewed sources

This contract was checked against ExternalTrustWriter.current_basis/3 and its
retained-action guards, ExternalTargets and ExternalTargetPreparation at Home
runtime f909889. [Target ownership](external-target-selections-v1.md) preserves
private stable identity across artifact replacement; [trust](external-trust-v1.md)
keeps author availability distinct from the immutable latest approve/revoke action.
The current native guidance/original contracts supply the exact consumed inputs
and encodings. No producer API, dependency update or schema migration is required.
