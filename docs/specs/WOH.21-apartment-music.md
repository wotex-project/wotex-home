# WOH.21 — Whole-apartment music and qualified speaker groups

Version: 0.2.0. Updated: 2026-10-13. Status: accepted target.
Implementation: planned. Evidence: missing.

## Purpose and scope

An authorized user selects music playing on the computer, a retained local file
or an enrolled media source and plays the same session on supported speakers
throughout the apartment. The user can select rooms, change group/member volume,
join/remove a speaker and see unavailable, partial or uncertain results. The
initial target is mono/stereo multiroom music, with a small shared startup delay.
True surround, video lip synchronization, open microphones, voice conversation,
device flashing and universal legacy-device support are outside this target.

The separately selected playback component owns media values, the portable Rust
timeline, DSP, output adapters and native host under MAU.01–04. WoTEx's
prospective WST.01–02 own optional lower-level stream/protocol joins; WPF.01–02
own generic external-profile interpretation. Device definitions and acoustic
qualification remain outside WoTEx. The full playback engine is allocated separately.
Home owns enrollment, sources/capture consent, room labels, grants,
Store history, current execution guards, qualification and native presentation.
Home remains one OTP application. `WotexHome.Authority` sequences use cases;
the single `Durable.Store` owns SQLite transactions/revisions/host locks.
Native workers get narrowly resolved capabilities, never a Store connection or
principal bearer. Audio samples travel in the native source/engine path, not
through the Store or public API.

## Required contracts and meaning

| Owner | Consumed behavior and present status |
| --- | --- |
| MAU.01 | Planned closed source/participant/group/command values, finite output closure and typed results; library loading is passive |
| MAU.02 | Planned common sample timeline, bounded buffers, epoch retirement, clock/drift correction and measured grades |
| MAU.03 | Planned exact Sendspin/AirPlay/Cast/native-group/host-output profiles; capability, protocol acceptance and audibility remain distinct |
| MAU.04 | Planned explicitly supervised Rust/native host, macOS process taps, specific output devices, bounded private IPC and continuous permission withdrawal |
| WOH.02/03/18 | Reviewed immutable profiles and enrolled pseudonymous Things; metadata/profile data cannot create a transport, permission or qualification |
| WOH.14/15 | Durable scoped originals, current guards, committed handoff and original-outcome recovery through one authority |
| WOH.08/16 | Native installation/permissions, host lifecycle and exact artifact/custody recovery; a compiled binary is not installed evidence |
| WOH.11 | Separate exact-device physical qualification; software fixtures and upstream claims cannot enable production dispatch |

The component contracts are [MAU.01](audio-engine/MAU.01-media-session-values.md),
[MAU.02](audio-engine/MAU.02-timeline-synchronization.md),
[MAU.03](audio-engine/MAU.03-output-adapters.md) and
[MAU.04](audio-engine/MAU.04-native-host-capture.md), with their
[catalogue](audio-engine/catalogue.yaml) and [component plan](../plans/audio-engine-delivery.md).
Before code, select the owned independent/consumer component source/facade and
exact protocol cohort; these documents do not allocate it to WoTEx. WST.01–02
are prospective protocol targets, not an available production dependency. No dependency pin or current producer is changed by this
contract. [WOH.20](WOH.20-universal-routines.md) can later consume admitted
media actions; ordinary foreground music must work without its optional kernel,
Matter, voice or an AI model.

## Closed Home input and output

**H21-01 — Description and bounds.** A stored group has format
`wotex-home.audio-group.v1` and exactly `group_id`, `revision`, `label`,
`members`, `minimum_grade`, `lead_ms` and `on_member_loss`. Group/source/session
IDs are authority-issued 128-bit opaque identities represented by 32 lowercase
hex characters. Revisions are uint64, represented as canonical decimal strings
on JSON; label is nonempty valid UTF-8 ≤128 bytes, no NUL. Members are 1–16
unique Home Thing IDs, each with an explicit required Boolean, sorted by ID.
Home resolves their producer participant/route and audible descendant closure;
callers cannot author native endpoint, MAC, process PID, profile or calibration.
The complete resolved physical output closure is at most sixteen enrolled Things.

