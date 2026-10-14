# Durable generator attempts and bounded repair

Version: 0.1.0. Updated: 2026-10-14. Status: accepted successor target.
Owner: WOH.18 H18A-02–05, H18-T13/T15/T16/T17; WOH.14/16 originals/recovery.
Implementation: planned. Evidence: missing.

## Result and ownership

An authenticated author explicitly starts a provider attempt against one retained
[preparation](generation-preparations-v1.md). Store recomputes the permitted
private projection, records an immutable handoff reservation before any provider
call, and dispatches through a bounded worker. A timely response is finalized
and validated by the same installed WPF.03 mechanics as a manual draft. Exact
draft/bundle bytes become inert actor-owned objects with retained assessment
metadata. Compatible mechanics never imply reviewed sources, independent fixture
success, profile approval, enrollment, selection, rule admission or an effect.

Every attempt is an explicit original; neither a timer, invalid response, lost
reply, restart nor model instruction can start a repair. An explicit repair
may send only the original permitted projection, the preceding invalid draft
from this same preparation/provider and its bounded diagnostic report. The
operator explicitly permits that feedback in the repair operation.

Authority owns the application use case; Store owns authentication, SQLite,
current policy, clocks, worker ownership and final retention. Custody owns exact
framed bytes. GenerationInput owns the initial private projection and
AuthoringAssessment uses the actual producer finalizer/validator. Workers and
provider adapters receive no Store connection, Home bearer, device transport,
activation API or arbitrary caller-selected callback. Their sole application
port is the selected input/response call. A trusted native adapter must separately
confine an external model and bound its network/process response before returning
it; a BEAM worker is not evidence of an OS sandbox. No adapter is installed by
default, and this contract qualifies no external provider or physical device.

## Installed provider and process boundary

Store option generation_providers is a proper list of at most 32 checked native
GenerationProvider values, default empty. A value contains exactly provider,
provider_sha256 and pid plus struct tag. Provider is the existing exact four-field
identity (id, model_id, adapter_sha256, locality). Its SHA uses the preparation
owner's provider domain/ordered array, never a PID or credential. PID is an
explicit alive local process supplied by trusted host composition; registered
names, remote PIDs, modules, callbacks, URLs and caller installation are refused.
The list is sorted/unique by provider SHA and PIDs are unique. Validate before
Store lock/SQLite. Malformed installation refuses invalid_store_options;
missing/dead selected provider returns generation_unavailable. No fallback.

An owned temporary worker calls exactly
GenServer.call(pid, {:generate_profile, document, output_bytes}, timeout_ms).
Document is private UTF-8; output_bytes is the current contract max_bundle_bytes,
at most 262144. Timeout is the remaining original attempt lifetime, never more
than 30000 ms. The provider receives no root/actor/operation ID, Home clock
origin, bearer, Store process or connection. Its reply is exactly {:ok, bytes}
or {:error, :unavailable}. Bytes must be nonempty valid UTF-8 and within the
output ceiling; all other replies become invalid_response with no raw diagnostic
or exception retained. Provider adapters must enforce the response ceiling at
their transport boundary, before constructing a BEAM reply.

The worker monitors Store and owns a monitored call helper plus a hard deadline.
Cancellation, Store death or deadline kills the helper and retires its reply
channel. Killing a caller cannot prove the remote model stopped or retract an
earlier export. Provider error/exit/timeout remains an unavailable/unknown
generation outcome. Worker processes are never restarted or retried. Only Store
accepts a response from the exact live worker and unguessable attempt token;
duplicate/foreign/late tokens are ignored. OTP diagnostic state redacts documents,
responses, credentials and private paths.

## Closed operation, input and historical codecs

Authority.start_authoring_generation/3 and Store.start_authoring_generation/3
take credential and exactly authority_epoch, operation_id, expected_revision,
preparation_operation_id, preparation_sha256, attempt, previous_operation_id
and repair_export. Epoch is positive signed-64; revision nonnegative signed-64;
IDs use Home's 1–128-byte ASCII grammar; SHA is lower hex64; attempt is integer
1..3. Attempt 1 requires previous_operation_id null and repair_export false.
Attempts 2/3 require the preceding attempt ID and repair_export true, explicitly
permitting its generated draft/diagnostics as feedback. No new instruction,
source, model, endpoint, credential, limit or caller-authored feedback is accepted.

