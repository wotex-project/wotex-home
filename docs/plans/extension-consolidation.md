# Consolidated profile and WIT research

Reviewed: 2026-10-03. Status: decisions promoted to ADR 0010 and WOH.18;
research is not installed-host, physical or complete lifecycle evidence.
Source baseline: `6c00eac`; audited implementation checkpoint: `a9b1130`.

## Result and platform benefit

Use immutable data profiles for independently delivered catalogue membership,
existing bounded Home rule source for automation definitions, and optional WIT
helpers for mappings requiring new computation. One Authority and Store retain
all admission, target grants, qualification, revisions and physical effects.
The runner is an optional extension of this model. Ordinary offline Home use
must continue without it. [ADR 0010](../decisions/0010-data-first-profile-admission.md)
owns this choice; [WOH.18](../specs/WOH.18-portable-profile-admission.md) and the
[plan](../plans/portable-profile-admission.md) make it concrete.

This removes the coupling between an exact device fingerprint and a full Home
release, without claiming a data file can introduce arbitrary new protocols.
WIT adds language-independent computation when useful; its ABI does not replace
profile semantics, grants, proof or physical evidence. Both improvements are
valuable, but independent delivery should not automatically incur native runtime
cost, platform entitlements, cancellation or supply-chain obligations.

## Inputs consumed

These are the original local source commits, retained as provenance after the
consolidation. The incoming document is preserved, with its disposition linked.
The private recovery bundle retains the original trees and history.

| Source | Useful contribution | Final disposition |
| --- | --- | --- |
| `a2aae3c` — WIT research | WIT/Canonical ABI, runtime alternatives, WASI/async status, Elixir/native split, host probes and failure model | Keep the report as a historical baseline. Revise its broad "WIT first" production recommendation through ADR 0010; no narrowing of current runtime qualification |
| `fc4d781` — extension boundaries | ADR 0009, WOH.17, affected authority/security/proof/host/recovery contracts and build sequence | Retain the optional executable boundary. Make profile data admission separately owned; shared lifecycle follows WOH.18 |
| `a9b1130` — isolated previews | Immutable bundles, closed IPC, one-shot Wasmtime, independent author/fixture, failure tests and measured cost | Preserve source/tests and historical evidence. Keep unqualified preview scope and document retirement-capacity/native-memory limits; no physical promotion |
| `4f89a46` — incoming research branch | [Data-first admission proposal](portable-profile-research.md), existing Authority/Store/rule reuse, offline operation, pure/physical retry asymmetry and staged programme | Adopt its production priority and authority/evidence gates. Replace its limited README-only audit with traced source; preserve WIT preview as a bounded optional experiment |

No implementation or evidence axis is raised by squashing these commits. The
incoming branch is not merged as an incompatible second architecture. Its P0/P1/P2
programme is refined into data phases P0–P5 and helper gates H1–H3 in the one plan.

## Primary-source checks and inference

The sources below were inspected afresh for this reconciliation. Versioned
claims use the reviewed release, not an assumption about future compatibility.
Home choices are inferences from these sources plus the repository audit.