Minimum grade is `clocked`, `calibrated` (default) or explicitly `best_effort`.
Lead is integer 250–10000 ms, default 2000. Member-loss policy is `continue`
(default) or `stop`. At most four sessions and sixteen unique physical outputs
are active controller-wide; session lifetime is at most eight hours. Native
queued audio is bounded to 4 MiB per route/source and 128 MiB globally; one
source per session, mono/stereo 44100/48000-Hz qualified conversion only.
No interpolation, codec or color/brightness meaning is inferred from device names.

Planned Authority use cases are `audio_sources`, `audio_source_put`,
`audio_source_forget`, `audio_group_put`, `audio_group_forget`, `audio_start`, `audio_pause`,
`audio_resume`, `audio_stop`, `audio_join`, `audio_leave`, `audio_volume_set`,
`audio_group_volume_adjust`, `audio_status` and `audio_original_status`.
Mutations carry authenticated scope,
authority epoch, original operation ID, expected Store/group revision,
expected session/playback epochs and exact operation payload. Session/playback
epochs use 32 lowercase hex characters; they are null for group put/new start,
otherwise must match current session state. Source selection/removal also use
null session/playback epochs. A stale pause/volume/stop cannot affect a later
resume generation. Exact typed operation payloads are:

| Operation | Closed payload |
| --- | --- |
| audio_sources | Empty object; read only, current source grants |
| audio_source_put | `selection_ref` (opaque nonempty ≤128 UTF-8 bytes), from the private host picker below |
| audio_source_forget | `source_id`, `source_revision`; refuse source_in_use while any live session uses it |
| audio_group_put | `group` (closed group body); new input group_id is null and revision is `0`, producing authority-issued ID/revision `1`; updates retain ID and advance revision exactly once |
| audio_group_forget | `group_id`, `group_revision`; refuse group_in_use while any live session uses it |
| audio_start | `group_id`, `group_revision`, `source_id`, `source_revision`; creates authority-issued fresh session ID/epoch |
| audio_pause/audio_resume/audio_stop/audio_status | `session_id` |
| audio_join/audio_leave | `session_id`, `member_id`, `group` (complete next group); join adds exactly that Home Thing, leave removes exactly it; revision is current+1 with checked overflow |
| audio_volume_set | `session_id`, `member_id`, `volume_fraction_ppm` (integer 0–1000000) |
| audio_group_volume_adjust | `session_id`, `delta_ppm` (integer -1000000–1000000) |
| audio_original_status | `authority_epoch`, `original_operation_id`; principal-private read, no new original |

All reads require current audio:read and relevant grants. New group/source
selection requires audio:manage; forgetting a source additionally requires its
ownership/access. Retain at most 64 source definitions and 64 group definitions;
full lists are bounded to those ceilings, and new definitions refuse capacity.
Source list entries contain exactly source_id, revision, kind, metadata and
availability (available/unavailable/unknown); kinds/metadata use MAU.01 bounds.
Stored groups have nonnull authority-issued IDs. Removing the last group member
refuses invalid_input; stop remains an independent operation.

Versioned WOH.15 API adapters expose these typed inputs under its existing
authenticated/original envelopes; no caller-supplied role or authority exists.
Admission returns the WOH.14 scoped receipt plus resolved session/playback epochs,
group/source revisions and sorted member outcomes. Current audio_status uses the
MAU.01 result shape with Home member-ID correspondence, grade_scope and nullable
pair_bound_us; it does not substitute an admission receipt for playback evidence.
No mutation accepts native structs, media URL, file path, account key or raw
packet. JSON unknown/duplicate members, invalid strings, overflow and ambiguous
IDs reject. Body ≤64 KiB and depth ≤16; no new field loosens an existing API.

API admission returns a held/terminal original within the existing finite API
exchange; asynchronous prepare/start has a total 15-second worker deadline:
prepare ≤10 seconds, control ≤5 seconds, both including queue time and capped
by the original deadline. Other controls have a five-second worker deadline.
These deadlines bound handoff/control response, not the future audible anchor;
a confirmed scheduled handoff may precede reported playing by the chosen lead.
Lost response is unknown and resolved through original status, not a fresh ID.

