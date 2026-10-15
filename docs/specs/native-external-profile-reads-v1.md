# Native external-profile catalogue and original reads

Version: 0.1.1. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-03/09 and H08-T1/T5/T9; WOH.15 H15-07/H15-T8;
WOH.18 H18-07/08 and H18-T6/T8/T11/T12.
Implementation: planned. Evidence: missing.

## Result and delivery order

The native client can explicitly read the current external-profile catalogue or
one exact inspection, trust or target original. This is the typed read prerequisite
for v2 native presentation. The existing [operator API](external-profile-operators-v1.md)
and Store own authentication/current grants, immutable history, trust and target
transitions. [Inspection](external-inspections-v1.md), [trust](external-trust-v1.md)
and [target selection](external-target-selections-v1.md) own unchanged receipt shapes.
No producer, schema or dependency addition is needed.

The remaining native delivery order is complete inspection/trust/target original
codecs, durable pending custody/recovery, explicit selected preparation/confirmation
and panel composition. This read component creates no mutation route, file write,
source publisher, grant or signing capability. Source/protocol and installed-host
qualification remain separate; historical reads need no live producer or publisher.

## Exact inputs and transport

**NXR-01.** Every public read takes an explicit socket path/transport and an exact
32-byte credential supplied by its caller. It captures or stores no credential and
chooses no controller. Original lookup additionally requires inspection/trust/target
kind, positive signed-64 authority epoch and Home operation ID (1–128 ASCII bytes,
existing Home ID grammar). Optional expected input SHA is lower hex64 and must
match a present receipt. Invalid arguments refuse invalidProfileRequest before any
request. Absence of a supplied input hash is a history read, not input verification.

Only external_profiles, external_inspection_status, external_trust_status and
external_target_status may pass the new closed read adapter. Requests retain
api_version=1, credential and, for status, authority_epoch/operation_id. Reuse the
existing 65536-byte request/1048576-byte response framing, strict duplicate/depth
checks and finite transport owner. No new transport retry, fallback, clock, signing
or Keychain acquisition is added. Error reasons are 1–128 lowercase ASCII identifier
bytes (first a–z, remaining a–z/0–9/underscore); malformed reasons refuse
invalidResponse. Propagate valid server refusal and transport/delivery failure.

Each explicit call reads controller identity before and after its one domain read.
Require identical deployment/owner/active epoch/principal and nondecreasing current
revision. Catalogue revision equals both identity reads and catalogue epoch equals
active epoch; drift refuses nativeGuardConflict. A status receipt keeps its requested
historical epoch, operation and kind even when active epoch is later. Final current
revision must be at least that receipt revision. Catalogue, inspection and trust reads require current profile:manage; target
history additionally requires enroll:review. Catalogue metadata is shared with
such authorized managers, but original status remains scoped to the authenticated
principal: another permitted principal sees missing, not another actor's receipt.
No read renews a receipt or proves
current permission beyond its actual authenticated exchanges. Returned values are
typed metadata with redacted reflection and contain no bearer or reusable session.

## Catalogue

**NXR-02.** Successful response is exactly api_version/outcome/external_profile_catalogue,
with version1 and outcome ok. Catalogue is exactly authority_epoch/store_revision/
policy_generation/items. Epoch is positive S64, revision nonnegative S64 and policy
generation 0–1024, at most current revision. Items has 0–64 closed records:
artifact_digest, id, version, trust_revision, trust_generation, trust_author, state,
reader_basis_sha256. Digest is lower hex64; id/trust_author use Home ID grammar;
version is canonical x.y.z, at most17 ASCII bytes, each component0–65535 with no
leading zeros. Preserve strict binary id/version lexical order, unique id/version
pairs and artifact digests. Do not apply numeric semantic-version ordering.

Trust revision is positive and at most catalogue revision; trust generation is
positive and at most current policy generation. State is exactly approved, revoked
or author_unavailable. Revoked requires null reader basis; other states require
lower hex64. Missing catalogue, unknown fields/states, duplicate/out-of-order rows,
scalar coercion or excess count refuses invalidResponse, never an empty reset.
These are current catalogue facts, not profile approval credentials or qualification.

## Immutable originals

**NXR-03.** Status is exactly api_version/outcome/member, with version1, outcome ok
and the owning external_inspection_receipt, external_trust_receipt or
external_target_receipt. Only exactly api_version/outcome with outcome not_found
returns missing, after the final identity check. Unknown/member-mismatched fields,
wrong requested epoch/operation, invalid digests/counters or optional input-hash
mismatch refuse invalidResponse. All integers reject booleans, floats, strings and
S64 overflow. Original metadata remains distinct from current catalogue/selection.

Inspection has exactly authority_epoch, operation_id, revision, input_sha256,
reader_basis_sha256, result_sha256, capture_digest, envelope_sha256 and
home_consumption. Epoch/revision are positive; all five SHA fields are lower hex64;
home_consumption is exactly matched. It establishes checked inspection history.

Trust has exactly the twelve fields in ExternalTrust's owning receipt. Action is
approve/revoke; epoch/revision/trust_generation/policy_generation/
artifact_first_approval_revision are positive, previous_trust_revision nonnegative
and less than revision. First approval revision is at most revision and trust
generation at most policy generation. Input/artifact/outcome SHA are lower hex64.
Approve requires a reader-basis SHA, revoke null. Generation1 requires approve,
previous revision0 and first approval equal revision. Later generations require
positive previous revision and first approval strictly before revision.

Target has exactly the sixteen fields in ExternalTarget's owning receipt. Action
is select/revoke. Epoch/revision/selection_generation/binding_revision/trust_revision/
policy_generation are positive; previous_selection_revision/resource_revision/
withdrawn_grants nonnegative. Target ID uses Home ID grammar; input/artifact/source
selection/outcome SHA are lower hex64. Withdrawn grants is at most4096, previous
selection revision less than revision, binding revision at most revision and trust
revision strictly before revision. First generation requires select, previous and
resource revisions0, binding equal revision and withdrawn grants0. Later generations
require positive previous revision and resource revision=selection generation−1;
select binds at this revision, revoke keeps binding at most previous selection
revision. A historical select is not evidence that the target is currently selected.

## Acceptance

| Case | Requirements | Falsifier | Level |
| --- | --- | --- | --- |
| NXR-T1 | 01–03 | Independent owning receipts for both quantities and approve/revoke/select histories; exact three framed read requests, missing and matching optional input hash. Mutation/capture, changed identity, silent coercion or metadata-as-authority fails. | Native/framed peer |
| NXR-T2 | 02/03 | Empty/full/sorted catalogue, generation edges and every closed receipt; wrong fields/kind/epoch/ID/hash, float/bool/overflow, future receipt, reordered/duplicate rows and malformed errors. Accepted malformed/current-state claim fails. | Native independent vectors |
| NXR-T3 | 01–03 | Actual private socket/Store original history, catalogue after revoke/author withdrawal, current grant denial and changed identity/revision; no write/provider prerequisite. Fixture-only success cannot establish this case. | Native/Store plus installed separately |

Installed selection/custody, UI accessibility, physical source truth and complete
native v2 authoring/confirmation/pending publication require their own later evidence.
