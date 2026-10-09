# Controller pairing wire v1

Version: 0.1.3. Owner: WOH.15 H15-07/H15-T8, WOH.08 H08-09/H08-T9. Status: inert encodings and independent Elixir/Swift correspondence implemented; separate TLS bootstrap clients, finite confirmation, atomic consumption and explicit core listener implemented; installed custody/setup remain planned.

This freezes the format entry for [controller connections](controller-connections-v1.md).
Parsing grants no pairing or certificate authority. The separate adapter must
satisfy the parent contract before sending secrets or provisioning principals.
The separate [consumption annex](controller-pairing-consumption-v1.md) owns
the implemented trusted Authority/Store transaction and secret-free history.

## Canonical bodies and framing

Bodies are canonical UTF-8 JSON arrays only: no objects, whitespace, escapes,
Boolean, null, float, negative integer or alternate integer spelling. Wire strings
are printable ASCII without quote/backslash; labels travel as base64url. Exact
re-encoding must reproduce every byte. Arrays have at most three levels and
32 members each. Each body is 1–8,192 bytes, without BOM or trailing newline.
The operator's private invitation file contains just the body, under the parent
contract's private custody.

Bootstrap connections prepend an unsigned four-byte big-endian body length.
Reject headers outside 1–8,192 before allocating/reading a body, consume exactly
that length and one response, then close. Complete-frame decoders reject
truncation/trailing bytes. Ordinary API object framing retains its existing bounds;
these arrays are separate setup records, not ordinary API routes. Transport
deadline and slow-peer checks are implemented in the separate
[TLS bootstrap clients](controller-tls-bootstrap-v1.md); listener connection
exhaustion remains unfinished.

## Invitation

```text
["wotex-home.controller-invitation.v1",1,
 controller_id,[identity_kind,identity_value],leaf_pin,trust_anchor,
 [endpoint_kind,endpoint_address,port],invitation_id,bootstrap_secret]
```

Controller and invitation IDs are separate random 32-byte values represented
by 64 lowercase hexadecimal digits. Controller ID is a per-install identity,
separate from Home deployment, owner and epoch. `leaf_pin` is SHA-256 of the
complete DER leaf certificate, in the same hexadecimal grammar. `trust_anchor`
is one DER X.509 trust-anchor certificate of 1–4,096 bytes, canonical unpadded
base64url. `bootstrap_secret` is a random 32-byte single-use secret, exactly
43 canonical unpadded base64url characters. Port is an integer from 1,024 to 65,535.

Identity and endpoint kinds are `dns`, `ipv4` or `ipv6`. Invited identity is the
literal certificate DNS-ID/IP-ID. The endpoint locates the peer and can differ
from its certificate identity; discovery/lookup/peer claims cannot replace it.
DNS values use lowercase ASCII LDH labels of 1–63 bytes, at most 253 total,
without empty labels, trailing dot, leading/trailing hyphen, wildcard, underscore
or URL syntax. The final label contains an ASCII letter. Internationalized names
use reviewed ASCII A-labels. IPv4 is four decimal octets without leading zeros.
IPv6 is eight lowercase four-hex-digit groups, without compression, brackets,
IPv4 tail or zone. Editors may normalize operator input first. Link-local IPv6
needs separately selected local client interface custody; the invitation cannot
choose that client's interface index or trusted route.