Outputs include immutable group/source/route basis, actual admitted/excluded
members, per-member original and outcome, readiness, reported playing state,
timing kind, grade/calibration scope, buffer delay, source availability and
current reason codes. Exclusion, protocol acceptance, reported playing and
measured audibility remain separate. Public results contain no private route,
OS process identity, source path/URL, PCM, credential or pairing material.

## Sources, selection and permission

**H21-02 — Source custody.** Trusted foreground setup reviews a local file or
specific application incarnation and publishes a private source revision/ref.
The authority derives public source IDs and resolves native custody privately.
The native picker creates a one-use selection_ref bound to principal, host/source
incarnation, kind, exact installed profile and reviewed source consent. It expires
after 30 seconds of that host's monotonic time and is lost on host restart.
Audio_source_put consumes it inside the authority transaction and creates a
fresh source ID/revision `1`; an exact original retry returns the original
receipt without consuming another selection or capturing again. An absent,
expired, cross-principal or changed-incarnation selection rejects selection_expired.
OS paths/bookmarks/PIDs/network credentials remain in private native custody;
the source list returns metadata (empty object when absent) and current
availability. Losing custody preserves historical receipt identity but reports
source_unavailable; it cannot reconstruct consent from the public source record.
Capture permission is separately scoped to that source; selecting Spotify does
not permit capture of other apps, the system mix, microphone or account tokens.
Source exit/PID reuse, OS permission loss or a changed source incarnation retires
the source epoch and session. No fallback to a broader capture source occurs.
File sources may work without WAN; Spotify/radio content availability is separate
from the local speaker-control path. An independent streaming-service receiver
is a later selected producer profile, not necessary for initial app capture.

**H21-03 — Current grants.** New installed permissions are `audio:read`,
`audio:manage` (group/source selection), `audio:control` and `audio:capture`.
Each is a new explicitly provisioned credential capability; existing read/light
grants do not gain them. Audio control also requires target grants for every
audible descendant, source access, current profile/declaration/qualification,
volume ceilings and the original author. Capture requires audio:capture and
foreground/OS consent for that exact source. An event, AI proposal, device name,
Cast group or native media button supplies no authenticated Home principal.

Native group/Double Up assemblies must expose their complete enrolled audible
closure or be reviewed as an explicit whole output assembly with all constituent
Things recorded. Unknown additional members refuse that topology. A native
group change or takeover invalidates unsent work and current readiness; Home
does not automatically regroup devices, replace a native queue or restore an
old favorite. Two sessions cannot own overlapping output closures. Another
authorized user must submit a current explicit stop/replacement operation;
arrival order is not permission to preempt.

**H21-04 — All supported speakers.** This UI selection resolves a reviewed
snapshot of authorized enrolled outputs with an installed music route, current
qualification and the selected minimum grade. Show every requested exclusion
and reason. Submit the exact resulting membership and snapshot revision; Store
rechecks the complete selection at commit. Newly discovered speakers cannot
join later automatically. Explicit required members that fail preparation
refuse start; optional members may be excluded with a partial result. Existing
members may keep playing after later loss under `continue` policy.

## Durable session and continuous stream boundary

**H21-05 — Admission and handoff.** Authority resolves source/participants
outside the writer. One Store transaction rechecks principal/grants, authority
epoch, source/group/profile/declaration/qualification revisions, complete output
closure, resource ownership, volume ceilings and capacity; reserves the group
original and bounded per-member child originals; records held work. Claim and
final handoff repeat mutable guards. A committed per-member handoff marker must
precede any play/group/source/volume transport mutation. Preparation is not play.
No sixteen-member control is implemented by widening the current single-Light
root/budget ledger; a new media admission/journal profile must be built first.

The session journal's required fields are original scope/digest, author,
authority/Store boot epochs, group/source revisions, full participant/descendant
basis, selected runtime/profile/calibration digests, retained deadline, per-child
held/claimed/handed-off/result states and terminal/unknown outcomes. Child
operation IDs are `audio-` followed by lowercase SHA-256 of UTF-8
`woh.audio.child@1\n`, the WOH.14 parent original seal digest, newline, the
exact Home member ID, newline and canonical decimal operation ordinal.
The ordinal starts at zero in sorted member order; the immutable resolved member
list fixes it. Children retain the parent's principal/authority scope.
Before code, freeze exact
schemas, derivation vectors and migration/backup integrity checks under this
owner. Do not invent a migration number or borrow absent fields from a similar
light receipt.

