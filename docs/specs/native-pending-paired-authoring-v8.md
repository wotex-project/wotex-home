# Native paired authoring and generation custody v8

Version: 0.1.2. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-09/H08-T9; WOH.15 H15-07/H15-T8;
WOH.18 H18A-02/04/05 and H18-T15/T16/T17.
Implementation: representation/private publication and mixed-version paired
correspondence implemented. Paired manual lookup/retry now has its fixed consumer;
paired generation remains disabled. Consumer evidence is recorded
[separately](../provenance/native-paired-authoring-consumer-2026-10.md). Foundation evidence: [executed foundation checks](../provenance/native-pending-paired-authoring-2026-10.md).

## Result and inherited boundary

The private pending journal can retain paired authoring and generation originals
without widening older wire formats or manufacturing signed custody. This entry
owns v8 representation, monotone upgrade and mixed-version paired publication
correspondence. [Authoring originals](native-authoring-originals-v1.md),
[generation originals](native-generation-originals-v1.md),
[v7](native-pending-generation-v7.md) and [v5](native-pending-custody-v5.md)
own unchanged input bytes and original custody. Actual signed submission belongs
to [paired composition](native-paired-authoring-generation-v1.md).

Use fixed native-pending-v1.json/.lock, same-user nonlinked 0700 parent and
0600 single-link regular files, descriptor/content/revision/inode whole-file CAS,
positive S64 revision, sixteen entries and existing canonical full-context/category
ordering. A category is unique by deployment/owner/epoch regardless of principal.
The coordinator additionally refuses a new original when any category occupies
that deployment/owner/epoch. Loading makes no write, capture, request or upgrade.

## Exact representation

**NP8-01.** Root is exactly
`["wotex-home.native-pending.v8",REVISION,ENTRIES]`, at most8388608 bytes.
Each entry remains `[CATEGORY,CONTEXT,CUSTODY,INPUT,PHASE]`. Context is exactly
`[DEPLOYMENT,OWNER,EPOCH,PRINCIPAL]`: lower hex64 deployment/owner, positive S64
epoch and 1–128 ASCII Home principal ID. Paired custody is exactly
`["paired",ASSOCIATION,CONTROLLER,CREATION_REVISION,VERIFIER]`; its three digests
are lower hex64 and creation revision positive S64. Principal is exactly
`paired-controller-v1:EPOCH:CLIENT`, canonical epoch spelling and lower hex64 client.
Original epoch equals context epoch; expected revision is at least creation revision.
These are custody references, not a credential, session, current grant or signing seal.

Authoring input remains exactly
`["authoring_operation",KIND,ORIGINAL_DOCUMENT,PAYLOAD_OR_NULL]`. Kind is
import/candidate/review. Complete canonical original is at most131072 decoded UTF-8
bytes; import payload is canonical unpadded base64url, at most349526 ASCII bytes
for at most262144 raw bytes. Only import has payload; the checked payload/frame
kind, size and SHA must match its original. Candidate/review require null.
Generation remains `["generation_operation",KIND,ORIGINAL_DOCUMENT]`, kind
preparation/attempt and complete owning canonical string at most32768/2048 decoded
UTF-8 bytes respectively. Both categories allow only `["pending"]` phase.
Revalidate owning originals, metadata and payload on encode, decode and access.

Other categories, custody and phases keep their existing grammar. Before tree
allocation preserve depth four, array members32 and ordinary unescaped ASCII
strings128. Only the exact authoring/generation marker and owning document slot
allow their larger UTF-8/quote-backslash escaped strings; payload remains bounded
unescaped ASCII. Schedule's8192 ASCII document allowance is unchanged. Canonical
re-encoding equals input bytes. Unknown versions/fields, scalar coercion, overflow,
wrong markers, slot bleed, wrong epoch/creation/payload, or capacity refuse without
reset, eviction or fragments. Values redact private reflection.

## Compatibility and transitions

**NP8-02.** v1–v7 preserve exact accepted grammar. In particular, v6/v7 cannot
contain paired authoring and v7 cannot contain paired generation. Accessor support
for a metadata value does not make that value legal under an older root marker.
First paired authoring/generation retain chooses v8 under one CAS, increments
revision once and preserves all other entries exactly. No-op confirms existing
bytes/version. Older supported roots without the new entries stay unchanged on
load or ordinary publication except their existing required upgrade. Retain v8
after resolution, an empty journal, phase changes and later local/ordinary writes.

**NP8-03.** Paired publication correspondence must use the actual required/retained
root version, not a v5 constant. First capture expects exactly the sorted prior
entries plus one entry, revision+1 and
`requiring(combined_entries, keeping: prior_version)`. Recovery retention expects
identical snapshot; review transition expects only its allowed phase replacement;
resolution expects only exact entry removal. Phase/removal preserve before version
for v5/v6/v7/v8. Full-content/inode/CAS, other-row and original-identity checks stay
unchanged. This also repairs existing paired ordinary recovery after a local
authoring/generation publication has upgraded its journal.

Uncertain publication remembers the exact original and requires reload; late
completion cannot clear memory or authorize dispatch. Never downgrade, edit an
original, replace its association or silently allocate another operation ID.

## Representation before consumer availability

**NP8-04.** Historical metadata decoding performs no Keychain, signing, clock or
transport work. Until the paired category's closed signed consumer exists, first
capture and every recovery action for it refuse before publication/credential/
transport. Ordinary local recovery never accepts paired custody. Native target
access remains broker-local. Enabling lookup/retry/confirmed acknowledgement is
a separate implementation step governed by the composition owner; v8 publication
alone proves no authorization, generation handoff or model completion.

No Store schema, dependency or sibling API change is required. Before code freeze
independent Python v8 roots using already frozen authoring/generation originals,
both kinds/families, Unicode, mixed old categories and S64/creation boundaries.
The native encoder under test cannot allocate its own valid expectations.

## Acceptance

| Case | Requirements | Stimulus / falsifier | Level |
| --- | --- | --- | --- |
| NP8-T1 | 01/02/04 | Independent paired import/candidate/review/preparation/attempt, exact bytes/hash, native/manual/mixed roots; wrong scalar/phase/custody/payload/old marker. Drift, widened old root, private reflection or premature consumer fails. | Native software |
| NP8-T2 | 02/03 | Actual old-root upgrade, exact no-op, full CAS, resolution/empty/local retain, restart and two-process ordinary/paired publishers. Multiple winners, lost row or downgrade fails. | Private file/process |
| NP8-T3 | 03/04 | Paired ordinary capture/review/cancel/resolve in v5 through v8, other entries preserved, substituted snapshots and unsigned category refusal before capture/network. v5-only assumptions, stale removal or fixture-created signing success fails. | Native/private file |

Focused representation/process checks do not prove installed signing, storage
power-loss or physical qualification. Record actual source, inputs, toolchain,
commands and limitations per completed dependency.
