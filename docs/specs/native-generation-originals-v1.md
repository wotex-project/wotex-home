# Native complete generation originals and reservation receipts

Version: 0.1.1. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.18 H18A-02/04/05 and H18-T15/T16/T17; WOH.08 native delivery dependency.
Implementation: pure native codec implemented. Evidence: [executed independent byte and refusal cases](../provenance/native-generation-originals-2026-10.md).

## Result and ownership

Swift can retain and revalidate the complete canonical preparation or attempt
operation, including its exact input SHA and original revision. It can verify
the corresponding immutable reservation receipt before a later SDK resolves a
pending mutation. This pure dependency precedes pending-journal publication and
native dispatch; it reads no file/credential/source and starts no provider.

The implemented GenerationPreparation, GenerationInput and GenerationAttempt
codecs own the wire meaning. Store owns current actor, source custody, policy,
provider, authority epoch/CAS, deadline and attempt index. Valid native fields or
a checked reservation receipt establish representation correspondence only,
never current export permission, source review, candidate completion or an effect.

Existing native manual authoring originals and v1–v6 pending records keep their
exact encodings. The new value has its own generation kind, rather than adding
generation to the import/candidate/review enum. Pending publication requires an
explicit successor journal category/version before any native submission; the
codec cannot place these bytes in an older authoring or schedule slot.

## Closed native input and canonical arrays

HomeGenerationOriginalKind is preparation or attempt. A checked immutable
Sendable value retains kind, positive signed-64 epoch, 1–128-byte Home operation
ID, nonnegative signed-64 expected revision and complete canonical UTF-8 bytes.
IDs start alphanumeric and then contain alphanumeric/dot/underscore/colon/hyphen.
Input SHA is lower hex64 SHA-256 of those exact bytes. Native map export must
reconstruct all metadata from the bytes before use. Reflective/debug output
exposes only kind/epoch/operation, never instruction, source references or bytes.

Native JSON is bounded before parsing: preparation 1–131072 bytes, attempt
1–8192. The existing duplicate/depth-16 strict scanner runs before Foundation.
Canonical decode is bounded to preparation 1–32768 bytes, attempt 1–2048 and
requires exact re-encoding. Reject unknown/missing fields, duplicate members,
invalid UTF-8, native scalar aliases, boolean/float/overflow integer slots,
noncanonical escapes/spacing/order/numbers and trailing members. No normalization,
source interpretation, provider lookup or producer validation is performed.

**NGO-01 — Preserve complete preparation.** Native fields are exactly
authority_epoch,operation_id,expected_revision,provider_sha256,policy_sha256,
remote_export,projection,budget. Digests are lower hex64 and remote_export is an
actual boolean. Canonical bytes are exactly:

```
["wotex-home.generation-preparation.v1",
 [EPOCH,ID,REV,PROVIDER_SHA,POLICY_SHA,REMOTE_EXPORT,
  [CONTRACT_SHA,INSTRUCTION,PASSAGES,EXAMPLES,LIMITS],
  [ATTEMPTS,ATTEMPT_MS,TOTAL_MS]]]
```

Projection has exactly contract_digest,instruction,passages,examples,limits.
Instruction is UTF-8 0–4096 bytes; Unicode Cc is forbidden except LF and tab.
Passages have 0–32 records exactly reference,offset,length. Reference is exactly
object_digest and first_revision (lower hex64 and positive signed-64); offset is
integer 0–262144, length integer 1–4096. Canonical passage slots are
[digest,first_revision,offset,length], strictly increasing and unique by
(digest,offset,length). Examples are 0–32 exact references, canonical
[digest,first_revision], strictly increasing and unique by digest. All occurrences
of the same digest across both lists require the same first revision. These
are selected handles/ranges, not evidence of ownership or source truth.

