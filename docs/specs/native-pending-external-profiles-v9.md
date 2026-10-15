# Native external-profile pending custody v9

Version: 0.1.2. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-03/09 and H08-T1/T5/T9; WOH.15 H15-07/H15-T8;
WOH.18 H18-07/08 and H18-T6/T8/T11/T12.
Implementation: representation, private publication and conditional consumer guards implemented.
Evidence: [independent/native/private-process checks](../provenance/native-pending-external-profiles-2026-10.md).
The [fixed SDK](native-external-profile-sdk-v1.md) now enables ordinary local actions;
paired actions remain disabled pending their signed consumer.

## Result and ownership

Retain a complete external inspection, trust or target-selection original across
client restart and lost replies. This contract owns journal representation,
private publication and compatibility. [Complete originals](native-external-profile-originals-v1.md)
own the exact canonical input and SHA; [typed reads](native-external-profile-reads-v1.md)
own receipt history. A retained record is neither a credential nor permission to
send. Fixed mutation/recovery and selected confirmation are separate consumers.
External target selection is distinct from native controller target-access grants.

Inherit the fixed native-pending-v1.json/.lock account paths, same-user nonlinked
0700 parent, 0600 single-link regular files, descriptor/content/revision/inode
whole-file CAS, positive signed-64 journal revision and sixteen-entry capacity.
Entries sort lexically by canonical UTF-8 context plus category. Deployment/owner/
epoch/category is unique across principals. The coordinator additionally permits
only one pending original across categories for a deployment/owner/epoch. Loading
performs no write, upgrade, credential capture, signing, clock or network work.
[v8](native-pending-paired-authoring-v8.md) owns the unchanged older categories.

## Closed representation and limits

**NP9-01.** Root is exactly
`["wotex-home.native-pending.v9",REVISION,ENTRIES]`, at most 8388608 UTF-8 bytes.
Each entry is exactly `["external_profile",CONTEXT,CUSTODY,INPUT,["pending"]]`.
Context is `[DEPLOYMENT,OWNER,EPOCH,PRINCIPAL]`: lower hex64 deployment/owner,
positive signed-64 epoch and a Home ID of 1–128 ASCII bytes (initial alphanumeric,
then alphanumeric/dot/underscore/colon/hyphen). No other phase is legal.

Input is exactly `["external_profile_operation",KIND,ORIGINAL_DOCUMENT]` with kind
inspection/trust/target. ORIGINAL_DOCUMENT is the complete owning canonical UTF-8
string, not base64 or a reconstructed summary. Inspection/trust/target ceilings
are respectively 16384/4096/32768 decoded bytes. Revalidate the original kind,
canonical bytes, header and all owning bounds on encode, decode and accessor.
The original epoch must equal context epoch; operation ID comes from that original.
Keep its explicit expected revision, historical inspection epoch and SHA unchanged.

Custody is exactly one of:

- `["manual",VERIFIER]`, lower hex64 verifier; principal cannot start
  native-setup-v1:. This is historical bearer correspondence only.
- `["native","operator",CREATION_REVISION,VERIFIER]`, positive signed-64 creation
  revision, lower hex64 verifier; principal is exactly native-setup-v1:EPOCH:operator.
  Reject controller role. Original expected revision is at least creation revision.
- `["paired",ASSOCIATION,CONTROLLER,CREATION_REVISION,VERIFIER]`, three lower hex64
  digests, positive signed-64 creation revision; principal is exactly
  paired-controller-v1:EPOCH:CLIENT with canonical decimal epoch and lower hex64
  client. Original expected revision is at least creation revision. Metadata can
  be decoded without an installed signed app or current association.

Before materializing the tree retain depth four, array members32, ordinary
unescaped ASCII strings128 and the full-file ceiling. Only a v9 root plus the
exact external_profile_operation marker, valid kind and original slot (input
index2) permits its larger string and quote/backslash escaping. Determine the
kind's narrower limit before reading its original. Other slots and old roots
gain no allowance. Existing authoring/generation UTF-8 and schedule ASCII slots
retain their exact rules. Outer canonical strings escape only quote/backslash;
the nested original codec owns any inner escapes. Re-encoding must equal input
bytes. Reject unknown versions, fields, coercions, overflow, noncanonical bytes,
invalid UTF-8, wrong marker/kind/epoch/custody, duplicates and capacity without
returning fragments, resetting or evicting records. Values redact reflection.

## Transitions and compatibility

**NP9-02.** Preserve v1–v8 exact accepted grammar and bytes. They refuse every
external_profile entry, including short originals fitting an old string bound.
First external retain upgrades to v9 in one CAS and revision increment, keeping
all other entries unchanged. No-op confirms the exact existing file and version.
Resolution removes only the exact original and increments once. Retain v9 through
resolution, empty roots and later local/paired/older-category writes. Old supported
roots without the new category keep their previous monotone upgrade behavior.
At maximum revision, refuse a content change; a no-op still checks file CAS.

Paired publication correspondence uses actual required/retained root version,
including v9 with ordinary paired entries. Adding expects the exact sorted union;
retention expects the identical snapshot; phase changes and resolution preserve
version, all other rows and full original identity. A stale content/inode/revision
snapshot refuses. Competing processes have one winner; restart loads that winner.
Uncertain writes retain the original in memory and require reload. Late completion
cannot authorize dispatch or remove it. Never allocate another operation ID to
recover an uncertain original. Downgrade readers fail closed on v9; no rollback
rewrites its marker or strips its entries.

**NP9-03.** Until the corresponding closed fixed external mutation/recovery
consumer is implemented, external first capture and every recovery action refuse before
credential capture, signing, clock, private publication or transport. Metadata
access and disposable private-file representation fixtures remain available.
Ordinary local recovery continues to refuse all paired custody. No automatic
retry, cancellation or acknowledgement follows loading or displaying a record.
Enabling lookup/retry/explicit absent acknowledgement requires its separately
specified consumer to verify the complete original against typed history and
current authorization. The fixed SDK owns the implemented ordinary local consumer.
Target history additionally needs enroll:review; profile:manage alone cannot
authorize it. This representation does not expand paired permission allowlists.

No Store schema, dependency, sibling API or source publisher changes are needed.
Before native implementation freeze independent Python roots from already frozen
external originals. The Swift encoder under test cannot allocate expected bytes.

## Acceptance

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| NP9-T1 | 01/02 | Independent exact roots/SHA for all kinds, both quantity families, multichannel, manual/native/paired, mixed/empty/max revisions; old roots, phase/type/epoch/custody/kind/slot bounds and malformed originals. Drift, widened old grammar or private reflection fails. | Independent native software |
| NP9-T2 | 02 | Actual old-root upgrade, exact no-op, stale CAS, resolution/empty/later writes, maximum revision, process exit/reload and concurrent publishers; one winner, all other entries intact, no downgrade. | Private file/process |
| NP9-T3 | 02/03 | Ordinary paired publication/recovery correspondence in retained v9; external capture/recovery refuses before instrumented credential/clock/network/file work, metadata still loads. Side effects, silent resolution or unsigned success fails. | Native/private file |

These checks establish software custody, not installed signing, target storage
power-loss survival, source qualification or physical dispatch. Record actual
source/toolchain/fixture/commands/results and remaining consumer gates.
