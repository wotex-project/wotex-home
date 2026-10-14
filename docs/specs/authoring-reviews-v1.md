# Durable authoring source and fixture review

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-09; profile-authoring-v1 H18A-03/04/05.
Implementation: planned. Evidence: missing.

## Result and authority boundary

An authenticated operator records source attribution against one retained manual
candidate and can additionally check its exact consumer envelope and independent
fixtures. A successful review produces an inert proposal, never import/trust,
enrollment, observation, selection or physical qualification. Source documents
remain data. This component checks identities, explicit attribution coverage and
fixture correspondence; it cannot attest source truth or discover semantic
contradictions in prose. The operator must leave uncertain/conflicting facts
unresolved. Model-authored evidence alone is not operator review or control.

Authority.review_authoring_candidate/3 forwards credential and the original input
to the single Store. The stateless writer executes on Store's borrowed connection.
Pure helpers and WPF receive no credential, Store handle or transport. Imports,
candidate originals, existing v1 approvals and physical dispatch retain their
separate [authoring](profile-authoring-v1.md), [candidate](authoring-candidates-v1.md)
and WOH.18 boundaries. Review never edits an earlier candidate receipt.

## Inputs and limits

Input contains exactly authority_epoch, operation_id, expected_revision and
review. Epoch is positive signed-64, revision nonnegative signed-64, operation a
Home ID. Review is exactly mode, candidate_ref, evidence, unresolved_paths and
envelope_ref. Mode is source or complete. Candidate_ref is exactly
authority_epoch, operation_id, revision, input_sha256 and assessment_sha256,
matching the current actor's immutable candidate original. Its epoch/revision
are positive signed-64 and its digests lower hex64. Source mode requires null
envelope_ref; complete requires an actor-owned immutable envelope handle exactly
object_digest/first_revision (positive signed-64).

Evidence is a proper list of at most 256 records, each exactly instance_path,
source_ref and locator. Paths are ≤512 UTF-8 bytes and must name one required
fact root below; source_ref is a selected original source's complete tagged
digest, not a URL. Locator is nonempty inert text ≤256 UTF-8 bytes without Unicode
controls/format characters. Records are strictly sorted/unique by
(instance_path, source_ref, locator). Unresolved_paths is a proper sorted unique
list of at most 64 required roots. Unknown fields/structs, malformed references,
paths, ordering/duplicates and unselected sources refuse invalid_authoring_review.
The first over-budget cons cell or encoded input >131072 bytes refuses
authoring_limit without scanning an over-budget tail. There are no defaults.

Profiles.AuthoringReview encodes the canonical ordered input:
`["wotex-home.authoring-review.v1", [epoch, operation, expected_revision,
[mode, [candidate_epoch, candidate_operation, candidate_revision, input_sha256,
assessment_sha256], [[path, source_digest, locator], ...],
[unresolved_path, ...], envelope]]]`. Envelope is null or [digest, first_revision].
No objects or floats appear. Decode enforces depth eight, 4096 nodes, 256 array
members and 4096 bytes per string before materialization and requires exact
decode/encode equality. Invalid wire/native data refuses invalid_authoring_review.

## Source attribution

Profiles.SourceReview.check/4 takes a checked current AuthoringAssessment, verified
source read records, evidence and unresolved paths. It revalidates assessment
through AuthoringAssessment.to_map/2 using its selected contract. Only compatible
validate-phase candidates enter review; otherwise candidate_incompatible.
Public Wotex.JSON.decode/2 parses the already checked original draft with the
selected byte limit, depth eight, 4096 nodes, collection 256 and string 4096.
The producer owns JSON syntax/duplicate/schema/closure semantics, not Home.

Required roots are mechanically enumerated from that original draft, sorted:
/profile/binding; each /profile/fingerprint/i; each channel's
/profile/channels/i/selector, /semantic and /invalid_values; its /conversion
when non-null; and each definition's /definitions/i/unit and /value_schema.
Indices are canonical zero-based decimals. Labels, local reference hashes and
installed behavior-contract links are mechanics, not new device-source claims.
The maximum 32 channels/definitions/fingerprint clauses yields at most 225 roots.
Evidence cannot cover a whole /profile, an unrelated annotation or a guessed
leaf instead of the exact root. All declared channels count, including optional
ones; later consumption can separately exclude unsupported channels.

