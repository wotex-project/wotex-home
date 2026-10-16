# Local device behaviour successors v1

Version: 0.1.2. Updated: 2026-10-13. Status: accepted target.
Owner: WOH.01 semantics and WOH.03 mappings, H03-T8; WOH.20 integration.
Implementation: planned. Evidence: missing.

## Scope and authority

These mappings select installed generic WoTEx behaviours through WOH.18 review,
selection and qualification. Authority owns requests; the single Store owns
intent/claim/handoff/settlement. Current authors/grants, declarations, revisions,
fresh facts, invariants and exact qualification are repeated at admission and
handoff. No discovered name, role or native queue result grants control.

Current Light/SmokeDetector and portable-profile v1 stay unchanged. New semantic,
binding/schema and admission profiles must precede use. Unknown model/firmware
remains unknown; physical qualification is additional to software evidence and
dispatch remains disabled by default.

## Required mappings

**LDB-01 — Covers.** Normalize position to integer `open_fraction_ppm`, 0–1000000,
zero closed and one million open. Requested target, reported position, movement,
stop support and unknown are separate facts. Test inverse device scales at both
endpoints and intermediate values. Stop is a new separately authorized effect;
cancellation cannot unsend movement. Speed/favourite/tilt/obstruction/calibration
remain absent unless the exact cohort supports them. Disconnected last-known
position is history rather than current feedback.

The CMD-03 candidate requires explicit without-response BLE and an installed
host under planned WoTEx WBL.08, reviewed private identity and read/move/stop/
readback qualification. App timers do not establish timer-edit commands. The
[timer ownership contract](device-schedule-ownership-v1.md) owns migration;
no firmware update, timer modification or new hub is required by this target.

**LDB-02 — Media.** Source/favourite, session, reported playback state, volume
and stop use separate typed contracts. Volume is a qualified fraction, not
brightness. Request, local acceptance, playing report and audible output remain
distinct evidence. Enrolled private custody resolves source and required metadata;
routine source cannot supply arbitrary URLs or credentials.

The Sonos candidate preserves favourite identity/metadata rather than treating a
title as a stream URI. Local player and remote content availability have separate
failures. Subscription loss requires refresh/new baseline. Partial scenes retain
completed light/cover receipts when media fails, without automatic compensation
or resend. AirPlay/grouping capabilities require exact independent support.

[WOH.21](WOH.21-apartment-music.md) owns multiroom music, source capture,
group/member controls, current authorization and synchronization qualification.
The selected independent/consumer component MAU.01–04 owns the Rust engine,
media values, DSP/timeline, finite adapters and native host. WoTEx WST.01–02
own protocol streams, WPF.01–02 read external definitions; model/cohort profiles
remain consumer/publisher data. Volume uses normalized `volume_fraction_ppm`
0–1000000 with installed hardware-step/software-gain vectors, not equal loudness.
Clocked/calibrated/best_effort/unavailable grades retain actual timing evidence;
they never promote an ACK into audibility. The confirmed WONDERBOOM 2 candidate
uses host Bluetooth audio, with standby/reconnect and tail calibration; HomePod,
Cast, PLAY:1 and TV routes retain independent cohort gates. Foreground music
requires no routine kernel, voice, AI or Matter export.

**LDB-03 — Loads and channels.** A writable relay requires reviewed attached-load
class and qualified power-restoration/actuation policy; Switch branding does not
assign ordinary-light risk. Meter channels use v2's exact unit/direction/reset
semantics. Unsupported channels stay absent. Heaters/locks/safety maintenance
need separate effect/admission contracts.

SHCB-1's candidate mapping is RGBW bulb with actual colour/white-mode review.
SHMOS-02 product generation does not determine API generation: use its documented
Gen1 surface and actual reports. SHPLG-S requires load and meter-unit review.
Hue extends verified HTTPS resources/events without TLS downgrade. LIFX retains
numeric identity, correlation, separate readback and unknown-outcome handling.

**LDB-04 — Remotes and ecosystems.** Button gestures retain exact supported
event, source epoch/sequence and duplicate meaning. Initial/reconnected/retained
reports fabricate no press. Disclose coexisting bridge/device actions and avoid
executing one intention twice; an event supplies no authenticated human grant.

Matter import/export and Thread routing remain distinct. Home exports cannot
re-enter its device path. Unsupported cover/media/routine export is not disguised
as a Boolean switch. Exact TV/speaker models, firmware and public APIs precede
Art Mode/voice successors. No microphone or console API is inferred from identity.

## Failure, entry and acceptance

Profile/firmware replacement invalidates affected qualification, facts and
unsent routine work. Expanded declarations never widen old grants. Lost mutation
replies recover original scoped receipts; unknown handoffs are reconciled without
resend or causation claims. Recovery retains exact closure/history but grants no
freshness or activation authority.

Before each mapping's code freeze exact schemas, model/firmware/API/host cohort,
independent conversion/byte/report vectors, evidence thresholds, budgets,
private custody and physical lab procedure. A missing field is an entry failure,
not a default borrowed from a similar model. Generic routine evaluation and
Swift require no vendor branch.

H03-T8: independent traces cover inverted cover values, ACK-only/unknown movement
and granted stop; favourite metadata/content failure/partial scene; load denial,
meter resets and absent channels; duplicate/reconnected remote events and
coexisting bridge actions. Missing/changed required basis refuses control.
Record software, installed BLE/TLS/subscription lifecycle and actual device
read/move/stop/readback/override/WAN-cut results separately. Fixtures qualify no
candidate device.
