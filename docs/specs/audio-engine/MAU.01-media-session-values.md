# MAU.01 — Generic media sessions, sources and participants

Version: 0.2.0. Updated: 2026-10-13. Status: accepted target.
Implementation: planned. Evidence: missing.

Allocation: consumer/independent playback component, not a WoTEx package.
WoTEx WST.01–02 supply optional protocol-stream joins; generic protocol timing
and packetization do not own DSP, capture/render or acoustic qualification.
Device/cohort definitions are externally supplied, never a WoTEx model catalogue.

## Purpose and ownership

A separately selected consumer/independent audio engine represents one music source
playing on a finite set of outputs. A portable Rust engine owns audio buffers,
timing and adapter sessions. The Mix facade owns validated values and an explicit
consumer-host port; it has no application callback or dependency-load effects.
The consumer supplies enrollment, permission, source custody, trusted clocks,
supervision, durable operation history and physical qualification. No producer
library gains consumer credentials, a database handle or a device-control grant.

This is the consuming project's accepted component contract, outside the WoTEx
package family. No Rust artifact or independent public facade exists yet. Before
implementation, select the owned component/source project and exact host/facade
cohort. Do not register the playback engine as a WoTEx protocol package.
Core TD/TM interpretation, Runtime Form selection and existing BLE mechanics
remain separate. Audio over Bluetooth uses an audio output/A2DP adapter, not
GATT writes. Routines are an optional consumer of media actions, not an engine
dependency. Multiroom mono/stereo music is the initial scope; channel-assigned
surround, video lip synchronization and microphone conversation are excluded.

## Terms and dependencies

A **source** supplies decoded audio under a consumer-owned authorization and
availability lifetime. A **participant** is an explicitly enrolled output route,
including every audible descendant of a native group or output assembly. A
**group revision** is immutable membership and playback policy. A **session** is
one volatile execution of a group revision and source revision. An **epoch**
distinguishes runtime/clock incarnations; matching names never preserve an epoch.
An **adapter profile** is an installed implementation/cohort contract, not
downloaded code. A **qualification** binds measured evidence to that profile,
source/build, hardware/firmware, route/codec and calibration identities.

