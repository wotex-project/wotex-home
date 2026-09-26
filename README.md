# Wotex Home

**Local-first home control built on WoTEx and Elixir/OTP.**

Home keeps device control inside the home. Its target is predictable operation without vendor clouds, unsafe live rule editing or an AI deciding physical truth. The first host is macOS; Nerves is the appliance deployment path for the same core.

This repository contains specifications, qualification plans and an initial pure Elixir core. It is not an implemented or certified controller: there is no durable authority, driver or physical command path yet. Start with the [specification index](docs/specs/WOH-index.md), [architecture](docs/architecture/system.md) and [implementation plan](docs/plans/implementation.md), which records the remaining delivery gates.

Run `mix test` for the pure core. The pinned Elixir/OTP versions are in `.tool-versions`.

The current semantic subset covers exact Light values, read-only smoke report types, capability declarations and boot-scoped observation freshness. It does not yet implement group/scene execution, vendor conversion or physical evidence.

Discovery candidates, interviews and exact profile matching are read-only. A matching fingerprint is a review hint, not enrollment or permission to control a device.

The pure policy check rejects stale authority/revision, missing permissions, unsupported writes and unresolved invariants. It cannot authorize a device by itself: authentication, durable state, final dispatch checks and a driver boundary are still required.

A single-writer SQLite store persists current reports, enrollment, principal grants, a journal and scoped request receipts with WAL and verified `synchronous=FULL`. It rejects duplicate, conflicting and old source sequences and refuses silent source-epoch/profile changes. Local provisioning issues random credentials; request staging derives policy inputs from persisted state. Request outbox rows remain held and cannot be dispatched; IPC authentication, command admission, backups and power-loss qualification remain open.

Draft automation data now has a closed parser, three-valued predicates and a narrow structural screening pass. Passing that screen does not activate a rule: proof correspondence, persisted admission and guarded execution are still required.

## How control works

```text
local UI / CLI / structured requests / admitted automation
                            |
                 one authenticated Home authority
                            |
             capabilities + arbitration + runtime guards
                            |
                durable intent and execution receipt
                            |
                      WoTEx / local devices
```

Candidate automations are checked before activation. Conflicting or insufficiently qualified drafts remain inactive and cannot access the physical command path. Active rules retain runtime guards, causal/action budgets and explicit desired-state ownership. A model result is scoped evidence, not a universal safety guarantee.

The store distinguishes intent, protocol acceptance, reported state and unknown physical outcome. It does not promise exactly-once actuation or atomic multi-device scenes. A second controller is read-only until an explicit fenced transfer.

## Local hardware

Initial targets are the owned older EU LIFX bulbs and the purchased Aqara Smoke Detector without an Aqara hub. A documented Zigbee coordinator is still required for the detector's radio path. Exact Hue and Shelly profiles can follow local-only qualification. Product-family semantics live here; generic datagram, Zigbee, HTTP, MQTT, BLE and Matter mechanics belong in WoTEx.

Smoke integration starts read-only. The detector's standalone detection and siren never depend on Home, the Mac, the coordinator, WAN, inference or verification. Home is not a certified fire-alarm or emergency-lighting system.

## Inference and verification

DistilBERT is a local untrusted input adapter and is required in the full Goatmire prevention demonstration. Ordinary typed control works without it. ex_maude checks declared rule/model questions; a bounded search without a counterexample remains inconclusive, not proof. New proof-required revisions cannot activate without sufficient evidence. Existing admitted rules continue only while their assumptions and runtime guards remain valid. Refpath is an optional client with no special authority.

## Hosts and offline behavior

The native macOS UI is a client of an opt-in background Elixir service. Closing a window does not stop automation; sleep/logout and credential availability still impose real limits. Nerves provides a separately qualified appliance profile. Both must pass offline boot/recovery with artifacts preinstalled; neither requires a cloud controller.

See the [lab catalogue](docs/labs/README.md), [hardware ledger](docs/provenance/hardware-qualification.md) and [procurement plan](docs/plans/procurement.md). Hardware support is per exact device/firmware/capability, not a brand-wide claim.
