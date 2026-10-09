# Controller listener v1

Version: 0.1.1. Owner: WOH.15 H15-07/H15-T8, WOH.08 H08-T9, WOH.19. Status: explicit core Host composition, bounded TLS listener, ordinary Authority parity and finite real pairing implemented; separate ordinary native client implemented; installed setup and native remote selection remain unfinished.

This implements the server transport of [controller connections](controller-connections-v1.md).
It calls the existing Authority and single Store. It receives no SQLite handle,
device transport or privileged local principal. Private Unix-socket IPC remains
available. TLS input gains no same-UID exception and cannot call ordinary
principal provisioning, identity replacement, transfer setup or pairing-window
administration routes.

## Trusted activation and lifetime

`ControllerConnections.Server.start_link/1` accepts exactly `enabled`,
`authority`, `identity` and `binding`, with optional process `name`. Unknown or
duplicate keys refuse. `enabled` must be exactly true. Authority must resolve
to a live Store PID, and its finite pairing-review owner must be bound to that
same PID. Identity is an already loaded, originally sealed
[installation record](controller-installation-identity-v1.md); activation never
creates, replaces or renews it.

Binding is exactly `%{interface: name, address: literal_tuple, port: port}`.
The interface name is 1–64 bytes, appears in actual `inet.getifaddrs`, is up and
running, and contains the selected address exactly once. Port is 1024–65535.
IPv4 wildcard, zero-network and multicast addresses refuse. IPv6 wildcard,
multicast, link-local and IPv4-mapped addresses refuse; scoped link-local
selection remains a separate client/host mechanism. Loopback is supported for
local testing. One listener binds one selected address; IPv6 uses v6-only
binding. Actual socket address/port must match before activation succeeds.
This code changes no interface, route, router mapping, DNS or firewall rule.

Trusted `Host.start_link` can add this transport with the optional
`controller_lan: %{identity: loaded_identity, binding: binding}` argument.
The finite review and listener follow Store ownership and private IPC in the
existing rest-for-one tree. Omission starts neither review nor LAN listener.
Installed release configuration, local setup commands and native settings do
not yet expose this argument. A trusted in-process option is not installed
service qualification.

The listener binds the original Store and review PIDs. Death of either stops
the listener and accepted connections. A one-second fence and connection/send
boundaries recheck those exact live identities, selected interface/address,
original private-file seal and current certificate validity. Subsequent
connection checks do not wait on the review or Store mailbox. Store restart
starts a fresh review and revalidates the same loaded identity; it never
adopts replaced custody. Acceptor/listener loss closes its linked socket owners.
Identical-byte identity inode replacement fences the transport. Certificate
renewal and installed custody/lifetime procedures remain separate work.

`template/1` returns only the current public installation descriptor plus
selected endpoint, after the same fence. It opens no window. `status/1` exposes
only enabled state, active connection count and limit. OTP diagnostics replace
state and message with fixed private/redacted values; TLS diagnostics are
disabled. No key, bearer, bootstrap secret or custody path is logged.

## Bounded framing and ordinary dispatch

Only TLS 1.3 is enabled, with session tickets and early data disabled. At most
32 admitted sockets share one cap across handshakes and request workers; backlog
is also 32. Excess accepted sockets transfer to a disposable owner which is
terminated before starting a handshake. The pinned OTP cohort closes that
transport promptly, optionally with bounded warning alerts, and sends no
handshake or application payload. Saturation leaves UDS and Store available.

Each admitted socket has a five-second absolute handshake budget. A linked
watchdog ends its actual owner if a stalled TLS operation exceeds that budget.
Successful handshake starts a separate five-second ordinary frame/request
budget. The four-byte big-endian header must declare 1–65536 bytes before any
body read. A canonical pairing array is separately capped at 8192 bytes after
its first byte and before reading the remainder. Fragmented header/body reads
retain the original deadline; there is one request/response per connection.