Source records are the same exact object/payload/first_revision shape as the
owned reader, sorted by digest, ≤32, total complete frames ≤4 MiB. Every record
must be kind source and prove raw payload SHA/size and reconstructible full frame
identity before attribution. Pure validation establishes byte correspondence,
not actor ownership; Store supplies the complete selected owned set. Each source
in evidence must appear in that set. Empty evidence/sources may record missing
attribution but never complete it.

One distinct citation attributes a root. Multiple distinct citations for one
root are ambiguous in this first review profile; the operator must choose or
consolidate authoritative evidence, or leave the root unresolved. This is a
deterministic metadata ambiguity rule, not a claim to detect conflicting prose.
Covered_paths has single-citation roots not explicitly unresolved. Missing_paths
has roots with no citation, excluding explicitly unresolved roots. Ambiguous_paths
has roots with multiple citations. Status is ambiguous if any ambiguous root,
otherwise incomplete if missing/unresolved roots remain, otherwise attributed.
Explicit unresolved roots block attributed even when they have a citation.

Native SourceReview fields are exactly assessment, sources, evidence,
unresolved_paths and data. Data is exactly format wotex-home.authoring-source@1,
basis_sha256, draft_sha256, sources_sha256, evidence_sha256, status,
required_paths, covered_paths, missing_paths, ambiguous_paths and unresolved_paths.
sources_sha256 hashes UTF-8 wotex-home.authoring-sources@1, newline and public
canonical JSON of the ordered object summaries plus first_revision (no payload).
evidence_sha256 hashes wotex-home.authoring-evidence@1, newline and canonical JSON
of the complete ordered evidence/unresolved pair. Data is ≤24576 encoded bytes
and includes no payload, locator, value or capture text. to_map/2 accepts a current
checked assessment, refuses stale_authoring_basis for changed basis/draft identity,
recomputes and compares every native field before exposing data. Extra/forged
native fields refuse invalid_authoring_review.

## Envelope and independent fixture checks

Source mode makes no envelope/capture/fixture comparison. Its receipt uses
home_consumption not_assessed and fixture_status not_supplied when the candidate
selected no fixture handles, otherwise not_assessed. Complete mode requires
Store's trusted authoring_capture option (default null/unavailable), supplied by
the host's capture boundary rather than the operator/model. This is the explicit
WPF binding capture; it establishes correspondence, not physical/source truth.
The host must replace the selection on capture change. Null refuses
authoring_capture_unavailable. Original lookup precedes every producer/capture
selection so older receipts remain history when a selection disappears.

Profiles.AuthoredEnvelope.compile/3 takes the revalidated compatible assessment,
original owned envelope bytes and explicit host capture. Public core JSON decodes
the final bundle; public WPF Profile/Definition.reference and core JSON.encode
derive separately retained canonical document records with exact semantic/raw
identities. These bytes are derived artifacts, not original draft substrings.
All individual and aggregate v2 limits apply. ExternalEnvelope.compile/5 owns
the read-only Home join against the assessment contract's trusted installed
registrations and exact reader limits. It rejects wrong envelope references,
unknown consumption, unsupported required channels and capture mismatch.

Every fixture handle in the candidate original must still be actor-owned kind
fixture with the identical first revision. Verified payloads decode through
public Wotex.JSON.decode/2 (copied strings, duplicate refusal, depth eight,
4096 nodes, collection 256, string 256, complete bytes ≤65536). Each payload is
one complete four-field fixture record from AuthoringFixtures; decoded fixtures
sort uniquely by ID and the aggregate remains ≤262144 bytes. No fixture is
selected by the model or synthesized from the candidate. AuthoringFixtures.check/3
and its public checked summary own exact selector/C02/unit/provenance comparison.
Empty fixtures remain not_supplied, never passed. The actual capture is not
returned in the review receipt. A failed/incomplete fixture result can be retained
as a blocked proposal; a resource/API/invalid input refusal creates no review row.

## Durable transition and receipt

Current profile:manage authentication, import/candidate/review integrity and
original lookup precede CAS, byte reads, producer work and current selections.
Original key is (principal, epoch, operation) in the review namespace. Exact
replay returns the retained receipt, changed input authoring_operation_conflict;
status reads only this currently authenticated actor's original. Revocation blocks
reads/replays. New requests require current epoch/global revision CAS, active
controller outside maintenance, exact candidate reference and current contract
basis equal to the candidate's retained basis. Changing producer/limits/accepted
Home contracts requires a new candidate; old assessment is not a current token.

