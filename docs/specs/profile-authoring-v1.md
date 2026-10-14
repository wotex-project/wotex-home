# Consumer-owned profile authoring

Version: 0.1.7. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18, H18-09/H18-T13–H18-T18.
Implementation: tagged private custody and authenticated inert staging implemented;
durable object ownership/original imports, actor-owned reads/source passages
and pure installed contract/manual mechanics and independent fixture comparison
implemented; durable candidate assessment/generation operation planned.
Evidence: independent frame/import/authoring/fixture identities,
focused actual-root/Store tests and a fresh three-archive pure consumer.

## Result, location and dependencies

A Home operator can manually author or optionally ask a configured AI to draft
a supported model mapping against the exact installed WoTEx contract. Both
paths finalize and validate through the same producer and remain proposals.
No separate definitions repository, shared catalogue, cloud or AI is required.

Public model templates live in Home's existing priv/profiles layout, with
independent vectors in test/support/profiles. These are proposed v2 assets,
not a change to current v1 fixtures. Drafts, supplied documents, installation
identities and approval history live in Home's private custody. No runtime
profile loader reads Markdown, scans a neighboring repository or fetches a URL.

Implemented WoTEx WPF.01–03 in owned source own the closed mapping language, pure compiler and
authoring contract/finalizer/diagnostics. WPF.03 exports supported schemas,
bindings/contracts and limits, computes local-reference hashes without guessing
semantics, and reports deterministic compatibility. Public APIs are Contract.export/4,
Draft.finalize/2 and Validation.check/3, with checked projections for their native
values. Exact archive evidence is retained by the producer. Home's authenticated/
candidate assessment/generation operation and application dependency adoption
remain planned; when absent, these producer-dependent operations report
unavailable and use no local substitute. Durable object import below is implemented.
The [v2 envelope](device-profile-mappings-v2.md) joins finalized mappings to
Home consumption contracts. [WOH.18](WOH.18-portable-profile-admission.md) owns
import, trust, selection, retention and recovery. Existing v1 behavior is unchanged.

## Inputs, identity and limits

An authenticated authoring request contains exactly mode, contract_digest,
base_draft_ref, source_refs, fixture_refs, instruction and limits. Mode is manual
or generated. Contract_digest is lower hex64 over the trusted host-exported
WPF.03 contract, not a contract supplied by the model. Base_draft_ref is null
or a private immutable digest/revision handle owned by this actor. Source_refs
and fixture_refs are explicit unique private custody handles; no URI is fetched.
Instruction is bounded UTF-8 text, never executable code or an authority grant.
Unknown/duplicate fields reject. Actor, authority epoch and current installed
binding/producer/policy basis come from Authority, not these request fields.

| Resource | First Home ceiling |
| --- | --- |
| Mapping/envelope/individual definition | 64 KiB each; depth eight, 4096 JSON nodes |
| Complete generated draft/finalized raw closure | 256 KiB; 32 channels/definitions/dependencies, per v2 |
| Instruction | 4096 UTF-8 bytes, no NUL/control characters except newline/tab |
| Selected source passages | 32, each ≤4096 UTF-8 bytes; aggregate ≤128 KiB |
| Fixture reports | 32; each obeys WRT.06 C02 bounds; aggregate input ≤256 KiB |
| Diagnostics | 64 and 24 KiB encoded; truncate without reporting success |
| Field evidence / unresolved paths | 256 evidence entries / 64 unresolved paths |
| Generation attempts | 1–3 explicitly requested; no hidden provider retry |
| Per-attempt / total deadline | Required positive monotonic milliseconds, ≤30000 / ≤120000; attempts and repair consume the same total |
| Pending authoring operations | ≤16 host-wide and one executing generation per operator |

All limits are explicit and may narrow these ceilings. Authoring shares WOH.18
custody's existing 128-object, 4-MiB and 32-lease quotas; no reserve bypass or
automatic deletion of selected/history/backup objects. Source originals need
not enter a model: only approved bounded passages do. Request refusal on
capacity changes neither a draft nor an active profile. Deadline is owned by
the host; restart retires the executing attempt rather than extending time.
Source/draft custody objects need a separately closed successor encoding;
they are not parsed as v1 profile artifacts or admitted by relaxing that codec.
Set max_check_steps explicitly within WPF.03's 1000000-step ceiling; all
authoring schema/finalizer counts share that budget and refuse on exhaustion;
WPF.01/02 work retains its separately enforced reader/numeric limits.

