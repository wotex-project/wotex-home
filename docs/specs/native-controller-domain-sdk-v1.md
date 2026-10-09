# Native controller domain SDK transport v1

Version: 0.1.0. Owner: WOH.08 H08-09/H08-T9, WOH.15 H15-07/H15-T8. Status: accepted shared transport entry; implementation and evidence pending.

This composes the existing [ordinary TLS client](native-controller-api-v1.md)
with the existing typed local SDK. It adds no wire format, server route, Store
schema, Keychain import, controller selection or authorization seal. The typed
SDK keeps its original field validation, consistent paging and exact
receipt/source/principal correspondence.

## Explicit operation scope

An explicit asynchronous domain operation supplies one validated public peer,
exact 32-byte application credential, trusted certificate-clock producer and a
fixed typed SDK function. The transport is installed only in that operation's
task-local scope. It cannot change the process's selected credential/controller,
rewrite a socket path, register a proxy listener or replace the global local
client. Outside this scope, existing private-UDS/native-broker behavior remains
unchanged. A remote error never removes the scope or retries through UDS.

The adapter consumes the SDK's exact ordinary request bytes and original
`allowNotFound` policy. Require the request's credential to match the operation's
original credential before connecting. Do not import, recover or select a
different key. The actual TLS client supplies all chain/name/pin/clock,
framing/envelope and ordinary/review deadline checks. Local broker/setup/target
access remains outside ordinary remote transport and refuses inside this scope
before signing/socket work. Public association metadata supplies no live grants.

Trusted production session composition must obtain actual matching existing
[paired Keychain custody](native-paired-keychain-v1.md), authenticated current
owner/principal/grants and original association/selection checks. The low-level
domain entry, like the existing byte API, may accept a credential in a private
foreground fixture; that fixture cannot manufacture installed custody or a
current-session seal. A clock producer is trusted host input, never API data,
discovery information or a default fallback from an unknown clock. Each new
exchange needs a current bounded clock; it does not renew Home execution-clock
qualification or authorize a device effect.

## Finite bridge and completion

Existing synchronous typed SDK calls run on a detached worker, never block the
main actor and never reenter the same bridge concurrently. The async TLS owner
runs separately. A locked private completion cell and finite semaphore wait
join them; one active request at a time is allowed. Capture an absolute
continuous deadline before clock production/task scheduling: five seconds for
handshake plus five ordinary or ten review seconds. No scheduling, late clock,
fragment or result may extend it. Timeout cancels the original TLS owner,
retains uncertainty and creates no replacement connection.

After transport returns, the typed SDK performs its original domain validation.
Before returning a successful typed result, recheck the last original exchange
deadline and cancellation. Validation crossing that deadline refuses even if
the envelope was received in time. Each explicitly requested page uses a new
exchange; the SDK's existing watermark/cursor/count guards remain unchanged.
An operation with no exchange grants no remote scope. Reusing a stopped bridge
or spawning work that outlives its owning operation refuses.

Cancellation closes the active TLS owner and prevents subsequent requests.
Cancellation/timeout after a request may have begun remains unknown; verified
server refusals preserve their exact closed SDK errors. A credential mismatch
or concurrent request refuses before opening another connection. No raw
platform error, bearer frame, cell or task is reflected, serialized or logged.
Private buffers/tasks are released when the owner finishes; this does not claim
platform memory erasure.

## Required evidence and successors

Use independent real TLS peers to verify exact typed request bytes, invalid
trust with no application data, malformed domain replies, bounded slow/lost
delivery, no fallback/second connection, credential mismatch, cancellation,
late typed validation and concurrent/outliving request refusal. Exercise real
Authority/Store health, identity, snapshot/catalogue, power/original receipt,
maintenance, profile, explicit-rule and schedule typed paths through the same
adapter and compare their public typed results to UDS. Device dispatch remains
default-disabled. Existing local client/SDK regressions remain required.

This entry does not complete remote UI sessions. Actual signed Keychain/current
scope composition, saved selection, stale completion/switch/revocation guards,
[v5 original capture/recovery](native-pending-custody-v5.md), window/menu-bar
integration, installed macOS 15 TLS and headless/hardware qualification remain
separate obligations. Load never contacts an owner or starts a local fallback.
