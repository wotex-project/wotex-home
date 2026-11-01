# WOH.06 — English voice and conversational Home control

Version: 0.3.0. Updated: 2026-11-01. Status: accepted target, partial implementation.

## Purpose and current evidence

English voice and text are the primary M1 interface to the supported home.
An authenticated operator can ask about current evidence, control qualified
ordinary lighting, run scenes, prepare routines and schedules, diagnose a
failure and recover the original outcome. This is a multi-turn product journey,
not a classifier demonstration or a chat window that only suggests commands.
Home remains independently usable through native/typed controls when inference
or speech is unavailable. English is the only M1 speech language.

The present `WotexHome.Intent.Grammar` and `Intent.Resolve` implement only a
bounded English Light-power candidate/preview. They do not implement this
conversation, speech, scene or broad control contract. Existing training and
classifier evidence is preserved below. Physical dispatch remains disabled by
default; no requirement here enables a device, widens a grant or supplies
hardware evidence. New H06-T7–T25 and the owning M1 cases remain unimplemented.

## M1 capability dispositions

The inventory describes the whole agent surface, not permission granted by a
model. M1 requires C01–C15 and C20 for its actual qualified reference cohort.
Unsupported targets/capabilities are explicit; their absence cannot be silently
filled with a guessed binding or simulated success. C16–C19 retain independent
later gates. Catalogue completion for a whole contract and M1 profile acceptance
are separate decisions.

| ID | Capability and agent behavior | Authority/disposition | Owning boundary |
| --- | --- | --- | --- |
| C01 | English push-to-talk input, final transcript, spoken response and text parity | Required; only an explicit native capture session supplies audio | WOH.06/08 |
| C02 | Multi-turn clarification, correction, scoped context, task progress and interruption | Required; conversation is not a permission or physical-state store | WOH.06/14/15/16 |
| C03 | Inspect permitted rooms/Things/capabilities, current reports, quality, age and history | Required read; unknown/stale remains explicit | WOH.01/14/15 |
| C04 | Execute ordinary power, dimming, colour, white temperature and transitions | Required qualification for capabilities actually present in the selected lighting cohort; no reuse of power-only proof for broader writes | WOH.01/03/05/11/14 |
| C05 | Create/edit rooms, groups and scenes; run admitted exact member sets | Required; membership review, per-member authority/results and non-atomic physical effects | WOH.01/14/15 |
| C06 | Draft/explain/compare rules, inspect conflicts, simulate/shadow and request activation review | Required; native current review and positive admission precede activation | WOH.04/07/20 |
| C07 | Prepare calendars, one-shots/countdowns and schedule changes; inspect due/missed/paused work | Required; native clocks, current author, original occurrence and qualified scheduler | WOH.04/14/15/20 |
| C08 | Apply permitted temporary overrides; inspect/expire/revoke them and explain precedence | Required; finite native lease, current scope and whole-Thing arbitration | WOH.04/14/15 |
| C09 | Read supported sensor/battery/fault/smoke reports and explain uncertainty | Required; detector baseline read-only, independent detection/siren, notification acknowledgement is not clearance | WOH.01/03/05/11 |
| C10 | Diagnose, explicitly refresh an enrolled Thing, inspect bounded host/network/model health and prepare support | Required scoped read; no network sweep, arbitrary URL or shell access | WOH.03/15/16 |
| C11 | Guide discovery, compare identities, prepare profile import/mapping and replacement review | Required assisted path; enrollment/trust/selection/qualification/grants remain distinct native decisions | WOH.02/18 |
| C12 | Explain access, prepare pairing/grant/revocation and controller-selection tasks | Required assisted path; current protected native identity decisions, no agent-issued bearer or self-grant | WOH.05/15 |
| C13 | Guide backup, update, maintenance, restore and owner transfer; inspect progress and originals | Required assisted path; native maintenance/custody/fencing and separate installed evidence | WOH.08/14/15/16 |
| C14 | Configure admitted assistant/mic/voice/locale/privacy profile and inspect retention/capacity | Required; protected native configuration, local defaults, no automatic cloud/training | WOH.05/06/16 |
| C15 | Deliver opt-in scoped task/sensor notices with quiet/privacy controls and current evidence | Required local presentation; not a certified alarm or autonomous privileged response | WOH.05/06/08 |
| C16 | Music/source/speaker-group control | Later; comprehension is not a playback engine | WOH.21 / MAU contracts |
| C17 | Wake word, ambient listening, satellites, vendor assistants, semantic full duplex and Matter | Later explicit voice/privacy/endpoint qualification | WOH.06/10 |
| C18 | Hush/mute/reset/OTA, unknown-load plugs, locks, heaters, medical or other high-impact control | Unavailable in M1; separate capability/safety authority, never another spoken confirmation | WOH.03/05/11 |
| C19 | Dedicated Nerves/manufactured hub and additional host/hardware cohorts | Later/optional; no server required for standalone Mac features | WOH.09/12/19 |
| C20 | Explain install/compatibility/security/help and link accurate release material | Required; static public help has no anonymous controller or customer-data API | WOH.08/16 |

