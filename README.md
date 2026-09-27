# Wotex Home

**Local-first home control built on WoTEx and Elixir/OTP.**

Home keeps device control inside the home. Its target is predictable operation without vendor clouds, unsafe live rule editing or an AI deciding physical truth. The first host is macOS; Nerves is the appliance deployment path for the same core.

This repository contains specifications, qualification plans and an emerging Elixir core. It is not an implemented or certified physical controller: there is no guarded driver or physical command path yet. Start with the [specification index](docs/specs/WOH-index.md), [architecture](docs/architecture/system.md) and [implementation plan](docs/plans/implementation.md), which records the remaining delivery gates.

Run `mix test` for the current core and `mix woh.spec.check` to check spec versions, required cases and dependency links. The pinned Elixir/OTP versions are in `.tool-versions`.

The current semantic subset covers exact Light values, read-only smoke report types, capability declarations, boot-scoped observation freshness and closed scene plans with per-member reports. It does not yet implement group/scene execution or physically qualified device control.

Discovery candidates, interviews and exact profile matching are read-only. A matching fingerprint is a review hint, not enrollment or permission to control a device.

An explicit enrollment review now checks the candidate, interview, profile and proposed Thing together. It remains pending authenticated commit and creates no device authority.

The pure policy check rejects stale authority/revision, missing permissions, unsupported writes and unresolved invariants. It cannot authorize a device by itself: authentication, durable state, final dispatch checks and a driver boundary are still required.

A same-host SQLite lock gates the single-writer store. It persists current reports, enrollment, principal grants, a journal and scoped request receipts with WAL and verified `synchronous=FULL`. Reports require exact active enrollment; a bounded batch records all values from one device reply atomically. It rejects duplicate, conflicting and old source sequences and refuses silent source-epoch/profile changes. Local provisioning issues random credentials; request staging derives policy inputs from persisted state and caps held work per principal and globally. Trusted declaration reduction and Thing, principal or target-grant revocation reject matching held work atomically. An opt-in private Unix socket accepts credential-authenticated health, held submission/cancellation, status and pending-only draft reviews. Read-only held power and colour inspections recheck current Store reports, and a fresh already-reported power value can close held work with a durable no-send receipt. Request outbox rows otherwise remain held and cannot be dispatched; installed IPC identity, command admission, cross-host fencing, restore and power-loss qualification remain open.

Startup checks the held receipt/outbox relationship. The local socket exposes redacted health, scoped revision-stable pages of current observations, enrolled Thing declarations and observation history, plus polling cursors for observation and own request events. An intervening write requires a new snapshot page sequence; push subscriptions and retention-gap handling remain open. Held work is never reported as delivered. Trusted in-process calls can export and verify a bounded encrypted SQLite snapshot, then stage a quarantined offline copy that Store refuses to start. Key custody and fenced restoration of authority remain open.

Draft automation data now has a closed parser, three-valued predicates and a narrow structural screening pass. Later stages revalidate rule structs so a modified in-memory value cannot bypass parser bounds. Passing that screen does not activate a rule: proof correspondence, persisted admission and guarded execution are still required.

A credential-free draft sandbox exercises Boolean edges, unknown facts, cooldown, no-op checks, effect conflicts and causal budgets. Its proposals cannot reach the durable outbox or a driver.

The optional draft conflict screen calls the pinned ex_maude source's isolated receipt API for an explicit, Boolean subset. A candidate review combines that negative screen with structural checks and returns only rejected or pending outcomes bound to exact rule and Thing digests. A finding rejects the draft; no finding never grants admission. The Mix dependency uses the committed source snapshot in `vendor/ex_maude`; its exact origin and license are recorded in [provenance](docs/provenance/ex-maude-vendor.md).

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

