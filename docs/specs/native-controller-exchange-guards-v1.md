# Native controller exchange guards v1

Version: 0.1.1. Owner: WOH.08 H08-09/H08-T9, WOH.15 H15-07/H15-T8. Status: bounded additional guard implemented with independent TLS and real-owner SDK evidence; actual signed session and installed evidence pending.

This extends the [shared typed transport](native-controller-domain-sdk-v1.md)
with additional refusal checks for the future actual signed session. It adds no
wire fields, credentials, grants, selection, Keychain backend or session seal.
A supplied successful closure cannot manufacture custody or authorization.

## Original exchange boundaries

An explicitly supplied guard checks before opening a connection, after actual
TLS verification immediately before application send, after validated response
decoding, and after the typed SDK has decoded a successful result before async
delivery. Existing entries without a guard retain their original behavior.
Each exchange and page uses its original peer, bearer and absolute deadline.
Checks cannot renew an expired custody lease, select another association or
extend handshake/request budgets. The final typed check uses the last original
exchange deadline, including its original clock-production/scheduling budget.

Production composition must itself supply actual current signed custody and
original association/selection checks, following the [paired custody
contract](native-paired-keychain-v1.md). These platform/file checks may block.
They run on a separate executor from the socket owner, with a finite continuous
deadline and cancellation. A blocked check cannot prevent socket cancellation
or async completion. No late check may send application data or publish a value.
Platform work already in progress may finish later; no memory erasure or forced
termination of Security APIs is claimed.

A failed check before possible send refuses with the closed `invalidRecord`
transport error. After possible send, failed/expired/cancelled checks retain
`outcomeUnknown`, including a previously validated server reply. No raw guard or
platform error is serialized, reflected or logged. Timeout and cancellation
stop the original owner; no replacement connection, local fallback or automatic
retry is created. Existing TLS trust/clock and typed receipt guards still run.

## Required evidence

Use real independent TLS peers to check all four boundaries, success ordering,
pre-connect and pre-send refusal without application data, post-send refusal,
and guard failure after typed decoding. Block each boundary beyond its original
deadline and cancel while blocked; require finite owner completion and no late
application send/delivery or second connection. Preserve existing unguarded
bootstrap/API/domain and actual Authority/UDS parity regressions. Fixtures may
exercise additional closures but cannot create a signed session or touch the
operator's Keychain. Installed signed selection, revocation, original paired
recovery and macOS 15 interoperability remain separate successors.

## Implementation and development evidence

`NativeControllerExchangeGuard` carries only an additional check with closed
opening, sending, delivering and decoded phases. Its private owner runs platform
work on a separate queue, retains an absolute continuous deadline and uses short
timer checks so host sleep cannot renew the awake budget. Cancellation and a
late result stop that owner without awaiting the platform call. Raw guard errors
are reduced to a Boolean; the private closure/owner have empty reflection.

The actual TLS owner invokes the opening check before trust preparation or
connection, the sending check after its actual peer recheck, and the delivering
check after bounded envelope decoding. Its own original phase timer remains
active while awaiting a check. Finishing cancels the check owner and the original
socket, clears buffers and prevents late callbacks from sending or delivering.
The API passes the optional check unchanged; bootstrap and unguarded callers
retain their original boundaries. The shared domain bridge adds the decoded
check under its last original exchange deadline and repeats cancellation and
deadline checks before returning the typed value. An uncertain post-send guard
cannot expose an otherwise verified server refusal as a current result.

`mix woh.native.controller.domain.smoke guards` passes sixteen independent
real-peer/listener cases: exact successful phase order, unchanged pin refusal,
refusal/blocking/cancellation at each of four boundaries, a guarded server
refusal and malformed typed domain data. Opening cases prove no connection;
sending cases prove no application data. Later cases retain the exact original
request with no second connection. Owner completion stays at the original
handshake/request/domain deadline; cancellation finishes promptly. A controlled
platform latch remains blocked until the owner has actually returned. The
fixture then releases that call, waits for its actual return and checks that
it never advances to another phase. These additional closures manufacture no
custody seal.

The full domain task also passes the original seventeen independent cases and
thirty-two actual Authority/Store typed UDS/TLS comparisons. Each real-owner
operation now records the opening/sending/delivering sequence for each original
exchange, followed by one final decoded check; consistent multi-page reads keep
their original watermarks. Physical dispatch remains disabled. Native app
warnings-rejecting typechecking passes on Swift 6.4/macOS 27 targeting macOS 15.
Actual signed Keychain/selection composition, installed macOS 15 interoperability
and physical effects remain separate; this is additional transport checking.

The unchanged bootstrap task passes its 35 trust/frame/deadline/cancellation/
installation-identity and actual Authority delivery cases; the ordinary API
trust/envelope/original-receipt regression also passes. Seven focused packaged
Store/macOS inventory tests, format, warning-rejecting Elixir compilation and the
twenty-contract metadata check pass.

The full pinned Linux Core suite passes 2,615 tests with zero failures and seven
skips, excluding no socket cases. This is an isolated writable tracked-source
copy with the exact pinned registry, real privileged service-UID fixtures and
the existing locked dependency/toolchain cache. The bundled x86_64 Maude checker
runs through the host compatibility runtime with four read-only libraries from
the pinned Debian image; project dependencies are unchanged. Native arm64's
default unavailable-checker refusal remains separate from this Core check.
Earlier runners were corrected for read-only source/cache, missing registry,
service-user source readability and absent x86_64 loader. The four
checker-dependent cases fail with the unavailable default provider and pass
with the actual compatible checker; no production guard or test assertion was
weakened. Mix emits its existing discovery warning for explicitly loaded support
scripts. This full local run is not a replacement hosted macOS 15 CI run.
