# Controller transfer v1 mechanism

Version: 0.1.0. Accepted mechanism authored before its consumer, 2026-10-07.
Implementation remains open. This closes WOH.14/15/16 ownership recovery; it does
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