The codec bounds the anchor carrier without parsing/authenticating X.509.
The real creator must supply valid DER through maintained platform tooling.
TLS must reject invalid DER, failed chain/signature, name, validity or leaf pin
before sending a secret. DNS-ID/IP-ID matching follows
[RFC 9525](https://www.rfc-editor.org/rfc/rfc9525.html); Common Name and discovered
aliases cannot supply replacement identities. TLS 1.3, clock refusal and disabled
early data retain the parent contract's requirements.

## Exact request and confirmation

```text
["wotex-home.controller-bootstrap-request.v1",1,
 controller_id,invitation_id,client_id,request_id,client_label,bootstrap_secret]
```

Controller/invitation/secret come from the trusted invitation. Client and request
IDs are separately generated random 32-byte values, 64 lowercase hexadecimal
digits. They identify association/exchange, not hardware attestation. Label is
canonical unpadded base64url of 1–80 UTF-8 bytes, excluding C0/C1 controls,
U+061C, U+200E/U+200F, U+2028/U+2029, U+202A–U+202E and U+2066–U+2069.
It is untrusted display text and cannot authenticate a client.

No role, permissions, grants, declaration or ordinary API credential may appear
in a request. Local confirmation separately binds its full original and approved
access. `request_digest` is SHA-256 of the complete canonical request body,
excluding the header, as 64 lowercase hexadecimal digits. It includes label and
secret and cannot supply operator confirmation by itself.

## Response and scope correspondence

```text
["wotex-home.controller-bootstrap-response.v1",1,
 controller_id,invitation_id,client_id,request_id,request_digest,
 ["paired",deployment_id,owner_id,authority_epoch,principal_id,revision,
  permissions,target_ids,credential]]

["wotex-home.controller-bootstrap-response.v1",1,
 controller_id,invitation_id,client_id,request_id,request_digest,
 ["refused",reason]]
```

Deployment/owner use existing 64 lowercase hexadecimal IDs. The Store derives
positive signed-64-bit epoch and association/provisioning decision revision.
Principal/target IDs use Home's existing 1–128-byte ASCII grammar. Credential
is a separately generated random 32-byte bearer in canonical unpadded base64url,
which must differ from the invitation bootstrap secret;
only its digest and current grants belong in the Store.

Permissions are nonempty, sorted and duplicate-free from Home's current closed
vocabulary. Targets are sorted/duplicate-free, at most 32. Existing provisioning
rules remain: zero targets permit only `read`, `enroll:review`, `host:maintain`,
`profile:manage` or isolated `host:transfer`. Transfer combines no other permission
and has no targets. Syntax grants no enrollment or access.

Initial approval defaults to exactly `["read"]` and `[]`. Before credential custody,
correspondence requires all four original IDs, the full request digest, a distinct
credential and exactly the approved permissions/targets. Extra or missing scope is refused. Separately
trusted explicit approval may select another scope through the same check;
request fields cannot nominate it. Later widening/rotation retains existing
trusted approval/current-grant rules.

Refusal reasons are `pairing_closed`, `pairing_expired`, `invitation_unavailable`,
`invitation_consumed`, `confirmation_denied`, `pairing_busy`, `pairing_unavailable`
and `outcome_unknown`. Refusals carry no credential/secret. These format values
do not establish a window, backoff, transaction or retry adapter. After consumption,
lost credential delivery requires local revocation and a fresh invitation; retries
cannot replay success secrets. Atomic consumption/association and cleanup/crash
behavior must be implemented through the single Store before pairing delivery.

## Independent evidence

The [corpus](../../test/fixtures/controller_connections/wire_vectors.json) was
authored with independent Python JSON/base64/SHA-256 values, without either codec.
It has 28 valid records with expected fields/framed bytes, 158 malformed records,
18 request/access correspondence cases and 12 header vectors. Public synthetic
IDs/secrets and opaque anchor carriers establish format/bounds only, not installed
credentials or certificate validity.

Run `mix test test/wotex_home/controller_pairing_codec_test.exs` and
`mix woh.native.controller.pairing.wire.smoke`. Swift independently reconstructs
every expected field, checks the same refusals/framing and hashes the full original
through CryptoKit. These checks open no TLS, Keychain, controller Store, pairing
window or device worker. Actual Apple/OTP interoperability, chain/name/pin/clock
rejection, early data, window expiry/restart, one-use/crash transactions, lost
delivery, revocation and lost mutation responses remain H15-T8/H08-T9 obligations.
