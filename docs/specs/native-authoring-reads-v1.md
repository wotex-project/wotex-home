# Native authoring object and original-receipt reads

Version: 0.1.2. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-T13/T14/T16/T17/T18; WOH.08 native task presentation;
WOH.15 H15-03. Implementation: typed SDK, selected driver and read panel implemented.
Evidence: [executed native/Store/archive checks](../provenance/native-authoring-reads-2026-10.md);
installed accessibility and signed paired delivery remain unqualified.

## Result and boundaries

An explicit Things-task read retrieves one actor-owned authoring object's verified
metadata, or one import/candidate/review original receipt. The typed SDK also
retains verified exact bytes for future explicit local consumption. Opening the
panel, changing inputs, switching tasks and startup make no request. Historical
receipt success is labelled inert history; complete review is not approval,
selection, provider export permission, current admission or physical evidence.

[Authoring operators](authoring-operators-v1.md) owns the implemented four read
routes, strict 65536-byte requests/1048576-byte responses and current
profile:manage actor privacy. [Candidate](authoring-candidates-v1.md) and
[review](authoring-reviews-v1.md) own historical receipt grammar. This successor
owns strict Swift decoding and selected-session presentation only. It adds no
route, schema, upload/mutation, pending-journal kind or producer algebra.

## Exact SDK inputs and outputs

Object input is one lower hex64 object digest. Original input is kind import,
candidate or review, positive signed-64 authority epoch and Home operation ID:
1..128 UTF-8 bytes, ASCII letters/digits/underscore/colon/dot/hyphen, first byte
letter or digit. No trimming, coercion, boolean-as-integer or invented default.
The panel epoch accepts only the canonical positive decimal spelling. Inputs
outside these bounds refuse locally before credential capture or transport.

Every successful envelope has exactly api_version 1, outcome ok and the owning
member. Missing has exactly api_version 1 and outcome not_found and yields nil;
errors keep the ordinary typed server error. Unknown/extra/null/duplicate fields,
fractional/overflow numeric fields and mismatched requested identities refuse
invalidResponse. The existing private peer, original five-second deadline,
strict duplicate/depth scanner and bearer redaction are inherited unchanged.

| Member | Closed shape and constraints |
| --- | --- |
| authoring_object | object, first_revision positive S64, payload_base64 |
| object summary | kind, object_digest, payload_sha256, payload_bytes |
| authoring_object_receipt | authority_epoch, operation_id, object, first_revision, revision; 1 ≤ first_revision ≤ revision |
| authoring_candidate_receipt | authority_epoch, operation_id, revision, input_sha256, basis_sha256, assessment_sha256, disposition, capture_status, bundle, source_review, fixture_status |
| authoring_review_receipt | authority_epoch, operation_id, revision, input_sha256, candidate_revision, basis_sha256, result_sha256, source_review, home_consumption, fixture_status, proposal_status; 1 ≤ candidate_revision < revision |

All digest fields are lower hex64. Object kinds/tags are source/1, draft/2,
bundle/3, fixture/4, contract/5, envelope/6, profile/7 and definition/8. Source,
draft, bundle and contract payloads are 1..262144 bytes; the other kinds
1..65536. Decode canonical unpadded URL-safe base64, at most 349526 ASCII bytes;
check actual length and payload SHA, then rebuild the exact frame
`WOHA || 0x01 || tag_u8 || length_u32be || payload_sha256_raw32 || payload` and
check object_digest equals SHA-256 of that frame and the requested digest.
Preserve bytes without UTF-8 decoding or normalization. Payload-bearing native
values redact reflective/debug descriptions. No automatic file output occurs.

Candidate disposition is compatible or invalid; capture_status not_supplied;
source_review not_assessed; fixture_status not_supplied or not_assessed. Bundle
is null or the exact four-field object summary above with kind bundle. It remains
inert object metadata and cannot be turned into an approved artifact by the SDK.
Review source_review is attributed/incomplete/ambiguous; home_consumption
not_assessed/matched; fixture_status not_supplied/not_assessed/passed/failed/
incomplete. proposal_status equals complete exactly for attributed+matched+
passed, otherwise incomplete. Preserve these independent outcomes.

## Selected-session and panel transitions

**NA-01 — Scope reads to the selected controller.** The shared controller driver
captures current saved selection/generation, reserves busy and uses the original
local metadata fence or current paired session. Read controller identity before
and after the typed request. Deployment/owner/authority/principal must match,
after revision must be ≥ before revision and ≥ any returned receipt/first
revision. Historical requested epochs may precede the current epoch; the SDK
must not substitute the current epoch. Existing native verifier correspondence,
paired trusted-clock/credential/peer/custody seals and final delivery-current
checks remain mandatory. Failed paired selection never invokes local custody.
Selection or generation change during I/O refuses publication.

**NA-02 — Present explicit inert history.** One shared model exposes object digest
and original kind/epoch/ID inputs, two explicit read actions and typed results.
At most one read is active. Shared app/session busy guards include this model.
An input change, session/access change or sleep/wake increments generation and
clears results; delayed results for an earlier generation never publish. A read
error clears previous results and offers explicit retry without a timer or
automatic request. A missing result is distinct from transport/refusal failure.
Display object kind/size/digests/first revision and each receipt's independent
outcomes, original identity and revision. Do not display payload/base64, bearer,
private paths or infer a current permission from a historical result. Wrap long
digests/IDs at 480/599/600/839/840-point widths and supply native field/action
accessibility labels. Session changes are refused while the read is active.

| Event | Result |
| --- | --- |
| Explicit valid read | Capture selected scope, clear prior result, publish only verified current delivery |
| Exact original status | Same historical receipt, no revision/upload/approval change |
| Not found | Visible missing history; no automatic mutation |
| Lost/refused reply | Read error; no outcome_unknown mutation claim |
| Input/session/access/wake change | Retire display and delayed publication; preserve server history |
| App restart | Empty presentation, no retained bytes or automatic API/custody request |

## Entry and acceptance

The typed authoring operators are implemented in `fc265c1`. Existing strict Swift
transport and selected controller driver are concrete prerequisites already in
the application. Signed paired installation remains unavailable when its owning
seals/clock are absent; fixtures cannot declare that prerequisite satisfied.
Native mutation/pending custody and passage presentation retain separate delivery
obligations; this read SDK is a dependency for those subsequent specifications.

| Case | Requirement | Executable stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NA-T1 | 01 | Independent framed peer: every kind at exact bounds, binary bytes, matching frame SHA, three receipt kinds, missing/error/lost, invalid base64/length/hash/tag, strict numeric/closed shapes and independent review-outcome combinations. Any accepted mismatch/coercion fails. | Native software |
| NA-T2 | 01 | Selected-driver before/after scope, old original epoch, owner/principal/epoch change, watermark regression, lost read and paired clock absence. Local fallback or publication outside captured scope fails. | Native software |
| NA-T3 | 02 | Delayed input/session/wake result, repeated click, failed read and startup; mounted metadata/history at responsive widths. Automatic requests, stale publication, payload display or clipped decision fields fail. | Native software/visible presentation |
| NA-T4 | 01/02 | Actual private Store/socket with independently imported source and archive-backed candidates/reviews; Swift values equal retained Authority history without a new revision. | Store/archive software |

Record actual compiler/commands/vectors and limits in provenance. Native build,
mounted rendering and unsigned private peers do not prove installed accessibility,
signed paired delivery, producer adoption or physical qualification.