All candidate and envelope ownership/kind/revision checks precede byte access.
Store leases verified draft/bundle/sources and (complete mode) envelope/fixtures,
recomputes the manual assessment and requires exact retained assessment/bundle
correspondence. Missing/corrupt/unsafe bytes refuse authoring_object_unavailable;
custody loss profile_custody_unavailable. A changed candidate/current basis refuses
stale_authoring_basis; wrong owned kind/revision stale_authoring_reference;
unowned/missing candidate/handle not_found. Every lease is released on all paths.

One transaction rechecks authentication, epoch/CAS/maintenance, all immutable
references and current contract/capture selections, appends authoring_candidate_reviewed
with entity_id operation_id and retains canonical input, result and receipt.
SQLite failure rolls back every row/revision. It changes no candidate original,
profile trust/current selection, rule, enrollment, grant or effect queue.

Receipt is exactly authority_epoch, operation_id, revision, input_sha256,
candidate_revision, basis_sha256, result_sha256, source_review, home_consumption,
fixture_status and proposal_status. Source_review is attributed/incomplete/
ambiguous. Home_consumption is not_assessed or matched. Fixture_status is
not_supplied/not_assessed/passed/failed/incomplete. Proposal_status is complete
only when source attribution is attributed, Home consumption matched and fixture
status passed; otherwise incomplete. Complete means review metadata/correspondence
under this exact basis, never physical or active authority.

Schema 31 adds profile_authoring_reviews with exactly principal_id,
authority_epoch, operation_id, input_document, result_document, receipt_document
and revision. Primary key is original identity; revision unique FK to journal.
Migration validates supported predecessors and creates an empty table, conferring
no review. Retain ≤1024 originals, ≤4 MiB input and ≤4 MiB result bytes. Input
≤131072, result ≤65536, receipt ≤4096. Capacity refuses authoring_review_capacity.

Receipt encodes the eleven fields above in that order. Result encodes
["wotex-home.authoring-review-result@1", source_summary, envelope_summary,
fixture_summary], with null last two in source mode. Summaries use a closed
ordered representation: source fields in their declaration order above;
envelope fields format, envelope_sha256, document_identities (reference/raw_sha256
records), projection_sha256, consumption_sha256, home_contracts, exclusions,
producer; fixture fields format, consumption_sha256, fixtures_sha256, status,
cases and uncovered_channels. Reference is [id, version, sha256], document is
[reference, raw_sha256], channel-contract [channel_id, reference], exclusion
[channel_id, reason], producer [core_archive_sha256, runtime_archive_sha256,
profiles_archive_sha256], case [id, disposition, reason]. Source summary includes
only safe root paths/hashes/status, never evidence locators or original values.

Integrity validates canonical encodings/hashes, actor/candidate/import references,
input CAS revision−1, exact journal event/entity links and orphan review events,
result/receipt correspondence and selected resource bounds. It needs no installed
producer to validate historical metadata, and cannot renew review authority.
Corruption refuses corrupt_authoring_reviews and fences Store writes. Inclusive/
database-only backup, retired/normalized snapshots and transfer use each schema's
actual table set. Existing retained import/candidate bytes already protect every
review input; no new byte owner or fetch path is created. Restore stays quarantine
and resumes no provider or control. Every later import/admission must revalidate
the complete current basis, explicit grants and actual qualification.

## Acceptance and implementation entry

Before durable code, freeze independent source-root/attribution vectors and
canonical review input/result/receipt vectors plus
priv/profiles/authoring-review.schema.json. Test public producers in a fresh exact
three-archive consumer and actual Authority/Store transactions in its isolated
archive-backed process. Required cases include both independent quantities,
missing/ambiguous/unresolved facts, unrelated/derived paths, forged native/source
identity, bound excess, duplicate fixture JSON, valid/wrong selector and scale,
sentinel/null/time preservation, empty/missing channel coverage, stale contract/
capture/candidate/source revisions, another actor/revocation/maintenance/CAS,
lost replies/missing files/producer loss/restart, SQL fault rollback, tampered
deep links, schema 30 migration, quotas and encrypted quarantine recovery.
Software evidence is separate from source authenticity and physical qualification.
