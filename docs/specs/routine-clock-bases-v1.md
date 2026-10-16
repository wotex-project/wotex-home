# Independent composed clock bases v1

Version: 0.1.3. Updated: 2026-10-16. Status: accepted target.
Owner: WOH.20 H20-04/06/07/08; WOH.04 temporal confidence; WOH.14 fences;
WOH.08/09/19 installed host/source qualification.
Implementation: pure canonical policy/request codecs, independent basis tokens,
exact receipt coordinates, anchored continuity and exclusive sample/UTC expiry
checks and the signed UTC owner's original-witness/matching-withdrawal APIs are
implemented. Native reference, private elapsed owner and Store capture remain planned.
Evidence: independent pure vectors and bound-Store UTC owner tests; complete clock
capture and installed RCB acceptance remain open. Legacy successful behavior is preserved.

## Result, ownership and compatibility

A composed delay or deadline uses one qualified boot-local elapsed basis.
Replacing or losing UTC confidence alone must not expire that elapsed basis,
reset a qualified elapsed edge or renew a deadline. Calendar/UTC windows still
require the complete current qualified UTC interval. Neither an OS wall clock
nor a receipt tuple qualifies either basis by itself.

WRO.02/03 and the producer's bounded continuation successor own explicit
Time@2/Run@2 semantics. Home supplies qualified coordinates and owns custody,
current Store scope, independent generations and irreversible withdrawal.
The [membership contract](routine-active-membership-v1.md) owns selected
definitions and producer-independent fences; the run journal must join clock
loss to original outcomes/spend. This clock contract creates no admission,
membership, trigger, retry or physical command.

The legacy schedule clock has one coupled generation, signed UTC exchange,
original age deadline and wall-versus-monotonic withdrawal. Preserve its closed
policy/request/record/package, ClockSample, ActivationClock and successful Time@1
behavior. RCB-01/08 deliberately strengthen observed rollback and failed-write
withdrawal: neither can restore expired confidence or receipt freshness.
Do not relabel a legacy receipt callback as an installed elapsed source or use
a legacy unqualified sample to claim the new qualification. Ordinary direct
controls and producer-independent history reads keep their existing clock scope.

## Dependencies and implementation entry

Inspected Home 524e7383: Schedules.ClockCodec/ClockLease/ClockOwner/ClockSample,
Durable.Store.ClockContext, Store's actual origin/boot and clock withdrawal;
WoTEx 973fb32c: public Time, Kernel, Edge, Collection and temporal adapters.
Home now consumes the consolidated continuation milestone 5fc17f4a; the clock
implementation adds no dependency change.

The [signed UTC source](schedule-clock-source-v1.md) and
[private owner](schedule-clock-owner-v1.md) already supply UTC custody. Composed
use additionally enforces the original lease's exclusive expiry at final
projection. A new qualified elapsed owner and native reference/lifecycle port
are concrete Home prerequisites; no such installed source exists merely because
BEAM supplies System.monotonic_time/1. Implement them under this contract,
with host-specific source qualification and independent software probes.

Before live adoption, freeze the executable elapsed policy/request/source/
snapshot schemas and independent arithmetic/hash vectors, complete clock-loss
journal encodings and Integrity/Backup joins, current snapshot/final-handoff
consumption and supported host lifecycle port. The remaining composed admission,
temporal source/consideration, journal and client contracts must be complete
before activation. Physical dispatch remains default-disabled; synthetic source
fixtures or a parsed qualification digest do not qualify an installed clock.

The new trusted native seams are specified here; none is a socket/model route:

| API | Contract |
| --- | --- |
| WotexHome.Host.ClockReference.read/1 | One bounded read from the explicitly selected native owner PID; returns the complete RCB-02 observation or a payload-free failure |
| WotexHome.Schedules.ElapsedClockOwner.start_link/1 | Trusted options store, operator, root, policy_file and reference_owner, plus optional standard name; no ambient source discovery or caller-selected callbacks |
| WotexHome.Schedules.ElapsedClockOwner.request/1 and approve/2 | Original operator only; both return {:ok, summary} with exactly state, request_file, request_sha256, source_id, reference_id, elapsed_generation and authority_granted false. state is pending/accepted/expired; approve takes the exact request digest |
| WotexHome.Schedules.ElapsedClockOwner.binding/1 and sample/2 | Bound Store only; binding returns its accepted seven-field binding, sample takes the complete current binding and returns exactly binding/elapsed witnesses as defined below |
| WotexHome.Schedules.ElapsedClockOwner.withdraw/2 | Bound Store only; irreversibly expires the exact expected elapsed token, without custody/clock/producer/SQLite work; repeat is unchanged and a different token cannot expire a replacement |
| WotexHome.Schedules.ClockOwner.routine_binding/2 | Bound Store only; takes the existing exact scope/now_ms context and returns scope, actual original lease started_ms and original sample after current lease/custody checks; old current/2 is unchanged |
| WotexHome.Schedules.ClockOwner.withdraw/2 | Bound Store only; irreversibly expires the exact expected six-field UTC scope, without clock/custody/SQLite work; stale different scope cannot expire a replacement |
| WotexHome.Durable.Store.routine_clock_binding/1 | Trusted bootstrap returns the actual seven-field elapsed binding for a healthy active writable Store; never a copied scope |
| WotexHome.Durable.Store.attach_routine_elapsed_clock/2 | Trusted host attaches the actual accepted owner PID, repeating binding/origin/current qualification; exact retry cannot replace it |
| WotexHome.Durable.Store.routine_clock_snapshot/1 | Trusted capture returns the closed full capture below or a typed error; no effect, source installation or authorization |
| WotexHome.Durable.Store.invalidate_routine_clock/2 | Trusted withdrawal takes exactly elapsed_token/utc_token, each the expected currently attached basis or null, at least one non-null; withdraw matching incarnations once, leave replacements untouched and treat repeated stale notices as unchanged |

