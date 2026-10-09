# Controller TLS bootstrap v1

Version: 0.1.2. Owner: WOH.15 H15-07/H15-T8, WOH.08 H08-09/H08-T9. Status: bounded OTP and Apple bootstrap clients implemented against independent TLS peers and an isolated real Authority listener; installed pairing/custody and native ordinary remote workflows remain unfinished.

This implements the client trust/deadline portion of
[controller connections](controller-connections-v1.md), using the frozen
[pairing records](controller-pairing-wire-v1.md). The client opens no controller
listener and publishes no Keychain credential. Independent synthetic peers check
adversarial trust/framing; two additional native cases use the separate
[real Authority listener](controller-listener-v1.md), actual one-use provisioning
and consumed replay refusal in a private isolated Store.

## Trust before application data

`ControllerConnections.TLSIdentity` uses normal OTP `verify_peer` chain,
signature, purpose and current wall-clock validity checks. Its callback rejects
every platform `bad_cert`. Invited DNS-ID/IP-ID must match certificate SAN
through the maintained matcher, and SHA-256 covers complete leaf DER. Only the
invited DER anchor is supplied. TLS state contains public identity/anchor/pin/clock,
without secret or bearer. No Common Name exception or failed-PKIX override exists.

`NativeControllerTLSClient` uses Network.framework and Security.framework,
expected literal identity SSL policy, invited anchor-only trust and disabled
online certificate fetching. Normal current system-time evaluation is mandatory.
SAN must exist; the platform policy rejects wrong, Common Name-only and URI-only
substitutions in the tested cohort. Complete leaf DER must match the invited pin.
SecTrust work has a separate serial owner so it cannot block socket cancellation.
Cross-queue diagnostics contain only a locked closed error name; raw platform
diagnostics, certificates and private frames are not logged.

Both clients require TLS 1.3, disable resumption/tickets, supply no PSK or early
application data and send only after successful handshake, identity, pin and
clock checks. Apple also disables False Start. Both repeat peer/clock checks
before sending. These settings and fixtures do not replace an installed
downgrade/0-RTT packet campaign or installed listener qualification.

## Additional clock guard

Trusted host composition supplies a conservative UTC uncertainty interval. It
is not an API field, Home execution-clock qualification or automatic assertion
that an arbitrary wall clock is trustworthy. Unknown clocks cannot disable
validation; private local setup remains the repair path.

Constructors accept ordered integer UTC milliseconds from zero through
253402300799000 and a lease of 1–15000 milliseconds. Both endpoints advance by
elapsed monotonic time without widening or renewal. Apple uses `ContinuousClock`,
including suspension. OTP's Mac `CLOCK_UPTIME_RAW` pauses during sleep, so the
Elixir guard separately refuses raw OS wall/monotonic elapsed disagreement beyond two
milliseconds and expires against both elapsed clocks. Wall time adds refusals,
never certificate authority; the VM's corrected wall-time view is not used to
hide an OS clock change. The closed interval supplied by trusted host
composition must account for millisecond sampling uncertainty. Malformed,
future-observed, expired or overflowing bases refuse. The whole live interval
must fit every validated path certificate and the invited anchor. This adds
refusals; it cannot backdate an expired peer into acceptance. Apple numeric
CFAbsoluteTime validity properties use the 2001 epoch; localized labels are
never parsed. Actual clock provenance, sleep/wake and repair remain host gates.

## Finite one-exchange ownership

The Elixir `BootstrapClient.run/4` and native async entry validate the closed
invitation/request and exact controller, invitation and bootstrap-secret join
before dialing. Approved access is a separate trusted selection, initially
`read`/zero targets; requests cannot declare roles or grants. Clients are not
yet composed into product setup or UI.

DNS locates the peer without replacing invited identity. OTP resolves inside
the bounded owner, selecting one IPv6 address when available, otherwise one
IPv4 address. Apple uses platform address selection. Literal IPv4/expanded IPv6
endpoints are independent of DNS/IP SAN identity. No client starts a new
bootstrap exchange after failure. Link-local IPv6 is refused pending separately
owned local client interface selection; invitations cannot choose a scope ID.

A five-second absolute handshake budget covers startup, resolution and trust,
followed by a separate five-second request/framing budget. Headers must declare
1–8192 bytes before body read/allocation. Fragmented reads retain their original
deadline. One response must match all original IDs, request digest and exact
approved access; the credential must differ from the bootstrap secret. Lost or
invalid replies, timeout, close, send failure, truncation, oversized/empty frames,
digest substitution or scope widening after a possible send return
`outcome_unknown`, without retry or credential custody. Verified refusals stay
correlated refusals. Native cancellation closes its connection and preserves
uncertainty after a queued send. Killing the OTP owner closes its socket, with
bounded monitor cleanup rather than an indefinite platform-resolution wait.

## Evidence and remaining delivery

`controller_tls_bootstrap_test.exs` runs 30 real socket cases. Its independent
OpenSSL/OTP peer uses literal arrays rather than the client codec/trust callback.
Four pure clock cases and existing pairing/tool cases complete 255 focused
tests, passing on pinned OTP 28.5.0.6 / Elixir 1.19.6 on the Mac and arm64 Linux
CI builder, without socket exclusions. `mix woh.native.controller.tls.smoke`
now passes 34 independent Apple/OTP cases plus native clock guards, including
the [Home-generated private identity](controller-installation-identity-v1.md)
and real default-read provisioning/consumed replay. The latter use independent
literal requests and actual Store original scope/revision, rather than a
fixture-authored credential or principal.
Local Swift 6.4
passed warnings-as-errors and Swift 6 checks with an arm64 macOS 15 deployment
target on macOS 27. Installed macOS 15/Swift 6.1 behavior is not established;
CI includes this smoke for future runs.

Cases cover DNS/IP SANs, IPv4/IPv6/manual/DNS endpoints, changed pin under the
same CA, wrong/missing/URI-only SAN, wrong purpose, expired/future certificate,
unknown CA, corrupted signature, unknown critical extension, malformed anchor,
uncertain clock, TLS 1.2, fragmented/refused replies, lost/oversized/empty/slow
frames, wrong digest, widened scope, handshake timeout and native cancellation.
Request peers reject a second connection during bounded post-request observation.
Keys use private temporary directories and owner-only files; native fixtures
receive synthetic records over framed stdin, never private arguments/logs.

The separate private identity factory, finite review owner and atomic Store
consumption now implement their core foundations. Still required: installed
identity setup/renewal and private invitation transfer; installed composition of
finite confirmation/window/backoff and one-use provisioning/revocation;
Keychain/controller selection and native ordinary TLS/original mutation recovery; explicit
link-local interface custody; installed/headless interoperability. No physical
dispatch or hardware qualification guard changes here.