Limits has exactly max_passages,max_passage_bytes,max_passages_bytes,max_examples,
max_examples_bytes,max_input_bytes. Every value is a positive integer; ceilings
and canonical order are respectively 32,4096,131072,32,262144,1048576. Counts
must fit selected max_passages/max_examples; each length and sum of lengths fit
selected passage-byte ceilings. Do not infer actual example/input byte size from
references; Store/custody must verify those bytes. Budget has exactly attempts
(1–3), attempt_ms (1–30000), total_ms (1–120000), with attempt_ms <= total_ms.
It selects bounds without starting or renewing any clock.

**NGO-02 — Preserve explicit attempt and repair.** Native fields are exactly
authority_epoch,operation_id,expected_revision,preparation_operation_id,
preparation_sha256,attempt,previous_operation_id,repair_export. The preparation
and predecessor IDs use the same Home grammar; SHA is lower hex64. Canonical
bytes are exactly:

```
["wotex-home.generation-attempt.v1",
 [EPOCH,ID,REV,PREPARATION_ID,PREPARATION_INPUT_SHA,
  ATTEMPT,PREVIOUS_ID_OR_NULL,REPAIR_EXPORT]]
```

Attempt is integer 1–3. Attempt one requires null previous ID and false repair
export. Attempts two/three require a valid previous ID and true repair export.
This representation names explicit feedback consent; it does not manufacture
the predecessor's invalid draft/report or authorize automatic repair. Store
checks the retained predecessor, original budget/deadline and current policy.

## Immutable receipt correspondence

**NGO-03 — Verify a reservation, not completion.** Preparation receipt is exactly
authority_epoch,operation_id,revision,input_sha256,projection_sha256,basis_sha256,
provider_sha256,policy_sha256,disposition prepared. Attempt receipt is exactly
authority_epoch,operation_id,revision,input_sha256,preparation_sha256,attempt,
handoff_sha256,provider_sha256,disposition handoff_reserved. Epoch/revision are
positive signed-64, IDs/digests use the input grammar, and attempt is 1–3.
The canonical receipt array preserves the listed field order, at most 2048 bytes.

A mutation receipt must match original kind, epoch/ID, expected_revision+1
without overflow and input SHA. Preparation additionally matches the exact
provider/policy SHA; attempt matches preparation SHA and attempt index. Other
hashes are checked metadata assertions. A typed reply is neither current model
readiness nor a completed draft. No receipt decode can authorize another attempt,
change an original, discard uncertainty or fabricate a settled assessment.

Invalid input/receipt throws the existing native invalidProfileRequest or
invalidResponse family without private fragments. No file publication, replay,
timer, provider or cancellation operation exists in this codec. Historical
decode/revalidation needs no loaded WPF producer or source bytes.

## Acceptance and next entry conditions

Before code, allocate independent native/canonical/receipt/SHA cases in Python
from the already frozen two-family preparation and attempt vectors. The Elixir
owner can cross-check those frozen bytes but cannot replace the independent
oracle by computing expectations with the Swift implementation.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NGO-T1 | 01–03 | Both families' exact native/canonical originals, receipt arrays/SHA, maximum signed-64 values and private Unicode/control escaping; any drift/coercion/private reflection fails. | Pure native |
| NGO-T2 | 01/02 | Unknown/missing/duplicate/bool/float/overflow, invalid IDs/digests, order/duplicates/reference inconsistency, counts, instruction controls, every narrowed limit and contradictory initial/repair shape; accepted malformed value fails. | Pure native |
| NGO-T3 | 01–03 | Inclusive native byte ceilings, over-limit native/canonical input, altered canonical metadata, wrong receipt identity/hash/revision/provider/policy/attempt and overflow next revision; parse before bounds or false success fails. | Pure native |

Native v7 pending custody must name its exact category/slot/version/CAS and retain
these complete originals before SDK mutation. The SDK must keep preparation
availability, running/unknown attempt and settled result separate, repeat selected
controller/custody checks, and classify lost mutation replies as outcome unknown.
Those next contracts must define status/options/cancellation and durable result
joins, rather than inferring them from a reservation. Pure codec evidence is not
native submission, installed signing, actual model, OS confinement or physical
qualification. No ExBooking or WoTEx API change is required for this consumer wire.
