# Durable initial generator preparations

Version: 0.1.2. Updated: 2026-10-15. Status: accepted successor target.
Owner: WOH.18 H18A-02/04/05, H18-T15/T16/T17; WOH.14/16 durable originals.
Implementation: inert preparation/original/status/cancellation and schema-36
recovery integration implemented. Evidence: [executed software cases](../provenance/generation-preparations-2026-10.md).

## Result and trust boundary

An authenticated profile author explicitly selects an installed generator policy
and owned source passages/examples. The single Store validates the complete
selection, computes the existing bounded GenerationInput and retains a durable
original preparation receipt. Lost replies query or retry that exact original.
The result is inert: no provider call, exported document, generated draft,
assessment, profile approval, enrollment or effect occurs. Provider handoff and
repair need separately defined current guards and original attempt records.

Authority owns this use case; adapters and a future generator receive no Store
connection or principal bearer. The stateless writer borrows Store's connection
only inside its transaction. Custody retains the selected immutable frames.
GenerationInput owns exact projection bytes/limits; AuthoringContract owns
current installed producer reconstruction. No schema or compiler is duplicated.
This initial operation has no base draft or repair feedback; those inputs remain
unavailable until their own export/handoff contract is implemented. Existing
manual candidate inputs/receipts and every prior original remain unchanged.

## Trusted installed policies

Store option generation_policies is a proper list of at most 32 checked native
GenerationPolicy values, default empty/disabled. Validate and reconstruct all
values before acquiring Store lock/SQLite. Values are sorted uniquely by
(principal_id, provider.id). Policies are trusted native installation data;
neither an operation, source document nor model can install them. This Store
contract adds no loader, application default, endpoint or provider credential.
The [Host installation successor](generation-installation-v1.md) now supplies
checked policies through an immutable private file or explicit native input;
its policy data starts no model and does not replace these current guards.

GenerationPolicy.new/1 takes exactly principal_id, provider, remote_export,
passages, examples and limits. Principal is a Home ID, provider is exactly id,
model_id, adapter_sha256 and locality: two Home IDs, lower hex64 adapter/build
identity and locality local/remote. This identity asserts selected host code/model,
not provider authentication, confinement or a URL. Remote_export is boolean;
local providers require false. A remote provider with false remains installed
but cannot prepare an export. Passages/examples use GenerationInput's exact
reference/range grammar and ordering (32 each); limits use its six positive
bounded ceilings. These lists are the explicit maximum permitted exact ranges
and examples, not entire source documents. Requested lists must be subsets;
overlap or a different length is not implicit permission. Policy contains no
instruction, source bytes, endpoint, credential, executable callback or driver.

The policy's canonical representation is the ordered array
[principal_id,[id,model_id,adapter_sha256,locality],remote_export,
 [[object_digest,first_revision,offset,length],...],
 [[object_digest,first_revision],...],
 [max_passages,max_passage_bytes,max_passages_bytes,max_examples,
  max_examples_bytes,max_input_bytes]].
Policy SHA hashes UTF-8 wotex-home.generation-policy@1, newline, compact canonical
JSON of that array. Provider SHA hashes wotex-home.generation-provider@1, newline
and its four-slot array. Native fields are exactly input, sha256 and provider_sha256
plus struct tag. Reconstruct every field before use; malformed installation
refuses invalid_generation_policy without durable resources. Inspection exposes
only the two SHA fields. There are no implicit policies or fallback providers.

## Closed preparation request and wire identity

Authority.prepare_authoring_generation/3 and Store.prepare_authoring_generation/3
take credential plus exactly authority_epoch, operation_id, expected_revision,
provider_sha256, policy_sha256, remote_export, projection and budget. Epoch is
positive signed-64; revision nonnegative signed-64; operation a Home ID; hashes
lower hex64; remote_export boolean. Projection is the exact five-field request
of GenerationInput: contract_digest, instruction, passages, examples and limits.
Budget is exactly attempts, attempt_ms and total_ms: integers 1..3, 1..30000,
1..120000, with attempt_ms <= total_ms. Attempts are a future explicit ceiling,
never evidence that a provider has been called. All values are explicit.

GenerationPreparation.encode/1 produces exactly the compact ordered array:

