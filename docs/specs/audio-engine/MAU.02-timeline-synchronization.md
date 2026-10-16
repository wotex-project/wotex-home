# MAU.02 — Audio timeline, alignment and qualification grades

Version: 0.2.0. Updated: 2026-10-13. Status: accepted target.
Implementation: planned. Evidence: missing.

Allocation: consumer/independent playback component, not a WoTEx package.
WoTEx WST.01–02 supply optional protocol-stream joins; generic protocol timing
and packetization do not own DSP, capture/render or acoustic qualification.
Device/cohort definitions are externally supplied, never a WoTEx model catalogue.

## Scope and inherited boundary

This contract schedules one continuous music timeline onto heterogeneous
outputs. It owns anchor calculation, buffer accounting, clock mapping, drift
correction and honest synchronization claims. The consumer owns authority and
measurement evidence; adapters own their actual transport clocks and queues.
It is not a video/surround or simultaneous-command-start contract.

[MAU.01](MAU.01-media-session-values.md) supplies immutable source/group/route
identities, one source per session, 1–16 participants, four sessions, bounded
PCM and 128 MiB total queued audio. Unknown fields, stale epochs, aliased
descendants and unavailable required profiles reject before allocation.
[MAU.03](MAU.03-output-adapters.md) supplies current timing reports and finite
cleanup; [MAU.04](MAU.04-native-host-capture.md) supplies native clocks/capture
and an explicit consumer authorization lifetime. No clock or calibration is
trusted merely because a peer reported it.

## Inputs and exact coordinates

**MAU02-01 — Timeline.** Each playback epoch binds session/source epoch,
sample format, source start cursor `C0` and monotonic coordinator anchor `T0`.
For source frame cursor `C`, its intended output time is the rational value
`T0 + (C-C0)*1000000/sample_rate` microseconds. Convert a hardware scheduling
deadline by rounding up, so a frame is not intentionally scheduled early.
Track changes in a library stream preserve the cursor; source replacement,
seek, resume after pause and discontinuity create a new epoch/anchor. Cursors
never substitute for device-reported or physically measured playback position.

| Input | Type/bound/default |
| --- | --- |
| Coordinator clock | Explicit host-owned signed-64-bit monotonic microseconds and epoch; regression or epoch change retires affected sessions |
| Clock sample | Domain/epoch, four exchange timestamps or hardware timestamp plus sample cursor, sequence and nonnegative uncertainty_us ≤1000000 |
| Participant timing | Current route generation, clock mapping, required lead 0–10000 ms, internal output delay 0–10000 ms, calibration tail 0–5000 ms |
| Calibration | Consumer-resolved immutable digest, exact route/codec/build/source-clock identities, measured delay/error interval and acquisition time; no caller-authored evidence |
| Source frame | Epoch, consecutive sequence/cursor, sample format, first-sample capture time; 1 sample-frame–100 ms, default 20 ms; final short file fragments are legal; ≤64 KiB frame |
| Lead | Group's explicit 250–10000 ms, default 2000; fixed for a playback epoch; no silent increase |
| Clock freshness | Required timing sample age ≤2 seconds and mapped uncertainty ≤5000 us for a clocked grade; unavailable mappings do not acquire `clocked` grade |
| Host feedback | Output cursor/latency feedback at least every 250 ms during streaming; queues and packet acceptance alone are insufficient |
| Source stall | 2000 ms while playback needs another frame and no playable source audio is queued; intentional pause/EOF and credit-blocked prefill do not start this timer |
| Session lifetime | At most eight hours from start, no implicit renewal; consumer must create a new authorized session |
| Correction | Bounded continuous rate adjustment ≤±500 ppm; adjustment change ≤50 ppm per second; excess or >20 ms uncorrectable error triggers rebuffer/grade withdrawal |

Timing uncertainty includes the mapping estimate, measurement resolution and
known output pipeline error. Network round-trip time alone is not output delay.
Counter overflow, negative exchange duration, malformed sequence and impossible
buffer depth reject. Keep at most 128 accepted samples per mapping and one
current mapping per participant; reject a late sample from a retired epoch.

**MAU02-02 — Clock mapping.** Use a continuously updated offset-and-drift
estimator, with four-timestamp samples captured at actual send/receive boundaries.
Compare it against the pinned Sendspin time-filter reference and independent
simulated affine clocks. Filtering may not hide a clock discontinuity. A native
output maps hardware sample time to coordinator monotonic time; scheduling from
wall-clock sleep alone cannot claim hardware alignment. An AirPlay helper that
requires Unix time gets an explicitly sampled monotonic-to-wall projection;
wall-clock correction invalidates that projection and requires re-anchoring.

