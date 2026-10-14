# Local trust for exact external profile closures

Version: 0.1.2. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-03/04/05/07/08, H18-T3/T4/T6/T8/T11/T12.
Implementation: pure preparation/codecs and schema 33 Authority/Store trust, catalogue,
original history and recovery implemented; inspection/trust socket and CLI
adapters implemented under their owning annex. Evidence:
[executed archive, Store and recovery cases](../provenance/external-trust-2026-10.md).

## Result and ownership

An authenticated operator explicitly approves or revokes one exact v2 envelope/
profile/definition closure for the local catalogue. Approval records the current
reader/consumer basis and complete immutable byte identity. It grants no target
selection, enrollment, observation, control, routine or physical qualification.
It is an operator decision; a generated proposal, compatibility result, source
attribution summary or inspection receipt is not approval.

The existing v1 local approval policy and its profile_policy_generation remain
unchanged. V2 has a separate format-qualified catalogue and
external_profile_policy_generation, initially zero. Future v2 target/observation
consumers must bind and recheck that generation and the current trust original;
they cannot use the v1 generation or an earlier inspection as a substitute.
No publisher wildcard, signature, network fetch, automatic update or expiry is
introduced. Explicit local approval has no internet freshness prerequisite.

Authority.change_external_trust/3, external_trust_status/4 and
external_profile_catalogue/2 forward to the single Store. Catalogue requires
current profile:manage and returns exactly authority_epoch, store_revision,
policy_generation and items, sorted by id/version. Each item is exactly
artifact_digest, id, version, trust_revision, trust_generation, trust_author,
state and reader_basis_sha256 (null on revoke). It reports retained local
decisions and current author permission, not byte availability or selection. The stateless writer receives only its borrowed connection.
Public WPF mechanics remain owned by the
[inspection boundary](external-inspections-v1.md); no copied producer validator
or unit algebra runs in Home. Private immutable custody and schema 29 owned
imports protect bytes. The host alone supplies the current ReaderSelection.

## Exact byte identity and pure preparation

Profiles.ExternalArtifact encodes a closed manifest exactly format, id, version
and objects. Format is wotex-home.external-artifact@1; id is a Home ID, version
the bounded canonical x.y.z envelope version. Objects is an ordered proper list
of two to 34 records, each exactly kind, reference, object_digest,
payload_sha256 and payload_bytes. First is kind envelope with null reference;
second kind profile with its exact WPF reference; the remainder are kind
definition, strictly sorted by reference ID/version, unique by ID and full object
digest. References have absolute URI ≤256 bytes, canonical version and lower
hex64 SHA. Full object and payload digests are lower hex64; sizes positive
integers ≤65536. Profile/definition payload total ≤262144, envelope ≤65536.
All complete object digests are distinct. No first-import revision, actor,
capture or compiler identity is part of the raw closure identity.

Canonical bytes are [format, id, version, objects], with object represented as
[kind, reference-or-null, object_digest, payload_sha256, payload_bytes] and
reference [id, version, sha256]. Manifest ≤32768 bytes. Artifact_digest hashes
UTF-8 wotex-home.external-artifact@1, newline and the ordered objects array
alone. The full envelope digest already binds its id/version and attribution;
equal labels cannot redirect to a raw variant. Different actors importing the
same exact closure have the same artifact digest despite different first imports.
Changed envelope, document raw variant, reference, kind or length changes it.
Encode/decode are producer-independent and require exact canonical equality.
Malformed manifests refuse invalid_external_artifact; resource excess refuses
external_profile_limit.

Profiles.ExternalApprovalPreparation.build/3 takes the exact inspection original
input, complete typed read records and current ReaderSelection. It first invokes
InspectionPreparation.build/3: revalidates reader basis, all requested kinds/
first revisions, complete frame/raw identities, actual public parsing, reachable
closure, installed consumption and host capture. It then decodes the actual
envelope labels through EnvelopeCodec, constructs the manifest only from those
verified records and returns exactly artifact, artifact_digest and inspection.
Artifact is the manifest above; inspection is the fresh closed result from
InspectionPreparation. This pure value establishes correspondence, not ownership
or approval. No byte is published and no Store or credential is passed to it.

## Original request and bounds

Input contains exactly authority_epoch, operation_id, expected_revision, action,
artifact_digest, expected_trust_revision, expected_policy_generation,
inspection_ref and acknowledgement. Epoch is positive signed-64; revision and
both expected counters nonnegative signed-64. Operation is a Home ID; artifact
digest lower hex64. Action is approve or revoke. Approve requires acknowledgement
exactly operator_digest_approval and an inspection_ref containing exactly
authority_epoch, operation_id, revision, input_sha256 and result_sha256, matching
this actor's retained inspection original. Its epoch/revision are positive
signed-64 and its digests lower hex64. Revoke requires null inspection_ref and
null acknowledgement. All fields are required; there are no defaults.

