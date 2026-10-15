# WOH.20 — Reusable routines and the Home consumer

Version: 0.1.27. Updated: 2026-10-15. Status: accepted target.
Implementation: partial, restricted comparison, pure timezone/calendar joins, bounded temporal runtime adoption, explicit kernel proposal proof and its initial invocation join, inert external reader-to-Fact projection and measured native external-input review context.
Evidence: finite software subset; full acceptance cases remain open.

## Purpose, ownership and current subset

Home must consume a reusable, optional WoTEx routine kernel without exporting
household policy or creating a second execution authority. The same kernel
must also support a consumer with no household vocabulary. A routine is an
immutable composition of typed triggers, conditions and steps; a run is one
durable execution of that exact revision; a step proposes a bounded transition
or effect. A schedule defines temporal triggering, not the routine itself.

WoTEx owns the generic capability/behaviour basis, source/IR and deterministic
kernel under planned WRO.01–WRO.04. ExBooking owns generic recurrence enumeration
under SP.08. Home owns enrollment, authors/grants, policies, Store transactions,
clock trust, supervision, dispatch, API and presentation. These producer
contracts do not give a library a database, device channel or credentials.

The existing executable admission remains one unconditional explicit Boolean
ordinary-Light effect, causal budget one, zero cooldown and ownership 1 ms.
Pure wider grammar, provided-set arbitration, temporal calculations and the
opt-in delivery owner are narrower software mechanisms, not universal admission.
No dependency pin, old loader, physical dispatch default or qualification is
changed by this target. Refpath and booking wrappers are outside this build track.

## Required contracts

| Owner | Behavior consumed | Required failure behavior |
| --- | --- | --- |
| WRO.01, WoTEx prospective routines package | Typed installed behaviour, observation and effect-domain basis; TD/TM and Continuum reuse | Unknown required semantics reject; description supplies no authority |
| WRO.02 | Closed source, complete canonical IR, bounded pure transition decisions | Unsupported construct, invalid native value or exceeded bound returns a typed refusal |
| WRO.03 and ExBooking SP.08 | Original recurrence occurrences and consumer-host temporal seam | Missing producer or changed time-zone basis blocks that temporal profile |
| WRO.04 and WOH.07 | Model scope, independent correspondence and separate result axes | Unsupported/inconclusive analysis cannot admit work requiring proof |
| WOH.18 | Exact bytes/projection, reviewed selection, retained closure and trust generations | Replacement/revocation fences dependent use without widening grants |
| WOH.14/15/16 | One writer, immutable scoped operations, handoff and quarantined recovery | Stale authority refuses; uncertain handoff never becomes a retry instruction |

The producer paths are `wotex/docs/packages/wotex-routines/specs/` and
`ex_booking/docs/specs/SP.08-occurrence-enumeration.md`. Their catalogues/task
list identify current implementation. Home consumes documented public APIs from
one coherent selected revision set; it does not call a sibling's hidden module.

## Requirements

**H20-01 — Description and data.** TD/TM 1.1 remain WoTEx's affordance foundation.
An inert mapping selects an installed binding and semantic contract; it cannot
author endpoints, commands, grants, timers or code. Raw bytes, semantic
projection, source/IR, implementation build and qualification are separate
identities. Reuse Continuum's compatible exchange values; a missing field needs
a producer contract addition, not an alternative receipt store. Existing
portable-profile v1 bytes and approvals retain their original meanings.

**H20-02 — Kernel and host.** Kernel input consists of immutable program,
explicit event, revisioned snapshot, time basis and retained run state. Output
is a finite ordered transition proposal or typed error. Loading or evaluating
the pure kernel starts no process, reads no clock/environment/files and performs
no transport or Store access. A separately chosen driver has consumer-owned
startup, capacity and retirement. Authority calls the kernel outside the writer;
Store revalidates the complete proposal basis inside the committing transaction.

