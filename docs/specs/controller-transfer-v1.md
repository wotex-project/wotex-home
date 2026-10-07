# Controller transfer v1 mechanism

Version: 0.1.22. Accepted mechanism authored before its consumer, 2026-10-07.
The isolation codec, schema 21 source retirement and trusted source delivery are
implemented; destination acceptance remains open. This closes WOH.14/15/16
ownership recovery; it does
not equate a database epoch, stopped process or signed assertion with physical
old-writer isolation.

## Source retirement and destination review

The single Store owns a persistent random deployment identity and controller
owner identity. These are opaque 32-byte values, not credentials or device IDs.
Migration creates local provenance without changing old receipts, epochs or
revisions; an old archive lacking this identity cannot become a retired-source
transfer by inference. A dedicated `host:transfer` principal has no maintenance,
profile, qualification or device grants. Retirement requires that permission,
an already active maintenance barrier, exact epoch/revision and an explicitly
chosen new owner identity. It retains an immutable scoped operation before
export. Retrying exact inputs returns the original receipt; altered inputs
conflict. Finite retirement/history capacity rejects excess without truncation.

Retirement permanently prevents new source mutations and new handoff while
preserving diagnostic/original receipt/export reads. It never refunds roots,
replays uncertain work or clears old history. The source Host is shut down
through its owning supervisor after the retired archive is exported; outstanding
handed-off work remains unknown. Ordinary startup refuses a retired source.
A process lock or this marker cannot fence another computer or an old copied
database. A qualified external isolation procedure is still mandatory.

The existing exact-byte encrypted archive transfers the retired snapshot.
Verification and staging remain inert. Destination review binds the authenticated
archive SHA-256, deployment/source owner, original epoch/retirement revision,
chosen destination owner, current destination runtime and a fresh one-use local
challenge. Challenge custody is private and descriptor-checked, has finite
capacity and original lifetime, and cannot be renewed by a retry. A stale
archive, different owner, missing byte, replaced challenge or changed runtime
requires another explicit review, not a permissive fallback.

## Isolation evidence

A closed signed isolation decision binds that complete destination review and
the exact domain set. The trusted host has explicitly provisioned issuer keys
outside the archive; no public route accepts a key or a caller truth map. There
are no default transfer keys. Its declared method is physical disconnection,
qualified network isolation or device credential revocation, with an exact
qualification/procedure reference. Merely stopping Home is not an isolation
method for unauthenticated LIFX. Authenticated-protocol counter/credential
continuity has its own complete dependency decision; absence is unknown, never
"not applicable" inferred from an empty file.

Signature verification establishes the trusted issuer and exact decision bytes.
It does not establish that the procedure happened: its actual cohort/host
qualification and private physical evidence remain the issuer's obligations.
Software fixtures use explicit disposable issuer keys and remain synthetic.
Missing/withdrawn issuer trust, unsupported method, incomplete domain coverage,
unknown counter continuity, expired decision or stale destination review blocks
activation. AI proposals, archive integrity and successful restart supply no
isolation decision.

### Ownership origin and retirement encodings

The Store-owned local bootstrap commits an origin as compact JSON
`["wotex-home.controller-origin.v1", [deployment_id, owner_id, authority_epoch,
store_revision, "local_bootstrap"]]`. Both identities are independent random
32-byte values encoded as lowercase hexadecimal. The bootstrap preserves the
existing positive epoch and nonnegative revision, creates no authority journal
event and gives no principal a new permission. The origin is retained unchanged.
Its identities, epoch and revision must correspond to the singleton ownership
row and its subsequent ownership history; an older schema is never interpreted
as a retired source merely because a later local bootstrap created this row.

Retirement input is compact JSON
`["wotex-home.controller-retirement-operation.v1", [authority_epoch,
operation_id, expected_revision, destination_owner_id]]`. The immutable receipt
is compact JSON
`["wotex-home.controller-retirement.v1", [principal_id, authority_epoch,
operation_id, expected_revision, deployment_id, source_owner_id,
destination_owner_id, maintenance_revision, revision]]`. Fields are closed,
IDs use Home's bounded syntax and integers use signed-64-bit bounds. Source epoch
and expected revision leave space for their required increment. Retirement
revision is exactly expected revision + 1; maintenance revision is positive and
at most expected revision. Source and destination owner identities differ.
Decode must re-encode to the same bytes; whitespace or alternative ordered
encodings cannot identify a durable operation. Retry scope is authenticated
principal, original epoch and operation ID, with exact input bytes.

