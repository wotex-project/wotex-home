# Retained generic read semantics

Version: 0.1.2. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.01 H01-05/H01-T6; WOH.18 H18-08/H18-T11/T12.
Implementation: retained read codec, shared Thing/Registry and fail-closed current-use bridge implemented.
Evidence: [exact archive and actual Store regressions](../provenance/generic-read-semantics-2026-10.md).

## Result and boundary

The shared Home Thing registry can represent a multi-channel EnvironmentalSensor
using format-qualified, exact external read declarations. Its capability keys
and quantity references remain data; no model/vendor/sensor enum is added.
Existing Light/SmokeDetector declarations, values, observations and write
admission keep their current closed formats. This representation grants no
enrollment, current trust, report acceptance, control or physical qualification.
The single Store remains the durable authority; no parallel Thing registry or
principal grant namespace is created.

The [read declaration](external-read-declarations-v1.md) owns live checked
channel/consumer/policy preparation through public WPF APIs. This contract owns
only its immutable retained representation and integration into Thing/Registry.
Producer-independent decoding is required for restart and historical recovery.
A syntactically valid retained record cannot replace live declaration rebuilding,
current trust/reader/source guards or reviewed target selection.

## Exact retained record

Profiles.ReadDeclarationCodec.encode/2 takes a checked native
ExternalReadDeclaration and an exact artifact_digest (lower hex64). It rebuilds
the original through its public to_map/5, encodes its data with public canonical
core JSON and verifies the existing declaration SHA. Reconstruct every typed
envelope/profile/definition frame from the rechecked original bytes through
AuthoringObject.new/2, attach the exact selected references and compute the
owning ExternalArtifact.identity/1 manifest. Require its digest to equal the
supplied artifact_digest; a wrong raw-closure assertion refuses
external_artifact_mismatch. This does not establish actor ownership of those
bytes. Success returns exactly
format wotex-home.retained-read-declaration@1, artifact_digest,
declaration_document and declaration_sha256. The last two are exact canonical
data bytes and their owning prefix-qualified declaration identity. Encoding
needs the installed producer; missing producer refuses profiles_producer_unavailable.

ReadDeclarationCodec.decode/1 accepts that exact non-struct record. Document
is nonempty UTF-8 JSON, at most 65536 bytes. Reject repeated object names before
building maps, depth over eight, over 4096 total value nodes, arrays/objects over
256 members, strings or object keys over 4096 bytes and non-JSON native values.
Document SHA is SHA-256 of UTF-8 wotex-home.external-read-declaration@1, newline
and these exact bytes. Never reserialize or reinterpret retained bytes to make
them match another identity. The decoded data must have exactly the nineteen
fields from the owning declaration contract and its format. Validate Home IDs,
risk ordinary/sensitive, freshness integer 1..86400000 ms, exactly operations
[read], exact URI/version/lower-hex references, four data/consumer/closure digest
fields and the three exact producer archive digests, or the distinct closed
five-field compiled-runtime identity from the [installed runtime successor](installed-profile-runtime-v1.md).
Historical decoding preserves each representation without current runtime lookup.
Integer consumer constraints
are exactly min/max signed-64 with min ≤ max and unit a non-struct JSON object;
Boolean unit/constraints are null and source value_schema.type boolean;
external constraints null and unit null or a JSON object. Value_schema is a
non-struct JSON object. Unit/schema are retained opaque bounded producer output;
decoding does not implement WPF unit algebra, DataSchema validation or source
authenticity. Future live admission must rebuild the complete original.

Success is exactly data and the retained record. Unknown/native/duplicate fields,
wrong SHA/format/IDs/references/nulls/types/operations refuse
invalid_read_declaration_record; resource excess refuses external_profile_limit.
Neither bytes nor hashes are rewritten. Different bytes with a different valid
SHA are different retained records, not inferred canonical producer output.

## Shared Thing and capability representation

