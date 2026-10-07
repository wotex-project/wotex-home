# Implementation order and release gates

Version: 0.2.143. This plan separates executable slices from external acceptance gates.

Spec numbers are identifiers, not implementation order. The [catalogue](../specs/catalogue.yaml) tracks implementation and evidence status separately. A completed pure slice is not an implemented physical controller.

## Portable profile and optional helper build track

The [portable profile plan](portable-profile-admission.md) owns the consolidated
production sequence: closed data import, explicit local approval, Store-owned
selection/retention/recovery and actual host/device qualification. WOH.18 and
ADR 0010 define that planned path; existing rule source/compiler remains the
automation boundary. Ordinary data profiles require no Wasm engine.

Portable data phase P1 now implements bounded inert import, fixed direct-power
binding/projection, private synchronized custody, finite quotas and monitored
leases. Independent serialized fixtures, adversarial parser/custody cases and
publication restart checks pass. Schema 19 now adds separate management permission,
maintenance-gated local digest approval/revocation, immutable scoped history and
encrypted dependency summaries with historical schema compatibility. No external
selection or public import route is active; P2/P3 must complete selection and
every current guard/pin before activation.
Trusted selection preparation now binds the authenticated snapshot, exact
approved artifact/runtime and fresh one-use capture to a bounded canonical
proposal and a semantic diff. It rejects stale pins, ambiguous identities and
declaration widening without changing a Thing or granting control.
Store-controlled inert collection now preserves all retained approval metadata
and monitored leases while recovering finite staging quota. Active selection,
owning-domain pins and actual host wiring remain the next delivery.
Selection proposals now have bounded, operator-scoped transient custody,
original-capture expiry, exact pending retry and one-use checkout with monitored
lease retention. Active transitions and current guard/recovery pins remain open.

The [component plan](component-extensions.md) owns optional WIT helpers. Its
implemented import-free previews have no Store/device effect; [historical
validation](component-extensions-validation.md) records independent authors and
failure retirement. Source review found cancellation-slot reuse can overlap
retiring native children; native memory/OS containment is also open. A production
helper needs a named mapping benefit plus those gates, then the shared lifecycle
and physical evidence. The direct-power critical path below retains current
compiled profiles, the full runtime basis and default-disabled dispatch.

## Current checkpoint and next critical path

Home is one Mix/OTP application. Namespace boundaries are not independently
released packages. Unix-socket, CLI and trusted setup adapters enter through
`WotexHome.Authority`; only the Store owns SQLite, its host lock, transactions,
boot clocks and live claimant monitors. Stateless Store domains own canonical
receipts, enrollment/principals, observations/refresh, qualification, overrides,
execution, read projections and shared schema/integrity/journal primitives.
Device sessions never receive a Store connection or bearer credential.

Provisioning/storage and command policy share one closed permission vocabulary.
Combined qualification, enrollment, review and control permissions remain
independent; qualification alone never grants command authority. Regression
coverage includes the guarded queued/claimed/handoff path, not just provisioning.

The executable direct-power path is now one coherent sequence:

1. A host-owned selected-interface capture discovers and interviews an exact
   LIFX identity. The immutable packaged product-27 and product-22 power profiles can be
   reviewed/enrolled by an authenticated operator; enrollment is not control
   qualification. Enrolled refresh repeats identity and commit-time authority.
2. Submission stores a scoped held receipt. Exact retries, cancellation and
   status preserve the original operation identity. The public socket cannot
   qualify a profile, provision a credential or execute a raw device command.
3. Trusted internal admission and claim require current grants, epoch,
   declaration/resource/generation, fresh reports and the exact signed profile
   claim package. Its compiled-code binding includes every packaged Home/UDP
   module; a structural rewrite requires a new review. Direct-power v1 fixes
   duration to zero before claim. The same supervised worker repeats guards at
   durable handoff, owns its transport and sends only after the marker commits.
