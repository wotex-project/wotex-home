# Native certificate clock source

Version: 0.1.6. Updated: 2026-10-15. Status: accepted implementation contract.
Owner: WOH.08 H08-09/H08-T9, WOH.15 H15-07/H15-T8.
Implementation: inert codec/lease, fixed-file production owner, volatile generation
and source-aware TLS clock primitive implemented; shared Setup/driver remains planned.
Evidence: NC-T1 executed; NC-T2/T3 partial file/generation/worker and actual unsigned
refusal evidence; shared composition and installed qualification remain open.

## Observable result and trust boundary

An explicitly installed and qualified local UTC issuer can answer one fresh
native-app challenge. The app then supplies conservative current UTC intervals
to its existing paired TLS factories until the original source expires or loses
continuity. Setup exposes request, explicit response import, current confidence
and withdrawal. Construction/startup/selection performs no issuer, file, Keychain
or network work. There is no default issuer, OS-clock confidence, public NTP
dependency or automatic renewal. Without an accepted source, paired operations
remain unavailable and the selected controller is retained.

This owner is independent of a Home Store and can operate while the Mac is a
client of another controller. It never starts a local execution owner, reads a
local credential/UDS, changes a Store or sends an issuer request itself. An
operator transfers the public challenge to the qualified local issuer and
explicitly imports its signed answer. Issuer setup/UTC accuracy and monotonic
bounds require an actual host qualification procedure; a signature only proves
which installed key signed the supplied time. Existing [recovery](controller-clock-v1.md)
and [schedule](schedule-clock-source-v1.md) clock formats/authority remain separate.
Normal system-time PKIX checks, SAN, full leaf pin, TLS 1.3 and current paired
custody remain mandatory under the [TLS contract](controller-tls-bootstrap-v1.md).

## Closed inert documents

**NC-01 — Representation.** All four documents are canonical compact UTF-8 JSON
arrays, at most 4096 bytes, depth at most three, arrays at most sixteen members,
ASCII strings at most 128 bytes. Only arrays, strings and nonnegative signed-64
integers occur. Objects, booleans, nulls, floats/exponents, whitespace, escaped
strings, unknown/expanded members and noncanonical bytes refuse. Re-encoding
must equal input. IDs are 1–128 ASCII bytes, begin with an alphanumeric character
and otherwise contain only alphanumerics, `.`, `_`, `:` or `-`. Digests are 64
lowercase hex characters. Binary values use canonical unpadded base64url: keys
and challenges exactly 32 decoded bytes, signatures exactly 64.

Policy is exactly the following thirteen-member array:

```text
["wotex-home.native-certificate-clock-policy.v1", source_id, issuer_id,
 public_key, issuer_generation, procedure_ref, qualification_digest,
 runtime_digest, maximum_response_ms, maximum_age_ms, maximum_error_ms,
 monotonic_drift_ppm, maximum_discontinuity_ms]
```

Generation is positive. Response is 1–60000 ms; total age 1–600000 ms and strictly
greater than response plus twice maximum error. Error/discontinuity are 0–1000
ms and drift is 0–1000 ppm. They are installed whole-horizon assumptions, not
measurements inferred from success. Qualification binds that issuer's UTC error,
the selected Mac's elapsed-clock accuracy, sampling and permitted undetected
wall/continuous disagreement. The policy's runtime digest is SHA-256 of the
canonical four-member array
`["wotex-home.native-certificate-clock-runtime.v1", team, executable_identity,
bundle_identity]`; team and the canonical base64url code identities come only
from the actual protected-app signing check used by paired custody. Strict
nested/all-architecture static validation remains mandatory. A runtime digest
from a supplied dictionary/path is inert and cannot install a source.

Request is exactly
`["wotex-home.native-certificate-clock-request.v1", "org.wotex.home",
runtime_digest, challenge, policy_digest]`. Policy digest hashes the entire
canonical policy, including all time bounds/key/procedure. The owner generates
32 unpredictable challenge bytes and records its original continuous request
instant before publication; a decoded request reconstructs no timing authority.

