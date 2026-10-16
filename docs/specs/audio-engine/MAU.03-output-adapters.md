# MAU.03 — Finite audio output adapters and native groups

Version: 0.2.0. Updated: 2026-10-13. Status: accepted target.
Implementation: planned. Evidence: missing.

Allocation: consumer/independent playback component, not a WoTEx package.
WoTEx WST.01–02 supply optional protocol-stream joins; generic protocol timing
and packetization do not own DSP, capture/render or acoustic qualification.
Device/cohort definitions are externally supplied, never a WoTEx model catalogue.

## Scope and dependency boundary

The separately selected audio component connects a common music timeline to independently
installed Sendspin, AirPlay, Cast, native-group/HTTP-pull and host-audio profiles.
No generic adapter promises every device, firmware, codec or group topology.
Unsupported cohorts are explicit refusals, not a requirement to modify hardware.
Consumers enroll identities, permit actual audible targets and qualify cohorts.
The producer owns packet/session behavior and bounded transport resources.

[MAU.01](MAU.01-media-session-values.md) owns immutable participants, complete
audible descendant closure, one route per active session, normalized volume and
typed outcomes. [MAU.02](MAU.02-timeline-synchronization.md) owns one sample
timeline, future anchors, clock mappings, finite queues and sync grades. Timing
capability is not measured alignment. [MAU.04](MAU.04-native-host-capture.md)
owns explicitly started native processes and private capability custody.
Existing core/Runtime ports remain independent; no base protocol package gains
a dependency on audio or consumer product semantics.

## Installed profile and host port

**MAU03-01 — Finite profile.** Each profile declares exact protocol/source
revision, adapter build digest, platform/backend, cohort selectors, source/codec
formats, supported controls, authentication/trust strategy, timing kind,
maximum startup/remote buffer tail, descendant-resolution method and cleanup
behavior. If firmware cannot be reported, explicitly qualify only the particular
enrolled physical unit/host route with `firmware_unreported`; never infer a
model-wide wildcard. Unknown required profile fields refuse. A profile can narrow the
MAU.01 limits; it cannot widen them or install code from device metadata.
Before any cohort code claims support, freeze its wire/codec vectors and
controlled-peer acceptance in the profile's executable schema/fixture directory.

The planned Rust `OutputAdapter` port provides `probe`, `prepare`, `start_at`,
`push_audio`, `pause`, `resume_at`, `set_volume`, `stop`, `status` and `close`.
All calls take session/route epoch, explicit deadline and cancellation context.
Unsupported controls return `unsupported_operation`; raw actions are absent.
`prepare` receives a resolved host capability, not a public URL/key. `start_at`
reports requested and accepted anchor separately; an adapter that cannot honor
the anchor reports estimated/unknown timing. `push_audio` consumes bounded queue
credit and returns accepted frames, never a playback-success result.

| Limit | First profile ceiling |
| --- | --- |
| Startup | 10 seconds total, including resolution/pairing readiness; interactive pairing is a separate consumer setup operation |
| Control | 5 seconds absolute deadline including queueing, except prepare/open startup above; no deadline extension on retries |
| Stop/close | Initiate within 250 ms of retirement; local resource cleanup ≤1000 ms; remote buffered tail retained separately |
| Transport resources | One owned control session and at most two media connections per participant; sixteen active routes engine-wide |
| Control body | ≤64 KiB after decode/decompression, depth ≤16; no unbounded XML/JSON or external entity resolution |
| Discovery | Separate explicit probe: ≤10 seconds, ≤64 candidates, ≤256 KiB accumulated frames; no automatic enrollment |
| Live audio | MAU.01 per-route/global byte bounds and MAU.02 source stall/lifetime; no unbounded historical cache |
| Status | Current route epoch/sequence, source/format, reported transport state and timing confidence; no private route/key/URL in public diagnostics |

## Selected adapter classes

