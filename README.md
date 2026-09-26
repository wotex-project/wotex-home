# Wotex Home

**Local-first home control built on WoTEx and Elixir/OTP.**

Home keeps device control inside the home. Its target is predictable operation without vendor clouds, unsafe live rule editing or an AI deciding physical truth. The first host is macOS; Nerves is the appliance deployment path for the same core.

This repository contains specifications, qualification plans and an emerging Elixir core. It is not an implemented or certified physical controller: there is no guarded driver or physical command path yet. Start with the [specification index](docs/specs/WOH-index.md), [architecture](docs/architecture/system.md) and [implementation plan](docs/plans/implementation.md), which records the remaining delivery gates.

Run `mix test` for the current core. The pinned Elixir/OTP versions are in `.tool-versions`.

The current semantic subset covers exact Light values, read-only smoke report types, capability declarations, boot-scoped observation freshness and closed scene plans with per-member reports. It does not yet implement group/scene execution, vendor conversion or physical evidence.

Discovery candidates, interviews and exact profile matching are read-only. A matching fingerprint is a review hint, not enrollment or permission to control a device.

An explicit enrollment review now checks the candidate, interview, profile and proposed Thing together. It remains pending authenticated commit and creates no device authority.

The pure policy check rejects stale authority/revision, missing permissions, unsupported writes and unresolved invariants. It cannot authorize a device by itself: authentication, durable state, final dispatch checks and a driver boundary are still required.

A same-host SQLite lock gates the single-writer store. It persists current reports, enrollment, principal grants, a journal and scoped request receipts with WAL and verified `synchronous=FULL`. It rejects duplicate, conflicting and old source sequences and refuses silent source-epoch/profile changes. Local provisioning issues random credentials; request staging derives policy inputs from persisted state and caps held work per principal and globally. An opt-in private Unix socket accepts credential-authenticated health, submission and status requests. Request outbox rows remain held and cannot be dispatched; installed IPC identity, command admission, cross-host fencing, restore and power-loss qualification remain open.

Startup checks the held receipt/outbox relationship. The local socket exposes redacted health and scoped, revision-stable pages of current observations, enrolled Thing declarations and observation history. An intervening write requires a new page sequence; no event stream exists yet. Held work is never reported as delivered. A trusted in-process call can export a bounded encrypted SQLite snapshot and verify it without restoring authority; key custody and safe restore remain open.

Draft automation data now has a closed parser, three-valued predicates and a narrow structural screening pass. Later stages revalidate rule structs so a modified in-memory value cannot bypass parser bounds. Passing that screen does not activate a rule: proof correspondence, persisted admission and guarded execution are still required.

A credential-free draft sandbox exercises Boolean edges, unknown facts, cooldown, no-op checks, effect conflicts and causal budgets. Its proposals cannot reach the durable outbox or a driver.

The optional draft conflict screen calls the local ex_maude checkout's isolated receipt API for an explicit, Boolean subset. A finding rejects the draft; no finding never grants admission. The current Mix dependency points to the sibling checkout, so release packaging still needs an immutable published artifact.

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

Initial targets are the available older EU LIFX bulbs and Aqara Smoke Detector without an Aqara hub. The operator reports the needed hardware available; exact coordinator and device identities still need local qualification. Exact Hue and Shelly profiles can follow local-only qualification. Product-family semantics live here; generic datagram, Zigbee, HTTP, MQTT, BLE and Matter mechanics belong in WoTEx.

Smoke integration starts read-only. The detector's standalone detection and siren never depend on Home, the Mac, the coordinator, WAN, inference or verification. Home is not a certified fire-alarm or emergency-lighting system.

The first LIFX LAN subset has a bounded packet codec, in-boot response ledger, selected-subnet discovery window and read-only vendor/product/firmware interview. Identity collisions remain visible. It does not open a UDP socket or control a bulb; the WoTEx datagram owner, admission, dispatch and physical qualification are still needed.

## Inference and verification

DistilBERT is a local untrusted input adapter and is required in the full Goatmire prevention demonstration. Ordinary typed control works without it. ex_maude checks declared rule/model questions; a bounded search without a counterexample remains inconclusive, not proof. New proof-required revisions cannot activate without sufficient evidence. Existing admitted rules continue only while their assumptions and runtime guards remain valid. Refpath is an optional client with no special authority.

## Hosts and offline behavior

The target native macOS UI is a client of an opt-in background Elixir service. For a foreground development host, set `WOTEX_HOME_DATA_DIR` to an absolute private directory and run `mix run --no-halt`; application startup then owns the Store and socket together. This host has no device dispatch or installed LaunchAgent, and credentials still require trusted in-process provisioning. Closing a future window must not stop automation; sleep/logout and credential availability still impose real limits. Nerves provides a separately qualified appliance profile. Both must pass offline boot/recovery with artifacts preinstalled; neither requires a cloud controller.

See the [lab catalogue](docs/labs/README.md), [hardware ledger](docs/provenance/hardware-qualification.md) and [procurement plan](docs/plans/procurement.md). Hardware support is per exact device/firmware/capability, not a brand-wide claim.