Schema 21 adds only a singleton ownership origin/current head and
bounded immutable retirement receipts. A retirement receipt links to its
principal, same-epoch active maintenance predecessor and exact retirement
authority journal event. Validation rejects unmatched events in either
direction, substituted identity or head, post-retirement writes and missing
origin/history. Destination acceptance requires its own authored canonical
encoding and guarded transition; schema 21 alone never clears quarantine.

The trusted Authority provides separate one-time `transfer:local` provisioning
with only `host:transfer` and no target grants. That permission cannot be combined
with another permission or acquire a target through provisioning or later grant
rotation. These are in-process trusted operations; no socket route gains setup,
retirement, archive keys or activation from this slice. Source retirement repeats
complete origin/head/history validation outside and inside its transaction,
records one immutable receipt and exact journal event, and permits only original
receipt/diagnostic/export reads afterward. Every other Store call is refused,
including observation, credential, maintenance, profile and handoff mutations.
Claimant termination cannot append a new mutation after retirement. Normal
startup refuses the retired source before handed-off recovery. This local marker
does not stop another copy or establish physical isolation.

Focused SQLite tests cover scoped retry/conflict/privacy, separate authority,
all four retirement write failures, substituted origin/head/journal/epoch/input
and post-retirement revision, schema 20 archive/migration preservation and
retired exact-byte archive quarantine. A fixture also preserves an unknown
handed-off receipt and spent causal root. Source shutdown/reopened diagnostic
delivery is now implemented; destination acceptance remains the next stage.

### Trusted source delivery

The foreground `retire-export EPOCH OPERATION_ID EXPECTED_REVISION
DESTINATION_OWNER_ID ARCHIVE` command receives exactly two private stdin lines:
the original transfer credential, then the archive key. Each is 32 bytes encoded
as 43 canonical unpadded URL-safe Base64 characters plus LF. Neither secret is an
argument, environment setting, structured output or archived device credential.
Explicit one-time transfer bootstrap retains the existing trusted foreground
custody pattern. Ordinary socket and native control routes do not gain this
operation. The command retires the current opted-in Host through Authority,
exports all retained exact profile bytes and validates the published archive
against the complete original retirement receipt before stopping the Host under
its owning application supervisor. An export failure leaves the source retired;
it cannot restore source authority. Existing archive retry is accepted only if
its authenticated exact receipt matches and all retained bytes verify. An
unrelated archive or wrong key cannot be overwritten or reused as success.

After interruption, `export-retired SOURCE_DIRECTORY ARCHIVE` runs offline with
only the archive-key stdin line. An isolated source-reader supervisor acquires
the usual Store lock before custody, requires existing canonical private source
and profile roots, validates already-retired schema/history without migration,
and starts no socket, capture, review gate or device worker. It exposes only
retained diagnostic/original receipt/export reads; all new source writes remain
refused. A normal source, quarantine, missing byte, active writer or substituted
root is refused. Its owning supervisor closes every child after export. This
supports interrupted delivery, not destination activation or physical fencing.

Archive verification returns the SHA-256 and size of the exact descriptor-read
encrypted bytes it authenticated. That digest binds later destination review;
it is not inferred from a second path read or inserted into its own archive.

Seven source-delivery tests exercise retained byte export/retry, complete receipt
correspondence, wrong keys/archives, active-writer refusal, quarantine/normal-root
refusal, missing bytes, closed read-only children and application-supervisor
shutdown. Actual foreground and offline child scripts consume both stdin secrets
without returning them. Fixtures disable optional network/capture/write settings
before host startup and qualify no physical source isolation or installed host.

### Closed isolation package and signature encoding

