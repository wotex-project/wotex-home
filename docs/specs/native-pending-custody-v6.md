# Native pending authoring-original custody v6

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 H08-09/H08-T9; WOH.18 H18-T13/T16/T17;
WOH.15 H15-03. Implementation: planned. Evidence: missing.

## Result and inherited custody

Extend the actual [v5 journal](native-pending-custody-v5.md) to retain complete
[native authoring originals](native-authoring-originals-v1.md), including raw
import payload custody, before any later native mutation. This entry owns codec
and private fixed-file publication; the typed mutation/recovery runner and panel
require subsequent explicit delivery contracts. Publication alone sends no API
request and establishes no import, assessment, review, approval or control.

Retain the fixed per-account private pending file/lock, same-user ownership,
0700 nonlinked parent/0600 regular files, descriptor/content/revision/inode CAS,
canonical ordering, one category per deployment/owner/epoch, sixteen total entries
and existing context/custody meanings. Load/unchanged confirmation makes no write
or request. Unknown/corrupt/oversized versions refuse without resetting history.
Old v1..v5 input syntax and 65536-byte accepted roots remain unchanged.

## Exact root, record and byte bounds

The root is `["wotex-home.native-pending.v6",REVISION,ENTRIES]`. Revision is
positive S64, and the root is at most 8388608 bytes. The private pending reader's
outer byte allocation may reach this bound, but a recognized older root still
refuses above 65536 before parsing its entries. Depth four, array member count
32 and entry count sixteen stay unchanged. Sixteen maximum-sized imports with
complete originals/payloads fit this ceiling; no body is evicted to make room.

**NP6-01 — Retain the complete original.** The new authoring category input is
exactly `["authoring_operation",KIND,ORIGINAL_DOCUMENT,PAYLOAD]`, where KIND is
import/candidate/review and ORIGINAL_DOCUMENT is the complete canonical UTF-8
original string, independently revalidated by its owning native codec. It is
not a digest, path or receipt substitute. This v6-only string slot allows
131072 decoded UTF-8 bytes and canonical quote/backslash escaping. Actual
import/candidate/review ceilings remain 4096/32768/131072. All Unicode is preserved
byte-for-byte; no normalization or replacement-decoding is allowed. Other
ordinary strings retain 128 unescaped ASCII bytes; the existing schedule slot
retains its separate 8192-byte ASCII grammar.

PAYLOAD is null for candidate/review. For import it is canonical unpadded URL-safe
base64 of exact raw payload bytes, nonempty and at most 349526 ASCII bytes. This
separate v6-only slot permits no escapes or nonbase64 characters. Verify decoded
length/kind ceiling/payload SHA and the exact WOHA tagged frame SHA against the
original summary before encoding, decoding or publication. A changed kind, hash,
size, original or payload refuses; raw source/document bytes are not normalized.
Nothing stores a user path or uses a path to reconstruct a lost original.

The only phase is `["pending"]`. Original epoch must equal retained context
epoch. Local manual custody keeps the existing verifier/principal constraints.
Native custody requires Operator role and expected revision at least its creation
revision. Authoring under paired custody refuses in this first extension until
the paired authoring dispatch/original-purpose consumer is implemented; older
paired records remain valid and preserved. No credential, seal, account key,
clock sample, producer selection or current permission is recorded. These
payload-bearing values, entries and documents redact reflective/debug output.

## Publication, versioning and failure

**NP6-02 — Preserve old originals through CAS.** First authoring publication from
an older root upgrades to v6 once under the same whole-file CAS, advances revision
once and preserves every old entry/context/custody/input/phase/order. Concurrent
ordinary/authoring publishers have one winner; the stale writer cannot discard,
overwrite or upgrade another result. Exact retained-entry replay confirms its
same bytes without allocating another identity or incrementing file revision.
After resolution, empty and later ordinary publications retain v6. Old-root
reads and confirmations preserve their original version and bytes.

Invalid input, wrong context/role/phase, seventeenth entry or same-owner authoring
category conflict refuses before write. A failed/uncertain publication keeps the
complete original in memory and requires reload/CAS confirmation before a later
consumer may dispatch. Resolution removes only the exact confirmed entry and
cannot remove a newer original with its category. Import payloads remain private
while unresolved; resolution removes their journal custody with the original.
No timer, automatic retry, semantic review or packet handoff is introduced.

## Compatibility and delivery entry

The pure original codec is implemented in `1d1d53a`; typed authoring read SDK and
operator routes are implemented separately. The shared coordinator already
requires complete publication before dispatch and limits current originals.
This extension must expose a revalidated original/payload accessor for a later
runner. Existing local and paired recovery runners must explicitly refuse the
new category until their owning authoring implementation exists; a missing runner
cannot silently resolve or drop it. The panel must retain unresolved authoring
entries visibly without pretending that Retry is currently available.

The complete native mutation SDK, original lookup/retry correspondence, selected
first publication, provider export and installed signed delivery remain separate
entry obligations. No application schema or producer dependency pin changes.

## Acceptance

| Case | Requirement | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NP6-T1 | 01 | All three independent originals, full binary import, large UTF-8 review, exact SHA/byte preservation, wrong payload/hash/kind/epoch/role/phase, paired refusal and slot bounds. Changed bytes or widened old strings fail. | Native software |
| NP6-T2 | 01/02 | v1..v5 preservation, mixed originals, exact no-op, sixteen maximum imports and seventeenth refusal, old roots above 65536 and unknown versions. Eviction, silent reset or old-root enlargement fails. | Native software/private file |
| NP6-T3 | 02 | Actual private publication/resolution, stale full-file CAS, two independent processes racing ordinary and v6 publication, restart/load with no request, uncertain publication/reload, version retained when empty. Multiple winners, changed originals or an API request fails. | Native private-file software |

Full-file software fsync/CAS does not establish installed disk power-loss survival,
signed custody, authoring mutation success, producer availability or qualification.
