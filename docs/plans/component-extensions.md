# Component extension implementation and review plan

Version: 0.1.2. Updated: 2026-10-03. Optional executable-helper track; evidence
gates stay separate. [The portable profile plan](portable-profile-admission.md)
owns the consolidated production build order under ADR 0010. Background and
primary sources are in [the research report](wit-wasm-plugins.md) and
[the consolidation](extension-consolidation.md).

## Structure and ownership

| Location | Responsibility |
| --- | --- |
| `native/components/wit/` | Versioned authored WIT; generated native bindings use these bytes |
| `native/components/runner/` | Locked Wasmtime executable, empty linker, bounded single-call IPC |
| `native/components/examples/` | Separately buildable author examples and independent fixture implementation |
| `lib/wotex_home/plugins/` | Immutable bundle staging/reading, closed IPC and bounded OTP runner |
| `WotexHome.Authority` | Explicit unqualified preview; future lifecycle through WOH.18 |
| `Durable.Store` | Future sole WOH.18 activation/revocation/history writer; no initial schema change |
| `test/wotex_home/component_*` | Actual native boundary, failure retirement and authority isolation |
| `native/components/README.md` | Host build, framing/budgets, SDK and development operation procedures |

Home remains one Mix application. No generic network stack or credential store
is embedded in the guest. This first Home adapter provides a concrete upstream
extraction candidate; moving code into sibling repositories is separate work.

## Contract alignment

| Owner | Required alignment | First slice / subsequent gate |
| --- | --- | --- |
| WOH.02 discovery/profile | Permit immutable typed components under WOH.17; firmware/profile updates still require review | Compiled enrollment stays authoritative; no plugin matching |
| WOH.03 mappings | Name pure payload preview separately from correlated physical reports | No packet or transport path replacement |
| WOH.05 security | Malicious guest input/output, native compiler trust and least privilege | Empty linker; production OS containment remains a gate |
| WOH.07 proof | Bind every executable dependency and changed semantic mapping | Retain existing full Home/UDP runtime digest |
| WOH.08/09 hosts | Separate optional runtime and actual signed/board closure | Development worker opt-in; do not ship it silently |
| WOH.11 hardware | Component identity joins exact cohort evidence for physical use | Synthetic vectors do not qualify any device |
| WOH.14 durability | Artifact pins, activation CAS/barrier, uncertainty/history retention | No schema or effect changes initially |
| WOH.15 authority | Lifecycle via Authority; no raw plugin executable/import surface | Trusted internal preview only; no public socket route |
| WOH.16 recovery | Native/provenance inventory, external artifact custody, quarantined restore | Production packaging and lifecycle must follow |
| WOH.17 extensions | ABI, bundles, containment, semantics and acceptance matrix | New owning contract, partial implementation/missing evidence |
| WOH.18 portable admission | Data first, explicit local trust, target selection, retained history | Planned independently of the optional engine |

WOH.01 and WOH.04 retain closed units/capabilities and rule IR. Future profile
selection pins join their reviewed dependencies; arbitrary plugin metadata
cannot extend these languages or activate bundled rules.
No required case, catalogue evidence axis or hardware ledger is promoted from
these development checks. ADR 0009 and system architecture record the choice.

## Review of difficult paths

