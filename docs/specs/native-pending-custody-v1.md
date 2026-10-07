# Native pending-operation custody v1

Version: 0.1.8. Accepted mechanism with coordinator/health/maintenance composition evidence, 2026-10-07. WOH.08 owns this client journal;
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
new operation or renew capture. Publication permits pending to review, then
review to commit_pending or cancel_pending with that same token/digest, or an
unchanged phase. Once commit/cancel intent is published it cannot be reset,
switched to another intent or rebound to a different review. Restored held reviews are lookup/cancel only:
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

After uncertain phase or removal publication, reload the actual file before
continuing. A repeated phase may confirm its already-published identical intent
through unchanged full-file CAS; preserve the original input/custody/context,
and never switch committed/cancelled intent or its review token/digest. With a
verified matching Authority result, an already-removed entry in a retained
positive-revision file may be confirmed without a write or revision change.
A missing/reset journal, stale file snapshot or newer original in that same
owner category refuses this confirmation. It cannot remove newer work or
declare an unknown operation resolved merely because its receipt is missing.

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

The pure Swift codec is implemented. `mix woh.native.pending.codec.smoke`
checks independent literals for power/cancel, override issue/revoke, rule
suspension, maintenance begin/end and all four profile actions. It checks
select prepare/change phases without changing their original inputs, all four
native references, verifier matching and controller/principal/epoch mismatch.
Canonical ordering, one category per owner across principals, sixteen entries,
signed-integer limits, depth/member/string/byte bounds, closed fields and
Boolean placement are exercised. Objects, nulls, alternate numbers/escapes,
unsupported actions and trailing bytes are rejected. No fixture opens custody,
sends an API request or publishes a journal. The app compiles under Swift 6
with warnings as errors, and the existing profile client passes 72 peer cases
after sharing its ordered field definitions with this codec.

Private file publication is implemented with the shared fixed-document storage
layer also used by native network preferences. `mix woh.native.pending.storage.smoke`
checks original revision/content/file-identity CAS, unchanged records, category
and capacity refusal, exact immutable profile phases, durable resolution to a
retained empty file and preservation of unrelated settings. It rejects unsafe
file/lock modes, symlinks, FIFOs, hardlinks, replacement, malformed/oversized
bytes, root aliases and exhausted revision. Separate real processes exit before
and after publication, then load the original without rewriting or sending any
request. Two competing publishers retain exactly one original and refuse the
other. The network file keeps its own lock, format and bounds, and the existing
preference/panel/inventory fixtures pass. Actual app/helper compile under
Swift 6/macOS 15 with warnings as errors. These checks establish process
restart/CAS behavior; storage power-loss survival and installed account custody
remain unqualified. App operation/recovery composition is still to be implemented.

The credential client now captures native bytes and their immutable registered
original reference under the same memory-selection lock. Manual custody reads
the fixed legacy item outside that lock, then repeats the original selection
nonce before publishing a capture; changed selection refuses it. A known
native hash cannot become manual custody. Existing-only manual recovery checks
the fixed item and exact original SHA-256 without selection, creation, update,
delete or fallback. Inert session and broker fixtures check missing native
guard/no-session refusal, canonical registered reference capture, redacted
reflection and invalid manual verifier refusal before any SecItem call. Their
registered native guard is negative only, never a signed-success fixture.
The existing health/identity fixtures and actual app compile pass. Successful
manual/native custody and the complete app journal composition retain their
own obligations.

The shared main-actor coordinator now captures original custody, checks an
actual authenticated identity and publishes the closed request before returning
its in-memory bytes for delivery. Startup only reads the private file. Unknown
owner records block new work; an authenticated current owner still cannot start
another operation while any of its original categories remains unresolved.
Publication, phase and resolution failures require reload and preserve the
operation guard. `mix woh.native.pending.coordinator.smoke` uses an actual
private Store and two separate client processes for original lookup and exact
retry after a committed reply is discarded. Publication precedes the actual
mutation; restart captures no replacement credential and sends no automatic
request. Wrong snapshot credential and wrong epoch publish nothing. The
original receipt stays private to its principal, and recovery adds no Store
revision. Durable removal retains the empty journal. The actual app compiles
with Swift 6 warnings as errors. This coordinator evidence uses ordinary
disposable fixture custody; model/UI integration and installed signed custody
remain separate obligations.

Power submission/cancellation, override issue/revocation and rule suspension
now publish through that coordinator before their first delivery. Original
lookup and retry retain their captured bytes and typed inputs; removal must
publish before their memory guard clears. Missing later cancellation/revocation
results preserve both originals. `mix woh.native.session.operations.smoke`
checks the exact journal input and custody hash before forwarding each actual
mutation, and checks a second window cannot replace the shared original.
Positive recovery leaves a durable empty file. App startup reads the journal
before new session/mutation work, and a failed load exposes reload status.
Authenticated read-only setup can establish an ownership change without
automatically replacing the selected credential or rebinding old records.
Complete persistent recovery and maintenance/profile wiring remain outstanding.

The storage/coordinator fixtures also check publication-confirmation recovery.
An actual publisher removes the original after its real Store receipt has been
verified; a second coordinator's cached removal refuses, requires reload, then
confirms the retained empty file without another revision. Inert file-only
profile-phase probes similarly confirm already-published review/commit intent
after reload and refuse changing it to cancellation. They perform no custody
capture/API call and provide no actual review approval. Storage probes refuse
absent/reset files, stale snapshots and newer same-category originals; none is
removed or overwritten by resolution confirmation.

Maintenance begin/end now capture the status credential and require the same
original capture when publishing their request. Both sends and original receipt
lookup validate the matching principal/action/revision barrier before durable
resolution clears memory. `mix woh.native.maintenance.panel.smoke` checks twelve
actual private-Store workflows: begin/end original lookup and exact retry after
lost committed replies, requests dropped before reaching Home, repeated refused
retries after principal revocation, changed snapshot credentials before capture
and definite first refusal. Two windows share the journal guard; a new request
cannot replace its original. Missing receipts/refused later retries retain it;
successful resolution or definite first refusal publishes removal before new
work is enabled. Retries preserve the original Store receipt and revision.
The uncertain maintenance panel is rendered and inspected without any Keychain
or signed custody fixture. Complete persistent recovery and profile composition
remain to be built.

The coordinator retains at most sixteen original captures in redacted memory,
including a validated capture whose first file publication fails. Reload reads
only the file and never forgets those known originals. It merges matching
context/custody/input metadata with the stored phase; an authenticated ownership
change can distinguish old originals, but file absence cannot reclassify them.
Only verified resolution removes a known capture. Phase confirmation keeps the
same input and bytes. The coordinator fixture holds the real private publication
lock, authenticates the original against a real Store, then checks publication
refusal sends no mutation. After releasing the lock and reloading the missing
file, the original ID remains guarded without another capture or automatic send.
The existing removal-confirmation case also retains its known original until
verified confirmation, despite the file already being empty. Persistent recovery
must publish an unconfirmed original before any mutation; it cannot generate a
replacement ID from that reload. Complete recovery controls remain outstanding.
