# Durable external profile inspection

Version: 0.1.3. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-08/H18-T11–T12 and retained lifecycle H18-07.
Implementation: checked pure reader selection, original/result/receipt codecs
and explicit typed-byte preparation implemented; schema 32 durable originals,
current-basis transaction and encrypted quarantine recovery implemented; operator
routes and later trust/selection remain planned. Evidence: independent vectors,
exact archive and actual Store/recovery checks; no observation/physical claim.

## Result and boundaries

An authenticated operator inspects an explicitly selected actor-owned v2
envelope and separately retained profile/definition bytes against the host's
current reader and capture selection. One immutable original records its checked
read-only envelope result. This is inert inspection, not trust approval, source
review, enrollment, target selection, canonical observation, grant or device
qualification. It permits independently exported profiles without requiring a
manual authoring candidate. Existing v1 operations and schema 29–31 authoring
imports/candidates/reviews keep their namespaces and meanings.

Authority.inspect_external_profile/3 forwards to the single Store. A stateless
writer uses only its borrowed connection. The pure
[ExternalEnvelope](device-profile-mappings-v2.md) consumes public WPF parsing,
Compiler.references/3, Compiler.compile/4 and Projection.to_map/2; no substitute
reader, closure walker or unit algebra is permitted. The
[exact value component](external-values-v1.md) remains separate. No module, URI,
directory search, provider, transport or private credential is selected by data.

## Trusted reader selection

Profiles.ReaderSelection.new/3 accepts installed, capture and reader_limits,
all explicitly supplied by the host. Installed is exactly bindings, contracts,
home_contracts and producer as defined by the v2 envelope. Bindings is a nonempty
proper list ≤32, strictly sorted/unique by registration ID/version and unique
by ID. Every registration revalidates through public WPF Binding.to_map/2.
Contracts and home_contracts are proper lists ≤32 of exact sorted unique
references (absolute URI ≤256 bytes, bounded x.y.z version, lower-hex64 SHA),
unique by ID. Producer has exactly the three lower-hex64 archive identities
core_archive_sha256, runtime_archive_sha256 and profiles_archive_sha256.
Archive identities are host assertions; new/3 does not install or inspect files.

Capture is a non-null public WPF capture exactly binding, capture_epoch, digest
and fields. Its exact binding reference must select one of the supplied installed
registrations; public Capture.to_map/3 verifies representation and digest under
that registration. Capture fields are actual host-held input, never guessed from
a profile. The reader limits are the eight explicit v2 fields, positive integers
bounded by max_bytes 262144, max_depth 8, max_nodes 4096, channels/definitions/
bindings/dependencies 32 and max_numeric_digits 64. No defaults are filled.

Before producer construction, the complete input record is bounded through public
core JSON.encode/2 by reader.max_bytes/depth/nodes, collection 32 and string 4096.
Unknown fields, structs, malformed ordering/references/capture or native values
refuse invalid_external_reader. Resource excess refuses external_profile_limit;
absent public functions profiles_producer_unavailable. An uninstalled capture
binding refuses invalid_external_reader. There is no fallback to an absent
capture or earlier cohort.

Native ReaderSelection has exactly inputs and data plus its struct tag. Inputs
contains exactly installed, capture and reader_limits. Data contains exactly
format wotex-home.external-reader@1, basis_sha256, producer, reader_limits,
home_contracts, bindings (checked registration references), contracts,
capture_digest and capture_epoch. Basis_sha256 hashes UTF-8
wotex-home.external-reader@1, newline and public canonical core JSON of the
complete checked inputs, including actual capture fields and full registration
mechanics. Data contains no capture fields, selector schemas or credentials.
to_map/1 re-exports from retained inputs and compares every native field before
returning the summary; extra/forged fields refuse invalid_external_reader.
The value binds supplied correspondence, not current trust or device freshness.

Store's trusted external_reader option is null by default and otherwise this
exact checked native selection. Boot checks native shape without needing an
optional producer. New inspection revalidates it before reading payloads and
again inside the transaction. The host replaces the selection when capture,
reader limits, registrations, accepted contracts or archive cohort changes.
No operator/model input can install that selection.

## Original input and identity

