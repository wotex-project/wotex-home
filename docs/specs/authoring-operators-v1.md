# Typed authoring import, candidate and review operators

Version: 0.1.1. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-T13/T14/T16/T17/T18; WOH.15 H15-03.
Implementation: planned. Evidence: missing.

## Result and ownership

Private socket and CLI operators can import every supported authoring-object
size, read their own immutable bytes, explicitly assess a manual candidate,
record source/complete review and recover each original receipt. Authority
forwards the unchanged original to the single Store. Imports/candidates/reviews
remain inert: none approves a profile, installs a host meaning/source, selects
a Thing, grants access, records a report or enables control.

[Authoring](profile-authoring-v1.md) owns schema 29 input, byte ownership and
passages; [candidates](authoring-candidates-v1.md) owns schema 30 mechanics and
host-selected contract; [reviews](authoring-reviews-v1.md) owns schema 31 source/
fixture correspondence. Current profile:manage and actor-scoped original lookup
precede new work. New durable work requires current epoch/revision, active
controller outside maintenance, owned handles, exact host contract/reader and
existing quotas. Status never renews bytes, producer availability or approval.

## Closed private requests

Keep api_version 1, canonical 32-byte bearer encoding, request ceiling 65536,
response ceiling 1048576, strict duplicate/depth rejection, private 0700 parent,
0600 socket and same-user peer. Every wrapper has exactly api_version, operation,
credential and its listed fields. Unknown fields/versions refuse
unsupported_operation_or_fields. Native codecs own originals; adapters add no
defaults, actor identifiers, host contract/reader or provider selection.

| Operation | Additional fields | Successful response member |
| --- | --- | --- |
| authoring_upload_begin | upload | authoring_upload |
| authoring_upload_chunk | upload_ref, offset, chunk_base64 | authoring_upload |
| authoring_upload_status | upload_id | authoring_upload |
| authoring_upload_cancel | upload_ref | authoring_upload |
| authoring_object_import | input, upload_ref | authoring_object_receipt |
| authoring_object_status | authority_epoch, operation_id | authoring_object_receipt |
| authoring_object_read | object_digest | authoring_object |
| authoring_source_passages | selectors | authoring_passages |
| authoring_candidate_assess | input | authoring_candidate_receipt |
| authoring_candidate_status | authority_epoch, operation_id | authoring_candidate_receipt |
| authoring_candidate_review | authority_epoch, operation_id, input_sha256, input_ref | authoring_review_receipt |
| authoring_review_status | authority_epoch, operation_id | authoring_review_receipt |

Import input is the exact four-field native AuthoringImport. Candidate input is
the exact four-field native AuthoringCandidate. Review input_ref is one completed
review_original upload containing exact canonical AuthoringReview bytes. Its
SHA must equal the declared input_sha256 and its decoded epoch/ID must equal the
wrapper; the decoder changes no original fields. Import upload_ref and review
input_ref may be null for an original-only probe: an exact retained original
returns its receipt, a changed identity conflicts, and absent original returns
authoring_upload_required without new work. These probes are reads for transport
failure classification. Status epoch
is positive signed-64 and operation ID a Home ID of 1..128 bytes. Object digest
is lower hex64. Selectors retain their owning sorted/count/range grammar.

Success is exactly api_version, outcome ok and the named member. Status/missing
owner object is outcome not_found. Refusal is outcome error/reason string.
Object read returns exactly object (four-field summary), first_revision and
payload_base64 (canonical unpadded URL-safe original bytes). Responses never
include credential, private path, full tagged frame or another actor's bytes.
Passages preserve their exact owning text/offset/hash records. Private operator
read access does not authorize exporting these bytes to an AI/provider.

## Bounded transient upload custody

**AO-01 — Preserve complete bytes.** AuthoringUpload is a native process owned
by the private server's Store lifetime; Authority can instead receive an explicit
configured owner. Direct Authority defaults to unavailable. Server starts one
private owner when none is supplied and stops it with the endpoint/Store. It has
no Store connection or bearer and is not another durable writer. All public
operations first obtain current profile:manage principal/current active epoch
from Store in one authenticated call; only Authority supplies that native scope.
Quarantine, retired/fenced Store or revoked permission refuse before owner access.

Upload is exactly upload_id, purpose, payload_bytes and payload_sha256. ID is a
Home ID; purpose is import_payload (1..262144 bytes) or review_original
(1..131072 bytes); digest is SHA-256 of those exact bytes, lower hex64. No
decoding/normalization occurs during assembly. Namespace is current principal,
authority epoch and upload ID; changed metadata conflicts. Owner has a random
lower hex32 incarnation. Upload_ref is exactly owner_epoch and upload_id. An
old incarnation, another principal/epoch or unknown ID cannot borrow bytes.

Chunks are exactly 32768 bytes except the final remaining chunk, with canonical
unpadded URL-safe base64 and offsets 0,32768,... . Offset is nonnegative integer
and must equal the next cursor. Exact lower-offset chunk replay returns the same
current cursor; changed bytes or a future/unaligned offset refuse without change.
The final chunk verifies complete original SHA before declaring ready; mismatch
invalidates the upload and releases its body. It creates no ownership/Store row.

