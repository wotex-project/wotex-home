# Native pending-operation custody v1

Version: 0.1.0. Accepted mechanism, 2026-10-07. WOH.08 owns this client journal;
WOH.14/15 retain all durable operation and Authority semantics. The journal is
private client intent, never a Store receipt, credential, grant or physical
qualification. It lives outside encrypted controller backups and owner transfer.

## Original records

Before the first API send, capture one credential and obtain
[authenticated controller identity](controller-identity-read-v1.md) under it.
Require the request epoch to match that active controller. Capture the credential
custody reference under the same memory-selection lock as its bytes. Publish
the exact original record durably before sending any mutation. A failure or
uncertain publication sends no API request and requires reloading that original
record; it never authorizes a replacement ID. Keep in-flight bytes private in
memory and redact reflection/descriptions.

The file is `native-pending-v1.json` in the actual OS account's fixed
`Library/Application Support/WoTExHome` directory. Its canonical UTF-8 JSON
array is `["wotex-home.native-pending.v1",revision,entries]`, revision a positive
signed 64-bit integer. A missing file/root is the empty revision-zero snapshot,
without creating files or selecting a credential. The file is at most 65,536
bytes, depth four, sixteen entries, thirty-two members per array and 128 bytes
per string. No objects, nulls, floats, alternate numeric encodings or trailing
bytes are accepted. Boolean is permitted only for the submitted power value.

Each entry is exactly `[category,context,custody,input,phase]`. Context is
`[deployment,owner,epoch,principal]`: existing lowercase 64-character controller
IDs, positive signed 64-bit epoch and closed Home principal ID. Categories are
`maintenance`, `override`, `power`, `profile`, `rule`. There is at most one entry
per `(deployment,owner,epoch,category)`, even across principals. Sort entries by
ascending canonical UTF-8 bytes of `[deployment,owner,epoch,principal,category]`.
Do not silently drop, edit or prune an unresolved entry at capacity.

Custody is exactly `["manual",verifier]` or
`["native",role,creation_revision,verifier]`, with lowercase SHA-256 verifier.
Manual refers only to the existing non-syncing service
`org.wotex.home.operator`, account `local-api-v1`; no path/service/account is
caller-selectable. Native refers to one original fixed v1 role and positive
creation revision, with principal exactly `native-setup-v1:<epoch>:<role>`.
Native bytes cannot become a manual reference; manual references cannot name a
reserved `native-setup-v1:` principal. The bytes, bearer encoding and
OS signing/Keychain seals are never serialized.

The exact closed input arrays are:

| Category | Input |
| --- | --- |
| power | `["submit",operation,target,resource_revision,power_boolean]` |
| power | `["cancel",operation]` |
| override | `["override_issue",operation,target,resource_revision,duration_ms]` |
| override | `["override_revoke",operation]` |
| rule | `["activate_rule",operation,expected_revision,0]` (suspension only) |
| maintenance | `["begin_maintenance",operation,expected_revision]` |
| maintenance | `["end_maintenance",operation,expected_revision,begin_revision]` |
| profile | `["profile_prepare",action,epoch,operation,expected_revision,artifact_digest,expected_trust_revision,...selection_fields]` |
| profile | `["profile_change",action,epoch,operation,expected_revision,artifact_digest,expected_trust_revision,...action_fields]` |

IDs and integer ranges remain those of their owning API. Profile values follow
the exact ordered common/selection/revocation fields of
`wotex-home.profile-operation.v1`; the embedded epoch must equal context.
Prepare accepts select only. Inputs cannot contain endpoints, captures, new
declarations, credentials, loader names or caller clocks. Unsupported future
operations require a separately accepted encoding, never an arbitrary JSON
replay route. Content-addressed import, scoped refresh and collection keep their
own existing read/reconciliation semantics rather than inventing operation IDs.

Phase is `["pending"]`, or for profile select only
`["review",token,digest]`, `["commit_pending",token,digest]` or
`["cancel_pending",token,digest]`. Tokens use existing closed review IDs and
digests are lowercase SHA-256. Publish a returned held review before enabling
its controls, and publish commit/cancel intent before the respective send.
Changing phase preserves context, custody and original input; it cannot mint a
new operation or renew capture. Restored held reviews are lookup/cancel only:
no retained elapsed time, wall time or fresh app clock recreates review approval
or TTL. An explicitly authorized commit already marked commit_pending can be
retried with its original input; the actual Authority repeats its live guards.
For an original profile_prepare, commit_pending invokes profile_change with
the same closed profile-operation values, and cancel_pending invokes only
profile_review_cancel with its original token. Those are the fixed phase
transitions, not caller-selected replay routes.

## Publication and recovery

Require the existing physical-path, same non-root real/effective UID, private
700 directory and pinned descriptor/name protections. The file and dedicated
`native-pending-v1.lock` are regular UID-owned 600 files with one link; the lock
has zero bytes. Read through no-follow/nonblocking descriptors with size/EOF
bounds and repeated full identity checks. Use nonblocking exclusive flock,
original revision/content/inode CAS, random exclusive 600 temporary file,
file fsync, repeated root/lock/current-file pins, atomic rename and directory
fsync. An unchanged record performs no write or revision change. A failure
after publication is outcome uncertainty, never a declaration that nothing was
written. Removing a resolved entry preserves the file and advances its revision;
no implicit file deletion resets the journal. Preserve unrelated settings/files.

Load the journal before enabling new mutating controls after app launch. Share
one coordinator across windows. A loading, unreadable, malformed or conflicted
journal blocks new work and exposes bounded recovery status. Loading performs
no Keychain, broker, API, driver or automatic retry work. Recover Original is
explicit: use [existing native custody](native-original-custody-v1.md), or read
the exact original manual item, verify its hash, then obtain authenticated
identity and compare original deployment/owner/epoch/principal before lookup
or exact retry. Recovery never selects a general session, imports/rotates a
credential, ensures a native role, edits input, generates an ID or falls back
to another credential/controller. Missing custody or scope mismatch preserves
the unresolved record and explains its state.

A verified receipt/result or definite refusal of the first attempt may remove
its entry. Missing receipt, vanished review or any failed later retry preserves
the original, including revocation, expiry and policy refusal. Positive original
review cancellation resolves only that held review; uncertain cancellation
requires original scoped lookup/cancel recovery. Persist resolution before
unblocking new work. If removal fails, retain the original and resolve it again.

Unresolved current-owner records block session replacement and new work under
that owner. Records from another owner/epoch/deployment remain preserved as
unresolved history. An explicit authenticated check may identify that ownership
change and permit explicit selection of a separate current session; it never
rebinds the old records or retries them with new custody. Such selection grants
no device targets and does not assert physical isolation. Historical records
still consume the sixteen-entry ceiling until actually resolved.

Required evidence: independent codec vectors, bounds and closed inputs; private
file/lock/symlink/hardlink/mode/replacement/CAS refusal; two windows and crash
before/after publication; actual Store lost replies and requests never received,
app process restart, original lookup/exact retry once with unchanged receipts,
wrong manual/native verifier, changed principal/controller/epoch, retained
refusals and no automatic sends. Render the recovery flow and compile the app.
Successful signed custody and installed storage/account survival remain separate
host evidence; fixtures cannot manufacture them.