Record is exactly
`["wotex-home.native-certificate-clock-record.v1", "org.wotex.home",
runtime_digest, challenge, policy_digest, observed_utc_ms]`. UTC is 0 through
253402300199000 milliseconds since 1970, leaving ten minutes of headroom below
the TLS clock's supported limit. Its signature covers the record format's ASCII
bytes, one zero byte, then the entire canonical record JSON. Package is exactly
`["wotex-home.native-certificate-clock-package.v1", record_array, signature]`.
Verify all joins and Ed25519 using the installed policy key before accepting.
Cross-purpose recovery/schedule documents and another challenge/key/runtime
cannot satisfy this source. Pure decode/signature/lease values convey no
installed source, session, credential or authorization seal.

## Current interval and discontinuity

**NC-02 — Original timing.** Pure lease calculation accepts exact policy/request/
package bytes and nonnegative integer elapsed milliseconds from the original
request start. Response receipt `r` must satisfy `0 <= r < maximum_response_ms`.
Current `n` must satisfy `r <= n < maximum_age_ms`. There is no new start on
status, identical response retry, new TLS acquisition or copied documents.
Let `u` be signed observed UTC, `e` the sum of maximum error, permitted
discontinuity and two milliseconds of sampling allowance, and
`d = ceil(n * monotonic_drift_ppm / 1000000)`. The inclusive
conservative interval at `n` is:

```text
earliest = u + (n-r) - e - d
latest   = u + n     + e + d
```

Reject underflow, overflow, reversed coordinates, expired response/age and any
interval outside 0–253402300799000. Independently rebuild from original bytes
and signature for each pure lookup; mutable cached bounds cannot replace them.
Real elapsed observations round lower/upper coordinates outwards by one
millisecond at the native conversion boundary. TLS delivery retains its original
five-second session lease; a source lookup never extends that session.

**NC-03 — Withdrawal.** OS wall time is only a continuity veto. Compare current
wall/continuous deltas both with the previous sample and cumulatively with the
original request anchor. Refuse rollback, invalid/nonfinite wall input, or an
absolute disagreement exceeding policy discontinuity plus ceiling-rounded drift
and two milliseconds of sampling allowance. Small corrections cannot hide by
resetting a rolling anchor. The two-ms allowance is already included in `e`
above and is counted once. A passing comparison supplies no UTC.
Wake/sleep notification, policy/runtime/file replacement and explicit withdrawal
permanently invalidate that source generation. Reverting a setting/file cannot
restore it. Each sample repeats checks, and an owner timer checks at most once
per second. Timer progress alone cannot authorize a later sample.

## Production owner, custody and presentation

**NC-04 — Fixed custody and states.** The process-wide app owns one thread-safe
source with states unavailable, requesting, qualified and withdrawn. Its
constructor and status are passive. Explicit Begin obtains actual protected-app
signing facts, reads the existing policy, fixes original policy/runtime and
continuous/wall anchors, and publishes one challenge. Begin while requesting or
qualified refuses capacity; after withdrawal an explicit Begin creates a fresh
generation/challenge. No request/response file restores a source after restart.

The fixed root is `Library/Application Support/WoTExHome/certificate-clock/`
under the actual account's canonical home. Explicit Begin may create only this
missing child beneath existing safe native account custody. Root is owned by
the non-root current account, mode 0700, without links/ACL mutation. The operator
installs `policy.json` as a canonical single-link regular 0400 file beforehand;
the app does not invent its key or repair unsafe custody. Root has fewer than
64 children before a new request directory is created. Each request gets a new
0700 child containing immutable single-link 0400 `request.json`; accepted import
publishes immutable `response.json` there. Bound all reads/writes to 4096 bytes.
Retain full descriptor/path/inode/content/owner/mode/ancestor seals and repeat
them around signing, signature checks, publication and current use. File seals
include size, nanosecond modification/change times and exact bytes. Directory
and ancestor seals include device/inode, owner, complete mode and ACL; their
entry-change timestamps are not identities, so ordinary unrelated native
metadata publication cannot renew or invalidate this source. Ancestors must
remain canonical directories owned by root or the current account, without
group/other mutation or ACL mutation grants. A root-owned sticky temporary
parent is permitted only by the separate unsealed file-fixture entry. Identical
bytes at a replaced inode fail. Failed publication never becomes confidence.
This owner removes no historical directory to manufacture capacity.

