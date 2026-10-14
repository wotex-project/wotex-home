# Durable manual authoring candidates

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-09; profile-authoring-v1 H18A-01/03/04/05.
Implementation: closed encoding and authenticated manual Store originals implemented.
Evidence: independent ordered vectors; fresh three-archive and actual Store cases;
focused recovery and historical migration checks. Source review/generation remain separate.
The [software record](../provenance/authoring-candidates-2026-10.md) retains the
exact source, archives, executed results and qualification limits.

## Result and boundaries

An operator imports an immutable draft and explicitly selected sources/fixtures,
then asks the single Store to retain a manual mechanics assessment as an original
operation. A lost reply reads the same assessment identity and derived bundle reference.
This does not perform source review, independent fixture comparison, current v2
admission, generation, enrollment or selection. Those remain separately required
by the [authoring owner](profile-authoring-v1.md). Manual authoring precedes the
configured provider path; generated requests cannot silently run as manual ones.

Authority forwards this use case to Store; transport, provider and pure helpers
receive no database handle or credential. The stateless candidate writer borrows Store's connection only
inside its transaction. Custody holds exact typed bytes and monitored leases.
Public WPF.03 finalization/validation and the checked Home AuthoringContract/
AuthoringAssessment own producer mechanics. No alternative validator is allowed.

## Current host selection

Store's trusted `authoring_contract` option is null (default disabled) or the
exact native AuthoringContract selected by the host's qualified artifact loader.
It contains its explicit installed bindings/contracts, three archive assertions
and narrowed limits. A caller/model cannot supply or replace this option through
the operation. The host must replace its selection on an artifact/policy change;
producer re-export/native revalidation runs on each new operation. Null selection
refuses authoring_unavailable; absent public producer functions refuse
profiles_producer_unavailable. Original receipt lookup precedes this selection,
so a previously completed original remains readable when the producer is absent.
This option does not establish a deployed package cohort or physical evidence.

## Closed operation and identity

Authority.assess_authoring_candidate/3 and Store.assess_authoring_candidate/3
take credential and exactly authority_epoch, operation_id, expected_revision and
request. Epoch is positive signed-64, revision nonnegative signed-64, operation
is a Home ID. Actor is always current Store authentication, never input data.
Request contains exactly mode, contract_digest, base_draft_ref, source_refs,
fixture_refs, instruction and limits, as declared by the owning authoring spec.
This transition accepts mode manual only; generated refuses
unsupported_authoring_mode. Contract_digest is the selected WPF contract identity.
Limits are exactly the selected five-field AuthoringContract limits, with their
eight-field reader map; changing limits requires a separately exported contract.

Base_draft_ref is required and contains exactly object_digest and first_revision.
Source_refs and fixture_refs are proper sorted unique lists of those handles,
at most 32 each, ordered by object_digest. First_revision is positive signed-64.
Draft/source/fixture kind and actor ownership are proved from the retained import
ledger, not the handle alone. Every first import precedes the candidate revision.
Instruction is UTF-8, 0–4096 bytes, with no Unicode control except newline/tab;
it remains inert review text and is not executed or sent to a provider.

Profiles.AuthoringCandidate.encode/1 converts native data to exactly:
`["wotex-home.authoring-candidate.v1", [epoch, operation, expected_revision,
["manual", contract_digest, [draft_digest, draft_first_revision],
[[source_digest, source_first_revision], ...],
[[fixture_digest, fixture_first_revision], ...], instruction, limits]]]`.
Limits is the ordered array [reader, max_bundle_bytes, max_diagnostics,
max_report_bytes, max_check_steps]. Reader is ordered max_bytes, max_depth,
max_nodes, max_channels, max_definitions, max_bindings, max_dependencies,
max_numeric_digits. The canonical UTF-8 JSON contains no objects or floats,
is at most 32768 bytes and requires exact decode/encode equality. Unknown/native
struct fields, duplicate/unsorted handles, invalid types/strings/limits or wire
input refuse invalid_authoring_candidate. A bounded decoder enforces depth eight,
4096 nodes, 256 entries per array and 4096 bytes per string before construction;
resource excess refuses authoring_limit. Counts above handle ceilings refuse
authoring_limit without traversing an over-budget tail.

## Store transition and retries

Current profile:manage authentication and full candidate/import ledger validation
precede original lookup. Original identity is (principal, epoch, operation), in
the candidate namespace separate from object-import originals. Exact input
replay returns the retained receipt without CAS, file access or recomputation;
changed input under that identity refuses authoring_operation_conflict.
Status authenticates current profile:manage and reads that actor's original only;
revocation blocks reads/replays. Missing original returns not_found.

A new original requires current epoch and global revision CAS, active controller
authority outside maintenance, the selected exact contract identity/limits and
all actor-owned draft/source/fixture handles with matching first revisions/kinds.
Wrong kind or revision refuses stale_authoring_reference; unowned handle returns
not_found. All references pass before payload reads. Store verifies and leases
the draft and calls AuthoringAssessment.assess/3 with null capture. Its compatible
or invalid report is retained honestly; no capture match, source review or fixture
comparison is inferred. Producer resource/API refusal creates no candidate row.