Binding methods return {:ok, binding}; elapsed sample returns {:ok, witness}
with exactly binding and elapsed; UTC routine_binding returns {:ok, witness}
with exactly scope, started_ms and sample. Native reference read returns
{:ok, observation}. Store attach/withdraw returns :ok on success and exact
retry. The complete snapshot returns {:ok, capture}. None returns a raw clock
process state or private sealing descriptor. All failures are payload-free as
specified below; redacted process status omits paths/origins/nonce/native handles.

ClockOwner.routine_binding/2 retains the legacy native context's exact atom keys
`:scope` and `:now_ms`; scope is the complete six-field string-keyed UTC scope.
Its new witness has exactly string keys scope, started_ms and sample. It returns
the actual immutable lease start and original sample, after current custody,
scope and lease checks, never advanced bounds relabeled as an anchor. Wrong
callers return routine_clock_forbidden without source work. A malformed bound
Store context returns invalid_routine_clock; lost scope/lease/custody returns
routine_clock_unavailable and permanently expires that owner. No later status
can renew it. ClockOwner.withdraw/2 uses a 1000-ms call bound and validates only
the closed expected scope; malformed input refuses unchanged. A matching scope
consumes pending or accepted state; exact repeats and a different well-formed
scope return :ok unchanged. Withdrawal performs no runtime, clock, custody or
Store callback. The legacy current/2 route and its error vocabulary stay unchanged.

Store-internal observed loss uses the actual owner/monitor/basis identity; a
delayed notification must not withdraw a replacement owner. Host lifecycle
integration must invalidate both affected current bases and qualify event/source
ordering in its owning native port contract before implementation. Native backend
selection, native ABI/IPC and packaging belong to those host guides/contracts;
an arbitrary process implementing this message shape is not an installed source.

## Time coordinates and trust

The pure value layer has these native seams. All maps are complete plain
string-keyed claims. They perform no Store, clock, file, process, runtime or
custody measurement and cannot create the qualified capture scope. The owning
processes must supply actual current inputs and permanently withdraw invalid
incarnations under RCB-04/08.

| API | Exact result and checks |
| --- | --- |
| Schedules.RoutineClockCodec.policy_document/1, decode_policy/1 | Canonical RCB-03 bytes or complete thirteen-field policy map |
| Schedules.RoutineClockCodec.request_document/1, decode_request/1 | Canonical RCB-04 bytes or complete fourteen-field request map; signed raw fields remain decimal text |
| Schedules.RoutineClockCodec.binding/1 | Exact seven-field RCB-06 binding with canonical signed origin |
| Schedules.RoutineClockCodec.utc_scope/1, utc_sample/2 | Exact six-field supplied signed UTC scope and original qualified ClockSample under that scope |
| Schedules.RoutineClockCodec.observation/2 | Complete RCB-02 native observation under the supplied policy; source/reference/digest, raw ordering and sample width agree |
| Schedules.RoutineClockCodec.elapsed_token/1 | Reconstruct the full request, replace only its format with routine-elapsed-basis@1, then hash the canonical ordered array |
| Schedules.RoutineClockCodec.utc_token/4 | Scope, original qualified ClockSample, actual exchange start and native observation produce exactly the RCB-06 UTC token; scope/boot/generation must agree |
| Schedules.RoutineClockMath.coordinate/2 | Raw primary and raw origin are signed-64 integers; subtract exactly, returning a nonnegative signed-64 coordinate |
| Schedules.RoutineClockMath.continuity/4 | Policy, initial anchor, previous successful observation and new observation; exact identity and initial/previous/new interval relations pass, returning :ok |
| Schedules.RoutineClockMath.freshness/4 | Binding, policy, new native observation and final coordinate return exactly sampled_ms/expires_ms under exclusive RCB-05 expiry |
| Schedules.RoutineClockMath.utc_interval/6 | Original sample, scope, exchange start, native lifecycle raw start, actual raw origin and final coordinate return the advanced {lower, upper}; preserve exclusive original expiry and the strict lifecycle join |

