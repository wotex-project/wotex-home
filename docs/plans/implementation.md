# Implementation order and release gates

Version: 0.2.175. Updated: 2026-11-01. This plan separates executable slices from external acceptance gates.

Spec numbers are identifiers, not implementation order. The [catalogue](../specs/catalogue.yaml) tracks implementation and evidence status separately. A completed pure slice is not an implemented physical controller.

## English voice and conversational M1

Accepted 2026-11-01. Scope: specifications/catalogue and this existing tracker
only. The user requires **voice in M1, English only**. WOH.06 is the primary
interaction owner; Home Authority and the single SQLite Store remain the
physical/domain authority. Ordinary qualified voice/text actions execute under
current scoped grants without a visual click on every command. Protected
native review and unavailable high-impact operations remain separate paths.

WOH.06 inventories twenty capability dispositions (C01–C20), ten branching
journeys (J01–J10), eight everyday native families (U01–U08), six protected
native families (A01–A06) and six public release/help families (P01–P06).
The twelve packages below retain **all remaining M1 implementation and
qualification**, including pre-existing native, device and routine gaps. They
are open work, not estimates or completion claims. The earlier detailed
checkpoint/history and physical critical path remain valid foundations.
The catalogue's aggregate contract cases also contain later/demo obligations;
M1 does not require every future target or classifier experiment to be complete.

### Required product outcome and first receiving path

An authorized person installs the Mac app, explicitly configures local
controller/network/custody/assistant/microphone, enrolls and qualifies the
actual home cohort, then uses English push-to-talk or text for current facts,
lighting, scenes, routines, schedules, overrides, diagnostics and original
recovery. The actual local English recognizer/agent/synthesizer and current
Home facade complete the task with the WAN/DNS blocked after provisioning.
Native controls and applicable admitted routines remain usable without the
assistant. A paired native LAN client completes the same current-authority
path. A server, Matter, a Home Assistant instance or an always-listening device
is not a prerequisite.

Establish the public receiving path early: selected local assistant profile →
closed Home consumer facade → existing authenticated Authority → current Store
read/decision/original → existing qualified worker → correlated report → native
Activity/voice/text result. Start with an authorized read and a denied ordinary
request before any real dispatch. No private worker/Store/raw-device API is
exported. Task-to-native-original recovery must exist before effects can become
uncertain; a nice transcript or mock recognizer cannot close this path.

### Scope decisions fixed for this milestone

| Decision | Accepted contract |
| --- | --- |
| D01 Language/input | English-only voice and text. Push-to-talk with visible mic/permission/stop; no wake-word/ambient capture or language-support inference. |
| D02 Shared execution | Qualified local Refpath agent/conversation/model/speech/tool services, Home-specific narrow consumer. No duplicate generic runtime, router, speech coordinator, task/approval store or pricing engine. |
| D03 Physical truth | Home Authority/Store owns current principal/targets, semantics, safety, originals and device effects. A model, generic grant, LAN peer or recognized voice is not that authority. |
| D04 Review classes | Ordinary qualified request may execute directly; enrollment/profile/credential/grant/routine/restore changes use current exact native review; C18 remains unavailable. |
| D05 Speech repair | Final complete utterance only; negation/ambiguity/unsupported/clipped speech clarifies/refuses. Partial transcription and spoken yes cannot authorize sensitive work. |
| D06 Operations | Exact native original per accepted effect; scene parent aggregates members. No physical transaction/blanket rollback, blind uncertain resend or refunded causal root. |
| D07 Automation | Existing source/compiler/proof/shadow/review/admission/activation/runtime and current full active-set arbitration. Generic reasoning does not create a new scheduler or positive proof. |
| D08 Local data | No runtime speech/model download or cloud fallback. Seven-day bounded private text default may be disabled/shortened; raw audio is ephemeral. No default training or cross-home context. |
| D09 Native product | Reuse Things/Rules/Activity/Setup and shared session/custody/pending models; first launch remains explicit Setup, primary normal use is conversation. |
| D10 Hosts | Qualify standalone Mac and paired LAN native client first. Linux/shared compute, Nerves and manufactured hub remain independent optional profiles. |
| D11 Devices | Private exact-cohort manifest for at least two owned LIFX scene lights plus the purchased read-only Aqara/coordinator; support is per actual capability/model/firmware, not brand. Colour/fade cannot inherit direct-power proof. |
| D12 Later profiles | C16–C19 music/MAU, Matter/satellites/full-duplex/wake word, high-impact control and extra appliance cohorts stay separately gated; their existing contracts remain intact. |
| D13 Release boundaries | Existing public release/help material, accurate support matrix, declared Home/model/dependency redistribution rights. No hosted subscription/account/anonymous control surface is introduced. |

The reference manifest, exact selected Refpath export/model/voice source,
installed host/custody evidence, hardware fingerprint/coordinator and licensing
are explicit engineering/release entry work below. They are not fabricated
pins, default approvals, hidden substitutes or evidence supplied by this plan.

### Everything remaining to build and qualify

