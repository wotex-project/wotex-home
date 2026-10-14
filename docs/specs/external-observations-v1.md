# Durable external reported values

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18-04/05/08, H18-T3/T4/T5/T8/T11/T12; WOH.01 H01-T6.
Implementation: planned. Evidence: missing.

## Result and dependencies

Authority.accept_external_report/2 accepts one native host-custodied decoded
receipt into the single Store, preserving exact WPF interpretation and supplied
consumer coordinates. The receipt proves a host receive instant under its
configured publisher; it does not qualify a device or establish physical truth.
Only [ReportOwner](external-report-custody-v1.md) supplies report bytes and clock.
There is no socket/model route accepting report bodies or receive timestamps.
Device workers own transport and receive no Store connection or bearer.

[Durable target selection](external-target-selections-v1.md) owns source bindings,
stable identities, checked declarations, approving/selection authors, policy and
resource counters. [ExternalValue](external-values-v1.md) owns interpretation via
public WPF Interpreter/Proposal and exact Unit conversion. ReadCapability retains
those opaque units/schemas without broadening legacy Capability/Value, fact,
routine or control vocabularies. Generic reported-value reads are separately
authenticated previews; they confer no dispatch or routine authority.

## Native originals and source preparation

Input is exactly report_owner_epoch (lower hex32) and report_id (Home ID). Its
canonical original is ["wotex-home.external-observation.v1", epoch, report_id],
at most 512 bytes under the existing array-only AuthoringWire limits. Namespace
is this epoch/report ID; no caller supplies target, principal, value, channel,
sequence, policy, clock, producer or closure. Metadata receipt recovery precedes
fresh report/source/bytes/CAS work. A historical receipt cannot renew freshness.

Store has an explicitly configured external_report_owner process reference,
default null, in addition to its source owner/custody. New work requires a
writable active controller and the same live report-owner epoch. Checkout occurs
only from the configured Store PID. Resolve one selected external target by the
receipt's exact source_ref/source_owner_epoch/source_selection_sha256; no legacy
or unbound target can be chosen. Require its shared Thing/resource/pointer,
latest selection author's profile:manage plus enroll:review, exact current approved
trust revision and active profile:manage approver, and global external policy
generation retained by that selection. Revoked/stale/ambiguous targets refuse.

New admission requires an explicit selection committed in this Store boot.
Keep only target→selection-revision in transient Store state, initialized empty
and updated after an actual new select commit; exact original replay never adds
it. Restart/restore therefore requires explicit reselection before fresh use.
Historical originals stay readable. This marker contains no private source body.

SourceOwner.current/5 is a new native read-only snapshot boundary: principal ID,
source_ref, expected source-owner epoch and SHA. Store derives the current
selection author before calling it. It returns the exact already published
checked selection or the source owner's existing typed refusal. It creates no
lease/original/time and authorizes no use. This avoids spending the bounded
target-review original namespace on every sensor packet. There is no public
socket route; the final report guard and current source catalogue remain required.

Read actor-owned immutable typed frames through existing sequential custody leases.
Rebuild the selected target with its original typed handles, actual current source
snapshot and retained approval manifest. Require the whole rebuilt target outcome
to equal the retained selection's exact outcome. Then ExternalValue.project/4
uses the actual report, included channel's exact host consumer and that checked
envelope. No supplied proposal, catalogue projection or cached normalized value
bypasses interpretation. Unknown/excluded channels and stale profile/binding/
capture/source epoch refuse. Private byte leases release on every path.

## Clock, sequence and commit

**OB-01 — Preserve actual receipt.** Record the original report, exact public
canonical ExternalValue data and source-selection basis without changing any
producer source_time/receipt_time, quality/reason/continuity or normalized value.
The native report guard's receipt_monotonic_us is converted using floor division
by 1000, then subtract Store.clock_origin to obtain Store elapsed receipt_ms.
Reject pre-Store-boot, future or expired receipt; do not substitute processing time.
Retain current Store boot epoch separately. Freshness age is elapsed Store time
minus that original elapsed receive instant; equality at freshness_ms is stale.

**OB-02 — Keep replay separate from fresh receipt.** A non-null sequence is the
original canonical unsigned-64 decimal string. For one target/channel/source epoch,
the first non-null sequence may be any value. Thereafter reject an equal sequence
under a new report original as external_observation_duplicate and a smaller one
as stale_external_sequence. Do not invent a sequence for null. Null, retained,
replayed, gap or unknown continuity never establishes fresh reported value.
Continuous with a preceding non-null sequence requires exactly previous+1;
otherwise continuity_mismatch. Baseline may establish a new fresh source sample
only at a larger sequence under the same epoch. Source epoch changes require the
explicit target/source succession, which clears the current pointer but retains
historical sequence/tombstone evidence. Qualities invalid/unknown/stale retain null
normalized values; no zero/false replacement occurs.

**OB-03 — Commit once.** One Store transaction repeats original lookup, current
controller/epoch/target/author/trust/policy/resource/source and owned byte basis.
Require the held report/source guard unchanged, live Store PID, original clock
and deadline, and the same prepared value/declaration. Append one
external_observation_recorded authority journal event with entity target_id,
immutable original/outcome/receipt, update the target/channel current pointer and
its non-null sequence cursor. Report publication is not this commit. SQL failure
rolls back every row/pointer/counter. Final guard failure rolls back as its typed
policy refusal, preserving Store writability. Finish report checkout on a definite
attempt/refusal; lost reply uses exact durable original lookup and never renews
source evidence. A consumed original with no durable row needs an actually new
transport receipt, not automatic retransmission with a changed clock/ID.

