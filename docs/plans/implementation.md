# Implementation order and release gates

Version: 0.2.52. This plan sequences target contracts; it does not claim executed delivery.

Spec numbers are identifiers, not implementation order. The [catalogue](../specs/catalogue.yaml) tracks implementation and evidence status separately. A completed pure slice is not an implemented physical controller.

## Current checkpoint and next critical path

Home now has closed semantic values, discovery/review records, restricted-rule screening, a narrow negative ex_maude check, a single-writer SQLite Store, held request receipts, scoped local socket reads/mutations, an exact English light-intent preview, pure LIFX discovery/interview/read/power/colour exchanges, bounded discovery, read and identity-interview paths (read and interview tested against independent scripted loopback peers), an inventoried OTP release and an unsigned macOS development bundle with authenticated health and revision-stable scoped Thing/observation paging. Authenticated in-process enrollment review binds one selected stable device ID to one Thing and operator. Schema version 7 preserves earlier bindings as legacy evidence and supports authenticated re-review with an immutable identity history and pending-work invalidation. A digest-bound LIFX direct-power mapping check remains pending physical qualification; none of these results grants device control. Thing, principal and target-grant revocation, credential rotation and trusted declaration narrowing atomically reject affected held work. The verifier source is pinned inside this repository at `82037e0f3b6494789cc7e634102e23dab53b7fe2`. A pinned LIFX registry artifact can be staged locally and was included in an inventoried development release; it is absent from Git and its distribution remains a separate gate. Read-only held power and colour inspections recheck current authority and reported state, and matching power or complete HSBK reports can atomically close held work with a no-send receipt. Schema version 5 adds a checked execution ledger, turns a synthetic unsettled handoff into a durable unknown outcome on restart, and invalidates queued/claimed work or marks handed-off work unknown in authority-change transactions. Schema version 8 adds a synthetic-fixture-tested direct-power held-to-queued transition and an in-process claim that persists a token without send authority. A trusted in-process qualification writer now requires separately signed physical review and exact current basis, but default reviewer keys are absent and there is no dispatch API. The native bundle has no installed credential broker or qualified background registration. No physical device path is admitted by these pieces.

The WOH.11 evidence boundary now validates sanitized case receipts and exact cohort/environment matching. A fixed LIFX programme and report expose eleven fixture, integration and hardware gaps for one cohort. The report cannot authenticate receipt provenance, produce physical evidence or qualify a Store profile.
An opt-in Ed25519 attestation check now binds supplied reviewer signatures to the fixed programme and receipt bytes. Public-key trust, artifact inspection and source-ID provenance remain separate gates before profile qualification.
An optional private artifact check verifies content-addressed file bytes and exposes only their count; capture origin and physical review remain unverified.
The trusted qualification writer retains the bounded signed claim package outside SQLite. Queue and claim reread its hash and signatures against current pinned reviewer keys; a database-only restore lacks the package and fails closed. Raw captures and physical outcome remain under the reviewer's custody and assertion.

A pure WOH.04 gate now filters rule proposals with safety decisions and bounded operator leases before consuming causal budgets. Schema version 10 supplies authenticated, journaled, current-boot override leases for ordinary Light power through the Store. Live in-process lease calls now use the Store's own monotonic clock. An authenticated read-only socket route exposes current granted leases with Store-timed remaining life. The native read view now displays those leases for its catalogue targets. Schema version 11 now persists bounded override-operation receipts and the socket exposes idempotent issue/revoke/status routes. The native window now has 15-minute issue, status and revoke controls for authenticated operators, with operation IDs kept for uncertain-response lookup. No active automation consumes these leases. Authority changes clear affected leases. The gate is not yet fed by an admitted runtime or current invariant records, and an issued lease does not change queued work.
The restricted one-rule qualification now checks pure gate/sandbox precedence and blocked-root preservation across finite safety and lease states, binding the gate and lease modules into its runtime digest. This is proposal filtering evidence only; its decisions are not yet wired into a dispatch guard. A real handoff remains disabled until current dynamic invariant provenance where needed, authenticated override lookup, transport ownership and the durable handoff marker are joined at the last authority check.
For the separately qualified one-capability LIFX direct-power profile, the claim guard now derives a static allow decision from the exact integrated-Light declaration, with empty extensions and constraints; any wider shape returns unknown. The physical review runtime digest binds this module. This narrow static scope does not supply dynamic safety facts or enable a handoff.