The retained candidate record binds actor/authority epoch, immutable request,
base draft revision, original draft bytes, exact contract/installed-basis digests,
sources/fixtures, finalized bytes/report, field evidence and unresolved paths.
It also records generation adapter/build identity when applicable. These are
conceptual successor obligations, not a declared existing SQLite schema/API.
Freeze the closed record encoding and original-operation receipt/migration
contract before adding a durable writer; re-use the one Store authority.

Field evidence entries contain exactly instance_path, source_ref and locator.
Paths use RFC 6901 over known draft fields, ≤512 bytes; source_ref names one
selected immutable source; locator is inert text ≤256 bytes. Unresolved paths
are unique/sorted bounded pointers. Source attribution proves neither truth nor
qualification; it makes a proposed model/firmware/selector/scale reviewable.
Required facts lacking evidence or with conflicting source claims block review
completion. They never become guessed zeroes, units or selectors.

## Requirements and transitions

### Private typed custody objects

Before the durable authoring writer, the existing private Custody owns immutable
tagged objects alongside its unchanged plain v1 profile files. Each tagged file
contains exactly ASCII WOHA (four bytes), version 1 (one byte), kind tag (one
byte), payload length (unsigned big-endian 32 bits), raw SHA-256 of payload
(32 bytes) and that exact payload. No trailing bytes or unknown versions/tags
are accepted. The complete file digest is its custody handle; payload_sha256
separately identifies original bytes. Kind is part of the file digest, so the
same bytes under source/draft are different objects and cannot alias an approval.

| Tag / kind | Nonempty payload byte ceiling |
| --- | --- |
| 1 source | 262144 |
| 2 draft | 262144 |
| 3 bundle | 262144 |
| 4 fixture | 65536 |
| 5 contract | 262144 |
| 6 envelope | 65536 |
| 7 profile | 65536 |
| 8 definition | 65536 |

`Profiles.AuthoringObject.new/2` constructs the frame from kind and original
bytes; parse/1 verifies exact length, kind bound and payload digest. Its native
fields are exactly bytes (complete frame), digest, kind, payload and
payload_sha256. summary/1 revalidates all fields and returns exactly kind,
object_digest, payload_sha256 and payload_bytes. Invalid native/frame input
returns invalid_authoring_object. This checks storage representation, never
document compatibility, attribution, review, capture or physical truth.

`Custody.stage_object/3`, read_object/2 and lease_object/2 use that parser and the
same pinned root, non-replacing synchronized publication, descriptor checks and
monitored leases as v1. Plain v1 and tagged reads are separate APIs. A tagged
object cannot be read/selected/exported as a v1 Artifact. File names remain the
complete-file digest plus .json; the suffix is an opaque custody convention,
not a claim that a tagged frame is JSON. Inventory counts frame bytes, including
the 42-byte header, against the same 128-object/4-MiB/32-lease ceilings. Duplicate
publication consumes no new quota. Crash orphans continue consuming quota.

Collection validates either historical v1 syntax or an exact tagged frame,
protects both lease kinds and the Store-supplied retained digest set, and never
parses a tagged payload as active data. A changed checksum/length, symlink,
permission, descriptor, root or publication identity fails closed. Maximum file
and temporary-file access is 262186 bytes; v1 parsing still enforces 32768 bytes.
Store-only export_objects/2 accepts at most 128 sorted unique complete summary
records and returns those exact summaries plus frame bytes after all objects
verify; caller/field/digest/size mismatch refuses without partial output.
Existing export_many/2 and its v1 archive encoding retain their original shape.

`Authority.stage_authoring_object/4` authenticates current profile:manage through
the single Store before staging, and returns only the summary. It does not start
an authoring operation or establish actor ownership of a source reference.
Authenticated durable reference ownership, retained journal rows and backup
packaging belong to the schema 29 writer below; generic custody alone must not
claim them. No new SQLite version is required for this
storage component. Root-file tests exercise actual quotas, publication, leases,
collection, checksum corruption, wrong API/type, caller ownership and restart;
independent binary/digest vectors precede code.
The [custody software record](../provenance/authoring-custody-2026-10.md) retains
the implemented source and executed root/Store checks; durable object ownership
has its separate schema 29 acceptance obligations below.

