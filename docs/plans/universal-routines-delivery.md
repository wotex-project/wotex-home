# Universal profiles and routines delivery

Version: 0.1.21. Updated: 2026-10-15. Accepted build order; implementation and
evidence remain separate. No dependency or device operation is changed by this plan.

## Sources and reconciliation

The routines research at commit
`f454204` is preserved in [the research record](universal-profiles-routines-research.md).
Its Home baseline is `c73d7ac`. The earlier portable-profile branch `4f89a46`
is already reconciled in [the retained memo](portable-profile-research.md),
ADR 0010 and WOH.18; do not replay its original P1 as missing implementation.

Source review on 2026-10-13 checked Home's compiler, capability schema, portable
binding, recurrence and pinned dependencies, plus WoTEx `80c8b918`, ExBooking
`f73193c` and ExMaude `2c61558` read-only. ExBooking's research revision
`212cffa` differs from that checkout only in Decimal lock maintenance; its
recurrence API is still duration-bearing, horizon-clipped intervals. The new
generic API belongs there, with no Home concepts.

Home now consumes the exact ExMaude 0.5.0 Hex release and retains its reviewed
UDP Git pin. Development sibling selection is explicit. These dependency
changes have their own provenance and gates. Source inspection,
research source claims and planned cases are not new executed evidence.
No sibling is an external ownership blocker: implementation is sequenced in
its own repository and consumed only after its public contract passes.

The first producer addition is now implemented and committed in ExBooking's
development source: SP.08 values, facade/domain operation, shared recurrence positions,
bounded query/cursor enumeration and independent DST/calendar/page vectors.
Its full local gate passed 401 tests with 97.0% coverage and actual archive/
notebook consumers on Elixir 1.20.4/OTP 29.0.4. Optional absent-tool checks were
skipped by that repository's gate. That stage 2 milestone selected no Home
dependency or scheduler adapter; later temporal selection is recorded below.

## Normative owners

| Repository | Contract / artifact | Boundary |
| --- | --- | --- |
| ExBooking | SP.08, `docs/specs/SP.08-occurrence-enumeration.md`; SP.01/02/06/07 and task list | Pure original recurrence enumeration; no scheduler, authority, storage, device or consumer vocabulary |
| WoTEx | WRO.01–04, `docs/packages/wotex-routines/specs/`; completion plan | TD/TM/Continuum-compatible behaviour basis, bounded source/IR, host seam and scoped model projection |
| Home | [WOH.20](../specs/WOH.20-universal-routines.md), [v2 mappings](../specs/device-profile-mappings-v2.md), [timer ownership](../specs/device-schedule-ownership-v1.md) | Household policy, grants, Store, exact device cohorts and honest presentation |

The optional nineteenth WoTEx package is now registered. WRO.01 has closed
Limits/Registry/Unit/Basis/Fact values, exact dimensional conversion, an
explicit observation source class, offline schemas/vectors and the lossless
Continuum Fact adapter. Its pure constructor/schema tests, fast gate, docs,
archive contents, dependency audit and application-free checks pass. The
catalogue retains partial status for execution joins and independent adoption.
Home's restricted read-only archive comparison now passes 360 finite cases
and duplicate/blocked-root/forged-source checks; see the
[shadow profile](../specs/routine-shadow-v1.md). The restricted kernel runtime
consumer is implemented under the bounded initial-proposal contract below;
composed execution remains a later stage. Routines is also selected for the
separately bounded temporal calculation path.

WoTEx now implements source/IR regeneration, qualified snapshots, retained
composition and staged receipts, reported-edge qualification, complete
provided-set arbitration, immutable scalar schedules, a direct optional
calendar adapter and an explicitly started bounded driver. Analysis has closed
result axes and bounded concrete Witness replay; model projection/backend
execution remain open. The package fast gate passes 109 tests; an independent
manual source-transition/predicate lane catches six isolated behavioral
mutations. Two extracted archive composition consumers pass 11 and 6 tests;
the renewed calendar consumer passes 8 tests. Exact artifact/lock/source
digests are recorded in WoTEx's `docs/packages/wotex-routines/provenance/`.
These software checks do not establish Home restricted-corpus parity, actual
Store transactions, installed clocks or physical qualification.