Owner defaults: 16 body-bearing uploads, 4 MiB reserved declared body bytes,
1024 retained identities and 60000 ms nonrenewing monotonic lifetime. Trusted
options may only narrow these bounds; TTL is 100..60000 ms. Admission reserves
declared bytes before assembly. Metadata originals are not evicted or renewed.
States are uploading, ready, checked_out, consumed, cancelled, expired or invalid.
Status is exactly format home-authoring-upload-v1, owner_epoch, upload_id,
purpose, payload_bytes, payload_sha256, next_offset, state and remaining_ms.
It contains no body, principal or deadline instant. Exact begin/status/chunk
replay never restarts time. Capacity refuses authoring_upload_capacity.

| Event | Transition / outcome |
| --- | --- |
| Exact begin replay | Return current metadata, including terminal states; no allocation/renewal |
| Complete matching bytes | uploading → ready |
| Borrow for fixed purpose | ready → checked_out, bound to the Authority route caller PID |
| Finish a definite attempt | checked_out → consumed; body released |
| Cancel | uploading/ready → cancelled; terminal replay unchanged |
| Cancel during checkout | authoring_upload_checked_out; never claims rollback |
| Deadline / borrower death | Body released; expired/consumed metadata retained; an already sent Store call may still commit |
| Endpoint/Store/owner restart | All transient uploads disappear; old owner refs cannot revive them |

Only the checkout caller can finish its borrow. Definite refusal consumes that
checkout too. Deadline/caller loss cannot prove a Store call rolled back; durable
original status decides the import/review outcome. OTP process status and errors
must redact all payloads, credentials and private source fragments.

## Durable composition and recovery

**AO-02 — Use originals across uncertain delivery.** Import checks exact durable
original identity before upload access, so a completed import can replay without
its upload/owner/bytes. Changed original conflicts. New work authenticates again,
borrows only import_payload and invokes the existing Store import with the exact
input and bytes. Review resolves actor-scoped original status and exact input SHA before upload
access; fresh work borrows review_original, verifies/decodes its canonical original
and invokes the existing Store review. Original review status works without the
upload. All borrows finish on definite paths; SQL/worker/lost-reply uncertainty
never invents a new operation ID or producer attempt.

Object-import, candidate-assess and candidate-review are durable mutations.
Exchange retains the ordinary five-second deadline, classifies dispatch/worker
loss as outcome_unknown and kills its route worker without asserting rollback.
Upload failures are transient transfer errors, recovered by upload status/cursor;
they are not a claim about durable commit. Status/read/passages failure is a read
error. Current candidate/review may refuse host authoring_unavailable or
profiles_producer_unavailable; adapters never substitute a contract/validator.

**AO-03 — CLI preserves exact custody.** Commands are:

```
authoring-object-import ORIGINAL_FILE PAYLOAD_FILE
authoring-object-status EPOCH OPERATION_ID
authoring-object-read OBJECT_DIGEST ABSOLUTE_OUTPUT_FILE
authoring-source-passages SELECTORS_FILE
authoring-candidate-assess ORIGINAL_FILE
authoring-candidate-status EPOCH OPERATION_ID
authoring-candidate-review ORIGINAL_FILE
authoring-review-status EPOCH OPERATION_ID
```

Retain --socket and --credential-file private descriptor checks. Input paths are
absolute, at most 1024 bytes, checked private 0600 regular files. Import original
is at most 4096 bytes; candidate original at most 65536; review native JSON file
at most 262144, with its canonical encoder enforcing 131072; selectors at most
32768. Payload is nonempty and at most its owning kind ceiling. Strict bounded
JSON decode rejects duplicate/deep fields before the owning encoder. CLI resolves an original-only probe first, then computes/checks the exact payload
summary before new-byte transfer. A completed import can therefore replay after
its payload file disappears. CLI uploads fixed
chunks under a fresh explicit transfer ID and retains original durable epoch/ID.
It does not edit CAS or original fields to compensate for other writes.

Lost chunk reply reads its original upload status before another chunk; a changed
owner, terminal upload or wrong metadata refuses rather than reuploading silently.
Lost durable reply exits 3 and names the exact corresponding status command with
the original epoch/ID and same credential. No automatic new durable ID occurs.
Reads/transfers/refusals exit 1, syntax 2, successful mutation/read 0 and missing
original 4. Object read writes only the verified bytes to an exclusive new private
0600 output file; no overwrite, link following, normalization or payload logging.
It prints safe summary/path metadata, not source contents. Private output failure
is a local read error and cannot change Store ownership.

## Acceptance

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| AO-T1 | 01/03 | All payload kinds at owning limits, 32768/final chunks, wrong hash/base64/offset, exact replay, actor/epoch/owner substitution, quota/TTL/cancel/restart/borrower death. Extra allocation/time or private status bytes fails. | Process/software |
| AO-T2 | 02/03 | Actual Store/socket/CLI import, read and status for full 256-KiB binary and typed profile/definition objects; lost reply and exact replay after owner/byte loss. New revision, byte drift or actor leak fails. | Software |
| AO-T3 | 02/03 | Two independent quantities: manual candidate and source/complete review through socket/CLI equal Authority and original status. Changed contract/CAS/permissions/handles, missing producer and discarded replies. Implicit approval or new original fails. | Software/archive |
| AO-T4 | 01–03 | Strict file modes/links/JSON, exclusive output, closed framed fields, stopped Store, deadline and receipt recovery. Unsafe path, malformed original or uncertainty treated as success fails. | Software |

No schema or dependency pin changes are allocated. Native authoring/review panel,
accepted host source/meaning installation, provider export/handoff and installed/
physical qualification retain their separately specified delivery obligations.