**H20-03 — Source and bounded profiles.** One canonical source/IR feeds runtime
evaluation and model projection. Existing v1 formats reject new constructs.
The successor names its supported semantic profile; unsupported features never
compile to no-ops. Home's first composed target has at most 64 expanded nodes,
four nested routine levels, four parallel branches, sixteen possible effects,
sixteen waits and a run duration of at most 24 hours. Count expansion after
version-pinned parameter binding; recursive invocation and dynamic target
discovery reject. The global active set remains at most 64
rules/schedules/routines and batches at most sixteen arbitrated effect groups.
These are Home admission ceilings, not universal library constants.

Composed profiles require new admission/root/schema evidence before activation.
No sixteen-effect budget is inferred from the current single-effect ledger.
Initial overlap policy is reject: one nonterminal run per routine revision;
a repeated original returns its own result, and a different trigger while busy
records a skipped-busy outcome without another effect.

**H20-04 — Facts, steps and completion.** Predicates use true/false/unknown;
negating unknown remains unknown. Required stale, missing, invalid or old-source
facts are unknown. A blocked condition emits no effect. A report-event trigger
requires qualified current continuity; first/reconnected/restored/retained
samples establish a baseline rather than an edge. Profile/source-generation
changes reset the baseline.

An absolute-action step declares its evidence threshold. A sequence advances
only on that threshold; protocol acceptance alone cannot satisfy reported
equality. Parallel branches retain separate originals/outcomes; the initial
join is all-required. Failure stops new unsent dependent work, retains already
committed outcomes and waits for disposition of started work. Unknown handoff
halts dependent progression with an unknown outcome. Waits require explicit
deadlines; unknown conditions remain waiting until deadline, then time out.
Delay is boot-scoped elapsed time; restart expires its unsent continuation.
No implicit compensation, toggle, notification provider, race/quorum join or
catch-up is included in this first profile.

**H20-05 — Whole-set arbitration.** Before the batch cutoff, collect every
eligible proposal from the complete current bounded active set under one
membership/generation, fact, declaration, policy and clock basis. Use reviewed
effect domains, conservatively whole-Thing. Hard constraints filter first;
current authorized override leases apply next. Equal-authority incompatible
effects conflict without an arrival-order winner. Equivalent effects retain
all original contributors and nonrefundable accounting. Store commits only if
the full collection and arbitration basis still matches. The existing
`provided_proposal_set_only` receipt cannot prove that collection.

**H20-06 — Durable current authority.** One Store transaction rechecks original
author and input/target grants, authority epoch, program/admission/profile
identities, active generation, resource revisions, facts, invariants, overrides,
clock/window and capacity; reserves run/step originals and causal roots; and
creates held work or a terminal refusal. Claim and final handoff repeat all
mutable guards relevant to their effect. Transport starts only after the
durable handoff marker commits. Workers receive neither Store handles nor a
principal's bearer. A due event and successful pure proposal grant nothing.

**H20-07 — Time and external schedulers.** SP.08 enumerates original due
instants, never clipped availability starts. Home binds its source revision,
active generation, authority epoch and exact time-zone data identity to those
occurrences. Calendar and UTC intervals require a host-owned confidence
interval wholly within `[due, due + late_window)`, including at final handoff.
Clock correction invalidates old projections; backward movement cannot repeat
considered work and forward movement records bounded missed ranges.
Countdown/delay use boot-local elapsed coordinates. Default missed policy is
skip. [Device schedule ownership](device-schedule-ownership-v1.md) separately
records controller/device/external execution; suspending Home does not stop a
device timer. SP.08 is calculation, never trusted time or activation.

**H20-08 — Retry, cancellation and recovery.** Scope originals to principal,
home/authority epoch and operation identity. Logical resubmission returns the
original outcome. Cancellation prevents future unsent work and retains spend;
it cannot unsend or compensate a command. A stop is a fresh separately granted
effect. Unknown handoff is reconciled by qualified observation without resend or
causation claims. Replacement, revocation and transfer invalidate unsent work
and retain unknowns/history. Restore stays quarantined and does not activate
copied definitions. Same-owner restart may resume only a supported revalidated
profile; boot-local waits expire. Compaction retains no-repeat watermarks and
all ambiguous-effect originals.