## M1 shared execution profile

**H06-06 — Qualified reuse.** Reuse Refpath's public agent/conversation,
model routing, speech and admitted tool-execution services through a selected
local profile. Home owns its consumer facade, meanings and physical authority;
it must not create another generic agent loop, speech coordinator, model router,
approval ledger, task store or pricing engine. WoTEx owns TD/TM, profile,
protocol and routine mechanics; ExBooking owns its selected calendar mechanics;
ExMaude supplies only its actual bounded checker/receipt contract.

Home currently has no selected Refpath pin or installed Home connector. The
profile must first fix source/licences, configuration, public contracts,
storage/custody, provider/model artifacts, extension ABI/export and supported
host. The inspected Refpath source is evidence of candidates, not a dependency
upgrade. `refpath_home_assistant` integrates the separate Home Assistant product;
it is not a WoTEx Home connector. Missing producer behavior is delivered and
qualified at its shared owner before dependent Home adoption; never substitute
a local clone or silently mount Core/admin tools. The existing Home core remains
independent of this optional execution service even though its qualified local
assistant profile is required for M1's primary experience.

**H06-07 — Current association.** A trusted native session selects one Home
controller and a finite assistant scope. The host binds the authenticated client,
Home principal, controller/authority epoch, current allowed targets/operations,
selected Refpath profile and expiry outside model arguments. Per-call Home
checks resolve current authority; cached tool lists, conversation IDs, model
context, LAN address, speaker identity and past approval never supply it.
Delegate no more than the intersection of that current grant and the selected
assistant scope. Control does not imply enrollment, qualification, rule/host
management or access to other principals' receipts. Pairing and scope changes
are protected native tasks. No bearer enters a prompt, tool arguments, transcript,
worker payload or device packet. Device workers still receive narrow resolved
work, not Store handles or operator credentials.

A facade exposes only typed, bounded Home operations: scoped catalogue/facts/
history and diagnostics, ordinary control and admitted scene requests, rule/
schedule/profile preparations, permitted overrides and original status/cancel.
These are target operation classes, not claims of installed API names. Store
alone admits new effects. Activation, credential issue/export, target grants,
qualification, source trust, restore, firmware and raw transport/SQL/shell are
not ordinary agent tools. A request for protected work opens the exact native
review task and returns its status; it never manufactures a positive receipt.

## English capture, interpretation and output

**H06-08 — Explicit local capture.** M1 uses push-to-talk in the native app or
its shared menu/keyboard action. There is one capture owner per selected native
session, visible recording state, a selected input/output device, permission and
mute controls, and a reliable stop action. No launch/login/background/wake-word
recording. Permission denial/revocation, screen/session lock, controller/principal
switch, input removal, sleep, client loss or capture error stops capture and
invalidates its incomplete turn. No other app's system-audio capture or WOH.21
music permission follows from microphone consent.

The admitted local speech profile prepares English audio through its qualified
audio converter, recognizer and synthesizer. All artifacts are installed and
verified before the WAN-free readiness check. Missing model/voice, unsupported
locale, engine failure or resource exhaustion shows unavailable and preserves
manual/text control. No speech/provider download or cloud fallback occurs at
startup or runtime. Existing separately approved remote profile-authoring does
not supply permission to export voice or household context.

**H06-09 — Complete utterance and repair.** Partial transcripts are display-only.
An effect proposal requires a complete final utterance, resolved current target,
exact value/unit and the current Home risk decision. Never dispatch from the
first plausible words while later negation or a second clause is still pending.
Clipping, OOD/language uncertainty, conflicting names, missing units, pronouns
without a current unambiguous reference and incomplete scope require clarification
or refusal. Quoted commands, device names, imported instructions, TV/audio
content and text being discussed are not command authority. An untrusted label
cannot instruct the model to fetch secrets or alter policy.

Context references are re-resolved under the current session/grants and exact
membership/declaration revisions. Unsupported English accents or code-switching
produce explicit repair; no Swedish recognition/support claim is made. Spoken
clarification can resolve an ordinary target/value within existing authority.
A spoken yes, a high score or a generated review cannot replace a protected
native decision. Speaker recognition/voice cloning is not an M1 identity feature.

**H06-10 — Honest spoken results.** The response is derived from scoped native
receipts/reports and named evidence, not optimistic model narration. Distinguish
prepared, awaiting review, admitted/queued, handed off, protocol acknowledged,
reported match/mismatch, unavailable and unknown. A matching readback is a device
report with its actual trust; it does not prove physical causation or light output.
Use a separately correlated read after the transition where the profile requires
it. Say which members succeeded, failed or remain unknown; never announce “all
off” from one ACK or missing member.

