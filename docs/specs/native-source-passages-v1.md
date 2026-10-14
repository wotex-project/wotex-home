# Native bounded authoring source passages

Version: 0.1.1. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 H08-T1/T2/T5 and WOH.18 H18-09/H18-T13/T17.
Implementation: bounded SDK, selected local read and native history presentation implemented.
Evidence: [executed Store, peer and native checks](../provenance/native-source-passages-2026-10.md).

## Purpose and ownership

An author explicitly reads a byte range from an actor-owned immutable source
to inspect evidence before preparing a source review. The native interface
shows exact passage identity and inert text. Reading reserves no revision,
imports no data and grants no attribution, approval, selection or device effect.
This implements the existing local projection in
[profile authoring](profile-authoring-v1.md#explicit-bounded-source-passages)
and consumes Authority.authoring_source_passages/3 through its existing private
socket route. Store alone authenticates profile:manage, checks ownership and
leases verified source originals. No new producer API or schema is required.

## Closed inputs and outputs

The SDK takes a nonempty list of at most 32 selectors. Each has exactly
source_ref (lowercase 64-hex complete tagged source digest), offset (integer byte
index 0..262144) and length (integer bytes 1..4096). The list is strictly sorted
and unique by source_ref, offset, length; total selected length ≤131072 bytes.
Native typed construction and decoded responses must reject boolean/float,
overflow, missing/unknown fields, duplicates and invalid bounds. Validate the
whole input before credential or socket I/O. Different overlapping ranges are
allowed. No clipping, normalization, extraction, URI fetch or inferred selection.

The existing route returns either exact api_version=1/outcome=not_found or
api_version=1/outcome=ok/authoring_passages. Success contains exactly one record
per requested selector, in that order. Each record has exactly source_ref,
source_payload_sha256, first_revision, offset, length, passage_sha256 and text.
All digests are lowercase 64-hex; first_revision is a positive signed-64 integer.
The selector must equal the requested tuple. Text must be nonempty valid UTF-8,
have exactly length bytes and match passage_sha256 computed over those exact
bytes. Unicode control characters are refused except LF/tab. No full original,
credential, private path or selection authority is returned. The source payload
hash and historical revision are authenticated Store assertions; a passage
alone cannot reconstruct the full original digest. Preserve that distinction.

## Requirements and state transitions

**SP-01 — Bounded strict SDK.** Use only the existing read route and closed
selector fields. Strictly decode the complete response before returning any
passage, including cross-selector correspondence, lengths, hashes and metadata.
Partial, extra, duplicate, reordered or malformed records refuse the entire
read. Not-found returns no passages. Preserve existing typed server errors for
revocation, permission denial, invalid ranges, custody failure and limits.

**SP-02 — Selected local session.** Reject paired selection before credential,
file, socket or paired transport I/O; local source reading is not remote export
authorization. Capture one local credential, read identity before and after
projection and require the same deployment/owner/epoch/principal and current
installation/reference association. The final Store revision must not regress
and must be at least every historical first_revision. Recheck selected metadata
and session generation before delivery. A concurrent unrelated revision may
advance because the source bytes are immutable. Retired or revoked scope cannot
deliver prior text. No pending journal or operation ID is created.

**SP-03 — Explicit native presentation.** Extend authoring history with one
source digest and explicit offset/length fields and a Read Source Passage action.
Defaults are offset 0 and length 256; never clip a default to available bytes.
The form accepts canonical decimal integers only. Shared busy/access guards
apply. Construction, reload and input edits issue no read. On explicit read,
clear old results before starting; replace them only after complete verification.
Show digest, raw source hash, historical revision, byte interval, exact passage
hash and plain inert text. Text is never Markdown, a link, HTML, a command,
review evidence or a model instruction. Escape Unicode format-category scalars
as visible U+hex markers in the displayed text; hashes and byte lengths remain
those of the original unmodified passage. Do not export or copy text automatically.

**SP-04 — Retirement and failure.** Source/input, other history selector,
session/access replacement, sleep/wake and cancellation retire any late result.
Repeated busy actions produce one read. Failure/not-found clears prior passages;
no stale text survives refusal. Keep public metadata separate from transient
source text and exclude text from reflection/diagnostics. Source reading owns
no durable state. Lost replies may be read again explicitly; no mutation retry,
quota refund or recovery operation is implied.

## Acceptance

| Case | Requirements | Stimulus and independent observation | Level |
| --- | --- | --- | --- |
| SP-T1 | SP-01 | Exact route and independent UTF-8/hash vectors; malformed fields/types/order/length/hash/control/limits refuse; invalid input issues no request | Native SDK/peer |
| SP-T2 | SP-01/02 | Two real Store source families and overlapping byte ranges match independently sliced original bytes; another principal/wrong kind/split UTF-8/out-of-range/refused scope returns no text; reads change no revision | Software Store |
| SP-T3 | SP-02/04 | Identity/epoch/principal/reference or selected generation changes and regressing watermark refuse; advancing unrelated revision succeeds; paired selection performs no credential or paired request | Native peer/selection |
| SP-T4 | SP-03/04 | Delayed UI edits/session/wake/cancel retire delivery; busy-repeat one call; not-found/failure hides old text; format-control text is visibly escaped; inspect five existing viewport widths | Native model/render |

Evidence must record source/toolchain/fixtures, commands and actual results.
Software and synthetic peers do not establish installed signing/accessibility,
source authenticity, remote provider authorization or physical qualification.