If finalization produces bundle bytes, Store stages a typed bundle and holds its
lease through the commit. An invalid finalization has no bundle. One transaction
rechecks authentication, CAS, epoch, maintenance, references and capacity,
appends authoring_candidate_assessed with entity_id equal to operation_id and
stores the original input, full safe assessment and receipt. SQLite failure
rolls back every row/revision; a published orphan remains inert and quota-counted.
Every lease is released. New operations do not replace older candidates.

The receipt contains exactly authority_epoch, operation_id, revision,
input_sha256 (SHA-256 of canonical input), basis_sha256 (Home contract basis),
assessment_sha256 (SHA-256 of retained assessment encoding), disposition
(compatible/invalid), capture_status not_supplied, bundle (null or four-field
tagged bundle summary), source_review not_assessed and fixture_status.
Candidate fixture_status is not_supplied for empty fixture_refs and not_assessed
when explicit fixture handles were supplied but no comparison ran. The retained
pure mechanics summary still says not_supplied because its API received no
fixtures. Integrity checks this distinction against the original request.
It grants no authority. Its ordered encoding is
[epoch, operation, revision, input_sha256, basis_sha256, assessment_sha256,
disposition, capture_status, bundle, source_review, fixture_status]; bundle is
null or [kind, object_digest, payload_sha256, payload_bytes].

The assessment encoding retains all 11 fields of the checked Home mechanics
summary in order: format, basis_sha256, draft_sha256, bundle_sha256, phase,
disposition, capture_status, report, home_consumption, source_review,
fixture_status. Report is the ordered public representation [format,
contract_sha256, candidate_sha256, disposition, capture_status, diagnostics,
truncated]. Each diagnostic is [phase, code, instance_path, rule_id, repair].
The decoder validates this finite metadata representation, not producer
semantics or current admission: format literals, exact digest fields, phase/
disposition/capture labels, at most 64 safe diagnostics, path ≤512, code/rule/
repair ≤128 UTF-8 bytes without controls, boolean truncated and compatible only
with empty diagnostics/not truncated. Integrity also applies the original
request's selected diagnostic count and encoded report byte ceilings.
The report's candidate identity equals
the bundle payload hash in validate phase or draft payload hash in finalize
phase; its contract identity equals the request. Finalize phase is invalid and
has no bundle; validate phase has a bundle even for an invalid binding report.
Stored assessment is ≤65536 bytes; receipt ≤4096 bytes. No raw draft/source,
capture, provider output, credential or private path is returned or logged.

## Schema, quotas and recovery

Schema 30 adds profile_authoring_candidates with exactly principal_id,
authority_epoch, operation_id, input_document, assessment_document,
receipt_document and revision. Primary key is (principal, epoch, operation);
revision is unique and references authority_journal. Prior supported schemas
validate before migration; the new table starts empty and grants no ownership.
The original schema 29 import tables and identities remain unchanged.

At most 1024 candidate originals and 4 MiB each of retained input and assessment
documents are allowed. Receipts are separately bounded per row. Before staging
and again in the transaction, the writer checks these bounds and the shared
128-object/4-MiB retained tagged-frame quotas, together with existing imports/v1
references. Capacity refuses authoring_candidate_capacity before commit; no
reference reservation bypass or deletion of history is allowed.

Integrity checks canonical documents, receipt hashes/identity, input CAS equal
to revision−1, exact journal event/entity/principal links, source/draft/fixture
first-import ownership and kind, assessment-to-input/receipt/bundle correspondence,
and orphan candidate journal events. Corruption refuses corrupt_authoring_candidates
and fences Store writes. Historical receipt validation requires no installed
producer and cannot turn a historical compatible report into current authority.

Collection and inclusive WOHBK3 export retain the union of import-owned objects
and all candidate bundle summaries, deduplicated/sorted by complete digest with
conflicting summaries refused. Existing actor-owned inputs remain retained by
the import journal. Candidate bundles are private candidate results, not new
object-import ownership rows. Inclusive export verifies their actual typed bytes;
database-only backup declares them unavailable. Restore remains quarantine,
retains original histories and cannot resume providers or select a profile.
Retired snapshot/transfer commitments include the actual new table; normalized
older snapshots use the declared empty seven-column table, with no fabricated
candidate or active permission. Missing/corrupt derived bytes refuse inclusive
export and later byte-dependent review, while original receipts remain history.

## Acceptance and implementation entry

Freeze `priv/profiles/authoring-candidate.schema.json` and independent ordered
input/receipt/assessment vectors before code. Use an exact three-archive producer
consumer plus actual Home Authority/Store/SQLite/custody tests, without adding a
neighboring source dependency or changing the application pins merely for tests.
The test loader may expose only the checked consumer's producer/dependency ebins
to the isolated Home test process; it supplies no production fallback or admission.
The isolated process can restore the original dynamic Elixir protocol where
Home's dependency-free consolidation omitted an optional dependency implementation.

Required software cases: valid manual candidate for both external quantities;
invalid syntax/selector retained as invalid; exact replay after lost reply,
missing draft/bundle, producer/configuration loss and restart; conflicting input;
CAS/epoch/maintenance/revocation; another actor and changed first revision/kind;
typed unavailable default; actual SQL-trigger rollback with orphan/zero leases;
tampered receipt/assessment/journal/reference links; schema 29 migration preserving
existing imports; exact quotas; collection and encrypted inclusive/database-only
quarantine restore. Fixtures and software tests establish no physical correctness.
Remaining source review, independent fixture admission and generated-attempt
state machines stay explicit owning obligations, rather than fabricated success.