4. ACK remains protocol acceptance. Correlated readback and observation retention
   settle observed/contradicted atomically; uncertainty, worker death and restart
   retain unknown. Explicit reconciliation requires an exact newer fresh
   production report, current signed basis and no live old worker. It never
   resends or claims that a matching state proves command causation.

New handoff markers now include the single Store's own boot/elapsed-time pair.
Integrity and encrypted backup checks preserve it through settlement and
restart, reject inconsistent or backwards timing and keep legacy rows untimed.
The direct-power path now repeats a closed Home attempt-rate/spacing policy at
queue, claim and handoff, reading this history and current Store time in the
same transaction. Old or untimed history requires a complete new-boot window.
No-send and blocked work consume no attempt; uncertain/terminal handoffs do.
This is not physical dwell or an admitted rule runtime.

Explicit requests now also have durable single-effect roots, keyed by their
immutable principal/epoch/operation identity. One queue acceptance reserves the
depth-one intent in that transaction; claim and handoff recheck its original
queue journal link. Cancellation, revocation, fencing, reconciliation and
restart do not refund it. New rejected/held/no-send work spends no effect.
Schema 14 retains roots separately from disposable execution rows; legacy
migration marks unknown provenance rather than inventing it, and missing or
ambiguous old queue provenance cannot authorize execution. These are internal
operator-request budgets, not rule-event roots or proof of physical causation.

The deterministic validation entry is `elixir bin/test.exs --socket-free
--firmware-host`, using already-built locked test dependencies. It compiles fresh
source, rejects warnings, checks all catalogue identities and reports excluded
OS tests. `elixir bin/build.exs --dependency-env test` also builds a fresh
unsigned production Home release against that explicitly selected dependency
cache, checks packaged Store/CLI/verifier startup and verifies its inventories.
It does not run the full host/socket smoke. Full CI still runs real socket tests. Swift app/agent and client
fixtures compile for arm64 macOS 15 under Swift 6 warning rejection. These are
source/logic/build checks, not installed-host or hardware qualification.

The native rule policy panel now reads current status, suspends with a revision
check and resolves original admission/activation operations after an uncertain
reply. Independent Swift socket fixtures and live Swift/CLI parity cover the
closed scalar boundary; activation counts are historical barrier results.
Native source editing, admission and invocation are still pending. macOS CI
now includes the health/rule fixtures and live parity task.

Existing additional slices remain supported: scoped draft-rule negative checks,
immutable recorded candidate outcomes and a proposal-only restricted correspondence basis; pure colour planning and
no-send settlement; grammar/local intent proposals; read-only Shelly frames and
interview; bounded explicitly verified Hue HTTPS resource reads; optional Matter export/proposal shapes; encrypted quarantined backup;
macOS/Nerves development packaging, inventories and read-only board probes.
None gains production authority from this structural rewrite.

The closed Home compiler now binds canonical source and complete IR identities;
the actual sandbox and explicitly negative native projection consume its entries.
Three-valued truth tables, typed thresholds, event origins, 1,620 finite state
cases and a mixed sequential trace compare the machine against independent
reference decisions. The v3 proposal correspondence basis adds these compiler/
source/IR commitments to the complete packaged Home BEAM manifest through the
same internal artifact reader used by the separate Home/UDP profile basis.
Closed receipts can be checked against current inputs and freshly repeated
finite correspondence; changed metadata/code or retained old module versions
fail closed. Native/OS identities and physical qualification remain separate obligations;
the schema 17 subset below supplies durable admission and activation. Named negative-model
omissions remain unproved; a pending proposal result is not upgraded to admission.

Schema 15 now stamps every newly accepted report/current projection with the
Store's own receipt epoch/time alongside unchanged adapter metadata. Replay,
rollback and restart cannot renew that timestamp. Authenticated bounded fact
reads verify the exact journal/declaration/grant basis and keep untimed, expired,
old-boot, future and lab reports unknown. Startup and encrypted staging validate
the retained clock/content links. This is accepted receipt age and preview input,
not source authentication, dynamic invariant policy or rule admission. Existing
qualified direct-power report guards remain separate.

