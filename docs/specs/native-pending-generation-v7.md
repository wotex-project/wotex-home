# Native pending generation-original custody v7

Version: 0.1.0. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-09/H08-T9; WOH.18 H18A-02/04/05 and H18-T15/T16/T17;
WOH.15 H15-03. Implementation: planned. Evidence: missing.

## Result and ownership

The shared private pending journal can retain a complete checked generation
preparation or attempt before a future native SDK submits it. Publication stores
the exact original, without calling a model, opening sources or granting export
permission. This successor owns representation and private publication only.
[Native generation originals](native-generation-originals-v1.md) owns complete
operation bytes and reservation correspondence; [generation operators](generation-operators-v1.md)
owns authenticated Store operations. Store owns current actor, policy, source
custody, CAS, deadlines, handoff and settled candidate outcomes.

Inherit the fixed per-account pending file/lock, same-user ownership, nonlinked
0700 parent and 0600 regular single-link files, descriptor/content/revision/inode
whole-file CAS and canonical ordering. Preserve all existing context/custody
meanings, sixteen total entries and one category per deployment/owner/epoch
regardless of principal. Loading and unchanged confirmation send no request and
make no write. Unknown/corrupt roots refuse without deleting or resetting history.

## Exact representation and bounds

**NP7-01 — Retain complete generation.** The root is exactly
`["wotex-home.native-pending.v7",REVISION,ENTRIES]`. Revision is positive signed-64;
the root is at most 8388608 bytes. Entries retain the five fields category,
context, custody, input and phase in their existing order. The new category is
`generation`, with input exactly
`["generation_operation",KIND,ORIGINAL_DOCUMENT]`. KIND is `preparation` or
`attempt`; ORIGINAL_DOCUMENT is the complete canonical UTF-8 string from the
owning checked codec, at most 32768 or 2048 decoded UTF-8 bytes respectively.
No raw source payload, private path, credential, receipt or current permission
is substituted for this string. The accessor revalidates bytes and metadata
before returning the immutable original.

The bounded scanner permits at most 32768 decoded UTF-8 bytes in this v7-only
document slot, and only after the exact generation action marker. Preserve
UTF-8 and canonical quote/backslash escaping byte-for-byte; no normalization,
replacement decode, escaped Unicode alias or raw JSON control character.
Outer scanner depth four and array count 32 stay unchanged. Ordinary strings
retain 128 unescaped ASCII bytes, the schedule document retains 8192 ASCII bytes,
and authoring document/payload slots retain their separate v6 bounds. Slot
allowances cannot leak between neighboring entries or unrelated input markers.

The only phase is `["pending"]`. Original epoch equals context epoch. Manual
custody requires its existing valid principal and lower-hex verifier. Native
custody requires Operator role and expected revision at least the positive
creation revision. Paired custody refuses until its separate generation consumer
exists; older paired entries remain valid. Values, entries and documents redact
reflection rather than displaying instructions or source references.

## Publication, retry and recovery

**NP7-02 — Preserve history through one CAS.** Reading or confirming v1–v6
retains its version and exact bytes. Roots v1–v5 retain their 65536-byte ceiling;
v6 retains 8388608 and cannot contain generation. First generation publication
upgrades any supported older root to v7, advances journal revision once and
preserves every unrelated original/context/custody/phase. v7 remains v7 after
resolution, an empty journal and subsequent ordinary publications. Concurrent
generation/ordinary or generation/authoring publishers have one CAS winner;
a stale writer cannot upgrade, overwrite or remove that winner.

Exact retained-entry replay confirms existing bytes without incrementing revision.
A same-owner generation category conflict, seventeenth entry, invalid original,
wrong epoch/role/phase or old-root generation refuses before a write. Preparation
and attempt share this category; the caller resolves an exact mutation original
before retaining another. No eviction or silent new operation ID/CAS is allowed.
Resolution removes only the exact retained entry and cannot remove a newer
original occupying that category. Missing/unsafe files and publication uncertainty
use the existing unavailable/conflict/capacity/invalidRecord/outcomeUnknown
families without private fragments. Uncertain publication retains complete memory
and requires explicit reload/CAS confirmation before any later submission.

**NP7-03 — Refuse premature dispatch.** Until the typed generation SDK and
original-purpose runner exist, every recovery action on this category refuses
before credential lookup or transport. The panel displays the retained kind and
pending status with recovery unavailable. No mutation button or automatic timer
is introduced. The low-level accessor is available to the future consumer.
Cancellation of a Store preparation is a separate authenticated use case;
`cancelReview` cannot cancel or discard generation.

The later SDK contract must distinguish confirmation of this pending mutation
from a running/unknown attempt and a settled draft. A handoff reservation can
confirm that an attempt was recorded; it cannot claim candidate completion.
Options, settled assessment joins, cancellation and post-reservation model-status
tracking require explicit contracts before enabling native dispatch. Journal
publication creates no Store record and no durable model-running reference.

## Compatibility and implementation entry

No application schema, dependency or sibling API changes. Existing v1–v6 roots,
manual authoring payloads and local/paired recovery behavior retain exact syntax.
Frozen generation originals are already independently allocated and checked.
Before code, allocate an independent v7 root oracle in Python from those bytes,
including Unicode escaping, both kinds and mixed retained entries. Do not compute
valid journal expectations with the Swift encoder under test.

## Acceptance

| Case | Requirements | Setup, expected observation and falsifier | Level |
| --- | --- | --- | --- |
| NP7-T1 | 01/03 | Independent v7 roots for every frozen generation original; native/manual custody, full/narrowed/Unicode, exact input SHA/accessor, wrong epoch/role/phase/paired and marker/slot bleed. Byte drift, private reflection or an enabled unimplemented recovery action fails. | Pure native software |
| NP7-T2 | 01/02 | v1–v6 preservation/upgrades, mixed authoring/schedule/ordinary entries, sixteen entries and seventeenth refusal, exact replay and old/unknown/corrupt/oversized roots. Eviction, widened old syntax or downgrade fails. | Native private-file software |
| NP7-T3 | 02/03 | Actual private retain/load/resolve, stale CAS, same-category/newer-original conflict and two independent processes racing generation against ordinary/authoring publication. One winner, unchanged old entries, version retained when empty; multiple winners, premature dispatch/removal or any request during load fails. | Native private-file software |

Retain source/toolchain/input identity, commands, results and limitations with
executed evidence. Software fsync/CAS and synthetic process restart do not
establish installed disk power-loss survival, signed account custody, actual
model behavior or physical qualification.