The first LIFX LAN subset has a bounded packet codec, in-boot response ledger, selected-subnet discovery window, read-only vendor/product/firmware interview, correlated GetColor session, exact Home report conversion, pure power and colour set/ack/readback exchanges, fresh-baseline HSBK colour planning with a dispatch recheck, and a pinned-registry interpreter. Bounded discovery, identity interview and read paths use a caller-owned datagram transport; independent scripted UDP peers on loopback test identity and readback, while a fixture tests selected-prefix discovery. A temporary read-only lab probe (`mix run bin/lifx_read_lab.exs en0`) now uses a one-use capture process and found no candidates on this development Mac on 2026-09-27. It requires a candidate reference if several devices respond. Run `mix woh.lifx.registry.fetch` to stage the exact product metadata locally before a development release; the artifact is ignored by Git and checked by SHA-256 at runtime. Identity collisions and unknown products remain visible. Production code does not open a UDP socket or control a bulb; the WoTEx datagram owner, admission, dispatch and physical qualification are still needed.

## Inference and verification

DistilBERT is a local untrusted input adapter and is required in the full Goatmire prevention demonstration. Ordinary typed control works without it. ex_maude checks declared rule/model questions; a bounded search without a counterexample remains inconclusive, not proof. New proof-required revisions cannot activate without sufficient evidence. Existing admitted rules continue only while their assumptions and runtime guards remain valid. Refpath is an optional client with no special authority.

## Hosts and offline behavior

The target native macOS UI is a client of an opt-in background Elixir service. For a foreground development host, set `WOTEX_HOME_DATA_DIR` to an absolute private directory and run `mix run --no-halt`; application startup then owns the Store and socket together. This host has no device dispatch or installed LaunchAgent, and credentials still require trusted in-process provisioning. Closing a future window must not stop automation; sleep/logout and credential availability still impose real limits. A [Raspberry Pi 4 Nerves development image](native/nerves/README.md) now cross-builds the same core for OTP 28 and places private state under `/data`; it has not booted on a board or passed rollback/power-loss qualification. Both hosts must pass offline boot/recovery with artifacts preinstalled; neither requires a cloud controller.

For a local release smoke check, run `MIX_ENV=prod mix release --overwrite`, then `mix woh.release.smoke _build/prod/rel/wotex_home/bin/wotex_home`. From a clean committed tree, run `mix woh.release.inventory create _build/prod/rel/wotex_home` and `mix woh.release.inventory verify _build/prod/rel/wotex_home` to bind every assembled file to the source commit. This checks bundled Maude execution and private host startup/shutdown on the build machine. The source dependency is pinned in this repository; clean-machine installation, native dependency closure, signing and installed-host qualification remain separate release gates.

For an isolated source check with locally cached Hex packages, run `mix woh.isolated.smoke` from a clean committed tree. It builds the archived commit in a temporary directory with `HEX_OFFLINE=1` and has no access to a neighboring ex_maude checkout or ignored local LIFX registry.

`mix woh.macos.app.assemble` wraps an inventoried release in an [unsigned SwiftUI development app](native/macos/README.md) with a per-user background agent registration surface and authenticated read-only health, Thing catalogue and observation views. A trusted foreground bootstrap can issue a zero-target diagnostic credential for manual Keychain import. Run `python3 bin/smoke_native_health.py`, `python3 bin/smoke_native_snapshot.py`, `python3 bin/smoke_native_read_view.py`, `python3 bin/smoke_bootstrap_health.py` and `python3 bin/smoke_native_live_host.py` for fixture, paging, bootstrap and actual-host checks. Assembly does not register the agent.

The release also includes `bin/wotex_home_cli` for health, redacted support preview/private export, paged catalogue/snapshot/history/event reads, receipt, enrollment-review and override lookups, bounded draft-rule review, held request submission/cancellation and operator override issue/status/revoke. Supply `--socket` and `--credential-file` with absolute paths; the credential file must be mode 0600 and contain the canonical 43-character operator credential. `submit` reads the closed mutation envelope from an absolute 0600 JSON file; `review-rules` reads a private JSON object containing only `rules`. A held receipt is durable staging, not a physical effect, and draft review never activates a rule. On an uncertain mutation response, reuse its original epoch and operation ID with `receipt` or `override-status`. The CLI uses the same scoped local socket and has no provisioning or device-send command.

See the [lab catalogue](docs/labs/README.md), [hardware ledger](docs/provenance/hardware-qualification.md) and [procurement plan](docs/plans/procurement.md). Hardware support is per exact device/firmware/capability, not a brand-wide claim.
