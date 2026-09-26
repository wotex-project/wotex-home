# Implementation order and release gates

Version: 0.2.1. This plan sequences target contracts; it does not claim executed delivery.

The [build readiness review](../research/2026-09-26-build-readiness.md) records the dependency order, concrete interface decisions and external gates. Spec numbers are identifiers, not implementation order. A completed pure slice is not an implemented physical controller.

## 0. Establish the executable semantic boundary

Bootstrap the Mix project with pinned Elixir/OTP versions. Implement WOH.00/WOH.01 as pure, bounded data and validation: stable opaque IDs, exact capability operations and units, typed observations, explicit unknown/stale states and a closed command shape. Add read-only WOH.02 candidate/profile matching without giving discovery any command authority. Keep all runtime status claims at `planned` until their acceptance cases are run in the required environment.

Exit: invalid/unknown fields and units are rejected, unsupported capabilities never appear as executable operations, and discovery cannot mutate a device. This slice has no driver credentials or physical command path.

## 1. Close the proof and authority model first

Implement WOH.05 policy, WOH.14 durable receipts/outbox and WOH.15 headless authority before attaching physical mutation. The authority epoch changes on fenced ownership transfer; a separate active-rule generation changes on activation. Then implement the closed Home IR, effect domains, three-valued predicates and admission state machine. Specify the restricted-rule proof basis and reject unsupported composed semantics. Tests must kill incorrect priority, unknown-to-false, omitted guards, stale revision and duplicated-effect mutations.

Exit: a rejected candidate has no driver credentials/calls; activation races and crash points are executable tests. No AI or live hardware is needed.

## 2. Build one complete local device path

Implement the reusable WoTEx datagram owner and a Home LIFX profile. Use a scripted independent peer first, then the owned old bulb. Read identity/capabilities, enroll, issue an absolute state request and re-observe it. Preserve unknown outcomes and conflicting newer requests. Pass WAN-cut, address churn and restart cases.

Do not block this vertical slice on every planned radio or a native UI. Do not call an ad-hoc raw UDP script the completed Home product.

## 3. Qualify the purchased detector's local path

Select one documented Zigbee NCP family after exact coordinator review. Implement generic serial/NCP and ZDO/ZCL contracts upstream. Interview and qualify the purchased detector through a read-only Home profile. Prove standalone alarm independence and network report behavior separately. Keep OTA, hush and linkage changes disabled. Follow with USB/restart and secure backup/counter continuity tests.

Exit: exact SKU/firmware/coordinator cohort, not a brand claim or pairing-only success.

## 4. Add the real prevention service

Integrate ex_maude for declared conflict and reachability questions. Preserve its current inconclusive semantics. Add generic receipts upstream without claiming a positive verifier exists. A Home compiler/model profile must cover priority, unknown facts, effects and environment assumptions before composed rules depend on it. Keep unsupported proof-required revisions inactive.

Exit: negative draft evidence, bounded runtime prevention, atomic activation barrier and current-state guards. Existing admitted control survives verifier loss only under still-valid assumptions.

## 5. Independent devices and neutral consumers

Add exact local Hue and Shelly profiles. Run unchanged semantic Light operations through different protocols with declared conversion tolerances. Add headless API/CLI, cursor/snapshot consistency, scoped auth, group partial outcomes and external-controller arbitration.

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