| Package / state | Required implementation and receiving owner | Dependency and discriminating completion |
| --- | --- | --- |
| B01 — Open: selected shared profile | Select/freeze exact Refpath source/public contract/export/ABI, configuration/storage/custody, local English ASR/model/TTS artifacts/licences, provider installation/retirement, no-egress/resource and finite shared-run limits. Deliver missing generic primitives at their existing Refpath owner. | WOH.06 H06-06/11/16/17, H06-T18/T21/T24; G01/G02/G09. Inspected sibling/source or existing native plugin tests are not an installed Home consumer. Home Assistant connector is not Home. |
| B02 — Open: complete English voice/conversation | Real push-to-talk, local conversion/recognition, final transcript/English semantics, repair/multi-turn, local spoken output/interrupt/quiet/privacy, selected devices and private scoped context/progress. Reuse B01 shared execution and storage. | B01 plus B03's authenticated read/scope/original interface; WOH.06 C01/C02/C14/C15 and H06-T7–T10/T17–T20/T23. Actual audio/English cohort, not text-only/model-stub success. |
| B03 — Open: Home-scoped tool/authority join | Closed schemas, current principal/controller/epoch/target/revision binding outside prompts, typed read/control/scene/preparation/override/status/cancel allow-list; protected native review receiver and persistent task-to-original association. No raw/admin tool export, credential forwarding or duplicate effect ledger. | Native WOH.14/15 foundations and B01's public interface; can begin with scoped reads and refusals independently of physical/model readiness. H05/H14/H15-M1 cases, H06-T11–T13/T16/T24; G03. |
| B04 — Open: real lighting path | Complete actual supported power/dimming/colour/white/transition intent, profile/unit/gamut/coupling/timing, Store admission/claim/handoff, worker and independent report/physical observation. Freeze exact supported hardware/runtime before extending code. | WOH.01/03/05/11/14, B10 installed custody before live use; H03/H11-M1 cases; G04. Continue native qualification independently of B01. Existing immediate-power/fixture signatures cannot qualify broader writes. |
| B05 — Open: rooms/groups/scenes | Native current composition records/editor, exact membership/risk/review, whole-Thing plan, per-member originals and partial/unknown recovery. Wire U02/U04 and agent/native execution to one owner. | B03/B04; H01/H14-M1 cases and H06-T14/T24; G05. Two real lights, membership/grant race and lost member reply prove honest aggregate state; no hidden chunking/rollback. |
| B06 — Open: routine lifecycle | Complete closed source/manual/generated editor, semantic validation/correspondence, isolated shadow, supported positive restricted proof, exact native review/admission/activation, complete current active-set arbitration, observation/revision/retirement. | WOH.04/07/20; producer entries below, B03 and required device profile. H04/H07/H20-M1 cases and H06-T15; G05/G06. Existing provided-set/inert/counterexample-only work cannot activate control. |
| B07 — Open: schedules and overrides | Current author/target, selected calendar/countdown/time-zone/clock basis, original occurrence, late/missed/catch-up/expiry, override precedence, pause/revoke and restart. Join native scheduler, not an agent polling loop. | B06's supported admission plus actual selected WoTEx/ExBooking semantics; H20/H04-M1 cases; G06. Clock/source loss, DST/fold, conflicting active work and revoked author have real Store refusals/outcomes. |
| B08 — Open: detector and sensor visibility | Record exact Aqara retail/fingerprint/coordinator; finish qualified local read-only transport/profile/observations/unknown/fault/test/alarm and local scoped notices. Reuse reviewed generic mappings for supported extra channels; no inferred writable/unsafe capability. | WOH.01/02/03/05/11/18, actual upstream radio/profile entry as needed. H05/H11-M1 cases and H06-T23; G04. Manufacturer-defined alarm independence and radio reports are separate physical evidence. |
| B09 — Open: all receiving/public families | Implement/connect U01–U08/A01–A06 over the existing native app/menu/session models, actual protected decision paths and current outcomes. Deliver P01–P06 through existing public release/help structure. | Feature owners B02–B08/B10/B11; H08-M1, H06-T20/T22; G07/G10. Actual keyboard/VoiceOver, adaptive layout/focus/draft/review/original continuity, realistic English errors and accurate public compatibility. |
| B10 — Open: installed Mac and paired LAN | Signed installed service/registration/lifecycle, actual private credential/mic/network custody, certificate clock/TLS/association, limited paired client, scope changes/revocation, sleep/logout/restart and truthful availability. No second controller. | Existing WOH.08/14/15/16 foundations; H08/H15-M1 cases; G07. Existing unsigned refusal, private pipes or mounted views do not prove positive signed installed custody/paired success. |
| B11 — Open: diagnostics/privacy/recovery | Bounded current refresh/health/support, capacity isolation, selected shared conversation retention/disposal/derived lineage, audio retirement, protected exports, maintenance/update/backup/restore/transfer and task-to-original continuity. Preserve unknown obligations/spent roots; quarantine stale restored scopes/context. | WOH.03/05/14/15/16/18 plus actual B01 shared storage; H14/H16/H18-M1 and H06-T17/T19/T25; G08/G09. Inspect real data/canaries and exercised recovery, not queued-cleanup or DB-only success. |
| B12 — Open: whole M1 release | Join J01–J10/C01–C15/C20 to actual English speech, native/paired receivers, current shared/native owners and exact hardware; independently review measured task quality, operational failure and public/licence claims. | Requires B01–B11 and G01–G10. Retain exact subject/evidence per owner; no fabricated/mock/default-excluded criterion or missing mandatory installed/physical case closes M1. |

### Shared source allocation and concrete producer entry work