**MAU03-02 — Native Sendspin.** Implement the exact selected upstream spec
revision, including discovery direction, handshake, encryption/pairing, format
negotiation, clock synchronization, availability, stream lifecycle and frame
bounds. Both client-initiated and server-initiated connections must be supported
where the selected spec requires them. Keep source and player roles separate:
permission to play is not permission to capture or inject audio. Unpaired access
is disabled in the consumer's production profile. A legacy plaintext test peer
is labeled a software fixture, not a compliant production implementation.

PCM and FLAC are the required first engine formats. Repacketize source frames
into complete selected-spec codec units and legal chunk durations; no format
switch discards retained audio or shifts the shared timeline. Declare current
upstream gaps explicitly. The inspected Rust library is client-oriented and its
server proposal is unmerged; that proposal does not establish current pairing,
external-output bridging, per-client format or full spec parity.

**MAU03-03 — AirPlay.** Support independently qualified legacy RAOP and modern
AirPlay paths rather than assuming a Rust RAOP library supports current receivers.
Resolve current device capabilities, pairing and timing route before start.
Preserve the receiver's selected access restrictions; no downgrade, global
verification bypass or removal from a native ecosystem is an automatic recovery.
The adapter records whether authentication is modern, explicit legacy trust or
unavailable. Opaque device/account/credential material stays in host custody.

A native helper may provide transport/encoding and a shared PTP clock while
Rust owns session policy and the source timeline. It must report actual accepted
start anchors, clock readiness, queue bounds and loss. Failure to establish the
selected shared clock withdraws the grade or refuses the profile; it does not
silently retain `clocked`. Local wall-clock changes invalidate Unix anchor
projections. Registering an AirPlay-looking bridge for an HTTP-pull output does
not turn its final leg into scheduled AirPlay playback.

The inspected helper documents `--auth` credential input and printed pairing
material. Before production adoption, add or select a private inherited-FD/IPC
credential intake and private pairing-result channel, with redacted diagnostics.
Do not launch its credential-bearing CLI examples from this adapter. This is
a named generic helper prerequisite/contribution, not an already available API.
Authentication/trust class stays visible separately from the synchronization
grade; legacy plaintext/local trust cannot acquire encryption by earning a grade.

**MAU03-04 — Cast.** Provide two explicit route profiles: ordinary Cast media
playback/native group, and a selected Sendspin receiver running on compatible
Cast firmware. Ordinary Cast can play one finite/live encoded stream; expose
its actual timing as estimated or opaque until independently measured. A native
Cast group is one adapter route with every enrolled member resolved and granted;
the native system's internal sync is not evidence of alignment with other routes.

Probe the exact APIs used by a custom receiver. The inspected Sendspin receiver
depends on Web Audio scheduling; firmware without those APIs refuses that
profile. This does not prohibit experimenting with another ordinary-Cast adapter.
Such an experiment starts as best_effort and earns a grade only through MAU.02
evidence. No firmware downgrade, replacement board or hidden service install is
part of fallback. Changing profile requires consumer selection and new basis.

**MAU03-05 — Native group and HTTP pull.** An adapter for a native speaker
system may serve a privately authorized music stream and control its enrolled
coordinator through the installed local API. Enumerate audible descendants and
current coordinator before prepare and immediately before play/group/volume.
An external group change, takeover, coordinator change or unresolvable member
invalidates the route. Do not silently take over a native queue, add speakers,
restore an old group or infer permission from a same-brand identity.

HTTP pull does not imply exact playback-time control. Report whether start,
position and clock feedback are precise, estimated or unavailable. A fixed
calibration may support calibrated music under an exact cohort; source-position
polls and TCP delivery alone do not establish a 20-ms acoustic bound. Native
grouping behind a scheduled coordinator is a separate qualified route profile.

The first stream server binds an explicit private interface, with one
cryptographically random ≥128-bit capability per participant/session epoch,
resolved privately by the host. It permits only the selected live stream and
bounded reconnect behavior; no arbitrary file, directory, source URL, redirect,
remote fetch or open proxy exists. A network source and output stream use separate
capabilities. Header/connection parsing obeys the limits above. Repeated GET/range
requests cannot revive an expired epoch or replay retired history. Exact live
framing/content-length/codec behavior must be specified in each cohort; lying
about a file length is not a generic compatibility default. Plain LAN audio
transport is labeled accordingly, never authenticated or encrypted by implication.