All values return {:ok, result} except continuity's :ok. Private shape failures
return invalid_routine_clock; exceeded byte/string/collection/depth or signed-64
arithmetic bounds return routine_clock_limit. A structurally valid but different
source/identity, negative elapsed result, nonqualified UTC, rollback, interval
divergence or failed lifecycle join returns routine_clock_unavailable. Only a
valid sample whose original expiry has been reached returns
routine_clock_snapshot_stale. No value is clamped, renewed or partially returned.
Native observation endpoint/start fields are integers; request/projection raw
coordinates remain canonical signed text. Native structs and numeric floats
refuse. The strict private decoder remains producer-independent.

`priv/profiles/routine-clock.schema.json` closes the policy, request, binding and
native observation shapes. `test/fixtures/routines/clock-bases.json` and its
standalone Python generator freeze full canonical documents/tokens, exact
coordinates and conservative interval arithmetic before production code. These
entry values qualify no installed reference, custody or host lifecycle source.

**RCB-01 — Keep the receipt coordinate exact.** The elapsed coordinate remains
the Store's actual BEAM monotonic-millisecond reading minus its immutable
clock_origin; epoch is its random clock_epoch. Compute the subtraction exactly
before range checking, including a negative raw VM origin and a 65-bit
intermediate. A qualified reading must be nonnegative signed-64 and nondecreasing.
Do not clamp a negative/regressed reading to zero, copy processing time into an
original receipt or change the origin while retaining the same boot epoch.

This preserves the existing external report clock relation: original report
microseconds project by floor division into the same Store receipt coordinate.
The native reference is an independent continuity check; it does not replace
that coordinate, select a different receipt origin or supply UTC. Existing
successful legacy/manual receipt behavior is preserved by this successor.

Actual primary-clock rollback or same-boot origin mutation is a receipt-basis
fault, stronger than UTC/reference loss. Fence timed Store writes/dispatch and
require a new Store boot/receipt epoch; do not approve a replacement elapsed
owner under the old receipt epoch. Otherwise an expired native/external report
could become fresh again when the coordinate moves back into its old lifetime.
The Store's receipt observer must retain the highest actual primary reading
within that boot. Existing successful legacy reads/encodings remain unchanged;
rollback must not be hidden by the legacy helper's zero clamp.

Store maintains a separate positive elapsed_generation, initially 1 for a new
Store boot. It is independent of legacy temporal_clock_generation, which remains
the UTC owner's generation for this join. Each observed loss of an attached
qualified elapsed basis detaches it and increments elapsed_generation exactly
once. Repeated reads with no owner do not consume generations. Counter exhaustion
records unavailable status; it cannot wrap/reset or project a new qualified Time.

**RCB-02 — Qualify an actual reference/lifecycle source.** Trusted host
composition selects one explicitly supervised native reference owner. Neither
policy data nor a user request chooses a module, PID, clock function, native
path or network source. The port returns a complete plain observation with
exactly source_id, reference_id, source_digest, reference_epoch,
reference_started_ms, lifecycle_generation, lifecycle_started_ms,
primary_lower_ms, primary_upper_ms and continuous_ms.

Controller-host supervision owns that reference process independently of the
approval client. Closing the client must not normally stop the source or valid
controller-owned work; genuine source death still withdraws qualification.

Source/reference IDs use Home IDs; source_digest is bare lowercase hex64 of the
actual qualified source implementation/cohort descriptor. reference_epoch is
fresh lower hex32 per source-owner incarnation, never a private hardware ID.
lifecycle_generation is positive signed-64, increasing on suspend/resume,
source reset or loss of lifecycle certainty. It cannot reset under the same
reference_epoch. reference_started_ms is that source incarnation's immutable raw
primary start; lifecycle_started_ms is the latest generation boundary in the
same raw clock. Both are signed-64, with reference_started_ms <=
lifecycle_started_ms <= primary_lower_ms. They never move backward under the
same source incarnation. continuous_ms is a nonnegative signed-64 host continuous-clock
coordinate unaffected by UTC setting/correction. The primary interval contains
the actual reference-read instant in raw BEAM monotonic milliseconds; endpoints
are ordered signed integers in -9223372036854775808 through +9223372036854775807.
Its span is at most the selected maximum_sample_ms. Return unavailable rather
than a partial, cached or caller-authored observation.

The reference owner reads both clocks itself, bounding the continuous-clock
read between actual primary readings. The elapsed owner surrounds the port
call with its own primary readings and requires the complete returned interval
inside those bounds. Every new interval begins at or after the prior interval's
upper endpoint; reference time cannot regress. Source identity, reference epoch
and lifecycle generation must remain exact. A wall timestamp cannot occupy
continuous_ms. The host-specific implementation must establish those semantics,
including lifecycle ordering; the schema cannot establish them.

