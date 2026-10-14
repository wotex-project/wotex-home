# Native source and fixture review preparation

Version: 0.1.1. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 H08-T1/T2/T5 and WOH.18 H18-09/H18-T14/T16/T17.
Implementation: local authenticated review preparation, private content inputs,
current-basis publication and native presentation implemented.
Evidence: [actual Store, fault, recovery, retirement and foreground checks](../provenance/native-authoring-review-preparation-2026-10.md).
Installed delivery, paired mutation and physical/source qualification remain separate.

## Result and inherited decisions

An operator chooses an owned compatible candidate original, supplies explicit
source-attribution/unresolved facts and optionally an owned envelope for complete
fixture/consumption review. Native preparation constructs the complete review
original from authenticated history and the current installed contract/revision.
The operator need not transcribe a candidate receipt's hashes or invent an epoch
or revision. Confirmation/publication remains a separate click.

[Authoring reviews](authoring-reviews-v1.md) owns exact citations, source coverage,
consumer-envelope and independent fixture checks, actor history, schema 31 and
the inert proposal receipt. The [complete native codec](native-authoring-originals-v1.md)
owns canonical review bytes; [first-decision publication](native-authoring-panel-v1.md)
owns current capture, full v6 retention before submission and receipt resolution.
Review neither approves/imports a profile nor selects a Thing, grants access,
publishes an observation or dispatches an effect. Attributed source metadata is
not source authenticity. A complete proposal still requires separate admission.

## Inputs and exact preparation

**RP-01.** Native prepare takes positive signed-64 candidate_epoch, Home ID
candidate_operation and one private absolute evidence-file URL. The file obeys
NativeAuthoringFiles: current-user-owned regular 0600, one link, no ancestor/leaf
symlink, stable descriptor/name/size/inode/time witnesses and <=131072 nonempty
bytes. Decode strict UTF-8 JSON before Foundation materialization, with duplicate
decoded key refusal and container depth eight. The file is an inert four-field
review-content object, exactly mode, evidence, unresolved_paths and envelope_ref;
it is not a complete operation or a producer profile. Unknown/missing keys and
floats/bools in integer positions refuse invalidProfileRequest.

Mode is source or complete. Evidence is 0..256 exact instance_path/source_ref/
locator records. Source_ref is lower hex64 over an original selected source's
tagged frame. Root paths are <=512 UTF-8 bytes and exactly /profile/binding,
/profile/fingerprint/i, /profile/channels/i/selector, /semantic, /invalid_values
or /conversion, and /definitions/i/unit or /value_schema, where i is canonical
decimal 0..31. Locator is inert nonempty UTF-8 <=256 bytes with no Unicode Cc/Cf.
Evidence is strictly sorted/unique by the byte tuple path/source/locator.
Unresolved_paths is 0..64 sorted/unique required-root strings. Native preparation
does not guess roots, auto-attribute a source or collapse ambiguity. The Store
checks actual required roots and selected sources using the retained candidate.

Source mode requires null envelope_ref. Complete mode requires exactly
object_digest lower hex64 and first_revision positive signed-64 over an owned
envelope. The complete original codec applies its inherited depth/node/member/
string and final 131072-byte budget, including newly supplied header/reference;
an evidence file within its separate limit may still exceed that final budget.
Resource/schema refusal creates no pending original or Store row.

**RP-02.** Require selected local controller before private file or credential
I/O; paired selection refuses unavailable without local fallback. Capture one
credential/native reference and read before identity, authenticated installed
contract export, candidate original status, and after identity. Every current
watermark equals the export's revision; owner/principal/epoch/installation and
the local capture reference must remain the same. Association generation and
metadata fences must remain current before delivering a prepared value.
Current profile:manage remains enforced by export/status and again by Store.

Status is queried with the operator's exact candidate_epoch/operation. Require
an actual candidate receipt with compatible disposition, positive revision,
lower-hex input_sha256 and assessment_sha256 (native resultSHA) and basis_sha256
equal to the current export's complete Home basis. Missing original refuses
candidate_unavailable; incompatible candidate refuses candidate_incompatible;
changed installed basis/current scope refuses nativeGuardConflict. A candidate
revision greater than the current revision is invalidResponse. The candidate's
historical epoch remains part of its reference; a new review uses the current
active epoch. Do not rewrite a receipt or infer an assessment hash.