Schema version 9 now persists a rule-generation fence. A trusted empty-policy advance rejects unsent old work and records handed-off work as unknown; queued direct power carries the current generation through claim. Rule content, active pointer, proof-qualified activation and dispatch remain unimplemented.
Principal-scoped request event paging now accepts every closed execution disposition, so queued/claimed transitions and crash-recovered unknown outcomes remain readable across restart. It still does not supply transport handoff or physical-outcome evidence.
Authenticated exact enrollment and re-review retries now return their original current binding decision revisions after a lost reply, including across restart. The retry must match the authority event type as well as the review content; a superseded reference or changed declaration conflicts. The read-only enrollment-status socket remains the external recovery path because commit is still in-process only.

The release build now has a component and local license-input inventory, a file-level SPDX 2.3 JSON document and a file-hash inventory. Missing license inputs, `NOASSERTION` license conclusions and unsigned provenance remain explicit release gates.
Exact versioned Erlang/OTP and Elixir source license inputs are now pinned for the current release toolchain. The component inventory refuses changed input bytes or new runtime versions without remapping. This does not decide the Home project license or close the remaining native and dependency inputs.
The two Hex packages with no standalone license file now contribute pinned package metadata and README notices, labelled `notice_only`. The generated release wrapper carries pinned OTP and Elixir source inputs; the Home-authored CLI is mapped separately to Home. Home components still lack a project license input and bundled Maude remains notice-only. Every SPDX conclusion remains `NOASSERTION` pending a proper release review.
Encrypted database-backup inspection now lists its external qualification claim-package references and states that reviewer keys, raw qualification artifacts and device credential/counter continuity are outside the archive. Backup inspection also counts retained operator leases and states that a restored Store cannot reactivate them. Staged restoration remains quarantined until fenced transfer is built.
The macOS development assembly emits a file-level SPDX document for the full bundle, inventories the outer app and verifies its embedded OTP inventory; signing, notarization and native license closure remain release gates.
The local OTP release now disables distributed Erlang through its packaged environment script. The release smoke checks that no Erlang node is alive; Home clients continue to use the private Unix socket.
The smoke now waits for the socket and database to reach their final private modes and for a complete framed unauthorized health reply before declaring startup ready. Its bounded window is 60 seconds after a parallel native-host run exceeded the former development-host startup limit; timeout diagnostics report endpoint modes.
The Raspberry Pi 4 Nerves development image cross-builds against the current Home source. A bounded image check now records the ARM ELF closure and absence of foreign Maude binaries or packaged node flags; board boot, update validation and power-cut evidence remain open.
The rejected DistilBERT candidate's local artifact checker now bounds every input and rejects duplicate manifest members or swapped model labels even if its self-contained hashes are rewritten. The candidate remains rejected; a release-pinned manifest, independent evaluation and bounded serving path are still required.

The native window now has a scoped read-only lookup for a durable operation receipt, including explicit unknown outcomes, and can stage a typed Light power request with a control credential. It keeps the operation ID for status lookup. Staging does not establish a physical effect, and the default diagnostic credential cannot submit control.
The same operation view can cancel held or still-queued work under its original ID and use status to resolve an uncertain reply. Claimed or handed-off work remains non-recallable.

The next control path is: pin a committed WoTEx UDP revision whose endpoints represent the selected IPv4 prefix; run a Home transport adapter against an independent scripted peer; review the exact LIFX device/profile cohort; complete the authenticated enrollment selection on the actual device; add qualified handoff and readback transitions, extending the existing abandoned-claim recovery to fence a real transport owner; then perform the selected real-bulb read/write/readback and WAN-cut cases. A packet send or LIFX ACK cannot fill the observed-state or physical-effect gate. The committed ex_maude receipt API can reject narrow Boolean conflicts, and its newer generic bounded-search API improves evidence collection without becoming a positive Home proof. A single explicit Boolean Light rule now has a digest-bound proposal correspondence basis exposed on authenticated draft review while its decision remains pending; durable activation, current invariants and dispatch guard evidence remain missing before any rule can become active.
The enrollment IPC seam must first bind the operator's selection to a host-held bounded capture and packaged profile; the present Store call trusts its in-process evidence caller. Scoped review-reference status and exact retry handling now exist, but no socket commit route is exposed. A second read-only `en0` LIFX lab window on the development Mac returned zero candidates, and no USB serial coordinator appeared, so these checks cannot be recorded as physical qualification.
Current initial enrollment and re-review commits resolve exact same-operator, same-content retries to their original decision revisions while the respective binding remains current. Changed or superseded input conflicts. A read-only `enrollment_status` socket lookup scopes review-reference status to its operator across restart. Host-held capture provenance still precedes an IPC commit route.
The native window now looks up that scoped review reference and labels current, superseded and revoked bindings without treating any of them as device qualification.
The release now includes a headless CLI for health, redacted support preview/private export, paged scoped catalogue/snapshot/history/event reads, request receipt, enrollment-review status, one-target override status and bounded draft-rule review, plus held request submission/cancellation and override issue/status/revoke. It reads a canonical credential from an explicit 0600 file and submitted mutation or draft rules from separate private files, then uses the same private socket client. That client checks the private endpoint and connected peer before sending credentials. Paged reads carry explicit returned watermarks/cursors between invocations. A draft review stays pending and cannot activate a rule. Uncertain mutation replies require status lookup under the original operation ID. There is no CLI provisioning, qualification, enrollment commit or device-send command.