The current exercised development archive cohort uses ExBooking `0418a06`
and WoTEx runtime source `5bf61912`; WoTEx `d7e2ef00` owns its paired archive
acceptance harness. Published ExBooking 0.2.3 does not contain SP.08; its public API
addition is unreleased. Joint temporal development must use a coherent exact
source/archive cohort, with published-producer adoption recorded separately.
Full suites, Dialyzer and expensive SDK/firmware builds are milestone gates;
focused mechanism checks accompany each implementation commit.


ExBooking `fb9082f` now implements an explicit bounded immutable timezone
provider, with a complete green local gate (410 tests, 97.1% coverage, Dialyzer,
audits and actual archive/notebook consumer). WoTEx `f0e68746` joins it through
public APIs; nine calendar archive cases and its 120-test fast gate pass. Home's
[pure timezone join](../specs/routine-timezone-provider-v1.md) passes every retained
230-vector local-label case through the extracted producer seam, plus gap/fold/
second-fold paging, original encoding, context/cursor and precision checks. Its
existing restricted 360-case Boolean comparison remains separately scoped. The
exact archives are development cohorts; Home selects no runtime dependency or
new temporal admission from this evidence. WRO.04's frozen-time proposal runner
also passes its native cohort, with only inconclusive admission; wider models
remain open.

## Ordered additions

| Stage | Owner and deliverable | Completion required before next dependent stage |
| --- | --- | --- |
| 1 — contracts | All three repositories; requirements, template/skills, ownership and acceptance review | No competing semantic definition, unresolved default or misleading implementation claim; links/catalogue checks |
| 2 — generic recurrence | ExBooking SP.08; public values/facade, bounded traversal/cursor and independent vectors | Stable original UTC/nominal/ordinal across horizon/pages; DST/COUNT/UNTIL and work-limit errors; existing API parity; full repository and archive gate |
| 3 — generic basis | WoTEx WRO.01; installed behaviour contracts and complete Continuum field reconciliation | Scalar/event/fast/slow/media constructors, closure/schema and exact conversion pass; no consumer names or privileges. Execution completion/repeat joins are checked with stage 4, avoiding a circular gate. |
| 4 — kernel extraction | WoTEx WRO.02; optional package scaffold, public source/IR and pure kernel | Existing restricted corpus parity and independent non-household archive consumer; no hidden package APIs or load effects |
| 5 — temporal join | WRO.03 plus Home scheduler/WOH.20 | ExBooking adapter parity; original occurrence encoding unchanged; current clock/author/Store guards and independent durable fault traces |
| 6 — sensors and composition | WRO.02/04 plus Home WOH.01/04/07/14/18 | Qualified fact continuity, complete-set collection, multi-root/step schema and admission proof; no activation from provided-set correspondence alone |
| 7 — user/device delivery | Home integrations, API and native host owners | Exact device/firmware, installed custody and physical acceptance; per-step unknown/partial results and owner labels |
| 8 — ecosystem/voice | Optional qualified Matter/native/media/capture owners | Legitimate export types, restricted principals and independent capture permissions; ordinary routines pass with all optional services absent |

User-authorized implementation starts with stage 2 after stage 1's review.
Stage 2's generic producer is implemented and locally checked. Stage 3's pure
foundation is implemented, with its execution joins and stages 4–8 remaining. This plan does not enable physical dispatch,
commission devices or perform host installation.

## Disposition of the research work packages

