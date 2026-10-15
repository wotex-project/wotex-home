# Native generation workspace and first decisions

Version: 0.1.4. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.08 H08-09/H08-T9; WOH.18 H18A-02/04/05 and H18-T15/T16/T17;
WOH.15 H15-03/07 and H15-T8.
Implementation: workspace, guarded local first decisions, panel, repair/cancellation
and fresh manual candidate composition implemented. Explicit absent-original
pending acknowledgement and installed delivery remain unfinished.
Evidence: [custody dependency](../provenance/native-generation-workspace-2026-10.md)
and [executed first-decision checks](../provenance/native-generation-flow-2026-10.md).

## Result, owners and entry conditions

The local native operator can choose an installed generator policy, select its
permitted ranges/fixtures, enter instruction/budget, prepare and separately confirm
one generation original. A durable client workspace preserves the complete root
and explicit attempts through native restart and pending-mutation resolution.
The native panel can read status, explicitly repair an invalid candidate, cancel
its root and pass a generated draft through ordinary manual assessment/review.
No automatic attempt, provider fallback, export on opening/editing, profile
approval, target selection or physical control follows.

[Generation SDK](native-generation-sdk-v1.md) owns strict options/full result and
status correspondence, one unchanged mutation and uncertainty. Store owns current
actor/source/policy/provider/basis/epoch/CAS, nonrenewing deadlines, export and
settlement. [v7 pending](native-pending-generation-v7.md) owns publication before
mutation. This entry owns local workspace custody, selected-session first decisions
and presentation. Existing [manual authoring](native-manual-draft-v1.md) and
[review preparation](native-authoring-review-preparation-v1.md) own fresh manual
candidate receipts, attribution and review. A generation assessment is not a manual
candidate-reference substitute or reviewed source truth.

The actual SDK, original codec, v7 publication and installed policy/operator routes
are implemented. No ExBooking/WoTEx API, application schema or dependency change
is needed. Signed paired generation remains unavailable; refuse before capture.
Unconfigured policy stays empty. Concrete model quality, installed signing,
confinement and physical qualification retain their separate gates.

## Durable workspace representation

**NGU-01 — Preserve complete session inputs.** Use fixed per-account private
`native-generation-workspace-v1.json` and `.lock`, under the same private directory
owner as native pending metadata. Inherit same-user/nonlinked 0700 parent,
0600 regular single-link files and descriptor/content/revision/inode whole-file
CAS from NativePrivateDocuments. Never store a credential, seal, provider endpoint/
key, source/draft bytes, local clock or current permission. Load sends no request
and makes no write. Mirrors redact instructions and handles.

The canonical root is exactly
`["wotex-home.native-generation-workspace.v1",REVISION,ENTRIES]`, positive S64
revision and at most 2097152 UTF-8 bytes. There are 0–16 entries, strictly sorted
by canonical `[DEPLOYMENT,OWNER,EPOCH]` bytes and unique by those three fields,
regardless of principal. Entry is exactly:

```
[[DEPLOYMENT,OWNER,EPOCH,PRINCIPAL],CUSTODY,BASIS_SHA,
 PREPARATION_DOCUMENT,ATTEMPT_DOCUMENTS,CANCELLATION_PENDING]
```

Context uses lower hex64 deployment/owner, positive S64 epoch and 1–128 ASCII
Home principal ID. Custody is exactly `["manual",VERIFIER]` or
`["native","operator",CREATION_REVISION,VERIFIER]`; verifier lower hex64,
native creation revision positive S64 and native principal must equal the existing
`native-setup-v1:EPOCH:operator` spelling. Manual custody retains the existing
non-native-setup principal constraint; paired custody refuses. Basis SHA is lower
hex64 installed authoring-basis metadata, not current authority by itself.

Preparation document is the complete owning canonical UTF-8 string, at most32768
decoded bytes, kind preparation and epoch equal context. Native expected revision
must be at least custody creation revision. Attempt documents are 0–3 complete
canonical strings, at most2048 decoded bytes each, and no more than preparation's
selected budget.attempts. Preserve insertion/attempt order. Each is kind attempt,
same epoch, exact preparation operation/input SHA, index equal one-based position,
and strictly increasing expected revision greater than preparation expected revision.
IDs are unique across root/attempts. Initial predecessor null/repair false;
subsequent predecessor is exactly the preceding attempt ID and repair true.
Revalidate all owning bytes/metadata before encode, decode and access. These are
representation links, not evidence that a Store reservation occurred.

