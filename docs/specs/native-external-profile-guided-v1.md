# Selected native external-profile guided decisions

Version: 0.1.0. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-03/09/H08-T1/T5/T9; WOH.15 H15-07/H15-T8;
WOH.18 H18-07/08/H18-T6/T8/T11/T12.
Implementation: planned. Evidence: missing.

## Result and owners

The Things external-profile panel constructs all five decisions without a complete
original file: inspect, approve, withdraw approval, select read-only target and
withdraw target. Operator inputs identify imported objects, a retained inspection,
an artifact or target/source; authenticated reads supply reader, epoch/CAS, trust,
policy and target counters. The [pure builders](native-external-profile-builders-v1.md)
own exact construction; the [guidance decoder](native-external-guidance-reads-v1.md)
owns closed bodies. This owns selected local composition, forms and fresh review.

Keep the [existing selected panel](native-external-profile-panel-v1.md) lifetime,
confirmation, [v9 journal](native-pending-external-profiles-v9.md), fixed SDK and
Activity recovery. Signed paired consumption remains separate. Paired selection
refuses before credential, file, clock, signing or transport, with no local fallback.
No Store schema, producer, dependency, grant or physical-dispatch change is needed.

## Operator inputs and local draft

**NGU-01.** Default to Guided; keep Complete decision file as an explicit alternate
using the existing private-file path. Changing entry mode retires preparation.
Guided action is exactly inspection/approve/revokeTrust/select/revokeTarget.
One immutable Sendable draft retains the explicit operation ID and only the
action's inputs; reflection is empty. Validation is pure and precedes credential
capture. IDs are1–128 ASCII bytes, first alphanumeric then alphanumeric/dot/
underscore/colon/hyphen; all digests lowerhex64. Canonical positive decimal input
rejects whitespace, leading zero, bool/float/string coercion and S64 overflow.

| Action | Explicit input |
| --- | --- |
| inspection | operation ID and checked envelope/profile/definition references |
| approve | operation ID, retained inspection epoch and operation ID |
| revokeTrust | operation ID and artifact digest |
| select | operation ID, retained inspection epoch/operation, target ID, explicit source_ref and checked object references |
| revokeTarget | operation ID and target ID |

Object references use NB-02 exactly: envelope object digest/first revision, profile
URI/version/reference SHA plus object digest/first revision, and0–32 ordered
definition rows with the same five fields. Forms begin empty, never sort or repair
rows, and bound Add to32. Inputs come from the operator's owned import receipts
and exact profile/definition references. The existing authoring import panel can
copy handles; this UI does not claim a pasted handle proves current ownership.
It copies no WPF reader and does not parse raw payloads into authority.

Operation ID is explicit. New operation creates `external:` plus a lowercase UUID
only when clicked, without IO. Preserve that ID across Prepare failures; never
silently regenerate it on retry or increment CAS. A retained inspection lookup
may be explicitly copied into the guided epoch/operation inputs; its revision and
SHA values are read from the actual owned receipt during preparation.

Catalogue refresh retains its explicit action. A separate Read source choices
uses the selected driver's current authenticated local source catalogue; before/
body/after identity/principal/epoch/revision must agree. Show available-empty versus
unavailable, owner epoch, reference, method/trust and selection/policy digests as
comparison metadata. Selection is explicit; never choose the first row by default.
Editing, opening, navigation, mode/action selection, startup and timers perform
no read, capture, operation allocation or pending write.

## Fresh selected preparation

**NGU-02.** Draft validation finishes before capture. Under one driver reservation,
capture the actual selected-local metadata/generation, existing credential/reference
and selected request fence. Read controller identity, validate native capture
principal/owner/verifier if present, then current context and external catalogue.
Use only the captured credential/socket and exact operation-specific requests:

| Action | Additional reads, in order |
| --- | --- |
| inspection | none |
| approve | exact inspection status at explicit historical epoch/operation, then its five-field artifact reference |
| revokeTrust | none |
| select | exact inspection status, its artifact reference, explicit target basis, source catalogue |
| revokeTarget | explicit target basis |