| Owner | Reused responsibility / work required before dependent consumption |
| --- | --- |
| Refpath public execution/conversation | Selected local agent/turn/task/routing/tool/funding/cancellation and private persistence contracts; CV.01/CV.04, IN.23/IN.38 scoped transport/identity and IN.44 voice contracts. Qualify current Home peer/principal association, admitted export, executable ABI/provider install/retirement, finite scopes/resource controls and original-task recovery. Missing shared limits/lifecycle extend that producer; no Home clone. |
| Refpath speech/provider | Qualify actual English local ASR/TTS/model, private audio artifact/lease/format conversion, offline assets/rights, installed hardware/latency and failures. Current whisper.cpp native/fake-executable conformance is not real audio/ABI/installed Home proof. Existing generic voice connector proposals do not supply a WoTEx Home endpoint. |
| WoTEx TD/TM/WPF/runtime/UDP | Existing generic parser/interpreter/units, public consumption and protocol mechanics. Home owns accepted meanings/target/risk/trust/report policy. New schema/operation/radio needs its generic owner plus exact Home profile/correspondence and hardware evidence. Do not create a second parser/protocol runtime from agent output. |
| WoTEx routines / ExBooking | Reuse selected public calculation/source/occurrence/civil/clock interfaces; complete the actual Decision/Collection/composed semantics required by the offered profile, independent correspondence and active membership before Home admission. Newer sibling proof is not the consumed pin. No parallel calendar/scheduler/kernel. |
| ExMaude | Existing bounded result/receipt/checker, no generic positive safety certificate. Complete missing Home semantic correspondence/restricted admission at its native owner; composed work stays gated until its actual proof profile exists. |
| Home | Native domain/Store originals, current grant/custody/clock/qualifications, device and scene/routine policy, consumer-only facade, native audio permission/presentation, installed local/paired lifecycle and physical evidence. Device workers never receive Store handles/operator bearers. |

Entry source `3dadb1d11a8048b9d5098d2c8d636dd748d09414` was clean. Existing
Mix source/lock selections are unchanged: WoTEx UDP
`dde1837f03f88a847ba5a0ec4479711a5ff1cf96`, WoTEx profiles/runtime
`687a5cd70267fa47dbfb36e28eccad6ef2964fdf`, routines
`5fc17f4a8b36da9ca2b6f4dd19a6ee1a63bfdcaa`, ExBooking
`3fa614cd3cf106aba7161e17015969634afc3730` and ExMaude Hex `0.5.0`.
Refpath `ea4eb256d453ef828cae5214948d819f9e7d3b94` was inspected during planning;
it is **not** a selected/installed Home dependency. No source pin is upgraded
by accepting this target. Generic producer work remains at its existing repo
owner; the present authorization writes Home specs/tracker only.

### Required qualification gates

These gates select evidence for the owning spec cases, not new acceptance
semantics or a second progress ledger. All are open.

| Gate | Required evidence and refusal |
| --- | --- |
| G01 Shared consumption | Exact sources/licences, public contracts/export/ABI/configuration, storage/custody and actual Home receiving path. Missing admin/raw/protected producer ability is refused, not assumed. |
| G02 English local voice | Complete installed local ASR/agent/TTS/artifacts and audio endpoints, actual independent English utterance/repair corpus, WAN-cut, latency/resource and permission/output lifecycle. English-only; no text-only or fake-audio substitution. |
| G03 Current authority | Actual local/paired/tool/native read and mutation paths with current principal/peer/controller/grants, revocation/expiry/changed basis and protected exact-subject review. Voice/model/ReviewGate capacity is not approval. |
| G04 Real cohort | Exact lights/capabilities and read-only detector/coordinator; physical read/write/readback/transition, independent observation, alarm independence, WAN-cut and drift/interruption. No inherited brand/signature/fixture qualification. |
| G05 Scenes and rule safety | Exact member/active-set scope, partiality, whole-Thing arbitration, isolated shadow, supported positive admission and current review/activation. Unknown/inconclusive/conflict fails closed. |
| G06 Temporal execution | Actual selected producer/clock/input/civil contracts, occurrence identity, lateness/catch-up, overrides, current author/grants and restart/clock loss. No unselected kernel or autonomous profile inferred from pure calculation. |
| G07 Installed native/paired tasks | Signed actual service/custody/certificate-clock/audio, native and paired tasks, keyboard/VoiceOver/reflow/focus/review/original continuity and sleep/lock/disconnect. Mounted/unsigned-only evidence is insufficient. |
| G08 Privacy/disposal/restore | Scoped canaries across conversation/audio/derived data/logs/export/backup, real retention/disposal and suppressed stale restore, native unresolved originals/spent roots retained and single owner fenced. |
| G09 Operational boundedness | Actual model/speech/storage/capture/tool caps, overload/noisy-neighbor, cancelled/dead workers, observations/alarms responsiveness, device/host/power/restart recovery and no duplicate effect. Report measured supported conditions, not a universal safety/performance promise. |
| G10 Whole release | Independently review J01–J10 and C/U/A/P traceability, consented English quality evidence, precise public support/help/release claims, accountable licensing and exact retained evidence for every mandatory owner case. Documentation checks cannot close installed/physical or legal/safety qualification. |

### Documentation delivery and validation handoff

The approved target is written at the existing semantic owners and their three
native/paired receiving contracts, the canonical index/catalogue and this
tracker. Existing implementation/evidence axes remain unchanged. Original
requirement/case IDs and historical test/host/physical limitations remain;
new voice and M1 cases are open. The local-controller mechanism plan links here
without creating another M1 ledger. No runtime, migration, fixture, dependency,
model, firmware, app or producer code is implemented by these changes.

The initial native catalogue check passed all 22 canonical contracts using the
actual `Mix.Tasks.Woh.Spec.Check.check/1`. Final checks, review findings and
session-owned cleanup are recorded below before handoff. The first engineering
work remains B01/B03's exact public read/refusal/original contract alongside
B04/B10's existing real cohort and installed-custody critical path; do not start
live dispatch or broad agent tools to work around missing prerequisites.

### Executed documentation verification — 2026-11-01