## Playback and failure transitions

**MAU02-03 — Start and buffer.** Resolve all required participants before start.
Each must have enough lead for its advertised buffer, transport startup and
output/calibration tail. If the selected lead cannot accommodate a required
participant, return `lead_insufficient`; do not delay an already playing group
or silently omit that participant. Optional failures are reported as exclusions.
Optional members below the requested minimum are also excluded. Start/join
requires the composed active group's grade to meet the minimum, not merely
each individual participant's grade.
Choose `T0` in the future, fill bounded queues and schedule each output against
the same source cursor/time. Account for rate conversion and encoder/decoder
delay. Sending play commands together is not synchronization.

Control deadlines bound accepted handoff/response, not waiting for a future
audible anchor. A scheduled start may return its confirmed anchor before playback;
later current reports cannot be fabricated from that acceptance.

The first profile uses PCM/FLAC for native Sendspin outputs; other adapters
negotiate only their qualified formats. Resampling is per output when required,
with phase/delay represented in its timing basis. Real-time callbacks do not
allocate, lock, parse JSON, perform network I/O or encode. Failed buffer credit
refuses ingress before mutation; a slow output cannot block another callback.

**MAU02-04 — Join and leave.** A join supplies a complete next group revision
and a participant ready for the retained lead. Select a future source cursor
and send only future audio; no past music is replayed. If history needed for
codec initialization is absent, wait for a bounded decodable boundary within
the original join deadline or refuse. Existing members continue on their
anchor. A leave withdraws new audio and closes that route, retaining its remote
buffered-tail outcome. A larger lead requires a separate explicit restart with
a new playback epoch; no hidden group-wide pause is introduced by a join.

**MAU02-05 — Discontinuity and drift.** Pause stops source ingress/capture and
retains the intended timeline cursor, not an assertion of physical pause position.
Live resume starts from newly captured current audio; a local-file resume is an
explicit request to decode from the retained intended cursor under a fresh source
epoch. Never reuse old transport buffers. An unresolved remote pause/stop must
be reconciled before resume can claim exclusive route ownership.

Normal non-live source EOF drains the queued timeline through its last frame,
then closes routes; drain is bounded by the retained lead/queue and remote tail.
Live EOF retires only that source session. Another group does not stop merely
because one source ended.

Pause, seek, source gap, lost clock or
underrun clears affected local queues and advances epoch before any continuation.
Never replay already heard frames to catch up. A participant that falls behind
may drop only complete expired frames and rejoin at a future cursor. Apply smooth
rate correction only while its clock/feedback basis remains current; a large
correction is a bounded rebuffer, not prolonged audible speed/pitch distortion.
Record discarded, clipped and underrun frames separately. A network retry of
the same transport packet in the same epoch is not a new media-start operation.

| Event | Required behavior |
| --- | --- |
| Required member cannot start | Start refuses; local queues retire; handed-off output uncertainty is retained |
| Optional member cannot start | Exclude it with reason; survivors may start with actual membership shown |
| Member loss/timing regression | Withdraw its grade and new audio within 250 ms of host detection; continue survivors or stop according to group policy |
| Source/authorization loss | Withdraw ingress; stop/close adapters; retain possible remote tail up to advertised bound or unknown |
| Underrun | Silence only for at most 250 ms while rebuffering; thereafter detach participant or stop under policy |
| Engine or host restart | All old epochs invalid; no auto-play, buffer replay or source reopening |

Silence inserted during a brief underrun advances the timeline and is counted;
it is never labeled source audio or measured playback success. After detach,
rejoin requires a new explicit command and current basis.

## Grades and calibration

**MAU02-06 — Grades.** Readiness and grade are independent fields. A route's
transport timing kind is a capability description; its grade is one of:

| Grade | Required meaning |
| --- | --- |
| `clocked` | Current scheduled/hardware clock feedback plus exact-cohort physical qualification of the complete output path |
| `calibrated` | Qualified cohort with a current measured fixed tail offset, but no complete clock feedback for the final leg |
| `best_effort` | Playback available; no currently established whole-path alignment bound |
| `unavailable` | Source/route absent, unsupported, refused or unable to play |

