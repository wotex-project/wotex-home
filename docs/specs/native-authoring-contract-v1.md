# Selected-session native authoring contract reads

Version: 0.1.5. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-T1/T2/T5, WOH.15 H15-T1 and WOH.18 H18-T13/T16.
Implementation: bounded native decoder, immutable contract value and selected
driver read implemented. Evidence: [executed peer/local scope and actual Store checks](../provenance/native-authoring-contract-2026-10.md).
The [mapping editor](native-mapping-editor-v1.md) now consumes these verified
bytes through a separately fenced local context and records its own UI evidence.
New export through installed paired delivery and installed host/physical
qualification remain separate evidence obligations.

## Result and dependencies

The native selected controller can explicitly read the installed authoring
contract before constructing a manual draft original. The
[authenticated export](authoring-contract-export-v1.md) owns Store authorization,
exact document and summary. The selected-session driver owns current local
credential capture or sealed paired session, controller association generation,
before/after identity and delayed-result retirement. This read publishes no
pending original or file, imports no bytes and admits no profile.

## Checked client value

**NC-01.** Add a native contract client for exactly authoring_contract_export
with no request fields beyond the existing api_version/operation/credential
wrapper. Credential is exactly 32 bytes and stays inside the selected transport.
Decode the exact success wrapper and six-field export body from the owning
contract. Reject not_found, unknown fields, malformed typed metadata and all
server errors as their current typed outcomes. Epoch is positive signed-64,
revision nonnegative signed-64 and principal is a Home ID; bool/float aliases
are rejected even when Foundation compares them equal to an integer.

Summary contains exactly its eight owning fields, format
wotex-home.authoring-contract@1 and consumption policy
wotex-home.read-only-profile@1. Its three summary SHA fields (contract_sha256,
contract_raw_sha256 and basis_sha256) are lower hex64.
Producer has either the exact three archive fields or the exact tagged five
runtime fields under installed-profile-runtime-v1. The
[producer succession contract](mqtt-producer-cohort-v1.md) requires canonical
lower-hex40 revision syntax, preserving older recorded/controller revisions
without comparing them to the client build. Current installed-code equality is
a controller guard; native syntax acceptance creates no installation authority. Home contract references are a proper sorted
unique list of at most 32 exact id/version/sha256 records, using the existing
closed native external-reference grammar. No URL or named reference is fetched.
Limits contain exactly reader and the four existing authoring limit fields;
positive integer ceilings are reader bytes 262144, depth eight, nodes 4096,
channels/definitions/bindings/dependencies 32, numeric digits 64; bundle bytes
262144, diagnostics 64, report bytes 24576 and check steps 1000000. No missing
limit or unknown field gets a default.

Contract_base64 is unpadded URL-safe Base64 at most 349526 ASCII bytes. Decode
nonempty UTF-8 bytes at most 262144 and require exact re-encoding. Scan strict
JSON before Foundation decoding, rejecting duplicate decoded keys, container depth above
32 (root container counts one), more than 50000 nodes, collections above 4096 and strings/keys above 16384
UTF-8 bytes. Contract is an object with exactly format, producer, schemas,
semantic_rules, bindings, contracts and limits, format
wotex.profile.authoring-contract@1. Bindings is a list at most 32, contracts
is at most 32 closed references, and document limits equal the independently
checked summary limits by exact integer values/field sets. Producer/schemas/
semantic_rules and binding bodies remain bounded opaque WPF grammar data;
the native client implements no schema validator or semantic compiler. These
decoded-document limits match the inspected producer envelope bounds; ordinary
response scanning retains its default 16-container/256-member bounds. Only this
explicit decoded contract scan opts into the larger document limits.

Compute full SHA-256 of exact decoded bytes and compare contract_raw_sha256.
Compute SHA-256 of UTF-8 wotex.profile.authoring-contract@1 followed by newline
and those exact bytes and compare contract_sha256. Preserve raw bytes without
reserialization or Unicode normalization. basis_sha256 remains the authenticated
Store's complete producer/Home-policy assertion; the native client checks its
representation and preserves it rather than claiming an independent producer
export/reconstruction. It confers no current admission or physical proof.

Return an immutable Sendable value exposing epoch, principal, revision, contract
identity, raw identity, basis identity and typed limits for later preparation.
Raw contract bytes remain private value custody; reflection omits them and no
automatic file/stdout/log publication occurs. Native values cannot be fabricated
through a public unchecked initializer. Invalid response refuses invalidResponse
before returning a preparation basis; malformed caller input refuses
invalidProfileRequest before transport.

## Selected session and drift

**NC-02.** Add one explicit driver read using its existing shared busy/reload/
association-generation guard. Local selection captures one current credential
and pins that same native reference before/after transport. Remote selection
uses only its currently selected sealed session, runs through its credential
lease and repeats current/delivery guards. There is no local fallback.
Compare before/after controller owner/principal/epoch/installation identity;
export principal/epoch must match. Require before revision <= export revision
<= after revision. Regressing watermark, replacement/revocation, changed
selection generation, invalidated local metadata or retired paired lease must
discard the complete result. Historical receipts are not changed or resolved.
The read returns no payload if the selected session becomes stale before delivery.

No view mounts/focus/wake/session reload automatically invokes this read. A later
explicit draft-preparation flow may consume it and must acquire a fresh basis
at its own confirmation/publication boundary. Export is not a reservation;
retries may return different current metadata. Timeout is read transport failure,
never mutation outcome_unknown. No pending custody schema or journal changes.

## Acceptance

| Case | Requirements | Setup and falsifier | Level |
| --- | --- | --- | --- |
| NC-T1 | 01 | Independent peers deliver two real frozen WPF grammar documents with separately calculated raw/domain hashes, both producer shapes and narrowed limits. Malformed fields/Base64/UTF-8/duplicate keys/types/bounds/hash/limits and not_found refuse. Reserialization, schema evaluation or discarded producer assertion fails. | Native private peer |
| NC-T2 | 02 | Selected local/paired before/after identity, scope and watermark changes; delayed association-generation and delivery invalidation. Credential recapture/fallback or stale result delivery fails. | Selected native fixtures |
| NC-T3 | 01/02 | Live authenticated export from actual Store for both independent families matches Swift decoded bytes and typed basis; no revision or file publication. Signed installation, physical qualification and ergonomic draft UI remain unclaimed. | Actual Store/native software |

Use owning native host compile/fixture closures for the new source. Add new
source explicitly to each affected fixture/package list; a forgotten closure
must fail compilation rather than silently test old code. Full artifact/signing,
manual draft construction and installed protocol publishers remain separate.