Profiles.ExternalTrust encodes ["wotex-home.external-trust.v1", [epoch,
operation, expected_revision, action, artifact_digest, expected_trust_revision,
expected_policy_generation, inspection_ref-or-null, acknowledgement]]. Ref is
[epoch, operation, revision, input_sha256, result_sha256]. Input ≤4096 bytes.
All retained encodings use the existing bounded array-only wire grammar: depth
eight, 4096 nodes, 256 array members, strings ≤4096 bytes, signed-64 integers,
no objects/floats, exact decode/encode equality. Native structs, unknown fields,
malformed refs, wrong acknowledgement/action/nulls refuse invalid_external_trust.
Resource excess refuses external_profile_limit.

## Durable transition and current authority

**ET-01 — Authenticate and recover the original.** Current profile:manage
authentication, v1 ledger consistency and external import/inspection/trust
consistency precede lookup. Key is (principal, epoch, operation) in the external
trust namespace. Exact input replay returns its immutable receipt before CAS,
maintenance, byte/producer work or current reader selection. Changed input
refuses external_trust_conflict. Status requires the actor's current permission;
revocation blocks original reads/replays. A replay never renews current approval.

**ET-02 — Guard the new decision.** New work requires current authority epoch,
global Store revision, expected current trust revision, expected external policy
generation and active maintenance. Profile management is independent from
host:maintain: another authorized actor may establish the maintenance barrier.
Unknown artifacts have trust revision/generation zero. First action must approve.
Approved→approve refuses external_already_approved; revoked→revoke refuses
external_already_revoked. Reapproval is a new approve after revoke and advances
generations; it never edits the first approval or restores old current pins.
All counters must have room before effects/publication or journal mutation.

**ET-03 — Recompile approval.** Approval resolves this actor's exact retained
inspection original, then checks every imported handle/kind/first revision at
or before the current CAS. Its reader basis must match the current host selection;
missing reader is external_reader_unavailable, changed basis stale_external_basis.
Read actual owned bytes with sequential checked leases and release them on every
path. Missing/corrupt/unsafe bytes are authoring_object_unavailable; custody loss
profile_custody_unavailable. Recompute the complete inspection and require its
exact result document to match the retained original. An old successful original
without current byte/reader correspondence cannot authorize approval. Require the
fresh manifest's artifact digest to equal the requested digest. Wrong digest is
external_artifact_mismatch; changed inspection/reference is stale_external_reference.

Same id/version in this v2 catalogue with different artifact digest refuses
external_label_conflict, even when the earlier artifact is revoked. Never pick
latest, normalize original bytes or replace first metadata. V1 labels live in
their existing format namespace; no unqualified lookup can alias them to v2.
Reapproval by a different actor requires that actor's own identical byte imports
and current exact inspection; it confers no access to the previous actor's sources.

Revoke reads retained manifest/history only. It must remain available with missing
files, absent reader/producer or withdrawn author. It records no fresh inspection
and does not attempt to reinterpret historical bytes. Current catalogue state is
revoked after revoke; approved only while the latest approving principal remains
active with profile:manage, otherwise author_unavailable. Restored quarantine is
never live authority. A status receipt can report historical action approve while
the current catalogue is revoked or author_unavailable; keep these distinct.

**ET-04 — Commit atomically.** One transaction rechecks actor permission, epoch,
CAS, maintenance, both counters, exact inspection/import references and, for
approval, the same revalidated current reader. Append external_profile_approved
or external_profile_revoked with entity_id artifact_digest. Retain canonical
input, outcome and receipt; first approve also retains immutable manifest/label
metadata. Advance per-artifact trust generation and external policy generation
exactly once. A SQL fault rolls back all rows, counters and journal/revision.
No target/observation/rule/grant/effect table is changed by this stage. Future
selection/observation writers must refuse stale trust/policy at every use and
implement their separately specified invalidation barrier before being enabled.

## Receipt, outcome, tables and recovery