Each port request has one 1000-ms overall monotonic deadline, including mailbox
delay. At most one request is outstanding per elapsed owner. Timeout, source
death, malformed reply, changed identity or inability to obtain a fresh bounded
pair permanently expires that elapsed owner. No retry, background replacement,
detached probe or cached last-good value follows. The source owns and cleans up
its native observation resources; the elapsed owner owns no transport worker.

## Private elapsed policy and one-time approval

**RCB-03 — Install a purpose-specific policy.** A trusted operator installs one
immutable 0400 policy under canonical private 0700 custody, outside Store/backups.
Its request root is a separate purpose root from the signed UTC owner, canonical,
nonsymlink, mode 0700 and with fewer than 64 children before construction. Reuse
the existing sealed private-file/ancestor identity checks; identical bytes at a
replacement inode do not restore trust. Never delete other requests to make room.

Policy wire is this exact compact UTF-8 array, in order:

    ["wotex-home.routine-elapsed-policy.v1", source_id, reference_id,
     procedure_ref, qualification_digest, runtime_digest, source_digest,
     approval_timeout_ms, maximum_sample_ms, maximum_discontinuity_ms,
     drift_ppm, qualified_run_ms, monotonic_policy, suspend_policy]

IDs use Home's 1–128-byte ASCII grammar; the three digest fields are bare hex64.
approval_timeout_ms is 1–60000; maximum_sample_ms is 1–1000;
maximum_discontinuity_ms and drift_ppm are 0–1000; qualified_run_ms is exactly
86400000. monotonic_policy is invalidate_on_discontinuity and suspend_policy
is invalidate_on_lifecycle_change. No fields/defaults or automatic alternate
policies exist. Arrays have at most sixteen members, nesting at most three,
4096 bytes total and 128-byte strings; encoded integers are nonnegative
signed-64 with canonical decimal syntax. Reject objects, floats, duplicate/
expanded fields, unsupported versions, noncanonical bytes and UTF-8 errors.

The policy qualifies the selected relative clock for any supported finite run
horizon up to 24 hours while that exact runtime/source/custody/lifecycle remains
valid. It grants no UTC anchor. It has no whole-owner age lease and no implicit
UTC-style renewal: fresh source samples have the strict lifetime below, and
any discontinuity permanently ends this incarnation. That trust assumption
must be established by the installed host procedure, not inferred from file
mode, a fresh sample, operator approval or a passing software test.

runtime_digest is the complete actual Home application inventory from
RuntimeArtifacts.digest([:wotex_home], "wotex-home.routine-clock-runtime@1").
No module filtering or loaded-code fallback is allowed. source_digest separately
binds the actual native reference/lifecycle implementation and dependencies
measured by trusted host composition. A pure descriptor or source's own claim
cannot replace that measurement. Both must match the policy at construction,
approval and every current sample, surrounded by fresh custody checks.

**RCB-04 — Bind approval to the actual Store boot.** The elapsed owner is a
host-owned process with no SQLite connection or operator bearer. At construction
only, obtain the actual active writable Store's deployment/owner digests,
authority epoch, clock_epoch, elapsed_generation and clock_origin through its
trusted private binding. Monitor that Store, the native reference owner and the
independent approval PID.
Never accept a caller-created scope or use a database-restored clock origin.

Create a fresh 32-byte random challenge nonce and one new private request file.
Its exact ordered array is:

    ["wotex-home.routine-elapsed-request.v1", deployment_id, owner_id,
     authority_epoch, store_boot_epoch, elapsed_generation, runtime_digest,
     monotonic_origin_ms, policy_sha256, source_digest, reference_epoch,
     reference_started_ms, lifecycle_generation, lifecycle_started_ms,
     challenge_nonce]

deployment_id, owner_id and digests are bare hex64; boot is the actual Home ID.
monotonic_origin_ms, reference_started_ms and lifecycle_started_ms are canonical
signed decimal text within signed-64 (no plus, leading zeroes or negative zero),
preserving raw VM coordinates. challenge_nonce
is canonical unpadded base64url of exactly 32 bytes. Other counters are positive
signed-64. Use the policy's same 4096-byte/array/nesting/string bounds. Record
the original request-start elapsed coordinate and strict approval deadline.
Files preserve exact root/path/descriptor/content/ancestor seals.

Only the original approval PID may approve the exact request digest before
the original deadline. This is a trusted local decision to use the installed
qualified relative-clock policy, not an uploaded timestamp or signed UTC proof.
No signature or UTC record is manufactured for it. Approval revalidates the
complete original binding, custody/runtime/source checks and a current native
reference pair, including the original deadline after those checks.
Exact accepted retries return the same basis and never reset its anchor/deadline.
Wrong digest/caller refuses without granting authority; invalid original approval,
expiry or custody/source failure consumes that challenge permanently.

