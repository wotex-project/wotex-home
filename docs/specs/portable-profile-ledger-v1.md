# Portable profile ledger v1 mechanism

Version: 0.1.11. Implementation design for WOH.18 P2/P3, 2026-10-07.
Schema 20 implements retained approval, compatible reviewed target replacement,
revocation, owning-domain pins and historical backup verification. Schema 19
retains its earlier validator requiring empty selection/pin tables. Trusted core
selection, initial external enrollment and firmware replacement are delivered;
public host/operator flows remain separate unfinished work.

## Retained qualification snapshots

Schema 20 now adds `profile_qualification_history`, with
one immutable snapshot per original `profile_qualified` authority revision;
`profile_qualifications` remains the current head. Its ordered encoding is
`["wotex-home.qualification-history.v1", values]`, using the field order in
`Qualification.HistoryCodec`: Thing, profile, resource revision, identity/basis/
registry/runtime digests, evidence reference, original revision, provenance,
declaration document, principal, authority epoch and enrollment-binding revision.
This encoding was fixture-tested and committed before its SQL migration.

Migration copies every existing head, including revoked heads, with provenance
`legacy_migrated` and null declaration/principal/epoch/binding fields. Those
details were not retained in the old slot and must not be reconstructed as
original evidence. Migration preserves its status, journal revision, Store
revision and epoch; it grants no new qualification. The retained migration
revision separates legacy snapshots from later guarded events, so a new row
cannot discard its provenance by claiming to be a legacy migration. New `guarded_current`
snapshots retain the exact canonical declaration, authenticated principal,
current epoch and reviewed binding revision. Their binding predates the original
qualification journal event. Keep at most 4,096 snapshots, refusing admission
at capacity rather than deleting history.

Every history row links to its exact authority event and every such event links
back to a snapshot. The current head must equal its snapshot and be the newest
snapshot for that Thing. A new verified qualification may replace a revoked
head, without modifying an earlier snapshot or restoring an old selection.
Exact historical evidence retry returns its original revision; it never makes
that earlier qualification current again. Archive manifests retain evidence
dependencies from all snapshots, including revoked and replaced heads. Schemas
4–19 retain their own exact table sets and integrity checks. These historical
records alone never establish current physical qualification.

## Canonical requests and historical receipts

`Profiles.Operation` defines executable, fixture-tested UTF-8 encodings. An
operation is the compact JSON array `["wotex-home.profile-operation.v1", values]`.
Values are ordered as action, authority epoch, operation ID, expected Store
revision, raw artifact digest and expected artifact trust revision.

`approve` and `revoke` use those six fields only. `select` appends target ID,
expected resource revision, expected enrollment-binding revision, expected
selection generation, expected global profile-policy generation, expected rule
generation, host capture session reference, candidate reference and review
reference. `revoke_selection` appends target ID, expected resource revision and
expected selection generation only; it needs neither readable bytes nor a new
capture. Rollback is a new `select` operation with fresh review of retained,
currently approved compatible bytes. Epoch is positive; all other integers are
nonnegative signed-64-bit values. IDs and digests use the existing closed syntax.
The authenticated principal never comes from this document.

An operation's primary identity is `(principal_id, authority_epoch, operation_id)`.
Retain the exact canonical input, SHA-256 commitment, original expected pins,
final revision, changed target count, invalidated request count and handed-off
unknown count. Exact retry checks the caller's current lifecycle permission and
returns the original receipt before testing current CAS pins or byte presence.
Changed input conflicts. Historical lookup is principal-private and never claims
that the original artifact approval or target selection remains current.

## Rows and migration

The Store owns these bounded shapes; collaborators borrow its handle only:

`Profiles.LedgerCodec` fixes their ordered scalar/document encodings as
`["wotex-home.profile-ledger.v1", kind, ordered_values]`. Artifact, operation,
selection, current and owning-domain pin encodings are independently fixture
tested. The authored row field order in that module is the migration input;
SQL writers must use explicit column names and validate the corresponding
codec before retaining a row. Decode is historical structure validation, never
proof of journal linkage, caller authorization or file availability.