| Research item | Spec and concrete next addition |
| --- | --- |
| P01 ownership/evidence | ADR 0011, WOH.20 and producer catalogues; preserve current partial status and remove Refpath/wrappers from this track |
| P02 capabilities | WRO.01; exact units, whole-resource domains, continuity and declared completion. Home v2 selects these installed meanings |
| P03 profiles | WOH.18/v2; multi-channel schema and selection joins, preserving v1 custody/history and explicit grant changes |
| P04 ExBooking | SP.08; original enumeration without fake duration, deterministic bounded pages and unchanged availability policies |
| P05 kernel | WRO.02; extract generic decisions through public archives, keep Home-specific authority outside |
| P06 temporal driver | WRO.03; explicit host-owned driver and ExBooking adapter, Home occurrence/window/current-basis commits |
| P07 sensor events | WRO.01/02 and WOH.04; baseline, sequence, debounce/hysteresis/cooldown and independent traces before admission |
| P08 composition | WRO.02 and WOH.20; finite sequence/parallel/wait/subroutine profiles, complete-set arbitration and nonrefundable roots |
| P09 Maude | WRO.04/WOH.07; full semantic projection, result axes, independent oracle and mutation cases |
| P10 BLE write mode | WoTEx WBL.08 before code; explicit acknowledged/without-response mode with typed evidence and queue/deadline/cleanup parity |
| P11 native Mac BLE | WoTEx WBL.08 host successor; CoreBluetooth permission/identity/lifecycle/readiness tests; Linux support is not Mac evidence |
| P12 Motionblinds | Home local-device behaviour contract; `open_fraction_ppm` 0 closed/1000000 open, exact inversion vectors, independent read/move/stop evidence; timer editing separate |
| P13 Shelly/Hue/LIFX | WOH.03/v2; model/API-cohort mappings and qualified events/writes. SHCB-1 is RGBW bulb, SHMOS-02 uses Gen1 surface; preserve Hue TLS and LIFX readback |
| P14 Sonos | Home local-device behaviour contract; enrolled source/favourite/session/volume/stop, private metadata, local command vs remote content failures |
| P15 Matter | WOH.10 and upstream exposed-server contract; legitimate light/cover types, stable endpoints, restricted fabrics and loop prevention |
| P16 entertainment/voice | Separate optional Home contracts after exact TV/speaker/capture identity; no unsupported microphones, Art APIs or console controls |
| P17 authoring UX | WOH.20/08/15; source/diff, owner/next/missed, simulation, overrides and original step receipts |
| P18 independent reuse | WRO corpus in separate archive consumers; same decisions without shared private schema or household ontology |

P10–P16 name later contract entry requirements rather than invented supported
protocols. Their packet/API/host specifications must precede their code; stage 1
does not claim those future vendor features are build-ready.

## Drift checks and qualification

Before each consuming change, compare producer API/semantic version, exact
selected source/build, executable profile and adapter mappings. Availability
intervals and occurrences cannot substitute for one another; shared identity
conventions do not merge pure replay with physical retry. New source extraction
changes compiled qualification identities; retain historical receipts and obtain
new correspondence rather than editing old digests.

Run ordinary controls and the restricted corpus alongside every extraction.
Use read-only shadow decisions, never a second Store/dispatcher. Test negative
cases at the exact boundary: stale author/profile/time basis, complete active-set
changes, delayed handoff, lost original response and cancelled/unknown branch.
Record software, installed-host, physical and ecosystem evidence separately.
Existing [local product delivery](local-controller-delivery.md) remains the
installed-host/transfer critical path; generic extraction cannot weaken it.

## Current temporal runtime checkpoint

The [runtime successor](../specs/routine-temporal-runtime-v1.md) now selects the
exact civil producer cohort, delegates production calendar calculation through
its public join, binds the complete ten-application v4 proof and closes an
eleven-application Store inventory. The complete 541-module Home application
required the authored 1024-module bound; no module filtering is permitted.
[Executed evidence](../provenance/routines-runtime-2026-10.md) includes independent
calendar/source mutations, all-member runtime/guard mutations, producer absence,
actual SQLite retention/restart, calendar activation and qualified-clock polling.
The all-member writer campaign now covers opening/closing/final drift,
queue/no-send/claim/handoff, poll preparation, withdrawal SQL faults and retained
spent/unknown roots. Historical v1–v3 active rows withdraw without rewriting old
admissions or originals; same-owner restart creates no new authorization,
clock custody or claim token. The targeted 73-case runtime/current-guard
milestone passed; no full application suite, Dialyzer or host build is inferred.

The restricted generic kernel's initial-proposal software milestone is recorded
below. The archive shadow profile remains its independent comparison evidence.
Continue stage 6 with qualified fact continuity, complete sets, multi-root/step
schema and a concrete admission proof. Installed host,
minimum-window load and physical campaigns remain separate obligations.

## Explicit kernel adoption order

