# Native controller API v1

Version: 0.1.0. Owner: WOH.15 H15-07/H15-T8, WOH.08 H08-09/H08-T9. Status: bounded native ordinary TLS API and real Authority receipt parity implemented; native selection, durable association/Keychain custody and installed interoperability remain unfinished.

This client consumes the existing [controller listener](controller-listener-v1.md)
and ordinary API. It shares the [bootstrap client's](controller-tls-bootstrap-v1.md)
platform chain/name/SAN/pin/clock checks and finite connection owner. It adds no
server route, provisioning permission, device dispatch or local UID exception.

## Public peer and exact request

`NativeControllerPeer` contains exactly controller ID, expected certificate
identity, complete leaf DER pin, invited DER anchor, candidate endpoint and port.
Constructing it from a validated invitation discards the invitation ID and
bootstrap secret. The same closed address/digest/anchor-size/port grammar applies.
It is an in-memory public trust projection, not a persisted association format.
Location cannot replace identity or change principal/operation scope.

`NativeControllerAPIRequest` retains the exact ordinary request bytes. Before
connecting, it requires a 1–65,536-byte strict JSON object, integer API version 1,
bounded ordinary operation name and canonical 32-byte bearer. Duplicate decoded
members, including escaped duplicates, and depth above 16 refuse. Authority
still owns each route's complete closed field/permission schema. The shared
`LocalHealthClient.requestBody` constructor refuses overrides of the version,
operation or credential envelope and uses the unchanged local encoding. Neither
the request's mirror nor the exchange owner's mirror exposes private frames.
Bearer-bearing requests are never persisted by this transport.

## One bounded exchange

TLS 1.3 and normal platform certificate validation precede application bytes.
Resumption and False Start stay disabled; no early data, fallback or automatic
retry is introduced. The five-second absolute handshake deadline includes
resolution, trust and clock rechecks. A separate five-second ordinary request
deadline, or ten seconds for the existing seven review operations, includes
send, fragmented framing and strict envelope decoding. A reply whose validation
crosses the original deadline is unknown even if all bytes arrived in time.
Domain-specific receipt/snapshot/original correspondence remains the owning
SDK's obligation before publishing a successful application result.

Responses declare 1–1,048,576 bytes in the existing unsigned four-byte
big-endian header before allocation. One mutable receive buffer appends bounded
fragments without copying its complete prefix on each read. Headers and body
retain the same absolute request deadline. The owner releases its outgoing
frame after queuing send and clears owned buffers on completion. This is memory
lifetime reduction, not a platform-wide erasure guarantee.

The shared strict local envelope decoder preserves exact verified server
refusals. Bare `not_found` is accepted only when the original caller opts in.
Malformed/oversized/empty/truncated/lost replies, expiry or cancellation after a
possible queued send remain `outcomeUnknown`; a broken connection cannot prove
that the Authority did not commit. Recovery explicitly reads the original
controller/principal/epoch/operation, without minting a new operation ID or
resending. Revocation returns the existing authenticated refusal.

An optional host-check diagnostic cell retains only a fixed validation-stage
name and numeric platform status. It holds no platform error object, certificate,
endpoint, invitation or application bytes and cannot affect validation. Normal
production calls supply no cell. Fixtures print its bounded snapshot only after
an unexpected outcome; no raw Security/Network diagnostic is emitted.

## Evidence and delivery boundary

`mix woh.native.controller.api.smoke` compiles Swift 6 with warnings as errors
and an arm64 macOS 15 deployment target. Independent OpenSSL/OTP peers check
valid and invalid chain/name/purpose/signature/pin/clock, TLS 1.2 refusal,
fragmented/lost/slow/invalid frames, strict escaped-duplicate/depth/envelope
refusals, exact 64-KiB requests and 1-MiB responses, verified server refusals,
ordinary/review deadlines, validation crossing the deadline and deterministic
post-send cancellation. Peers verify exact application input and observe no
second connection; failed trust sees no application bytes.

Separate real Authority/SQLite/private-UDS/TLS cases compare health, controller
identity, catalogue and snapshot. Native control produces the same immutable
receipt as UDS; exact original lookup and exact retry do not advance the Store.
A validated relay delivers a real mutation to the Authority, discards its
committed reply and observes no native retry. Native uncertainty resolves to the
same original TLS/UDS receipt without another revision. Read-only control is
rejected through the same receipt path. An explicitly approved real pairing
grants read/ordinary-control for one synthetic target; the freshly delivered
credential performs control and original UDS/TLS lookup in memory. Revoking the
old principal makes ordinary native requests unauthorized. Dispatch remains false.
Temporary keys/Store/custody are private and removed; stdin carries synthetic
records and fixture output contains only constant results or receipt digests.

The affected four core test files pass 74 tests on pinned OTP 28.5.0.6 / Elixir
1.19.6 on both the development Mac and arm64 Linux builder, with real sockets
and no exclusions. The shared local health and live CLI/native parity smokes
also pass. These checks establish development mechanisms, not full acceptance.
Local Swift 6.4 runs on macOS 27. CI at `69c6e88` on macOS 15.7.9 rejected the
first valid bootstrap peer with `tlsPeerUnverified`; its undifferentiated log
does not establish the failing check. The bounded stage diagnostics support
that investigation; they are not a demonstrated fix or macOS 15 evidence.

This client is not yet connected to the existing window/menu-bar session or
domain SDK selection. Still required: versioned public association and original
custody, separate non-syncing per-controller/principal Keychain items, explicit
selection and current-scope refresh, stale completion/switch/revocation guards,
installed private invitation transfer and host/headless interoperability.
No credential is automatically imported, and no failed remote exchange enables
a local execution owner or qualifies any hardware.