Only the bound Store may attach or sample the accepted elapsed owner. Attach
requires the exact original Store/origin/scope and no different currently attached
owner. Exact attach retry retains the original basis; replacement requires
withdrawal and a fresh challenge under the advanced elapsed generation. During
a Store sample the owner uses the Store-supplied complete current scope and its
retained binding. After construction it never calls back into Store: current
scope is checked by Store at attachment and supplied afresh on each sample.
This avoids an approval/sample/attachment deadlock with the waiting writer.
Approval/client exit after acceptance does not stop a valid clock owner. Exit
before approval expires the challenge. Store death stops it; restart always
needs a new boot binding and approval. Historical request files never recreate it.

## Continuous qualification and stable identities

**RCB-05 — Check both rolling and original anchors.** Retain the initial
accepted reference pair and latest successful pair. For each new pair compare
both against the new observation, retaining exact reference/lifecycle identity.
For old primary interval [a0,b0], new [a1,b1], and reference delta d, require:

    d >= 0
    a1 >= b0
    allowance = maximum_discontinuity_ms + ceil(d * drift_ppm / 1000000)
    d - allowance <= a1 - b0
    b1 - a0 <= d + allowance

Compute with exact integers and check final range/overflow. These comparisons
require the entire possible primary delta interval inside the allowed reference
delta interval. Do not compare a midpoint, substitute UTC, hide a regression
with zero or reset the original anchor after each successful status read.
Pair sampling width counts toward the allowance; a too-wide pair refuses rather
than narrowing uncertainty. Source and custody failure is irreversible even
when old bytes/values later return.

At Store projection time n, the original pair's primary_upper_ms minus the
actual Store origin is sampled_ms. Require sampled_ms <= n and
n - sampled_ms < maximum_sample_ms. Qualification does not survive exactly at
that expiry. Receipt of the owner reply or processing time cannot renew it.
The owner may obtain a genuinely new pair on a new sample call while its
incarnation remains qualified. Periodic checks are at most once per second;
every Store request independently repeats all checks. Timer delay never extends
sample life or permits use of the previous last-good value.

A valid fresh source pair can become stale while the capture caller waits or
performs other checks. Refuse that capture without Time, new effects or deadline
renewal. This orchestration staleness alone does not revoke a still-qualified
source incarnation or advance elapsed_generation; a later explicit capture
requires a genuinely new pair. Native source failure/timeout, invalid pair,
identity/continuity loss and custody/runtime changes still expire the owner
irreversibly. Do not turn those losses into a retryable stale-capture result.

Define C as compact recursively sorted-key UTF-8 JSON and H as bare lowercase
SHA-256. The elapsed generation token is `home:elapsed:` plus H(C of this exact
ordered array):

    ["wotex-home.routine-elapsed-basis@1", deployment_id, owner_id,
     authority_epoch, store_boot_epoch, elapsed_generation, runtime_digest,
     monotonic_origin_ms, policy_sha256, source_digest, reference_epoch,
     reference_started_ms, lifecycle_generation, lifecycle_started_ms,
     challenge_nonce]

The token binds the approved incarnation. It excludes UTC and current pair/time
values, so successful fresh sampling does not change it. It is an integrity
commitment, not a caller-authenticatable permission token. Only actual private
owner/Store checks establish qualification.

## UTC join and the complete Time alternative

**RCB-06 — Use current UTC without coupling generations.** Obtain UTC only
through the actual signed owner/current scope, repeating its existing custody,
signature/lease and runtime checks. Advance the original ClockSample at final
Store coordinate n. In addition to its existing validation, require
n < sampled_monotonic_ms + maximum_age_ms with checked addition. This preserves
ClockLease's exclusive original start-plus-age expiry; a reply just before
expiry cannot authorize a later projection at the endpoint. Keep legacy
ClockSample.advance/4 behavior unchanged outside this successor.

For composed use the actual UTC owner must expose its original signed-exchange
start as well as original sample/scope. Require that start in Store coordinates
strictly after the current native reference's lifecycle_started_ms minus the
actual Store origin. This includes source incarnation replacement. A legacy UTC
owner without this fresh lifecycle join is unavailable for composed UTC; it
cannot be promoted by stamping an old lease with the current lifecycle value.
Obtain a fresh signed exchange when that boundary is not met. UTC-only renewal
under an unchanged elapsed/reference incarnation leaves the elapsed token exact.

The UTC token is `home:utc:` plus H(C of this exact ordered array):

    ["wotex-home.routine-utc-basis@1", complete_legacy_utc_scope,
     source_id, qualification_digest, sampled_monotonic_ms,
     utc_lower_ms, utc_upper_ms, maximum_age_ms, drift_ppm,
     qualification_started_ms, reference_epoch, lifecycle_generation,
     lifecycle_started_ms]

