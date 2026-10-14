# Native authoring submission and original recovery

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 H08-09/H08-T9; WOH.18 H18-T13/T14/T16/T17/T18;
WOH.15 H15-03. Implementation: planned. Evidence: missing.

## Result and prerequisites

A closed local native SDK submits the unchanged complete import/candidate/review
original and resolves its exact actor-scoped receipt. The shared original-purpose
runner can look up or retry a published [v6 journal entry](native-pending-custody-v6.md).
Complete publication precedes mutation; lost replies retain the same original.
This entry owns SDK transfer and recovery correspondence. First-decision panel
and selected publication require their separately specified composition; no
unpublished editable input may be substituted into a recovery entry.

[Authoring operators](authoring-operators-v1.md) owns routes, current permission,
Store CAS, quotas, byte custody and upload state. [Native originals](native-authoring-originals-v1.md)
owns canonical originals. [Native reads](native-authoring-reads-v1.md) owns strict
receipt decoding. Imports/candidates/reviews remain inert and confer no approval,
selection, provider export, runtime admission or control. Paired authoring custody
remains unavailable; preserve older paired recovery without local fallback.

## Closed SDK and transfer

**NM-01 — Preserve the complete original.** Accept only a revalidated native
original and, for import, its verified exact payload. Candidate/review require
null payload. Revalidate canonical bytes, metadata and import WOHA frame before
any transport; no mutable fields, epoch/ID/CAS edits, contract/reader substitution
or automatic provider attempt. Keep private peer/custody checks, api_version 1,
65536-byte request and 1048576-byte response bounds and five-second exchanges.

Lookup invokes the owning original-status route under the original epoch/ID.
Retry first probes import/review with null upload/input ref; an exact retained
receipt resolves without upload access. An absent original permits a new explicit
transient transfer using a fresh `upload:` plus lower hex32 random ID; durable
epoch/ID remain unchanged. Candidate retry forwards exact native fields directly.
Only authoring_upload_required permits import/review transfer; other refusals
propagate unchanged. Status/read/probe never performs a mutation.

Use purpose import_payload for raw bytes and review_original for canonical review
bytes, exact declared length/raw SHA and 32768-byte chunks except final remainder.
Strictly decode the exact nine-field upload metadata from the operator owner,
matching ID/purpose/length/SHA, lower hex32 owner, bounded integer cursor and
remaining_ms 0..60000. Begin must be uploading at offset zero. Lost begin reply
reads that same ID's status once. Lost chunk reply reads status once: same owner
and previous cursor/uploading permit one exact retry; expected advanced cursor
and uploading/ready permit continuation. Changed owner, terminal state, metadata
or unexpected cursor refuses without silent reupload or deadline renewal.

Only a complete ready ref reaches import/review. Final request uses unchanged
input or exact original header/SHA. Definite result/refusal may best-effort cancel
that transfer; cleanup failure cannot replace a verified durable result. Lost/
malformed final reply or outcome_unknown retains uncertainty and performs no
rollback claim or automatic retry. Expose a typed outcomeUnknown for final
delivery uncertainty; transfer/probe failures remain ordinary errors.

## Receipt correspondence and journal recovery

**NM-02 — Resolve only matching history.** Every result uses the strict read SDK
shape and must match kind/epoch/operation. Import receipt's complete object summary
equals the original; revision equals expected_revision+1 and first_revision is
positive and ≤ revision. Candidate/review receipt input_sha256 equals canonical
original SHA and revision equals expected_revision+1. Review candidate_revision
equals its complete candidate reference revision. Overflowed next revision cannot
match a result. Preserve independent source/consumption/fixture/proposal outcomes;
a compatible candidate or complete review cannot become approval.

Original-purpose recovery accepts only pending authoring entries with existing
local manual/native Operator custody, exact verifier and authenticated original
controller/principal. Use the coordinator's existing capture/publication/reload
and whole-file CAS rules. Lookup missing retains the original; exact matching
lookup/retry can resolve it. Refused, malformed, uncertain, changed-custody or
changed-controller results retain it. No cancellation action exists for a durable
authoring original, and transient upload cancellation cannot remove its history.
Paired authoring recovery refuses before transport. Native UI enables only the
implemented local lookup/retry actions and labels results as inert originals.

## Acceptance

| Case | Requirement | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NM-T1 | 01/02 | Independent framed peer: candidate, full binary import, large canonical review, exact original replay without uploads, closed refs/metadata and receipt joins. Changed bytes/ID/CAS or implicit approval fails. | Native software |
| NM-T2 | 01 | Lost begin/chunk before/after retain, owner/cursor/TTL/refusal, lost/malformed committed reply and cleanup failure. Silent new durable ID, renewed deadline, repeated uncertain commit or false rollback fails. | Native software |
| NM-T3 | 02 | Actual Store/archive and separate client processes: v6 publication observed before mutation, lost replies, exact status/retry, restart, failed publication/reload, revoked permission, changed original/result. Premature dispatch/removal or another revision fails. | Native/Store software |

Record actual compiler/commands/inputs and limits. Signed paired first submission,
installed publication/disk survival, producer dependency adoption, provider export
and physical qualification remain separate obligations.
