# Portable profile local API v1 mechanism

Version: 0.1.5. Implemented shared Authority/API/CLI P4 routes for WOH.18, 2026-10-07.
Native window composition is implemented; installed-host/physical qualification
remains open.

All requests use the existing private same-user socket, API version 1, canonical
credential representation and bounded length framing. The maximum request body
remains 65,536 bytes and response body 1,048,576 bytes. Duplicate names, excessive
nesting and extra route or operation fields are rejected. No route provisions a
credential, installs reviewer keys, submits capture packets/declarations, accepts
a host filesystem path, grants a target or enables physical dispatch.

## Closed route fields

Every route has exactly `api_version`, `operation` and `credential`, plus the
additional fields below. The principal is derived by Store; it never comes from
a request. String identifiers and integers retain their existing closed syntax.

| Operation | Additional fields | Result body |
| --- | --- | --- |
| `profile_import` | `artifact_base64` | `profile_artifact` |
| `profiles` | none | `profile_catalogue` |
| `profile_target` | `thing_id` | `profile_target` |
| `profile_prepare` | `selection` | `profile_review`, or original `profile_receipt` |
| `profile_change` | `change` | `profile_receipt` |
| `profile_operation_status` | `authority_epoch`, `operation_id` | original `profile_receipt` or not found |
| `profile_review_status` | `review_token` | transient `profile_review` or not found |
| `profile_review_cancel` | `review_token` | cancelled or not found |
| `profiles_collect` | none | `profile_collection` |

`artifact_base64` is canonical unpadded URL-safe Base64, nonempty and at most
43,691 characters, decoding to at most 32,768 exact UTF-8 artifact bytes. Re-encode
comparison rejects padding, whitespace and alternate encodings. The envelope
fits the existing frame limit even when source JSON contains many escaped
characters. Authority checks current management permission before custody;
publication keeps the existing strict parser, registry checks, immutable bytes,
quotas and synchronization. Import is idempotent by raw digest and changes no
approval or target authority. The reply identifies raw/projection/registry,
profile id/version/reference and host binding, with `authority_changed: false`.

`selection` is exactly the existing `Profiles.Operation` select object; `change`
is exactly one of its four action shapes. The canonical retained operation
encoding is unchanged. Preparation requires management and enrollment review,
current CAS/maintenance/trust and fresh host-held capture. Exact preparation retry
returns its original token without consuming or renewing evidence; an already
committed exact scope returns its immutable original receipt. Commit consumes
only that held exact input after all Store guards. It accepts no caller proposal,
semantic diff, runtime digest, approval body or command packet.

Receipts retain the existing closed original epoch/operation/action/input digest,
expected/final revisions, raw digest, changed/invalidated/unknown counts and trust/
policy generations. Historical lookup is principal-private and checks current
management permission before returning original history, including after bytes
or transient owners disappear. Changed input conflicts under the same scope.
An uncertain commit is resolved by the original epoch/operation and exact inputs;
a new operation cannot substitute for a lost reply.

Review status/cancellation authenticate current management permission and derive
its principal before calling the transient owner. Tokens are opaque identifiers,
not credentials or durable receipts. Status exposes remaining host-derived life,
original pins, exact captured identity versus prior identity, semantic diff and
pending physical qualification. Cancellation releases pending custody only and
cannot cancel a checked-out Store transition. Lost preparation or owner restart
never manufactures another capture or a renewed lifetime.

Catalogue status separates local trust author/generation, current artifact
availability and retained mapping status. Target status is an authenticated
snapshot of Store/epoch/policy/rule pins, absent/active/revoked target, current
resource/enrollment/selection pins and declaration/profile identity. Null prior
identity/declaration and zero pins represent actual absence only. A revoked
selection stays explicit; unavailable bytes never cause compiled fallback.
Retained qualification-head metadata is separate from current file/runtime and
execution admission. None of these reads proves a physical result or grants
control. Collection retains the existing management/maintenance and Store-owned
reference snapshot; no API caller supplies roots or reference sets.

## Status and review reply fields

`profile_catalogue` has exactly `store_revision`, `authority_epoch`,
`policy_generation`, `items`. Each retained item has raw/projection/registry
identities, `id`, `version`, `binding`, `trust_revision`, `trust_generation`,
`trust_author`, `state`, `byte_availability`, `qualification_status`. Trust state
is approved/revoked/author-unavailable; byte availability is a fresh call-local
available/unavailable result, never a retained approval. Qualification status
labels the generic mapping pending physical evidence.