complete_legacy_utc_scope has exactly deployment_id, owner_id, authority_epoch,
store_boot_epoch, clock_generation and runtime_digest from the actual signed
owner. Use the complete original sample, not its later advanced interval.
qualification_started_ms is the actual original exchange start in nonnegative
Store coordinates; lifecycle_started_ms is canonical signed raw decimal text.
The anchor stays unchanged through its signed lease; a new source/lease/scope
gets a different token even if its current UTC interval happens to be equal.
No policy/lease is renewed by this hash or an elapsed sample.

Store samples its own receipt coordinate around owner calls, revalidates both
against the actual same boot and uses one final n for elapsed and UTC advancement.
One capture has a 10000-ms overall monotonic budget, no implicit retry and no
more than one call to each clock owner; the existing UTC call retains its
5000-ms timeout and the native reference call its 1000-ms deadline. Check budget
before/after every callback. Order UTC before the final elapsed sampling where
both are needed; validate every original sample again at final n.
An optional UTC read that makes the elapsed sample too old refuses the complete
capture; never reuse the old elapsed pair. If elapsed is qualified but UTC is
unavailable, return the explicit absent-UTC alternative rather than inventing
point time. UTC-only means no elapsed runtime/source/custody/lifecycle changed.

The complete generic Time has exactly:

| Member | Value |
| --- | --- |
| format | wotex.routines.time@2 |
| epoch | Actual Store.clock_epoch |
| elapsed_ms | Final qualified nonnegative Store coordinate n |
| clock_generation | Approved home:elapsed: token |
| utc_generation | Current home:utc: token, or explicit null |
| utc_low_ms, utc_high_ms | Full current advanced interval, or both null with absent UTC |

Mixed UTC nullability, null required elapsed fields and omitted fields refuse.
Validate through public Time.new/2/to_map/2.
No Time@1 fallback exists for composed runs. The later complete snapshot retains
the full Time and both actual clock commitments, original sample coordinates,
expiry and current guard revisions; an unqualified partial clock cannot form a
positive current certificate. A pure valid Time map establishes none of this trust.

Successful Store capture returns {:ok, capture} with exactly format
`wotex-home.routine-clock-snapshot@1`, scope qualified_composed_clock_input_only,
binding, time, elapsed, utc and utc_reason. binding has exactly deployment_id,
owner_id, authority_epoch, store_boot_epoch, elapsed_generation, runtime_digest
and monotonic_origin_ms, with the types/actual values above. time is the complete
Time@2. elapsed has exactly policy_document, policy_sha256, source_id,
reference_id, source_digest, reference_epoch, reference_started_ms,
lifecycle_generation, lifecycle_started_ms, challenge_nonce, anchor, last,
sampled_ms and expires_ms. The two raw source-start fields use canonical signed
decimal text. policy_document is
the original canonical policy bytes; policy_sha256 is raw SHA-256 of those bytes.
The request digest is likewise raw SHA-256 of its exact canonical bytes.
anchor and last each have exactly primary_lower_ms, primary_upper_ms and
continuous_ms; preserve raw signed primary endpoints as canonical decimal text
in this JSON projection and the nonnegative reference coordinate as an integer.
sampled_ms is last.primary_upper_ms minus the actual origin; expires_ms is
sampled_ms + maximum_sample_ms, with checked signed-64 output.

utc is null or exactly scope, sample, expires_ms, qualification_started_ms,
reference_epoch, lifecycle_generation and lifecycle_started_ms, retaining the complete
original six-member signed-owner scope and original closed ClockSample.
expires_ms is sampled_monotonic_ms + maximum_age_ms, checked for overflow.
Its native reference/lifecycle fields must exactly equal elapsed's fields.
utc_reason is null with qualified utc, otherwise temporal_clock_unavailable.
Recompute both tokens and current intervals from these exact originals; do not
serialize advanced UTC bounds as a new anchor. The two runtime digests use their
own purpose domains; both require actual current inventories, not equality of
their different domain-separated hashes.

Capture is bounded to 65536 compact UTF-8 JSON bytes, depth 16, 8192 nodes,
128-member collections and 8192-byte strings, counting every embedded copy.
Only Store constructs a qualified capture from actual private owner replies.
Parsing/re-hashing a copy cannot establish current qualification or guard the
next handoff. No socket/API accepts clock captures, providers or qualification
flags from callers. The complete active-set certificate has its own later scope.

Equal clock tokens do not establish that an earlier decision is still current.
Elapsed progress can unlock a delayed/waiting member or expire a Fact/deadline
between calculation and commit, including a conflicting proposal absent from
the earlier batch. The complete-cut contract must bind a conservative validity
region for every supplied member and freshly prove final Time remains inside
it, along with unchanged facts/prior/authority. Both negative and positive
eligibility, source-time qualification, window edges and all pending proposals
must be covered. A check of selected effect deadlines alone is insufficient.