The required inspection must be found and of inspection kind. Construct its
reference from the returned epoch,operation,revision,input SHA and result SHA;
do not derive hashes or borrow another principal's inspection. Missing required
receipt/artifact refuses preparation. Preserve its historical epoch.

Read context again, then invoke the owning pure builder. Read the new original's
exact status namespace at its current epoch/operation and finish with identity.
Require no existing original, equal before/after authority/principal and Store
revision, context principal/epoch/revision equal authenticated identity, and
catalogue epoch/revision/policy equal context. Every guidance body shares that
same comparison basis through the pure builder. Context maintenance state/begin
revision agree across reads. Inspection/approve/select additionally require equal
available reader basis; metadata-only revokes ignore reader availability changes.
No retry, CAS repair, source hold or mutation follows a refusal.

There are6 domain/identity exchanges for inspection or revokeTrust,8 for approve,
10 for select and7 for revokeTarget. Each is the existing bounded private socket
exchange. This group does not add nested SDK identity brackets. If a domain read
refuses, stop before the remaining sequence. A successful preparation stores the
exact draft/original/capture/identity/selection/generation in the existing privately
constructed prepared value and allocates no journal entry.

## Review, confirmation and invalidation

**NGU-03.** Present the existing action/consequence, controller owner/principal,
epoch/operation/CAS, complete canonical SHA and kind-specific safe facts. Guided
reader/trust/source/counters are fetched and never editable. Do not display raw
payload, capture, bearer, private path, stable physical ID or raw JSON. Labels,
form sections and accessibility names distinguish object digest, reference SHA,
first import revision, historical inspection epoch and new decision identity.
Long facts wrap at480/599/600/839/840/1320 points and enlarged text.

Submit requires a separate confirmation over the frozen prepared value. Reacquire
and compare credential/reference, repeat the entire guided preparation group and
require exactly the same canonical original and authenticated identity/revision.
This detects reader/source/target/trust changes which a previous display cannot
authorize. No frozen value is patched with fresh counters or rebuilt under a new
operation ID. Complete-file decisions retain their previous confirmation path.

After this check use the existing journal publication, fixed status-first SDK,
receipt verification and whole-file resolution. Check prepared lifetime and
selection before/after every async hop, before credentials/publication/delivery,
and in the additional local request guard around the entire fresh group and SDK.
Cancellation retires immediately even with a detached worker waiting. Retired
late values cannot publish, send or remove an uncertain original. Lost replies
and failed publication/resolution keep the exact complete original for Activity.

All draft fields, row edits/add/remove, action/mode, session/access, sleep/wake and
explicit source/catalogue/history work retire preparation and clear confirmation.
Delayed results after invalidation are discarded. Shared app busy/journal guards
prevent overlapping work. No automatic read follows submission. Old file-driven
workflows and existing original encodings remain compatible.

## Acceptance

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NGU-T1 | 01/02 | Both quantity families/all five guided decisions through actual shared app model/driver/Store; exact independent request sequences and original parity. Hidden allocation, producer bypass, stale basis or mutation during Prepare fails. | Actual local software |
| NGU-T2 | 01/02 | Invalid operation/target/ref/objects before capture, paired refusal, missing receipt/artifact, unavailable source/reader, changed reader at same revision and changed revision/policy/source owner. Partial review, fallback or silent repair fails. | Native/private peer/Store |
| NGU-T3 | 02/03 | Changed inputs during held Prepare, stale Submit, retirement/cancellation between SDK status and mutation, failed publication/resolution and dropped commit reply with separate-process Activity recovery. Send before publication, late send or missing retained original fails. | Actual process/custody/socket |
| NGU-T4 | 01–03 | Mounted guided input/prepared/confirmed/success/missing/uncertain/error across responsive widths and normal/enlarged text; explicit add/remove/source/inspection choices. Clipping, implicit requests, confused namespaces or false current-state claim fails. | Visible native software |

Record exact commands/results and remaining installed/signing/publisher/hardware
gates. Layout stress is separate from installed OS accessibility and VoiceOver;
synthetic metadata and successful software delivery do not qualify physical sources.