| Table | Retained shape and linkage |
| --- | --- |
| `portable_profiles` | Raw digest primary key; unique reserved id/version label; canonical validated metadata, projection bytes/digest, binding and registry digest; first approval revision. No raw artifact bytes or active pointer. |
| `profile_operations` | Scoped operation primary key; canonical request/commitment; original receipt and exact authority-journal link. Trust actions also retain previous trust revision/generation. |
| `profile_selection_history` | Thing and monotonically increasing generation; parent scoped operation; prior selection/resource/binding revisions; exact raw/projection/trust pins; selected or revoked state; new declaration and reviewed identity basis where selected; exact journal/enrollment links. |
| `profile_current` | One current history pointer/generation per Thing. A revoked selection remains an explicit unavailable state, with no compiled fallback. |
| `profile_observation_pins` | Observation journal revision to exact raw/projection/selection/trust/resource pins; append-only. |
| `profile_request_pins` | Original scoped request/root identity to the same pins; all effect transitions repeat them. |
| `profile_rule_pins` | Admission revision and target to the same pins; activation/invocation and execution repeat them. |
| `profile_qualification_pins` | Original qualification authority revision and target to the same pins; old qualification remains historical after selection changes. |

Admission capacity is the existing combined 64-profile ceiling, including
compiled labels and revoked external label tombstones. Use at most 1,024
lifecycle operations, 2,048 retained selection generations and 64 current Thing
selections in the first delivery.
Existing enrollment-review limits still apply. Retained pin rows inherit the
bounded owning receipt/history domain; no pin can outlive its original journal
identity by being rewritten onto another operation.

Migration creates empty profile/pin tables and a zero global profile-policy
generation without changing Store revision, epoch, declarations, observations,
credentials, rules or qualification. Existing provenance is compiled, never an
invented external approval. No old review/document is rewritten into a new
profile. The legacy schema-4–18 table sets remain exact.

## Trust, review and transition ordering

Provision `profile:manage` explicitly through trusted foreground setup, with no
control targets. It is independent of `host:maintain`, `enroll:review`,
`qualify:profile` and `control:ordinary`. Lifecycle changes require the existing
global maintenance barrier. Selection additionally requires current enrollment
review permission and fresh one-use host evidence. Plain import stays inert.

Approve verifies a held custody lease, raw bytes, projection, binding and registry
before inserting the immutable artifact/label and local digest approval together.
Approval/revocation increments global profile-policy generation. Current use
binds the selected artifact's exact active approval revision; an unrelated local
approval cannot silently transfer evidence between artifacts. A later trust
policy/compiler change requires its own version and requalification.

Prepare selection authenticates and snapshots every request pin plus the current
enrolled identity/declaration and exact host runtime. Authority consumes one
operator-bound capture, derives the declaration and displays the semantic diff.
Commit repeats authentication, capture/binding, trust, revision, generation and
no-widening checks. It retains the new enrollment review and historical profile
selection, changes the current pointer/resource revision, revokes qualification,
clears current reports/source grants, invalidates unsent work and suspends rule
policy in one transaction. Preserve handed-off uncertainty and spent roots.

Revocation uses retained rows and remains possible with missing files. Artifact
revocation invalidates every dependent selection under the same transaction;
target revocation changes only its selected scope. Neither revocation nor a
later approval restores an old selection, fact, qualification or active rule.
All multi-row transitions use real rollback injection tests.

## Current guards, integrity and retained recovery

The trusted selection-review path feeds the Store-owned selection transaction.
`Store.ProfileWriter.selection_basis` checks management and enrollment-review
permissions, maintenance, current trust author, every caller CAS pin and the
exact reviewed enrollment/history binding before Authority consumes a capture.
Authority leases the approved bytes, obtains the complete Home/UDP runtime
digest and consumes the operator-bound host capture once. `Profiles.Review`
reparses the bytes, repeats identity/dependency/pin correspondence and derives
the declaration. New operations, wider freshness, changed units/risks or new
capabilities are rejected. The summary exposes profile/declaration changes,
pending physical evidence and conservative invalidations without adding grants.

Its canonical document is the at-most-64-KiB ordered JSON array
`["wotex-home.profile-selection-review.v1", input_document, basis_values,
runtime_digest, enrollment_identity_digest, proposed_thing_document]`.
`basis_values` use the exact field order authored in `Profiles.Review`: actor,
epoch, Store/policy/rule/maintenance revisions, target/resource/binding/selection
pins, trust revision/generation, raw/projection/registry digests, proposed profile
reference, captured stable identity/manufacturer/model/firmware and current Thing
document. This review is an inert proposal. It creates no retained operation,
selection, fact or qualification by itself and is absent from the public API.