The package is a strict duplicate-free UTF-8 JSON object of at most 8,192 bytes,
with exactly `decision` and `signature`. The decision has exactly the ordered
fields below; the package's object order and insignificant whitespace are not
part of the signature. No field supplies a public key or a trusted clock.
Signature is exactly 64 Ed25519 bytes encoded as 86 canonical unpadded URL-safe
Base64 characters. The signed payload is the ASCII domain
`WOH15-controller-isolation-v1` followed by one NUL byte and compact UTF-8 JSON
of this ordered array:

```
[format, deployment_id, source_owner_id, destination_owner_id, source_epoch,
 retirement_revision, archive_digest, review_digest, runtime_digest,
 challenge_id, domain_digest, domain_count, counter_state, counter_state_digest,
 method, procedure_ref, issuer_id, issuer_generation, isolation_policy_digest,
 issued_at_utc_ms, expires_at_utc_ms]
```

`format` is `wotex-home.controller-isolation.v1`. Identity and digest fields are
64 lowercase hexadecimal characters; source and destination owners differ.
Epoch, retirement revision and issuer generation are positive signed-64-bit
integers, and source epoch leaves room for one increment. Domain count is 0–64.
Challenge, procedure and issuer references use Home's bounded opaque ID syntax.
Methods are exactly `physical_disconnection`, `qualified_network_isolation` or
`device_credential_revocation`. Counter state is exactly `no_radio_state` with
null digest, or `verified_continuity` with a complete digest. An unknown counter
state cannot be signed as accepted. UTC issue/expiry are nonnegative signed-64-bit
milliseconds, with a positive lifetime at most 600,000 milliseconds.

The canonical historical document is compact JSON
`["wotex-home.controller-isolation-record.v1", ordered_values, signature]`.
Its SHA-256 is the decision digest; the separately retained package digest is
SHA-256 of the original exact package bytes, including whitespace. Construction
and decoding alone authorize nothing. Verification repeats all thirteen scope
fields from deployment identity through counter-state digest against the trusted
review. It requires an explicitly trusted clock with issue ≤ now < expiry, and
an out-of-archive issuer policy with exactly public key, generation, method,
procedure reference, policy digest and counter state. Each policy commitment
must match the signed claim. Issuer capacity is eight; there are no default keys.
Historical signature records never install or revive current issuer trust.

Eight pure tests cover every substituted scope field, every issuer-policy
commitment, wrong keys/forgeries, original expiry bounds, closed counters and
methods, duplicate JSON names and bounded/canonical signatures. This is software
codec evidence; no source was physically isolated by these tests.

## Store-owned acceptance

### Complete retained device domains

The implemented inert v1 domain document is compact JSON
`["wotex-home.controller-domains.v1", logical_snapshot_digest, domain_records]`.
New acceptance uses the authored v2 document
`["wotex-home.controller-domains.v2", logical_snapshot_digest, source_counts,
domain_records]`. The count array is exactly `[principal_rows,
active_principal_rows, qualified_profile_heads, current_observation_rows,
target_grant_rows, source_grant_rows, override_lease_rows]`, read from all actual
source rows, without filtering by the receiving principal. Each is an integer
0–131,072; active principals cannot exceed total principals. V2 binds these
original counts into domain/review/isolation SHA commitments so acceptance
receipts can validate their revocation/clearing counts after mutable rows have
been withdrawn. Fresh acceptance requires total principals at most 63, qualified
heads/override leases at most 64 and receipt counts equal these signed values.
V1 remains inert historical data and cannot supply these missing commitments
for fresh acceptance; it is not reinterpreted as v2.

The v2 source-count derivation and inert receipt correspondence check are now
implemented. Eleven database/domain tests include all retained principals,
revoked principals, actual current reports, target/source grants and live leases,
and preserve exact source/quarantine correspondence. Nine acceptance-codec tests
include every withdrawal-count substitution, over-capacity source custody and
non-integer/extra/missing count fields. These checks neither withdraw authority
nor accept quarantine; the guarded transaction must use the same actual counts.
SHA-256 of these exact bytes is domain digest; domain count is the number of
records. It derives read-only from the validated retired source/quarantine,
never a caller-supplied list. All enrolled Things are included, including
revoked Things and currently read-only capabilities. Scope is the whole Thing,
matching the existing shared effect domain, so narrowing or disabling a current
capability cannot omit an older physical/credential dependency.
The target set also includes every retained observation journal/current report,
request/execution and qualification target. A retained target without a current
declaration encodes `[target_id,"unresolved",null,null,null,[],null,[],[],
["unknown"]]`; it cannot disappear from scope or establish counter absence.

