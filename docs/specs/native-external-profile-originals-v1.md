# Complete native external-profile originals

Version: 0.1.2. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-03/09 and H08-T1/T5/T9; WOH.15 H15-07/H15-T8;
WOH.18 H18-07/08 and H18-T6/T8/T11/T12.
Implementation: pure complete-original codecs and bounded preflight implemented.
Evidence: [281 independent cases, 579 URI parity cases and owning checks](../provenance/native-external-profile-originals-2026-10.md).
Pending mutation/recovery and selected confirmation remain separate.

## Result and dependencies

Native confirmations and later pending recovery preserve the entire original
inspection, trust or target input, including its exact operation ID, authority
epoch and expected revisions. A displayed ID or receipt cannot reconstruct it.
This owns pure native codecs, not mutation, pending publication or a signed result.
The implemented [native reads](native-external-profile-reads-v1.md) provide typed
history; [inspection](external-inspections-v1.md), [trust](external-trust-v1.md) and
[target selection](external-target-selections-v1.md) own unchanged Home input and
receipt semantics. No Store schema, producer API or dependency changes are needed.

## Closed inputs and canonical bytes

**NXO-01.** Support exactly inspection, trust and target. Common headers are
positive signed-64 authority_epoch, Home operation_id (1–128 ASCII bytes, initial
alphanumeric then alphanumeric/dot/underscore/colon/hyphen) and nonnegative S64
expected_revision. Reject floats, booleans, strings or overflow in every integer
position. Digests are exactly 64 lowercase hexadecimal characters. Null is an
explicit required value where specified; omission or unknown fields refuses.

Inspection's native object is exactly authority_epoch/operation_id/expected_revision/
inspection. Inspection has reader_basis_sha256, envelope_ref, profile and definitions.
Envelope_ref is an exact object_digest/first_revision handle; first revision is
positive S64. Profile is exactly reference/object_ref; reference is exactly
id/version/sha256 and object_ref is a handle. Definitions is 0–32 such document
records, strictly sorted by reference id/version, unique by reference ID and
object digest. A profile/envelope digest does not implicitly alias a definition;
actual ownership/kind/raw/semantic closure checks remain Store decisions.

Reference ID is an absolute ASCII URI with a scheme, at most 256 bytes, accepted
by Home EnvelopeCodec/URI.new in the pinned runtime; no spaces, controls, quotes,
backslash or non-ASCII bytes. Preserve that metadata predicate, including its
five-digit port-text bound and existing hexadecimal/dot suffix acceptance after
an IPv6 literal (for example x://[::1]abc). This is not a network-endpoint validator;
tightening parser behavior requires an owning compatibility decision. Preserve the original URI string without fetching,
normalizing or repairing it. A bare scheme such as urn: and opaque percent text
accepted by URI.new remain metadata; they confer no transport support. Version is
canonical x.y.z, at most 17 ASCII bytes, each decimal 0–65535 without leading zeros.

Trust's nine fields in order are authority_epoch, operation_id, expected_revision,
action, artifact_digest, expected_trust_revision, expected_policy_generation,
inspection_ref and acknowledgement. Expected counters are nonnegative S64. Approve
requires an exact inspection_ref containing authority_epoch/operation_id/revision/
input_sha256/result_sha256 (epoch/revision positive) and acknowledgement
operator_digest_approval. Revoke requires both null. Preserve the inspection's
explicit historical epoch; do not rewrite it to the new operation epoch.

Target's fifteen fields in order are authority_epoch, operation_id,
expected_revision, action, target_id, artifact_digest, expected_trust_revision,
expected_policy_generation, expected_selection_revision, expected_resource_revision,
source_ref, source_owner_epoch, source_selection_sha256, objects, acknowledgement.
All expected counters are nonnegative S64; target_id uses Home ID syntax. Select
requires source_ref Home ID, source_owner_epoch exactly 32 lower hex characters,
source_selection_sha256 digest, objects exactly envelope_ref/profile/definitions
with inspection's handle/reference rules and acknowledgement
operator_external_selection. Revoke requires all five source/objects/acknowledgement
fields null. These metadata fields neither publish a source nor qualify a device.

**NXO-02.** Canonical UTF-8 is compact JSON arrays, no object members or whitespace:

- Inspection: ["wotex-home.external-inspection.v1",[epoch,operation,expected_revision,
  [reader_basis,[envelope_digest,envelope_first],[[profile_id,profile_version,
  profile_sha],[profile_object,profile_first]],definition_documents]]].
- Trust: ["wotex-home.external-trust.v1",[the nine ordered fields]], replacing a
  present inspection_ref with [epoch,operation,revision,input_sha,result_sha].
- Target: ["wotex-home.external-target.v1",[the fifteen ordered fields]], replacing
  present objects with [envelope_handle,profile_document,definition_documents].

Each definition document uses [[id,version,sha],[object_digest,first_revision]].
Preserve lower hex, integer spelling, nulls and array order, with unescaped slash
and ordinary JSON string escaping. SHA256 is over these complete original bytes,
with no added domain or newline. No receipt, capture, provider or current grant is
embedded. Canonical byte ceilings are inspection 16384/trust4096/target32768.
Native JSON-object input ceilings are respectively 65536/16384/131072; whitespace
and key order may vary there, but strict decoded duplicate names refuse.

Before complete Foundation tree materialization, bound nesting to eight containers,
nodes to 4096, arrays to 256 members, strings to 4096 decoded UTF-8 bytes and integer
tokens to 20 bytes within −S64max..S64max. Canonical input allows no objects or
boolean/float tokens; native object input additionally allows at most 32 keys per
object and forbids duplicate decoded keys. Apply each owning narrower count/string/
scalar rule after preflight. Re-encoding a canonical input must equal its bytes,
so alternate escapes, whitespace, number spellings, wrong formats/kinds or trailing
input refuse invalidProfileRequest. Invalid native maps, malformed JSON and resource
refusals use that same payload-free family; never return partial input.

The immutable native value retains kind/header/complete canonical bytes and SHA;
its constructor is private to the codec. Reflection redacts input/reference data.
A fields accessor revalidates retained bytes and header correspondence each time.
Construction performs no file, credential, clock, network, publisher or Store work.

## Acceptance and next consumers

Freeze an independent Python corpus before implementation, starting with the
existing owning two-quantity and multichannel originals. Assert exact bytes/SHA,
strict input maps, empty/32 definitions, ordering/identity conflicts, S64 edges,
URI/version boundaries, action nullability and malformed canonical/native JSON.
Also check parity with the actual Elixir owning codecs, not only native roundtrip.

| Case | Requirements | Falsifier | Level |
| --- | --- | --- | --- |
| NXO-T1 | 01/02 | Independent original bytes/hash and native fields for all kinds, both quantities, multichannel and bounds. Swift allocates expected bytes, changes an ID/revision or leaks reflection. | Pure native independent vectors |
| NXO-T2 | 01/02 | Closed-field, type/coercion, duplicate/alias/order, kind/format, URI, nullability and preflight resource failures. Accepted malformed input, trap or allocation before bounds fails. | Pure native/refusals |
| NXO-T3 | 01/02 | Actual Elixir encode/decode agrees with every frozen accepted input/byte sequence and refuses the same malformed native originals. Divergence requires a contract/codec fix, never silent normalization. | Owning codec parity |

Next consumers must publish complete pending input before any send, require fresh
selected authorization/current guards, verify typed receipt correspondence and
retain uncertainty after possible publication/send. This codec alone implements
none of those stages or physical/installed qualification.