Input is exactly authority_epoch, operation_id, expected_revision and inspection.
Epoch is positive signed-64, revision nonnegative signed-64 and operation a Home
ID. Inspection is exactly reader_basis_sha256, envelope_ref, profile and definitions.
Basis is lower hex64 and must match the host's current ReaderSelection summary.
Envelope_ref is exactly object_digest/first_revision, naming actor-owned kind
envelope. Profile is a document record exactly reference and object_ref, naming
actor-owned kind profile. Definitions is a proper sorted list ≤32 of the same
document records naming kind definition; order is reference ID/version, unique
by ID and complete object digest. First revisions are positive signed-64 and
must match the retained first import at or before expected_revision. No draft,
bundle, unowned filesystem orphan or v1 artifact can alias these kinds.

Profiles.ExternalInspection encodes the canonical ordered input:
`["wotex-home.external-inspection.v1", [epoch, operation, expected_revision,
[reader_basis_sha256, envelope_handle, profile_document, [definition, ...]]]]`.
Handle is [object_digest, first_revision]; reference [id, version, sha256];
document [reference, handle]. Decode admits only canonical array-only JSON,
signed-64 integers, null/booleans/strings, depth eight, 4096 nodes, 256 array
members and strings ≤4096 bytes. Input ≤16384 bytes. Canonical decode/encode
equality is required. Unknown/native/duplicate/unsorted/malformed fields refuse
invalid_external_inspection; an over-budget list stops at its 33rd cell and
refuses external_profile_limit without scanning an oversized tail.

## Durable transition

Before the Store writer, Profiles.InspectionPreparation.build/3 accepts the
complete decoded original input, read records and a checked ReaderSelection.
It revalidates the original encoding and current reader summary, requiring exact
reader_basis_sha256. Read records are a proper sorted unique list by complete
object digest, ≤34 entries, exactly object/payload/first_revision as returned
by the authenticated typed reader. They contain exactly the requested distinct
envelope/profile/definition handles, with no unrelated record. Every summary
has exactly kind, object_digest, payload_sha256 and payload_bytes; actual payload
and reconstructible tagged frame identities must match it and the requested
kind/first revision. First revision must not exceed the original CAS revision.
This pure correspondence check grants no actor ownership; only Store can select
those records from the current principal's retained import rows.

Before hashing/copying, per payload ≤65536 and complete selected frame bytes
≤329108 (256-KiB documents + 64-KiB envelope + 34 frame headers). The existing
raw profile/definition total ≤262144 still applies. Excess is
external_profile_limit; malformed/missing/extra/forged read records or wrong
kind are invalid_external_inspection; changed first revision is
stale_external_reference; changed reader basis stale_external_basis. It derives
only the exact supplied reference/raw SHA/bytes records and calls the public
Home envelope boundary under the checked reader inputs. Success is the result
record above, with current reader/capture identities and checked envelope summary.
It publishes no byte, reads no path and creates no receipt or revision. The Store
must independently apply EI-01–04 before making that result durable.

**EI-01 — Original before current work.** Authenticate current profile:manage
and validate retained import/inspection history before original lookup. The
original key is (principal, epoch, operation) in this separate namespace. Exact
replay returns the retained receipt before CAS, current selection, byte access
or producer work. Changed input refuses external_inspection_conflict. Status
reads only that current actor's original; revoked credentials cannot read/replay.
Original lookup never renews capture, approval or active authority.

**EI-02 — Resolve complete owned closure.** New work requires current authority
epoch/global revision CAS and active controller outside maintenance. Before byte
access check every selected import's actor ownership, kind and exact first
revision. Missing/unowned references return not_found; wrong kind/revision refuses
stale_external_reference. Null selected reader refuses external_reader_unavailable;
changed selected basis refuses stale_external_basis. Validate all complete raw
identities through sequential verified Custody object leases, released on every
path. Retained import references protect the entire closure from collection.
Missing/tampered/unsafe bytes refuse authoring_object_unavailable; unavailable
custody profile_custody_unavailable. Never search a raw variant by semantic SHA.

Profile/definition payloads are each ≤65536 bytes and their total ≤262144 before
producer copies; envelope ≤65536 separately. The pure envelope checks exact
semantic/raw identities, selected reachable closure, installed mechanics and
host capture, then returns its safe eight-field inspection summary. A wrong
envelope-to-document join, stale capture/profile or unreachable definition cannot
be retained as successful inspection. No derived bytes are staged by this API.

**EI-03 — Atomic original.** One transaction rechecks actor permission, epoch,
CAS/maintenance, every import reference and the current checked reader selection.
Append external_profile_inspected with entity_id operation_id and retain canonical
input/result/receipt. SQLite failure rolls back rows, journal and revision. No
approval, target, observation, grant, qualification, rule or effect queue changes.