TTS uses the selected local English voice and selected endpoint only. Sensitive
private detail defaults to the screen; spoken notices need explicit audience/
privacy and quiet settings. Alarm/report acknowledgement never clears smoke or
mutes independent hardware. Muting Home's convenience output is separately
labelled. Interrupting TTS stops playback immediately and prevents that audio
from being captured as a new command; it does not undo or repeat device work.

Push-to-talk stops ongoing TTS before accepting another capture. This is
turn-taking with interruption, not semantic full duplex. A spoken result
starts with its current disposition and any required operator action; output
limits cannot hide a denial, partial or unknown outcome behind a long preamble.
The complete authorized original/result remains reachable in native text.

## Bounds and defaults

**H06-11 — Finite work.** These are conservative M1 admission defaults, not
performance claims. A selected producer/host may impose stricter bounds; it may
not silently raise them. Any increase needs a new admitted profile and regression
qualification. Use shared execution/speech owners for their enforcement, not
parallel Home counters.

| Subject | M1 default/maximum | Failure meaning |
| --- | --- | --- |
| Capture | One explicit utterance, at most 30 seconds | Limit/clipped audio is not an executable partial command |
| Speech input at the admitted recognizer boundary | Mono signed 16-bit little-endian PCM, 16 kHz, at most 480,000 samples / 960,000 bytes; qualified conversion before this boundary | Wrong format/size or missing converter refuses transcription |
| Final user text | At most 8,192 UTF-8 bytes; no NUL; no hidden truncation | Oversize/malformed input refuses the turn |
| Interactive assistant scope | 15 minutes idle and 30 minutes absolute; earlier native lock/revoke/change ends it | Resume requires fresh current association; conversation data cannot renew it |
| Reasoning per turn | At most four model steps, eight tool calls and 60 seconds elapsed | Stop new work and show pending native originals; never restart a handed-off operation |
| Read/ordinary tool invocation | At most 30 seconds or the stricter native deadline | Lost response is distinct from no effect; inspect original status |
| Scene/control plan | At most 16 exact members, one absolute proposed effect per whole-Thing domain in the approved step | Larger/incompatible scope needs explicit narrowing; no automatic chunking |
| Assistant concurrency | One active mutating turn per principal and at most two active turns per Home controller | Busy/refusal; native emergency/read paths keep their own reserved capacity |
| Spoken answer | At most 2,048 UTF-8 bytes and 30 seconds playback | Stop with visible continuation; full authorized detail remains on screen |
| Conversation history | Local private shared-owner storage, seven-day default, at most 20 threads / 50 turns each / 5 MiB total per Home; user may disable or shorten | Capacity refuses new persistence without discarding unresolved native originals |
| Raw audio | Ephemeral private lease for the current turn only; no recording retention by default | Revoke/retire after consumption, cancellation or expiry; crash residue is quarantined and removed before reuse |

A turn is one final user input and its bounded assistant/tool response group.
Expiry/accounting uses the selected host's actual clock contract, not model time.
Home device attempt spacing, causal budgets, invariant and occurrence limits
remain independently enforced by the current native owners; model/tool quotas
cannot refund or replace them. If shared execution lacks the required principal/
controller cap, qualify that producer primitive before adoption. Background
household intent becomes a native admitted routine/schedule, not an unbounded
sleeping agent loop. CPU/memory/storage/output limits and dispatch-latency evidence
must name the real host profile before acceptance.

## Planning, human decisions and original operations

**H06-12 — Current native effects.** Ordinary qualified actions can execute
without a new visual confirmation on every turn, using the user's explicit
request and current scoped grant. Semantic/risk admission, resource revision,
profile/runtime qualification, current observations and Store policy still run
at native admission/claim/handoff. A successful generic tool/approval check is
insufficient. Never pass model-authored endpoints, packet bytes, arbitrary code,
a requested permission body or a qualification claim to a device worker.

Resolve “all” into an exact current visible member set before admission. A
restricted, unknown or missing required member blocks the proposed aggregate
until the user explicitly narrows it. A membership change invalidates the plan.
After execution starts, report partial outcomes and preserve each member's
original identity; physical all-or-nothing and generic scene rollback are not
promised. Any corrective change is a separately authorized new intention, not
an automatic compensation that overwrites another controller's newer state.

