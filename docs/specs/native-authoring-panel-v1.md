# Native authoring first-decision panel

Version: 0.1.2. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 H08-09/H08-T9; WOH.18 H18-T13/T14/T16/T17/T18;
WOH.15 H15-03. Implementation: planned. Evidence: missing.

## Result and scope

An explicit Things-task panel reviews one complete local import/candidate/review
original, publishes its v6 custody and submits it through the implemented native
SDK. This first delivery accepts independently authored native original files;
it does not invent a profile/draft/provider, rewrite CAS, derive source truth or
enable approval/selection. The original-purpose Activity lookup/retry remains
the recovery path after restart or uncertain submission.

[Complete originals](native-authoring-originals-v1.md) owns exact closed fields,
canonical bytes and identity; [v6 custody](native-pending-custody-v6.md) owns full
original/import payload publication; [submission/recovery](native-authoring-mutations-v1.md)
owns unchanged dispatch and receipt correspondence. These are implemented concrete
dependencies. First submission is local-only. Paired selection must refuse before
local credential/file/API work and never fall back to the Mac's authority.

## Inputs, review and selected scope

Kind is import/candidate/review. An explicit file picker selects an absolute
original-file URL at most 1024 UTF-8 path bytes. Import additionally selects a
payload URL with the same path bound; other kinds require no payload. Kind/path
changes clear the prepared review and confirmation without a request. Opening
the panel, startup, file selection and task changes acquire no credential and
send no API request. Prepare is explicit; Submit requires a separate confirmation.

**AP-01 — Preserve private file bytes.** Read only a same-user 0600 regular file
with one hard link, no final/ancestor symlink, an original O_NOFOLLOW descriptor
and bounded original/native JSON/payload size. Check descriptor/name identity,
mode/owner/link/size and modification/change metadata before and after reading.
No file is rewritten, chmodded, normalized or logged. Original JSON ceilings are
4096/65536/262144 for import/candidate/review; the native codec separately enforces
canonical 4096/32768/131072. Payload is nonempty and at most its kind's owning
ceiling. Validate full input/canonical SHA and import raw/frame correspondence
before retaining a prepared value. File mutation/link/mode/oversize failures clear
the review and refuse without submission.

**AP-02 — Bind a reviewed decision.** The shared selected driver reserves one
local metadata/generation fence, captures existing current credential/reference,
checks original native verifier correspondence and reads authenticated controller
identity before/after the existing profile:manage catalogue. Owner/authority/
principal must match, catalogue epoch matches identity and all three Store
watermarks must be equal. An intervening write requires a new Prepare; current
permission cannot be inferred across a later watermark. It does not fetch a
producer contract or substitute its own limits.
Original epoch must equal selected current epoch and expected_revision must equal
the final checked Store watermark; a stale file refuses and is never edited.
Prepared state retains the exact original/payload, capture and selection/generation
basis. No current permission is inferred from a historical receipt or saved label.

Show kind, original epoch/ID/CAS, selected principal/owner, canonical SHA, import
kind/size/object/raw SHA, or candidate contract SHA and source/fixture counts, or
review candidate revision/mode/evidence/unresolved counts. Show that import/
assessment/review is inert and approval/selection are separate. Never show raw
payload, complete original JSON, instructions/source locators, bearer or private
path. The file basename may identify the user's selection. Long IDs/hashes wrap
at 480/599/600/839/840-point widths; fields/actions have native accessibility labels.

## Publication, dispatch and outcomes

**AP-03 — Publish before first dispatch.** Submit requires the same reviewed kind/
paths, checked confirmation, current local selection/generation and idle shared
controller/journal. Recheck fresh identity, credential/reference and unchanged
prepared epoch/CAS before publication; no silent reprepare. Begin the complete
authoring original through the shared coordinator with the exact expected capture
and controller, then verify its full private publication/current original and
selection fence before any SDK mutation. Re-read files only for a new Prepare;
Submit uses the already verified immutable reviewed bytes.

Publish success is distinct from Store mutation success. Publication failure or
uncertainty retains the coordinator's same original and requires reload; no SDK
mutation follows. A scoped matching receipt permits whole-file CAS resolution
before reporting success. Failed resolution retains uncertainty and its original.
The first-decision view receives only verified typed metadata/outcomes; it does
not optimistically import/approve/select or modify Things/reports.

During this initial submission only, an authenticated closed server refusal from
the following fixed set may resolve the same newly published local record under
the existing full-file CAS: permission_denied, unauthorized, invalid_credential,
stale_authority_epoch, resnapshot_required, maintenance_active, authoring_unavailable,
profiles_producer_unavailable, authoring_limit, authoring_object_capacity,
authoring_candidate_capacity, authoring_review_capacity, stale_authoring_reference,
stale_authoring_basis, revision_exhausted, authoring_operation_conflict,
invalid_authoring_import, invalid_authoring_candidate and invalid_authoring_review. This is a definite
refusal of that initial attempt; it is not a rollback claim for uncertain work.
Unknown reasons, transfer failure, outcomeUnknown, malformed response, changed
scope/custody or a later recovery refusal retain the original. Existing recovery
rules continue to retain all later refused originals; initial-refusal cleanup
must not be reused by lookup/retry or inferred from missing status.

At most one prepare/submit is active. Shared app busy/session guards include this
model. Input/session/access/sleep/wake change retires prepared display and delayed
publication. If the original is already durably retained, display retirement does
not erase it or cancel an in-flight Store call; Activity recovery keeps its same
recorded owner. Session change remains refused while work is active. No timer,
automatic request, new durable ID or AI/provider export is introduced.

## Acceptance

| Case | Requirement | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| AP-T1 | 01/02 | Private regular/link/ancestor/mode/owner/hard-link/size and changed descriptor/name checks; three kinds, full binary and large UTF-8 review. Unsafe read, normalization, credential capture on paired selection or CAS editing fails. | Native software |
| AP-T2 | 02/03 | Delayed file/identity/input/session/wake and changed principal/owner/epoch/revision/capture; explicit confirmation and duplicate clicks. Stale review, fallback or dispatch before full publication fails. | Native software/Store |
| AP-T3 | 03 | Real private Store/archive: all three initial operations, lost committed replies and Activity recovery, definite first refusal versus later refusal, failed publication/resolution/reload and separate process restart. Premature success/removal or changed original fails. | Native/Store software |
| AP-T4 | 01–03 | Mounted review/success/uncertain/error presentation at responsive widths; no automatic startup/file-pick request and no private payload display. Clipped decision fields or implicit approval fails. | Native visible software |

Record exact compiler/commands/cases and limits. Installed accessibility/signing,
paired authoring, ergonomic draft construction, host meaning/source installation,
producer adoption, provider handoff and physical qualification remain separate.