`Profiles.Review.decode_history/2` now checks this exact canonical encoding
against the retained artifact row. It repeats every original request/basis pin,
fingerprint match, fixed declaration derivation, no-widening check and the exact
enrollment identity commitment. It neither requires today's installed registry
or runtime nor invents candidate packets, a capture deadline or live approval.
`Bindings.historical_declaration/3` reconstructs only the versioned fixed binding;
its successful structural check grants no current device support. SQL selection
history must additionally link the scoped parent operation, original review and
authority events, generation/resource chain and current pointer. The live,
startup and archive validators now enforce these links in both directions.

The transient `Profiles.ReviewSession` owns pending proposals and exact custody
leases. Its default eight slots may be configured down or up to 32, with at
most 4 MiB of encoded retained terms and 128 combined live/retired capture
identities. The original host capture's local monotonic deadline caps a maximum
60-second pending lifetime; retries never renew it. Retired identities expire
only when that capture can no longer be fresh, preventing another registration
after cancellation or checkout. The actor/epoch/operation and exact canonical
input select pending status; other actors cannot see a token or conflict.

One checkout returns the canonical proposal and host-derived deadline, monitors
the commit caller and retains the lease until that caller finishes or dies.
Pending expiry and owner restart release leases without durable activation.
`Profiles.Review.valid?` reconstructs every field from bounded bytes/evidence;
captured deadlines are transient and absent from portable history encodings.
Trusted Authority preparation rechecks the current Store basis before pending
retry or consuming a new capture. Store selection first looks up the original
receipt, repeats current authorization/CAS, then checks out the exact scoped
proposal. It rereads custody bytes and the runtime outside SQLite, repeats the
basis/history correspondence inside the transaction, and checks the original
deadline again immediately before commit. Checkout is consumed on success or
failure; exact committed retry needs neither a proposal nor external files.

The first delivered schema-19 slice accepts only `approve` and `revoke`, retains
zero changed targets and rejects selection. Its live/startup/archive validator
checks immutable artifact metadata, operation input commitments, alternating
trust history, exact global policy generations and both directions of journal
links. Approval requires verified custody; revocation and historical receipts
remain available without the file. An approval whose author loses management
permission is unavailable for current use. Migration creates empty lifecycle
tables without changing existing authority state. The following selection/pin
requirements remain implementation obligations before external activation.

Observation acceptance and effect queue/claim/handoff validate the exact current
selection, active local approval, artifact availability and owning domain pins.
The Store sequences external custody verification before its transaction and
rechecks row pins before commit; native decode/compilation does not run inside
SQLite. A missing artifact blocks dependent work while retaining status/history.
Catalogues must still disclose unavailable selections. No replacement version
or reconstructed serialization satisfies an absent digest.

Startup and archive verification check both directions of every new journal,
operation, selection, review and pin link. Historical enrollment and revoked
qualification rows may refer to earlier profiles only through this validated
selection history; current qualified rows must match current declarations and
selection pins. Corrupt authority links disable writes, rather than becoming an
ordinary unavailable artifact result.

Schema-19 backup manifests list all retained raw/projection identities,
dependencies, approvals, selections and required external bytes. Verification
does not invent byte custody or current freshness. Transfer verifies exact bytes
before an explicitly fenced restore; staging remains quarantined. Historical
schemas report empty portable dependencies and retain their original validators.

The delivered GC may remove only inert, unreferenced artifacts/stages. Store serializes the
reference snapshot and custody collection against new admission/selection;
custody additionally checks caller leases and accepts snapshots only from its
trusted configured Store owner. Management permission and active maintenance
are required. Preflight verifies the whole bounded namespace before deleting;
per-file/root identity checks and directory synchronization precede success.
Missing retained bytes remain external requirements. Collection changes no
Store revision and can be retried without rewriting authority. No deletion removes metadata,
receipt tombstones, selection history or pinned external dependencies. When
retained history fills capacity, refuse new admission. Archival retirement is
a separately reviewed future mechanism.

Preparatory runtime hooks now use `Store.ProfileGuard` for observations, refresh,
new requests, rule use, qualification and execution boundaries. Historical
receipt lookup keeps its original ordering. Fact previews return unknown for a
known unavailable profile while independent compiled targets remain readable.
Policy unavailability rolls back without disabling the writer; corrupted
authority links fail closed. A coarse trusted enrollment cannot use an approved
portable label without its separate selection.