**H06-13 — Protected decisions.** Enrollment, profile approval/selection,
capability expansion, credential/pair/grant changes, routine admission/activation,
sensitive configuration, backup disclosure, restore and owner transfer require
exact current native permission and human review where the owning contract
requires it. Show target, source/artifact revision, changed scope, consequences,
expiry and outstanding operations before approval. Any changed subject/basis
requires renewed review. The authority ReviewGate's concurrency capacity is
not proof of human approval; Store owns its actual current checks/commit.
No universal “approve all agent actions” or voice-only administrator mode.
C18 remains denied even if a person types or speaks another confirmation.

**H06-14 — Original recovery.** Bind every accepted native operation to its
existing `(principal, authority epoch, operation ID)`, canonical payload and
Store disposition. A shared task may reference several native originals; it
cannot replace their identity or create another Home effect ledger. Retain the
scoped task-to-original association before uncertain handoff. Shared Refpath
conversation/task persistence is selected and qualified once; Home retains only
its native business/receipt truth and required opaque association.

After reconnect, retry, TTS interruption, timeout, process failure or restart,
recover the same current-authorized original status before proposing new work.
The model being unavailable cannot make native status/cancel/reconciliation
unavailable. An exact replay cannot use a newly minted identity, renew grants,
spend another causal root, refund a spent root or require live generation when
the original owner's replay contract is producer-independent. Cancel before
native handoff only as that owner permits; after handoff show in-flight/unknown
and reconcile without a resend. Revocation denies new work at every boundary;
historical receipt access follows current native scope, never a global agent feed.

**H06-15 — Routines are a separate path.** Conversational authoring produces
closed native source and a bounded preview, not an active scheduler. Preserve
validation, analysis, supported positive proof/correspondence, shadowing,
current exact-subject review, admission, activation and runtime guard distinctions.
A found counterexample blocks; no counterexample, timeout, unsupported model or
provider confidence is not positive admission. Inspect the complete current
active set/whole-Thing arbitration, not just a caller-provided proposal subset.
Use WOH.20/WoTEx/ExBooking clocks and kernel where selected. A schedule needs
current author/grants, clock/source, occurrence identity, lateness/catch-up,
expiry, override and restart behavior. An assistant cannot turn a future
risky intent into a background retry loop. Existing qualified routines remain
independent of a conversation/model outage while their own assumptions hold.

## Context, privacy and lifecycle

**H06-16 — Data does not grant authority.** Retrieve the minimum current Home
data needed by the authorized turn. Tool outputs, TDs, names, docs and histories
are untrusted content; isolate them from instructions and prohibit prompt-driven
scope/egress changes. No unrestricted filesystem/web/email access, external
account connection or global Refpath tool catalogue is required for M1. Local
model/profile installation uses verified artifacts through the existing owners.

Conversation text, derived summaries and audio are not training permission.
No cross-home sharing, default feedback export, fine-tuning or telemetry of raw
prompts/room names/credentials. Retained summaries/embeddings, if selected at
all, inherit source audience, purpose, expiry and deletion; they cannot be an
unbounded second memory. Optional history uses the bounds above and explicit
native controls. Clearing conversation/audio does not delete Home receipts,
spent-root tombstones, unresolved effects or required review/recovery evidence.
WOH.16 owns coordinated disposal/restore policy and its real postconditions.

Before prompt composition, history/replay reads, buffering and text/TTS delivery,
resolve the current source audience and withdrawn/revoked access. Retire or
filter now-inaccessible source context and buffered output through the selected
shared owner; an old transcript/summary cannot reintroduce a forbidden source.
Native historical audit/receipt access follows its own current policy. Model
memory never decides whether either class may be disclosed.

**H06-17 — Independent failure domains.** Refpath/model/speech/TTS workers have
explicit host ownership and bounded supervised resource/IPC profiles. Their
failure cannot restart the radio/controller, block Store or starve alarm/report
processing. Closing a window stops its capture, not an enabled background Home
service. Sleep/wake, logout, locked custody, changed output and paired-link loss
produce truthful availability. Stop capture/speech on changed context; scoped
native state/receipts determine safe recovery. Installation, code/model updates,
compatible rollback and restored conversation require new exact-profile checks;
restored data alone never re-arms dispatch or restores current privileges.

## M1 user journeys

**H06-18 — Complete receiving journeys.** Every journey includes loading,
empty, denied, stale, offline/unavailable and unknown states where applicable.
It must be usable through the actual native/paired receiver with its original
operation visible; a tool transcript or isolated component does not complete it.