The documentation delivery covers 26 existing files: nineteen canonical owners,
three native/paired receiving contracts, index/catalogue, this tracker and the
existing local-controller plan's link to it. No new tracker, runtime, schema,
fixture, model/provider, dependency or host procedure was introduced. All 171
original catalogue cases and original numeric requirement IDs are preserved;
51 open cases bring the catalogue to 222. All contract implementation/evidence
axes are unchanged. C01–C20, J01–J10, U01–U08, A01–A06, P01–P06, B01–B12 and
G01–G10 have complete nonduplicated inventory rows; all packages/gates remain open.

Two review passes followed ordinary voice, protected review, scene partiality,
routine/clock, revoke, original recovery, privacy and restore paths across their
actual owning source/contracts. Corrections made before handoff:

- Kept the classifier's original demonstration/evaluation evidence while
  replacing its future-microphone/ten-command framing for the new M1 profile.
- Bound the consumer to the actual seven-key Mutation/API and native original.
  Explicitly identified that `Authority.submit/3` produces a held receipt;
  native qualified execution is additional open work, not an ACK-to-success path.
- Made native review capacity distinct from current human approval and
  retained all current Store/revision/profile/qualification checks.
- Put spoken disposition/uncertainty first, stop TTS before the next capture,
  and recheck source audience/revocation before prompt/history/buffer/output
  use. Output limits or an old transcript cannot hide or bypass those facts.
- Preserved exact independent routine/physical/installed proof gates and
  prevented wider lighting, media, appliance or voice support from inheriting
  a narrower software/profile result. Updated index/version dates and table
  structure without rewriting historical evidence dates.

Executed `mise exec -- mix woh.spec.check`: exit 1, because this checkout lacks
its declared dependencies (including the selected WoTEx/ExBooking/ExMaude,
yaml_elixir and native/ML packages). No dependencies were installed. Executed
the same existing checker source directly using:

```sh
mise exec -- elixir \
  -pa /Users/futhr/Code/refpath/_build/dev/lib/yaml_elixir/ebin \
  -pa /Users/futhr/Code/refpath/_build/dev/lib/yamerl/ebin \
  -r lib/mix/tasks/woh.spec.check.ex \
  -e 'IO.inspect(Mix.Tasks.Woh.Spec.Check.check("docs/specs"))'
```

Result: `{:ok, 22}`. Read-only parser application versions yaml_elixir 2.12.2
and yamerl 0.10.0 match Home's `mix.lock`. The checker validates actual catalogue
identities, versions, case references and dependency cycles; its predicates were
not replaced. Additional bounded documentation queries confirm preserved
statuses/requirements/cases, fifteen added local links, inventory and new table
shape, no untracked files and changes confined to the 26 allowed documents.
`git diff --check` passes. No application, database/Store, speech/model,
browser/native accessibility, installed host/paired transport, hardware,
network/power or deployment test ran. The check establishes documentation
consistency; G01–G10 still require their real evidence. Shared read-only parser
libraries/caches and private retained Home data were not changed.

Final boundary checks retain the clean entry's original 204 inspected documents
and confine the patch to the 26 intended documentation paths. Dependency/source,
native code, tests, schemas and fixtures remain unchanged; no `deps` or `_build`
directory was created. The existing catalogue check was rerun on the final
canonical-spec tree and again passed all 22 contracts with preserved original
statuses/requirements/cases. Whitespace checks passed after handoff edits.

Session cleanup removed only
`/var/folders/mn/3p3l7s893gn5lx3d4vybx_j00000gn/T/wotex-home-agentic-specs-oe0hpwfb`.
All entries were owned by UID 501, with no symlink or live reader
(`lsof -nP +D`, exit 1 with empty output). Removed 12 regular files and reclaimed
275,227 logical bytes / 303,104 allocated bytes; verified that exact directory
is absent. Shared parser/build caches, private custody/histories and other
sessions' outputs were preserved. No containers, images or volumes were created.

## Local controller product delivery

The [universal routines plan](universal-routines-delivery.md) records generic
producer work in ExBooking/WoTEx and WOH.20's bounded consumer work. Each
producer's current handoff owns its next executable slice; new shared behavior
is defined and qualified there before Home consumes it. The M1 packages above
govern joined Home adoption while the current durable/installed-host/physical
critical path stays required. No dependency is updated implicitly.

The [local controller delivery plan](local-controller-delivery.md) extends this
critical path with complete standalone Mac workflows, autonomous scheduling,
an optional shared Linux/Pi service, paired LAN clients and independently
authored standard sensor mappings. Its [research record](local-controller-research.md)
audits sibling contracts and current primary sources. WOH.19 owns shared-host
delivery; WOH.04/15/18 own the new scheduler/connection/mapping successors.
These mechanisms are planned, not implemented by accepting their contracts.
The current durable transfer/recovery work below remains first in that sequence.
A dedicated Nerves image stays optional; a shared server does not require
replacing the host OS, and no server unlocks otherwise supported core features.

## Portable profile and optional helper build track

The [portable profile plan](portable-profile-admission.md) owns the consolidated
production sequence: closed data import, explicit local approval, Store-owned
selection/retention/recovery and actual host/device qualification. WOH.18 and
ADR 0010 define that planned path; existing rule source/compiler remains the
automation boundary. Ordinary data profiles require no Wasm engine.

Portable data phases P1–P3 now implement bounded inert import, fixed direct-power
binding/projection, private synchronized custody, finite quotas/leases, local
maintenance-gated approvals and reviewed initial/replacement selection. Schema
20 retains qualification history, selection generations and all four owning-
domain pins, with bidirectional startup/recovery validation. Current use repeats
call-local byte/runtime checks; collection retains every historical reference.
Shared Host custody and reviews start after Store ownership. P4 now exposes the
closed authored Authority/API/CLI import, review, select/revoke/status/collection
surface and separate manager/operator bootstrap. The native client validates
these routes and shares live trust/receipt parity with the CLI. The native window
composes profile import, review, selection, revocation and uncertain-reply
recovery. Fresh artifacts for subsequent source changes and actual
installed-host/device acceptance remain open.
Synthetic fixtures do not promote these mappings to physical qualification.