The [kernel successor](../specs/routine-kernel-adoption-v1.md) owns the restricted
runtime entry contract. Admitted invocation now calculates the actual public
Compiler/Kernel initial proposal before creating held work. The credential-free
draft Sandbox remains a separate path; this join does not widen admission.
All generic mapping data stays in Home; no household policy enters
WoTEx or ExBooking. The selected public producer APIs already cover this join.

1. Implement the bounded Home installed mapping, source/program conversion and
   complete initial-result validation. Preserve wider supported pure ownership
   values; actual durable admission remains its existing one-effect profile.
2. Bind a current v4 proposal proof to the complete producer cohort and actual
   source-specific Kernel checks. Decode v3 only as unchanged historical content.
3. Add authenticated inert preparation, Authority calculation outside the writer
   and current/final Store revalidation before one held original/root. Preserve
   the existing invoke API through the same sequence; close raw-message bypasses.
4. Execute producer/native/projection mutations, actual duplicate/race/SQL and
   history/restart/adapter cases, then the owning mechanism milestone. Keep the
   draft archive oracle and its result scope explicit.

These steps do not complete stage 6. Qualified sensor facts, complete-set
collection, composed run/step roots, durable completion and wider admission still
follow their owning contracts. No host/image/full-suite gate is part of a pure
mapping edit; milestone evidence must name the checks actually executed.

The [kernel adoption checkpoint](../provenance/routines-kernel-2026-10.md) implements
steps 1–3 above: bounded mapping/result checks, current v4 correspondence,
historical v3 decoding, native preview and the actual Authority/Store initial
invocation join. The first durable corpus checks caller-process calculation,
concurrent originals, relevant-basis changes, final permission drift, five SQL
publication faults, capacity, raw-route refusal and producer-absent restart.
Step 4 now adds 120 all-member runtime mutations across preparation, commit
and final publication, six final-read SQL faults, three actual producer failures
and unchanged actual-v3 held history across current restart/producer absence.
Actual retained-v3 queued/claimed/handoff/ACK cases now preserve spend and
uncertainty through current restart and producer absence, including cancellation
and quarantined encrypted restore. Real selected-profile custody loss, active
source replacement and foreign-epoch proposals refuse without publication.
The owning rule/temporal software milestone passed 115 tests. Stage 6 still
requires qualified facts/continuity, complete-set collection, composed run/step
roots, durable completion and wider admission; those contracts are next.

## External input execution checkpoint

The generic prerequisite now passes its own bounded software milestone. WoTEx
743ef568 implements the complete external binding, null receipt UTC and explicit
floor precision; d1b2e87b records native/archive execution, four behavioral mutants
and the full 179-test, 95.4% package gate. Home now selects exact d1b2e87b in
both locks, with the focused native and renewed civil archive checks below. See the
[exact source review](../provenance/routines-external-input-2026-10.md).

Continue stage 6 in this order:

1. Specify and freeze the bounded Home original-reader/fact correspondence,
   independent unit/identity/negative-clock vectors and inert result grammar.
   A Home ExternalValue may already contain converted data, so reexecute the
   original WPF report under the exact checked envelope; retain both witnesses.
2. Select and verify the coherent producer cohort, then implement that pure
   projection with focused reader-to-evaluation/kernel and failure tests. Preserve
   runtime-proof invalidation and historical originals under the source change.
3. Specify qualified current Store collection and its exact authenticated scope,
   semantic/source installation, report/resource/selection revisions, current/final
   guards and reconnect/restart/expiry behavior before adding a current fact route.
4. Implement complete-set and composed run/step/root persistence plus their bounded
   admission proof, rollback/history/restart and independent correspondence cases.

This checkpoint neither extends the legacy FactReadModel nor changes observation
admission, grants, active rules, clocks or default-disabled physical dispatch.

## Bounded fact projection entry

The [Home projection successor](../specs/routine-external-facts-v1.md) now defines
closed native/current inputs, original reader reconstruction, explicit Mapping
and limits, eight-member inert output, error reduction and REF-T1–T5 acceptance.
The offline schema and independent Python-hashed vector precede implementation;
three shape/hash cases pass. The vector distinguishes Home 2500 thousandths,
reader 2.5 degrees and routine 250 centidegrees, with original -1001 us projected
to 9998 ms and explicit null receipt UTC.

