# Native authoring data imports and candidate selections

Version: 0.1.1. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.08 H08-T1/T2/T5 and WOH.18 H18-09/H18-T13/T14/T16/T17.
Implementation: local private-file data imports, authenticated selections and native form implemented.
Evidence: [executed Store, peer, recovery and native checks](../provenance/native-authoring-data-selection-2026-10.md).

## Purpose and boundaries

An operator imports private source, fixture or other authoring bytes without
writing operation JSON, then explicitly supplies owned source/fixture handles
for a separate manual draft assessment. Imports are inert custody records.
Assessment, source review, approval, target selection and physical qualification
remain separate decisions. Authority/Store retain authorization, ownership,
revision CAS and durable receipts; Swift never opens SQLite.

The complete original codec, private v6 pending publication, bounded socket
upload and original recovery are inherited from
[native authoring originals](native-authoring-originals-v1.md).
The installed contract and owned draft are inherited from
[manual drafts](native-manual-draft-v1.md). Existing complete-original and
[review preparation](native-authoring-review-preparation-v1.md) stay compatible.
No producer changes or schema migration are required.

## Inputs and representation

| Input | Representation and bounds | Owner |
| --- | --- | --- |
| Data kind | Exactly source, draft, bundle, fixture, contract, envelope, profile or definition | Operator |
| Data bytes | Nonempty; source/draft/bundle/contract ≤262144 bytes, other kinds ≤65536 bytes | Private operator-selected file |
| Selection file | Optional; nonempty strict UTF-8 JSON ≤16384 bytes, container depth ≤3 | Operator |
| Source/fixture handle | Exactly object_digest and first_revision; lowercase 64-hex digest, positive signed-64 integer, no boolean/float | Verified Store import receipt |
| Instruction | Existing manual assessment UTF-8 bound of 4096 bytes | Operator |

All selected files must have absolute paths, owned regular mode-0600 leaves,
one hard link and no symlink leaf/ancestor. Existing descriptor identity,
size and before/after metadata checks apply. Read exact bytes; never rewrite,
parse or infer data-kind payload content during inert import.

The selection root has exactly source_refs and fixture_refs. Each is an array
of 0..32 exact handles, strictly ascending unique object_digest. Missing fields,
unknown fields, duplicate JSON keys, invalid UTF-8, wrong types, out-of-range
integers and unsorted/duplicate handles are refusals. An absent selection file
means both arrays are empty; a supplied malformed file has no fallback.

## Requirements and transitions

**DS-01 — Generic inert data preparation.** Reject remote or unavailable local
selection before file or credential I/O. Read the kind-bounded private bytes;
capture one local credential; read controller identity, authenticated profiles
catalogue and controller identity again. Require unchanged authority owner,
principal, epoch, installation/reference association and session generation,
with equal before/catalogue/after Store revisions. An installed authoring
producer is not required for this inert operation. Construct a fresh
authoring:data:UUID operation using current epoch/CAS, the existing unchanged
WOHA tags 1..8, exact raw SHA256, tagged-frame SHA256 and byte size. Validate
the complete original/payload with the existing native codec before preparation
returns. Submission requires explicit confirmation and all existing fresh
identity/CAS checks, complete private original publication before any request,
bounded upload and matched receipt. Expose a handle only from a matched import
receipt; repeated identical bytes retain the historical first_revision.

**DS-02 — Closed handle selection.** Parse the optional private file before
transport. Preserve every selected handle exactly. No dropping stale handles,
per-field defaults, inferred kinds or automatic addition of imported objects.

**DS-03 — Authenticated selected-object validation.** Within the same
before/contract/after identity bracket used to prepare manual assessment, read
each selected object through the authenticated object-read client. Verify its
full tagged frame, raw hash, size, requested digest, expected source/fixture
kind and exact first_revision. A missing object returns
authoring_object_unavailable; wrong kind/revision returns
stale_authoring_reference; malformed read responses retain typed decoder
refusals. Complete selected frames together must not exceed 4194304 bytes.
Release each payload after validation and retain only handles. Require the
same verified draft context, current epoch/CAS, equal bracket revisions and
current exported contract/typed limits. Build the complete candidate original
with the exact sorted source/fixture sets. Store independently rechecks every
reference. The existing fresh complete-basis check also runs before pending
publication; a changed basis requires new preparation.

**DS-04 — Explicit native flow.** Add a Data Import kind/file entry and an
optional selection-file chooser for an owned manual draft. All entries share
busy, local-access and pending-work guards. Data file/kind edits retire prepared
work. Selection-file edits retire assessment preparation while preserving the
owned draft. Session replacement, wake and cancellation retire late work;
repeated busy clicks start one call. Mount/reload performs no import, file read,
assessment or publication. Display imported digest and historical first
revision, and prepared selected counts. An explicit copy action may copy only
the two-field handle. Never automatically assess, review, approve or select.

| Event | Result | Failure/uncertainty |
| --- | --- | --- |
| Prepare data | Reviewed immutable decision; no Store mutation | No decision/handle on invalid file, scope or basis |
| Confirm and submit | Matched import receipt and explicit handle | Unknown reply retains original; no handle or new operation retry |
| Prepare selected assessment | Complete candidate on one current basis | Any missing/stale selection refuses the whole preparation |
| Recover original | Existing original lookup returns historical result | Unknown remains pending; never manufacture a handle |

Cancellation cannot undo a handed-off Store operation. Retired UI deliveries
cannot restore a decision or owned handle. A lost reply uses the existing
retained original and Activity recovery, with no automatic resubmission.
Revocation, restart, capacity limits and epoch/CAS conflicts retain existing
fail-closed original/upload semantics. This slice adds no durable state.

## Acceptance

| Case | Requirements | Stimulus and independent observation | Evidence level |
| --- | --- | --- | --- |
| DS-T1 | DS-01/04 | Import all eight kinds through native SDK into a default Store without installed authoring producer; independently hash WOHA frames, compare exact payload/receipt/history; malformed private files and bounds produce no publication | Software |
| DS-T2 | DS-02/03 | Independent source/fixture sets; exact candidate input compared with Store; reject missing/wrong-kind/wrong-revision/duplicate/unsorted/extra-key/bool/float/overflow inputs and revision change with no candidate publication | Software |
| DS-T3 | DS-01/03 | Native source/fixture/envelope/draft imports → selected assessment → complete review against actual Store; inspect v6 publication before transport, lost reply and original lookup without extra revision | Software |
| DS-T4 | DS-04 | Delayed preparations interrupted by edits/session/wake/cancel and repeated busy action; owned draft survives selection edit; shared work guards; inspect prepared/receipt views at five existing viewport widths | Native software/render |

Checks must name source/toolchain, actual commands, fixtures and results.
Compilation, synthetic peers and software Store tests do not establish signed
installed-host behavior, physical qualification or permission to dispatch.