[MAU.02](MAU.02-timeline-synchronization.md) owns scheduling, discontinuities and
sync grades. [MAU.03](MAU.03-output-adapters.md) owns finite transport profiles
and truthful protocol evidence. [MAU.04](MAU.04-native-host-capture.md) owns
native isolation, capture, IPC and artifact custody. Their absence returns
`unsupported_profile`, never discovery-driven fallback. TD affordance references
are optional descriptions; when supplied, their interpretation uses the public
[TD 1.1 contract](https://www.w3.org/TR/2023/REC-wot-thing-description11-20231205/).
A valid TD or selected Form supplies no permission or physical qualification.

## Closed values and bounds

All constructors accept explicit immutable inputs and validated `Limits`.
String-keyed JSON and native structs are independently revalidated. Unknown
fields, duplicate keys/IDs, invalid UTF-8, NUL, nonfinite numbers, cycles and
unsupported discriminators reject; omission of a required member rejects.
Defaults below are applied only to the named optional fields. No environment,
network, clock, randomness or remote JSON-LD lookup occurs in a constructor.

| Value | Exact representation and limit |
| --- | --- |
| ID/epoch | Caller-issued 128-bit identity, 32 lowercase hexadecimal characters; never a MAC address, endpoint or account name |
| Digest | SHA-256, 64 lowercase hexadecimal characters; version labels do not substitute |
| Revision/cursor/sequence | Unsigned 64-bit integer; JSON uses canonical decimal strings `0` or `[1-9][0-9]*` |
| Monotonic time | Signed 64-bit microseconds in a named clock epoch; canonical decimal string, no `-0`; epochs must match before comparison |
| Group | `format: audio-engine.group@1`, `id`, `revision`, `members`, `minimum_grade`, `lead_ms`, `on_member_loss`, `qualification_ref` (opaque ≤128 bytes or null; consumer-resolved combined-cohort evidence) |
| Members | 1–16 entries, each exactly `participant_id`, `route_digest`, `required`; IDs unique and sorted lexicographically; Boolean `required`, default true |
| Policy | `minimum_grade`: `clocked`, `calibrated` or `best_effort`, default `calibrated`; `lead_ms`: integer 250–10000, default 2000; `on_member_loss`: `continue`, default, or `stop` |
| Source | `format: audio-engine.source@1`, `id`, `revision`, `kind`, `custody_ref`, `availability_epoch`, `format_profile`, `live`; optional `metadata`; kinds `local_file`, `application_capture`, `network_input`; opaque custody reference ≤128 UTF-8 bytes; `live` is Boolean |
| Source format | Nested `format_profile` contains exactly `sample_rate`: 44100 or 48000 Hz, `channels`: 1 or 2, `sample_format`: `s16le` or `f32le`; format fixed within a source epoch |
| Participant | `format: audio-engine.participant@1`, `id`, `profile_id`, `profile_digest`, `route_digest`, `route_generation`, `descendants`, `timing_kind`, `qualification_ref`, `calibration_ref`, `volume_ceiling_ppm` |
| Descendants | 1–16 opaque enrolled IDs including the output itself, unique/sorted; any overlap between participants rejects `route_alias` |
| Timing kind | `scheduled`, `host_output`, `estimated_pull` or `opaque`; capability alone is not a synchronization grade |
| Qualification/calibration reference | Opaque reference ≤128 bytes or explicit null; resolved privately by consumer, never a self-asserted evidence object; route generation is an epoch, not a firmware/version label |
| Volume | Integer `volume_fraction_ppm` 0–1000000; normalized control coordinate, ceiling 0–1000000; zero means muted audio, not device power-off; no equal-loudness or dB meaning |
| Metadata | Optional title/artist/album ≤1024 bytes each, total ≤8192 bytes; display only, never playable source identity |
| Engine | At most four sessions/groups, sixteen active unique output routes and sixteen total unique audible descendant IDs; at most four sources, one per session |
| Buffers | ≤4 MiB decoded/encoded queued audio per source or participant, ≤128 MiB across the engine; all intermediate queued audio counts |
| Control | ≤64 KiB encoded message, depth ≤16, ≤128 members per object, ≤1024 array entries across message; ≤32 pending commands engine-wide |

`Limits` is a closed object with optional positive-integer fields and these
defaults/ceilings: `sessions: 4`, `participants: 16`, `audible_descendants: 16`,
`sources: 4`, `source_audio_bytes: 4194304`, `participant_audio_bytes: 4194304`,
`total_audio_bytes: 134217728`, `control_bytes: 65536`, `pending_controls: 32`,
`retained_originals: 1024`, `pending_events: 256`, `session_ms: 28800000` and
`lead_ms: 10000`. Omitted fields take those defaults; supplied limits may narrow
but never widen them in profile version 1. `retained_originals` must be at least
`pending_controls`; a control budget unable to encode the installed ready/limit
manifest rejects startup. Fixed format, structural depth and per-value minima
above cannot be relaxed by Limits.
Profile IDs are installed ASCII identifiers `[a-z0-9._-]{1,128}`; route and
availability generations are the 128-bit epochs above. Metadata contains only
optional title/artist/album strings. No field gains an implicit null/default
except the explicitly optional/reference fields above.
Source custody resolves actual bytes/stream handles and credentials; public
source values contain neither file paths nor URLs, process selectors or keys.
Mono is duplicated into stereo before gain; no channel-assigned surround is
inferred. `s16le` maps signed sample `n` to `n/32768`; `f32le` samples must be
finite in [-1,1]. A host conversion that clips must count/report clipped frames.

**MAU01-01 — Canonical identity.** Canonical JSON sorts object keys by UTF-8
bytes, preserves ordered arrays, uses minimal JSON escapes and no whitespace;
numbers are bounded integers, while 64-bit counters/times are the strings above.
The semantic digest is SHA-256 of UTF-8 `audio-engine.semantic@1\n`, the exact
`format` value, a newline, then canonical JSON of the value. The digest is a
derived output, not an input field. Display `metadata` is excluded from the
source semantic projection. Group
member order is sorted, not an execution-priority hint. A changed route,
membership, source revision or policy produces a different basis.
Canonical strings leave valid non-ASCII UTF-8 and `/` unescaped, escape quote
and backslash, use `\b`, `\f`, `\n`, `\r`, `\t` for those controls and lowercase
`\u00xx` for other permitted control characters; do not normalize Unicode.

**MAU01-02 — Source and authority separation.** Validated source references and
media metadata are inert. Only an explicit consumer host starts a session after
permission checks. A network source requires a separately installed receiver
profile; a Spotify Web API control response is not decoded music. The first
application-capture path captures the selected application's audio, rather than
requiring a streaming-service account integration in the engine.

## Commands, outcomes and transitions

**MAU01-03 — Public operations.** Planned value constructors are
`Limits.new/1`, `Source.new/2`, `Participant.new/2`, `Group.new/2` and
`Command.new/2` under `AudioEngine`. They return `{:ok, value}` or
`{:error, %AudioEngine.Error{code: atom, path: JSON_pointer}}`; only installed
atoms exist, and errors include no rejected value. Planned host operations are
`open`, `start`, `pause`, `resume`, `stop`, `join`, `leave`, `set_volume`,
`status` and `close`, through the MAU.04 port. Unsupported operations reject
before dispatch. No arbitrary command, module or packet field exists.

A command carries exactly `request_id`, `request_sequence`, `session_id`,
`session_epoch`, `expected_playback_epoch`, `expected_group_revision`,
`operation`, `deadline_us` and `payload`. Expected playback epoch is null before
the first start; otherwise it must match the current 128-bit playback epoch,
including for pause/resume and membership changes. Open supplies caller-issued
fresh session ID/epoch and null expected revision/epoch. A new playback epoch
never changes the session identity or authorizes a stale command.

Open payload contains exactly `group`, `source`, `participants`,
`authorization_ref`, `runtime_digest` and `source_descriptor` (MAU.04).
Participants are sorted by ID and match the complete group's member set.
Authorization reference is opaque, ≤128 bytes; runtime digest uses the digest
encoding above. Join payload is exactly `member`, `participant`, `group`;
leave is exactly `participant_id`, `group`; either group is the complete proposed
next revision. Set_volume is exactly `participant_id`, `volume_fraction_ppm`.
Resume is exactly `source_descriptor`, registering a fresh source epoch under
the same authorized source revision. Status is read-only. Start, pause, stop,
status and close payloads are empty. `open` has at most a ten-second deadline; other
commands have at most five seconds. Membership mutation validates the complete closure.

**MAU01-04 — Honest results.** Results carry request/session/epoch/basis,
disposition and sorted per-participant outcomes. Dispositions are `refused`,
`staged`, `admitted`, `handed_off`, `reported`, `partial`, `unknown` or `closed`.
Readiness and playback state are separate: `opening`, `ready`, `buffering`,
`playing`, `paused`, `draining`, `degraded`, `stopping`, `stopped`, `failed` or `closed`.
Local buffer acceptance, protocol acceptance, reported playback and measured
audible output are separate evidence fields. Absent evidence is explicit null.
An aggregate reports `partial` when admitted members differ in outcome and
`unknown` when a required handed-off control cannot be resolved. A sync grade
cannot make an unknown control result successful.

The result object contains exactly `request_id`, `request_sequence`, `session_id`,
`session_epoch`, `playback_epoch`, `group_revision`, `source_revision`, `disposition`, `state`,
`grade`, `grade_scope`, `pair_bound_us`, `participants` and `error`.
Grade uses MAU.02's four values; grade_scope is the sorted unique active
participant IDs covered by that group claim, ≤16. Pair_bound_us is a nonnegative
signed-64-bit microsecond bound or null when unestablished; an empty scope is
unavailable. Excluded/unavailable members stay in participant outcomes and
never disappear into a successful group result. Error is null or `{code, path}` from the closed
error set. Sorted participant outcomes contain exactly `participant_id`,
`route_generation`, `disposition`, `reported_playback`, `timing_kind`, `grade`,
`accepted_frames`, `protocol_ack`, `scheduled_anchor_us`, `remote_tail_until_us`,
`evidence_ref`, `audible_evidence_ref` and `error`.
Reported playback is `playing`, `paused`, `stopped` or null; times/evidence
are explicit null when unavailable. Evidence references are opaque, ≤128 bytes.
Accepted_frames is the cumulative accepted sample-frame count in this playback
epoch, canonical uint64 or null; protocol_ack is accepted/rejected/null for the
reported control. Evidence_ref identifies current qualification; audible_evidence_ref
identifies an actual session measurement, normally null without a measurement
campaign. Historical qualification never populates live audible evidence.
An unavailable aggregate basis uses null revisions, never fabricated zero.
Playback epoch is null before first start, then the current 128-bit identity;
pause retires old queues and issues a new paused epoch, resume issues a fresh
playing epoch. Result/event snapshots disclose each change. Affected route
rebuffering changes its route generation without resetting surviving timelines.

Open transitions only from an absent session to opening, then ready or failed.
Start is valid only from ready; pause from buffering/playing/degraded; resume
only from paused. Stop is valid from opening/ready/buffering/playing/paused/
draining/degraded and ends stopped; close is allowed from any owned state and
ends closed. Failed/stopped/closed sessions cannot start/resume; opening a new
session is explicit. Join/leave and volume require ready/playing/paused/degraded,
plus each selected adapter's supported operation. Status is read-only in every
retained state. Other transitions refuse stale_basis or unsupported_operation.
During a new start/resume, publish a buffering event with the fresh playback
epoch, wait for its current host guard, then hand off control and audio. This
wait is inside the original command deadline; it never admits an old guard.

| Event | Guard | Result |
| --- | --- | --- |
| Open | Closed values, current host authorization, free capacity | New volatile session, `opening`; no source frames/device play before start |
| Start | All required participants ready, minimum grade met, source available | Shared future anchor, `buffering`; per-output handoff/report evidence |
| Pause/resume | Same session/basis and supported profile | New playback epoch; stale queued audio retired; uncertain remote tail reported |
| Join/leave | Current revision, complete descendant permissions, capacity | Atomic revision change; join must meet retained lead, otherwise refusal |
| Member loss | Matching current generation | `degraded` and continuing survivors, or group stop under explicit policy |
| Source loss | Live EOF/fault, or needed queue empty beyond MAU.02 stall bound | Retire only that source session; no historical replay; normal file EOF drains |
| Close | Any owned session | Retire ingress and adapters; final per-output outcome, never fabricated silence |

**MAU01-05 — Repeat and concurrency.** Original scope is engine epoch plus
`request_sequence`; the consumer host assigns strictly increasing uint64 sequences
starting at one and never reuses a request ID for a new original. The engine
retains at most 1024 originals including the ≤32 pending controls, and one
accepted-sequence high watermark. A retained identical original returns its
current original outcome without another control; changed bytes return
`request_conflict`. Pending originals may advance through staged/admitted/handoff
outcomes to one terminal result; a retry never duplicates that pending work.
Once terminal, the result is immutable.
An unseen sequence at or below the watermark returns `original_retired`, even
after its result was evicted; it never becomes new work. Pending originals are
never evicted. Terminal entries may be evicted oldest-first; bounded refusals
also retire their original sequence. The consumer owns durable originals across
restart; the engine never
restores or automatically starts an old session. One route/descendant cannot be
owned by two live sessions. An external takeover invalidates route ownership.

Errors include `invalid_input`, `unsupported_profile`, `route_alias`,
`stale_basis`, `stale_epoch`, `unauthorized`, `source_unavailable`,
`minimum_grade_unavailable`, `capacity`, `deadline`, `request_conflict`,
`original_retired`, `adapter_lost`, `unknown_handoff`, `lead_insufficient`,
`clock_lost`, `source_discontinuity`, `buffer_credit`, `expired_frame`,
`resample_limit`, `unsupported_operation`, `pairing_required`,
`identity_mismatch`, `native_group_changed`, `source_taken_over`,
`protocol_error` and `remote_tail_unknown`. Transport text and
credentials never enter errors, telemetry or inspected public values.
JSON_pointer paths use only installed field names and numeric array indexes;
an unknown field reports its nearest known parent, never the supplied key/value.

## Entry and acceptance

Before implementation delivery, select the owned component/source project and
facade; create closed offline schemas for all values,
commands/results and independent canonicalization vectors in the selected component's
`priv/schemas/` and `priv/vectors/`; implement the listed constructors and host
port without reading documentation at runtime. Archive consumers must exercise
the public facade and Rust host independently of any consumer product.

| Case | Requirements | Stimulus and falsifier | Evidence |
| --- | --- | --- | --- |
| MAU01-T1 | 01–02 | Independently encode boundary values, reordered objects and mono PCM; digests/conversions match; duplicates, nonfinite and unknown members reject | Pure independent oracle |
| MAU01-T2 | 02–03 | Load package/create values with no host; no process, network, account access or capture appears | Independent archive |
| MAU01-T3 | 03–05 | Duplicate/change original, race membership revision and alias two descendants; no second control or wider group | Controlled host |
| MAU01-T4 | 04 | Mixed local acceptance, report, failure and uncertain member; aggregate retains every distinction | Independent traces |
| MAU01-T5 | 03–05 | Exhaust slots/originals/audio buffers at and above each bound, then close/restart; bounded refusal, no replay or retained resource | Native fault/allocator checks |

All cases are obligations, not evidence. The
[completion plan](../../plans/audio-engine-delivery.md) owns delivery order.