**H21-06 — Continuous guard.** After authorized start, the host owns a finite
stream capability bound to that session/source/closure and at most eight hours.
An in-memory guard is refreshed at least every 250 ms and expires within 1000 ms
without current consumer state. Grant/owner/source/profile/group changes and
maintenance revoke it; new ingestion/output stops at the next 250-ms check.
The host publishes current Store-owned invalidations without giving Rust a
writer or sending every PCM block through SQLite. Guard gaps fail closed.
Closing a presentation window does not stop an otherwise valid owned session;
controller/capture-host loss retires it. The Mac remains an availability
prerequisite while it supplies captured audio.

Stop/revocation withdraws future samples and initiates already-authorized session
cleanup. It cannot unsend queued audio or guarantee immediate acoustic silence.
Show `stopping`/unknown and the selected adapter's bounded remote tail; an opaque
tail stays unknown. Remote stop/pause requires confirmed ownership of that
session/source/route; after another controller takes over, close only Home's
stream/connection without stopping the new music. Never start a second stream
to repair an uncertain handoff.

**H21-07 — Recovery.** Identical logical retry resolves the original; changed
payload under that original conflicts. Pause/resume, seek/source replacement,
rejoin and process restart use fresh playback epochs; expired frames are never
replayed. On controller/engine restart retain group definitions, private custody,
qualification history and original outcomes, but sessions remain stopped or
unknown until fresh observation. No autoplay/auto-resume follows backup restore,
transfer, reconnect or source availability. A resume is a fresh authorized
operation on a live compatible session; after restart use a new explicit start.
Restore/transfer retains private source consent as history and requires new
host-specific capture permission, route review and current qualification.

## Timing, volume and presentation

**H21-08 — Synchronization evidence.** `clocked` requires current hardware or
scheduled clock feedback and exact-cohort acoustic evidence. `calibrated` has a
measured current fixed tail offset with a qualified stable cohort; `best_effort`
has playback but no established alignment bound. The selected qualification
target is ≤20 ms absolute inter-output skew for every one of at least 1000
probes over 60 minutes, without an unexplained epoch jump or dropout >250 ms.
Record one independent measurement clock and acoustic/channel corrections.
This is the engineering requirement for a claim, not a guarantee from a brand,
protocol, schema or timestamp log. Group grade is the lowest actual active
member grade, including optional members, with its exact participant scope.
Missing/excluded members remain partial/degraded outcomes; they do not count as
playing. Below-minimum optional members are excluded before start/join. A group claim
also requires evidence for this combination or composable residual error
intervals relative to one qualified reference. Including clock/calibration
uncertainty, max(upper_i)-min(lower_i) must be ≤20000 us. Missing/incompatible
bounds make the group best_effort despite stronger individual route grades.
Start/join requires the composed group to meet the requested minimum. Home
privately resolves combined-cohort qualification or composable participant
bounds into producer inputs; callers cannot assert that evidence. Losing the
minimum withdraws the affected route within 250 ms and follows member-loss
policy; an unisolatable cause stops the group, never silently lowers policy.

Calibration binds exact physical output, source/build/profile, host/codec/rate,
processing and route generation. Reconnect/firmware/route/codec changes retire
the current basis; retained offsets become proposals until the qualified stable
cohort's reconnect validation passes: at least ten independently measured probes
within 60 seconds against the same reference, with every skew ≤20 ms and no
changed codec/processing/physical-unit assumption. Otherwise retain best_effort
or unavailable under the requested policy. Calibration may use an explicitly authorized test
tone and microphone; neither background listening nor microphone access is
required for ordinary music. Distances and room reflections affect listening
positions, so qualification does not promise perfect sound arrival everywhere.

**H21-09 — Volume.** Ppm is a normalized control fraction, not light brightness,
measured loudness or sound-pressure dB. Installed adapter vectors define hardware
steps or software gain; avoid double attenuation and never round above a granted
ceiling. Preserve member settings when adding a group. A group volume adjustment
is an explicit bounded delta applied to each current authorized member and
clamped at its ceiling, with per-member originals/results; one failed member
does not cause compensating volume changes elsewhere. Native external changes
remain reports, not authenticated Home commands.