**H20-09 — Admission and analysis.** Reuse WOH.07's four axes: validity, findings,
execution completion and admission decision. Analysis binds full source/IR,
behaviour/declaration, model/compiler, runtime, time policy and environmental
assumptions. Unsupported semantics reject projection. A completed bounded
search without a counterexample remains inconclusive where positive evidence
is required. Extraction changes runtime identities and requires new independent
correspondence; old receipts remain history. Backend loss blocks fresh
proof-required admission, while still-applicable admitted work keeps runtime
guards. Device events never supply executable Maude source.

**H20-10 — API, UI and independence.** Authenticated API/CLI/native clients
expose immutable revision, resolved participants, execution owner, next/missed
occurrences, current overrides, blocked reasons and per-step receipt references.
Aggregates distinguish partial and unknown outcomes; completed means every
required step met its declared evidence threshold, not measured physical success.
Simulations use explicit snapshots/virtual time and cannot dispatch.
Closing a client does not stop valid controller-owned work. A second independent
consumer must execute the same generic corpus through a real package archive
without importing Home modules, schema or vocabulary before universal reuse is
claimed.

## Implementation entry and compatibility

Before kernel consumption, freeze executable source/IR/error schemas,
capability/Continuum field mapping, public host callback contract and archive
closure in WoTEx. Before temporal consumption, implement and test ExBooking
SP.08, preserve Home's current occurrence encodings and prove adapter parity.
Before composed activation, define exact run/step/root journal encodings,
migration/integrity/backup joins, complete active-set validation, cancellation
and independent model traces. Missing evidence leaves that profile inactive.

Extract by read-only decision comparison first; never dual-write or dual-dispatch.
Keep original source/profile/receipt identities interpretable. No generic
mechanism narrows the full current qualification digest without independent
dependency and mutation evidence. Installed-host and physical gates remain
additional obligations. The [implementation plan](../plans/universal-routines-delivery.md)
orders this work and the optional device/ecosystem successors.

## Acceptance obligations

| Case | Requirements | Stimulus and expected observation | Evidence |
| --- | --- | --- | --- |
| H20-T1 | 01–03 | Two independent producers/consumers use the same scalar/event/actuator corpus; no vendor or Home branch exists in kernel decisions; package load performs no I/O | Independent archive software |
| H20-T2 | 01, 03 | Old v1, unknown semantics, recursive nesting, excess expansion, changed child/profile bytes and widened declarations reject or require fresh admission; old grants do not widen | Pure plus Store |
| H20-T3 | 04 | Exhaustive three-valued tables and independent event traces cover reconnect, retained replay, stale facts, waits and source replacement; no false edge/effect | Pure plus Store |
| H20-T4 | 05–06 | Place a conflicting proposal beyond the sixteen-group cutoff; collection still conflicts. Race generation, grants and membership changes at commit/claim/handoff; zero stale sends | Independent model plus real Store |
| H20-T5 | 06, 08 | Inject crash/failure before and after reservation, claim, handoff and settlement; duplicate original/lost reply retains one history/root; unknown never causes resend | Real Store/controlled transport |
| H20-T6 | 04, 08 | Sequence ACK-only, partial parallel success, unknown branch, deadline and post-handoff cancellation retain exact per-step outcomes; no compensating effect appears | Independent run traces plus Store |
| H20-T7 | 07–08 | SP.08 vectors, DST fold/gap, clipping, duplicate ticks, clock correction, delayed handoff and restart retain original identity and skip expired work | Independent temporal/Store traces; host clock separately |
| H20-T8 | 09 | Mutate unknown handling, omitted step/effect, cutoff order, guard/root join and model identity; correspondence refuses. Timeout/truncation/empty search cannot become admission | Independent reference/mutation |
| H20-T9 | 07, 10 | Timer migration fails at each staged boundary; Home never claims an external timer stopped. API/UI distinguish owner, blocked, partial and unknown | Software peers; real timer/installed UI separately |
| H20-T10 | 01–10 | Motion/light, slow actuator/media and non-household procedure share public kernel; disable voice, WAN and optional verifier for still-valid work; preserve ordinary controls | Independent archive, installed and exact-device layers separately |

