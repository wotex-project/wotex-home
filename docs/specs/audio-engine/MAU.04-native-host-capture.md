# MAU.04 — Native engine host, macOS capture and bounded IPC

Version: 0.2.0. Updated: 2026-10-13. Status: accepted target.
Implementation: planned. Evidence: missing.

Allocation: consumer/independent playback component, not a WoTEx package.
WoTEx WST.01–02 supply optional protocol-stream joins; generic protocol timing
and packetization do not own DSP, capture/render or acoustic qualification.
Device/cohort definitions are externally supplied, never a WoTEx model catalogue.

## Purpose and ownership

A consumer explicitly supervises a portable Rust engine and chooses native
platform adapters. A thin macOS layer owns system/application audio capture,
OS permissions, device handles and host timing. The engine can also accept a
consumer-owned file decoder or selected network-input profile. No mandatory
desktop framework, streaming-service account, automation kernel or background
service is introduced by loading the library.

[MAU.01](MAU.01-media-session-values.md) owns closed values, origins, four
sessions/sources, sixteen routes and 128 MiB queued audio. [MAU.02](MAU.02-timeline-synchronization.md)
owns epochs, future scheduling, clock feedback, grades and source stalls.
[MAU.03](MAU.03-output-adapters.md) owns exact protocol profiles, bounded
sessions and cleanup. Consumer writers/credentials remain outside the Rust
engine; continuous PCM never goes through a consumer database or public JSON API.

## Explicit startup and capabilities

**MAU04-01 — Host instance.** The consumer selects exact native artifact/source,
digest, platform/architecture, protocol/profile versions and runtime budgets.
Verify bytes before execution and start through a consumer-owned supervisor.
No adjacent-checkout discovery, downloaded executable, ambient module discovery
or runtime fallback can select another build. Native helper dependencies are
separately inventoried with compatible notices and platform/runtime obligations.
The Mix facade's planned `Host.start_link/1` requires explicit configuration;
no package application callback starts it automatically.

Startup supplies a fresh 128-bit engine epoch, private inherited IPC descriptors,
one selected monotonic clock epoch/provider and narrowed MAU.01 limits. The process
receives no consumer bearer, Store handle, household schema or generic shell
capability. Credentials needed by a particular adapter are resolved through a
private host capability bound to that profile, participant/session and lifetime.
No secret appears in argv, environment, public records or stderr diagnostics.

The first local host profile uses one system-wide native clock coordinate in
both processes: `darwin.uptime_raw_us@1` is
`floor(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000)`; `linux.monotonic_us@1`
is checked `seconds*1000000 + floor(nanoseconds/1000)` from
`clock_gettime(CLOCK_MONOTONIC)`. Select only the profile installed on that OS;
never equate Rust Instant, BEAM monotonic time or wall time with this coordinate.
The native facade's planned `Host.now_us/1` returns the bound epoch/time for
deadlines and guard expiry. Ready reports the exact provider and current sample;
the consumer checks it lies between its same-provider prelaunch/post-ready
samples. Provider failure/regression or sleep/wake retires the epoch. Hardware
or remote clocks still require the MAU.02 mapping; a common local coordinate
does not establish physical output timing. Package the required platform API
declarations/notices with the native artifact before installed delivery.

**MAU04-02 — Continuous authorization.** The consumer host validates current
permission/basis before opening, start/control handoff and membership changes.
Its opaque authorization capability binds source, complete descendants,
operation set, volume ceilings and session/route epochs. The native host must
receive refreshed authorization state at least every 250 ms; validity is at
most 1000 ms without a refresh. A missed refresh, host/control-channel loss or
revocation stops new source ingestion/output within the next 250 ms check.
Graceful cleanup is preauthorized for the already-owned session, not fresh play.
Remote stop/pause is allowed only while the same route/source ownership is
confirmed. External takeover closes this session's local stream/connection;
cleanup must not stop another controller's music.
Possible previously buffered remote audio remains bounded/unknown as MAU.03
reports; withdrawal does not promise instantaneous physical silence.