Records sort by binary target ID and have exactly this field order:

```
[target_id, status, profile_ref, resource_revision, declaration_digest,
 current_capabilities, current_binding, identity_history, selection_history,
 current_transport_basis]
```

Capabilities sort by key and encode `[key, sorted_operations, risk_class,
value_kind, unit]`. Current binding is the exact eleven-column schema 21
`enrollment_bindings` row, or null if absent. Identity history sorts by revision;
each entry is `[history_values, transport_basis]`, where values are the exact
fourteen-column schema 21 `enrollment_review_history` row. Selection history
sorts by revision and encodes `[revision, generation, state, artifact_digest,
projection_digest, resource_revision, binding_revision, runtime_digest,
declaration_digest, capabilities, transport_basis]`. Every historical declaration
and transport is checked, even for revoked/superseded selections. The complete
logical snapshot commitment also binds all credentials, grants, reports, rule
dependencies and retained roots/requests without returning their private bytes.

A resolved transport basis is `["lifx-direct-power-v1", "udp",
"no_authenticated_radio_state", profile_ref, stable_id, manufacturer, model,
firmware, "compiled"|"portable", dependency_digest]`. It requires complete v2
identity, legacy TOFU, a valid LIFX target, exact packaged fingerprint or retained
fixed portable binding/fingerprint and the closed direct-power declaration.
Compiled dependency digest is the installed catalogue digest; portable digest
is the validated retained projection digest. These establish software dependency
classification, not device identity authentication, current approval, profile
qualification or physical isolation. Missing/legacy/unsupported bindings encode
`["unknown"]`, without inventing transport from a name or capability role.

Only a nonempty complete domain set whose current and every historical identity/
selection resolve through this known LIFX binding yields `no_radio_state` with
null counter digest. Empty sets, missing metadata and unsupported/coarse
dependencies yield inert `unknown`, which cannot produce accepted isolation
scope. Radio or authenticated credential/counter continuity needs its own
complete qualified source custody and is never synthesized here. A historical
report/request/qualification profile reference outside that
Thing's complete resolved identity/current profile set also makes its current
transport basis unknown. This refuses unsupported historical protocol traces
even if the latest declaration is a known LIFX profile. Limits are 64
domains, 32 identity records per Thing, 2,048 total selection records and
4,194,304 document bytes. Exhaustion rejects the whole set without truncation.
Private identity-domain documents stay in trusted recovery custody and are not
returned through normal sockets, logs or support summaries.

This complete domain derivation and its trusted retired-archive basis are
implemented. Ten SQLite/Store/archive tests cover known compiled LIFX, exact
source/quarantine parity, empty and unbound sets, revoked/read-only targets,
superseded compiled plus selected/revoked portable history, historical v1
metadata, 64/65-domain refusal, undeclared retained targets and unsupported
historical transport traces. Fixtures create no physical isolation, counter
qualification or enabled dispatch.

### Separately provisioned destination owner

Trusted foreground `new-owner OWNER_FILE` takes no secret stdin and starts no
Home service. It creates independent random 32-byte destination owner bytes,
encoded as lowercase hex in exact compact JSON
`["wotex-home.controller-owner.v1", owner_id]`, without a newline. The exact
document SHA-256 is owner-custody digest. The returned summary contains only
owner ID and digest. This opaque identity grants no permission, issuer trust,
activation or physical isolation. It is chosen before source retirement and
held outside the arrived archive and restore directory.

The explicit absolute canonical file destination has an existing symlink-free
0700 parent. New custody uses an exclusively created private temporary file,
descriptor/path identity checks, synchronization, 0400 final mode and a
non-replacing hard link followed by directory synchronization. Reads require
exact bounded canonical bytes, a single regular 0400 file owned by its private
parent, pinned ancestor and descriptor identities and a stable complete read.
Existing custody is never replaced; retries use an explicit read of the original
file rather than generating a new identity. Missing, aliased, replaced,
over-permissive or malformed custody blocks destination review. This local
private file mechanism is implemented and does not establish installed Keychain/host identity
qualification; a host-account owner is outside its protection boundary.