Explicit Import fixes the original request digest and consumes a live challenge
on any invalid answer, failed check or uncertain publication. A stale original
request digest conflicts before reading input and cannot consume a newer
challenge. Once accepted, a different response conflicts without replacing the
accepted source; failed current-source checks still withdraw it. A known accepted
identical retry returns the original acceptance and deadlines only while current;
a changed response conflicts. The importer reads an existing canonical private
0400 response file chosen by the operator, verifies it, then copies into fixed
owned custody without following links or overwriting a file. No signer command,
endpoint, shell invocation or caller-chosen issuer key is accepted.

**NC-05 — TLS composition and UI.** A qualified lookup obtains actual current
protected-app identity and repeats all source/custody/continuity checks. It
returns a native TLS clock with a continuous expiry no later than the original
source expiry and fifteen seconds after lookup. Every `bounds()` repeats the
same original source checks and recomputes conservative current bounds; it cannot
survive source withdrawal or keep using a cached earlier interval. Blocking
source work stays off the socket/deadline executor, so the existing owner returns
on its original deadline and drops late results. Missing/invalid source never
uses local credentials, manual clock fields, saved permissions or OS UTC.

Setup's explicit Begin/Import actions share the application's busy and loaded
journal guards defined in NC-06. They send no controller/device request. Display current
source/procedure identity, finite remaining age, bounded confidence or a closed
refusal; never claim a fixture proves time accuracy. Input/selection/wake changes
invalidate late UI completion. The actual application installs this production
producer in the shared controller driver; the current nil producer remains the
default for smaller fixtures. The production owner has no directory, runtime,
clock or successful signing/backend constructor parameter. Its private current
source can arise only from actual-self signing and fixed account custody. A
separate unsealed file/generation fixture may check real private files and signed
synthetic answers, but cannot be installed in that owner or mint its TLS clock.
No fixture backend can mint production signing or an accepted production owner. Error classes are invalid_document, scope_conflict,
invalid_signature, clock_unavailable, expired, custody_conflict, capacity and
outcome_unknown. Logs omit raw documents, paths and platform error objects.

Begin and Import each have one original five-second continuous operation
deadline, covering actual signing, file work and final delivery. A single
process-wide operation slot remains held until its actual worker retires, even
when cancellation/expiry has already returned. Refuse another operation while
it is retiring. Cancel, timeout and explicit withdrawal invalidate its token
immediately; late file publication or platform completion cannot install a
request or confidence. Before/after every publication, repeat token, original
deadline and custody checks. Unknown publication remains historical private
files without authority; no automatic replay or source reconstruction occurs.
Clock sampling/custody/signing runs off socket and operation deadline executors.
At most one actual signing/runtime validation per production owner may be in
flight; contention returns capacity without withdrawing an otherwise unchanged
source. That slot stays held until the check actually returns. Periodic checks
repeat source timing/files without scheduling another signing worker. Every
actual sample repeats current signing before and after source-file checks.
Timestamp each uncertainty projection with its continuous observation instant;
advance it with outward rounding and drift after subsequent checks, so time spent
validating a sample is never silently discarded. No projection renews source age.

**NC-06 — Shared action model.** The process-wide application constructs one
parameterless production owner and one Setup model. Only that actual owner is
bound to the production driver's selected and original-purpose clock factories.
Smaller driver fixtures retain the nil producer default. A separate UI-action
fixture may return presentation metadata and controlled completions, but cannot
be installed as the actual owner's signing/source backend or supply the shared
application's production clock. Construction, rendering, status polling and
controller metadata reload perform no signing, clock-file, credential or network
work. Status is presentation only; actual TLS acquisition repeats NC-05.

Begin is enabled only in unavailable/withdrawn state, with no current or retiring
clock operation, no other shared busy work and loaded safe pending-journal
metadata (a snapshot exists and reload is not required). A retained original
does not block clock renewal: otherwise expiry would prevent the very paired
recovery required to resolve that original. Clock setup changes no controller,
credential or original; ordinary session changes retain their pending-original
guards. Import has the same shared guards and
requires requesting/qualified state plus its exact original request digest.
Its only editable input is an absolute local response-file path: 1–4096 UTF-8
bytes, leading `/`, no NUL. Spaces are allowed; text is not silently trimmed or
interpreted as a URL, command or key. Invalid UI text refuses before invoking
the importer and does not consume the challenge. Once submitted, the owner's
live-answer consumption and identical-retry rules apply unchanged.

