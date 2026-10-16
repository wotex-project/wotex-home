# Music output alignment and lifecycle qualification

Version: 0.1.1. Updated: 2026-10-13. Procedure status: planned.
Executed evidence: none. Owner: WOH.21 H21-T2–T9 and WOH.11.

## Purpose and entry

Qualify a specific music-output cohort and measured clocked/calibrated grade.
Protocol ACKs, queued PCM and engine timing estimates do not establish acoustic
alignment. The initial target is the same mono/stereo music across rooms,
including a confirmed WONDERBOOM 2 Bluetooth route; surround is unnecessary.

Before running, have the implemented WOH.21 private lab harness, selected native
engine/profile artifacts, finite explicit test authorization and volume ceilings,
private enrolled identity/custody, installed capture/output permissions and
independent recorder/analysis tools. This document supplies no executable command
for an unimplemented harness and enables no production dispatch. Host commands
must be delivered in the owning native guide with the harness.

Keep QR payloads, MACs, device/OS IDs, source paths, accounts and pairing material
in existing private custody/fixture locations. Public evidence uses opaque unit,
route, source and artifact references. No credentials/identities in command
arguments or tracked audio/logs. Calibration captures only the explicit test
signal/session; ordinary music requires no microphone.

## Record the exact cohort

Record repository/native source and toolchain, build/profile/schema digests,
source format/capture mode, clock/route generations, host/backend and firmware,
actual physical units/assemblies, native group descendants, codec/rate/sound
processing, current calibration and selected group policy/lead. A device unable
to report firmware is recorded as unreported and qualified only as that enrolled
unit, never as a model-wide wildcard. The Frame and bedroom Google speaker must
be identified before their device-specific acceptance.

Use signed installed macOS capture where claimed. Verify source process identity,
OS permission and exact output selection before test tones. Start with local
files and controlled non-personal signals; test Spotify/application capture
separately, with explicit consent. A content-service failure is not necessarily
speaker transport failure.

## Independent measurement

Use one independent multichannel recorder clock for compared outputs. Calibrate
channel/microphone delay with a common reference; position microphones at equal
recorded distances from their respective outputs or subtract measured propagation
differences. Separate direct arrival from reflections. Retain the signal template
and analysis version/digest. Engine-generated skew numbers are diagnostic only.

Emit a finite known probe sequence with at least 1000 uniquely indexed probes
spread over 60 minutes. Independently correlate each recorded channel against
the source template, pairing the same probe index across outputs. Record each
pair's absolute time difference, missing/ambiguous detections, dropout durations,
epoch changes and calibration uncertainty. Reject ambiguous/clipped/noisy
measurement windows; they cannot disappear from a claimed successful campaign.
If all outputs cannot be captured together, use reproducible pair campaigns
under the same recorded setup and basis; do not infer an untested pair from
unrelated room recordings.

Pass the selected alignment requirement only when every compared probe has
absolute inter-output skew ≤20 ms, with no unexplained epoch jump or dropout
longer than 250 ms. Missing/ambiguous measurements require rerun with a corrected
measurement setup, not promotion. Report actual maximum and sample coverage.
The result applies to that cohort/environment, not every listening position.

## Required campaigns

1. **Steady playback:** local file/native output first, then mixed HomePod and
   WONDERBOOM 2, then each independently assessed Google/Sonos/TV route. Measure
   warm-up, all probe pairs and drift for the complete hour.
2. **Capture isolation:** deny/revoke OS consent, exit/relaunch the selected app,
   reuse its old PID, change default output, and exercise system-mix exclusion.
   There must be no broader capture, unintended reroute or feedback stream.
3. **Join/leave and pressure:** add/remove a route while survivors play, fill
   bounded queues and stall one route. Observe explicit refusal for insufficient
   retained lead, correct policy, unchanged survivor timeline and resource cleanup.
4. **WONDERBOOM 2:** power off/on, lose Bluetooth range, reconnect after another
   source used it, and pause long enough to observe documented 15-minute standby.
   Record actual behavior. No remote wake or persistent availability is inferred.
   Double Up is not enabled unless its full assembly was separately enrolled.
5. **Basis changes:** change codec/output processing, route generation and
   current calibration; verify grade withdrawal. The reconnect-validation
   procedure must measure at least ten probes against the same reference within
   60 seconds and meet the ≤20-ms bound before reusing a previously qualified
   stable-cohort offset. A failed validation leaves best_effort/unavailable.
6. **Ownership and recovery:** native-controller takeover/group change, grant
   revocation, host sleep/exit, engine failure, lost command response and restart.
   Check no stale send/new stream, original recovery and explicit unknown remote
   tail. Restart/restore/reconnect must not autoplay.
7. **Availability:** block WAN for enrolled local file playback. Independently
   make remote radio/Spotify content unavailable; distinguish content failure
   from local routes. Disable routines, AI, voice and Matter during ordinary music.

Controls keep their original finite deadlines. A software fixture establishes
only its own layer. Actual Bluetooth/OS/firmware permission behavior and acoustic
outcome require the real campaign. A device/profile that fails alignment may be
assessed as best_effort or unsupported with its limitation retained.

## Evidence and review

Retain actual commands, artifact/profile digests, private capture references,
calibration revisions, measurement channel/distance corrections, full per-probe
results, faults/exclusions and outcome. Reconcile them against
[WOH.21](../specs/WOH.21-apartment-music.md) and the selected MAU playback component and exact WST protocol cohort
cohort before any production grade/dispatch enablement. Human/operator review
establishes the exact supported cohort; passing a lab does not authorize new
sources, targets or wider grants. Changed inputs retire dependent qualification;
old campaigns remain historical evidence.
