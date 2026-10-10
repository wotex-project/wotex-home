# Native controller domain SDK transport v1

Version: 0.1.3. Owner: WOH.08 H08-09/H08-T9, WOH.15 H15-07/H15-T8. Status: accepted shared transport foundation; bounded implementation and development-host evidence below, installed session composition pending.

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

An optional [additional exchange guard](native-controller-exchange-guards-v1.md)
now checks opening, actual verified pre-send, decoded response and final typed
delivery boundaries on a separate bounded executor. The last original domain
deadline covers its final check. A blocked platform check cannot starve socket
cancellation or extend delivery. This optional check supplies no custody seal;
actual production signed session composition must supply its own current checks.

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

## Implemented foundation and evidence

`NativeControllerDomainClient.perform` runs a fixed synchronous typed SDK closure
on a detached worker under an explicit `NativeDomainTransportScope`. The shared
SDK selects this scope before any UDS path, peer or signing work, and forwards its
original request bytes and not-found policy. The private bridge compares the
original credential, allows one active exchange and joins the actual async API
client through a locked completion cell. Short semaphore waits check continuous
time after host sleep. Clock production, scheduling, domain decoding and final
async result delivery cannot extend the original absolute exchange deadline.
Cancellation stops the TLS owner; terminal scope reuse cannot connect. A
concurrent refusal that ends its owning operation cancels the active original
and conservatively reports that original as unknown. Local brokerage refuses
remote scope before default-path discovery or explicit-path socket/signing work.

The actual peers also exposed loose legacy health decoding. The shared decoder
now checks the exact outer keys and either the original eleven health members
or the current thirteen-member receipt-capacity projection. Integer fields
refuse booleans/floats, flags require actual booleans, epoch is positive and
generation/capacity counters are consistent. Legacy fields are accepted without
inventing receipt counters; partial capacity pairs and unrelated fields refuse.

`mix woh.native.controller.domain.smoke` checks seventeen independent real-peer
or listening-socket cases: typed health, broker isolation, outliving inherited
work, wrong SAN/pin without application data, malformed typed fields/envelope,
exact server refusal, late domain decoding, post-send cancellation, concurrent
requests, lost/slow/oversize replies, credential mismatch, no exchange and a
late clock producer that never connects. Peers compare the complete expected
request field set/values, retaining JSON member-order freedom, and observe no
second connection. Original SDK bytes are passed unchanged to the TLS client.

The same check compares thirty-two typed SDK calls against one actual
Authority/SQLite/private-UDS/TLS owner: health, identity, authenticated current
permission/target scope, consistent catalogue/
snapshot, power/original and absent receipts, maintenance begin/end/originals,
profile import/approval/catalogue/originals, explicit-rule current/preview/
review/admission/activation/invocation/originals, and schedule current/timezone/
review/admission/source/activation/suspension/originals. Approval enters actual
maintenance; review uses the actual finite gate. Schedule activation uses the
existing private signed **software clock fixture**, not a qualified installed
clock. Dispatch remains disabled and no device packets or Keychain calls occur.
The optional `authority` argument runs only this owner comparison during
development, not the independent peer checks.

These checks use the pinned Elixir/OTP and locked dependencies on the development
Swift 6.4/macOS 27 host, targeting macOS 15. They do not establish macOS 15/Swift
6.1 interoperability, installed signed custody, actual current-session selection,
paired pending recovery or physical effects. The later macOS 15 CI TLS refusal
recorded by the ordinary client remains unresolved; no trust guard is weakened.

Shared health/identity, 54 explicit-rule, 110 schedule and 72 profile peer
regressions, actual unsigned broker refusal and live CLI/native receipt parity
also pass. Full native warnings-rejecting typechecking, format, Elixir warning
checks, the twenty-contract catalogue check and seven focused packaged-probe/
macOS inventory tests pass. These are local checks, not a replacement CI run.