Order is clocked ≥ calibrated ≥ best_effort; unavailable never satisfies a
minimum. A group reports the minimum grade of all active admitted members,
including optional members, and its exact grade_scope. Lost/excluded members
remain separate outcomes; partial/degraded is retained even if survivors earn
a grade. No active members means unavailable. A bounded
group claim additionally requires evidence for this combination or composable
per-route error intervals relative to one qualified timing reference. With
current residual intervals [lo_i, hi_i], including clock/calibration uncertainty,
the conservative pair bound is max(hi_i)-min(lo_i); it must be ≤20000 us.
Incompatible reference/cohort assumptions or missing bounds make the group
best_effort even when individual routes have stronger grades. An excluded
speaker never counts as playing. Meeting a numerical clock-estimator target
without acoustic evidence cannot promote a physical route.
Combination evidence resolves through the group's explicit qualification_ref;
composable route bounds resolve through participant qualification references.
If streaming loses the requested minimum, withdraw the affected route within
250 ms and follow member-loss policy; if the cause cannot be isolated, stop the
group. Do not continue with a silently lowered minimum.

The selected music qualification target is at most 20 ms absolute inter-output
skew for every one of at least 1000 probes during 60 minutes of continuous
playback, with no unexplained epoch jump or audio dropout longer than 250 ms.
This is a product engineering requirement, not a protocol guarantee. Measure
under one independent recorder clock, account for microphone/channel offsets
and equalize or record acoustic distances. It establishes alignment in the
tested cohort/environment, not simultaneous sound arrival at every room position.

**MAU02-07 — Calibration custody.** Calibration changes are explicit new
immutable revisions; store the measured interval, method, uncertainty, selected
codec/output settings and qualification basis. Neither discovery nor engine
uptime supplies calibration. Changed device/firmware, output assembly, codec,
host backend, timing algorithm, sound processing or route generation invalidates
it. On reconnect retain old settings as a proposal only; regain calibrated
grade through a qualified stable-cohort reconnect-validation procedure: at least
ten independent probes within 60 seconds against the same reference, every skew
≤20 ms, no changed codec/processing/physical-unit assumption. Otherwise remain
best_effort or unavailable under the requested minimum. Acoustic calibration
requires explicit host microphone/test-tone permission; ordinary playback
requires neither a microphone nor background acoustic monitoring.

**MAU02-08 — Honest degradation.** A failed/expired grade immediately changes
the visible state. If below the group's minimum, stop feeding that participant;
under `on_member_loss: continue` detach it and retain survivors, under `stop`
retire the group. Do not silently lower the policy, widen rate correction,
increase latency or claim a silent/uncertain output aligned. A user may explicitly
create a best-effort revision for distant rooms with disclosed limitations.

## Entry, compatibility and acceptance

Before engine delivery, freeze clock/timing/frame/grade schemas and independent
vectors, including all rounding, rate-conversion and error-budget terms. Pin
Sendspin protocol/time-filter revisions and identify incompatibilities in Rust
upstream code before choosing a fork. No dependency is selected by this spec.
Existing protocol libraries and pure routines remain independent.

| Case | Requirements | Stimulus and falsifier | Evidence |
| --- | --- | --- | --- |
| MAU02-T1 | 01–02 | Independent rational clock oracle: ±50/500 ppm, delayed/asymmetric exchanges, overflow, rounding and clock steps; bounded aligned cursors, no old-epoch scheduling | Pure/reference |
| MAU02-T2 | 03–05 | Mixed formats, codec delay, one slow output, full queues and source stall; bounded memory, stable survivors, no historical replay | Native scripted outputs |
| MAU02-T3 | 04–05 | Join/leave, pause/resume, duplicate command, device loss and insufficient lead during playback; no hidden restart or old audio | Independent timed traces |
| MAU02-T4 | 06–08 | Forged/missing/stale qualification and route changes; no grade promotion or automatic policy downgrade | Consumer-independent host |
| MAU02-T5 | 02, 05–08 | Exact real mixed cohort, 1000 probes/60 min, reconnect and changed-codec campaigns; worst pair skew ≤20 ms under claimed scope, otherwise grade refused | Independent acoustic/installed |

Sources inspected for design: [Sendspin protocol](https://github.com/Sendspin/spec/tree/ee8aad9660fc57345e726a888486f47f66a41f97),
[time filter](https://github.com/Sendspin/time-filter/tree/39dd3f4a7c37bcd63d8e2ee3885bf4d76fcaa61a),
[Rubato asynchronous resampling](https://docs.rs/rubato/latest/rubato/).
Their claims/targets are not new executed evidence for this engine.