| Primary source | Supported fact | Home decision / inference |
| --- | --- | --- |
| [W3C TD 1.1](https://www.w3.org/TR/2023/REC-wot-thing-description11-20231205/) §§1.2, 9, 10 | A Thing Model describes class-level affordances; a TD describes interactions and security, and does not grant credentials | Retain TD/TM upstream ownership. Portable Home profiles select reviewed bindings; descriptions and matching never authorize control |
| [WIT reference](https://component-model.bytecodealliance.org/design/wit.html) and [worlds](https://component-model.bytecodealliance.org/design/worlds.html) | WIT specifies types/imports/exports, not behavior | Typed values still need limits, semantic validation and exact mapping qualification |
| [WASI 0.3 release](https://wasi.dev/releases/wasi-p3) | Native async/streams/futures exist; 0.3.0 shipped June 11, 0.3.1 August 11, 2026; Wasmtime 46 implements final 0.3.0 | Synchronous import-free first world is a scope choice. Async availability does not justify adding network imports or changing handoff/retry policy |
| [Wasmex 0.15.1 component calls](https://wasmex.hexdocs.pm/Wasmex.Components.html#call_function/4) | Timed-out calls continue and subsequent Store operations wait | Keep native computation outside the BEAM failure domain; a wrapper timeout alone is not retirement |
| [OTP 28 Port API](https://www.erlang.org/docs/28/apps/erts/erlang.html#open_port/2) | External-process communication and exit status are Port events | Track actual native retirement and invocation ownership. Task/Port disappearance alone is not proof of OS-process resource release |
| [Wasmtime interruption](https://docs.wasmtime.dev/examples-interrupting-wasm.html) | Fuel and epochs interrupt guest execution; yielding differs from trapping | Compilation, lifting, callbacks and teardown need separate wall-time/resource control; no callbacks in the current world |
| [Wasmtime 49.0.2 resource limiter source](https://github.com/bytecodealliance/wasmtime/blob/v49.0.2/crates/wasmtime/src/runtime/limits.rs) | Instance limits omit runtime/embedder allocations; memory-size limits apply to individual memories | Four 4 MiB memories do not imply 4 MiB total RSS. Typed list lifting allocates before final output validation; require native containment |
| [Wasmtime security](https://docs.wasmtime.dev/security.html) | Guests obtain I/O through linked interfaces; engine bugs remain a defense-in-depth concern | Empty imports reduce guest authority; native same-user processes still need actual OS restrictions and supported patched engines |
| [Wasmtime 49.0.2 release](https://github.com/bytecodealliance/wasmtime/releases/tag/v49.0.2) and [async advisory](https://github.com/bytecodealliance/wasmtime/security/advisories/GHSA-32h6-97mm-8q3c) | October 2 patch includes an async component native stack overflow fix | Preserve the pinned minimal feature set; no dependency update here. Production needs an ongoing advisory/patch policy, not a permanent security claim about a pin |
| [Wasmtime release policy](https://docs.wasmtime.dev/stability-release.html) | Monthly majors; multiples of 12 are 24-month LTS, other releases get two months | Evaluate a supported LTS for production at that time. Rebuild and requalify affected runtime identities rather than silently replacing the development pin |
| [TUF 1.0.36](https://theupdateframework.github.io/specification/v1.0.36/index.html) §§4–5 | Persistent metadata versions, thresholds, hashes and expiry address rollback/freeze/mix-and-match attacks | No home-grown registry verification. First use explicit local digest approvals; separate update freshness from retained offline local approval |
| [Apple JIT entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit), [Wasmtime platforms](https://docs.wasmtime.dev/stability-platform-support.html), [Linux cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html) | JIT permissions, target support and kernel memory/process controls are separate host mechanisms | Signed Mac and exact musl Pi 4 containment must be qualified independently. Linux AS limits do not establish Mac RSS or availability guarantees |

The first research report's library comparisons remain scoped to its inspected
tags. Extism's byte-oriented ABI, Wasmex convenience and Zed's extension SDK
are alternatives/patterns, not Home acceptance evidence. The implemented preview
uses no WASI or native-cache deserialization. AOT, Pulley, WASI 0.3 resources and
more author languages remain choices to measure against a named host/use case.

## Source-backed gaps

`ProfileCatalogue` derives compiled fingerprints and declarations; `Profile.new`
validates a bounded matching record, not an external admission manifest.
`Authority.commit_lifx_capture` uses the compiled package and operator-bound
capture. `EnrollmentWriter` stores reviewed identity/retry/tombstone links;
re-review cannot replace a profile. `QualificationWriter` checks the exact signed
claims and complete Home/UDP runtime before effect use. None supplies external
catalogue import, publisher trust or current external profile selection.

Rules already have a closed codec/compiler and schema-17 admission, activation
and explicit invocation. This is a restricted unconditional single-effect Light
profile, not autonomous scheduling or arbitrary authored automation execution.
Portable rule distribution can reuse this source. Sharing digest/CAS/history
conventions does not merge profile truth, rule proof and physical effect authority.

The optional runner validates real component function types before initialization,
uses empty imports and sends bounded values. A lying decoder can return a valid
Boolean; the unqualified result cannot enter Store. Native watchdog/EOF `_exit`
and prior PID tests show eventual retirement for tested failures. However,
`Runner` clears its active slot after killing the OTP owner, before observing
native exit on cancellation. Rapid replacements or runner restarts can overlap
retiring children. This is a production process-capacity gap, not evidence that
one admitted job guarantees one live OS child. H2 must retain a retirement owner
and block reuse/restart admission until verified retirement or fail closed.

The native executable remains trusted host code: an unexpected large stdout
chunk may be allocated by ERTS before Elixir rejects it. Guest replies are fixed
by that executable, but arbitrary executable paths are not an untrusted native
plugin surface. Artifact-size, fuel and linear-memory bounds do not contain all
compiler/lifting allocations, and macOS RSS lacks a hard limit here. Production
needs containment before parsing/compilation and honest failure when unavailable.

## Decisions after adversarial review

| Question | Decision |
| --- | --- |
| General scripts or arbitrary Wasm application plugins? | Excluded from baseline. Data v1 has no expressions; helpers use reviewed worlds and mappings |
| New catalogue entry vs new semantic binding? | Data may select supported fingerprints/bindings. New protocol behavior, units or risk requires host review |
| Device and automation symmetry? | Share immutable identity, current-owner admission and scoped history; preserve separate proof, observation and nonreplayable-effect rules |
| Signed artifact automatically trusted/qualified? | No. Separate provenance, local approval, target enrollment, qualification and current effect grants |
| Broad qualification digest slows independent delivery? | Retain it; new data identity joins the basis. Narrowing requires demonstrated dependency completeness |
| Data import atomically updates device/rule permissions? | No. v1 cannot widen a declaration; profile changes revoke evidence and suspend rules, never autoactivate packaged source |
| Partial activation, lost reply, restart or rollback? | Global maintenance plus transactional selection/invalidation; historical receipts, new rollback generation, retained unknown and spent roots |
| Disk pressure and abandoned objects? | Explicit quotas, custody synchronization and leases/Store pins. Reject admission if referenced evidence cannot fit |
| Offline versus revocation? | Provisioned local approvals keep data-only use offline; known revocation fences effects. No claim to know unseen remote changes |
| High-rate plugins or a warm pool now? | No measured need. One-shot cost is historical; solve retirement/process bounds before pooling |
| Nerves requires the same engine as Mac? | No for data. Executable support depends on exact native closure/board evidence and can remain unsupported |

The current specs, ADRs and plans were reconciled against these decisions. Open
host/physical evidence and future signature/projection encodings are explicit
implementation gates. Research cannot honestly make every external environment
or future integration "solved"; it can establish a bounded design and measurable
stop conditions before building the next mechanism.

## Consolidation verification

Fresh checks used repository-pinned Elixir 1.19.6/OTP 28.5.0.6 and locked Git/Hex
dependencies in temporary paths; no dependency pin or runtime source changed.
`mix compile --warnings-as-errors`, `mix format --check-formatted` and
`mix woh.spec.check` passed, with 19 contracts. The focused catalogue,
bundle/runner, Authority/host, architecture, Store-collaborator and release
inventory-input regression run passed 37 tests. Rust format checks passed for
both existing projects. Local references and Git whitespace/identity boundaries
were checked before committing; these checks do not establish any acceptance
case's complete environment-specific evidence.

The first regression run had two failures: a 400 ms scripted-peer deadline raced
cold Python startup, and a source-packaging fixture assumed the default `deps/`
path. The deadline test now allows a two-second cold-start window and still
requires timeout, capacity rejection and observed native exit. A temporary link
supplied the fixture's expected dependency path; the unchanged fixture then
passed. Temporary dependency/build trees and the link are removed after checks.
Actual Wasmtime integration/unit/Clippy/benchmark runs were not repeated for
this documentation consolidation; their prior results remain solely in the
historical preview record. No signed app, firmware image or physical test ran.
