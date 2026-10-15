# Universal profiles and routines delivery

Version: 0.1.4. Updated: 2026-10-13. Accepted build order; implementation and
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
consumer remains planned. Routines is now selected for the separately bounded
temporal calculation path recorded in the current checkpoint below.

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

Next, define and adopt the restricted generic kernel runtime seam before wider
sensor/composition admission. The archive shadow profile remains its independent
comparison evidence. Stage 6 still requires qualified fact continuity, complete
sets, multi-root/step schema and a concrete admission proof. Installed host,
minimum-window load and physical campaigns remain separate obligations.

## Explicit kernel adoption order

The [kernel successor](../specs/routine-kernel-adoption-v1.md) is the next runtime
entry contract. Current admitted invocation builds held work directly; the
credential-free draft Sandbox is a separate path. Adopt the actual public
Compiler/Kernel initial proposal without changing that distinction or widening
admission. All generic mapping data stays in Home; no household policy enters
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