The [component plan](component-extensions.md) owns optional WIT helpers. Its
implemented import-free previews have no Store/device effect; [historical
validation](component-extensions-validation.md) records independent authors and
failure retirement. The [original-Port retirement repair](../provenance/component-retirement-2026-10.md)
now holds one aggregate VM slot through cancellation and Runner restart, fencing
admission when exit evidence is lost. Whole-VM restart and native memory/OS
containment remain open. A production helper needs a named mapping benefit plus
those gates, then the shared lifecycle
and physical evidence. The direct-power critical path below retains current
compiled profiles, the full runtime basis and default-disabled dispatch.

## Current checkpoint and next critical path

Home is one Mix/OTP application. Namespace boundaries are not independently
released packages. Unix-socket, CLI and trusted setup adapters enter through
`WotexHome.Authority`; only the Store owns SQLite, its host lock, transactions,
boot clocks and live claimant monitors. Stateless Store domains own canonical
receipts, enrollment/principals, observations/refresh, qualification, overrides,
execution, read projections and shared schema/integrity/journal primitives.
Device sessions never receive a Store connection or bearer credential.

Provisioning/storage and command policy share one closed permission vocabulary.
Combined qualification, enrollment, review and control permissions remain
independent; qualification alone never grants command authority. Regression
coverage includes the guarded queued/claimed/handoff path, not just provisioning.

The executable direct-power path is now one coherent sequence:

1. A host-owned selected-interface capture discovers and interviews an exact
   LIFX identity. The immutable packaged product-27 and product-22 power profiles can be
   reviewed/enrolled by an authenticated operator; enrollment is not control
   qualification. Enrolled refresh repeats identity and commit-time authority.
2. Submission stores a scoped held receipt. Exact retries, cancellation and
   status preserve the original operation identity. The public socket cannot
   qualify a profile, provision a credential or execute a raw device command.
3. Trusted internal admission and claim require current grants, epoch,
   declaration/resource/generation, fresh reports and the exact signed profile
   claim package. Its compiled-code binding includes every packaged Home/UDP
   module; a structural rewrite requires a new review. Direct-power v1 fixes
   duration to zero before claim. The same supervised worker repeats guards at
   durable handoff, owns its transport and sends only after the marker commits.
4. ACK remains protocol acceptance. Correlated readback and observation retention
   settle observed/contradicted atomically; uncertainty, worker death and restart
   retain unknown. Explicit reconciliation requires an exact newer fresh
   production report, current signed basis and no live old worker. It never
   resends or claims that a matching state proves command causation.

New handoff markers now include the single Store's own boot/elapsed-time pair.
Integrity and encrypted backup checks preserve it through settlement and
restart, reject inconsistent or backwards timing and keep legacy rows untimed.
The direct-power path now repeats a closed Home attempt-rate/spacing policy at
queue, claim and handoff, reading this history and current Store time in the
same transaction. Old or untimed history requires a complete new-boot window.
No-send and blocked work consume no attempt; uncertain/terminal handoffs do.
This is not physical dwell or an admitted rule runtime.

Explicit requests now also have durable single-effect roots, keyed by their
immutable principal/epoch/operation identity. One queue acceptance reserves the
depth-one intent in that transaction; claim and handoff recheck its original
queue journal link. Cancellation, revocation, fencing, reconciliation and
restart do not refund it. New rejected/held/no-send work spends no effect.
Schema 14 retains roots separately from disposable execution rows; legacy
migration marks unknown provenance rather than inventing it, and missing or
ambiguous old queue provenance cannot authorize execution. These are internal
operator-request budgets, not rule-event roots or proof of physical causation.

The deterministic validation entry is `elixir bin/test.exs --socket-free
--firmware-host`, using already-built locked test dependencies. It compiles fresh
source, rejects warnings, checks all catalogue identities and reports excluded
OS tests. `elixir bin/build.exs --dependency-env test` also builds a fresh
unsigned production Home release against that explicitly selected dependency
cache, checks packaged Store/CLI/verifier startup and verifies its inventories.
It does not run the full host/socket smoke. Full CI still runs real socket tests. Swift app/agent and client
fixtures compile for arm64 macOS 15 under Swift 6 warning rejection. These are
source/logic/build checks, not installed-host or hardware qualification.

The native rule policy panel now reads current status, suspends with a revision
check and resolves original admission/activation operations after an uncertain
reply. Independent Swift socket fixtures and live Swift/CLI parity cover the
closed scalar boundary; activation counts are historical barrier results.
Native source editing, admission and invocation are still pending. macOS CI
now includes the health/rule fixtures and live parity task.

Existing additional slices remain supported: scoped draft-rule negative checks,
immutable recorded candidate outcomes and a proposal-only restricted correspondence basis; pure colour planning and
no-send settlement; grammar/local intent proposals; read-only Shelly frames and
interview; bounded explicitly verified Hue HTTPS resource reads; optional Matter export/proposal shapes; encrypted quarantined backup;
macOS/Nerves development packaging, inventories and read-only board probes.
None gains production authority from this structural rewrite.

The closed Home compiler now binds canonical source and complete IR identities;
the actual sandbox and explicitly negative native projection consume its entries.
Three-valued truth tables, typed thresholds, event origins, 1,620 finite state
cases and a mixed sequential trace compare the machine against independent
reference decisions. The v3 proposal correspondence basis adds these compiler/
source/IR commitments to the complete packaged Home BEAM manifest through the
same internal artifact reader used by the separate Home/UDP profile basis.
Closed receipts can be checked against current inputs and freshly repeated
finite correspondence; changed metadata/code or retained old module versions
fail closed. Native/OS identities and physical qualification remain separate obligations;
the schema 17 subset below supplies durable admission and activation. Named negative-model
omissions remain unproved; a pending proposal result is not upgraded to admission.

