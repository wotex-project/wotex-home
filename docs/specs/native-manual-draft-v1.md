# Native manual draft import and assessment preparation

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 H08-T1/T2/T5 and WOH.18 H18-09/H18-T13/T14/T16/T17.
Implementation: planned. Evidence: missing.

## Result and preserved boundaries

An operator selects a private manually written WPF draft file, prepares and
confirms its inert import, then separately prepares and confirms assessment of
the verified owned draft. Home constructs complete original operations from
the current installed contract and authority basis. The operator no longer
needs to write operation JSON or invent a current revision, digest or limit.
The existing complete-original file workflow remains supported.

This first ergonomic slice owns file-based manual draft import and a separate
manual candidate decision, not a mapping editor, source/fixture review editor,
generator, approval, target selection, protocol publisher or effect. Structural
compatibility is a producer assessment; it does not prove that a selector/unit
matches hardware or that an author has reviewed sources. No semantic/model enum
or automatic repair/finalization/submission is added to the native client.

The [native contract read](native-authoring-contract-v1.md) supplies exact checked
grammar and typed limits. [Original codec](native-authoring-originals-v1.md),
[v6 pending custody](native-pending-custody-v6.md),
[submission/recovery](native-authoring-mutations-v1.md) and
[first-decision publication](native-authoring-panel-v1.md) retain exact input,
capture and private-file CAS before mutation. Store continues to own actor
history, epoch/revision checks, byte quotas, producer assessment and receipts.

## Inputs and prepared originals

**MD-01 — Import a selected draft.** Explicit prepare takes one private absolute
file URL, with the existing NativeAuthoringFiles checks: no symlink ancestors or
leaf, regular current-user-owned 0600 file, one link, stable descriptor/name/
size/inode/time witnesses, nonempty bytes <=262144. No URL fetch or file scan.
Preserve exact payload bytes; invalid JSON may be imported as an inert draft
and later receive an invalid assessment. No Unicode normalization, newline
conversion, schema evaluation or automatic draft repair occurs.

Require selected local controller before file/capture I/O; a paired selection
refuses unavailable with no local fallback. Obtain one current credential
capture, before identity, authenticated installed contract export and after
identity. Require same owner/principal/epoch/installation, the same local native
capture reference and exact equality of all three revision watermarks. Require
current profile:manage through export. Source/association generation and local
metadata fences must remain current before returning a prepared decision.

Construct the same complete import original accepted by the existing codec:
authority_epoch and expected_revision from the stable read; operation_id is a
fresh Home ID authoring:draft:<lowercase UUID>; object contains exactly kind
draft, payload_bytes, raw payload_sha256 and tagged object_digest. The tagged
digest hashes the exact WOHA version-one draft frame (tag two) from the owning
codec, including original payload length and bytes. Independently validate the
constructed original/payload through NativePendingAuthoring.checked. A prepared
decision retains these immutable bytes/capture/scope privately and exposes only
file basename, operation, kind, byte count, digests and current basis metadata.
Prepare publishes no original, file, import, revision or producer assessment.

**MD-02 — Assess a verified owned draft.** Assessment prepare accepts the checked
import receipt retained by this workflow and an explicit instruction string.
Receipt must be import kind with draft object summary and positive first_revision.
Bind it to the same retained principal/authority/owner/installation selection
under which the import was verified. A new session, authority succession or
unknown import outcome cannot silently reuse it. The draft handle is exactly
object_digest and first_revision from the actual receipt, including a historical
first_revision on exact existing byte ownership; never infer it as import CAS+1.

Instruction is 0..4096 UTF-8 bytes, no Unicode Cc characters except newline/tab,
under the complete original codec's rules. New prepare takes a fresh stable
local credential/before/export/after read as above; the current revision may
advance after import. Construct one manual candidate original with fresh Home
operation ID authoring:assess:<lowercase UUID>, current epoch/revision,
contract_digest from the export's verified WPF identity, the verified draft
handle, source_refs [], fixture_refs [], exact instruction and the complete
typed exported limits. Empty references explicitly mean no supplied sources or
fixtures; they make no review/completeness claim. Revalidate through the existing
codec; no caller-authored limit, contract, epoch or digest is substituted.