Seven owner-custody tests cover distinct random identities, exact commitments,
non-replacement, bounded canonical documents, modes/hard links/symlinks/parent
aliases, both synchronization failures and parent substitution. An actual child
foreground command receives no key and leaves Home database/socket absent.

### Authenticated source and quarantined snapshot correspondence

Trusted archive decoding reports SHA-256 of the exact authenticated source SQLite
bytes as snapshot digest, separately from encrypted-container digest. Transfer
basis requires an inclusive archive and its validated retired ownership head,
original retirement receipt, active source maintenance and source rule generation.
Neither a database-only archive nor a normally active source creates this basis.

Quarantine publication changes SQLite serialization. Correspondence therefore
also uses a closed logical snapshot commitment derived read-only from the actual
authenticated database, not caller-provided row lists. SHA-256 input begins with
ASCII `WOH15-controller-snapshot-v1` plus NUL, then compact JSON
`["wotex-home.controller-snapshot.v1", schema_version, schema_objects]` plus NUL.
Schema objects are exact `[type, name, table_name, sql]` rows from `sqlite_master`,
including indexes, views and triggers, sorted by those first three fields with
binary collation; implementation-owned `sqlite_*` objects are excluded.

For each retained table in binary name order, append compact JSON
`[table_name, column_names_in_schema_order]` plus NUL, followed by each full row
as compact JSON of `[sqlite_type, uppercase_hex_bytes]` cells plus NUL. Cells
use SQLite `typeof` and `hex`; permitted types are null, integer, text and blob.
Rows sort by each corresponding type/hex pair with binary collation. This binds
all retained history, permissions, hashes, observations, policies and ownership,
including revoked or currently unused rows; it does not compare only current
heads. SQL identifiers must use the existing lowercase/underscore schema syntax.
Bounds are 64 schema objects, 64 tables/columns, 131,072 total rows and 134,217,728
transcript bytes. Exhaustion refuses the whole basis without truncation.

The source contains no quarantine marker. The destination must contain exactly
the integer `restore_quarantine=1`; this single meta row is excluded from the
logical commitment and every other row/schema byte remains bound. Both sides
repeat their supported-schema integrity gate and retired ownership validation.
A marked database with a missing, additional, altered or differently typed row,
substituted schema, extra trigger or different original source refuses review.
The comparison uses Store-owned borrowed SQLite only; no public route receives
a connection or permits marker clearing. A matching snapshot is inert and
creates no acceptance, current report, grant, runtime or isolation authority.

The full commitment and trusted inclusive retired-archive basis are implemented.
Seven SQLite/archive tests cover authenticated source/container commitments,
serialization and row-order independence, altered unused credential/permission/
status rows, additional rows/triggers/views and a removed index, exact marker
type/value, complete budget refusal and rejection of active/database-only
archives. Staged copies still refuse ordinary Store startup. No test activates
an archived principal or qualifies source isolation.

### Destination review encoding

The authored destination review is compact JSON
`["wotex-home.controller-transfer-review.v1", ordered_values]`, with exactly this
field order:

```
[deployment_id, source_owner_id, destination_owner_id, source_epoch,
 retirement_revision, source_maintenance_revision, source_rule_generation,
 archive_digest, snapshot_digest, runtime_digest, owner_custody_digest,
 challenge_id, principal_id, credential_hash, permissions_document,
 domain_digest, domain_count, counter_state, counter_state_digest,
 issued_at_utc_ms, expires_at_utc_ms]
```

SHA-256 of this exact canonical document is the review digest. Identities,
credential commitment and all digest fields are lowercase 64-character hex;
reference IDs use Home's bounded syntax. Source epoch leaves one increment and
retirement revision leaves the three acceptance revisions. Source maintenance
revision is positive and precedes retirement; rule generation leaves an empty
generation increment. Snapshot digest refers to the exact authenticated source
SQLite bytes, before quarantine publication; archive digest refers to the exact
authenticated encrypted container. Neither is inferred from unverified paths.
Owner-custody digest binds separately provisioned local owner bytes outside the
archive. Principal and credential hash bind fresh private receiving custody,
not an arrived principal or bearer. Permissions document is exactly compact JSON
of `["read","host:maintain","profile:manage","enroll:review"]`. The operator
explicitly reviews that fixed recovery scope, which has zero Thing, control,
qualification or policy grants; no archived principal is reused.