| Journey | Public stimulus and complete outcome | Required adverse trace / owning cases |
| --- | --- | --- |
| J01 First use | Install, choose local controller/network, establish owner custody, select admitted local assistant/English voice, explicitly allow mic, enroll/qualify/grant actual devices, complete first control/readback | Missing artifacts/permission/qualification stays unavailable; H00-M1-T1, H08-M1-T1, H11-M1-T1, H06-T7 |
| J02 Everyday voice/text | Ask for exact lighting change or current report; clarify, admit, dispatch/read back, speak the scoped outcome | Negation, ambiguity, stale facts and unsupported colour do not send; H06-T8–T12 |
| J03 Correct/interruption | Revise an unsubmitted utterance, interrupt playback, cancel pending work or reconnect to its original | Cancellation after handoff never recalls/repeats; lock/revoke clears active context; H06-T16/T19 |
| J04 Rooms/scenes | Inspect exact membership, author/review, run and inspect every member | Changed/restricted member blocks preflight; partial completion remains partial; H01-M1-T1/T2, H06-T14 |
| J05 Routine/schedule | Describe intent, edit source, analyse/shadow, review exact basis, admit/activate, inspect occurrence, override/revise/retire | Conflict, inconclusive proof, missed time, changed active set and clock loss; H04-M1-T1/T2, H20-M1-T1/T2, H06-T15 |
| J06 Sensor concern | Inspect smoke/fault/missing data, explain provenance and issue permitted local notices | Missing reports do not clear alarm; hush/firmware denied, hardware independent; H05-M1-T1, H06-T23 |
| J07 Add/replace | Discover/import or manually author, compare identity/firmware/profile, review/qualify and grant separately | Address/name reuse cannot transfer trust; updates revoke affected qualifications; H02-M1-T1/T2, H18-M1-T1/T2 |
| J08 Pair/revoke | Pair actual LAN client, select limited scope, use voice, revoke during work and inspect disposition | Foreign peer/controller, changed association and revoked grants cannot dispatch/disclose; H15-M1-T1/T2, H06-T11 |
| J09 Failure/recovery | WAN cut, device loss, model/host restart, backup/restore/transfer; recover originals and current observations | No new identity, automatic resend, old-clock freshness or dual owner; H14-M1-T1/T2, H16-M1-T1/T2, H06-T25 |
| J10 Privacy/exit | Stop mic/TTS, shorten/disable history, export permitted support data, revoke assistant/client and retire device/home | Prove derived disposal, no secret export, retained unresolved obligations and no stale restore; H06-T17/T25, H16-M1-T2 |

## Required surfaces

**H06-19 — One native product.** Reuse WOH.08's existing Things, Rules, Activity
and Setup/session models; conversation is the primary normal-use entry after
explicit setup, not a second shell/controller. First launch still starts with
Setup before credential access/API contact. Families below may share views,
but none may disappear behind an unimplemented chat promise. Every protected
transition has a reachable native receiver; data/credentials are never entered
into an unrestricted model prompt.

| Family | Required task/page surface |
| --- | --- |
| U01 | Conversation/voice: permission/recording/transcript, current scope, clarification, progress, text fallback, interrupt and original result |
| U02 | Home/rooms/Things: authorized catalogue, group membership, current unknown/stale health and selection |
| U03 | Thing detail: exact capabilities/profile, reports/history, typed controls and missing qualification |
| U04 | Scene editor/preview/run: exact members, risk/review, per-member results and no generic rollback |
| U05 | Routine editor: generated/manual source, analysis/conflicts, shadow/evidence and separate review/admission |
| U06 | Active routines/schedules/overrides: due/missed/paused, clock availability, expiry, conflicts, pause/revise/retire |
| U07 | Sensor/notice detail: smoke/test/fault/missing distinction, scoped audience/quiet settings and independent-alarm limitation |
| U08 | Activity/recovery: shared task plus native originals, current status, uncertainty, cancel limits and reconciliation |
| A01 | Controller/network setup: explicit host/interface, registration versus health, standalone/paired selection and background lifecycle |
| A02 | Discovery/profile/enrollment: host-held evidence, manual/import authoring, exact trust/selection/qualification and separate target grant |
| A03 | People/paired clients/grants: protected custody, current principal, limited targets/permissions, expiry/revocation and independent host maintenance |
| A04 | Assistant/mic/model/privacy setup: admitted local profile/artifacts, English input/output, selected devices, retention and no silent cloud fallback |
| A05 | Maintenance/recovery: signed update/custody, capacity, backups, restore quarantine, transfer fencing and original operations |
| A06 | Data/support/exit: minimized export, conversation/audio/derived disposal, retained evidence explanation, revoke and device retirement |
| P01 | Public product overview and truthful local/experimental/M1 limitations |
| P02 | Public install/download/offline-artifact and supported-host instructions |
| P03 | Exact hardware/firmware/capability/locale compatibility and qualification matrix |
| P04 | Privacy/security/microphone, LAN threat model, egress and independent-safety explanation |
| P05 | Help/troubleshooting, unknown-outcome recovery and minimized support procedure |
| P06 | Release notes, source/model/dependency licences and actual unresolved release gates |

