# WOH.20 — Reusable routines and the Home consumer

Version: 0.1.0. Updated: 2026-10-13. Status: accepted target.
Implementation: planned. Evidence: missing.

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