GenerationAttempt encodes exactly compact ordered UTF-8 JSON, at most 2048 bytes:

```
["wotex-home.generation-attempt.v1",
 [epoch,operation,expected_revision,preparation_operation,preparation_SHA,
  attempt,previous_operation_or_null,repair_export]]
```

Historical decode uses AuthoringWire depth eight/4096 nodes/256 collection
members/4096-byte strings, integers only, exact re-encoding and no producer.
Malformed, float, struct, unknown field or contradictory initial/repair shape
refuses invalid_generation_attempt; resource excess refuses authoring_limit.
Original identity is principal/epoch/operation in the attempt namespace. Different
bytes at the same scope refuse authoring_operation_conflict.

The actual provider document is compact ordered JSON:

```
["wotex-home.generation-attempt-input@1", INITIAL_PROJECTION,
 null | [PREVIOUS_RAW_DRAFT_TEXT, PREVIOUS_ASSESSMENT_ARRAY]]
```

INITIAL_PROJECTION is the parsed canonical GenerationInput document, with its
exact selected bytes and contract. PREVIOUS_ASSESSMENT_ARRAY is the existing
AuthoringCandidate.encode_assessment representation, decoded as an array. It
includes only bounded existing producer diagnostics; no diagnostic is evaluated
as an instruction. Exact document size must fit the original selected
projection.limits.max_input_bytes (at most 1048576), including feedback. Exceeding
it refuses authoring_limit before any attempt is spent. Initial and augmented
document identities remain distinct: SHA-256 of the exact provider document is
handoff_sha256. Missing/corrupt prior draft bytes refuses before handoff.

Immutable receipt fields/slots are exactly authority_epoch, operation_id,
revision, input_sha256, preparation_sha256, attempt, handoff_sha256,
provider_sha256 and disposition handoff_reserved, at most 2048 bytes. A
reservation records possible export, not provider acceptance or observed model
completion. Receipt exposes no raw input, draft, diagnostic, credential or clock.

Settlement is separate immutable metadata. Result fields/ordered slots are
disposition, reason, draft_ref, bundle_ref and assessment. References are null
or [object_digest,first_revision]; assessment is null or the existing assessment
array. Dispositions are candidate, unavailable, invalid_response, unknown,
deadline_expired, cancelled, withdrawn or capacity. Candidate has reason null,
an owned draft reference and assessment; bundle reference is present exactly
when assessment has a bundle digest. Other dispositions have no references or
assessment and a null reason, except withdrawn reason is one of actor, epoch,
maintenance, policy, basis, source or store. Result is at most 131072 bytes;
noncandidate results at most 1024. No raw provider errors are retained.

Status returns exactly original (receipt), result (nullable decoded result),
result_revision (nullable), and state. A retained result determines state;
otherwise cancellation of its preparation yields cancelled, an old Store boot
yields unknown, expiry yields unknown, absence of the exact owned worker yields
unknown, and only a current owned worker yields running. It never implies that
the model actually accepted input. Original/status replay authenticates current
profile:manage but requires no producer, policy, provider, clock confidence or
custody bytes and cannot restart work.

## Current guards and transitions

**GA-01 — Resolve original first.** Authentication and preparation/attempt/import
integrity precede exact original lookup. Retry returns the original receipt
before CAS, source reads, current policy or provider work. Different authors
cannot read each other's originals. Current credential revocation blocks reads
and retries; historical bytes remain. A lost response never consumes another
attempt or renews time. A new operation cannot reuse a spent preparation/index.

