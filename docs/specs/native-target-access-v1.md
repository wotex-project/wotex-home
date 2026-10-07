# Native target access v1

Version: 0.1.1. Accepted mechanism with pure review correspondence, 2026-10-07. WOH.08 owns the signed native
flow; WOH.14/15 own receipts and the Authority/Store boundary. This is explicit
target access for the existing native operator, not credential rotation,
enrollment, profile approval, control dispatch or physical qualification.

The four setup roles still start with zero Thing grants. Only the current
`native-setup-v1:<epoch>:operator` may receive a target through this profile.
Diagnostic, maintenance and transfer stay ungranted. Native original Keychain
bytes, verifier, creation event and fixed permission set remain unchanged.
Generic trusted provisioning/rotation stays forbidden in the native namespace.

The first profile accepts exactly one ordinary writable power capability on
an enrolled Light with a selected portable profile. Additional channels require
their own reviewed encoding; this profile cannot grant them implicitly.
The app explicitly reviews that Light's power capability
and selected profile identity, then requests Grant Access. No import, discovery,
profile selection, role selection or AI proposal grants access automatically.
Grant checks the exact current Store revision, resource revision, binding
revision, portable profile selection generation and artifact digest, with live
reviewed identity and active usable declaration. A declaration or profile change
requires a fresh review. Access permits scoped reads and ordinarily authorized
requests; all physical dispatch and qualification gates still apply separately.

Profile selection, declaration or reviewed binding changes withdraw affected
native target grants in the owning Store transition, before exposing changed
capabilities. Revoking/reapproving artifact trust also cannot revive access.
Derive retained grant status from its original selected profile/trust/binding
basis and lifecycle history; unavailable bytes alone do not reset custody or
rewrite receipts. A fresh explicit review is needed to grant a changed basis.
Keep generic trusted principal/target revocation effective and irreversible by
receipt retry. All of these lifecycle joins require actual transaction evidence
before delivering native access.

Revoke Access explicitly removes one existing grant. It must remain possible
when the target has since become unavailable. Both operations require the exact
active controller and original native custody, finite signed peer/child-owner
guards and existing-only Keychain reads. Neither operation ensures a role or
creates a secret. No ordinary API or arbitrary bootstrap request is added.

The single Store owns the transaction. Its native access ledger keys original
principal/epoch/operation and binds the canonical input digest. Check original
custody before either first mutation or existing-result lookup. A matching
committed retry returns its immutable receipt without another revision; changed
input under the same identity refuses. Missing status is not resolution. A new
grant for an already granted target, or new revoke for a missing grant, refuses
without a write. Retain at most thirty-two target grants per native operator
and 1,024 original access receipts across all retained ownership epochs; no
receipt/history eviction or credential substitution is allowed at capacity.

Use the existing principal-scoped invalidation transitions for both operations:
reject held/queued/claimed work and mark dispatched/protocol-accepted work
unknown; never recall a packet or refund causal spend. Clear original live
override leases. One authority change event consumes `expected_revision + 1`;
each affected request consumes its existing rejection/unknown revision. The
immutable final revision is change revision plus affected requests, with
unknown outcomes a subset. No rule or request is activated by a grant.
Actual ledger/schema/integrity/backup/transfer joins must precede delivery.
Transferred native principals and access receipts remain inactive history;
new owners create separate zero-target custody, without copied grants.

The inert codec is `wotex-home.native-target-access.v1`, a canonical compact
JSON array, at most 4,096 bytes, one array depth, sixteen scalar members and
128 bytes per string. Reject objects, nested arrays, nulls, booleans, floats,
alternate numbers, escaping alternatives and trailing bytes. Integers are
nonnegative signed 64-bit values within the owning field's range. IDs use the
existing closed ASCII identifier syntax; controller IDs, verifiers and digests
are lowercase SHA-256 hexadecimal. The records below are in their exact order.

Original fields are deployment ID, owner ID, positive epoch, positive native
creation revision and verifier. The fixed operator role is implied; no role or
permission field is accepted.
Expected mutation revision is at least creation revision and below the maximum
signed 64-bit value, leaving room for the authority change event. The Store
also checks room for every affected request before committing the transaction.

| Record | Fields after format and record name |
| --- | --- |
| grant | original fields, operation ID, expected Store revision, target ID, resource revision, binding revision, selection generation, artifact digest |
| revoke | original fields, operation ID, expected Store revision, target ID |
| status / not_found | original fields, operation ID |
| receipt | deployment, owner, epoch, principal, operation, action, target, input digest, expected revision, change revision, final revision, affected requests, unknown outcomes |
| error | one closed reason from the executable codec |

Input digest is SHA-256 of the exact canonical grant/revoke record, including
its original custody reference. Receipt principal must be the fixed operator
for that epoch. Counts are bounded to 1,024 affected requests. No record
contains credential bytes, endpoints, paths, private device fingerprints or
caller code. Decoding supplies no signing, custody, grant or Store authority.

Before delivery, add a separately versioned native pending encoding for these
original operations, preserving v1 records explicitly. Publish original input
before a mutation; share loading, unresolved-operation and session guards with
other native work. Recovery opens original custody and uses only original
status or exact retry. Lost replies, refused later retries and unavailable
originals remain retained. No journal file or version is silently reset.

Software evidence currently covers inert grant/revoke/status/receipt
records, independent literal vectors, original input digests, fixed principal,
revision arithmetic and closed parser bounds. Store/Authority, migration,
backup/transfer, signed broker, pending composition and native controls remain
required. Installed signed success and hardware behavior need their own actual
evidence; a codec cannot qualify either.

Run `mix test test/wotex_home/native_target_codec_test.exs
test/wotex_home/native_setup_test.exs` for the sixteen passing codec/setup cases.
The new codec uses the shared Home ID validator and changes no Store schema,
native role permission, grant or dispatch setting.

`NativeSetup.TargetBasis` supplies pure correspondence against the Store-owned
profile-target snapshot. It requires a usable selected profile, reviewed
identity, exact target/epoch/Store/resource/binding/selection/artifact pins and
exactly one ordinary writable power capability. An actual private Store test
joins native zero-target custody with authenticated profile-target reads after
real scripted preparation/selection. Wrong pins, unavailable/revoked state
and a structurally valid expanded declaration refuse. The native catalogue
remains empty, Store revision does not change and qualification stays absent.
This predicate creates no grant and supplies no signed custody seal. Its test
joins the existing profile review suite and inert codec regressions; grant
transactions, lifecycle withdrawal and schema/recovery remain required.