Cancellation_pending is boolean local intent; it records no cancellation result.
It may change independently under CAS. No other field of an existing entry may
change. Exact entry confirmation is a no-op; appending an exact already retained
last attempt confirms without another revision. New attempts append one at a time,
never replace or remove old attempts. Root/context/custody/basis substitution and
same-scope new root conflict. Removing a whole exact entry requires an explicit
consumer decision below; a stale removal cannot erase a newer entry. Keep a
versioned empty file after resolution, with monotonically increasing revision.

Before Foundation tree allocation bound depth to four, nodes to1024, arrays to16
members and ordinary strings to128 unescaped ASCII bytes. Only the exact root
document slot permits32768 decoded UTF-8 bytes/quote-backslash escapes; exact
attempt slots permit2048. Canonical re-encoding must equal original bytes.
Unknown versions/fields, bad UTF-8, boolean/float/overflow integers, wrong ordering,
slot bleed, capacity, unsafe paths and changed original refuse without reset or
eviction. Use invalidRecord/unavailable/conflict/capacity/outcomeUnknown families
without fragments. An uncertain write retains memory and requires reload/CAS
confirmation before dispatch or later edits. No journal/Store schema migration.

## Explicit decisions and publication order

**NGU-02 — Select and freeze the current input.** Opening, startup, editing and
task/selection changes do no configuration RPC or model work. An explicit local
load checks selected association snapshot/generation and response fence, captures
exact manual/native Operator custody, reads authenticated identity, installed
contract and options, then repeats identity. Principal/epoch and Store revisions
must agree; changed selection/custody/basis invalidates the prepared decision.
Persisted metadata cannot supply that current proof.

Choose a policy explicitly, with no default model. Passage/example checklists
start empty; select only exact allowed metadata rows. Preserve canonical order,
unique handles/ranges and the policy's exact six limits. Instruction is0–4096
UTF-8 bytes, Cc forbidden except LF/tab. All three budget fields start empty;
require explicit canonical decimal attempts1–3, attempt_ms1–30000, total_ms1–120000,
attempt_ms<=total_ms. Remote policy requires both installed remote_export and a
separate unchecked-by-default export-consent confirmation. Local uses false.
The current contract SHA comes from the verified export, not editable text.
Show provider/model/locality, selected ranges/examples, instruction, byte ceilings
and budget before confirming preparation. Source text remains inert; reading
or selecting it creates no attribution or control authority.

Preparation records an inert root and starts no model. Before its mutation,
recheck selected snapshot/generation/custody/current identity revision and reviewed
basis; publish the complete workspace root, then publish its exact v7 pending
original, then submit once through SDK. Failed/uncertain publication sends nothing.
Matching reply/current identity can resolve the pending mutation only after root
workspace custody is confirmed. Lost/malformed reply retains both originals.
The two files have ordered publication, not an invented multi-file transaction.
On restart explicitly reconcile workspace/pending/status; never silently replace
an original or allocate a new identity because one publication was incomplete.
An explicit restore action checks current original custody and existing-only root/
last-attempt status, then republishes the complete absent root or retained last
attempt into pending recovery. It makes no generation mutation and preserves the
original revision/ID/SHA. Ordinary explicit lookup/retry then uses that pending
original. Refuse a missing root with retained attempts, another pending operation,
uncertain workspace custody or unresolved cancellation intent. Never reconstruct
an original from displayed fields or current options.

**NGU-03 — Start and repair separately.** Explicitly read the selected root's
current matching status; start only prepared. Re-read current contract/basis and
the same exact policy/provider, with provider_present true as a declaration rather
than model authentication. Store repeats actual availability/export guards.
Use current checked revision to construct one fresh unique attempt ID. Initial
index1 has null predecessor/false repair. Later index is previous+1 within original
budget and requires matching retained candidate result with assessment invalid,
current owned predecessor and explicitly confirmed feedback export. Show the
previous raw draft/report selected for feedback; no repair for running, unknown,
cancelled, compatible or missing result. Do not renew root time or enlarge limits.

Publish attempt append in workspace, then its v7 pending original, then submit
once. Keep running/unsettled unknown pending; explicit status and SDK recovery
preserve original identity. Settlement resolves pending under existing guards,
while workspace retains root/attempt inputs for status/review. A queue/deadline/
policy/permission/basis refusal creates no automatic alternative. First known
refusal and absent status require the separately confirmed SDK acknowledgeAbsent
decision on the exact pending original. It performs existing-only status/current
custody checks and exact journal CAS, never a mutation or stopped-model claim.
Workspace remains retained until its own separately confirmed archive. Uncertainty
never enables edited-input retry or a new operation ID.