**GA-02 — Guard and reserve every export.** New work requires writable active
normal Store, current profile:manage actor, epoch/global revision CAS, no
maintenance, matching actor-owned preparation/input SHA, same actual Store boot,
no preparation cancellation and now < its original expires_ms. Attempt must be
the next contiguous index and at most the original budget.attempts. Attempt 1
has no predecessor. A repair requires exactly the previous retained candidate
whose mechanics disposition is invalid; a compatible or uncertain/unavailable
predecessor refuses generation_attempt_unavailable. At most one unexpired,
unsettled attempt per author and 16 across the current Store boot are allowed;
conflict refuses generation_busy. Retained count ≤3072, input bytes ≤4 MiB and
result bytes plus 1024 reserved bytes per unsettled attempt ≤8 MiB; exceeding
these ceilings refuses generation_attempt_capacity before mutation.

Repeat the installed provider identity/PID liveness, original policy digest,
actor-specific exact source ranges/examples/remote consent and identical limits.
Require the original installed authoring basis and contract digest. Validate
owned reference kind/first revision before custody access, verify exact frames,
recompute GenerationInput and compare its SHA to the preparation receipt. For
repair, verify preceding owned draft frame and assessment correspondence before
constructing the feedback. No source or provider may be substituted.

Store samples started_ms from its actual nonnegative relative monotonic clock;
attempt expiry is min(preparation expiry, started_ms + original attempt_ms).
No overflow/renewal is allowed. Final reservation repeats current guards and
actual time, records authoring_generation_attempt_handed (entity attempt ID),
stores original receipt/document/digests and advances revision once. SQL failure
rolls back all history and sends nothing. Only after commit does Store start one
temporary owned worker; failure after commit is conservatively unknown, never
an invitation to retry the provider. No waiting provider call runs inside Store.

**GA-03 — Retain only timely current responses.** Before assessing or publishing
response bytes, repeat actor credential, epoch, maintenance, current selected
policy/provider identity, original authoring basis, preparation cancellation,
boot and both deadlines. Repeat at final transaction. Global revision CAS is
for handoff; append-only completion uses the actual current revision, so an
unrelated report need not invalidate generation. A changed relevant basis does.
Revocation/maintenance/policy/basis/source loss retains only withdrawn metadata;
cancellation retains cancelled; deadline retains deadline_expired. Late raw
responses are discarded and cannot affect another operation or activation.

For accepted bytes call AuthoringAssessment.assess(bytes, original current
contract, nil); no capture is fabricated. Preserve raw draft bytes and any exact
derived bundle in existing tagged custody. Their author-owned import originals
and the result are committed in one transaction. Import operation IDs are
ga:<SHA256(domain wotex-home.generation-object-operation@1, newline,
compact [principal,epoch,attempt_operation,kind])>. Kinds are draft or bundle.
Use existing import grammar, quota and journal mechanics with the current
revision for each import. Existing original conflicts refuse retention, never
overwrite an object/receipt. One final authoring_generation_attempt_settled
event retains result_document/result_revision. Failed multi-row SQL rolls back
all imports, settlement and revisions; synchronized orphan frames remain inert
under existing custody quota/collection rules. Missing capacity retires as
capacity without partial candidate metadata. No current authority is restored
from a mechanics report. Separate source review and fixture assessment remain
required by the parent before admission.

**GA-04 — Retire without replay.** Preparation cancellation commits its original
cancel history first, then retires matching workers and records cancelled attempt
metadata when writable. Cancellation after a settled candidate leaves the
candidate/result as history; it does not erase bytes. Revocation stops accepting
output, but cannot retract previously exported input. Owner/provider loss or
timeout retires the reply channel; unknown outcomes prohibit repair of that
preparation. Store boot/restore never resumes workers. Existing preparation
status/cancellation and all manual candidate contracts remain compatible.

## Schema, integrity and recovery

Schema **37** adds profile_authoring_generation_attempts with exactly principal_id,
authority_epoch,operation_id,input_document,preparation_operation_id,attempt,
handoff_sha256,receipt_document,boot_epoch,started_ms,expires_ms,revision,
result_document,result_revision. Primary key principal/epoch/operation; unique
principal/epoch/preparation/attempt; composite FK to its preparation; revision
and nullable result_revision unique FKs to authority_journal. Result document
and revision are either both null or both present. Input 1..2048 UTF-8 bytes,
receipt 1..2048, result 1..131072; checked integer attempt 1..3, nonnegative
started clock and expires > started. Migration validates actual schema36 then
adds an empty table; it spends no attempt or export consent.