**H18A-01 — Contract and authoring.** Authority exports the exact installed
WPF.03 contract narrowed to Home's v2 support and current operator scope.
The consumer restriction layer is an explicit review basis, not a rewritten
producer schema. Exported bindings contain grammar/mechanics, no private routes,
capture values or credentials. Manual tools receive the same contract as AI.
Provider schemas can assist generation; final checks always use WPF.03 plus
Home's current envelope/consumption policy. No copying validators/unit algebra.

### Pure installed contract and manual mechanics assessment

Before adding candidate journal operations, Profiles.AuthoringContract.export/2
accepts the host-selected installed record and explicit authoring limits.
Installed is exactly bindings, contracts, home_contracts and producer, using the
same native boundary as ExternalEnvelope: at most 32 bindings/contracts, sorted
unique Home contract references and exactly core_archive_sha256,
runtime_archive_sha256 and profiles_archive_sha256 lower-hex64 producer identities.
These identities are assertions supplied by the host's exact artifact loader;
this pure function neither discovers archives nor trusts candidate identities.
It has no credential, network, Store, device or filesystem port.

Limits contain exactly reader, max_bundle_bytes, max_diagnostics,
max_report_bytes and max_check_steps. Reader contains all eight explicit limits
from the v2 inspection boundary and may only narrow its ceilings. The other
positive integer ceilings are respectively 262144, 64, 24576 and 1000000.
Missing/defaulted/unknown/struct fields and improper or oversized lists refuse
invalid_authoring_contract; a selected numeric limit above a Home ceiling refuses
authoring_limit. Export calls the public installed Artifacts.current/0,
Contract.export/4, Contract.encode/1 and Contract.identity/1. It never copies a
producer schema or manufactures an installed grammar. Encoded contract bytes
must fit the 262144-byte contract custody ceiling.

Native contract fields are exactly bytes, contract (producer native),
contract_sha256, basis_sha256 and inputs (exact installed and limits).
AuthoringContract.to_map/1 re-exports and compares every native field before
returning the closed summary: format wotex-home.authoring-contract@1,
contract_sha256, contract_raw_sha256, producer, home_contracts, limits,
consumption_policy wotex-home.read-only-profile@1 and basis_sha256.
basis_sha256 is SHA-256 of UTF-8 wotex-home.authoring-contract-basis@1 followed
by newline and the public Wotex.JSON.encode/1 canonical encoding of the seven
other summary fields. Contract_sha256 is the separate WPF contract identity;
raw_sha256 identifies its exact exported bytes. The policy string records the
Home restriction for later envelope admission; it does not rewrite the WPF
grammar, which can describe mechanics Home does not consume. Forged native
input refuses invalid_authoring_contract. Changing selected archive identity,
Home contract or any limit changes the Home basis even if the WPF identity stays
the same. Caller-supplied identifiers cannot substitute for that current basis.