Review lifetime is positive and at most 600,000 UTC milliseconds. Original
one-use custody also enforces its own boot/monotonic deadline and cannot renew
that lifetime across retry/restart. The complete domain set is derived from
validated source declarations, identity/history and actual transport/counter
dependencies; its count is 0–64. Counter state may be `unknown` with null digest
in an inert review, or either accepted state defined by the isolation codec.
Unknown dependency state makes the review ineligible for signing/acceptance.
An empty file or unavailable adapter does not establish `no_radio_state`.

The implemented pure codec re-encodes on decode, bounds the document to 4,096 bytes and derives
the isolation verifier's exact thirteen-field expected scope, including the
complete review digest. It creates no challenge, key trust, principal, quarantine
exception or Store authority. Domain derivation, private review custody and the
durable acceptance encoding/writer remain separate next stages.

Six pure review tests cover exact field order and scope, fresh custody/snapshot/
barrier/lifetime substitution against a signed decision, inert unknown counters,
the fixed recovery permission set, signed-64-bit/domain/time limits and closed
canonical documents. These establish review encoding, not activation or isolation.

### Destination acceptance encodings and atomic barrier

Authored canonical operation input is compact JSON
`["wotex-home.controller-acceptance-operation.v1", ordered_values]`:

```
[principal_id, source_epoch, operation_id, retirement_revision,
 destination_owner_id, review_digest, isolation_package_digest]
```

Original retry scope is the fresh receiving principal, source epoch and operation
ID, with these exact input bytes. The original fresh credential proves receipt
ownership; arrived bearers cannot use this scope. Exact committed retry returns
the original receipt without clearing another marker, renewing a challenge,
advancing another epoch or rerunning any effect. Changed inputs conflict.

The canonical receipt is compact JSON
`["wotex-home.controller-acceptance.v1", ordered_values]`:

```
[principal_id, source_epoch, authority_epoch, operation_id, retirement_revision,
 source_maintenance_revision, source_rule_generation, rule_generation,
 fence_revision, principal_revision, revision, deployment_id, source_owner_id,
 destination_owner_id, review_digest, isolation_package_digest,
 isolation_decision_digest, domain_digest, domain_count, counter_state,
 counter_state_digest, revoked_principals, revoked_qualifications,
 cleared_observations, cleared_target_grants, cleared_source_grants,
 cleared_override_leases]
```

Both documents are closed, re-encode identically and have a 4,096-byte maximum.
IDs and hex digests use the same bounded syntax as the review. Source/destination
owners differ; source epoch advances once. Source retirement leaves room for
three revisions: fence is retirement + 1, fresh principal is retirement + 2 and
receipt/ownership/maintenance is retirement + 3. Source maintenance is positive
and precedes retirement. Rule generation advances exactly once from a positive
source generation. Domain count is 0–64; counter states follow accepted isolation
encoding, excluding unknown. Revoked-principal count is 0–63; qualification and
override-lease counts are 0–64. Observation and target/source-grant counts are
0–131,072 and bind actual transaction changes, without truncating retained history.

Schema 22 is allocated for this guarded acceptance, preserving actual schema 21
origins/retirements. A bounded `controller_acceptances` row retains the scoped
input/receipt, exact canonical review, original isolation package bytes and
canonical signed record, separate historical issuer-policy document and complete
private domain document. Its final revision links to exactly one
`controller_destination_accepted` authority event for `controller:<deployment>`.
No archive installs that historical public key as current trust. Historical
signature checking validates signature, original closed scope and policy but
does not require a past decision to be unexpired today or authorize new work.
Current acceptance always uses the live trusted-clock/issuer verifier instead.

