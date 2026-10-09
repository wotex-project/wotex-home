# Controller connections v1

Version: 0.1.6. Owner: WOH.15, H15-07/H15-T8. Status: accepted target; bounded pairing/review codecs, transient local review, atomic Store consumption, per-install identity factory and OTP/Apple TLS bootstrap clients implemented; LAN listener, installed pairing and native remote workflows remain planned.

## Transport and authority

This profile adds a paired LAN transport to the existing Authority; it does not
replace private Unix-socket IPC. Use TLS 1.3 with the existing four-byte
big-endian length followed by closed UTF-8 JSON, one request/response per
connection. Existing API version, route permissions, bounds, receipts and
principal/epoch/operation identity retain their meaning. No Erlang distribution,
raw Store access, generic device proxy or unauthenticated control route is
exposed. TLS early data/0-RTT is disabled, including for reads, so application
requests are never processed before the authenticated handshake completes.

Use maintained platform TLS implementations and normal certificate validation;
do not implement cryptography in Home. The exact OTP/Apple TLS cohort must
demonstrate mutual framing, identity checks and failure behavior before delivery.
TLS 1.3's current specification is
[RFC 9846](https://www.rfc-editor.org/info/rfc9846/); certificate service-name
validation follows [RFC 9525](https://www.rfc-editor.org/info/rfc9525/).

The listener is disabled until trusted local setup explicitly enables selected
addresses/interfaces and a nonprivileged port. Default installation opens no
public listener, router mapping or cloud tunnel. Setup does not change global
firewall rules. A configured remote listener accepts at most 32 concurrent
connections across handshakes and requests, with a five-second handshake
deadline followed by the existing route/frame deadline and bounded send period.
Reject oversized frames before allocation. Overload rejects new connections;
it cannot hold Store locks or displace pending work. Limits remain conservative
targets until measured. Remote input never acquires the same-UID trust of UDS.

## Explicit identity and pairing

Each installed controller has a separately generated private TLS identity and
stable controller ID. Neither the universal firmware image nor a release
archive contains a shared TLS key, bearer or pairing secret. A home authority
epoch is not a TLS identity, hostname or IP address.
The [installation identity foundation](controller-installation-identity-v1.md)
now creates one immutable private ID/certificate/key record, validates complete
signed correspondence and refuses unsafe/replaced custody before TLS options.
It opens no socket; installed host setup and lifetime ownership remain separate.

Trusted local setup creates a private out-of-band invitation containing protocol
version, controller ID, expected certificate identity and SHA-256 leaf
certificate pin, candidate endpoint, invitation ID and a random 32-byte
single-use bootstrap secret. It is at most 8 KiB. Its exact closed encoding and
bootstrap request/response fixtures must be frozen before implementing the
transport and provisioning adapter. The [closed wire profile](controller-pairing-wire-v1.md)
now defines those records and independent Elixir/Swift correspondence; it opens
no listener or window and provisions no credential.
The separate [TLS bootstrap clients](controller-tls-bootstrap-v1.md) now validate
platform chain/name/validity, the invited pin and a finite trusted-client clock
interval before application data. Independent OTP/Apple peers exercise trust,
framing and deadlines. The [secret-free local approval format](controller-pairing-review-v1.md)
binds the full original request, Store boot, current authority, revision and
approved access. Its transient owner now composes trusted read-only Authority
scope, bounded pending/backoff and exact checkout/lifecycle guards. Review and
checkout create no durable consumption or credential.
The separate [schema-28 consumption](controller-pairing-consumption-v1.md)
atomically provisions exact approved access and retains the one-use original,
with restart/lost-delivery status and trusted revocation. Installed identity
custody, setup and listener wiring remain separate.
The secret is transferred only through an operator-chosen private file or
private QR view; no command arguments, URL query, discovery record, clipboard
by default, telemetry or logs. A short displayed number alone is not an
authentication scheme. There is no trust-on-first-network-contact mode.

The client validates the invited certificate pin, certificate signature/chain,
validity and service identity before sending a bootstrap secret or bearer. A
local CA/trust anchor can be provisioned in the invitation; public PKI, public
DNS, online certificate retrieval and Internet time are not required. Unknown
or changed pins fail closed; certificate rotation requires an authenticated
reviewed replacement under the existing identity or a new trusted invitation,
never accepting a replacement merely because discovery advertises it.
Clock uncertainty affecting certificate validity is reported explicitly. Local
UDS setup remains available to repair clock/trust; remote clients cannot disable
certificate checks to recover access.

The invitation is usable only while the operator has opened one controller's
pairing window, for at most five minutes in that controller boot's monotonic
clock. Restart closes the window. At most one window and eight concurrent
pending pairing exchanges exist; attempts have bounded backoff. An explicitly
confirmed client receives a separately provisioned credential once, with exact
approved permissions. Default initial access is `read` with zero Thing grants.
Enrollment/profile-management permissions and target control grants require
separate explicit approvals; the current closed principal/rotation rules apply.
The exchange cannot accept caller-chosen roles or raw target declarations.

Bootstrap authentication is a separate setup adapter/use case, unavailable
outside the finite window. It calls the Authority's trusted provisioning
boundary and never publishes ordinary principal/key/transfer setup routes.
Durably consuming an invitation and recording its client association must not
create two credentials on a retry. A lost credential delivery requires trusted
local revocation and a fresh invitation; it is not answered by replaying a
secret-bearing response. Exact encoding, confirmation identity, transaction
and cleanup/crash fixtures are implementation-entry obligations, not existing
callable API names.

For an appliance without a local console, the operator's installer may generate
per-install private setup material and retain the public identity invitation
before flashing; the first boot consumes its private custody. Universal image
bytes remain public/unpersonalized. An appliance that cannot establish that
trusted channel must not expose open first-user-wins enrollment. This does not
require a dedicated image for shared-server installation.

## Discovery, credentials and reconnection

Optional mDNS/DNS-SD advertises version, controller ID and candidate endpoint
only. Discovery is an untrusted location hint and grants nothing; a manual
endpoint works without multicast. The service type/registration and closed TXT
schema must be fixed in the host delivery cohort before claiming discovery.
[DNS-SD](https://www.rfc-editor.org/rfc/rfc6763) does not replace pairing.
Endpoint changes retain the pinned controller identity; they do not mint a new
home or reset operation scope.

After pairing, existing application bearers travel only inside validated TLS.
The native app retains them in non-synchronizing Keychain custody, separately
per controller/principal. The server persists credential digests and current
grants through the single Store. A client association cannot grant target
authority on its own. Revocation/rotation has the same current checks at
admission and handoff as local calls. A stolen host-account credential remains
within the declared trusted-host threat boundary, rather than acquiring a
fictional hardware attestation claim.

Before a mutation, retain selected controller ID, principal association,
authority epoch, operation ID, exact input and expected resource revision.
Resolve a lost reply against that original controller/principal scope; do not
retry with a new ID, move it to a different controller or label it failed merely
because the TCP connection closed. Revoked/replaced associations can require
local administrative reconciliation, not silently recover another principal's
private receipt. Pairing or switching controllers never changes old receipt
identity. Obtain a fresh consistent snapshot after reconnection; events, if
later enabled, retain the existing bounded credit/gap contract.

The Mac may edit local drafts while the selected remote owner is unreachable.
Drafts do not become admitted schedules or queued effects until reviewed by that
owner. Live control is unavailable and clearly labeled. There is no implicit
local actuator fallback or background upload of offline button presses.

## Acceptance corpus

H15-T8 includes valid scoped pairing plus rogue discovery, endpoint/pin/name
substitution, expired certificate, uncertain clock, TLS downgrade/early data,
oversized/slow frames, connection exhaustion, pairing restart/expiry/replay,
lost credential delivery, denied grant widening, revoked credentials and lost
mutation responses. Run identical Authority cases through UDS and TLS with
independent clients. Audit artifacts, arguments, logs and discovery for secret
absence. Installed Apple/OTP interoperability and actual headless first-boot
custody are separate from synthetic TLS peers.