`Store.ProfileByteContext` verifies current bytes before the authority
transaction, using one bounded custody request for at most 64 commitments. Its
TEMP rows bind raw/projection/registry and the complete current Home/UDP runtime
digest; they are cleared before and after every Store call and omitted from
serialized archives. Runtime changes require a new selection basis. Missing
bytes or custody cannot inherit an earlier call's check. `ProfileSelectionHistory` validates exact
parent/review/journal ownership, declaration/resource/binding generations,
current pointers, maintenance and trust correspondence, and actual changed,
invalidated and unknown receipt counts. Artifact revocation must retain a barrier
for every then-selected target; later reapproval cannot conceal an omitted barrier.
`ProfilePinHistory` validates observation, original request, rule admission and
qualification pins in both directions, including missing pins in revoked gaps.
New owner rows capture their pin before mutation and retain it after their own
journal/receipt in the same Store transaction. Owning transitions repeat current
pins. Historic retries and archive checks preserve the original scope.

The selection transaction journals its new enrollment review, target selection
and final `portable_profile_selection_committed` operation in one transaction.
Target revocation journals `thing_profile_selection_revoked` and final
`portable_profile_target_revoked`; artifact revocation retains each target barrier
before its original `portable_profile_revoked` receipt. Immediate journal foreign
keys are satisfied before retaining selection rows; scoped parent foreign keys
are deferred to the same transaction. Selection and target revocation preserve
artifact trust/global profile-policy generations; approval and artifact revocation
advance them. All replacements increment resource/selection generations, clear
reports/source grants/overrides and revoke current qualification without deleting
old evidence. Existing maintenance already suspends rule policy and fences work;
any remaining pending effects are invalidated with handed-off uncertainty intact.
Ordinary narrowing and enrollment rereview refuse selected targets and require
the lifecycle path instead. This first review encoding preserves the already
reviewed stable identity/manufacturer/model/firmware tuple and refuses widening.
The v2 encoding below extends the transaction to initial external enrollment
and changed-firmware review while retaining this original v1 correspondence.

## Authored initial and changed-firmware review encoding

The next transition input is the closed at-most-64-KiB ordered UTF-8 JSON array
`["wotex-home.profile-selection-review.v2", mode, input_document, basis_values,
runtime_digest, captured_identity_values, enrollment_identity_digest,
proposed_thing_document]`. `mode` is exactly `initial` or `replacement`.
`basis_values` keep the v1 field order; `captured_identity_values` are ordered
stable identity, manufacturer, model and firmware. Canonical decoding rejects
extra fields/elements, whitespace substitution and malformed identity commitments.

Initial basis records resource/binding/selection revision and generation as zero;
prior stable identity/manufacturer/model/firmware and prior declaration are null.
These null fields mean the Store found no target or tombstone, not missing
capture evidence. The captured tuple remains separate and must match exact
artifact metadata and the fixed declaration binding. A new enrollment review
uses that fresh tuple in its existing reviewed-identity-v2 commitment. It creates
no control grant and remains pending physical qualification.

Replacement retains the prior Store-reviewed tuple and declaration in its basis.
The captured stable identity/manufacturer/model must match that tuple; captured
firmware may change only to an exact version in the newly approved artifact.
No-widening compares the proposed executable declaration with the retained prior
declaration. The new enrollment identity binds fresh captured firmware; an old
qualification cannot carry forward. Unchanged-firmware replacement continues to
emit v1, and v1 history decoding preserves its original exact correspondence.
Both decoders are historical checks without current registry/runtime or live
capture authority. Initial review summaries show null prior profile/freshness
and empty prior operations, never a fabricated prior declaration.

`Profiles.Review` and reconstruction/history fixtures were committed before
Store transitions consumed these encodings. The delivered transition distinguishes
absent targets from revoked targets, rejects occupied stable identities and used
review references, and creates enrollment/review/first selection atomically without
grants. Initial review links `thing_enrolled_reviewed`; replacement links
`thing_enrollment_rereviewed`. History validates initial zero/null basis, absence
of earlier target authority/reviews, and exact captured/new-review versus prior
binding correspondence. The same held-review/custody/runtime/deadline barriers
and retained pin rules apply. No schema migration is needed; existing rows retain
prior zero and new resource/binding revisions and full versioned review documents.
Scripted-peer cases exercise a registry product outside the compiled catalogue,
identity collision/tombstones, full initial rollback, firmware replacement and
old/new signed qualification history. They establish no physical qualification.