Schema 15 now stamps every newly accepted report/current projection with the
Store's own receipt epoch/time alongside unchanged adapter metadata. Replay,
rollback and restart cannot renew that timestamp. Authenticated bounded fact
reads verify the exact journal/declaration/grant basis and keep untimed, expired,
old-boot, future and lab reports unknown. Startup and encrypted staging validate
the retained clock/content links. This is accepted receipt age and preview input,
not source authentication, dynamic invariant policy or rule admission. Existing
qualified direct-power report guards remain separate.

Schema 16 now retains authenticated reported constraints and rechecks them at queue,
claim and handoff. Replacement uses revision CAS and invalidates pending work;
expired/restarted facts and revoked policy authors remain unknown. Integration
cases cover each execution boundary, immutable retry, journal tampering and
quarantined encrypted recovery. Orderly Store shutdown explicitly closes both
SQLite handles, including supervisor shutdown. These are software checks,
not physical safety qualification.

Schema 17 now supplies durable admission, generation activation/suspension and
authenticated explicit invocation for one unconditional ordinary-Light Boolean
effect. Canonical artifacts bind the independent finite correspondence basis,
source-bound IR, exact declarations, current invariant policy and complete Home
runtime. Activation atomically invalidates old work and discloses handed-off
uncertainty; invocation creates held requests with immutable rule origins. All
execution boundaries repeat current rule, invariant and override guards. This
subset has no autonomous scheduler, reported-edge execution or composed proof.
Current status, successor activation, invocation and execution also validate the
complete original activation receipt, epoch and ordered generation journal.
Corruption disables writes without a new receipt, causal reservation or handoff;
live regression cases cover invocation, queue, claim and handoff.

Schema 18 now provides a persistent authenticated host-maintenance barrier.
Begin atomically suspends rules, rejects unsent work and preserves handed-off
uncertainty; new ordinary requests and effect transitions remain blocked after
restart. Original receipts, observations and consistent encrypted backups stay
available. Explicit end checks the original begin identity and current revision
and leaves the active rule pointer empty. Real socket/CLI, rollback, restart,
corruption and all four pending phases are exercised. Artifact installation,
compatible rollback and board recovery remain separate gates.

The native maintenance panel now shares the four authenticated CLI/API routes.
It keeps current status separate from historical receipts and retains an
uncertain operation's exact inputs/original credential for lookup or retry.
Thirty-two independent peer cases and live CLI parity cover begin/end,
invalidated held work, blocked new staging and immutable historical counts.
New changes require a refreshed status and resolved prior operation. The panel
does not install an artifact or activate a restore.

At commit `6df29b1`, a fresh unsigned release passed packaged schema 18
maintenance/retry/restart/backup checks and the separate real private-socket
startup/shutdown smoke. Its macOS app assembled with 24 checked Mach-O files.
The new Raspberry Pi development image also cross-built and passed the image
checker (29 AArch64 ELF files, 1,431 release files, 43,060,888 firmware bytes).
These are local package checks; signed installation and a physical board are
still unqualified. A development-window check corrected registration labels
that overstated what the service status established.

The next critical gate is a real reviewed LIFX cohort and independent read/write/
readback, WAN-cut and crash evidence on the owned host. Normal dispatch remains
disabled until that gate is supplied. Broader rule admission/scheduling,
physical invariant evidence and qualified colour dispatch,
additional device mappings, installed credential custody and fenced restore
remain unfinished contracts. Signed release, board power-cut/radio, Matter
ecosystem and manufacturing evidence require their actual environments.
Do not mark those contracts implemented because deterministic tests pass.

## 0. Establish the executable semantic boundary

Bootstrap the Mix project with pinned Elixir/OTP versions. Implement WOH.00/WOH.01 as pure, bounded data and validation: stable opaque IDs, exact capability operations and units, typed observations, explicit unknown/stale states and a closed command shape. Add read-only WOH.02 candidate/profile matching without giving discovery any command authority. Mark a contract's implementation `partial` when only this subset exists; keep its evidence `missing` until the required cases run in the correct environment.

Exit: invalid/unknown fields and units are rejected, unsupported capabilities never appear as executable operations, and discovery cannot mutate a device. This slice has no driver credentials or physical command path.

## 1. Close the proof and authority model first

Implement WOH.05 policy, WOH.14 durable receipts/outbox and WOH.15 headless authority before attaching physical mutation. The authority epoch changes on fenced ownership transfer; a separate active-rule generation changes on activation. Then implement the closed Home IR, effect domains, three-valued predicates and admission state machine. Specify the restricted-rule proof basis and reject unsupported composed semantics. Tests must kill incorrect priority, unknown-to-false, omitted guards, stale revision and duplicated-effect mutations.

Exit: a rejected candidate has no driver credentials/calls; activation races and crash points are executable tests. The same denied request produces zero driver calls through every available entry point. No AI or live hardware is needed.

## 2. Build one complete local device path

Implement the reusable WoTEx datagram owner and a Home LIFX profile. Use a scripted independent peer first, then the owned old bulb. Read identity/capabilities, enroll, issue an absolute state request and re-observe it. Preserve unknown outcomes and conflicting newer requests. Pass WAN-cut, address churn and restart cases.

Do not block this vertical slice on every planned radio or a native UI. Do not call an ad-hoc raw UDP script the completed Home product.