P01–P06 use the existing public documentation/release structure; they create no
hosted account/subscription or anonymous controller API. Native/paired views
must preserve selected controller, drafts, review subject and pending originals
across adaptive layout and reconnect. Keyboard, VoiceOver, visible mic status,
readable errors and reduced-motion/contrast preferences require installed
English task evidence. Voice is an additional accessible input, not a reason
to remove typed controls or make private results automatically audible.

## Release acceptance

**H06-20 — Evidence before availability.** Execute the cases below through the
real shared profile and Home Authority/Store. Keep software, framed/TLS, mounted
native, signed installed, audio/model and physical-cohort subjects separate.
Record exact host/microphone/output, source/build/configuration, schema/runtime,
model/tokenizer/voice and device/profile/firmware identities. Primary paths use
WAN/DNS blocked after complete local provisioning. A mocked recognizer, schema
pass, signed fixture or synthetic device cannot close the installed/audio/
physical gate. Normal dispatch remains disabled until WOH.11 evidence admits it.

For English speech retain a consented independently sourced evaluation set with
at least ten speakers, distinct sessions and representative accents, distances,
quiet/noisy conditions and microphone profiles: at least 200 actionable and
200 negative/ambiguous/quoted/negated/background/unsupported examples. Compare
exact expected semantic targets/values and abstentions, report raw recognition,
repair/abstention and end-to-end task results separately; never credit model
accuracy for a later guard's rejection. Publish measured latency/resource and
supported conditions rather than claiming a universal score or hardware rate.
On the selected reference host, the M1 target is visible recording/stop feedback within 150 ms and p95 first meaningful spoken response within five seconds after a complete ordinary utterance with warmed artifacts; record cold-start separately. Pending device work must be described as pending. These are qualification targets, not timings established by this documentation.
The release target is at least 95% correct permitted task completion after at most one clarification on the actionable cohort, with recognition errors, abstentions and denials reported separately. This is an unmeasured acceptance target, not an achieved result.
Every unauthorized/adverse trace below requires zero forbidden native effects;
passing a corpus does not establish a field safety/error-rate guarantee.

| Case | Stimulus and enforcing owner | Independent proving assertion / falsifier |
| --- | --- | --- |
| H06-T7 | English push-to-talk on installed selected host, actual local ASR/agent/TTS and real qualified light | Source utterance/expected target/value, native original and correlated report agree; fabricated voice/provider/device evidence fails |
| H06-T8 | Same English intent by text and voice through current Home facade | Independently authored expected request and actual Store outcome/denial match; recognizer is not a second authority |
| H06-T9 | Ordinary authorized control without per-command visual approval | Current grant admits exactly the requested qualified effect; hidden human click, widened profile or unchecked host function fails |
| H06-T10 | Negation, quoted/background audio, incomplete/long utterance, OOD, pronoun and duplicate alias | Expected clarification/refusal and zero forbidden driver calls; partial transcript dispatch fails |
| H06-T11 | Foreign principal/target, stale association, removed member, revoked grant during read/queue/claim/handoff | Actual Authority/Store read/effect denied at the relevant boundary; no foreign data in text/audio/stream |
| H06-T12 | Smoke hush/reset/OTA, unknown-load plug, raw endpoint/packet/shell, self-grant and prompt injection | Independent forbidden-operation recorder sees zero calls and durable denial; spoken yes/confidence cannot change it |
| H06-T13 | Native exact-subject review then change payload, source, controller, generation or target | Store rejects stale/substituted review; capacity-gate success and a generated receipt cannot authorize it |
| H06-T14 | Two real scene members with one denied/changed preflight and one later lost response | No aggregate effect before narrowed approved scope; per-member original outcomes preserve partial/unknown, no blanket rollback |
| H06-T15 | Routine/schedule from conversation to shadow/review/admission/activation and due occurrence | Independent source/clock/active-set oracle plus real Store trace; no shadow effect or inconclusive/composed auto-admission |
| H06-T16 | Lose reply/reconnect/restart and cancel before/after handoff | Same native original/status and spent-root history; exactly one permitted handoff, no identity renewal or blind resend |
| H06-T17 | Canary prompts/room names/keys/audio, history expiry/disable/export and derived-data cleanup | Inspect actual logs/IPC/files/shared store/export with scoped canaries; no unauthorized disclosure/training or hidden residual copy |
| H06-T18 | WAN/DNS blocked, absent local artifact and unrelated remote authoring configured | Actual local English journey works when complete; unavailable local profile refuses without outbound speech/context fallback |
| H06-T19 | Lock/sleep, device removal, TTS interruption, model crash, capacity/deadline exhaustion | Capture/output retire under actual native lifecycle; no recycled audio/new effect, Store/observation remains responsive |
| H06-T20 | U01–U08/A01–A06/P01–P06 with native/paired English tasks and realistic errors | Actual keyboard/VoiceOver, reflow/focus/draft/original continuity and accurate public copy; static components alone fail |
| H06-T21 | Exact shared export/provider/ABI/artifact and licence closure on clean supported install | Public receiving path works with only admitted operations; missing producer primitive/unsupported deployment remains unavailable |
| H06-T22 | J01–J10 and C01–C20 offered/denied dispositions | Independent full-journey review proves every required receiving task and no implied later hardware/media/Matter privilege |
| H06-T23 | Real detector test/report/loss and local convenience notices | Manufacturer-defined detection/siren independence remains separate; no missing-to-clear or UI-ack-to-hush transition |
| H06-T24 | Duplicate/concurrent agent turns and scene members with shared limits plus native causal roots | Real shared admission and SQLite originals preserve both budgets; no extra Home generic counter, refunded root or hidden chunking |
| H06-T25 | Restore/transfer/rollback of conversation associations and Home originals with revoked access | Native owner stays fenced, old freshness/grants do not revive, unknown obligations remain and disposed private context is not silently reintroduced |

