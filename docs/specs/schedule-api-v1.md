# Local schedule API v1

Version: 0.1.2. Implemented Authority, framed local API and private-file CLI,
2026-10-08. WOH.15 owns the adapter boundary; WOH.04 and WOH.14 retain the
separate temporal proof and durable admission obligations.

The local API's existing four-byte big-endian length frame and closed JSON
envelope apply. Review, admission, activation, suspension and original lookup each have exactly four
fields: `api_version: 1`, `operation`, credential and `original_document`.
Operations are `schedule_review`, `schedule_admit`, `schedule_activate`, `schedule_suspend` and
`schedule_original_status`. The original document is the complete canonical
[schedule operation](schedule-operation-v1.md) string, at most 8192 bytes.
Each mutation requires its matching document kind. Lookup accepts all four
public kinds and remains private to its authenticated principal. Activation and
suspension use the [Store lifecycle](schedule-lifecycle-v1.md), current original
author, revision CAS and owned clock/timezone guards. There is no clock upload,
occurrence creation, timer registration or device-dispatch route.

Successful responses contain the ordinary API version/outcome envelope and
`schedule_receipt`. Review/admission receipts retain exactly kind, state (`reviewed` or `admitted`),
principal ID, authority epoch, operation ID, complete input digest, artifact
digest and publication revision. Missing original history returns `not_found`.
Changed original input or kind conflicts; it cannot renew evidence or alter
the prior receipt. None of these responses means an active timer, held effect,
protocol acknowledgement or physical observation. Activation/suspension receipts
have exactly 15 fields: kind, state (`activated` or `suspended`), principal ID,
authority epoch, operation ID, input digest, admission revision, previous
generation, rule generation, barrier revision, publication revision, affected
requests, unknown outcomes, reason or null and initial watermark. Lookup and
retry return these immutable originals after later suspension or clock loss.

Authority first establishes the Store's current authenticated stable principal,
epoch and revision under all three review/management/ordinary-control
permissions. Existing exact retries return through the original writer path
before timezone lookup or review-capacity acquisition. New work uses the
existing bounded review gate and then the Store's complete current author,
target, declaration, profile, invariant and revision-CAS transaction. Socket
interruption or worker timeout reports an unknown mutation outcome, never a
definite refusal based only on missing response bytes. The exact original file
is used for lookup and retry; no new operation is minted automatically.

`schedule_timezone` is a closed five-field read request: version, operation,
credential, `zone_name` and `local_datetime`. Local labels are exact
`YYYY-MM-DDTHH:MM:SS` values in years 1970–9999. Its seven-field `timezone`
result contains name, raw-byte digest, local label, instant count (zero to two),
first UTC milliseconds or null, second UTC milliseconds or null and
`basis_scope: calendar_calculation_only`. Gaps have no instant; folds preserve
both choices. This query authenticates before reading and repeats the same
principal/epoch/revision scope afterwards. Concurrent authority changes require
a fresh read. Resolved UTC values do not establish clock confidence.

Host timezone custody defaults to `/usr/share/zoneinfo`, root-owned. Trusted
host construction can select another absolute root and expected owner; request
fields cannot select either. Root and every named intermediate directory must
be owned by that owner and lack group/world write permissions. A selected file
must be a regular file of 1–65536 bytes under the same owner and permissions.
Installed aliases may follow trusted host symlinks; the decoded zone retains
the requested name. Directory identity seals surround the read; open-descriptor
and path seals match device/inode, ownership, mode, size and POSIX modification/
change timestamps before and after the bounded read. TZif is fully decoded.
Calendar source digests must equal those bytes. Missing, unsafe, changed or
malformed data refuse new content. Historical receipt lookup needs no current
timezone. No request can supply a clock sample, qualification, timezone bytes,
filesystem root, endpoint or executable.

CLI commands are `schedule-timezone ZONE LOCAL_DATETIME`,
`review-schedule ORIGINAL_FILE`, `admit-schedule ORIGINAL_FILE` and
`schedule-original-status ORIGINAL_FILE`. Operation files use the existing
0600 regular-file descriptor checks, reject symlinks and retain exact canonical
bytes. Credentials remain in their separate private files and outside command
arguments. Lost mutation responses return exit status 3 and identify the exact
original-file recovery command. Read-only missing status returns 4. CLI and
socket adapters neither provision an author nor qualify a clock or device.

Additional commands are `activate-schedule ORIGINAL_FILE`,
`suspend-schedule ORIGINAL_FILE` and `schedule-status`. Lifecycle files retain
the same exact-byte, 0600 and no-symlink checks; a file's kind must match the
selected command. Activation and suspension use the mutation unknown-outcome
path and its exact original-file recovery instruction, including a committed
transaction whose socket reply was lost. They use the bounded 10-second server
dispatch deadline and 15-second CLI response wait.

`schedule_status` is a closed three-field read: version, operation and credential.
It needs current review permission and returns only that stable principal's
latest lifecycle operation. With no own history its `schedule_status` object is
exactly state `inactive`, activation revision zero and reason null. Otherwise
the object retains the 15 lifecycle fields with current state `active` or
`suspended` and current reason. Another manager's later suspension does not hide
the original author's retained activation; its readiness reports a superseded
generation. Current readiness changes no revision and cannot substitute for an
immutable original lookup. Atom reasons are encoded as strings, with null
preserved and no new fields added to the older eight-field content receipts.

Fourteen new actual-file/Store/adapter cases exercise all 230 independently
authored timezone vectors, current installed-byte pinning, unsafe paths/modes/
owners, aliases and bounded malformed data, exact framed receipts, changed
original input, private lookup, grant loss, management permissions, revocation,
closed caller-input refusals, bounded review capacity and the actual socket/
private-file CLI. A socket fixture commits the original admission and loses its
reply before exact lookup/retry. The combined affected regression run passes
58 tests. This establishes software behavior, not installed clock accuracy,
native signed-host behavior, storage power-loss survival or physical control.

Four additional actual-Store/framed/socket/CLI cases cover the exact 15-field
receipts, principal-private readiness after another manager's suspension,
current readiness versus immutable original state, missing qualified clock,
wrong kind and closed client-time/extra-field refusal, private-file permissions/
symlinks/canonical bytes and a committed activation whose reply is lost. Exact
lookup/retry retains one generation, clock loss blocks readiness, and explicit
suspension needs no replacement clock. These remain software-only results.