Select the exact new Routines source under the existing runtime inventory and
historical-proof rules, then implement this contract and its actual native and
archive cases. Native Home value validation may delegate bounded compiled-code
inventory to RuntimeArtifacts; do not bypass that owner to claim the entire join
has no I/O. Current Store fact collection/qualification, complete sets, durable
composition and wider admission remain the following owned stages.

## External execution source selection

Home selects d1b2e87bdc82bd0138887931a9f40a2236ff2fdc for Routines in mix.exs
and both root/firmware locks. The other producer/Hex tuples are unchanged.
The owning package changelog and dependency declarations have no difference
from f3e77a43; its actual additions and acceptance are in the execution contract.
Twenty-eight focused cohort/profile/kernel/calendar cases pass, plus two actual
Store probes for a held invocation and genuine v3 restart/producer-loss history.
The renewed exact civil archive lane passes 14 cases, all 230 timezone/label and
112 recurrence vectors and no-application-start calculation. These checks do
not replace the earlier recorded full durable milestone or qualify hardware.

The inert fact projection now passes REF-T1–T5 in bounded software scope:
thirteen focused native/schema cases, five extracted archive cases and two
assertion-only identity/original-coordinate mutants. The archive witnesses were
frozen before the harness; current-runtime and regenerated Mapping drift checks
pass. Next specify qualified current Store fact collection and its transaction/
continuity evidence before implementation. Complete-set composition and broader
admission remain open.


## Current external input prerequisites

Source review at aa8ec898 found two explicit missing owners: qualified external
Mapping installation and the original consumed report lifetime. The
[Store-only lifetime witness](../specs/external-report-lifetime-v1.md) is now
implemented after its committed schema and independent signed/exclusive-deadline
vectors. Its 29 focused cases and 16 existing custody cases pass; original
publication/consumption receipts and quotas are preserved. Consumed custody
does not prove an observation committed. The reviewed input contract below now
specifies Mapping installation and complete requested collection, including
actor/grant/semantic/source qualification, Store boot, rebuild/revision/current-final
guards and baseline continuity. Its remaining durable/current work follows the
explicit delivery order. Do not promote
ordinary profile approval or fabricate an owner deadline from current defaults.

## Reviewed external input delivery

The [accepted input contract](../specs/routine-external-inputs-v1.md) and
[executed evidence](../provenance/routine-external-inputs-2026-10.md) govern this
successor. Current status and remaining order:

1. Fresh four-group runtime capture is implemented, including all twenty-app
   closing/absence probes. Pure Definition/native reconstruction, historical
   decoding, the fixed programme and separate signed-review verifier are also
   implemented; twenty focused Definition/review/entry cases pass. These are
   software foundations and create no current Store installation or Fact.
2. Retained package/input/outcome/receipt codecs and the exact original join are
   implemented; thirty-three focused retention/Definition/review/entry cases pass.
   Schema 38 now integrates retained graph validation at startup and every Store
   transaction, exact backup counts/inventories and quarantined recovery. The
   original schema-37 code confirms unchanged retained hashes after empty
   migration. Seventy-seven focused history/recovery cases, twelve selected
   historical migrations and twenty-two portable host cohort/probe cases pass.
   Bounded native review context is implemented with independent caller/author
   grants and repeated private-source/runtime checks. Focused actual Store
   restart, timeout, source drift and corruption probes plus four isolated runtime
   group drift cases pass. Implement original-first install/revoke and atomic
   maintenance/author/target withdrawal before exposing installed current use.
3. Implement Store-owned complete requested-scope collection from actual private
   custody, committed original pointer and live consumed lifetime. Exercise
   independent receipt, unit, continuity and final-basis fault traces.
4. Run the extracted producer consumer and existing read/unconditional-effect
   regressions, then the owning durable/recovery milestone. Continue complete
   active-set composition, run/step/root persistence and wider admission under
   their owners.

Preserve original registry order and immutable wire bytes. Historical decoding
provides no current authority. Physical review, installed hosts and later effect
execution remain unestablished. Use focused checks between logical commits and
remove each owned temporary workspace on exit.