Existing H06-T1–T6 below retain the classifier/demonstration scope and their
original unfulfilled evidence. They do not require installing DistilBERT to
accept a separately qualified shared M1 agent, unless the Goatmire profile is
also offered. No acceptance item is marked passed by this specification update.

## Sources and implementation entry

Home owners: [semantics/scenes](WOH.01-home-semantics.md),
[automation](WOH.04-state-automation.md), [safety](WOH.05-safety-security.md),
[verification](WOH.07-formal-verification.md), [native host](WOH.08-macos-host.md),
[hardware](WOH.11-hardware-qualification.md),
[durable originals](WOH.14-durable-execution.md),
[current authority](WOH.15-local-api-authority.md),
[recovery/privacy](WOH.16-release-recovery.md),
[profile authoring](WOH.18-portable-profile-admission.md) and
[routine consumption](WOH.20-universal-routines.md).

The shared public owners are Refpath IN.44 voice endpoint interoperability,
IN.23/IN.38 protocol/identity scope, CV.01/CV.04 conversation/storage and the
selected speech/execution/provider contracts. Exact installed consumption and
missing generic primitives must be qualified before dependent Home code.
Home's consumer envelope/schema, scoped operation allow-list, task-to-original
association, artifact/configuration and independent vectors are required entry
work; this document describes target semantics, not invented callable APIs.