Every case remains an obligation. Record source/build/fixture/profile identities,
environment, actual command/outcome and evidence location before changing status.

## Restricted extraction comparison

[The restricted archive shadow profile](routine-shadow-v1.md) owns the first
read-only comparison: one explicit unconditional Boolean ordinary-Light power
rule, causal budget one, ownership 1 ms and zero cooldown. It independently
retains Home desired-state, current gate and consumed-root policy before calling
the generic public kernel. Unknown desired state is not a false observed predicate;
proposal accounting is not manufactured held-effect spend. Other formats and
multi-original interleaving are outside this profile. The standalone harness
freshly compiles the exact Home source closure alongside supplied extracted
producer archives, with no application startup, Store or dispatch.

The [executed cohort record](../provenance/routines-shadow-2026-10.md) records
360 finite cases, duplicate/blocked-root release, unsupported/forged refusals
and fresh code identity. This establishes a narrow software comparison subset;
Home production kernel delegation, temporal Store joins, composed journal/
admission/model proof and installed/physical evidence remain open.

## Immutable timezone calculation join

[The explicit timezone-provider contract](routine-timezone-provider-v1.md) owns
Home's additive pure TZif-to-SP.08 provider and its exact four-archive comparison.
All 230 retained independent local-label vectors pass through the public producer
seam; gap/fold/second-fold pages preserve Home occurrence bytes and original IDs.
This supplies no clock confidence, dependency selection, scheduler activation or
Store admission. Full temporal extraction and durable current-basis races remain
H20-T7 obligations.

## Civil calendar and current runtime successor

The [civil calculation contract](routine-civil-calculation-v1.md) freezes a
separate complete immutable TZif provider and public WRO.03/SP.09 join before
code. It preserves wider offsets, more-than-two ambiguities, local-date search
order and unchanged Home original identities. The old RRULE provider stays
unchanged. Producer implementation and its archive corpus do not establish Home
runtime adoption.

The [temporal runtime contract](routine-temporal-runtime-v1.md) freezes the
complete ten-application producer/dependency cohort, eleven-application Store
guard union, v4 correspondence, historical-proof refusal and current writer
boundaries. The RCC provider and public pure calendar candidate now have
[exact archive evidence](../provenance/routines-civil-2026-10.md): all 230 local
labels, 112 recurrence vectors and bounded ambiguity/order/refusal cases pass.
Exact dependency selection, production calendar delegation and complete v4
runtime inventory now have [focused runtime and Store evidence](../provenance/routines-runtime-2026-10.md).
All-member opening/closing/final writer faults, retained historical v1–v3
withdrawal/restart and unchanged current guards now have bounded software
evidence. Wider routine admission, installed hosts and physical qualification
remain open. Both successors retain their separately stated scope. Existing
single-active admission and physical qualification requirements remain intact.

## Explicit kernel runtime successor

The [kernel adoption contract](routine-kernel-adoption-v1.md) owns the initial
generic proposal for the admitted explicit Boolean Light rule. It specifies the
consumer-owned installed mapping, exact generic input/result, complete-runtime
v4 proof, historical v3 decoding and Authority calculation followed by current
and final Store repeats. Draft desired-state suppression remains separate from
the actual held-request path. The wider pure ownership range is preserved;
durable admission remains one millisecond and one effect. Pure mapping/result
validation, current v4 proof, historical v3 decoding and the native preview now
have [bounded software evidence](../provenance/routines-kernel-2026-10.md).
Authority now prepares inert input, calculates the actual initial proposal
outside the writer and commits through repeated current/final Store guards.
Original-first duplicate/restart recovery, producer absence and publication
rollback have bounded software evidence. All-member preparation/commit/final
runtime mutations, six final-read SQL faults and actual producer failure now
refuse without stale publication. Actual v3 held, queued, claimed, handed-off
and acknowledged originals preserve their admissions, origins and causal spend
through current restart and producer absence. Only documented recovery or
cancellation advances request outcomes; restored archives remain quarantined.
Profile-custody loss, source replacement and foreign-epoch proposals also refuse
without publication. The owning rule/temporal software milestone passed 115 tests.
Full composed execution and sensor joins remain subsequent WOH.20 obligations.

