# Controller transfer v1 mechanism

Version: 0.1.2. Accepted mechanism authored before its consumer, 2026-10-07.
The pure isolation codec is implemented; durable transitions remain open. This
closes WOH.14/15/16 ownership recovery; it does
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

The planned schema 21 adds only a singleton ownership origin/current head and
bounded immutable retirement receipts. A retirement receipt links to its
principal, same-epoch active maintenance predecessor and exact retirement
authority journal event. Validation rejects unmatched events in either
direction, substituted identity or head, post-retirement writes and missing
origin/history. Destination acceptance requires its own authored canonical
encoding and guarded transition; schema 21 alone never clears quarantine.

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
environment-specific requirements. No new schema is allocated by this document;
canonical receipt/row encodings must precede the durable writer.