The model fixes its input, action nonce and presentation generation before
awaiting work. Input change during an action, controller/session selection
change, cancellation or sleep/wake invalidates that action, cancels its Task and
withdraws its source before any late completion can publish. An idle input or
selection change does not revoke an already accepted app-scoped source. Sleep/
wake and explicit Withdraw always revoke it, including during unrelated busy
work; withdrawal grants nothing and cannot free a retiring worker slot. A
cancelled UI action remains busy until its actual action call returns, and owner
retirement metadata continues to fence subsequent work. Cancellation cannot
make an old positive result visible or begin another action over retiring work.

Setup presents one section usable with local or remote selection, with explicit
Begin, Import and Withdraw, selectable public request-file location, current
source/procedure, remaining milliseconds and a human-readable closed outcome.
It never prints raw platform errors or claims that signature success measures
UTC accuracy. Narrow layouts stack actions and wrap long paths; wide layouts
can share a row. A presentation poll at most once per second may observe expiry
or retirement; it cannot extend a deadline, acquire a clock or create confidence.
Accepted/withdrawn/expired source changes invalidate scoped views without
changing controller selection, pending originals, journal receipts or device
reports. Missing confidence visibly disables paired recovery and leaves paired
requests unavailable; no local custody/UDS fallback is attempted. The production
application's explicit Swift assembly closure includes all clock owner/model/
panel sources; compilation alone is not installed signing or host evidence.

## Acceptance and implementation order

| Case | Required evidence / falsifier |
| --- | --- |
| NC-T1 | Independent Python/OpenSSL Ed25519 canonical records and literal integer interval vectors; mutated key/domain/scope/bounds, malformed/expanded JSON/base64/native values, underflow/overflow and strict response/age boundaries refuse. Pure results cannot construct installed custody. |
| NC-T2 | Actual private file owner: fixed policy/request/response publication, exact retry, one-source capacity, response consumption, original expiry, identical-byte inode/root replacement and changed runtime; restart requires new challenge. Unsigned production entry refuses before account files or issuer work. |
| NC-T3 | Held signing/file work and concurrent withdrawal/cancellation/expiry return boundedly, never publish late confidence. Cumulative tiny corrections, rollback, wall change and explicit wake permanently withdraw; old returned TLS clocks refuse after withdrawal. |
| NC-T4 | Actual shared Setup panel/model and driver wiring, no startup I/O, explicit actions, narrow/wide layouts, busy/input/generation drift and no local/UDS fallback. Controlled held UI-action completions test invalidation and retirement without minting an installed source. Production default starts unavailable and actual unsigned Begin refuses. An unloaded/unsafe journal blocks setup, while a retained original permits clock renewal without changing that original or ordinary session guards. Selection changes preserve an idle accepted app source but cancel active work; wake/withdraw revoke it even while busy. Existing TLS, paired capture/recovery/receipt and local workflows retain their guards. |
| NC-T5 | Actual installed signed app, configured issuer/key custody and UTC/elapsed accuracy across offline age, correction, sleep and reboot; macOS 15 chain/pin/expiry and current paired success. Synthetic source/signature/files and a deployment target do not discharge these obligations. |

Implement the closed inert codec and independently checked lease/withdrawal
arithmetic first, then actual fixed-file owner/signing refusal, then original
source-aware TLS clocks and shared Setup/driver composition. Keep each stage's
status/evidence separate. No default producer is enabled before the full owner
and composition exist. No dependency pin/schema or physical dispatch changes.

Apple's [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock)
provides the process-local clock primitive, and
[CryptoKit signature verification](https://developer.apple.com/documentation/cryptokit/curve25519/signing/publickey/isvalidsignature(_:for:))
provides Ed25519 verification. Neither API establishes the installed issuer's
UTC accuracy; that remains the named procedure's actual host evidence.

The [executed foundation evidence](../provenance/native-certificate-clock-2026-10.md)
records six independent OpenSSL signatures, eighteen interval and sixty-six
continuity vectors, canonical/scope/signature/timing refusals and byte-identical
regeneration. That foundation alone establishes no installed source owner. The subsequent
[owner evidence](../provenance/native-certificate-clock-owner-2026-10.md) records
actual private files, unsealed generation withdrawal, stale fixture clocks and
retiring worker capacity, plus actual unsigned production refusal. It does not
establish positive installed signing/source ownership, issuer accuracy, actual
owner timer/wake behavior or shared Setup/driver delivery.