| Failure or adversary | Required response and evidence |
| --- | --- |
| Forged manifest, substituted bytes, symlink, partial install | Closed metadata, regular bounded files, both-side hash check, atomic complete-directory publication; restart sees no active partial artifact |
| Correct package name, wrong types or extra imports/exports | Inspect actual component type and generated bindings before instantiation; reject rather than supply default imports |
| Start function loops or traps | Budgets already active at instantiation; disposable worker retires |
| Compilation bombs / Canonical ABI allocation abuse | Artifact/process bounds and deadline outside fuel; finite lifted memory/output; production native-memory containment gate |
| False sensor result / unsafe bytes | Preview is unqualified; host checks exact supported encoder semantics; future qualified decoder joins evidence identity |
| Hung callback, guest loop, native panic | No initial callbacks; fuel plus watchdog and EOF retirement; typed failure without restarting Store |
| Caller dies, supervisor stops, response arrives late | Monitor owner, close Port, native EOF exit; one invocation per process, no identity reuse |
| Flood, mailbox or queue pressure | One admitted OTP invocation, immediate capacity rejection, bounded frames; production must also count retiring OS children and restart races; future external API needs ingress limits |
| Upgrade/revoke between staging, claim and send | Store transaction barriers and repeated current pins at every boundary; future lifecycle tests use real SQLite failure injection |
| Crash after send / rollback | Preserve unknown and spent causal root; no resend, no reinterpretation |
| Missing artifact on restart/restore | Fail dependent work, retain history, quarantine restore; exact external dependency custody |
| ABI/SDK version drift | Supported world allowlist, locked toolchains/dependencies, independent producer tests; version is not qualification |
| macOS executable memory / musl Nerves incompatibility | Actual signed host and board tests; Pulley/AOT choice measured before delivery |
| Guest logs leak household data | No guest logging imports, finite diagnostics; native errors are codes |

## Build sequence and exit criteria

1. Freeze the import-free Boolean payload WIT and binary IPC. Write the new
   contract, ADR and the owner links above before code. Review the design against
   initialization, cancellation, native memory, malicious output and update races.
2. Implement independent component installation, generated native bindings and
   the OTP runner. Use a Rust author example and a separately handwritten
   Canonical ABI fixture, with independent expected vectors. Include native and
   Elixir framing/limit tests, actual caller-loss/timeout retirement, capacity,
   crash and Store availability checks. Measure cold calls and native RSS.
3. Reconcile actual results, failed assumptions and budget choices back into the
   contract/plan/host guide; keep a local validation record. Complete core format,
   compile, catalogue and affected regressions before the local implementation
   commit. This gate establishes a development preview, not production plugins.
4. Follow WOH.18's data-first lifecycle phases. Add explicit local digest approval,
   Store selection/retention/revocation, schema/integrity and historical backup
   sets together before active external profiles. This work requires no engine.
5. For a named mapping need, follow helper gates H1–H3: prove the benefit over
   data/host bindings, close retirement/capacity and allocation/OS containment,
   qualify actual signed Mac and exact Nerves closure, then join Store lifecycle
   and exact physical evidence. Brokered I/O and async worlds remain separate.

Steps 4–5 are future gates; the implemented preview cannot invent their evidence.
The first production data policy uses explicit local digest approvals; publisher
signature distribution is a later policy. Keep local explicitly staged unsigned
development components unqualified. Production writable helpers are reviewed artifacts, with
qualification scoped to exact mappings; arbitrary installed code cannot gain
device authority. Rust is the first author language, synchronous worlds the
initial ABI, one-shot processes the initial isolation choice. Broader codec
worlds, warm caches/pools and async I/O remain measured follow-up decisions.

## First implementation result

Steps 1–3 now have a working development preview and adversarial native/Elixir
checks. The [validation record](component-extensions-validation.md) records
actual results, cost, review corrections and limitations. The world remains
import-free; the Rust author project builds separately, installation needs no
Home rebuild, and the optional OTP child cannot commit a report/effect. SDK
metadata and both-side WIT hash checks prevent an old runner silently claiming
a new interface identity. Actual function types are checked before guest start.
No source-backed plugin loader, Store migration, active profile or physical
path was introduced. Source reconciliation found that cancellation releases the
OTP slot before observing OS retirement; prior PID checks prove eventual exit,
not a strict live-process capacity ceiling. Mac RSS and pre-validation native
allocations also remain open. The next production work is portable data phase P1,
followed by the shared lifecycle; helper hardening and delivery stay separate.
