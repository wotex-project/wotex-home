# Whole-apartment music delivery

Version: 0.2.0. Updated: 2026-10-13. Status: accepted build order.
Implementation: planned. Evidence: missing.

Deliver one music session from computer/Spotify audio or enrolled local media
to as many qualified existing speakers as the selected policy permits. The
candidate set includes PLAY:1, HomePod mini, H2E, the bedroom Google speaker,
confirmed WONDERBOOM 2 and The Frame. The default minimum is calibrated; weaker
best-effort groups require explicit selection. Surround is not a delivery gate.

## Owners and independent critical path

[WOH.21](../specs/WOH.21-apartment-music.md) owns Home source/target authority,
durable originals, qualification and UI. Generic Rust/media/timing/adapter/host
requirements belong to the [selected playback component](audio-engine-delivery.md)
under MAU.01–04 in `docs/specs/audio-engine/`, outside WoTEx. Select its owned
independent/consumer source project/facade before implementation. WoTEx WST.01–02
own optional protocol-stream joins and WPF.01–02 interpret externally supplied
device definitions; neither ships a full playback engine or speaker catalogue. Audio is optional and must not become a base
WoTEx, protocol, ExBooking or routine-kernel dependency.

Ordinary music can progress independently of the
[universal routine programme](universal-routines-delivery.md). Later media
routine steps consume its current admitted operations; they do not supply
new authority, sources, clocks or qualification. Source custody/capture and
device control are distinct. No installed service, physical dispatch or
dependency upgrade is performed by writing this plan.

## Ordered deliverables and gates

| Stage | Concrete work | Exit condition |
| --- | --- | --- |
| M0 requirements | MAU.01–04 and WOH.21, inventory/source research, exact limits/originals/grades and independent trace review | Contract/catalogue/link consistency; no hidden defaults or capability-as-physical-evidence claim |
| M1 upstream cohort | Select the owned component/source project and exact facade; audit Rust main/server PR against exact current Sendspin spec, time filter and native transport notices; select coherent exact source/archive cohort; specify private AirPlay-helper credential/pairing channels | Gap/compatibility manifest and logical local contribution patches; no source assumed merged/released or secret-bearing helper CLI adopted |
| M2 generic engine | Allocate independent/consumer component Rust scaffold and facade; closed schemas/values, source frame/IPC, timing and bounded queues | Independent clocks/formats/canonical bytes, pressure, original retirement and fault cases; application-free public archives |
| M3 host sources/output | Native specific process-tap/file source and specific Core Audio output, consent, guard lifetime and private source custody | Installed permission/PID/default-route/sleep/revocation cases; one output works without network/optional services |
| M4 first mixed proof | Add WONDERBOOM 2 Bluetooth and HomePod mini AirPlay; measured per-route tail calibration | Exact host/device/firmware-or-unreported-unit/codec cohort passes 1000 probes/60 min plus reconnect; no false synced state |
| M5 Google routes | Identify bedroom model/current firmware; native Cast group, compatible custom receiver or separately selected Bluetooth fallback | API/firmware probe and native group closure; each selected route graded from actual evidence, unsupported paths refused |
| M6 Sonos and TV | Exact PLAY:1 local source/favorite/HTTP profile and The Frame model; explore scheduled coordinator/TV receiver only as separately reviewed paths | Playability separate from sync; native takeover/member changes, content loss and measured classification; no required new purchase |
| M7 Home authority/UI | New MediaPlayer/group/source semantic and journal/API schemas; per-child original/guard flow, group/member volume, source picker and exclusions | Real Store/worker fault cases; no broadened capture/target grants, replay, second writer or optimistic group result |
| M8 installed delivery | Signed native custody/capture, optional shared-server route ownership, backup/transfer, clean artifacts and notices | Appropriate host/archive quality milestone and exact-device/WAN/restart evidence; no inferred board/ecosystem qualification |
| M9 optional routine join | Qualified media action/completion/effect-domain mapping into WOH.20 and generic WRO contracts | Independent composed partial/unknown/cancel traces; ordinary music still works with routines/AI/voice/Matter disabled |

M3/M4 producer lab proofs use explicit private test authorization and controlled
source/outputs; they do not bypass M7 or enable production dispatch. Implement
M7's permission/journal foundation before any Home integration that sends real
production controls. Software fake outputs can develop M7 in parallel with
physical route assessment without changing evidence status.

Each device assessment ends with a qualified profile, an explicit best-effort
classification or a documented unsupported refusal. A rejected legacy route is
not repaired by silently loosening the group's policy or inventing a public API.
The all-supported UI includes only the explicit currently authorized/qualified
resolved snapshot and reports every exclusion.

## Validation and contributions

Run focused constructor/schema/timeline/adapter/IPC/Store tests as each mechanism
lands. Use independent byte/rational-clock encoders and reference Sendspin peers,
not only tests mirroring implementation. Full changed-package, native and host
quality checks occur at stable milestones. Documentation work uses contract,
reference/metadata and whitespace checks; no unrelated application suite is a
documentation gate. Actual quality results belong with exact source/evidence.

Physical synchronization follows [the lab procedure](../labs/audio-synchronization.md).
Record source/profile/build/toolchain/device/firmware/codec/clock/calibration,
test setup and actual outcome. Reconnect/standby/codec change, one stalled member,
source loss, WAN loss and host sleep are separate cases. Preserve failed results
and historical evidence; never edit a digest to carry an old claim forward.

## Design review record

The documentation walkthrough covered local-file EOF, live source loss,
pause/resume, late join, required/optional failure, queue exhaustion, retired
original retry, host loss, revoked capture/grants, native group change and
external takeover. Iteration made the following requirements explicit:

- Bounded originals use a high watermark; evicted requests cannot execute again.
- Group synchronization needs combination evidence or composable error bounds;
  independently qualified speakers do not automatically form a qualified group.
- Normal file EOF drains; live/invalid source ingress affects only its session.
- Separate playback epochs prevent stale controls/guards from affecting resume.
- Native host deadlines use one explicit OS clock coordinate across processes.
- Source framing, cumulative credit and logical EOF have closed private IPC shapes.
- Revocation permits cleanup only while ownership remains confirmed; takeover
  cannot trigger a stop of another controller's source.
- AirPlay helper adoption requires private credential and pairing channels.
- Prepare/control deadlines bound handoff; a future acoustic anchor is separate.
- Bluetooth/native-group outputs require the complete audible effect domain.

This is design review, not executed engine, interoperability or acoustic evidence.
Implementation must generate independent byte/clock/lifecycle vectors from these
contracts and report any discovered conflict to its owning contract before code
or a support claim is broadened.

Reusable upstream contributions may include Rust server/current-spec parity,
external-output ports, native clock feedback, per-output resampling, bounded
join/reconnect behavior and conformance vectors. Household policy, room labels,
Store/schema and private device data stay in Home. Prepare logical local commits
when integrated in the main workstream; pushes/releases remain human actions.

## Research and remaining entry facts

[The research record](apartment-music-research.md) pins inspected upstream
snapshots and the WONDERBOOM 2 confirmation. It is not selected dependency or
physical evidence. Required facts include exact Google/TV hardware, current
receiver firmware/API surface, Sonos S1/S2/firmware, actual capture/output host
and private enrolled output identities. Unreported firmware needs explicit
unit-scoped qualification. These facts block only their device-specific stage,
not generic engine/schema/timeline work.