Gate: pin the WoTEx datagram implementation and its conformance results before claiming the protocol path. A scripted peer is fixture/integration evidence, never hardware qualification. No Home driver receives credentials until the durable writer, authenticated authority and guarded dispatch path are in place.

## 3. Qualify the purchased detector's local path

Select one documented Zigbee NCP family after exact coordinator review. Implement generic serial/NCP and ZDO/ZCL contracts upstream. Interview and qualify the purchased detector through a read-only Home profile. Prove standalone alarm independence and network report behavior separately. Keep OTA, hush and linkage changes disabled. Follow with USB/restart and secure backup/counter continuity tests.

Exit: exact SKU/firmware/coordinator cohort, not a brand claim or pairing-only success.

## 4. Add the real prevention service

Integrate ex_maude for declared conflict and reachability questions. Preserve its current inconclusive semantics. Add generic receipts upstream without claiming a positive verifier exists. A Home compiler/model profile must cover priority, unknown facts, effects and environment assumptions before composed rules depend on it. Keep unsupported proof-required revisions inactive.

Exit: negative draft evidence, bounded runtime prevention, atomic activation barrier and current-state guards. Existing admitted control survives verifier loss only under still-valid assumptions.

## 5. Independent devices and neutral consumers

Add exact local Hue and Shelly profiles. Run unchanged semantic Light operations through different protocols with declared conversion tolerances. Expose the already guarded headless service through qualified API/CLI facades, then add cursor/snapshot consistency, scoped auth, group partial outcomes and external-controller arbitration.

Exit: no vendor branches above profiles and no optimistic physical-success claims.

## 6. macOS installed host

Package an opt-in per-user background controller, authenticated local IPC and a narrow native credential broker. Build the SwiftUI shell against semantic snapshots/receipts. Compose inspect, compare, request-change, monitor and draft-rule tasks at the H08-08 compact, medium and expanded content edges while preserving enrolled Thing, observation-quality, authority, operation and physical-outcome meaning. Test window close, service disable, sleep/wake, logout, Keychain and USB lifecycle under a fresh account. Record the actual host availability limits.

## 7. Required local demonstration profile

The Elixir `mix woh.intent.train` task now checks the pinned base and authored split, trains a native Nx DistilBERT candidate and compares it with exact grammar and a compact character n-gram baseline. One five-epoch run accepted 16/20 held-out allowed phrases after the grammar/alias gate, while both baselines accepted 20/20; all had 0/44 false accepts on this small synthetic set. The earlier Safetensors candidate accepted 17/20 under a different recipe. Both remain rejected. Next obtain an independently sourced cohort, improve and recalibrate the model without weakening the command gate, install a bounded offline inference runtime and pin the artifact manifest in a release. Preinstall all artifacts. The Goatmire run rejects an isolated bad draft with zero physical effects, then executes a legitimately admitted light request. Typed control, verifier failure and RF fallback remain honest alternate cases.

## 8. Release-quality recovery and Nerves parity

Finish update compatibility, encrypted backup/recovery, redacted support export, resource limits and seven-day stability tests. Move the same Home semantics to a selected Nerves target. Qualify real power loss, firmware validation/rollback, radio continuity and optional native model capacity. Do not weaken the specification because an ARM binary or hardware test is missing.

## 9. Optional export and manufacture

Deliver WoTEx's separate Matter server/bridge profile, then qualify exact exported types and independent ecosystem controllers. Neither that bridge nor Siri/Google becomes the home authority. A manufacturable controller follows measured resource/RF needs and Conjunct composition evidence; Connect supports procurement, not runtime control.

## Do not build in the baseline

No active-active actuator writers, safety-state CRDT, globally exposed Erlang distribution, mandatory cloud/broker/database, custom Zigbee PHY, automatic smoke firmware updates, dynamic untrusted profile code, AI authorization, invented exactly-once actuation or a stage fixture with live conflicting rules. These exclusions are design boundaries, not missing shortcuts.

## Open gates tracked by the contracts

- WOH.03/WOH.11: retain the exact UDP owner pin and qualify a Zigbee revision; record each physical cohort, the detector's exact SKU/fingerprint, selected coordinator firmware and manufacturer's safe-test procedure before claiming a local detector cohort. A ZNP backend is a candidate, not a hardware endorsement.
- WOH.04/WOH.07: expand beyond the schema 17 explicit single-effect admission argument only with new correspondence and guard evidence; composed rules still require a separately justified proof profile. A bounded no-finding result cannot admit either profile by itself.
- WOH.05/WOH.08/WOH.15: qualify device-specific TLS/credential behavior, installed macOS identity and permissions, local IPC authentication and old-writer isolation on the actual host.
- WOH.06/WOH.09/WOH.10/WOH.12: replace the rejected local intent candidate with a separately evaluated checkpoint and bounded offline serving path; take the cross-built Raspberry Pi 4 development image through board boot, rollback, storage power-cut, radio and native-worker qualification; qualify supported languages, an ARM Maude binary, exact Matter revisions/server role and manufacturing/conformity evidence separately.
- WOH.14/WOH.16: test SQLite durability on target storage, command crash boundaries, encrypted recovery and radio counter continuity. Unit tests cannot establish power-loss survival or cross-host fencing.

Each release reports unresolved cases with their required environment and exact cohort. Documentation or a simulator never marks a physical, field or certification case passed.

Schema 20 now retains qualification snapshots and complete compatible profile
replacement/history/pin barriers. Trusted Store selection consumes exact held
one-use reviews, repeats bytes/runtime/CAS/deadline guards, preserves original
receipt/claim identity, revokes current evidence and forbids narrowing/rereview
bypass. Target/artifact revocation is possible with missing bytes; reapproval
cannot reactivate history. Current request/rule/qualification/observation/effect
use repeats selected pins and call-local custody/runtime checks. Startup and
encrypted recovery reject damaged selection and owning-domain correspondence.

