# Portable profile ledger v1 mechanism

Version: 0.1.0. Implementation design for WOH.18 P2/P3, 2026-10-07.
Schema 19 is the next actual migration from the current schema 18. It must not
enable external selection before its integrity, historical backup and effect
guards are complete. The current Store remains schema 18 until that delivery.

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
lifecycle operations and 64 current Thing selections in the first delivery.
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

GC may remove only inert, unreferenced artifacts/stages. Store serializes the
reference snapshot and custody collection against new admission/selection;
custody additionally checks caller leases. No deletion removes metadata,
receipt tombstones, selection history or pinned external dependencies. When
retained history fills capacity, refuse new admission. Archival retirement is
a separately reviewed future mechanism.
