# Read-only external-profile guidance

Version: 0.1.1. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.18 H18-03/04/07/08 and H18-T2/T3/T6/T8/T11/T12;
WOH.08 H08-03/09/H08-T9; WOH.15 H15-03/07 and H15-T2/T8.
Implementation: planned. Evidence: missing.

## Result and ownership

Guided native decisions can read an authenticated current reader basis, safe
host-published source choices, current target counters and an exact approval
manifest from the caller's retained inspection. These are missing inputs to the
[native review consumer](native-external-profile-panel-v1.md). No read allocates a
new original, approves bytes, selects a target, extends a source lease, grants
access, publishes a source/report or enables dispatch. Store remains the single
database owner and authenticates before producer, custody or source-owner work.

Use the existing [reader/inspection](external-inspections-v1.md),
[source custody](external-source-custody-v1.md), [trust](external-trust-v1.md) and
[target](external-target-selections-v1.md) contracts. This owns new read use cases
and their closed local socket/CLI wrappers. Native codecs/builders and signed
selected composition are subsequent consumers. No Store schema, dependency or
sibling producer API changes are required.

## Closed operations and common output

**EG-01.** All operations require a 32-byte current credential and current
profile:manage. Source choices and target basis additionally require enroll:review,
before contacting the source owner. Actor-scoped inspection derivation never
borrows another principal's original or raw imports. The Store runs each operation
on its owned connection under its normal authority/retirement/quarantine gate;
these new preparation reads are not added to retired-authority exceptions.

| API / socket operation | Additional input | Successful response member / body limit |
| --- | --- | --- |
| external_profile_context/2 / external_profile_context | none | external_profile_context /4096 bytes |
| external_source_catalogue/2 / external_source_catalogue | none | external_source_catalogue /32768 bytes |
| external_target_basis/3 / external_target_basis | target_id | external_target_basis /8192 bytes |
| external_inspection_artifact/3 / external_inspection_artifact | inspection_ref | external_inspection_artifact /65536 bytes |

Authority forwards to the single Store. Each successful body has exactly format,
principal_id, authority_epoch, store_revision, policy_generation plus its fields
below. Format is respectively wotex-home.external-profile-context@1,
wotex-home.external-source-catalogue@1, wotex-home.external-target-basis@1 or
wotex-home.external-inspection-artifact@1. Principal is the current authenticated
Home ID; epoch positive S64, Store revision and policy nonnegative S64. All integers
reject boolean/float/string coercion and overflow. IDs are1–128 ASCII bytes, initial
alphanumeric then alphanumeric/dot/underscore/colon/hyphen; digests are lower hex64.
Unknown/omitted input fields refuse. Whole successful body JSON must fit its limit
before returning; no truncation, partial fragments or extra output fields.

Common metadata comes from one serialized Store invocation. Source metadata is a
snapshot of the configured owner's response, not a promise of continued presence.
Clients bracket reads with identity/current watermark and compare any source
owner/selection identifiers again at confirmation. Store's actual mutation guards
still check current auth, epoch/CAS, maintenance, exact counters, bytes and leases.

## Read bodies and bounds

**EG-02 — Current reader context.** Add exactly maintenance, maintenance_revision
and reader. Maintenance is normal or maintenance; revision is zero in normal mode
and the positive active begin revision otherwise. This reveals no maintainer or
credential and requires no host:maintain grant; entering/leaving maintenance still
requires that separate permission.

Reader is exactly state, basis_sha256 and reason. A configured ReaderSelection
is reconstructed through its existing public to_map/1 after authentication.
Success gives available, its exact basis SHA and null reason. Missing/invalid
selection gives unavailable/null/external_reader_unavailable; missing producer
gives unavailable/null/profiles_producer_unavailable. No capture fields, capture
identity, installation bodies or producer-generated source enter the result.
An unavailable reader does not prevent metadata-only revoke preparation.

**EG-03 — Safe source choices.** Add exactly state, owner_epoch, sources and reason.
The explicitly configured ExternalSourceOwner catalogue is the only source; no
caller supplies a PID, endpoint, capture or policy. Available output has lower
hex32 owner epoch, null reason and0–32 sources strictly sorted/unique by source_ref.
Each row is exactly source_ref, source_selection_sha256, reader_basis_sha256,
source_epoch, source_generation, method, trust and policy_sha256. Epoch is lower
hex32 and generation positive S64. Method is operator_configured/legacy_tofu/
physical_button/qr_install_code; trust is unauthenticated_local/authenticated_device/
bridge_attested/synthetic_lab. Validate the existing safe owner's summary before
projecting; source_ref must agree with its nested data. Do not export stable_id,
its hash, raw reader/capture/channel policy, source lease tokens or monotonic time.

Missing/dead/timed-out owner gives unavailable/null/[]/external_source_unavailable.
Malformed owner metadata refuses invalid_external_source_catalogue instead of
silently inventing an empty catalogue. One owner call has its existing five-second
bound; the Store caller permits ten seconds. Existing expiry cleanup may retire
already expired source leases but allocates/renews none. Owner loss/replacement
after a read is handled by the actual later original/checkout guards.

