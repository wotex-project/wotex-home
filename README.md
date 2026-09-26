# Wotex Home

**Local-first home control built on WoTEx and Elixir/OTP.**

Home keeps device control inside the home. Its target is predictable operation without vendor clouds, unsafe live rule editing or an AI deciding physical truth. The first host is macOS; Nerves is the appliance deployment path for the same core.

This repository contains specifications and qualification plans, not an implemented or certified controller. Start with the [specification index](docs/specs/WOH-index.md), [architecture](docs/architecture/system.md) and [implementation plan](docs/plans/implementation.md). The [source review](docs/research/2026-09-26-spec-review.md) records decisions, actual upstream limitations and remaining work.

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