[Apple on-device speech availability](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
requires checking the actual recognition capability; API presence is not an
offline guarantee. [MCP tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
do not replace Home's business permission checks. [LIFX state-change semantics](https://lan.developer.lifx.com/docs/changing-a-device)
require operation/profile-specific response handling; immediate responses must
not be promoted to a completed transition. These sources support requirements,
not a current model/device/host qualification claim.

## Existing classifier and demonstration contract

The following implemented baseline and historical experiment remain separate
from the new primary experience. Their existing requirement/case IDs and evidence
are retained; the English voice/M1 rules above govern the broader new profile.

### Classifier role and model choice

**H06-01.** DistilBERT remains required in the complete Goatmire demonstration profile. It is optional to ordinary Home control. A classifier produces a candidate; it neither discovers physical truth nor authorizes an Action. Typed UI/CLI and structured Matter commands bypass classification and use the same command gate.

A base DistilBERT checkpoint is not a trained home-intent recognizer. Admission requires an actual sequence-classification checkpoint, exact tokenizer, label map, calibration, artifact license and evaluation evidence. Local candidates under `_build/intent-model-*` are deliberately **not admitted**. The Elixir training path uses [Bumblebee's fine-tuning approach](https://bumblebee.hexdocs.pm/fine_tuning.html) with Axon and EXLA. A later offline serving path must load the native Nx parameters with the matching model definition and qualify its execution backend. [Bumblebee's text classification serving](https://bumblebee.hexdocs.pm/Bumblebee.Text.html#text_classification/3) supplies a mechanism, not our intent labels or accuracy guarantees.

**H06-02.** Compare the trained model against a deterministic grammar and a compact statistical intent baseline. Keep DistilBERT for the requested PoC even if another optional profile later wins on energy/latency. The ten-command benchmark alone does not justify another generative LLM or retrieval runtime. The broader M1 workflows above use the qualified shared service rather than a Home clone. ONNX/runtime alternatives are separate qualified profiles, not silent conversions with assumed equivalent scores.

### Classifier candidate contract

A candidate carries model/tokenizer/label-map identities, supported locale, normalized text reference or ephemeral digest, ranked intents and scores, slot candidates with provenance, ambiguity/OOD disposition and evaluation timestamp. Raw scores are not calibrated probabilities. Input digests are not retained by default because common household phrases can be guessed.

**H06-03.** Device/room references resolve against the currently authorized registry after classification. An ambiguous 'turn it off' requests clarification; it does not select the last arbitrary device. Slots require deterministic type, range, unit and permission validation. Multi-action phrases are either explicitly supported by the grammar or rejected; truncation may not silently remove negation or a second clause.

The first grammar baseline recognizes only anchored English `turn/switch on/off [the] <exact target alias>` phrases, with optional leading `please`, `could you` or `can you`. It accepts at most 256 input bytes, normalizes case and repeated spaces, and abstains on pronouns, clause conjunctions, punctuation indicating another sentence, unsupported locale and malformed text. Its result is an ephemeral candidate, never an authenticated request. An exact alias must resolve to one currently granted enrolled Light with a validated writable `power` capability; only then may a typed mutation *preview* be constructed. The caller must still submit that preview to the authenticated Store gate, which rechecks current grants, revision, policy and runtime state. The grammar does not provide DistilBERT evidence or a general natural-language interface.

English is the selected M1 voice/text language. English weights do not imply Swedish or code-switched support. Speech recognition is outside DistilBERT and uses the separately qualified local M1 profile above; wake-word detection remains later. The classifier benchmark and its narrow English grammar do not qualify that microphone path.

### Classifier calibration and uncertainty

**H06-04.** Use held-out paraphrases, negation, quoted commands, irrelevant conversation, ambiguous devices, unsupported languages and adversarial inputs. Split by paraphrase/session source to reduce evaluation leakage. Choose per-intent thresholds, top-two margins and OOD rejection from validation evidence, not a universal score such as 0.9. Report false acceptance, abstention, confusion and calibration alongside accuracy. More risk requires explicit confirmation, not simply a higher confidence score.

The English Light experiment uses `priv/intent/corpus-v2.json`, split by template family and target alias. `mix woh.intent.train` checks exact hashes of the pinned Apache-2.0 DistilBERT base, trains a three-label model locally, calibrates on validation examples and writes only aggregate evaluation and native Nx weights to an ignored candidate slot. One five-epoch Elixir run accepted 16/20 allowed held-out phrases with 0/44 false accepts after the exact grammar/authorized-alias gate. Its deterministic character n-gram Naive Bayes baseline and the grammar each accepted 20/20 with 0/44 false accepts. The earlier local Safetensors experiment accepted 17/20 under its own training and baseline recipe; its artifact remains checkable, but its former training program has been replaced. Neither result is model admission or physical qualification. The authored set is small, synthetic and narrower than household speech; a zero count here supplies no field error-rate guarantee. A new independently sourced cohort and runtime/latency tests are needed before admission. Never improve apparent safety by counting the grammar's rejection as model skill.

The training task verifies pinned base hashes before use and writes model/tokenizer hashes, label map, corpus hash, tool versions and aggregate evaluation to a local immutable slot. It records a seed and shuffles batches, but identical weights across machines or repeated EXLA runs are not guaranteed; the manifest identifies the actual bytes evaluated. `mix woh.intent.artifact.check` accepts the historical Safetensors format and native Nx format. It checks slot integrity relative to its manifest, bounds every file and the corpus, rejects duplicate JSON members and symlinks, and verifies the DistilBERT class/label and tokenizer contract before reporting evaluation. A release must separately pin the manifest digest to authenticate installed bytes; the checker does not parse model weights or qualify inference. Neither tool installs a serving runtime or turns a model score into a command.

No intent class may request smoke hush, provisioning, credential export, firmware update or safety-policy changes in the baseline. Such requests are denied independently of classifier output. An optional agent cannot relabel them as ordinary light commands.

### Classifier offline execution and updates

**H06-05.** Models, tokenizer files, native runtimes and compilation artifacts are installed and checked before the offline readiness gate. Startup never downloads them. Missing artifacts return `intent_unavailable`; there is no cloud fallback. Bound input bytes/tokens, batch size, concurrency, memory and job time. Do not assume Apple GPU/ANE support from an Elixir backend name; record measured CPU/accelerator behavior per target.

Model updates install into a new immutable slot, pass the regression corpus and become active atomically. Rollback preserves label-map compatibility. Model version changes never rewrite admitted rules or historical decisions. Optional inference runs in an isolated restart/resource domain and cannot starve device observation.

### Classifier acceptance

H06-T1: actual trained checkpoint recognizes the held-out allowed intents and abstains on declared negatives at least as well as the grammar and compact baseline, on a separately sourced cohort. H06-T2: raw text, private room names and tokens do not leak in telemetry. H06-T3: missing model/WAN loss does not affect typed control. H06-T4: resource saturation leaves runtime guards responsive. H06-T5: backend/quantization changes repeat semantic and calibration tests. H06-T6: every accepted candidate still passes current authorization and invariant checks. The current candidate fails H06-T1; H06-T2–T5 require a deployed runtime and H06-T6 remains a control-path obligation.