Receipt is exactly authority_epoch, operation_id, revision, input_sha256, action,
artifact_digest, previous_trust_revision, trust_generation, policy_generation,
artifact_first_approval_revision, reader_basis_sha256 and outcome_sha256.
Reader basis is null on revoke and lower hex64 on approve. Generations/first
approval/revision are positive signed-64; previous trust nonnegative. Receipt
encodes these twelve fields in this order, ≤4096 bytes. Outcome is exactly format
wotex-home.external-trust-result@1, action, artifact_digest, inspection_ref, artifact_document and
inspection_document. Approval retains the exact canonical manifest bytes, same
inspection reference and fresh canonical inspection result document (≤32768 bytes); revoke has null last three. Outcome
encodes its six fields in this order, embedding the parsed canonical artifact
and inspection arrays in their last two wire slots (null on revoke), rather than a JSON string.
Decode reconstructs exact canonical artifact_document and inspection_document
bytes. The manifest digest must equal artifact_digest, and its selected semantic/
raw document identities and envelope raw SHA must match the inspection summary. This avoids
violating the wire string ceiling and stays within depth eight. Outcome ≤65536
bytes. Input/outcome SHA identify
the exact retained raw bytes, reproducible without installed producers.

Schema 33 adds profile_external_artifacts with exactly artifact_digest, id,
version, inspection_principal, inspection_epoch, inspection_operation,
artifact_document and first_approval_revision. Digest is primary key; id/version
unique; the complete first inspection identity references its existing row;
first approval uniquely references authority_journal. It adds
profile_external_trust_operations with exactly principal_id, authority_epoch,
operation_id, input_document, outcome_document, receipt_document and revision,
primary key original identity and unique journal revision. Meta adds
external_profile_policy_generation = 0. Supported predecessors validate before
empty migration; no old v1 approval or inspection becomes approved v2 data.

Retain at most 64 distinct v2 artifacts, 1024 trust originals, 4 MiB outcome
aggregate and 4 MiB input aggregate. Capacity refuses external_trust_capacity
before work and at commit; no deletion/reservation bypass. Existing import/custody
128-object/4-MiB limits still apply and protect every byte. Manifest identity,
first approval/inspection, exact actor-owned imports, outcome/current prefix,
canonical hashes, sequential trust/policy generations, CAS = revision−1,
journal type/entity/principal and orphan events must validate without producers
or files. Corruption refuses corrupt_external_trust and fences writes.

Inclusive/database-only backups and semantic/normalized transfer snapshots use
each schema's actual table set. Older normalized histories declare both empty
tables and external policy generation zero. WOHBK3 already retains all imported
typed bytes; no new byte owner is needed. Restore preserves originals in private
quarantine, never fetches sources, approves a missing successor, resumes a provider
or selects a target. Reinstating a withdrawn permission cannot revive retired
selection/freshness/qualification; those domains require their current guards.

## Implementation entry and acceptance

Freeze independent manifest/digest/input/outcome/receipt vectors in
test/fixtures/profiles/external-trust.json and closed request schema in
priv/profiles/external-trust.schema.json before code. Implement pure preparation
and codecs first; then actual Store writer/migration/recovery; operator routes
follow the same Authority transition. Parent plans/status must retain partial
v2 target/observation and physical qualification obligations.

| Case | Requirements | Setup and falsifier | Level |
| --- | --- | --- | --- |
| ET-T1 | 02–04 | Both independent quantities, exact shared raw closure identity across authors, approve/revoke/reapprove and permanent label conflict. Changed identity, implicit successor or active target/control fails. | Pure/software |
| ET-T2 | 01/03 | Exact retry after lost reply, missing files/reader/producer and restart; conflicting request and permission loss. Recompilation/reapproval or widened original reads fails. | Software |
| ET-T3 | 02/03 | Stale CAS/epoch/counters/inspection/reader/capture, wrong actor/kind/raw variant, absent maintenance, ambiguous closure and forged native fields. Any new approval without current complete correspondence fails. | Pure/software |
| ET-T4 | 03/04 | Revoke with missing files/producer and withdrawn author; actual SQL insert/counter failure and deep manifest/inspection/receipt/journal tampering. Unavailable revoke, partial commit, orphan acceptance or writable corruption fails. | Software |
| ET-T5 | 04 | Schema 32 migration, original/count/byte capacities, inclusive/database-only quarantine restore and v1 policy coexistence. Old authority promotion, changed v1 policy or incorrect retained snapshot fails. | Software |

Independent Python frame/ordered-array identities are the oracle; source/capture
values remain synthetic software inputs. None establishes vendor authenticity,
host transport support, physical qualification or complete active v2 delivery.

The [operator annex](external-profile-operators-v1.md) owns closed socket/CLI
wrappers and original-scoped uncertainty, with separately recorded executed
adapter evidence. Target/observation adoption remains a separate transition.
