# Native target access v1

Version: 0.1.6. Accepted mechanism with durable Store access and native brokerage, 2026-10-07. WOH.08 owns the signed native
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

The separately versioned [pending v2 encoding](native-pending-custody-v2.md)
implements these original inputs while preserving v1 records explicitly.
Publish original input
before a mutation; share loading, unresolved-operation and session guards with
other native work. Recovery opens original custody and uses only original
status or exact retry. Lost replies, refused later retries and unavailable
originals remain retained. No journal file or version is silently reset.

Schema 23 implements the original access ledger in the single Store. The
trusted Authority calls have no ordinary socket route. Original custody precedes
receipt recovery and first mutation; canonical input changes conflict. Store
transactions validate retained access and its current grant projection before
and after changes. Profile selection/trust, declaration, binding and principal
revocation withdraw invalidated grants inside their owning transaction. Retained
selection/trust timelines and generic target revocations prevent receipt retry
from reviving withdrawn access. Damaged links fail closed rather than repairing
a projection. New operations stop at the fixed receipt and target bounds.

Active schema 22 migration adds an empty ledger without changing custody,
grants, revisions or receipts. Unexplained native grants refuse migration and
roll back its DDL. Retired sources remain historical until guarded receiving
acceptance installs the new schema. Database-only and inclusive archives retain
and validate the actual schema 23 table; historical versions keep their own
exact table sets. Receiving acceptance retains original access receipts and
withdraws copied grants before exposing its new owner.

The trusted original-parent core pipe now accepts the same closed grant, revoke
and status records, within its existing 4,096-byte frame and five-second
first-byte deadline. Missing status echoes only the original status record;
matching committed calls return the exact immutable receipt. Bounded custody
and policy errors do not provision or substitute a credential. Existing setup
frames retain their independent encoding and behavior.

Pipe mutations carry a process-local guard tied to the original worker, Store
owner and first-byte deadline. The single Store checks it before work, after
the native writer's correspondence checks and after the final transaction
integrity checks, immediately before SQLite commit. Refused, raised or expired
guards roll back as unresolved outcome without disabling a healthy Store. A
worker reaped by the pipe cannot mutate later from the Store's queued call.
Direct trusted Authority calls use the same writer with an explicit local
caller guard; neither callback nor pipe supplies installed signing evidence.
Actual tests expire the final commit guard after all ledger writes and resume a
Store only after its original pipe worker timed out. Both retain zero access
writes and unchanged revisions; explicit fresh original retry can then succeed.

The native Swift codec now implements independent typed grant/revoke/status
records and receipt correspondence. Its separate sixteen-member scalar scanner
keeps existing setup/broker membership bounds unchanged. Original operator,
creation/expected revision, target and exact profile basis are checked before
encoding. Receipt parsing verifies the original action, scope, operation,
target, canonical input digest, revisions and bounded outcome counts. Missing
status matches the exact original reference and remains unresolved. Changes
hide their private reference from normal description/debug reflection. The
Swift and Elixir suites share an independent literal grant digest; malformed
encodings, expanded roles and changed receipts refuse. Both production app and
agent source lists include the new codec and compile under Swift 6 with warnings
as errors. Codec compilation and vectors supply no signing or grant authority.
Run `mix woh.native.target.wire.smoke` for native correspondence and
`mix woh.native.setup.wire.smoke` for retained setup/broker bounds.

The signed broker now delivers these exact closed records through its already
owned core pipe. It authenticates the original app/agent peer before reading a
frame, then uses only the original existing Data Protection Keychain item.
Original verifier, creation receipt and current controller identity must agree;
it repeats OS peer, socket and custody checks before sending the access record.
Access never obtains or ensures a role, returns credential bytes, selects a
session or substitutes another controller. The core and broker validate scoped
receipt structure; the app additionally matches the action, target, original
expected revision and digest of its complete retained mutation input. Status
alone cannot supply that mutation correspondence.

The actual owned-core fixture checks missing original status, denied grant and
revoke, wrong custody and caller route mismatch. Denials leave revision and
custody unchanged and permit further requests on that original core. Unsigned
client grant/status attempts send zero bytes; an unsigned agent session refuses
the target records before any core request or Keychain work. Both complete
production app and agent compile with Swift 6 warnings as errors. Run
`mix woh.native.core.pipe.smoke` and `mix woh.native.broker.socket.smoke` for
these boundaries. These are refusal and software pipe checks; successful
installed signing, actual Data Protection Keychain custody and account survival
still require their separate signed-host procedure.

Actual private SQLite tests cover grant/revoke and original status/retry,
stale review/custody, generic revocation, profile reselection and trust
revocation/reapproval, principal revocation, failed ledger insertion rollback,
damaged history, restart and archive verification. Synthetic historical queued,
claimed, dispatching and protocol-accepted rows exercise the real revocation
transaction: unsent work becomes rejected, handed-off work becomes unknown and
causal spend remains reserved. These fixtures send no packet. A second actual
software ownership transfer preserves the native receipt while withdrawing its
grant; new epoch custody starts ungranted. These are software evidence, not
physical isolation, installed signing or hardware qualification.

Run `mix test test/wotex_home/native_target_codec_test.exs
test/wotex_home/native_target_schema_test.exs
test/wotex_home/native_setup_test.exs
test/wotex_home/authority_profile_review_test.exs
test/wotex_home/recovery_store_test.exs` for the owning regressions. Access
pending model composition and native controls remain required
before delivering access through the app.

`NativeSetup.TargetBasis` supplies pure correspondence against the Store-owned
profile-target snapshot. It requires a usable selected profile, reviewed
identity, exact target/epoch/Store/resource/binding/selection/artifact pins and
exactly one ordinary writable power capability. An actual private Store test
joins native zero-target custody with authenticated profile-target reads after
real scripted preparation/selection. Wrong pins, unavailable/revoked state
and a structurally valid expanded declaration refuse. The native catalogue
remains empty, Store revision does not change and qualification stays absent.
This predicate creates no grant and supplies no signed custody seal. Its test
joins the existing profile review suite and inert codec regressions alongside
the actual durable access and lifecycle cases described above.