```
["wotex-home.generation-preparation.v1",
 [epoch,operation,expected_revision,provider_SHA,policy_SHA,remote_export,
  [contract_digest,instruction,
   [[object_digest,first_revision,offset,length],...],
   [[object_digest,first_revision],...],
   [max_passages,max_passage_bytes,max_passages_bytes,max_examples,
    max_examples_bytes,max_input_bytes]],
  [attempts,attempt_ms,total_ms]]]
```

Wire is UTF-8, at most 32768 bytes, depth eight, 4096 nodes, collections 256,
strings 4096, signed-64 integers and no objects/floats. Decode/re-encode must match
exact bytes; duplicate/unknown/struct/unsorted/improper/native fields refuse
invalid_generation_preparation. Counts above selected ceilings or other resource
excess refuse authoring_limit without walking an over-budget tail. Reuse the
public producer JSON only for projection/policy work, never historical decoding.

## Store transitions, current guards and outcomes

**GP-01 — Authenticate and resolve original before recomputation.** Current
profile:manage authentication and generation/import ledger integrity precede
original lookup. Scope is principal/epoch/operation in the generation-preparation
namespace. Exact input returns the immutable original receipt before CAS,
installation/producer/policy, custody/file access or clock work; changed bytes at
that scope refuse authoring_operation_conflict. Revocation blocks new/replayed
operations and status. Other actors' originals are not_found. Status has no
producer, policy, source or byte prerequisite.

**GP-02 — Check every new preparation.** Require current epoch/global revision
CAS, normal writable controller outside maintenance, selected current contract
digest, actual installed policy for authenticated principal/provider/policy SHA,
identical projection limits and permitted exact passages/examples. Remote
preparation requires both native remote_export true and this operation's explicit
remote_export true; local requires false. Missing policy/provider refuses
generation_unavailable; mismatching current policy refuses stale_generation_policy;
forbidden ranges/examples/export consent refuse generation_export_denied.

Every reference must be actor-owned, matching first revision/kind (source or
fixture) and first imported no later than expected_revision. Unowned returns
not_found; wrong kind/revision stale_authoring_reference. All metadata references
pass before payload reads. Read exact framed bytes through owned custody leases,
check frame summary against the ledger, then call GenerationInput.prepare with
only the selected object union. Missing/corrupt custody has its owning refusal.
Retain only SHA/count metadata from that private document, release every lease
and discard the raw projection after computation. Never return or log it.

Store supplies boot_epoch (existing boot:<hex32>) and monotonic coordinates
relative to its actual clock_origin. Created_ms is nonnegative signed-64;
expires_ms is created_ms + budget.total_ms with no overflow. Time is sampled once
for the original; no replay or cancellation extends it. New preparation requires
fewer than 16 uncancelled, unexpired preparations in this actual Store boot,
at most 1024 retained originals and at most 4 MiB aggregate original input bytes.
Capacity refuses generation_preparation_capacity before mutation. Final commit
repeats the actual current monotonic time; now >= the original expires_ms refuses
generation_deadline_expired rather than retaining an expired preparation. No
executing generator exists in this slice; the later handoff must enforce one executing
generation per operator as well as this shared capacity/deadline.

One transaction repeats authentication, integrity, epoch/CAS/maintenance,
references, current contract/policy and capacity, appends
authoring_generation_prepared (entity_id operation), stores input/basis/receipt
and increments revision once. SQL failure rolls back every row/revision. No file
is staged, no provider attempt is spent and no activation is created.

Receipt is exactly authority_epoch, operation_id, revision, input_sha256,
projection_sha256, basis_sha256, provider_sha256, policy_sha256 and disposition
prepared. Input SHA hashes the exact ordered operation document; projection SHA
is GenerationInput's domain-separated identity; basis is current Home contract
basis. Receipt encoding is its nine slots in that order, at most 2048 bytes.
It exposes no instruction, source/fixture content/handle, private path, boot/time,
provider credential or model confidence. Historical receipt stays prepared even
after cancellation/expiry/restart; status separately describes current availability.

**GP-03 — Cancel and retire without renewal.** Status/cancel authenticate current
profile:manage and scope to principal/epoch/operation. Status is exactly original
(receipt), state and cancellation_revision. State is cancelled when a retained
cancel revision exists; otherwise retired when boot_epoch differs from this
actual Store boot; otherwise expired at now >= expires_ms; otherwise prepared.
This state describes an inert preparation only, never a live export capability.
Metadata status remains possible when producer, policy or bytes are absent.