The generic successor is now accepted in WoTEx at
`docs/packages/wotex-routines/specs/verified-decision-v1.md` version 0.1.3.
It defines Wotex.Routines.Transition.verify/8, target Wotex.Routines.Decision
point/current-decision APIs, full supplied negative/positive membership and
canonical elapsed/UTC cells. Inspected source `83055631` implements the public
direct point checker: 113 affected tests verify 1,152 complete point transitions
and 72 edge relations with all eight forbidden forward seams disabled during
proof; six isolated native mutants fail through assertions with zero errors.
The internal time-cell foundation remains separately checked. Complete
Collection@2/Decision, independent arbitration verification, full VD acceptance
and both extracted consumers remain prerequisites before Home's consuming cut
code. This evidence is not selected by Home's existing dependency pin.

Home must use the completed public seam rather than calling that hidden
component, duplicating the kernel's time semantics or calculating a Kernel
transition inside the Store writer. The journal/cut contract must separately
authenticate any retained inert point transition and preserve its original
starts; current effects require a fresh valid complete cut. Repeatedly rebasing
a short delay to obtain a fresh certificate changes its meaning and may prevent
it from ever completing. Outside-writer replay still needs a final validity
guard. This owned producer addition selects no new Home dependency; clock capture
alone supplies neither the certificate nor permission.

**RCB-07 — Apply each basis to its declared semantics.** Elapsed delays, wait/
step/run deadlines, countdown windows, receipt freshness and elapsed edge
qualification use the stable elapsed token/epoch and n. Deadline addition must
fit signed-64; a run cannot start by wrapping or saturating its duration.
UTC loss/replacement alone does not renew/expire those operations. Facts whose
installed contract requires trusted source UTC age still become unknown when
the current qualified full interval is missing/incompatible, resetting an edge
where that input contract requires it.

Elapsed milliseconds are the qualified primary clock's coordinates. Any claim
about real-time accuracy must propagate its declared drift/discontinuity,
sampling and dispatch bounds through the owning analysis/host qualification;
Time@2 alone supplies no millisecond physical accuracy. Frozen models omitting
time progress, basis loss or this policy cannot provide composed admission.

UTC due/window descriptors bind the UTC token, source revision and exact timezone
data separately from elapsed identity. Require the entire current interval
inside the immutable [due, due + late_window) at preparation, reservation,
queue, claim and final handoff. New UTC basis expires old live UTC-window runs;
absent confidence/outside window expires their unsent continuation. No correction
changes an old due instant, extends a late window, creates a replacement original
or rewinds considered watermarks. Later future enumeration must use current
qualification and the retained no-repeat/skip boundary. No catch-up is inferred.

## Irreversible loss and recovery

**RCB-08 — Withdraw the actual changed basis.** The following outcomes are
independent of whether the producer can currently decode a Run:

| Cause | Elapsed basis | UTC basis and unsent work |
| --- | --- | --- |
| UTC correction, signed UTC lease expiry or UTC-owner/custody loss only | Retain exact qualified token/origin/deadlines | Withdraw UTC; expire old UTC-window work; source-age-dependent facts become unknown |
| Elapsed owner/reference death, primary/reference regression/divergence, lifecycle generation change or elapsed custody/runtime loss | Permanently detach; advance elapsed_generation once | Fence all composed unsent continuation; separately withdraw UTC if its scope/continuity is also lost |
| Trusted suspend/resume or lifecycle certainty loss | Native reference generation changes before a fresh sample can qualify; old elapsed basis expires | Withdraw UTC through its existing wake fence; do not resume a missed old window |
| Actual Store restart, authority/owner transfer or changed origin | New boot/scope; old basis unavailable | No restored clock confidence; copied work remains fenced/quarantined |

Actual primary rollback/origin mutation requires the stronger receipt-basis
health fence in RCB-01, not a new approval under the same receipt epoch.

Clock loss is an external observation and cannot roll back to qualified because
a SQLite barrier write failed. Detach/invalidate the volatile basis first. Use
the journal's producer-independent Home fence to record affected original
dispositions/spend. If it cannot commit, keep clock confidence withdrawn, fence
Store writes/dispatch through its health gate and report the error. Do not
restore the old owner/generation state or replay a packet after rollback.
Repeated handling of the same lost incarnation does not consume more generations.

Store withdrawal also consumes the old owner's accepted state through its
Store-only withdraw seam. That operation has a 1000-ms call bound and performs
no source/custody reads; if the owner cannot respond, keep it detached and stop
that owned clock process. No owner callback or cleanup wait may restore confidence
or delay write/dispatch fencing. Private request files remain bounded historical
custody; they are not source authority and are not replayed by a supervisor.

Recorded elapsed loss never becomes mere condition unknown that later resumes
the same unsent run under a fresh qualification. A new approved elapsed basis
has a different token; old original/deadline/outcome and spend remain history.
Started/handoff/unknown effects retain their original uncertainty/exclusion.
Their qualified observations may refine outcome under the journal contract,
without a new send or a clock-derived causation claim.

Default is no elapsed owner and no qualified composed Time. Current source/
clock absence blocks new composed effects, not pure authoring, original/history
reads or unrelated ordinary storage. Cancellation/revocation/fencing must remain
available without a current clock/producer. No status, client retry, saved policy,
request file, backup or old signed UTC package can approve a new incarnation.