**H21-10 — UI and routine independence.** Native/API users see the source,
actual rooms, grade/evidence scope, delay, exclusions, lost/unknown outputs and
per-member controls. A requested group is not shown as fully playing from one
successful ACK. Source-content failure is distinct from speaker transport loss.
Ordinary playback works without routine/voice/Matter/model services. Later
WOH.20 media steps must name qualified completion thresholds and current effect
domains; unsupported media model/admission profiles remain unavailable. No
speaker/routine is exported as a pretend Boolean light/switch.

## Device scope and implementation entry

The candidate inventory is Sonos PLAY:1, HomePod mini, Nest Wifi Point H2E,
the unidentified bedroom Google speaker, confirmed WONDERBOOM 2 and Samsung
The Frame. Candidate means a route to investigate, not installed support.
Firmware/model unknowns remain unknown. For a device that cannot report firmware,
a reviewed `firmware_unreported` qualification applies only to the particular
enrolled physical unit/host route, never all devices of that brand/model.

WONDERBOOM 2 uses a host Bluetooth audio route. It must be powered on/in range;
its documented last-source reconnect and 15-minute inactivity shutdown do not
establish remote wake, persistent availability or independent native group
control. Double Up is outside the first single-unit route unless its complete
assembly is separately enrolled. PLAY:1 local playback is investigated first;
precise cross-brand sync is a separate qualification and may remain best_effort.
An AirPlay-capable Sonos coordinator is an optional separately reviewed route,
not an assumed existing device/purchase. Exact Cast receiver and TV capabilities
precede their selected profile; no hidden firmware modification is required.

Before production delivery: implement MAU component schemas/public archives/native ABI;
install MediaPlayer/source/group semantic declarations and independently encoded
Home journal/API schemas; review private source/profile custody; qualify signed
capture/output lifecycle and each actual device cohort; complete backup/transfer
fault cases. Physical dispatch remains default-disabled until its real gates
pass. Requirements do not enable hardware or modify current dependency pins.

## Acceptance obligations

| Case | Requirements | Stimulus and falsifier | Evidence |
| --- | --- | --- | --- |
| H21-T1 | 01–04 | Independent closed group/source/action vectors, definition capacity, expired/cross-principal/consumed picker references, aliases/duplicates/unknown fields, grants and all-supported snapshot races; no widened target/capture | Pure plus Store |
| H21-T2 | 02, 06 | Capture only selected app; deny/revoke permission, reuse PID, change default output/system mix; no broader capture/reroute | Installed macOS |
| H21-T3 | 03–07 | Crash around reserve/claim/handoff, lose response, revoke descendant/source and retry original; no replay, second writer or stale send | Real Store/process peers |
| H21-T4 | 01, 04–07 | Required vs optional prepare failure, full capacity, takeover, join needing more lead, source/host loss; survivors/policy and partial originals stay exact | Independent lifecycle traces |
| H21-T5 | 05–07 | Pause/resume/rejoin/restart/restore/transfer; no stale audio, copied consent, automatic wake or autoplay | Native/Store fault campaign |
| H21-T6 | 08–09 | Exact mixed hardware under independent acoustic recorder: 1000 probes/60 min, codec/reconnect/volume changes; claimed skew ≤20 ms, otherwise grade refused | Physical/installed |
| H21-T7 | 03, 08 | Forged/stale calibration, changed firmware/unreported physical replacement and missing native APIs; no qualification reuse or silent fallback | Independent profile/physical |
| H21-T8 | 01, 09–10 | Member volume cap/rounding and partial volume failure; UI separates desired, reported, audible, excluded and unknown | Software plus installed UI |
| H21-T9 | 02, 10 | Local file with WAN/Spotify/voice/Matter/AI disabled; local playback works, remote-content absence is honest | Installed WAN-cut |
| H21-T10 | 01–10 | Independent consumer archive plus Home composition; routine services absent, production dispatch guard disabled and unsupported device selected | Archive/Store; physical separately |

Every case is an obligation. [Research](../plans/apartment-music-research.md),
[delivery order](../plans/apartment-music-delivery.md) and the
[physical procedure](../labs/audio-synchronization.md) retain scope and evidence
without relying on this conversation.