Refresh is an in-memory host guard over consumer-published current state, not
permission to reopen a writer or persist every PCM block. The consumer must
invalidate this state on grant, ownership, source/profile or membership changes;
if it cannot establish current state it stops refreshing. A new engine epoch
cannot reuse a previous capability. No auto-resume follows a process restart.

## Capture and native output

**MAU04-03 — macOS source.** The first native capture profile uses Core Audio
process taps on macOS 14.2 or later, with the documented audio-capture usage
description and actual OS permission. The host owns the exact selected process
incarnation or an explicitly selected system mix. Executable name/PID reuse is
not identity. Permission denial/revocation, source exit or incarnation change
returns source_unavailable and retires its epoch; no switch to system mix,
microphone, another application or virtual driver occurs automatically.

Capture only decoded audio; local file/capture/profile metadata grants no access
to account tokens or protected content interfaces. The selected OS output may
remain muted while the engine supplies a delayed local participant; otherwise
the UI must disclose that undelayed local playback is outside the group. Exclude
engine/helper playback from a system-mix tap to prevent feedback. If exclusion
cannot be established, refuse that capture profile. Explicit microphone and
test-tone permission is required only for calibration, never ordinary playback.

An installed capture profile declares actual input layout/rate, conversion to
MAU.01 mono/stereo PCM, timestamp method and any clipping/downmix. No silent
channel omission or inferred surround exists. Capture callbacks feed a bounded
nonblocking ring; they perform no network/JSON/Store work. Overflow records
source discontinuity and stops or re-anchors explicitly, never conceals lost
audio or grows storage.

**MAU04-04 — Native output.** Bind a specific OS device and actual hardware
sample/host clock, internal latency and route epoch. On macOS this is a Core
Audio backend; Rust bindings or a thin native wrapper are implementation choices.
Estimate the additional wireless/acoustic tail separately, under MAU.02.
OS default output changes cannot redirect an enrolled participant. Sleep/wake,
device/format changes and callback clock discontinuities retire affected
epochs. A sleeping capture Mac cannot be presented as an available source;
other independently supplied sources/bridges may continue under their own hosts.

## IPC and lifetime

**MAU04-05 — Control protocol.** Use private inherited socket/pipe descriptors
or a consumer-owned private local socket with same-user peer validation. The
first profile exposes no network control listener. Each frame is a four-byte
unsigned big-endian length followed by one UTF-8 JSON object, 1–65536 bytes.
No compression, implicit newline framing or partial-object execution occurs.
The envelope contains exactly `v: 1`, `kind`, `engine_epoch`, `sequence` and
`payload`; kinds are `ready`, `request`, `result`, `event`, `guard`, `credit`,
`source_end`, `close`.
Sequences are canonical uint64 decimal strings, strictly increasing per direction;
control retransmission uses a new envelope sequence and the original command.
Old epoch, malformed length/UTF-8, duplicate/unknown fields, stale sequence or
truncated/oversized body closes the connection and retires owned sessions.

Directions are host-to-engine for request/guard/source_end/close and engine-to-host
for ready/result/event/credit. Sequences start at zero independently per direction. The
host supplies the engine epoch through private startup configuration; ready is
the first engine frame. Wrong direction or request before ready closes the epoch.

| Payload | Closed members |
| --- | --- |
| ready | `artifact_digest`, `profiles` (sorted unique `{profile_id, profile_digest}`), `limits` (resolved MAU.01 Limits), `clock_epoch`, `clock_profile` (one installed ID above), `clock_sample_us`, `operations` (sorted unique installed MAU.01 operation strings) |
| request/result | Exact MAU.01 command/result; envelope epoch must match the bound host instance |
| guard | `authorization_ref` (opaque ≤128 bytes), `session_id`, `session_epoch`, `playback_epoch` (or null before first start), `revision` (canonical uint64), `expires_us` (agreed engine monotonic time), `valid` (Boolean) |
| event | `session_id`, `session_epoch`, `playback_epoch` (or null), `participant_id` (or null), `route_generation` (or null), `kind`, `snapshot`, `metrics`, `error` |
| credit | `source_id`, `source_epoch`, `through_bytes` (canonical uint64 cumulative allowed wire bytes) |
| source_end | `source_id`, `source_epoch`, `next_sequence`, `final_cursor` (canonical uint64; position immediately after the last supplied frame) |
| close | Empty object |