Profiles.AuthoringAssessment.assess/3 takes original draft bytes, a checked Home
contract and either null or the explicit WPF.01 binding capture supplied by the
host (binding, capture_epoch, fields and digest; typed field values remain under
the public producer's capture grammar). Before finalization, a non-null native
capture is bounded through public Wotex.JSON.encode/2 by the selected reader
byte/depth/node limits, 32 members per collection and 256 bytes per string.
Structs or a non-map capture refuse invalid_authoring_assessment. This preliminary
bound establishes no capture match; the producer validates correspondence when
it reaches capture checking.
Draft must be a nonempty binary no larger than the selected max_bundle_bytes.
Draft.finalize/2 owns parsing, schema/closure checks and local hash derivation.
An invalid producer ValidationReport produces phase finalize, null bundle bytes
and an invalid assessment. A producer Finalized must have exactly its four
documented fields plus struct tag, prove the original draft SHA, checked WPF
contract identity and SHA/size of its nonempty bundle bytes. Then Home calls
Validation.check/3 and ValidationReport.to_map/2; the checked report must identify
that exact bundle and contract. No producer-private parser/helper is invoked.
Capture matching remains separate from compatibility; absent capture is
not_supplied and a mismatching capture is never marked matched.

Native assessment fields are exactly draft_bytes, bundle_bytes (binary or null),
contract, capture and data. The data summary contains exactly format
wotex-home.authoring-mechanics@1, basis_sha256, draft_sha256, bundle_sha256
(lower-hex64 or null), phase (finalize or validate), disposition (compatible or
invalid), capture_status, report (checked safe producer report), home_consumption
not_assessed, source_review not_assessed and fixture_status not_supplied.
It includes no draft, source, capture values, provider output or private selector
text. Truncated diagnostics cannot become compatible. This stage establishes
only generic mechanics; independent fixture comparison, source review, current
Home envelope admission and durable candidate history remain required separately.

AuthoringAssessment.to_map/2 takes the native value and current checked Home
contract, refuses stale_authoring_basis if the bases differ, and recomputes the
assessment from its retained original inputs before exposing data. Changed
native draft/bundle/report/capture or extra fields refuse
invalid_authoring_assessment. The pure value grants no review, enrollment,
ownership, selection or physical qualification. Restart simply loses an
unretained pure value; durable candidate behavior is a subsequent contract.

Missing public producer functions refuse profiles_producer_unavailable, with
no validator fallback. Producer input_limit, numeric_limit and report_limit
refuse authoring_limit; other producer API errors refuse
invalid_authoring_contract or invalid_authoring_assessment at the affected
boundary. Public core byte/depth/node/collection/string limit_exceeded errors
also map to authoring_limit, including the complete encoded capture byte count.
Candidate syntax/semantic failures returned as checked reports remain
successful API calls with disposition invalid. Errors and safe diagnostics never
echo candidate fragments. Test a real three-archive consumer with no Home app
or routines package: both independently authored quantities, frozen original
draft/bundle identities, capture absent/matched/mismatch, invalid selectors,
duplicate JSON fields, diagnostic bounds, stale archives/limits, forged native
values and no leaked candidate/capture text. A separate locked consumer verifies
typed unavailable behavior when the public package is absent.

### Durable object import and ownership

Schema 29 adds profile_authoring_objects and profile_authoring_object_operations
to the single Store. It migrates prior supported schemas through their existing
validators and creates empty tables; old data gains no ownership or authoring
permission. Object rows contain exactly principal_id, object_digest, kind,
payload_sha256, payload_bytes and first_revision. The primary key is
(principal_id, object_digest); first_revision points to the original import's
authority_journal revision. Different authors may own the same verified bytes,
but an opaque digest alone does not authorize import or source access.

Operation rows contain exactly principal_id, authority_epoch, operation_id,
input_document, receipt_document and revision. Their primary key is the original
(principal, epoch, operation), with a unique journal revision. Input contains
exactly authority_epoch (positive signed-64), operation_id (Home ID),
expected_revision (nonnegative signed-64) and object (the exact four-field tagged
summary). The canonical encoding is an ordered JSON array:
`["wotex-home.authoring-import.v1", [epoch, operation, expected_revision,
[kind, object_digest, payload_sha256, payload_bytes]]]`, at most 4096 bytes.
Duplicate fields/native structs, unsupported summaries or noncanonical input
refuse invalid_authoring_import. A native map is encoded before Store use.

`Authority.import_authoring_object/4` and Store.import_authoring_object/4 take
credential, input and the original payload bytes. Authentication with current
profile:manage and original lookup precede payload publication, CAS or byte
availability. Exact original replay returns its retained receipt; changed input
under the original key refuses authoring_operation_conflict. A new original must
prove possession of bytes by reconstructing the exact kind/frame/summary, pass
current authority epoch and global revision CAS, and have active host authority
outside maintenance. It stages through the configured Custody and holds a typed
lease through the commit. A staging orphan after a refused/failed transaction
remains inert, unowned and quota-counted; it conveys no ownership.

One transaction rechecks authentication/current epoch/revision/maintenance,
records first ownership if absent, appends authoring_object_imported to the
authority journal with entity_id equal to operation_id, and retains the original
input/receipt. An existing ownership row must have the identical kind/payload
identity/size and preserves first_revision; a new original still gets its own
immutable receipt. At most 1024 operations/ownership links, 128 unique retained
object digests and 4 MiB of unique complete frames are allowed. Physical custody
also enforces its shared v1/tagged quotas. Capacity, stale basis or permission
refusal rolls back every SQLite row and revision; no source ownership is inferred
from file presence. Successful receipt is exactly authority_epoch, operation_id,
object, first_revision and revision. Its retained encoding is the ordered JSON
array [canonical_import_document_with_expected_revision_zero, first_revision,
revision]; canonical decode/encode equality is required. The zero is a fixed
receipt serialization field, not a renewed CAS or authorization. Journal/receipt/object links are validated
bidirectionally, including orphan events, duplicate/conflicting identities and
historical first-import ordering. Corruption fails Store closed.

`authoring_object_status/4` authenticates the current actor and reads its original
epoch/operation only, without payload access or renewed permission. It returns
the retained receipt or not_found; permission revocation blocks reads/replays.
It does not declare bytes available, source truth or approval. Store collection
protects every retained object digest plus existing v1 commitments/leases,
using the 128-entry collection seam; a filesystem-only orphan is collectable.

`Authority.read_authoring_object/3` and Store.read_authoring_object/3 take the
current actor credential and complete tagged object digest. The single Store
authenticates current profile:manage, validates retained import history and
selects only that principal's ownership row before contacting Custody. Invalid
digest refuses invalid_authoring_import; an unowned/missing digest returns
not_found even if another principal owns it or a matching filesystem orphan
exists. There is no alternate lookup by payload hash or source URI. A valid
ownership row obtains a typed lease and compares the actual object's full summary
to the immutable row before returning exactly object (four-field summary),
payload (original binary bytes) and first_revision. No complete frame or bearer
is returned. The lease is released on every outcome. Missing/changed/unsafe
bytes refuse authoring_object_unavailable; unavailable custody refuses
profile_custody_unavailable. A summary mismatch is also
authoring_object_unavailable and does not rewrite historical ownership.
Permission revocation refuses unauthorized even for a previously read object;
reads do not change any revision, current approval or first-import identity.
Reads may retrieve historical inert bytes during maintenance, but restored
quarantine cannot gain actor authorization. Real Store tests must show ownership
is checked before byte access, independent actor refusal, orphan refusal,
missing/tampered bytes, wrong digest, revocation and exact lease/revision retention.

### Explicit bounded source passages

`Authority.authoring_source_passages/3` and Store.authoring_source_passages/3
take the current author credential and a nonempty, proper list of at most 32
selectors. Each is exactly source_ref (complete tagged digest), offset
(nonnegative integer byte offset ≤262144) and length (positive integer bytes
≤4096). Selectors must be strictly sorted/unique by (source_ref, offset, length);
the total selected length is ≤131072. Unknown/native struct fields, malformed
digests, improper lists, duplicate/unsorted selectors, nonintegers and empty
requests refuse invalid_source_passage; counts, lengths or aggregate bytes
above ceilings refuse authoring_limit before authentication or payload reads.
List inspection stops at the 33rd cons cell with authoring_limit; it does not
scan an over-budget tail to determine its eventual properness.
Offsets and lengths are byte indices, with no clipping, decoding, normalization,
URI fetching, document extraction or inferred passage selection.

Store authenticates profile:manage once, validates the object journal and checks
every distinct source's actor-owned immutable summary before reading any bytes.
Unowned references return not_found; any owned non-source kind refuses
invalid_authoring_source. Only after the complete set passes does Store read
verified leased objects through Custody. Actual missing/corrupt/unsafe bytes and
unavailable custody use the same outcomes as read_authoring_object. Nothing is
returned until every selected passage succeeds; every lease is released.

`Profiles.SourcePassages.select/2` is the pure projection over those selectors
and the exact verified read records. The source table is a proper sorted unique
list of at most 32 records, each exactly object, payload and first_revision as
returned by the owned reader. It contains exactly the requested distinct
digests; each source summary is kind source and matches original payload
SHA/size and the reconstructible full tagged digest. First_revision is a
positive signed-64 historical identity. The source table's complete frame byte
sum is bounded by the shared 4-MiB custody ceiling before hashing any payload.
This pure check proves byte
correspondence, never actor authorization; only Store supplies that assertion.
Invalid read records refuse invalid_authoring_source.

Each chosen byte range must fit the actual original payload and form nonempty
valid UTF-8 without Unicode control characters except newline/tab. A split code
point, out-of-range interval or prohibited control refuses invalid_source_passage
for the complete request. Success is the sorted list of records containing
exactly source_ref, source_payload_sha256, first_revision, offset, length,
passage_sha256 (SHA-256 of exact selected bytes) and text (those exact bytes).
No full original, frame, credential, private path or selection authority is
included. Different overlapping intervals are allowed and each consumes its
explicit byte budget. Repeating an identical interval is refused. Selection
does not create ownership or alter a revision, and instruction-like source text
remains inert data. This local projection is not remote export authorization;
the later provider boundary must still recheck its explicit source/export policy.

Acceptance covers UTF-8 byte offsets and split code points, control text,
32/33 selectors, 4096/4097 bytes, exact SHA vectors, ordering/duplicates/improper
lists, wrong kind/summary, multiple owners, complete-set refusal with no custody
read, corrupted/missing bytes, revocation and unchanged revision/lease counts.
Independent raw/frame and passage SHA vectors are
test/fixtures/profiles/source-passages.json, generated from exact UTF-8 byte
offsets in Python before implementation.

Inclusive backup version WOHBK3 preserves the validated database, existing v1
archive objects and exact retained tagged frames under the existing AES-256-GCM
authentication. Its plaintext is an unsigned big-endian 32-bit length of the
existing v1 inclusive archive, that exact archive, followed by
an unsigned big-endian 16-bit tagged count and sorted records of unsigned
big-endian 32-bit frame length plus frame bytes. All complete-file identities
and summaries match the database's unique retained set; count ≤128 and total
tagged frame bytes ≤4 MiB. Existing WOHBK1/2 decoding remains unchanged.
Database-only backup declares tagged dependencies unavailable; it cannot claim
their bytes were included. Inclusive export refuses missing/corrupt bytes with
no partial output. Restore publishes all verified objects and the database only
into private quarantine. It preserves histories and ownership, but restores no
active authoring/generation/selection authority and never fetches missing data.
Transfer/recovery still applies its existing fences. The owning archive and
semantic snapshot checks use each version's actual table set.

Acceptance uses real SQLite import/replay/conflict, distinct-author ownership,
maintenance/revocation/CAS, missing payload, exact quotas, SQL fault rollback,
tampered receipt/journal/first revision, schema 28 migration, retained collection
and encrypted inclusive/database-only quarantine restore. This ownership stage
does not implement candidate assessment, provider handoff or active selection.

**H18A-02 — Generation boundary.** A configured, explicitly selected generator
receives only the approved contract, instruction and source passages/examples.
It has no device transport, shell, install, Store, bearer or activation port.
Remote processing requires the operator's explicit permitted source/export
policy; otherwise use a configured local generator or manual authoring.
Recheck that policy before each provider handoff. Revocation blocks future
handoffs; it cannot retract sources already handed to the provider. Record
that earlier handoff separately from draft acceptance and never replay it on
an original-operation retry. Provider credentials remain host-held.
Unavailable models or unsupported generation schemas return unavailable; they
cannot silently change provider, disclose sources or weaken validation.
Documents and diagnostic feedback are data, including instructions embedded
in them. The model cannot choose new sources, bindings, permissions or limits.

**H18A-03 — Finalize and assess.** For each candidate Home calls WPF.03's
finalizer and validator, then checks the v2 envelope and supplied independent
fixtures. Finalizer hashes/order are derived mechanics; authored scale, units,
sentinels and protocol selection are unchanged. Expected fixture results must
come from independently reviewed vendor/protocol evidence, not the same model
that authored the draft. Preserve raw sentinels, exact conversion, null/quality
and actual source time. A wrong register inside a supported selector grammar
can remain producer-compatible; source review/independent model fixtures must
refuse its use rather than claim the generic validator knows the hardware.
Reports show compatibility, capture status, uncovered
channels and unresolved source facts separately; never a single confidence score.

### Independent mapping fixtures

Profiles.AuthoringFixtures.check/3 accepts a checked ExternalEnvelope, explicit
fixtures and the identical selected reader limits. It revalidates the envelope
through its public summary and the producer Projection.to_map/2 before checking
any report. It is pure and has no device or Store port. The host supplies reviewed
fixture expectations; the component checks correspondence, not who reviewed
them. A generator's self-authored expectations cannot establish source review.

Fixtures are a proper list of at most 32 records strictly sorted/unique by Home
ID, each exactly id, selector, report and expected. Selector is independently
reviewed native JSON describing the intended installed selector, never copied
from the candidate to make the comparison pass. Report is the complete public
WPF.02 decoded report (13 closed fields, explicit C02 value and source/receipt
provenance). Expected has exactly the 14 public Proposal fields other than
profile_sha256, closure_sha256, capture_digest and compiler_ref. It includes
channel_id, affordance, semantic, unit, normalized_value, quality, quality_reason,
continuity, source_ref, source_epoch, sequence, source_time, receipt_time and
interpretation. All timestamps/units/values retain their exact public producer
encoding; there is no rounding or unit/schema implementation in Home.

Each complete fixture's canonical JSON is ≤65536 bytes; their aggregate is
≤262144 bytes. Public Wotex.JSON.encode/2 enforces depth eight, 4096 nodes,
256 members per collection and 256 UTF-8 bytes per string before producer
construction; complete encoded byte sizes are checked separately. Malformed
shape, IDs, ordering/duplicates/improper lists or expected representations refuse
invalid_authoring_fixture. The 33rd list cell or any resource ceiling refuses
authoring_limit without scanning an over-budget tail. Empty fixtures are allowed
only as an explicit not_supplied result, never a passed assessment.

Expected is validated by public Proposal.new/2 with the four exact selected
projection identities supplied separately. This is representation validation,
not deriving an expected result from the candidate. For each fixture, the report
channel must be an included Home channel with a supported producer plan. A
missing/excluded channel gives failed/channel_unavailable. The plan selector
must exactly equal the independent fixture selector, otherwise failed/
selector_mismatch. Only then Interpreter.project/3 processes the report and
Proposal.to_map/2 revalidates its output. A non-resource producer refusal gives
failed/interpretation_refused. The actual 14 fields must exactly equal expected,
including sentinel/null/quality, semantic/unit, source time, receipt time and
continuity. A difference gives failed/proposal_mismatch. No expected value is
filled from actual output. Resource refusal stops the complete check; absent
public functions give profiles_producer_unavailable.

Native fields are exactly envelope, fixtures, reader_limits and data. Data is
exactly format wotex-home.authoring-fixtures@1, consumption_sha256,
fixtures_sha256, status, cases and uncovered_channels. fixtures_sha256 hashes
UTF-8 wotex-home.authoring-fixture-set@1, newline and canonical public JSON of
the supplied complete ordered list. Cases are sorted records exactly id,
disposition (passed or failed) and reason (null or the four fixed codes above).
Uncovered_channels is the sorted included channel set without a passed fixture;
required and optional included channels count alike. Status is not_supplied for
an empty set, failed if any case failed, incomplete if otherwise uncovered
channels remain, and passed only for a nonempty all-passed complete set.
Summaries expose no decoded report, expected value, selector, source/capture text
or raw candidate. They do not establish physical correctness or source truth.

AuthoringFixtures.to_map/3 takes the native value, current checked envelope and
identical limits, revalidates both bases and refuses stale_authoring_basis when
consumption identity changes. It reruns fixtures against that basis and compares
every native field before exposing data; extra/forged fields refuse
invalid_authoring_fixture. The pure value is not retained across restart and
grants no approval. Durable fixture ownership/review and candidate journaling
remain later obligations. Acceptance uses independent exact report expectations
for the two quantity fixtures, wrong but producer-compatible register/conversion,
raw sentinel/null and preserved time, missing channel coverage, stale capture or
raw basis, malformed expectations and bounded/private diagnostics.
Independent report expectations and fixture-set identities are retained in
test/fixtures/profiles/authoring-fixtures.json; the fresh archive test is
test/support/profiles_fixture_consumer.exs. These synthetic expectations have
no manufacturer/physical qualification claim.

| Event | Required basis | Result / failure |
| --- | --- | --- |
| Start manual/generated draft | Current author permission, exact contract, source policy and capacity | Private pending candidate; no active-state change |
| Model response | Same pending operation/attempt and authority epoch, within both deadlines | Retain bounded candidate or invalid/unavailable disposition |
| Repair | Same approved input set, remaining attempt/time budget | New immutable draft revision; every candidate re-finalized/revalidated |
| Assess | Current installed basis, exact bytes, independent fixtures | Compatible/incompatible proposal; no trust/qualification granted |
| Review for import | Exact draft/report/source/fixture identities and current actor/policy | Existing WOH.18 import/trust proposal, or stale/unresolved refusal |
| Select for a Thing | Existing WOH.18 current capture, grants, declaration/qualification and Store transaction | Separate selection outcome; authoring cannot perform it |
| Cancel/revoke/deadline/restart | Pending operation basis | Retire attempt; late responses cannot update successor or active state |

**H18A-04 — Review and race guards.** Any candidate/source/fixture change creates
a new revision and invalidates prior assessment. Before import/trust/selection,
Authority rechecks current producer/schema/rule/binding identities, accepted
meanings, actor/epoch, base revision and source policy. Missing bytes, changed
firmware/capture or revoked authority refuses stale use. A compatible old report
is retained history, not a current certificate. Never infer enrollment or
physical qualification from model matching, schema checks or fixture success.

**H18A-05 — Retention and recovery.** Repeated authenticated original-operation
queries return the same retained draft/attempt result; they do not regenerate
or spend another provider attempt. A changed request requires a new operation.
A lost provider response is unavailable/unknown generation, with no model/tool
effect replay; explicitly requested repair uses the remaining shared budget.
Restore preserves original bytes/basis and quarantines candidates with missing
dependencies. No remote fetch, stale activation or automatic provider restart.
Private draft cleanup obeys existing custody references/leases and cannot remove
selected profiles or rewrite approvals. Telemetry records counts/dispositions,
duration and opaque operation correlation, never document/profile/secret bytes.

## Implementation entry and acceptance

The import schema is priv/profiles/authoring-import.schema.json; independent
ordered input/receipt vectors are test/fixtures/profiles/authoring-import.json.
Frame vectors remain separately frozen. Freeze producer schemas/public seams
and independent v2/authoring vectors before assessment/generation code. Pure
contract/manual mechanics vectors are test/fixtures/profiles/authoring-mechanics.json;
their draft, finalized bundle, exported contract and Home basis identities were
calculated independently in Python against the exact selected producer archive.
Then define the authenticated candidate assessment/generation encoding, durable
original receipt and migration/backup encoding under WOH.14/18. Object import
uses schema 29 as defined above; no candidate route or provider pin is chosen
by this document. Physical dispatch
remains default-disabled until its actual owning qualification passes.

| Case | Requirements | Stimulus and expected falsifier | Evidence |
| --- | --- | --- | --- |
| H18-T13 | 01, 03 | Manual and scripted-generator drafts describe unseen quantity through same producer/archive; different result or model branch fails | Pure/software |
| H18-T14 | 01–03 | Wrong units/register/selector despite valid JSON, forged hash, conflicting/missing source and unsupported provider schema | Explicit incompatible/unresolved/unavailable; no import/select |
| H18-T15 | 02, 05 | Inject source instructions to reveal credentials or activate a profile; cancel/revoke during generation | No forbidden port/export, late result cannot commit |
| H18-T16 | 03–05 | Change binding, fixture, draft revision, actor or capture between assessment/review/use | Current-basis refusal; old report remains history |
| H18-T17 | 02, 05 | At/above each quota/deadline, three failed repairs, lost response/restart/restore | Bounded disposition, original retry does not regenerate, no active changes |
| H18-T18 | 01, 04–05 | Offline export/import to another host with different grants/accepted semantics | Revalidated locally, no imported approval or physical claim |

Software cases are required but cannot prove a manufacturer mapping is physically
correct. WOH.11 and the relevant lab procedure own that separate evidence.
Primary rationale is the producer's [research decision](https://github.com/wotex-project/wotex/blob/main/docs/architecture/consumer-profile-authoring-research.md).