## Confirmation, publication and workflow state

**MD-03.** Each prepared import/assessment requires its own explicit unchecked
confirmation toggle and separate submit click. Use the existing driver submit
path: fresh same-capture/current identity/CAS and selection checks, full original
publication under v6 private custody before any upload or Store call, matched
receipt and safe CAS resolution before presenting success. Never auto-assess
after import or auto-review/approve/select after assessment. A second click
while busy makes no second operation. Preparation after changed inputs creates
a new original and requires a new confirmation.

The workflow states are idle, import_prepared, import_submitting, draft_owned,
assessment_prepared, assessment_submitting and unconfirmed. Only a verified
import receipt enters draft_owned. A known initial refusal follows the existing
first-decision original cleanup; unknown response, malformed receipt, lost reply,
scope loss after publication or unsafe publication retains the published original
and enters unconfirmed. Existing Activity recovery owns resolution. An
unconfirmed import cannot prepare assessment. Later successful recovery does
not automatically start a candidate; the operator makes a separate decision.

Changing the draft file invalidates the prepared import/assessment and its local
owned-draft handoff. Changing instruction invalidates only a prepared assessment;
it cannot change a published original. Session/access/host-wake invalidation and
cancellation retire prepared values, confirmations and local handoff context.
Late results cannot recreate them. Already published originals and Store
history remain under their owning recovery contracts. Do not refund a quota or
delete history on native UI invalidation.

**MD-04 — Native presentation.** Add an explicit manual-draft entry to the
existing authoring surface, sharing its busy/access/session gates and pending
coordinator. Show the chosen basename, preparation metadata, owned draft handle
and checked structural disposition/capture status. Instruction input is explicit;
no source document or draft payload is rendered, logged or sent to a generator.
Use readable wrapping at 480, 600, 720, 980 and 1320 pixel fixture widths. Mount,
focus, session reload and wake initiate no file read, export or mutation.
Import, assessment, source/fixture review, approval and target selection stay
separate visible decisions. Native reflection omits bytes, instruction, capture
and file path. Producer/install absence shows typed unavailable; it never chooses
a built-in template, relaxed v1 parser or local validator.

## Compatibility and acceptance

No Store schema, public mutation route, v6 root grammar, producer API or physical
dispatch flag changes. Manual mapping content remains consumer-owned. Public
templates/editor/generation and signed paired mutation remain separate successors.

| Case | Requirements | Setup and falsifier | Level |
| --- | --- | --- | --- |
| MD-T1 | 01/02 | Two independent quantity drafts: private bytes/tagged digest/current import original and separately current candidate original match independent Store/codec oracles, including reused owned bytes/first_revision. Invented revision/limit/handle, canonicalized payload or source/model branch fails. | Native/actual Store |
| MD-T2 | 01–03 | Paired selection before file/capture, malformed/private-file bounds, current identity/permission/CAS/capture/contract drift, input/session/wake/cancel while delayed. Any fallback, stale prepared delivery or confirmation reuse fails. | Native scoped fixtures |
| MD-T3 | 03 | Actual published v6 original precedes first upload/candidate call; lost replies and unsafe file CAS retain exact original and prevent next decision. Replay/status resolves original without duplicate revision; unverified import triggering assessment fails. | Store/socket/private custody |
| MD-T4 | 04 | Explicit import then separate assessment, repeat clicks, typed refusal/unknown status and widths above. Auto-I/O, payload/instruction reflection, clipped digests or conflated approval fails. | Foreground native model/render |

Installed accessibility/signing, private configuration delivery and actual source/
physical mapping qualification remain separate. Bounded synthetic draft and
socket evidence must not be recorded as device qualification.