Event kind is state/timing/pressure/retired/source_end. Snapshot is a MAU.01
result-shaped current status with null request_id/request_sequence, or null for
metrics-only timing/pressure events. Metrics contains exactly queue_bytes,
underrun_frames, clipped_frames, discarded_frames, correction_ppm, clock_error_us
and timing_sample_age_ms. Queue_bytes is an integer 0–134217728; frame counters
are canonical uint64 decimal strings; correction_ppm is integer -500..500 or
null, clock_error_us is signed-64-bit microseconds or null, timing_sample_age_ms
is a nonnegative integer ≤28800000 or null. Error is the MAU.01
null-or-closed error. No vendor exception or unbounded detail member exists.

Before request admission compare ready with configured identities. Guard
references resolve only through private host custody; stale revision/epoch or
expiry cannot renew permission. Exact schemas and independent byte vectors must
implement these direction/field rules before delivery.
After a playback-epoch change, publish the new epoch and admit no new ingress
or output until a guard bound to it arrives. No old guard implicitly authorizes
a resumed/rebuffered generation; remote retired tails remain separate.

**MAU04-06 — Audio ingress.** Open payload additionally registers one source
descriptor with exactly `source_slot`, `source_id`, `source_epoch`, `clock_epoch`,
`capture_kind`, `initial_cursor` and `format_profile`. IDs/epochs/formats use
MAU.01 encodings; capture_kind is host_hardware, peer_reported or synthetic.
A non-live file uses synthetic capture time zero; it is scheduled by source
cursor, never by that zero. Other sources supply the reported first-sample time
in their registered clock domain. The descriptor is private host data and must
match the resolved source and granted session. Source_slot is integer 0–3,
selecting one of four private source channels inherited at startup; one active
source owns a slot. Narrowed source limits narrow available slots. Resume also
registers a fresh source epoch and starts its sequence/credit counters at zero.
A slot can be rebound only after the prior sender is quiesced and all its queued
framing is drained/discarded within the source byte budget and 1000 ms cleanup
bound. Otherwise retire the slot and refuse reuse; never concatenate a partial
old frame with a new source epoch.

Use a separate private source descriptor to keep
large audio away from control/guard messages. A four-byte big-endian length
prefix includes the following 72-byte header plus payload, maximum 65536 bytes.
All header integers are big-endian; PCM payload is little-endian.

| Byte offset | Width | Field |
| --- | --- | --- |
| 0 | 4 | ASCII `MAU1` |
| 4 | 16 | Source ID, decoded from its lowercase-hex public identity |
| 20 | 16 | Source epoch |
| 36 | 8 | Unsigned consecutive source-frame sequence |
| 44 | 8 | Unsigned first source sample-frame cursor |
| 52 | 8 | Signed first-sample capture time, monotonic microseconds in the registered source clock epoch |
| 60 | 4 | Unsigned frame count ≥1; frame_count*1000 ≤ sample_rate*100 (at most 100 ms), including a final short file fragment |
| 64 | 4 | Sample rate, 44100 or 48000 |
| 68 | 1 | Channels, 1 or 2 |
| 69 | 1 | Sample format, 1=s16le, 2=f32le |
| 70 | 2 | Reserved, both zero |