Schema 16 now retains authenticated reported constraints and rechecks them at queue,
claim and handoff. Replacement uses revision CAS and invalidates pending work;
expired/restarted facts and revoked policy authors remain unknown. Integration
cases cover each execution boundary, immutable retry, journal tampering and
quarantined encrypted recovery. Orderly Store shutdown explicitly closes both
SQLite handles, including supervisor shutdown. These are software checks,
not physical safety qualification.

Schema 17 now supplies durable admission, generation activation/suspension and
authenticated explicit invocation for one unconditional ordinary-Light Boolean
effect. Canonical artifacts bind the independent finite correspondence basis,
source-bound IR, exact declarations, current invariant policy and complete Home
runtime. Activation atomically invalidates old work and discloses handed-off
uncertainty; invocation creates held requests with immutable rule origins. All
execution boundaries repeat current rule, invariant and override guards. This
subset has no autonomous scheduler, reported-edge execution or composed proof.
Current status, successor activation, invocation and execution also validate the
complete original activation receipt, epoch and ordered generation journal.
Corruption disables writes without a new receipt, causal reservation or handoff;
live regression cases cover invocation, queue, claim and handoff.

Schema 18 now provides a persistent authenticated host-maintenance barrier.
Begin atomically suspends rules, rejects unsent work and preserves handed-off
uncertainty; new ordinary requests and effect transitions remain blocked after
restart. Original receipts, observations and consistent encrypted backups stay
available. Explicit end checks the original begin identity and current revision
and leaves the active rule pointer empty. Real socket/CLI, rollback, restart,
corruption and all four pending phases are exercised. Artifact installation,
compatible rollback and board recovery remain separate gates.

The native maintenance panel now shares the four authenticated CLI/API routes.
It keeps current status separate from historical receipts and retains an
uncertain operation's exact inputs/original credential for lookup or retry.
Thirty-two independent peer cases and live CLI parity cover begin/end,
invalidated held work, blocked new staging and immutable historical counts.
New changes require a refreshed status and resolved prior operation. The panel
does not install an artifact or activate a restore.

At commit `6df29b1`, a fresh unsigned release passed packaged schema 18
maintenance/retry/restart/backup checks and the separate real private-socket
startup/shutdown smoke. Its macOS app assembled with 24 checked Mach-O files.
The new Raspberry Pi development image also cross-built and passed the image
checker (29 AArch64 ELF files, 1,431 release files, 43,060,888 firmware bytes).
These are local package checks; signed installation and a physical board are
still unqualified. A development-window check corrected registration labels
that overstated what the service status established.

The next critical gate is a real reviewed LIFX cohort and independent read/write/
readback, WAN-cut and crash evidence on the owned host. Normal dispatch remains
disabled until that gate is supplied. Broader rule admission/scheduling,
physical invariant evidence and qualified colour dispatch,
additional device mappings, installed credential custody and fenced restore
remain unfinished contracts. Signed release, board power-cut/radio, Matter
ecosystem and manufacturing evidence require their actual environments.
Do not mark those contracts implemented because deterministic tests pass.

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

Package an opt-in per-user background controller, authenticated local IPC and a narrow native credential broker. Build the SwiftUI shell against semantic snapshots/receipts. Compose inspect, compare, request-change, monitor and draft-rule tasks at the H08-08 compact, medium and expanded content edges while preserving enrolled Thing, observation-quality, authority, operation and physical-outcome meaning. Test window close, service disable, sleep/wake, logout, Keychain and USB lifecycle under a fresh account. Record the actual host availability limits.

## 7. Required local demonstration profile