## Cancellation, restart, result review and presentation

**NGU-04 — Retain cancellation identity.** Cancellation names the persisted root,
not a draft or successor. Require separately confirmed user intent and current
original custody/controller. Set cancellation_pending through workspace CAS before
SDK cancel, even when an attempt occupies pending. Matching cancelled status clears
only this local intent; lost reply retains it. Explicit lookup uses root status;
explicit retry sends the same idempotent cancellation. No automatic startup action,
deadline renewal or claim that a remote model stopped. Ordinary new generation
work remains blocked while cancellation intent is uncertain.

Load/restart preserves inputs and intent, with no RPC. Explicit resume opens
existing original custody, checks its verifier/controller/principal and current
status. A cached label/basis is never permission. Changed actor/epoch/owner/basis,
revoked custody, missing controller and malformed/late response retain originals
and retire private displayed content. Workspace reads can expose scoped identity
without using another principal's private projection. Keep explicit refresh;
there is no timer, background generation or hidden request on view appearance.

**NGU-05 — Keep generated review on the existing boundary.** A candidate is inert
owned draft/bundle plus complete mechanics. Display typed status and diagnostics;
compatible is not reviewed/admitted. An explicit “Assess This Draft” verifies owned
draft metadata/bytes against its result and obtains the stable generated import
receipt under the same original controller. Build a fresh manual candidate using
current contract/reader/basis/CAS and explicit deduplicated root sources/fixtures.
Publish and submit through ordinary authoring, then use its actual candidate
receipt for attribution/review. Never cast a generation attempt into a manual
candidate reference or infer fixture/source success. Existing authoring bounds
and refusals apply; changes of basis require a new reviewed decision.

The Things task exposes these operations as one generation panel sharing pending
coordination. Disable conflicting actions while busy/unconfirmed; invalidation
retires prepared decisions and private previews. Confirmation resets on every
changed input/context. Archive workspace only on an explicit decision after pending
and cancellation intent are reconciled. A missing root without attempts, a missing
last attempt, or an unknown/null attempt requires a separate archive confirmation
that expressly acknowledges uncertainty and that a later result may still arrive.
Running status always refuses archive. This removes client metadata, not controller
history, model work or an authorization guard. Signed paired presentation, actual
installed accessibility and physical qualification remain separate.

## Acceptance and delivery order

Before runtime allocate independent Python workspace roots from frozen original
vectors, including exact links/order/Unicode/cancel intent. The owning codecs may
cross-check but cannot replace the independent oracle.

| Case | Requirements | Stimulus, observation and falsifier | Level |
| --- | --- | --- | --- |
| NGU-T1 | 01 | Independent root/attempt/repair/Unicode/intent vectors, S64, maximum count/byte/slot and malformed links/order/custody/phase. Drift, alias, private reflection or metadata-as-authority fails. | Native software |
| NGU-T2 | 01/02/04 | Actual private CAS, independent processes racing root/append/intent/archive, stale same-content inode replacement, no-op, capacity and restart load with no request. Multiple winners, overwritten original or silent reset fails. | Private-file/process |
| NGU-T3 | 02/03 | Actual Store/native selected flow, explicit policy/selection/consent/budget, workspace then pending observed before mutation; dropped reply/restart and failure between publications. Early dispatch, changed ID/CAS, auto call or renewed budget fails. | Native/Store/process |
| NGU-T4 | 03/04 | Explicit invalid-candidate repair/cancel, missing/compatible/unknown/expired root, current guard withdrawal and lost cancellation reply. Implicit feedback, discarded intent or provider replay fails. | Native/Store/process |
| NGU-T5 | 02–05 | View-model editing/late responses/selection change, no request on open/load, generated draft to fresh manual receipt/review, inert labels and installed panel interaction. Borrowed authority, false review/control or stale content fails. | Native software plus separate installed checks |

Implement workspace codec/private custody first, then guarded driver decisions,
then panel/review composition, with evidence per dependency and focused tests.
The local first-decision flow now has focused native/Store evidence. Missing-status
pending reconciliation remains an implementation obligation: ordinary lookup
retains an absent original, so this slice cannot yet archive every first refusal.
Signed paired generation and installed interaction/qualification retain separate
gates; focused checks alone do not complete NGU-T3–T5.