## External input producer checkpoint

WoTEx now implements the bounded external input execution join: complete installed
external binding, required-but-null receipt UTC, explicit conservative precision,
native reader-to-kernel/edge paths and two extracted execution consumers with
identity/rounding mutations. Its full owning package milestone passes. The
[cohort and Home source review](../provenance/routines-external-input-2026-10.md)
records the later exact Home source selection separately from the producer
evidence; qualified current external facts remain unavailable.

The inert Home projection reconstructs the original public reader Proposal from
the exact retained report/envelope and preserves separate Home-converted and
original witnesses. Its explicit receipt correspondence and expiry remain inert.
Qualified current facts, complete-set collection, durable
composition and wider admission follow their own current Store/proof contracts;
external read approval and a generic constructor cannot supply those permissions.

## Inert external fact projection successor

The [external fact projection contract](routine-external-facts-v1.md) owns the
bounded original-reader/Mapping join before current fact collection. It preserves
independent Home-converted and original Proposal witnesses, complete external
profile/Basis correspondence, explicit receipt clocks and null receipt UTC.
REF-T1–T5 require actual native and extracted execution, adverse input/producer
cases and independent unit/identity/signed-clock expectations. Entry schema/vector
and native REF-T1–T4 checks pass; the extracted REF-T5 lane now passes five
archive cases and catches identity/original-coordinate mutants through assertions.
Thirteen focused native/schema cases include current runtime inventory and
regenerated Mapping drift refusals. This completes the inert software contract;
current Store fact collection, rule admission and dispatch remain separate.


The [consumed report lifetime contract](external-report-lifetime-v1.md) is the
next concrete prerequisite for qualified current collection. Durable v1 retains
the original Store receipt coordinate but no report-owner deadline; source review found that
the prior native owner discarded it after consumption. The bounded Store-only
witness now preserves it without processing-time renewal or a new durable format.
Its native owner, exclusive-clock, quota and failure checks pass.
Reviewed Mapping installation and complete current collection follow separately.

## Reviewed current external input successor

The [reviewed external input contract](routine-external-inputs-v1.md) now owns
exact context/Definition/runtime correspondence, signed read qualification,
scoped install/revoke history and bounded complete requested collection. It
preserves original owner receipt/lifetime, explicit unknown and current-final
guards. Its entry programme, closed schemas and independent wire/hash/signature
vectors pass [entry checks](../provenance/routine-external-inputs-2026-10.md);
EI-T1–T9 implementation and physical obligations remain open. Requested-scope
collection does not establish complete active program membership, composed run
persistence, admission or permission to send.

The fresh runtime foundation passes its eight focused entry/runtime cases,
including closing checks for all twenty app members under byte/version/module
inventory drift and absent metadata. Pure Definition construction and the signed
review verifier now pass twenty focused Definition/review/entry cases, including
independent original bytes/signatures, actual integer/Boolean/enum readers,
producer-free history and validly re-signed adverse claims. These establish
bounded EI-T1/T2/T7 foundations. Retained package/operation codecs and the exact
original join now pass thirty-three focused retention/Definition/review/entry
cases, including producer/programme-independent history and later-boot revoke.
The live schema-38 migration now integrates retained graph checks into startup
and every Store transaction, exact backup inventories/counts and quarantined
source-revision recovery. Seventy-seven focused history/migration/recovery cases,
twelve selected historical migrations and twenty-two portable Linux cohort/probe
cases pass. Actual preceding schema-37 code confirms unchanged retained hashes
after an empty migration. Native review context now measures the actual selected
private reader, source, receipt clock and complete runtime twice, with independent
caller/author permissions and target grants before private reads. Restart,
original replay, owner timeout, source drift and corruption have focused software
coverage; four isolated Store probes reject closing byte drift across all runtime
groups. Installation/revoke, proactive withdrawal and current collection remain
open. Linux-only execution, physical qualification and complete composed execution
retain their separate obligations.