Construct the exact existing review original: current authority_epoch/global
expected_revision, fresh Home ID authoring:review:<lowercase UUID>, and review
containing those four validated file fields plus candidate_ref derived only
from the checked receipt's epoch/operation/revision/input/result identities.
Revalidate through NativeAuthoringOriginalWire and NativePendingAuthoring.checked.
Retain the complete original, exact current basis and capture privately. Preparation
publishes nothing and exposes only safe operation/basis/candidate/count metadata;
locators, file path, source text, input evidence and capture stay out of reflection
and ordinary logs. No helper fetches cited locators or URLs.

## Submission, failure and presentation

**RP-03.** Each prepared review requires explicit unchecked confirmation and a
separate submit click. Existing submission rechecks the same capture/current
identity/global CAS/association and the complete manual basis before full v6
publication; upload and Store review follow that publication. Current Store
checks candidate/source/envelope/fixture ownership, first revisions, contract/
capture, maintenance, quotas and immutable original before commit. An unselected
source, wrong actual root, unavailable capture or malformed fixture can therefore
refuse after native preparation; the native client implements no parallel WPF
compiler or Home review validator. Its metadata preview is not a successful review.

Exact known initial refusals follow existing first-decision cleanup; lost reply,
malformed result, unsafe private publication, later scope loss or unknown outcome
retain the original for Activity recovery. No automatic retry, approval, selection,
fixture synthesis or source import follows. Editing file/candidate selector,
changing entry/session/access/wake or cancellation retires preparation and
confirmation; late data cannot restore them. Published history remains intact.
Repeated clicks while busy make one call. A changed input requires a new prepare.

**RP-04.** Add an explicit review entry beside complete-original and manual-draft
entry, sharing application busy/access/local-session and pending coordinator
guards. Inputs are candidate epoch/operation and private review-content file.
Show only basename, candidate/operation/basis hashes and evidence/unresolved
counts until confirmed; after verified receipt show separate source_review,
home_consumption, fixture_status and proposal_status. Do not label compatibility,
attribution or proposal completion as approval or physical qualification.
Mount/focus/reload/wake initiate no API/file I/O. Use logical widths 480, 600,
720, 980 and 1320 points and wrap digests/IDs; retain PNG backing scale in evidence.

## Compatibility, entry and acceptance

No Store schema, public route, canonical original, quota, v6 root or physical
flag changes. Source/fixture objects and envelope must already be imported and
owned through existing supported object workflows; the candidate original must
have selected the exact source/fixture handles. This preparation cannot append
handles to that immutable candidate. Data import/handle selection ergonomics
remain separately allocated work; their absence is not bypassed with invented
citations or generated fixture expectations.

| Case | Requirements | Setup and falsifier | Level |
| --- | --- | --- | --- |
| RP-T1 | 01/02 | Two independent actual candidates, source and complete inputs: constructed canonical review matches independent codec/Store reference and current basis without caller-transcribed hashes/revision. Wrong candidate identity, invented source/root or rewritten payload fails. | Native/actual Store |
| RP-T2 | 01–03 | Missing/incompatible/future candidate, changed basis/scope/watermark, malformed private file/citations/limits, paired selection before I/O and delayed selector/session/wake/cancellation. Fallback or stale prepared delivery fails. | Native scoped fixtures |
| RP-T3 | 03 | Full v6 original before first review upload/Store call; lost final reply, exact separate-process recovery, revoked actor and unsafe publication. Duplicate revision, late auto-approval or deleted uncertain original fails. | Actual Store/socket/private custody |
| RP-T4 | 04 | Separate fields/statuses, explicit preparation/confirmation, repeated clicks and widths above. Auto-I/O, reflected evidence/source bytes or clipped hashes fail. | Foreground native/model |

Existing independent authoring-review vectors are the byte oracle. Actual Store
and authenticated original status establish actor/receipt correspondence. Native
fixtures do not establish installed signing, paired review mutation, accessibility,
source authenticity or physical mapping/fixture qualification.
