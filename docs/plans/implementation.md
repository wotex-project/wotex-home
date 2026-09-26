# Implementation plan

## Phase 0 — specification and repository foundation

- establish WOH catalogue, ADRs, provenance and labs;
- pin WoTEx/ex_maude development revisions;
- create Mix project and quality gates following WoTEx conventions;
- no network work at application start.

## Phase 1 — pure Home domain

Implement Thing semantic helpers, observations, desired/observed state, profiles, registry values, rule values, ProposedTransition and typed errors. No hardware.

## Phase 2 — upstream prerequisites

Coordinate WoTEx generic datagram transport and Zigbee contracts. Do not implement private UDP/Zigbee stacks inside Home.

## Phase 3 — old LIFX physical lane

Broadcast discovery, version/capability query, Light materialisation, power/brightness/colour/temperature transitions and re-observation. WAN-cut evidence required.

## Phase 4 — Aqara Zigbee physical lane

Purchase/qualify coordinator, pair purchased detector, interview exact fingerprint, capture clusters/reports, implement exact profile, prove autonomous alarm independence, WAN-cut and restart recovery. Keep silence disabled.

## Phase 5 — Hue and Shelly

Local Hue Bridge and exact Shelly profiles. Run universal Light semantic equivalence.

## Phase 6 — automation and ex_maude

Rule revisions, deterministic planner, conflict detection and bounded safety verification. Preserve counterexample versus unverified semantics.

## Phase 7 — DistilBERT

Local finite intent classifier, deterministic threshold/normalization and no cloud fallback.

## Phase 8 — Goatmire PoC

Real light, deliberate rule composition conflict, counterexample/unverified handling and safe simulated smoke invariant.

## Phase 9 — macOS native shell

Frameshift-style Swift/SwiftUI host with Keychain, Bonjour/local permissions and narrow IPC.

## Phase 10 — Nerves

Move unchanged Home core to embedded host; qualify storage, radio, recovery, Maude ARM packaging and local inference.

## Phase 11 — Matter bridge

Only after upstream Matter exposed bridge/server role exists, expose selected Home Things to external ecosystems.

## Phase 12 — manufacturable hub

Conjunct product pack, then optional Conjunct Connect supplier/manufacturing flow.
