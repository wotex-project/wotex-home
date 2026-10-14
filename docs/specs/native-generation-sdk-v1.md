# Native generation SDK and original-purpose recovery

Version: 0.1.1. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-09/H08-T9; WOH.18 H18A-02/04/05 and H18-T15/T16/T17;
WOH.15 H15-03/07 and H15-T8. Implementation: planned. Evidence: missing.

## Result, dependencies and scope

A native SDK reads exact actor-scoped generation options, submits complete
preparation/attempt originals, reads their status and cancels a preparation.
The original-purpose runner can recover a published local v7 original without
changing its bytes or controller. No automatic repair, provider fallback,
source export from the client, new first-submission UI or paired generation
custody is introduced. Store remains the owner of export, CAS, source integrity,
deadlines, model workers and settlement. Compatible mechanics remains inert:
source review, fixture qualification, admission and effects are separate.

[Generation operators](generation-operators-v1.md) owns the six exact requests,
closed response members and current actor permission. [Native originals](native-generation-originals-v1.md)
owns complete original/receipt correspondence. [v7 pending custody](native-pending-generation-v7.md)
owns publication before mutation and its existing-only local custody. This entry
owns typed decoding, delivery uncertainty and recovery decision only. The same
api_version 1 framing, 65536-byte request/1048576-byte response, duplicate/depth-16
scanner, five-second exchanges, same-user private endpoint, current credential
lease and selected-session checks apply. No route, dependency or SQL schema changes.

## Options and typed historical values

**NGS-01 — Check options without inventing readiness.** Decode exactly the options
wrapper and format/principal_id/authority_epoch/store_revision/policies metadata
from the operator owner. Epoch is positive S64, revision nonnegative S64, principal
uses the 1–128 ASCII Home ID grammar. Policies are 0–32, sorted uniquely by
provider.id. Each row has exactly provider,provider_sha256,policy_sha256,
remote_export,passages,examples,limits,provider_present. Provider has exactly
id,model_id,adapter_sha256,locality; IDs use the Home grammar, digests are lower
hex64, locality local/remote and both flags are actual booleans. Local provider
requires remote_export false. Ranges/examples/six limits have the exact native
preparation projection grammar and ceilings; selections remain handles, not bytes.

Reconstruct provider SHA as SHA256 of `wotex-home.generation-provider@1` plus LF
and canonical `[ID,MODEL_ID,ADAPTER_SHA,LOCALITY]`. Reconstruct policy SHA as SHA256
of `wotex-home.generation-policy@1` plus LF and canonical
`[PRINCIPAL,PROVIDER_ARRAY,REMOTE,PASSAGES,EXAMPLES,LIMITS]`, using the owning
projection array ordering. Reject digest drift, unknown fields, wrong scalars,
unsorted/duplicate providers and inconsistent reference revisions. These hashes
describe host metadata; provider_present is a snapshot, not current model
authentication, capacity, source custody or export authorization. Expose checked
immutable Sendable options with revalidated native fields, redacting reflection.
Internal native storage may use sorted-key JSON and has no external digest identity.

**NGS-02 — Preserve full inert assessment and result.** A generation result native
map is exactly disposition,reason,draft_ref,bundle_ref,assessment. Its canonical
array is those five fields, at most 131072 bytes; references are null or exact
object_digest/first_revision handles, encoded `[DIGEST,POSITIVE_S64]`.
Disposition is candidate/unavailable/invalid_response/unknown/deadline_expired/
cancelled/withdrawn/capacity. Candidate requires null reason, draft handle and
complete checked assessment; bundle handle exists exactly when assessment bundle
SHA exists. Noncandidate has null handles/assessment. Only withdrawn has nonnull
reason, exactly actor/epoch/maintenance/policy/basis/source/store.

The owning AuthoringCandidate assessment has exactly format,basis_sha256,
draft_sha256,bundle_sha256,phase,disposition,capture_status,report,home_consumption,
source_review,fixture_status and canonicalizes to that eleven-slot array, at most
65536 bytes. Format is wotex-home.authoring-mechanics@1; basis/draft are lower
hex64, bundle null/lower hex64. Phase finalize means invalid and null bundle;
phase validate requires bundle. Disposition compatible/invalid; capture/fixture
not_supplied and consumption/source_review not_assessed are mandatory.

Report is exactly format wotex.profile.validation-report@1,contract_sha256,
candidate_sha256,disposition,capture_status,diagnostics,truncated, encoded in
that seven-slot order. Contract SHA is lower hex64; candidate SHA equals bundle
SHA when present, otherwise draft SHA. Disposition equals assessment; capture
not_supplied; truncated is boolean. Diagnostics are 0–64 exact phase,code,
instance_path,rule_id,repair maps, encoded in that five-slot order. Phase is
syntax/shape/semantic/binding/capture. Code/rule/repair are 1–128 UTF-8 bytes,
instance path empty or 1–512; all forbid Unicode Cc/Cf. Compatible requires empty
diagnostics and false truncated; invalid requires nonempty diagnostics. Preserve
diagnostic order and text rather than normalize, evaluate or infer attribution.

Canonical result/assessment decode accepts ordered arrays only, reencodes for
exact equality and refuses whitespace/escape/number aliases, extra members,
UTF-8 errors and scalar coercion. Bounds precede parse. Closed fixed shapes keep
depth at most eight, nodes below4096, collections at most256 and strings at most
4096; no arbitrary nested report body is admitted. Native map encode enforces
the same bounds. Checked result/assessment values are immutable Sendable with
private canonical bytes and safe metadata; native field access revalidates them.
Neither object handles nor SHA assert current ownership or source truth.

## Status, delivery and cancellation