`profile_target` has exactly `target_id`, `store_revision`, `authority_epoch`,
`policy_generation`, `rule_generation`, `status`, `profile_ref`, `declaration`,
`resource_revision`, `binding_revision`, `identity`, `identity_status`,
`selection_revision`, `selection_generation`, `selection_state`, `artifact_digest`,
`current_use`, `qualification_head`. Status is absent/active/revoked. Selection
state is absent/selected/revoked. Reviewed identity has stable/manufacturer/model/
firmware fields; a legacy or coarse binding is explicitly review-required, with
its actual binding revision or null when no binding exists. Only an absent Thing
has zero binding/resource pins. `current_use` is a profile guard result (usable
or a typed denial), not execution admission. A nullable qualification head has
exact profile/resource/identity/basis/registry/runtime/evidence/status/revision
fields, referring to retained original evidence independently of current use.

`profile_review` has exactly `review_token`, `review_digest`, `state`,
`remaining_ms`, `summary`, `identity`, `basis`. Identity contains `prior`,
`captured`, `method`; the first two contain stable/manufacturer/model/firmware
fields, nullable prior values for initial enrollment. The existing semantic
diff summary and original basis omit raw packet/declaration bodies. The token
alone cannot change a target; commit repeats the exact selection object.

`profile_collection` has exactly `removed_objects`, `removed_bytes`,
`object_count`, `total_bytes`, `digests`. Counts are bounded by custody's 128
objects and 4 MiB namespace; sorted distinct digests list published objects.
Lease-protected objects remain retained, but collection does not expose a
transient lease count or change any authority revision.

## CLI mapping and bootstrap

Commands are `profile-import PROFILE_FILE`, `profiles`, `profile-target THING_ID`,
`profile-prepare SELECTION_FILE`, `profile-change OPERATION_FILE`,
`profile-operation-status EPOCH OP`, `profile-review-status REVIEW_TOKEN`,
`profile-review-cancel REVIEW_TOKEN` and `profiles-collect`. CLI reads bounded
regular descriptor-checked files locally and sends bytes or closed objects;
those paths never reach the host. Credential custody keeps the existing private
0600 file and avoids command arguments. Selection/change input files are bounded
to 8,192 bytes, parsed through the existing strict JSON/operation codec and retain
exact CAS/operation fields. Native clients use the same route shapes.

Trusted foreground setup may explicitly provision a profile operator with only
`profile:manage` and `enroll:review`, no control targets. This is separate from
maintenance, controller grants and physical qualification. Preserve the existing
management-only bootstrap; never silently widen a distributed bearer. The new
bootstrap prints its one-time credential in a private terminal and has no socket
provisioning route. Installed credential brokerage remains a host qualification
obligation.

## Required software correspondence

Exercise CLI construction, closed fields, malformed/canonical Base64 and maximum
artifact/frame sizes, permissions, initial/replacement capture, exact pending
retry, semantic identity/diff, real socket commit/status, lost replies, missing
bytes, principal privacy, revoked selections and collection. Preserve older
routes and use the same original receipt through Authority, framed API and CLI.
Run affected host/client fixtures. No scripted peer, synthetic signed claim or
successful IPC request establishes physical or installed-host qualification.

The Swift client implements these routes with bounded duplicate/depth response
checks and closed nested decoders. Mutation receipts compare the original
ordered operation SHA-256, scope, action, raw digest and expected Store/trust pins;
review results compare every preparation pin. Status retains original credential/
input correspondence when a caller supplies the pending operation. The native window composes these clients with host-held capture and original
operation recovery.

## Native operator composition

The native window composes these existing routes with the existing
host-owned `lifx_discover`/`lifx_interview` routes. It imports exact bounded local
bytes, refreshes authenticated catalogue and target pins, explicitly chooses an
approved raw digest and host-produced candidate, and prepares a one-use review.
It displays prior/captured stable/manufacturer/model/firmware, proposed profile,
capability changes and separate qualification before an explicit commit action.
No client authors a declaration or capture body, selects a network endpoint or
interprets a profile as a grant. Host interface/custody selection stays trusted.

Each prepare/change retains its exact typed operation and original credential
before sending. An uncertain prepare retries that exact input without renewing
evidence; an uncertain change uses original scoped lookup or exact retry. New
mutations stay disabled until resolved. A held review uses only its original
operation and credential for status/cancel/commit, even after a new Keychain
credential is imported. Fresh status is required for each new operation;
historical receipts never stand in for current catalogue/target state. Cancelling
or losing a proposal cannot undo a committed selection or erase uncertainty.
A definite refusal of the first attempt may clear its pending input. Any failed
retry retains the original, including authentication/policy refusal after an
earlier lost reply. Expiry, missing receipt or a vanished review does not permit
replacement by a new operation. Eight live Store/window workflows include a
committed approval whose reply is dropped before principal revocation: two
refused retries keep identical typed fields and the original credential, scoped
lookup remains refused, the Store revision does not change and new work stays
blocked. Expired and lost-cancellation workflows likewise retain unresolved
selection inputs after a refused retry.
The initial window's pending custody is in memory; persistent client recovery and
installed credential brokerage retain their separate host obligations.