Payload length must equal frame_count*channels*sample_width, with checked
arithmetic and no trailing bytes. Source format/ID/epoch must match its opened
descriptor. Sequences start at zero, cursors at the registered initial cursor
and advance by frame count. Duplicate identical frames are discarded within a
retained 32-frame fingerprint window; conflicting, skipped or retired frames
signal discontinuity. Frames before a granted start or after withdrawal reject.
The source receives queue credit before writing. Through_bytes starts at zero
and increases monotonically per source epoch; total written bytes, including
each four-byte prefix and header, cannot exceed it. Outstanding credit reserves
the source queue budget and counts against global queued/reserved memory;
replenish only after buffers are released, never merely after reading a pipe.
An over-credit sender retires that source with buffer_credit. Retired credits
cannot authorize another epoch; checked counter exhaustion retires the source.
No credit blocks only its
non-real-time sender, never a native audio callback. File/network decoders must
obey the same lifecycle; synthetic capture time is explicitly marked by the
registered source profile, never relabeled as hardware capture.

Normal logical EOF is the source_end control frame, leaving its private channel
reusable for a later explicit source epoch. Cross-channel arrival can precede
the final audio frame: wait at most the two-second source stall bound for the
declared sequence/cursor, rejecting any extra frame. An empty source declares
sequence zero and initial cursor. Non-live EOF then drains the accepted timeline;
live EOF retires that session. Actual source-channel EOF/malformed bytes retire
the current source and slot for this engine instance, never another slot.

**MAU04-07 — Termination and diagnostics.** Startup/readiness has a 10-second
deadline. Control EOF, malformed control IPC, owner death and unexpected engine
exit retire all owned ingress and adapters. Audio-descriptor EOF/failure affects
only its source session, with normal non-live EOF draining as MAU.02 specifies.
Malformed audio retires that descriptor/session; it cannot poison another group.
Close local resources within 1000 ms; if a helper
does not exit, terminate its owned process group, never an unrelated process.
Report potentially audible remote tails rather than restarting/replaying.
At most 32 outstanding controls and 256 pending events exist; pressure coalesces
superseded metrics, while lost state/guard events close the generation. Public
metrics include queue depth, underruns, clipping, correction ppm, clock error,
timing kind and current grade. They exclude PCM, source paths/URLs, process
arguments, device identities, pairing material and external exception strings.

## Entry and acceptance

Freeze the Rust facade/host ABI, control payload schemas and source byte vectors
before host integration. Select an audited exact fork/release cohort and record
gaps relative to the pinned Sendspin spec. Upstream contributions are generic
server/client/clock/adapter improvements; consumer policy and custody stay out.
A Linux bridge is not macOS evidence. Source/build/license inventory, actual
signed installed permission and audio-route behavior are separate release gates.

| Case | Requirements | Stimulus and falsifier | Evidence |
| --- | --- | --- | --- |
| MAU04-T1 | 01–02 | Wrong artifact/ready identity, stale authorization, missed refresh and host loss; no new ingestion/output beyond guard bounds, no automatic replacement/restart | Real process/IPC |
| MAU04-T2 | 03–04 | Installed macOS permission denial/revocation, selected process exit/PID reuse, system-mix feedback and sleep/wake; no broader capture/output | Actual installed macOS |
| MAU04-T3 | 05–06 | Independent binary/JSON encoder: exact 72-byte header, overflow, truncation, duplicate sequence and fragmentation; bounded refusal with no partial frame execution | Native/independent bytes |
| MAU04-T4 | 02, 06–07 | Full queues, slow reader, blocked guard delivery and child death while streaming; bounded retirement, no callback allocation/blocking or source replay | Native fault/resource |
| MAU04-T5 | 01–07 | Two independent consumers use a real archive/native artifact with public ports; no consumer namespace/database/ambient configuration is required | Independent archive/installed |

Sources: [Apple process-tap sample](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps),
[Apple native clock](https://developer.apple.com/documentation/kernel/1462446-mach_absolute_time),
[POSIX clock coordinate](https://pubs.opengroup.org/onlinepubs/000095399/functions/clock_getres.html),
[native timing reference](https://github.com/chrisuthe/sendspin-player/tree/54fb3648dd60090e9fdb293b8905505d7604dc3c),
[Sendspin server guidance](https://www.sendspin-audio.com/build/guide/server/).
These are inspected implementation references, not evidence that this host exists.
