# Implementation order and release gates

Version: 0.2.8. This plan sequences target contracts; it does not claim executed delivery.

Spec numbers are identifiers, not implementation order. The [catalogue](../specs/catalogue.yaml) tracks implementation and evidence status separately. A completed pure slice is not an implemented physical controller.

## Current checkpoint and next critical path

Home now has closed semantic values, discovery/review records, restricted-rule screening, a narrow negative ex_maude check, a single-writer SQLite Store, held request receipts, scoped local socket reads/mutations, an exact English light-intent preview, pure LIFX discovery/interview/read/power/colour exchanges, bounded discovery, read and identity-interview paths (read and interview tested against independent scripted loopback peers), an inventoried OTP release and an unsigned macOS development bundle with authenticated health and revision-stable scoped Thing/observation paging. Authenticated in-process enrollment review binds one selected stable device ID to one Thing and operator. Schema version 7 preserves earlier bindings as legacy evidence and supports authenticated re-review with an immutable identity history and pending-work invalidation. A digest-bound LIFX direct-power mapping check remains pending physical qualification; none of these results grants device control. Thing, principal and target-grant revocation, credential rotation and trusted declaration narrowing atomically reject affected held work. The verifier source is pinned inside this repository at `82037e0f3b6494789cc7e634102e23dab53b7fe2`. A pinned LIFX registry artifact can be staged locally and was included in an inventoried development release; it is absent from Git and its distribution remains a separate gate. Read-only held power and colour inspections recheck current authority and reported state, and matching power or complete HSBK reports can atomically close held work with a no-send receipt. Schema version 5 adds a checked execution ledger, turns a synthetic unsettled handoff into a durable unknown outcome on restart, and invalidates queued/claimed work or marks handed-off work unknown in authority-change transactions. Schema version 8 adds a synthetic-fixture-tested direct-power held-to-queued transition and an in-process claim that persists a token without send authority. There is no production qualification writer or dispatch API. The native bundle has no installed credential broker or qualified background registration. No physical device path is admitted by these pieces.

The WOH.11 evidence boundary now validates sanitized case receipts and exact cohort/environment matching. It can identify missing or stale physical evidence, but it cannot produce such evidence or qualify a Store profile by itself.

A pure WOH.04 gate now filters rule proposals with safety decisions and bounded operator leases before consuming causal budgets. It is not yet fed by durable, authenticated overrides or current invariant records.

The next control path is: pin a committed WoTEx UDP revision whose endpoints represent the selected IPv4 prefix; run a Home transport adapter against an independent scripted peer; review the exact LIFX device/profile cohort; complete the authenticated enrollment selection on the actual device; add qualified handoff and readback transitions, extending the existing abandoned-claim recovery to fence a real transport owner; then perform the selected real-bulb read/write/readback and WAN-cut cases. A packet send or LIFX ACK cannot fill the observed-state or physical-effect gate. The committed ex_maude receipt API can reject narrow Boolean conflicts, and its newer generic bounded-search API improves evidence collection without becoming a positive Home proof. A single explicit Boolean Light rule now has a digest-bound proposal correspondence basis exposed on authenticated draft review while its decision remains pending; durable activation, current invariants and dispatch guard evidence remain missing before any rule can become active.

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

Train or obtain a licensed, evaluated DistilBERT intent checkpoint with pinned tokenizer/labels and held-out evidence. Compare it with a compact baseline; define abstention and supported languages. Preinstall all artifacts. The Goatmire run rejects an isolated bad draft with zero physical effects, then executes a legitimately admitted light request. Typed control, verifier failure and RF fallback remain honest alternate cases.

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
- WOH.06/WOH.09/WOH.10/WOH.12: select and evaluate a trained local intent checkpoint and supported languages, Nerves target/native binaries, exact Matter revisions/server role and manufacturing/conformity evidence separately.
- WOH.14/WOH.16: test SQLite durability on target storage, command crash boundaries, encrypted recovery and radio counter continuity. Unit tests cannot establish power-loss survival or cross-host fencing.

Each release reports unresolved cases with their required environment and exact cohort. Documentation or a simulator never marks a physical, field or certification case passed.