**GS-01 — Read capability.** Semantics.ReadCapability.new/1 decodes a retained
record and returns a native struct with exactly thing_id, role, key, value_kind,
unit, operations, risk_class, profile_ref, evidence_ref, freshness_ms, constraints
and record. Role is EnvironmentalSensor; key is declaration.capability_key;
profile_ref is external: followed by artifact_digest. Other metadata comes
unchanged from the declaration; record is the exact original retained record.
It exposes supports?/2 only for read. Malformed native structs, extra fields or
forged derived fields cannot survive Registry encoding/reconstruction. There is
no accepts?/2 or report coercion: the later external observation owner must use
the exact checked value/declaration and current source selection. Existing
Capability.accepts?/2 and Value.new/1 are not broadened.

**GS-02 — One Thing namespace.** Thing.new/1 keeps exactly id, role, profile_ref
and capabilities. EnvironmentalSensor requires profile_ref external:hex64 and
one to 32 retained read records with unique capability keys. All records must
derive the same thing_id, role and profile_ref as the Thing. No mixing legacy
and external records and no implicit baseline channel is allowed. Other roles
keep their existing capability grammar and required baseline. Native Thing
still indexes capabilities by key. Thing.capability/2 returns the declared
native capability or error; absence never receives a default.

Registry.encode_thing/1 reconstructs every native capability and the Thing,
serializes the existing closed outer JSON form and retains its 65536-byte total
ceiling. Generic capability entries are the original retained records, sorted
by capability key. Legacy serialization/order stays unchanged. decode_thing/1
reconstructs and requires exact equality with this Registry encoding. Damaged
documents refuse corrupt_enrollment. A forged native map key or capability
field cannot change the serialized Thing. No new SQLite tables, schema version,
dependencies, grants or producer fallback are introduced by this slice.

## Failure, history and current use

Pure construction is repeatable and has no clock or revision. Registry decoding
works with the producer absent and preserves record bytes/hashes for quarantine
and historical inspection. Current use must still resolve the single Store's
exact current external selection, approved trust author/policy, accepted meaning,
actor grants, actual host-held source/capture, immutable bytes and qualification.
Legacy observation/write paths cannot accept ReadCapability as Capability or
promote unknown generic data to their value types. Unsupported runtime consumers
remain unavailable until their owning reviewed transition is implemented.

**GS-03 — Fail closed at legacy current-use seams.** ProfileGuard.current/3
must refuse EnvironmentalSensor with profile_selection_unavailable until the
owning external-selection transition is implemented. It cannot use the legacy
compiled-profile fallback, even when no v1 portable profile matches the label.
Legacy FactReadModel projection returns unsupported_fact for ReadCapability;
it cannot return a mismatched successful capability as if it were a fact map.
The existing Thing inspection may expose retained declaration metadata, but its
capability entries have profile_unavailable freshness, no current value and zero
remaining freshness. No new read status token or qualification is manufactured.

The trusted Store fixture enrollment seam may round-trip a generic Thing as
declaration metadata; that does not establish reviewed external enrollment or
make legacy profile guards accept an external digest. No fixture grants wider
authority or manufactures a current observation. Generic target selection and
external report/Store-clock admission are the next durable owners, not effects
of this constructor.

## Acceptance and implementation entry

Freeze retained records and two-channel Thing encodings from independent
declaration vectors before code. Keep actual archival bytes as the oracle;
source hash verification alone does not establish live producer correspondence.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| GS-T1 | 01/02 | Both independent quantities and a multi-channel Thing round-trip exact frozen records/documents through public preparation and Registry. Wrong identity, reordered raw document or write support fails. | Software |
| GS-T2 | 01/02 | Extra/duplicate/deep/big fields, hashes, native derived fields/map keys, crossed Thing/artifact, mixed legacy records, duplicate keys, empty/33-channel Thing. Any accepted forged or widened declaration fails. | Software |
| GS-T3 | 02/03 | Actual Store fixture enrollment/restart and producer-free Registry decoding retain metadata; current profile/fact/observation/mutation seams refuse these capabilities. New report, grant or current authority fails. | Software |
| GS-T4 | 01/02 | Existing Light/SmokeDetector Registry, semantic value and observation tests remain unchanged; boundary errors and total Thing/document limits execute. Any legacy format drift fails. | Software |