**EG-04 — Target basis.** Add exactly target_id, state, selection_revision,
selection_generation, resource_revision, binding_revision, artifact_digest and
trust_revision. Target ID is explicit; invalid input refuses invalid_external_target.
Require current target-history validation before resolving its cursor. A new
unoccupied target gives absent and four zero counters, null artifact and zero trust.
An existing legacy/nonexternal enrollment refuses external_target_collision.

Selected/revoked external identities retain the exact current selection/resource/
binding counters, including dependency retirement and revoked tombstones. Derive
artifact digest from the retained canonical artifact manifest and trust_revision
from its latest retained catalogue entry, even when trust is revoked or its author
unavailable. Missing/inconsistent history is corrupt_external_targets, not absent.
Source owner/producer/bytes are not required; no live grant, report, qualification,
private stable identity or reactivation follows reading historical counters.

**EG-05 — Inspection artifact.** Input is exactly the five-field inspection_ref:
authority_epoch, operation_id, revision, input_sha256 and result_sha256, matching
the caller's exact retained receipt. Epoch/revision positive S64, IDs/digests as
above. Validate its closed shape before work; malformed input refuses
invalid_external_inspection_reference. Missing original returns not_found;
mismatching reference refuses stale_external_reference.

Add exactly inspection_ref, artifact_digest and artifact. Reuse existing inspection
history validation, actor-owned typed handles, current reader-basis match, immutable
byte reads and ExternalApprovalPreparation.build/3. Rebuild the inspection and
require its exact canonical result equals the retained result. Encode/validate
the existing ExternalArtifact and derive its identity with the owning prefix and
array layout. Artifact has exactly format/id/version/objects, with envelope then
profile then sorted definition rows,2–34 distinct complete object digests, existing
typed references/payload digests/size ceilings and at most32768 canonical bytes.
Never substitute semantic/raw/frame digests for one another or reinterpret an
old result with a changed reader. Export no raw object payload or capture.

Sequential private byte leases use the existing custody owner and release on every
path. Missing bytes, wrong ownership/kind/first revision, changed reader or absent
producer retain their owning typed errors. This is fresh read-only derivation,
not immutable receipt lookup: it may fail while historical status still succeeds.
An explicit historical inspection epoch is preserved; common epoch is the current
authority's. Future approval supplies its new operation and current CAS separately.

## Wrappers, errors and compatibility

**EG-06.** Local frames retain api_version1, encoded credential, operation and only
the table's additional fields. Exact success is api_version/outcome=ok/named member;
inspection missing is api_version/outcome=not_found. Errors retain the bounded
owning atom name through existing payload-free server mapping. Request bodies
remain at most65536 bytes with the existing strict Frame duplicate/depth checks;
responses at most1048576. Private socket/same-user peer and credential custody
remain mandatory. Reads do not become mutation-capable through LAN forwarding;
paired client support still requires its own current signed grant/session consumer.

CLI adds external-profile-context, external-source-catalogue,
external-target-basis TARGET_ID and external-inspection-artifact REFERENCE_FILE.
The reference file is absolute at most1024 path bytes, same-user0600 regular
one-link under a0700 private parent, with no ancestor/final symlinks and at most4096
bytes of strict native JSON. Artifact derivation has the existing thirty-second
Store computation call bound; context/source/target Store calls permit ten seconds.
The local socket exchange keeps its five-second client bound. No credential
or full reference is printed as an error. Existing CLI statuses0/1/2/4 cover
success/refusal/usage/missing; these reads never return mutation-uncertain3.
Old operations and original encodings remain byte-compatible.

Source/reader metadata may become stale immediately; retry is another explicit
read, never an implicit mutation or refreshed approval. Restart/restore may leave
metadata unavailable or quarantined; it cannot promote retained assertions into
current reader/source truth. No journal, Store revision, grant, original, raw-byte
publication or effect record is created by a successful/refused read.

## Acceptance

Use independent existing two-quantity/multichannel manifests/source summaries and
exact independently written request/response shapes. Implementation code cannot
allocate its own expected artifact digest or silently normalize output examples.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| EG-T1 | 01–05 | Actual Store context/source/absent-selected-revoked target/owned inspection artifact for both quantities; exact independent manifest/digest/header. Changed revision, raw/private identity, wrong namespace or lease allocation fails. | SQLite/process independent fixtures |
| EG-T2 | 01–05 | Invalid/missing/wrong-actor credential/ref, manager without enroll:review, unavailable reader/producer/owner/bytes, owner replacement and legacy collision. Early side work before auth, borrowed originals or reconstructed current source fails. | Store/owner/custody |
| EG-T3 | 03–05 | Explicit source succession, trust/author/target withdrawal, stopped publishers, tampered history/ref/owner data, byte failure/release and restarted owner. Stale live authority, erased tombstone, leaked lease or writable corruption fails. | SQLite/process |
| EG-T4 | 06 | Real framed UDS and CLI exact shapes, unknown/duplicate/extra fields, safe reference files, missing/error statuses and unchanged existing originals. Coercion, broad route, uncertain-read status or printed credential/reference fails. | Actual socket/CLI |

These checks establish software preparation data only. Native guided controls,
signed installed interaction, protocol publisher truth, power-loss survival and
physical qualification remain separately owned acceptance obligations.
