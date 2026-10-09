# Native controller associations v1

Version: 0.1.1. Owner: WOH.08 H08-09/H08-T9, WOH.15 H15-07/H15-T8. Status: public codec and private CAS publication implemented; Keychain/session/pending integration and installed evidence remain unfinished.

This fixes public client custody before composing [ordinary paired
requests](native-controller-api-v1.md) into controller selection. It extends no
server route or Store schema. Parsing, saving and selecting metadata grant no
credential, authenticated scope or device authority.

## Immutable association and editable location

A record is one canonical UTF-8 JSON array:

```text
["wotex-home.native-controller-association.v1",1,association_id,label_base64,
 controller_id,[identity_kind,identity_value],leaf_pin,trust_anchor_base64,
 [endpoint_kind,endpoint_value,port],
 [deployment_id,owner_id,authority_epoch,principal_id,creation_revision],
 [invitation_id,client_id,request_id,request_digest],
 permissions,target_ids,credential_verifier]
```

Digest/ID, identity, endpoint, port, DER carrier and approved access grammar is
the unchanged [pairing wire](controller-pairing-wire-v1.md). Epoch and creation
revision are positive signed-64-bit integers. Principal is exactly
`paired-controller-v1:EPOCH:CLIENT_ID`, with the canonical decimal epoch and
retained client ID. Label is 1–80 UTF-8 bytes with the pairing label's control
and directional-character refusals, carried as canonical unpadded base64url.
The credential verifier is lowercase SHA-256 of the exact 32-byte application
credential. No bearer or bootstrap secret appears in a record.

`association_id` is SHA-256 of this complete canonical binding array:

```text
["wotex-home.native-controller-association-binding.v1",
 controller_id,[identity_kind,identity_value],leaf_pin,trust_anchor_base64,
 [deployment_id,owner_id,authority_epoch,principal_id,creation_revision],
 [invitation_id,client_id,request_id,request_digest],
 permissions,target_ids,credential_verifier]
```

Label and endpoint are the only editable metadata. Editing them preserves the
binding ID and original custody; identity, pin, anchor, principal, authority,
approved access or verifier changes require a separate association. Exact
republication is idempotent. A record with a substituted field or incorrect
binding ID refuses rather than being repaired. Public IDs/digests and approved
access are historical metadata, not current grants.

Each record/binding body is at most 16,384 bytes, with the pairing canonical
array grammar: no whitespace, escapes, objects, Boolean/null, float, negative
or alternate integer spelling; depth at most three, at most 32 array members
and at most 5,462 ASCII bytes per string. The larger body carrier belongs only
to this new format, allowing the full 4,096-byte anchor together with 32 granted
targets. Existing invitation/bootstrap bodies remain at most 8,192 bytes.

Construction from an original bootstrap request and delivered association
checks exact pairing context/digest, controller and approved access; credential
must differ from the bootstrap secret. Its SHA-256 verifier replaces the bearer
in the record. This pure correspondence check is not a TLS verification seal.
Product publication must consume the actual verified TLS response and approved
selection, not treat a fixture, file or decoded response as proof of pairing.

## Public document and private publication

```text
["wotex-home.native-controllers.v1",revision,selection,record_documents]
selection = ["local"] | ["remote",association_id]
```

Revision is a positive signed-64-bit integer. There are at most eight records,
sorted by distinct association ID. Each record document is a complete canonical
record body carried as a string. The root is at most 131,072 bytes, depth at
most two and at most 32 members per array. Root strings decode at most 16,384
ASCII bytes; only canonical quote/backslash escapes are allowed. Exact
re-encoding reproduces all bytes. Unknown formats, malformed/duplicate rows,
wrong ordering or a remote selection absent from the document refuse.

The fixed files are `native-controllers-v1.json` and
`native-controllers-v1.lock` in the existing private account directory. Use the
shared descriptor-based 0700-directory/0600-single-link file checks, nonblocking
lock, full-content/inode CAS, fsync/rename and uncertain-publication behavior.
This kind alone has the new 131,072-byte limit; pending/network kind names and
limits remain unchanged. A missing document has in-memory revision zero,
empty associations and local selection. Reading or unchanged selection does
not create or rewrite it. A malformed/unsafe file never becomes that default.

Retaining a new association advances revision once and preserves all old rows
and selection. Selecting a retained remote row or local operation is an explicit
metadata change. Editing a label/location advances revision once. Every no-op
still performs the original CAS, so stale/replaced custody cannot pass by
requesting unchanged content. Conflicts/capacity/uncertain publication retain
the caller's original; reload before another decision. Association removal is
not part of this entry: originals may still reference historical custody.

## Keychain and operation successors

The separate remote Keychain service is
`org.wotex.home.paired-controller.v1`; its account is the complete association
ID. The binding includes controller/principal and exact credential verifier,
so different controllers, principals or credential generations cannot share
an item. Actual items must be non-synchronizing and retain the exact 32-byte
bearer under the owning host's current custody checks. Loading this public file
cannot retrieve, import, overwrite or delete an item. Keychain failure cannot
become manual/local credential fallback.

Live selection needs actual matching Keychain custody, fresh validated TLS and
authenticated deployment/owner/epoch/principal reads. Saved permissions/targets
cannot enable a button or authorize a request. An unreachable selected remote
owner stays selected and unavailable; no local execution owner starts from a
transport failure. Stale completion after selection/custody change is discarded.

The existing v1–v4 pending journals remain unchanged. A separately versioned
successor must retain association ID/controller ID together with existing
principal/epoch/exact operation and verifier before remote mutation. Recovery
uses that original association even after selection changes. Endpoint editing
cannot change its trust binding or principal; removal/Keychain collection needs
complete original-reference guards. Neither startup nor file load sends a
lookup, retry, device request or enrollment action.

## Required evidence

Independent literal vectors fix binding bytes/digests, Unicode label carriers,
all identity kinds, integer/boundary/access and full anchor/target bounds. Include
malformed canonical bodies/roots, wrong digest/principal/context, permission
widening and record-order/selection/capacity refusals. Old pairing vectors and
old private-document kinds must retain their exact behavior.

Actual private-file checks must cover missing/no-op bytes, immutable conflict,
editable metadata, stale/full-content/inode CAS, unsafe file/root/lock custody,
revision/capacity exhaustion, separate-process restart and competing publishers
with one winner. These establish public metadata custody only. Real paired
Keychain/session integration, pending-operation recovery, installed macOS 15
TLS interoperability and storage power-loss survival remain separate gates.

## Development evidence

`mix woh.native.controller.associations.smoke` compiles the production public
codec/storage with Swift 6 warnings as errors. Independent literal inputs cover
nine records, 54 record refusals, four roots, 16 root refusals and exact bootstrap
correspondence, including wrong request/controller/principal, credential reuse
and access widening. The fixture compares binding bytes and SHA-256 IDs to
independently authored values; it does not manufacture a TLS or Keychain seal.

Actual descriptor-based private files cover unchanged bytes, metadata edits,
immutable conflicts, stale/inode/full-content CAS, unsafe roots/files/locks,
revision and eight-record exhaustion. Twenty two-process publication races
each retain one winner, then a separate process reloads its original metadata.
These checks pass on the development Swift 6.4/macOS 27 host targeting macOS 15.
The unchanged pairing wire and network/pending private-document regressions
remain required checks. CI runs this public fixture separately before bootstrap;
it opens no listener, Keychain item or device worker and changes no live owner.