Outcome is exactly format wotex-home.external-observation-result@1,
report_document (the exact private decoded report JSON), value_document (exact
canonical ExternalValue data), value_sha256, target_selection_revision,
declaration_sha256 and source_selection_sha256. Both documents use the existing
fixed maximal UTF-8 chunks of at most 4096 bytes; each reconstructed document
is nonempty and at most 65536 bytes. Canonical ordered outcome array in this order
is at most 524288 bytes. Decode uses duplicate-rejecting bounded historical JSON,
closed Home metadata and exact byte hashes, without producer algebra/files.
value_sha256 uses the existing wotex-home.external-value@1 newline prefix;
report SHA uses the receipt owner's owning prefix. Historical validation must
compare target/declaration/consumer/quality/provenance correspondence, not merely
recomputed receipt hashes. It preserves opaque external C02/schema/unit bodies.

Receipt has exactly authority_epoch, report_owner_epoch, report_id, revision,
input_sha256, target_id, capability_key, selection_revision, resource_revision,
trust_revision, policy_generation, source_selection_sha256, report_sha256,
value_sha256, outcome_sha256, store_boot_epoch and received_store_ms. All revisions
are signed-64 with their owning positive/nonnegative bounds; clock elapsed_ms is
nonnegative signed-64, Store boot is a Home ID; all SHA values lower hex64.
Canonical ordered receipt array is at most 4096 bytes. It contains no source body,
private stable identity, transport endpoint, PID or transient deadline.

## Schema, invalidation and recovery

Freeze schema 35, with schema 34 as predecessor. Add exactly:

| Table | Columns in declaration order |
| --- | --- |
| profile_external_observations | report_owner_epoch, report_id, input_document, outcome_document, receipt_document, revision |
| profile_external_observation_current | target_id, capability_key, revision |
| profile_external_observation_sequences | target_id, channel_id, source_epoch, sequence, revision |

Original epoch/ID is PK; original revision unique journal FK. Current target/key
is PK and references the shared enrolled Thing and immutable observation revision.
Sequence target/channel/source epoch is PK, sequence is canonical uint64 TEXT
and revision references the exact original that supplied it. All tables start
empty. No old inspection/selection/report is promoted. Retain at most 4096
originals, 16 MiB outcome bytes, 2 MiB input bytes and 8192 sequence cursors;
refuse external_observation_capacity before preparation and at commit.
Capacity never evicts replay/sequence identity or changes freshness.

Target replace/revoke/dependency retirement deletes its current report pointers
atomically; original rows and sequence history remain. Grant withdrawal affects
authenticated read visibility, not receipt history. Missing source/producer/bytes,
author/trust/policy drift, old Store boot and source replacement block fresh use.
Restore/transfer uses actual tables and retains immutable originals/sequences,
without restoring live boot selection markers, leases, grants, qualification or
freshness. Older normalized histories declare empty new tables. Deep corruption
is corrupt_external_observations and fences writes.

## Reported-value reads

Authority.external_report_current/4 takes current bearer, target ID and capability
key. Require read permission and whole-Thing grant before lookup; no new grant
namespace. Return an explicit home-external-reported-value-v1 preview with current
target/resource/selection, exact value data or null, report revision, freshness
disposition, age_ms and remaining_ms. Missing/stale basis, wrong boot, expired,
unusable/discontinuous/null-sequence or synthetic_lab source yields unknown with
its actual reason; it never returns a current known value on an old selection.
Current private frame/source/producer checks occur outside SQL, repeated through
call-local checked context. Original receipt status likewise requires current
read permission/grant for its retained target. No original output is a current pin.
Legacy FactReadModel, invariants, routines and effects remain explicitly unavailable
for generic read values until their separately accepted correspondence exists.

## Acceptance

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| OB-T1 | 01–03 | Two independent quantities and actual multi-channel source: publish, prepare, commit, read/replay and restart/reselect. Wrong coordinate, new freshness from replay or implicit grant/control fails. | Software/archive |
| OB-T2 | 01/03 | Wrong owner/caller/channel/profile/capture/source/selection/trust/policy/author, missing immutable bytes/producer, preboot/future/expired receipt and source replacement during preparation. Partial admission or processing timestamp fails. | Software |
| OB-T3 | 02/03 | Equal/decreasing/maximum/null sequences, continuous gap, retained/replayed and sentinel quality. Renewed freshness, overflow, guessed continuity or zero/false fails. | Software |
| OB-T4 | 03 | Actual SQL/final-guard failure, lost reply, target/author/trust withdrawal and exact status. Partial pointers or revived authority fails. | Software |
| OB-T5 | 01–03 | Deep originals/value/declaration/journal/current/sequence corruption, exact quotas, migration and inclusive/database-only/normalized quarantine. Writable corruption or resumed live authority fails. | Software |

Independent canonical report/value/outcome/receipt/schema vectors precede code.
Pure helpers are not a completed observation owner: actual Store transaction,
authenticated read boundary, boot/sequence/invalidation and recovery cases are
required. Qualified transport cohorts and hardware evidence remain separate.