Initial enrollment and changed-firmware v2 encodings and Store transactions are
now implemented, with absent/tombstone distinction, occupied-identity refusal,
atomic original review/selection, no automatic grants, preserved qualification
history and both historical decoder versions. A scripted registry-supported
product outside the compiled catalogue exercises this path without a Home profile
rebuild; it is unqualified fixture evidence.

The shared Host now supervises private custody and one-use review owners after
Store ownership, resolves canonical OS directory aliases and stops downstream
consumers when transient custody restarts. It refuses malformed existing roots.

Closed API/CLI/native portable-profile operator flows are now implemented.
Exact encrypted retained byte transfer and quarantined directory staging are
implemented. The pure closed controller-isolation signature codec now verifies
exact destination scope, explicit issuer policy and original trusted-clock
expiry; it performs no activation or physical isolation. Next portable-profile
work: destination acceptance and fresh host delivery. Trusted source shutdown,
original archive retry and offline retired-source export are now implemented.
The pure canonical destination review binds source snapshot/barriers, fresh
receiving custody, fixed recovery scope and domain/counter commitments to the
signed isolation scope; it creates no activation or trusted keys. Trusted
`new-owner` now provisions immutable private destination identity outside the
archive without starting Home or granting permission.
The trusted retired-archive basis now retains exact source/container hashes and
a bounded complete row/schema commitment; quarantine comparison excludes only
the exact integer marker and creates no activation.
Complete retained domains now include revoked/read-only Things, superseded
identity/selection history and unresolved historical targets. Known complete
LIFX software dependencies can classify counter absence; missing, legacy or
unsupported data stays unknown and cannot form accepted isolation scope.
Canonical destination acceptance operations/receipts and historical issuer policy
now have pure codecs and separate past-signature audit. They cannot activate a
copy or supply current trust/time. Recovery custody and schema 22 acceptance
remain the next durable transition.
Signed v2 domain commitments now include complete original source authority
counts. The inert acceptance matcher rejects any withdrawal count that differs
from that commitment, preserving audit after mutable source rows are cleared.
Historical domain decoding and complete acceptance-row audit now bind all
original documents, signature policy and source counts. Unknown transport and
unsupported historical capabilities remain unavailable; unauthenticated LIFX
cannot use credential revocation as its isolation method.
Schema 22 now retains acceptance documents and extends the maintenance barrier.
Active historical migration preserves authority; retired schema 21 startup
refuses before migration. Quarantine schema installation belongs to the outer
acceptance transaction and rolls back with it. The guarded writer and private
one-use recovery owner remain the next stages.
The destination writer now commits the three-revision epoch/fence/principal/
acceptance transition atomically, verifies exact source counts and preserves all
other retained rows. Original private receipt lookup and successive ownership
history survive restart and encrypted export. The private one-use recovery
owner and foreground delivery now supply actual current byte, owner, trust,
conservative clock and original-challenge guards through operator acceptance.
Private file custody now supports complete immutable domains and separately
publishes the exact private CLI credential before acceptance. Both retain
exclusive synchronized publication, descriptor/ancestor checks and caller byte
bounds; neither creates a live review challenge or activates quarantine.
Transient seals retain original descriptor/file and ancestor identity, rejecting
identical-byte replacement while allowing unrelated sibling publication. Their
custody correspondence carries no secret bytes, current trust or authority.
The standalone private recovery review owner now binds the configured operator
and Store, retains original monotonic deadlines and private file seals, and
repeats current source, owner, runtime, trust and trusted-time guards. It holds
no SQLite handle or transport and cannot recreate a challenge after restart.
Recovery-mode Store integration is now implemented with private operator/owner
identity, no startup migration or ordinary mutation, actual outer transactions
and original receipt recovery before challenge checks. Accepted delivery stays
read-only until closing; death of either owner releases its Store. Foreground
supervision and original operation publication are now implemented. The session
starts only temporary recovery owners, checks the configured operator before
file writes, preserves exact staged profile custody through the final guard,
and publishes the original operation before acceptance. Diagnostic receipt-file
failure leaves a committed receipt recoverable. Timed command-line receiving
delivery now consumes explicit current private issuer/clock custody. Key-free
original receipt recovery creates no challenge or acceptance authority. No
default key or clock confidence is installed by these components.
The private recovery clock mechanism now has closed policy/request/response
codecs and an inert Ed25519 verifier binding the complete installed policy.
Its live original boot owner now retains private seals and monotonic request/
response timing, bounds current UTC conservatively and discards confidence on
expiry or changed context. Transfer preparation now narrows its signed window
conservatively and current guards require both UTC endpoints inside review and
decision windows. An actual receiving Store transaction exercises the signed
boot clock owner. Explicit current isolation-issuer configuration now pins its
original private file and withdraws trust on changed or missing custody, including
an actual final-guard transaction rollback. The real foreground CLI exchanges
bounded private stdin frames and recovers the committed receipt in a second
process. Separate epoch-specific transfer bootstrap leaves old source roles
revoked. Exact retained compiled enrollment succession permits fresh-owner
re-review without target or qualification grants; profile selection can use
its validated transfer barrier. Original histories survive re-review and two
accepted ownership transitions. All 895 development tests pass with four
optional native-backend skips; real socket and child CLI cases ran.
Schema 21 source retirement preserves original private history and
permanently refuses further writes; legacy migration grants no authority and
retired restore remains quarantined. Physical qualification and installed-host storage/containment gates
remain open. The broader software and hardware release obligations above still
apply; this slice does not complete every product contract.