In parallel, the macOS path needs signed bundle contents, `SMAppService` approval and lifecycle tests, installed peer-UID IPC validation and a Keychain broker. Backup verification and quarantined offline staging exist, while activation of a restored authority and radio identity/counter continuity remain a separate transfer gate. WoTEx Zigbee, Matter and Conjunct work in their own repositories must be pinned by exact committed revisions before Home claims those paths. DistilBERT requires a licensed trained checkpoint and held-out evaluation before the full Goatmire profile can run.

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

Package an opt-in per-user background controller, authenticated local IPC and a narrow native credential broker. Build the SwiftUI shell against semantic snapshots/receipts. Test window close, service disable, sleep/wake, logout, Keychain and USB lifecycle under a fresh account. Record the actual host availability limits.

## 7. Required local demonstration profile

The first licensed, locally trained DistilBERT Light-intent candidate has pinned base hashes, tokenizer/labels and a disjoint authored corpus. It is rejected: with the exact grammar and alias gate it accepted 17/20 held-out allowed phrases, while the compact baseline and grammar each accepted 20/20; all had 0/44 false accepts on this small synthetic set. Next obtain an independently sourced cohort, improve and recalibrate the model without weakening the command gate, install a bounded offline inference runtime and pin the artifact manifest in a release. Preinstall all artifacts. The Goatmire run rejects an isolated bad draft with zero physical effects, then executes a legitimately admitted light request. Typed control, verifier failure and RF fallback remain honest alternate cases.

## 8. Release-quality recovery and Nerves parity

Finish update compatibility, encrypted backup/recovery, redacted support export, resource limits and seven-day stability tests. Move the same Home semantics to a selected Nerves target. Qualify real power loss, firmware validation/rollback, radio continuity and optional native model capacity. Do not weaken the specification because an ARM binary or hardware test is missing.

## 9. Optional export and manufacture

Deliver WoTEx's separate Matter server/bridge profile, then qualify exact exported types and independent ecosystem controllers. Neither that bridge nor Siri/Google becomes the home authority. A manufacturable controller follows measured resource/RF needs and Conjunct composition evidence; Connect supports procurement, not runtime control.

## Do not build in the baseline

No active-active actuator writers, safety-state CRDT, globally exposed Erlang distribution, mandatory cloud/broker/database, custom Zigbee PHY, automatic smoke firmware updates, dynamic untrusted profile code, AI authorization, invented exactly-once actuation or a stage fixture with live conflicting rules. These exclusions are design boundaries, not missing shortcuts.

## Open gates tracked by the contracts

- WOH.03/WOH.11: pin reusable WoTEx datagram and Zigbee revisions; record the detector's exact SKU/fingerprint, selected coordinator firmware and manufacturer's safe-test procedure before claiming a local detector cohort. A ZNP backend is a candidate, not a hardware endorsement.
- WOH.04/WOH.07: deliver a positive restricted-rule basis and compiler correspondence; composed rules still require a separately justified proof profile. A bounded no-finding result cannot admit either profile by itself.
- WOH.05/WOH.08/WOH.15: qualify device-specific TLS/credential behavior, installed macOS identity and permissions, local IPC authentication and old-writer isolation on the actual host.
- WOH.06/WOH.09/WOH.10/WOH.12: replace the rejected local intent candidate with a separately evaluated checkpoint and bounded offline serving path; take the cross-built Raspberry Pi 4 development image through board boot, rollback, storage power-cut, radio and native-worker qualification; qualify supported languages, an ARM Maude binary, exact Matter revisions/server role and manufacturing/conformity evidence separately.
- WOH.14/WOH.16: test SQLite durability on target storage, command crash boundaries, encrypted recovery and radio counter continuity. Unit tests cannot establish power-loss survival or cross-host fencing.

Each release reports unresolved cases with their required environment and exact cohort. Documentation or a simulator never marks a physical, field or certification case passed.