The ordered schema 22 acceptance row is `[principal_id, source_epoch,
operation_id, input_document, receipt_document, review_document,
isolation_package, isolation_document, issuer_policy_document, domain_document,
revision]`. Its first three fields are the immutable operation primary key;
principal and final revision have owning principal/journal foreign keys, with a
unique final revision. Each document uses its already closed bounded encoding.
The domain document is canonical, at most 4 MiB, with at most 64 strictly sorted
unique targets, 32 identity entries per target and 2,048 selection entries in
total. Nested row fields, exact binding/history correspondence, sorted unique
capabilities/operations, integer revisions/generations, nullable legacy identity
metadata and resolved transport/identity/profile correspondence are checked.
No unknown domain can become complete by decoding its document. Only the current
implemented nonempty complete LIFX v2 domain set can supply acceptance counts and
`no_radio_state`; its unauthenticated protocol permits physical disconnection or
qualified network isolation, never device credential revocation. A historical
decoder does not consult current installed author trust or reactivate a profile.

Historical row audit repeats operation/receipt/review/domain digest and count
correspondence, exact original package versus canonical signature identity and
historical policy signature checking. The signed decision's issue/expiry window
must lie within the original review window. Owner, epoch, principal, operation,
barrier/generation and all three revisions remain exact; review credential hash
and zero-target fixed permissions are retained for the separate principal audit.
This read-only row audit installs no schema, current key, clock or authority.

Canonical historical domain decoding and complete acceptance-row audit are now
implemented. Eight pure record tests cover resolved/unknown/v1/v2 domains,
nested bounds and correspondence, portable selection projection, every retained
row commitment, signed count/scope substitution, original review expiry and
unauthenticated method refusal. Twelve database-domain tests repeat decoder
correspondence against actual retained source data, including a historical
capability outside the supported power transport. Unsupported retained
capabilities now keep a domain incomplete even when its profile reference is
known. The focused domain/record/count/signature/snapshot run passed 44 tests;
no schema 22 row, quarantine acceptance or physical isolation is established.

Normal migration from active schema 21 creates an empty acceptance table and
extends the maintenance action CHECK without changing any existing row, origin,
revision, epoch, rule generation or permission. Normal startup checks retired
ownership before migration or recovery writes. A retired schema 21 source stays
schema 21; its no-migration export reader and exact historical archives remain
supported. Destination acceptance checks original schema 21 correspondence
first, then installs schema 22 inside the same transaction as acceptance, so a
failed transition restores the original schema as well as all source rows.
Schema 22 retired sources already have that table and need no schema rewrite.

Retained receiving principal permissions remain the exact fixed recovery scope.
Its original credential hash is required until a later owning credential-rotation
event; the signed review continues to retain the original hash after rotation.
Historical validation does not require an old receiving principal to remain
active after a subsequent transfer. Retirement principals similarly keep their
exclusive transfer scope. Ownership transitions have a shared 64-row bound;
each active head can retire once and each retired head can accept once, with no
omitted, reordered, reused or unmatched journal event. A transferred maintenance
barrier can itself be the predecessor of a subsequent reviewed transfer while
its source remains under maintenance; ordinary end requires that same epoch.

Schema 22 storage, active-schema migration, retired pre-migration refusal and
read-only alternating ownership/transfer-barrier validation are now implemented.
Backup verification preserves exact schema 21 tables and adds schema 22's
acceptance table; complete source correspondence supports both versions.
Five actual database schema cases cover unchanged active authority, permanently
historical retired source/export, outer-transaction DDL rollback, exact quarantine
requirements and corrupted/unmatched ownership events. The focused migration,
qualification, profile and maintenance run passed 50 tests; the full suite
passed 783 tests with four optional native-helper skips and all socket cases
included. These checks install
no accepted destination receipt; guarded recovery custody and the acceptance
writer remain the next delivery stages.

Historical issuer policy is compact JSON
`["wotex-home.controller-isolation-policy-record.v1", [issuer_id, public_key,
generation, method, procedure_ref, policy_digest, counter_state]]`. Public key is
32 Ed25519 bytes in 43 canonical unpadded URL-safe Base64 characters; remaining
fields match the isolation decision and six-field current policy exactly. The
document has a 4,096-byte maximum and re-encodes identically. This historical
record describes trust at acceptance; decoding or auditing it never creates
present issuer trust, trusted time or a quarantine exception.

