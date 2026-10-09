# Controller pairing review v1

Version: 0.1.2. Owner: WOH.15 H15-07/H15-T8. Status: closed encoding, bounded live review and trusted Authority composition implemented; separate atomic consumption implemented; host setup/listener wiring and installed custody remain planned.

This freezes the local approval input for [controller connections](controller-connections-v1.md).
These records are private in-process setup records, absent from ordinary API
routes. Decoding or possessing an approval does not provision a principal.
The Store must recheck the live review, original request, current authority,
revision, permission policy and target eligibility in the separate
[one-use transaction](controller-pairing-consumption-v1.md).

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

## Finite local review

`PairingReview` owns one transient five-minute-maximum window. It receives an
opaque Store-owner PID for lifecycle binding, never a SQLite handle. Trusted
`Authority.pairing_open` reads the current writable active Store's boot,
deployment, owner, epoch and revision outside the review process. Maintenance,
retirement, damaged controller/maintenance history and unavailable Store refuse
that read. The Authority checks that its configured review belongs to the same
Store PID. No host starts a review or listener by default in this increment.

Opening accepts exactly the installed public `controller_id`, `identity`,
`leaf_pin`, `trust_anchor` and `endpoint`. It validates the invitation grammar
and anchor DER using the existing TLS identity parser, then generates fresh
32-byte invitation identity and secret. This parser does not prove possession
of the server private key or installed identity custody. The returned invitation
still requires private file/QR transfer. State retains a SHA-256 secret verifier,
never the secret or invitation body. A private BEAM reference controls local
pending/approve/deny/close operations; the opening setup process is monitored.
Ordinary API and bootstrap request fields cannot supply that reference, access
or current Store scope.

Trusted `Authority.pairing_prepare` may preconfirm a privately transferred
request before the network exchange. A post-TLS handler's `PairingReview.offer`
authenticates the same closed request, controller, invitation and secret with
OTP constant-time verifier comparison, retaining only public original fields
and the complete request digest. It binds one offer to the live handler PID.
Preconfirmation is unbound until one handler attaches; another connection cannot
take over an attached original. Preconfirmation does not relax the subsequent
TLS or finite request deadline.

At most eight pending clients and 32 new candidate entries exist per window.
Exact duplicates share their existing reference and consume no extra entry.
A different request for an already pending client refuses. Denial removes the
entry and retains a bounded digest tombstone; replacing/losing entries does not
refund the candidate budget. Authentication failures have 250 ms exponential
backoff capped at eight seconds; calls during backoff refuse without queuing.
After 32 authentication failures the whole window closes. Trusted cancellation
and pending review remain available during backoff.

`Authority.pairing_approve` reads current Store scope separately and approves one
exact pending original, with default access or separately explicit trusted
access. The Store boot/deployment/owner/epoch must match opening, and revision
cannot precede opening. Only one selected approval exists. Other pending
candidates gain nothing. Target existence, current grants and commit CAS remain
the separate Store transaction's responsibility; this transient approval does not
create any revision, journal row, target grant or credential.

Checkout reauthenticates the original, requires the selected exact request and
live attached handler, and creates one private reference committing to the
canonical approval digest. Guard checks that exact reference/digest and the live
window. Finish is restricted to the original checkout process and discards it.
Checkout is never represented as durable invitation consumption. The separate
Store composer obtains its private basis only as the bound Store PID, for the
actual original checkout caller, and repeats that guard before committing.

Every call/guard checks actual Store/setup/selected-worker liveness, in addition
to monitors; delayed monitor delivery cannot keep an approval live. Periodic
cleanup and calls check monotonic and raw wall deadlines, backwards time and
elapsed-clock disagreement over 250 ms. These extra refusals bound suspension
and clock changes, supplying no clock qualification. Expiry, cancellation,
review restart or setup/Store owner loss discard the window/verifier. An
unapproved worker's loss drops its pending entry; loss of the selected worker
closes the review as locally uncertain. That reason makes no durable commit
claim. A restarted Store gets a different boot scope and requires a new review
owner and fresh invitation. Standard OTP status replaces state and message with
fixed private/redacted values.

## Evidence boundary

The independently authored Python positional-array and SHA-256 corpus is
checked in at `test/fixtures/controller_connections/review_vectors.json`.
Elixir checks exact encoding, digest coverage, limits, alternate encodings,
missing/extra fields, malformed private encoder terms and secret rejection.
Live process/actual SQLite Authority tests cover current scope, absent/different
owners, exact access/originals, pending/candidate/backoff limits, concurrent
offers, one checkout, denial, cancellation, actual expiry, clock refusal,
restart and synchronous liveness despite delayed monitor delivery. Read-only
scope and review leave principal/target/journal counts and Store revisions
unchanged. Private state, pending summaries and OTP status exclude raw secrets.
These tests establish transient review and its composition only. The separate
consumption annex records durable commit/rollback and lost-delivery evidence.
Host wiring, ordinary TLS Authority parity and installed private transfer remain
required under H15-T8.