**MAU03-06 — Host output and Bluetooth.** Open a specific OS audio device,
never whichever output is currently the default. Bind its stable enrolled route,
OS generation, codec/rate and hardware clock/latency characteristics. Classic
Bluetooth audio is sent through the platform audio backend; BLE/GATT support is
neither necessary nor sufficient. The source host may be different from a nearby
output bridge, provided both follow the same timeline and private enrollment.

Separate measured host/DAC timing from unreported wireless/speaker buffering.
Current OS latency information plus a measured tail calibration may establish
calibrated playback; a number returned by an API is not whole-path evidence.
Route changes, codec changes, reconnect and standby invalidate the current basis.
Report unavailable while a portable speaker is off/out of range. No remote wake,
speaker battery telemetry or standby suppression is inferred from A2DP support.
Native double/group playback is admitted only when its complete assembly is
enrolled and the effect domain includes all audible descendants. Otherwise the
initial profile refuses that topology.

**MAU03-07 — Volume and evidence.** Hardware volume maps through installed
cohort vectors to the normalized control fraction; this does not promise equal
loudness, linear sound pressure or a dB value. Round to a device step without
exceeding the granted ceiling. Software gain applies only when that profile
selects it; never apply both hardware and software attenuation accidentally.
Device buttons/native controllers may change state; refresh the current report
and expose takeover/partial state instead of overwriting it with an old request.

## Loss, continuation and acceptance

Cancellation or revocation stops new audio, attempts allowed session cleanup and
retains uncertain remote tails. Remote stop/pause requires confirmed ownership
of the same source/session/route. After external takeover, close only this
session's stream/connection; do not stop or replace another controller's music.
Protocol retries are bounded inside one epoch
and original deadline. Unknown play/control handoff cannot automatically become
a second start. Reconnect produces a fresh route/session generation and requires
explicit joining; a reconnect event supplies no source or control permission.

| Case | Requirements | Stimulus and falsifier | Evidence |
| --- | --- | --- | --- |
| MAU03-T1 | 01–03 | Independent Sendspin/RAOP/modern AirPlay peers reject wrong format, pairing, clock and old epoch; no hidden downgrade or successful ACK-as-audibility | Protocol/native |
| MAU03-T2 | 01, 04 | Cast receiver capability missing; ordinary Cast still available only as separately selected profile; no false sync grade | Independent receiver peers |
| MAU03-T3 | 01, 05 | Pull stalls, malicious headers/ranges, expired capability, extra native-group descendant and takeover; bounded cleanup and zero unauthorized source/member | Real local HTTP plus native-group peer |
| MAU03-T4 | 01, 06 | OS default changes, Bluetooth disconnect/off/codec switch and opaque cascade; no audio reroutes to another device and old calibration retires | Installed platform plus exact hardware |
| MAU03-T5 | 02–07 | Mixed real adapter cohort passes MAU.02 acoustic campaign or is explicitly classified best_effort/unsupported; no brand-wide claim | Independent physical |

Primary research: [Sendspin Rust server proposal](https://github.com/Sendspin/sendspin-rs/pull/87),
[AirPlay helper](https://github.com/music-assistant/airplay-cli/tree/0974a3175913a8f19b47ccdd5ccb6fdf9f2f704a),
[Cast receiver limitation](https://github.com/music-assistant/support/issues/5297),
[AirConnect timing](https://github.com/philippe44/AirConnect/tree/5fdb61e20de59bac5dbda9f6e2ed56ce549ccabd),
[Bluetooth bridge](https://github.com/trudenboy/sendspin-bt-bridge/tree/9d55b3f0c089920c91c8448764e7ce610a65352d).
Inspection is not interoperability evidence; exact profiles/artifact notices
must be reviewed before source adoption or redistribution.
