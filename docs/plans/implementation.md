# Implementation plan

## Phase 0 — foundation
Establish specs, catalogue, ADRs, provenance, quality gates and explicit dependencies.

## Phase 1 — deterministic Home domain
Implement observations, desired/observed state, profiles, registry, authorization classes, immutable rule revisions, admission state and typed errors. No AI and no hardware.

## Phase 2 — upstream protocol prerequisites
Use WoTEx generic datagram and Zigbee contracts. Do not implement private UDP/Zigbee stacks in Home.

## Phase 3 — LIFX
Direct local discovery/control, capability query, re-observation and WAN-cut evidence.

## Phase 4 — Aqara
Qualify coordinator, pair/interview the purchased detector, implement the exact profile, prove autonomous alarm independence and recovery. Safety-privileged Actions stay disabled.

## Phase 5 — Hue and Shelly
Local-only profiles and universal Light semantic equivalence.

## Phase 6 — safe automation admission
Implement draft -> static validation -> deterministic composition checks -> immutable admission -> atomic activation. Candidate rules cannot affect hardware before admission.

## Phase 7 — ex_maude qualification
Integrate conflict/safety verification into admission. Keep the previous admitted revision active on counterexample, unverified-required, timeout or verifier failure.

## Phase 8 — optional DistilBERT
Add local intent classification only as an untrusted request adapter. Home is already complete without it.

## Phase 9 — Goatmire prevention PoC
Use an isolated bad draft fixture to demonstrate rejection, then a safe admitted path controlling a real light. Never activate the bad fixture.

## Phase 10 — macOS native shell
Frameshift-inspired Swift/SwiftUI host with narrow semantic IPC.

## Phase 11 — Nerves
Reuse the unchanged Home core and qualify embedded storage/radios/recovery.

## Phase 12 — Matter bridge
Expose selected Things only after upstream Matter server/bridge support exists.

## Phase 13 — manufacturable hub
Conjunct product pack, then optional Conjunct Connect manufacturing workflow.