Ordinary object frames use the existing closed `LocalAPI.Frame` decoder and
`LocalAPI.Server.route` Authority boundary. Shared `LocalAPI.Exchange` owns
bounded execution for both TLS and UDS. The ordinary deadline includes prior
frame reads; existing review operations retain their separate ten-second route
budget. A guard monitors the actual adapter caller and links its route worker.
Caller loss or expiry ends those execution processes even when Store is
suspended. Exceptions produce closed error names without logging raw calls.
Read timeout/unavailability and mutating `outcome_unknown` remain distinct.
Already submitted Store work or handoff cannot be undone by killing an adapter;
this is cleanup, not a transaction or physical cancellation guarantee.

Responses reuse the existing 1 MiB bound and a one-second socket-send timeout.
Malformed/duplicate-member/unknown-field requests retain existing closed
outcomes. Current application credentials and grants are checked by Authority
and Store, including rotation/revocation after TLS establishment. Lost mutation
responses resolve through the original principal/epoch/operation status; no
automatic resend or new operation ID is introduced. A second frame cannot
stage a second operation.

## Real finite pairing

Trusted `Host.open_controller_pairing/1` obtains the current public template
then calls Authority outside the listener process. The actual local setup PID
owns the window; possessing network access does not open it. The unchanged
[review owner](controller-pairing-review-v1.md) retains its one-window,
five-minute, eight-pending, candidate/backoff and exact confirmation limits.

Canonical bootstrap arrays use the frozen [wire codec](controller-pairing-wire-v1.md).
Post-TLS `Authority.pairing_offer/2` checks durable consumption, then offers the
exact request to the bound review as the actual socket worker. Existing trusted
preconfirmation sends approval when that worker first attaches; otherwise live
local approval is required. Confirmation refers to the private review reference,
not a network role/grant field. The original five-second request budget covers
offer, confirmation and completion under a linked watchdog, including a stalled
review mailbox.

Approved completion uses the unchanged [schema-28 transaction](controller-pairing-consumption-v1.md).
Actual checkout caller, live approval, current Store boot/owner/epoch/revision,
permissions and targets remain final commit guards. Default access is exactly
read with zero targets; control requires explicit local approval. Correlated
paired/refused frames contain the original IDs and request digest. Replay after
commit returns `invitation_consumed` without any credential, including after
restart. Lost delivery stays consumed and requires trusted original status,
revocation and a fresh invitation. Listener death/timeout does not refund it.

## Evidence and remaining delivery

The actual socket/SQLite corpus exercises UDS/TLS scoped-read and mutation/status
parity, current credential changes, lost mutation replies, default and explicit
pairing, preconfirmation/live confirmation, refusal/expiry/replay, framing,
handshake deadlines, overload, IPv6, custody and Store/review restart. The
shared Exchange tests check actual route-worker cleanup and secret-free failures.
The 132-case affected suite passes on pinned OTP 28.5.0.6 / Elixir 1.19.6 on
macOS and the arm64 Linux builder, without socket exclusions, including abrupt
listener loss, redacted status and stalled Store deadlines.

`mix woh.native.controller.tls.smoke` passes 34 Apple/OTP cases plus clock guards.
Two new cases use a real isolated Authority listener and private SQLite Store:
the native client receives a fresh real default-read credential, then an exact
consumed replay refusal. Independent literal wire input and original Store
scope verify the response. This creates no Keychain association. The available
Swift 6.4/macOS 27 host targets macOS 15; signed installed macOS 15/Swift 6.1
interoperability remains separate evidence.

The [ordinary native API](native-controller-api-v1.md) adds real paired scoped
control, UDS/TLS parity, a dropped real committed mutation reply, exact original
lookup/retry and revocation. Its development Mac checks pass; macOS 15 CI rejected
its first valid bootstrap peer, an unresolved separate interoperability failure.

Installed host activation/identity renewal/private invitation transfer, native
durable association/Keychain/controller selection, explicit link-local selection,
headless personalization, packet-level early-data campaigns and storage
power-loss evidence remain H15-T8/H08-T9/H19 obligations. No device is enrolled
or physically qualified by this corpus; dispatch remains default-disabled.