The Elixir `mix woh.intent.train` task now checks the pinned base and authored split, trains a native Nx DistilBERT candidate and compares it with exact grammar and a compact character n-gram baseline. One five-epoch run accepted 16/20 held-out allowed phrases after the grammar/alias gate, while both baselines accepted 20/20; all had 0/44 false accepts on this small synthetic set. The earlier Safetensors candidate accepted 17/20 under a different recipe. Both remain rejected. Next obtain an independently sourced cohort, improve and recalibrate the model without weakening the command gate, install a bounded offline inference runtime and pin the artifact manifest in a release. Preinstall all artifacts. The Goatmire run rejects an isolated bad draft with zero physical effects, then executes a legitimately admitted light request. Typed control, verifier failure and RF fallback remain honest alternate cases.

## 8. Release-quality recovery and Nerves parity

Finish update compatibility, encrypted backup/recovery, redacted support export, resource limits and seven-day stability tests. Move the same Home semantics to a selected Nerves target. Qualify real power loss, firmware validation/rollback, radio continuity and optional native model capacity. Do not weaken the specification because an ARM binary or hardware test is missing.

## 9. Optional export and manufacture

Deliver WoTEx's separate Matter server/bridge profile, then qualify exact exported types and independent ecosystem controllers. Neither that bridge nor Siri/Google becomes the home authority. A manufacturable controller follows measured resource/RF needs and Conjunct composition evidence; Connect supports procurement, not runtime control.

## Do not build in the baseline

No active-active actuator writers, safety-state CRDT, globally exposed Erlang distribution, mandatory cloud/broker/database, custom Zigbee PHY, automatic smoke firmware updates, dynamic untrusted profile code, AI authorization, invented exactly-once actuation or a stage fixture with live conflicting rules. These exclusions are design boundaries, not missing shortcuts.

## Open gates tracked by the contracts

- WOH.03/WOH.11: retain the exact UDP owner pin and qualify a Zigbee revision; record each physical cohort, the detector's exact SKU/fingerprint, selected coordinator firmware and manufacturer's safe-test procedure before claiming a local detector cohort. A ZNP backend is a candidate, not a hardware endorsement.
- WOH.04/WOH.07: expand beyond the schema 17 explicit single-effect admission argument only with new correspondence and guard evidence; composed rules still require a separately justified proof profile. A bounded no-finding result cannot admit either profile by itself.
- WOH.05/WOH.08/WOH.15: qualify device-specific TLS/credential behavior, installed macOS identity and permissions, local IPC authentication and old-writer isolation on the actual host.
- WOH.06/WOH.09/WOH.10/WOH.12: replace the rejected local intent candidate with a separately evaluated checkpoint and bounded offline serving path; take the cross-built Raspberry Pi 4 development image through board boot, rollback, storage power-cut, radio and native-worker qualification; qualify supported languages, an ARM Maude binary, exact Matter revisions/server role and manufacturing/conformity evidence separately.
- WOH.14/WOH.16: test SQLite durability on target storage, command crash boundaries, encrypted recovery and radio counter continuity. Unit tests cannot establish power-loss survival or cross-host fencing.

Each release reports unresolved cases with their required environment and exact cohort. Documentation or a simulator never marks a physical, field or certification case passed.

Schema 20 now retains qualification snapshots and complete compatible profile
replacement/history/pin barriers. Trusted Store selection consumes exact held
one-use reviews, repeats bytes/runtime/CAS/deadline guards, preserves original
receipt/claim identity, revokes current evidence and forbids narrowing/rereview
bypass. Target/artifact revocation is possible with missing bytes; reapproval
cannot reactivate history. Current request/rule/qualification/observation/effect
use repeats selected pins and call-local custody/runtime checks. Startup and
encrypted recovery reject damaged selection and owning-domain correspondence.

Next portable-profile work: authored initial-enrollment/changed-firmware review
encodings, their transaction/history cases, trusted production host custody and
review supervision, closed API/CLI/native operator flows and actual fenced byte
transfer. Physical qualification and installed-host storage/containment gates
remain open. The broader software and hardware release obligations above still
apply; this slice does not complete every product contract.