Private codec/shape refusal returns invalid_routine_clock; byte/node/string/
integer overflow returns routine_clock_limit; wrong operator/Store returns
routine_clock_forbidden. A different request digest or attempted live-owner
replacement returns routine_clock_conflict. Missing/withdrawn/currently invalid
owner, source, scope or qualification returns routine_clock_unavailable.
Capture budget or post-sampling freshness exhaustion returns
routine_clock_snapshot_stale, retaining a still-valid incarnation as described
above. UTC-only unavailability returns the explicit null-UTC capture when the
elapsed witness remains current. SQL/history damage retains the owning health
error; it must not be normalized into transient clock unavailability. No error
echoes a caller document, provider exception, private path or native handle.

## Acceptance

Normal planned trace: approve the actual elapsed source for one Store boot,
start a manual delay, then replace the signed UTC basis. Elapsed token/start/
deadline stay exact and the delay advances only at its original elapsed threshold;
a separately running UTC-window original expires. Adverse planned trace: a wake
changes the native lifecycle generation between preparation and final handoff.
The final source check withdraws elapsed/UTC and fences unsent originals. A failed
barrier write does not restore qualification or permit transport. These are
requirements, not executed installed evidence.

| Case | Requirements | Setup and expected observation / falsifier | Evidence level |
| --- | --- | --- | --- |
| RCB-T1 | 01–04 | Independent complete policy/request/hash vectors include negative raw origin, maximum bounds, 65-bit subtraction and canonical nonce; altered scope, fields, floats/overflow or cross-purpose UTC/recovery documents refuse | Independent codec |
| RCB-T2 | 02, 05 | Independent interval-delta/ceiling vectors cover zero drift, exact/one-over allowance, sampling span, reference/primary rollback and cumulative small changes; both rolling and original-anchor checks agree | Independent arithmetic/native |
| RCB-T3 | 03–05 | Actual private root/file/ancestor replacement with identical bytes, runtime/source drift and restoration, wrong operator/Store, strict approval deadline, retry and client exit retain one irreversible challenge/basis | Files/process/Store software |
| RCB-T4 | 01, 04–06 | Actual Store captures same receipt origin with fresh source pairs; repeated captures retain elapsed token, exact UTC absence stays null, delayed owner/UTC reply crossing sample or lease expiry refuses. Orchestration-only staleness permits a fresh capture with unchanged owner/token; actual basis loss does not | Actual Store/controlled sources |
| RCB-T5 | 05–07 | UTC-only correction/lease/source replacement during elapsed delay/countdown/edge preserves original elapsed identity/deadline; full Time@2/Run@2 persists. Required source-UTC-age facts still become unknown | Public kernel/Store software |
| RCB-T6 | 06–07 | Same-instant new UTC anchor changes token; old UTC run/cursor expires, new projections retain original due identity, backward/forward correction never repeats considered work or catches up | Independent temporal/Store software |
| RCB-T7 | 02, 04, 08 | Reference death/restart, changed source/lifecycle generation, timeout and suspend/wake before commit/claim/handoff withdraw once; returned old source/custody cannot resume the old run. Old UTC exchange predating the new lifecycle cannot acquire a fresh stamp | Actual process/Store/controlled worker |
| RCB-T8 | 05–08 | Inject barrier SQL failure after observed loss; volatile confidence stays unavailable, writes/dispatch fence and old owner cannot reattach. Later recovery retains exact charges/unknowns without resend | Faulted SQLite/source software |
| RCB-T9 | 01, 07–08 | Real Store restart/authority transfer/quarantined restore with pending delays, UTC windows, receipts and copied policy/request files creates no confidence, baseline, original or root | Retained Store/recovery software |
| RCB-T10 | 01, 06–08 | Missing owner/producer, generation exhaustion and malformed Time@2 cannot select Time@1 fallback; UTC-only loss preserves ordinary controls/legacy clock bytes. Actual primary rollback cannot requalify under the old receipt epoch or make expired reports fresh | Software regression |
| RCB-T11 | 02–05 | Actual host source identity, paired-clock sample bounds, continuous reference, lifecycle ordering, sleep/wake, drift over every supported run horizon and private custody satisfy the selected procedure on each supported OS/board | Installed host qualification |
| RCB-T12 | 06–08 | Qualified device/firmware, host scheduling load and real handoff/readback across correction/suspend/restart retain original windows, partial/unknown outcomes and no resend | Physical cohort qualification |

Before implementation, retain independent fixtures/generator source and exact
expected bytes/arithmetic, then actual commands/cohort/results. RCB-T11/T12
cannot be discharged by a scripted source, model, compiler or native build.
These cases contribute to H20-T3/T5/T6/T7/T8/T9; complete membership, snapshot,
journal/admission and device acceptance remain independently required.