**NGS-03 — Match the exact original.** Read status using positive S64 epoch and
Home ID, or the revalidated complete original. Preparation status is exactly
original,state,cancellation_revision. Its receipt matches requested scope; state
prepared/expired/retired/cancelled. Cancelled has positive S64 cancellation revision
above original revision; all other states require null. Cancel success must be
cancelled. Attempt status is exactly original,state,result,result_revision. Its
receipt matches scope; null result/revision permits running/unknown/cancelled.
Nonnull result is the checked codec above, result revision is positive S64 above
reservation revision and state equals result disposition. When a complete original
is supplied, enforce its full receipt correspondence too, including input SHA,
next revision without overflow and kind-specific provider/policy/preparation/index.

Success envelopes have exactly api_version,outcome and the named owner member;
missing has exactly api_version/outcome not_found and yields nil on existing-only
reads. Error has exactly api_version/outcome/reason, 1–128 ASCII characters matching
`[a-z][a-z0-9_]*`; malformed reasons refuse before display. Strict response
validation preserves errors as codes and prints no unvalidated body/diagnostic.

Submit forwards one unchanged complete native original to prepare/start, with
no upload, retry or policy substitution. Validate input before transport. A valid
matching reservation returns reservation only. Missing/malformed/lost reply,
transport failure or outcome_unknown after submission throws typed outcomeUnknown;
a well-formed definite refusal remains the exact server error. No claim of rollback,
remote stop or renewed deadline. Read/status failures are ordinary read errors.
Cancellation revalidates a complete preparation original and sends its epoch/ID
once; enforce cancelled status and matching receipt. Cancellation uncertainty uses
the same typed error and retains caller identity for an explicit later status read.

Delivery for original recovery first reads exact status. Existing history never
causes another mutation, regardless of current availability. Missing lookup retains
the original. Missing status on explicit retry allows exactly one unchanged submit,
then one status read; a missing/lost final status retains delivery uncertainty.
No automatic attempt number, predecessor, feedback export or new operation ID.

## Original-purpose runner

**NGS-04 — Publish and retain until knowledge permits resolution.** Enable only
local v7 lookup/retry using existing manual/native Operator custody and exact
verifier/controller/principal. Retain the coordinator's complete publication,
reload and whole-file CAS. Recheck authenticated original controller before and
after delivery; after revision cannot decrease and must cover the confirmed
reservation/cancellation/settlement revision. Wrong custody/controller, refused,
malformed, uncertain or missing result retains the original. Paired custody and
cancelReview refuse before transport. New UI submission remains a later contract.

A verified preparation status resolves its pending mutation, labelled original
preparation and current state; it does not mean export occurred. A running attempt
with null result remains pending so restart can explicitly query its same identity.
Null-result unknown stays pending: Store can observe a dead worker before
processing its already queued result, so unknown is a knowledge snapshot rather
than a stable absence of future settlement. Lookup/retry never clear it or cause
another handoff. Null-result cancelled can resolve with a cancelled label: the
committed preparation cancellation prevents subsequent candidate retention, but
cannot prove a remote model stopped.

The separate local acknowledgeUnknown action is available only for a local
attempt original. A confirmation dialog explains that clearing its pending record
accepts uncertainty and a result may appear later. Perform existing-only status,
repeat original/controller/custody/revision checks and use whole-file CAS before
removal. Unknown with null result can then resolve with an explicit acknowledgement
label; missing/refused/running retains, and a newly settled result resolves with
its actual disposition. This action sends no mutation, retry, cancellation or
provider request and does not authorize another attempt. It is not a journal
phase, so v7 encoding stays unchanged. Other categories/preparations/paired custody
refuse this action before transport. A checked settled result resolves
with its disposition, keeping candidate mechanics independent of approval/control.
The panel exposes original lookup/retry, confirmed unknown acknowledgement and
inert recovery labels; no polling, new attempt, cancellation button or edited-original substitution.

## Acceptance and implementation entry

Before code, allocate independent Python options/status/assessment/result vectors
from the frozen two-family operation/policy/result corpora, including every failure
and null/settled status. The Elixir owners cross-check frozen expectations but do
not replace them with Swift-computed valid bytes. Use fake framed peers for malformed
and dropped replies and actual Store/socket/independent native processes for parity.

| Case | Requirements | Setup, observation and falsifier | Level |
| --- | --- | --- | --- |
| NGS-T1 | 01–03 | Independent both-family options/results/assessments/status, Unicode diagnostics, every disposition and null state; exact bytes/hashes/typed fields. Drift, unchecked report or metadata-as-authority fails. | Native software |
| NGS-T2 | 01–03 | Unknown/duplicate/missing/scalar/UTF-8/bounds, policy hash/order/reference drift, diagnostic/phase/report/result contradiction, scope/receipt/revision and next-revision overflow. Any malformed success or printed raw body fails. | Native software |
| NGS-T3 | 03/04 | Lost/malformed prepare/start/cancel, exact status-before-retry, missing and definite refusal, running/unknown retained, confirmed unknown acknowledgement, cancelled labelled, queued-result race, settled result, stale controller/custody/publication and restart. Automatic second handoff, changed original, premature pending removal or false completion fails. | Framed/private-file/native |
| NGS-T4 | 01–04 | Actual SQLite/socket/native process options/prepare/start/status/cancel for both families, scripted provider and inert candidate/failure, original retry and lost reply. Extra revision/call/export, approval or unchanged source without current guards fails. | Store/socket/process |

No signed app, paired generation, live account/model, local confinement, power-loss
or physical qualification follows from these software checks. First-submission
editing/confirmation and installed delivery remain separate obligations.
