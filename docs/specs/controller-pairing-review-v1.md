# Controller pairing review v1

Version: 0.1.0. Owner: WOH.15 H15-07/H15-T8. Status: closed secret-free review encoding and independent corpus implemented; live local review, durable one-use consumption and installed custody remain separate mechanisms.

This freezes the local approval input for [controller connections](controller-connections-v1.md).
These records are private in-process setup records, absent from ordinary API
routes. Decoding or possessing an approval does not provision a principal.
The Store must recheck the live review, original request, current authority,
revision, permission policy and target eligibility in its eventual one-use
transaction. No schema number or durable receipt shape is reserved here.

## Canonical scope and approval

```text
["wotex-home.controller-pairing-review.v1","scope",
 store_boot,deployment_id,owner_id,authority_epoch,expected_revision]

["wotex-home.controller-pairing-review.v1","approval",
 controller_id,invitation_id,client_id,request_id,request_digest,client_label,
 store_boot,deployment_id,owner_id,authority_epoch,expected_revision,
 permissions,target_ids]
```

Bodies are canonical UTF-8 JSON arrays of 1–8,192 bytes: exact re-encoding,
no objects, whitespace, BOM, escapes, Boolean, null, float, negative or alternate
integer spelling. Maximum depth is two; each array has at most 32 members and
each encoded string at most 128 bytes. Maps accepted by the encoder contain
exactly their named fields, with no structures or extra members.

`store_boot` is the Store-owned `boot:` prefix followed by 32 lowercase
hexadecimal digits. Deployment, owner, controller, invitation, client, request
and request digest each contain 64 lowercase hexadecimal digits. Authority
epoch is from 1 through the maximum signed 64-bit integer; expected revision is
from zero through that maximum minus one, leaving a next decision revision.
Store boot and authority ownership have different identities.

The complete canonical bootstrap request determines `request_digest` under the
[wire profile](controller-pairing-wire-v1.md), including its original secret and
label. The approval contains only that digest and original public fields, never
the bootstrap secret or an application credential. `client_label` uses the same
1–80-byte UTF-8 display grammar and canonical unpadded base64url carrier as the
wire profile; it authenticates nothing. Permissions and targets reuse that
profile's closed, sorted, duplicate-free access grammar and existing transfer
and zero-target restrictions. Default initial access remains exactly `read`
with zero targets. Valid syntax does not establish active target eligibility.

`ReviewCodec.digest/1` is SHA-256 of the entire canonical approval body, excluding
any frame, as 64 lowercase hexadecimal digits. It commits to every original,
scope and access field. It is a local correspondence check, not an authorization
token or a durable consumption receipt.

## Evidence boundary

The independently authored Python positional-array and SHA-256 corpus is
checked in at `test/fixtures/controller_connections/review_vectors.json`.
Elixir checks exact encoding, digest coverage, limits, alternate encodings,
missing/extra fields, malformed private encoder terms and secret rejection.
These tests establish the format only. Live owner lifecycle, concurrent pending
limits, cancellation, durable commit/rollback, lost credential delivery and
installed private transfer remain separately required under H15-T8.
