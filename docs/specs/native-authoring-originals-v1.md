# Native complete authoring-original codec

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-T13/T14/T16/T17; WOH.08 native mutation/custody dependency;
WOH.15 H15-03. Implementation: planned. Evidence: missing.

## Purpose and ownership

Swift can retain and revalidate complete immutable import, manual candidate and
source/complete-review originals, including their exact canonical SHA. This pure
codec precedes native mutation and pending custody; it sends no request, opens
no credential/file, stages no bytes and creates no approval. The original field
semantics remain owned by Home's implemented AuthoringImport, AuthoringCandidate
and AuthoringReview codecs. A native JSON object is a local input representation;
only its exact ordered-array canonical original is a retained identity.

## Closed inputs and ordered encoding

Each native object has exactly authority_epoch, operation_id, expected_revision
and object (import), request (candidate) or review (review). Epoch is positive
S64; revision is 0..S64max; operation ID is 1..128 ASCII bytes, first alphanumeric,
then alphanumeric/dot/underscore/colon/hyphen. Boolean, fractional/overflow,
unknown fields, null substitutes, duplicate JSON and malformed UTF-8 refuse.
Bound native JSON before parsing to 4096/65536/262144 bytes respectively, with
the shared strict duplicate/depth-16 scanner. Bound canonical originals to
4096/32768/131072 bytes before parsing. Canonical decode also reencodes and
requires byte equality: no whitespace, object keys, alternative escapes,
numeric spellings or trailing members are retained.

**NO-01 — Match the owning arrays.** The exact canonical roots are:

```
["wotex-home.authoring-import.v1",[EPOCH,ID,REV,[KIND,OBJECT_SHA,PAYLOAD_SHA,SIZE]]]
["wotex-home.authoring-candidate.v1",[EPOCH,ID,REV,
  ["manual",CONTRACT_SHA,[DRAFT_SHA,FIRST_REV],SOURCES,FIXTURES,INSTRUCTION,
    [[MAX_BYTES,MAX_DEPTH,MAX_NODES,MAX_CHANNELS,MAX_DEFINITIONS,MAX_BINDINGS,
      MAX_DEPENDENCIES,MAX_NUMERIC_DIGITS],MAX_BUNDLE_BYTES,MAX_DIAGNOSTICS,
      MAX_REPORT_BYTES,MAX_CHECK_STEPS]]]]
["wotex-home.authoring-review.v1",[EPOCH,ID,REV,
  [MODE,[CANDIDATE_EPOCH,CANDIDATE_ID,CANDIDATE_REV,INPUT_SHA,ASSESSMENT_SHA],
    [[INSTANCE_PATH,SOURCE_SHA,LOCATOR],...],UNRESOLVED,ENVELOPE]]]
```

Arrays preserve this order. Canonical JSON emits exact decimal integers,
unescaped slash, UTF-8 Unicode and standard JSON quote/backslash/control escapes.
No numeric conversion, normalization or producer finalization occurs. Digest
strings are lower hex64. Object summaries have exactly kind, object_digest,
payload_sha256 and payload_bytes. Kinds and byte ceilings are source/draft/
bundle/contract 1..262144 and fixture/envelope/profile/definition 1..65536.
The summary validates metadata only; raw payload correspondence remains the
separate object/import owner.

Candidate request has exactly mode, contract_digest, base_draft_ref, source_refs,
fixture_refs, instruction and limits. Mode is manual. Each handle is exactly
object_digest and first_revision positive S64 and encodes [digest,first]. Source
and fixture lists each contain 0..32 handles strictly ascending by digest with
no duplicates. Instruction is UTF-8, 0..4096 bytes, no Unicode Cc except newline
and tab. Limits has exactly reader plus the four authoring fields above; reader
has exactly the eight fields above. Every limit is positive integer, with
ceilings respectively 262144/8/4096/32/32/32/32/64 and
262144/64/24576/1000000. This validates caller input without claiming that it
equals the current host contract; Store remains the current-basis authority.

Review has exactly mode, candidate_ref, evidence, unresolved_paths and
envelope_ref. Candidate reference has exactly authority_epoch, operation_id,
revision, input_sha256 and assessment_sha256; epoch/revision positive S64 and
ID/digests use the same grammar. Mode source requires null envelope; mode
complete requires an owned-handle-shaped envelope encoding [digest,first].
Evidence has 0..256 exact instance_path/source_ref/locator objects, strictly
ascending and unique by the tuple (instance_path,source_ref,locator). Locator
is nonempty UTF-8 at most 256 bytes with no Unicode Cc/Cf. Unresolved has 0..64
strictly ascending unique root strings. Allowed roots are exactly:

```
/profile/binding
/profile/fingerprint/N
/profile/channels/N/selector
/profile/channels/N/semantic
/profile/channels/N/invalid_values
/profile/channels/N/conversion
/definitions/N/unit
/definitions/N/value_schema
```

N is canonical decimal 0..31. No other path, leading zero or prefix expansion is
accepted. Encoding does not infer source truth, fixture success or complete
proposal from these references.

## Values, failures and compatibility

**NO-02 — Preserve complete identity.** An immutable Sendable value retains kind,
epoch, operation ID, expected revision and complete canonical bytes. Expose SHA-256
of those exact bytes and a revalidated native field map for the later transport.
Redact reflective/debug output to identity metadata; instructions/source locators
and original bytes are private. Revalidation must detect changed bytes or metadata
before a later consumer can use them. Invalid input returns the existing typed
invalidProfileRequest/invalidResponse family, with no source fragments in errors.

This pure codec has no retry, timer, capacity allocation or persisted migration.
Native mutation must publish a complete original through an explicitly specified
successor to the actual v5 pending journal before dispatch. The existing v5
65536-byte root and 8192-byte schedule slot do not admit these originals; neither
can be enlarged or bypassed merely because this codec accepts a larger review.
Raw object payload custody and import byte transfer remain separate requirements.
Existing schedule/profile/rule codecs and their accepted roots stay unchanged.

## Acceptance and entry

The owning Elixir codecs and their independent ordered-array vectors are already
implemented. Native implementation must use those byte vectors plus independent
boundary/adverse inputs before allocating a mutation/journal integration.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NO-T1 | 01/02 | Three independent canonical originals/native maps; encode/decode/hash and fields match exact owning bytes; UTF-8, quote/slash/tab/newline and maximum S64. Any byte drift/coercion fails. | Pure native software |
| NO-T2 | 01 | Unknown/missing fields, bad IDs/digests, float/bool/overflow, kind bounds, 33 handles, duplicate/unsorted lists, invalid controls/roots/mode/envelope and every narrowed limit ceiling. Any accepted malformed record fails. | Pure native software |
| NO-T3 | 01/02 | Maximum and one-over input/canonical budgets, 256/257 evidence, 64/65 unresolved entries, corrupted canonical bytes, forged metadata and private reflective output. Over-budget parse or private debug data fails. | Pure native software |

Pure success does not establish mutation publication, original receipt recovery,
host producer availability, approval, installed delivery or physical evidence.
