# Controller pairing consumption v1

Version: 0.1.1. Owner: WOH.14, WOH.15 H15-07/H15-T8, WOH.16. Status: schema-28 atomic pairing, retained original status, trusted revocation and real core listener composition implemented; installed host identity setup and pairing remain planned.

This closes the Store transition following the [finite local review](controller-pairing-review-v1.md).
It is a trusted in-process Authority use case, absent from ordinary API routes.
An approval document alone cannot authorize it. The separate
[post-TLS listener](controller-listener-v1.md) now composes it while retaining
the existing [transport and identity requirements](controller-connections-v1.md).

## Canonical retained original

```text
["wotex-home.controller-pairing-consumption.v1",
 <complete canonical approval array>,principal_id,revision]
```

The nested approval uses the unchanged [review encoding](controller-pairing-review-v1.md).
The outer body is canonical UTF-8 JSON, 1–8,192 bytes, at most three array
levels, 32 members per array and 128 bytes per string. Objects, extra fields,
whitespace, alternate spellings and trailing bytes refuse. The typed map has
exactly `approval`, `principal_id` and `revision`. The principal is exactly
`paired-controller-v1:<authority_epoch>:<client_id>`, with canonical decimal
epoch and the original 64-character lowercase hexadecimal client ID. Revision
is exactly the approved expected Store revision plus one. Neither bootstrap
secret nor application credential belongs in this record.

Schema 28 adds `controller_pairings`, keyed by globally one-use invitation ID,
with unique principal and decision revision. Its columns are `controller_id`,
`invitation_id`, `client_id`, `request_id`, `request_digest`, `authority_epoch`,
`principal_id`, `approval_document`, `receipt_document`, `credential_hash` and
`revision`. Only the original 32-byte SHA-256 application verifier is retained;
the raw application credential is generated once for the successful response.
The reserved principal namespace cannot be issued through generic provisioning.
At most 1,024 consumed associations are retained; denial, restart, revocation
and lost response do not delete history or refund that capacity.

## Atomic Authority and Store composition

`Authority.pairing_complete` validates the closed original bootstrap request
and checks durable invitation consumption before accessing transient review.
A consumed invitation always refuses as `invitation_consumed`, including after
restart or lost credential delivery. It never returns an old or current bearer.
An available original requires the configured review owned by the same Store,
the live selected approval and a checkout bound to the actual caller PID.

Only the bound Store PID can obtain a commit basis from that checkout. Store
uses its own boot, active deployment/owner/epoch, revision CAS, maintenance
guard, exact permissions and currently active explicit targets. It generates
a fresh credential distinct from the bootstrap secret, using only the review's
private verifier for that comparison. One SQLite transaction creates the
principal and target grants, original `principal_provisioned` journal event,
revision and immutable consumption row. The live review/caller/approval guard
is repeated after tentative writes and before commit. No caller-supplied
callback or approval token replaces it. Failed guard or any publication failure
rolls back all these rows and the revision. Checkout cleanup runs on success,
refusal and uncertain delivery; an exit during commit returns `outcome_unknown`.

Default access is exactly read with no targets. Explicit approved access uses
the closed wire permission policy and at most 32 distinct active targets.
Pairing grants no physical qualification, ownership transfer or automatic
dispatch. A controller/client/epoch can have only one derived principal;
replacement after revocation needs a fresh invitation and fresh client ID.

## Original status, revocation and recovery

Trusted `pairing_client_status` and `revoke_paired_client` require the exact
five-field original lookup: controller ID, invitation ID, client ID, request ID
and request digest. Another original for the same invitation conflicts; absent
invitation is not found. Status separates the immutable consumption receipt
from current disposition and current Store revision. Active-source disposition
is `active` or `revoked`; a still-active principal on a retired source reports
`source_retired`. Retirement fences writes without rewriting principal history.
Destination acceptance subsequently revokes old principals and clears grants.

Revocation requires current Store revision CAS, uses the existing principal
revocation transaction and returns the resulting status. Exact already-revoked
lookup remains idempotent. Revocation cannot recover or replay the bearer.
Later trusted target grants, removals and credential rotations keep the original
receipt unchanged. Current grants must match the latest exact target journal
transitions; verifier changes require the existing trusted rotation history.
These checks establish database correspondence, not cryptographic authenticity
against an attacker able to rewrite the whole database and its journal.

Startup, paired authentication, Store writes and backup verification validate
the complete association, canonical approval/receipt, original journal link,
owner/epoch interval, permissions and current grant/status correspondence.
Plain Store backup export also checks this history before writing an archive.
Schema-27 migration creates an empty table and no authorization or revision;
namespace collisions or invalid history roll back before publishing schema 28.
Historical archives retain their own table sets. New backup dependency reports
include `controller_pairing_rows` and explicitly deny credential reissue.
Restore remains quarantined. Transfer acceptance retains pairing originals,
withdraws archived authority and does not reactivate pairing windows or secrets.

## Evidence boundary

`test/fixtures/controller_connections/consumption_vectors.json` independently
authors canonical outer records and refusal cases. Codec tests check those
bytes, exact maps and original lookup bounds. Actual SQLite/process tests cover
concurrent completion, exact access, wrong caller/Store, CAS changes, publication
rollback, deadline expiry after tentative writes, restart, lost delivery, exact
revocation, immutable status, current grant damage, source retirement, migration
rollback and damaged startup/backup. Private snapshots and OTP status are checked
for raw-secret absence. Transfer tests check retained associations after actual
software acceptance. These checks do not establish installed identity custody,
installed LAN activation, client Keychain selection, storage power-loss survival or
physical qualification. Those remain H15-T8/H08-T9 and their host obligations.
The listener annex records separate actual socket/Store parity and independent
Apple bootstrap provisioning/replay checks; its trusted Host option is not an
installed setup workflow.
