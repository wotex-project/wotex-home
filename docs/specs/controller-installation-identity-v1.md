# Controller installation identity v1

Version: 0.1.0. Owner: WOH.15 H15-07/H15-T8. Status: bounded per-install identity factory and immutable private record implemented; installed host setup, listener ownership, rotation and first-boot delivery remain planned.

## Explicit creation and scope

Trusted local code calls `ControllerConnections.InstallationIdentity.create/2`
with an absolute custody path and exactly `not_before` and `not_after` whole
UTC-second values. The parent must already be canonical, symlink-free, private
0700 custody. Creation does not create a directory, start a Home host, open a
listener, open pairing, change network/firewall settings or provision a bearer.
No private material appears in arguments to an external command. OTP's maintained
`public_key` implementation generates and signs the certificates; Home does not
implement a signature or elliptic-curve algorithm.

Each creation generates an independent random 32-byte controller ID, encoded
as 64 lowercase hexadecimal digits, and separate P-256 anchor and server keys.
The stable service identity is `home-<first 32 controller ID digits>.local`.
The complete controller ID is signed into both certificates' subject
`serialNumber` attributes; changing the unused suffix cannot substitute an ID.
This DNS identity does not perform discovery, resolve a name, select an endpoint
or identify the Store's controller owner or authority epoch.

The caller-supplied interval must start at or after the Unix epoch, end strictly
after its start and no later than `9999-12-31T23:59:59Z`, and span at most 366
days. Both certificates have that exact interval. Times through 2049 use
canonical UTCTime, with GeneralizedTime from 2050. These inputs establish
certificate fields only: they do not establish a trustworthy host/client clock,
physical qualification or autonomous scheduling authority. Installation and
renewal must supply their separately reviewed clock/trust basis.

## Frozen private record

One canonical UTF-8 JSON array, at most 8192 bytes, contains:

```text
["wotex-home.controller-installation-identity.v1",
 controller_id, ["dns", service_identity], not_before, not_after,
 leaf_certificate, trust_anchor_certificate, leaf_private_key]
```

The three binary values are canonical unpadded base64url DER. Each certificate
is at most 2048 bytes and the EC private key is at most 256 bytes. Reject other
fields, objects, noncanonical JSON, excessive nesting/membership, floats,
oversized strings/numbers, invalid UTF-8, malformed DER and noncanonical DER
round trips before returning material. Parsing is bounded before entering a
container or converting a numeric token. This is a secret-bearing installation
record, never an invitation, backup record, discovery entry or ordinary API
input/output. Its anchor private key is discarded after signing; it is absent
from the record and all release/image bytes.

The closed certificate profile is v3, ECDSA with SHA-256 and absent signature
parameters, P-256 named-curve public keys and positive serials below 2^128.
The anchor is self-issued and self-signed, with critical CA basic constraints
and a zero path-length constraint, and critical keyCertSign/cRLSign usage.
Its common name is `WoTEx Home anchor`. The leaf is issued by that anchor,
with the DNS common name, critical non-CA basic constraints, critical
digitalSignature usage, serverAuth extended usage and exactly one matching DNS
SAN. Unique IDs, other extensions/purposes and alternate subject encodings are
refused. The anchor and leaf public keys must differ. Standard OTP signature
verification checks the root self-signature and leaf signature; a fresh random
challenge verifies the private scalar against the leaf's exact public point.
The private key's own public point must also match. Reads never infer integrity
from a name, pin or DER parse alone.

Creation checks the complete record before publication. Existing `PrivateFile`
custody synchronizes an exclusive 0400 temporary file, publishes by a
nonreplacing hard link, removes its owned temporary link, synchronizes the
parent and checks the final descriptor/path. One record keeps ID, chain and key
from becoming a partially installed identity. Concurrent creation has one
winner; every other creator receives `private_custody_exists`. Existing files,
links, damaged custody and expired identities are never overwritten or
regenerated automatically. File/directory sync failure follows the existing
owned-file cleanup rules; storage power-loss behavior remains a separate host
qualification obligation.

## Loading, activation and disclosure

`read/1` revalidates the entire closed record and retains its `PrivateFile` seal.
The private result has a redacted Inspect implementation. `check/1` rereads and
compares both complete material and the original seal: identical-byte inode
replacement, changed ancestors, mode/owner/link changes and forged in-memory
fields invalidate the loaded identity. This is private host-account custody,
not hardware attestation or protection against the declared privileged host.

`descriptor/1` repeats that check and returns only controller ID, DNS identity,
SHA-256 complete-leaf pin and base64url trust anchor, using the existing
invitation field names. It contains no leaf key, anchor key, bearer, bootstrap
secret, filesystem path or Store connection.

`server_options/1` repeats sealed custody validation and normal OTP PKIX path
validation, including current validity, before returning secret-bearing options
to a trusted socket owner. It requires TLS 1.3, disables session tickets and
early data, bounds handshake data and send time, and suppresses TLS diagnostics.
Expired/future material remains readable for local diagnosis but cannot serve;
refusal never grants a remote certificate-check bypass. Returning options opens
no socket. A future listener must repeat custody/validity at its own activation
and connection boundaries and stop on owner/Store/custody loss. This factory
does not provide that lifetime owner or rotation workflow.

## Implemented checks and remaining acceptance

The core suite checks unique installations, actual concurrent publication,
restart-style reads, bounded canonical parsing, ID/interval/anchor/leaf/key
substitution, damaged signatures and private scalars, mismatching key points,
unsafe file/link custody, identical-byte replacement, expiry and the 2050/final
year bounds. A real OTP TLS 1.3 socket validates the generated identity with the
existing pinned client. Independent OpenSSL verifies the generated chain,
hostname and server purpose and rejects a wrong name or client purpose.
The native TLS smoke corpus additionally sends independent literal pairing
frames through the Apple client to an OTP peer using this generated identity.
The expanded 32-case native corpus and 20 selected identity/private-file cases
passed on the available macOS cohort; the same 20 core cases passed in the
pinned Linux arm64 builder without networking outside its loopback fixture.

These are development software checks. No actual controller is installed or
paired, no Keychain entry is created and no physical driver is enabled. Signed
installed Apple/OTP interoperability, private Linux service custody, headless
first-boot personalization, lifetime listener fencing, reviewed renewal and
storage crash/power-loss evidence remain required by H15-T8 and their host
contracts. Universal releases remain unpersonalized.