Receipt is exactly authority_epoch, operation_id, revision, input_sha256,
reader_basis_sha256, result_sha256, capture_digest, envelope_sha256 and
home_consumption matched, encoded in that order. Result encodes
["wotex-home.external-inspection-result@1", [reader_basis_sha256, capture_digest],
envelope_summary]. Envelope summary uses the existing ordered fields format,
envelope_sha256, document_identities, projection_sha256, consumption_sha256,
home_contracts, exclusions and producer. Document identities are [reference,
raw_sha256], profile first and definitions in reference order. Contract entries
are [channel_id, reference], exclusions [channel_id, reason], producer the three
archive SHAs in core/runtime/profiles order. It retains no payload/capture text.
Result ≤32768 bytes and receipt ≤4096. All result and input hashes are raw SHA-256
of their exact retained bytes, independently reproducible without producers.

## Retention, corruption and recovery

**EI-04 — History is bounded metadata.** Schema 32 adds
profile_external_inspections with exactly principal_id, authority_epoch,
operation_id, input_document, result_document, receipt_document and revision.
Primary key is original identity; principal and unique revision reference their
existing rows/journal. The actual predecessor is schema 31; migration adds only this new table. Supported predecessors validate before migration;
the empty new table grants no inspection or active permission. Retain ≤1024
originals, ≤4 MiB input and ≤4 MiB result aggregate. Capacity refuses
external_inspection_capacity before work and again at commit; exact replay remains.

Integrity validates canonical encodings, exact receipt/input/result SHA and
identity joins, input CAS = revision−1, actor/epoch/journal links, every owned
first-import reference, exact result document/reference/raw SHA correspondence
with retained imports, envelope raw SHA, bounds and orphan inspection events.
Historical validation needs no producer or available files. Inconsistent history
refuses corrupt_external_inspections and fences writes. It cannot prove physical
capture/source truth or renew the historical basis.

Inclusive WOHBK3 already retains the import-owned typed inputs. Database-only
backup declares their bytes absent. Snapshot/normalized transfer commitments
include the actual new table, with a declared empty table for older schemas.
Restore preserves originals in quarantine, never fetches bytes, resumes providers
or selects a profile. Later trust/selection/observation use must revalidate the
complete actual current basis and grants under its own contract. There is no
pending provider operation, cancellation or effect replay in inspection.

## Implementation entry and acceptance

Independent reader/input/result/receipt identities are frozen in
test/fixtures/profiles/external-inspections.json; the closed input schema is
priv/profiles/external-inspection.schema.json. Freeze these before their code. First implement checked reader selection
and producer-independent original encodings; then add the actual Store writer,
migration/recovery and framed operator routes under their separate boundary.
Use the exact three-archive pure and actual Store consumers.

| Case | Requirements | Setup and falsifier | Level |
| --- | --- | --- | --- |
| EI-T1 | 01–03 | Independent temperature and unfamiliar density imported as explicit typed documents; exact reader/capture/closure and immutable original receipt. Wrong join or active authority fails. | Pure/software |
| EI-T2 | 01 | Exact retry after missing files, absent reader/producer and restart; changed input and revoked actor. Recomputed/changed original or widened read fails. | Software |
| EI-T3 | 02/03 | Other actor, wrong kind/first revision, stale CAS/epoch/maintenance/reader/capture, wrong raw variant and unreachable/oversized closure. Read before ownership, accepted stale input or lease leak fails. | Pure/software |
| EI-T4 | 03/04 | SQL-trigger failure, deep reference/raw SHA/receipt/journal tampering and orphan event. Partial commit or writable corruption fails. | Software |
| EI-T5 | 04 | Actual predecessor migration with retained imports/reviews, exact quotas and encrypted inclusive/database-only quarantine recovery. Fabricated current authority or lost original history fails. | Software |

Independent Python frame/ordered-array hashes and literal document/coordinate
fixtures are the oracle. Compilation and software tests do not qualify hardware
or make unreviewed meanings eligible for canonical observation or automation.

The [software record](../provenance/external-inspections-2026-10.md) binds the
implemented pure components and preserves the remaining durable obligations.

The [durable software record](../provenance/external-inspection-store-2026-10.md)
binds schema 32 and the executed actual Store cases.