Integrity requires exact historical operation/receipt/result encoding/hashes,
matching preparation SHA/provider/epoch/actor, contiguous indexes and valid
predecessors, expected_revision=handoff revision-1, same preparation boot,
expiry=min(preparation expiry, started+attempt_ms), bounded clocks and quotas,
matching handed/settled journal events/entities/counts, result_revision > handoff
revision and <= current revision, exact author-owned draft/bundle summaries and
assessment digests/basis. It requires no current provider, producer or files.
Corruption is corrupt_generation_attempts and fails Store closed.

Inclusive/database-only encrypted backups and full commitments preserve the new
exact table and existing owned frames. Normalized retention omits an empty
attempt table, preserving pre37 bytes. Nonempty scope includes handed rows with
revision<=source_revision and projects later settlement fields to null; owned
object/import rows retain their existing original revision filters. Quarantine
preserves history, never live workers, provider identity authentication or consent.

The explicit current Linux package/image/live-status and embedded Store probe
cohort becomes literal **37** after this reviewed migration. Exact historical
format-2 metadata for 28/35/36 remains verifiable but ineligible for new updates.
There is no cross-schema executable update/rollback. Historical test databases
must remove this future table before asserting an earlier actual schema.

## Acceptance and implementation entry

Before runtime code, freeze independent Python ordered request/receipt/provider
document/result vectors from existing two-family data. Use actual SQLite and
bounded scripted local GenServers to count observed calls and capture their exact
private input; fixtures supply no production confinement or physical evidence.

| Case | Requirements | Stimulus and falsifier | Level |
| --- | --- | --- | --- |
| GA-T1 | 01–03 | Both installed families, exact independent input/receipt/hash, same manual producer result, owned raw draft/bundle and original recovery; leaked source/bearer, automatic approval or extra call fails. | SQLite/process |
| GA-T2 | 01/02 | Permission/actor/epoch/CAS/maintenance, wrong/missing preparation/provider/policy/source/frame/basis/remote consent and forged native capability; refusal changes no revision/call count. | SQLite/process |
| GA-T3 | 01/02/04 | Lost reply/retry, changed original, spent index, concurrent same-author and 16 shared jobs, absent provider/files after restart; any replay/new deadline fails. | Process/restart |
| GA-T4 | 02–04 | Invalid draft then explicitly consented repair, exact prior draft/report feedback, three attempts/shared deadline, compatible/unknown predecessor and excess input/output; model-selected source or automatic repair fails. | Pure/SQLite/process |
| GA-T5 | 03/04 | Cancel, credential revocation, maintenance, changed policy/basis, provider/worker/Store death and exact deadline while blocked; late/duplicate/foreign output creates no candidate or effect. | Process/SQLite |
| GA-T6 | 01–04 | Prepare/settlement SQL faults, row/receipt/result/reference/journal tampering, actual36 migration/rollback, archive and normalized commitment; partial imports, fabricated live worker or changed historic commitment fails. | SQLite/archive |
| GA-T7 | 02 | Closed malformed/deep/duplicate/float/unknown wire and policy/provider mutations; literal Linux37 with legacy28/35/36 metadata verification and current refusal. | Pure/software |

Provider-specific network/process authentication/confinement, installed immutable
policy delivery, signed paired/native authoring and hardware qualification remain
separate delivery obligations; their absence leaves ordinary host generation
disabled. Consumer policy and attempt semantics belong here, not in ExBooking or
WoTEx. The consumed WPF.03 source remains the pinned
ba8ea373244ce57987f47a731b8eca3ccae9b45f; no producer replacement is required.

Process design follows the official [GenServer call and timeout contract](https://elixir.hexdocs.pm/1.19.5/GenServer.html#call/3).
Timeout/worker stop is interpreted conservatively as lost generation knowledge,
not proof that an external provider reversed an export or stopped its work.