The pure operation/receipt/policy codecs and separate historical signature audit
are implemented. Eight tests cover all closed ordered documents, exact integer
epoch/generation/three-revision arithmetic, original private commitments, finite
change counts and accepted counters, canonical public policy bytes, expired audit
versus current trust/time refusal, substituted policy/key/scope/signature and
separate original-package versus canonical-signature identity. Source retirement
also rejects a numerically equal floating revision on live use, archive
verification and startup. These codec/audit results create no schema 22 row or
activation; guarded recovery custody and the transaction remain next stages.

Before new acceptance, the recovery Store repeats exact archive/source/quarantine,
owner/challenge/runtime/domain/credential/scope/trust/time correspondence and
requires no held or pending executable source work. An inconsistent source
barrier is refused instead of performing extra writes outside the three-revision
receipt. The fresh principal ID and credential hash must both be absent from
arrived custody. Total retained principal capacity is 64; ownership transitions
are bounded to 64, shared across retirement and acceptance. Existing history is
never deleted or reused to make capacity. Complete snapshot/archive size limits
still apply to the retained acceptance documents.

In one Store transaction, epoch advances, the empty rule fence is appended,
old principals become revoked and target/source grants, current observations and
override leases are cleared. Current qualification heads become revoked while
their original snapshots/revisions remain. Fresh reviewed recovery principal
provisioning appends its own event with zero targets. Final acceptance persists
its complete records, changes the owner/head, clears exactly the quarantine
marker and establishes a maintenance row with action `transfer`, original source
maintenance predecessor and new epoch/generation/fence. Its final revision is
the new active maintenance marker and its journal event is shared with acceptance.
All counts and canonical links are checked before commit; rollback restores every
source row, epoch, quarantine marker and custody correspondence.

Maintenance history extends its strict predecessor chain for the transfer row;
ordinary `end` accepts the same-epoch transferred barrier and leaves rules empty.
The origin is retained unchanged. Ownership history alternates retirement and
acceptance, matching owners, epochs, revisions and barrier predecessors in both
directions. A retired source cannot resume writes, and a read-only source reader
cannot accept even a valid signature. The recovery owner closes after delivery;
ordinary Host startup is a separate step with dispatch still disabled.

Only a trusted recovery-mode Store may open the marked quarantine. It acquires
the usual host lock, validates the complete snapshot and exposes no normal host,
socket, device worker or ordinary mutation capability. It consumes only the
exact one-use reviewed decision after repeating current runtime, trust, byte,
identity, epoch, revision and challenge guards outside/inside the transaction.
No caller supplies a SQLite connection, clock, private device credential or
marker-clearing request. Transaction failure preserves quarantine and all prior
records; the original operation resolves an uncertain reply without replay.

Acceptance preserves the deployment identity, changes controller owner and
advances authority epoch once. It appends the ownership event, advances an empty
rule generation and retains an active maintenance barrier belonging to the new
epoch. It clears current reports/source grants, revokes qualification and old
principals/grants/overrides, and retains every original receipt, declaration,
selection, qualification snapshot and spent root. Retained selected profiles
remain unavailable under withdrawn authors/trust until fresh local approval and
reviewed selection; restoration never makes an old selection usable by itself.

The receiving operator explicitly provisions fresh recovery custody with no
Thing grants; no archived bearer becomes current. Maintenance end requires the
new transfer barrier and leaves rules suspended. New profile/enrollment review,
target grants and physical qualification retain their separate procedures.
Physical dispatch remains default-disabled even after acceptance. Ownership
history, retirement/acceptance journals, barrier predecessors and epoch/generation
chains must validate in both directions on live use, startup and every supported
archive. Historical signed decisions are audit records, not current trust.

Required software cases cover principal-private lost replies and input conflicts,
retired source startup refusal, cross-owner/archive/runtime substitution, absent
issuer/method/counter evidence, original challenge expiry and consumed-token retry,
all multi-row rollback boundaries, preserved unknown outcomes/spent roots,
revoked archived credentials and unavailable old selections, new maintenance
end, migration and encrypted historical recovery. Real source isolation,
installed identity/key custody and radio-counter/power-loss behavior are separate
environment-specific requirements. Schema 21 implements the authored origin and
retirement encodings; a destination-acceptance schema requires its canonical
receipt/row encodings before the durable writer.