Cancel records authoring_generation_cancelled once with the same entity_id,
retains cancellation_revision and returns status cancelled. Exact repeat returns
that original cancel status without another revision. Old-boot/expired metadata
may also be cancelled; cancellation does not send a provider request or retract
an export. Missing original is not_found. Cancellation is allowed during
maintenance because it only retires inert work; retired/quarantine Store cannot
perform new writes. Failed cancellation transaction preserves all original data.

## Schema, integrity, recovery and implementation order

Schema **36** adds profile_authoring_generations with exactly principal_id,
authority_epoch, operation_id, input_document, projection_sha256, basis_sha256,
receipt_document, boot_epoch, created_ms, expires_ms, revision and
cancellation_revision. Primary key is principal/epoch/operation; principal FK;
revision unique FK to authority_journal; nullable cancellation_revision unique
FK to that journal. Digests lower hex64; input 1..32768 UTF-8 bytes, receipt
1..2048, valid integer coordinates, expires > created. Migration first validates
the actual historical schema, then creates an empty table; it grants nothing.

Integrity checks every decoded input/receipt/digest/reference, first revisions
and kind, original expected_revision=revision-1, authority epoch bounds,
expires-created=total_ms, boot encoding, preparation/cancellation event/entity/
principal links, cancellation_revision > revision, complete event/row count
correspondence and all quotas. It requires no current producer, policy, bytes or
boot. Corruption is corrupt_generation_preparations and fails Store closed.

Every retained selected object remains an existing immutable import dependency;
generation adds no tagged kind, orphan reserve or file retention exception.
Inclusive/database-only encrypted backup and complete/normalized controller
commitments include the new exact rows. The normalized retained recipe omits an
empty generation table, preserving pre-36 commitment bytes. For a nonempty
retained scope it includes preparations whose revision is at most source_revision
and treats a cancellation later than that source revision as null. Full snapshot
commitments continue to include the actual table schema and every exact row.
Missing bytes retain inert metadata in
quarantine; restore or a new Store boot retires live availability, never resumes
generation or manufactures export consent. Original receipts survive producer/
policy absence. No provider is started during migration/recovery.

Before schema code, freeze Python ordered policy/input/receipt/hash vectors and
actual schema-35 migration/rollback cases. Update the explicitly reviewed Linux
current same-schema cohort and packaged probe to **36**, while keeping exact
historical format-2 metadata for 28 and 35 verifiable. Current executable/image
and live status gates accept only integer 36, never cross-schema updates. All
schema-specific validators/table sets and historical fixtures must preserve
their declared original schemas; do not simply relabel old databases.

## Acceptance

| Case | Requirements | Stimulus and expected observation / falsifier | Level |
| --- | --- | --- | --- |
| GP-T1 | 01/02 | Two actual installed contracts/owned source and fixture sets match independent projection/policy/input/receipt identities; exact replay/lost reply/status changes no revision or provider count, no raw text leaks. | SQLite/software |
| GP-T2 | 01/02 | Foreign/revoked/unprivileged actor, wrong contract/policy/provider/export flag/range/kind/first revision, missing bytes, CAS/epoch and maintenance refuse before mutation; metadata guards precede reads. | SQLite/software |
| GP-T3 | 02/03 | Inclusive 16 live/1024 retained/4-MiB input boundaries, cancellation/repeat, expiry without renewal, new boot/absent policy/producer and original replay; restart/restore never renews or exports. | SQLite/process |
| GP-T4 | 01–03 | Inject transaction failure for prepare/cancel, tamper receipt/hash/clock/journal/reference/row, migrate actual 35 and rollback corruption; encrypted inclusive/database-only quarantine and normalized commitment retain exact history. | SQLite/archive |
| GP-T5 | 02 | Malformed/deep/duplicate/float/boundary ordered inputs and forged native policy refuse; current Linux36 metadata/status/probe and historical28/35 verification remain distinct. | Pure/software |

The [attempt owner](generation-attempts-v1.md) implements durable handoff,
attempt/candidate retention, deadlines, response retirement and explicit repair.
The [Host installation](generation-installation-v1.md) supplies checked
capabilities and immutable private policy. Concrete model adapters/confinement
and signed/native delivery remain successors. Preparation fixtures qualify no
model confinement or physical device.
