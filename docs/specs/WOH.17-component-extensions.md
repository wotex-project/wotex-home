# WOH.17 — WIT component extensions

Version: 0.1.2. Status: accepted target; optional executable helpers, pure preview only.

## Authority and scope

**H17-01.** Extensions implement versioned WIT worlds. Home retains Thing
identity, capability vocabulary and units, permissions, freshness, rule
admission, durable transitions and transport custody. Component results are
proposals until the owning Authority use case validates their meaning and the
Store commits under current guards. No guest receives a Store connection,
bearer, raw device credential or ambient route. A WIT type, digest, publisher
signature or successful fixture is not semantic or physical qualification.

Portable data admission is separately owned by [WOH.18](WOH.18-portable-profile-admission.md)
under ADR 0010. An executable helper requires a named mapping need and benefit
over a supported data/host binding. No Wasm engine is required for data profiles,
existing rule source or ordinary local control. This is not a general application
plugin host; a future resource/driver world needs a separate review.

The first package is `wotex:home-profile@0.1.0`, with world
`wotex:home-profile/profile@0.1.0`, defined in
[profile.wit](../../native/components/wit/profile.wit). It exports exactly
`wotex:home-profile/light-power@0.1.0`, with synchronous `decode-power` and
`encode-power`. It imports nothing. Decode accepts at most two payload bytes;
the example maps exact little-endian zero and 65,535 to Boolean power and
returns typed malformed/unsupported otherwise. Encode proposes six payload
bytes; the host independently requires the requested Boolean level and zero
duration. This world exposes neither packet framing nor a device capability.
Results carry `unqualified_profile_preview` scope and exact component/WIT
identities. They never enter observations, enrollment, rule facts or dispatch.

## Artifact and compatibility

**H17-02.** Local installed artifacts are immutable, bounded and addressed by
the SHA-256 of their portable component bytes. A closed manifest identifies its
format, world and WIT SHA-256 as well as the component digest. Reject unknown
fields, unsafe paths, nonregular/symlinked artifacts, wrong hashes, unsupported
formats and unavailable bytes. Rehash the bytes actually sent to the worker;
verify again there. Accept portable component binaries only, never vendor
native caches or source text evaluated by the host. Validate the actual import,
export and function types, not just a manifest's package version.

The development installer writes a complete private staging directory before
one rename publishes a digest directory. Existing identities are verified,
never overwritten. It installs no dependency solver, URL fetcher, executable,
active pointer or signer policy. A staged incompatible component remains
unqualified and fails preview. Crash-left staging directories are inert and
must be cleaned without touching published artifacts. Local filesystem custody
assumes a trusted host account; it is not protection from its administrator.

Production admission additionally needs a closed provenance/license manifest,
configured artifact trust policy, dependency closure, actual runtime/adapter/config
identity and exact cohort evidence. A publisher cannot widen host budgets.
Local digest approval and any later publisher-signature mode follow WOH.18;
the current unsigned development installer implements neither production mode.
Interface evolution uses a separately supported world version and SDK;
compatibility does not transfer qualification. No digest scope is narrowed
without the affected proof and physical review.

## Execution and Elixir boundary

**H17-03.** OTP supervises the runner separately from persistence and device
sessions. Native Wasmtime runs outside the BEAM. Elixir sends only a closed,
versioned, length-framed binary message over a private Port; WIT terminates in
generated native bindings. Errors use finite codes without guest-controlled
logs, paths or native backtraces. No guest value becomes an atom. An invocation
has one process and one immutable artifact; component state is discarded.

The initial development runner admits at most one invocation, with no queue;
a second returns capacity immediately. The deadline starts at admission and
covers artifact loading, process startup, compilation, initialization, execution,
post-return, lifting and reply validation. Monitor the caller; on loss retire
the worker. On timeout, malformed response, native exit or trap retire it and
return a typed unavailable/error result. Never reuse uncertain state or accept
a late reply for another job. Native stdin EOF retirement and a wall-clock
watchdog are required because an Erlang timeout/Port close alone cannot stop
arbitrary native work.

Production capacity includes retiring OS children. Retain an independent native
retirement owner after caller cancellation; do not release capacity or reuse
state until retirement is observed, or fence admission when it cannot be proved.
Include runner restart in that ceiling. A PID alone is not durable process
identity and cannot justify killing an unrelated reused PID. The development
OTP-slot implementation does not yet meet this complete capacity requirement.

**H17-04.** Budgets apply before allocation/instantiation: finite artifact and
IPC sizes, input/output lengths, fuel, guest stack, memory/table/instance counts,
native CPU and wall time. No WASI, custom imports, guest threads or async
component features are linked in this world. Empty linkers and exact top-level
imports/exports are checked before initialization. Compilation and host lifting
are outside guest fuel; enforce separate process containment and include them
in failure tests. Linear-memory limits alone are not native RSS limits. Signed
production hosts require enforceable native memory/descriptor and OS sandbox
policy; a same-user subprocess is not an OS sandbox.

Budget values and the binary framing are specified in the owning
[native guide](../../native/components/README.md), bound to its runtime build.
Any increase requires remeasurement and affected qualification. Initial desktop
resource-limit probes do not qualify the Nerves or signed macOS closure.

## Semantics and failures

**H17-05.** Keep invalid input, unsupported mapping, guest trap, resource
exhaustion, native loss, timeout, incompatible interface and capacity distinct.
Malformed/unknown observations stay unknown; they never clear an alarm or
refresh a Store receipt. Encoding is a proposed operation. Independent host
validation or an explicitly qualified trusted encoder must establish its exact
allowed effect semantics before any handoff. Guest metadata cannot create
capabilities, change risk or claim cryptographic device authentication.

An I/O-capable future world requires separately versioned, finite prebound
session resources, per-use current grants/epochs and cancellation. Protocol
queries require review even when called reads. Effects require a committed
handoff marker before a guest can invoke an effect import. Local acceptance,
protocol ACK and independently reported state remain separate. Loss after
handoff remains unknown and cannot cause an automatic retry.

## Lifecycle, recovery and delivery

**H17-06.** Staging, validation, qualification and activation are separate.
Production activation/revocation follows WOH.18's Store-owned revision/generation change
under an authority barrier. The same transaction invalidates affected unsent
work and preserves handed-off uncertainty. Inflight work retains original
artifact identities; historical reports and receipts are never redecoded,
rewritten or refreshed after upgrade. Bound artifact retention and pin every
identity referenced by current and historical durable work. Failure to retain
required bytes blocks dependent work rather than substituting a newer plugin.

Backups identify required external component, signer and qualification custody;
restoration stays quarantined. Rollback must check Store-schema, world, adapter,
runtime and physical compatibility without refunding causal budgets. The
development content-addressed installer has no durable activation or recovery
authority and changes no Store schema.

**H17-07.** Host packaging accounts for the runner, WIT/SDK, runtime feature set,
Cargo lock, native dependency closure and license inputs. No runner is silently
added to an existing qualified release. A signed macOS executable needs its
actual JIT/interpreter and entitlement closure checked; Nerves needs exact
architecture/libc/system-image builds and board memory/restart evidence. Generic
transport hosting remains an upstream WoTEx responsibility. Offline authoring
and runtime use must work from provisioned artifacts without a registry.

## Acceptance

H17-T1: independently built components install and run without rebuilding Home;
wrong hashes, worlds, imports, exports and types fail closed.
H17-T2: independent golden vectors agree across implementations; malformed,
unsupported and dishonest outputs cannot acquire device authority.
H17-T3: initialization loops, execution loops, memory/table growth, output abuse,
native crash, truncated framing and deadlines retire the worker while Store and
unrelated reads remain available.
H17-T4: capacity, caller death, runner stop/restart and late replies neither leak
workers nor contaminate another invocation; state is isolated between calls and
rapid cancellation/restart cannot exceed a ceiling including retiring OS children.
H17-T5: activation/revocation races, transaction rollback, restart and missing
artifacts preserve original identities, history and handed-off uncertainty.
H17-T6: backup/quarantined restore and incompatible rollback cannot activate old
authority or reinterpret observations.
H17-T7: signed macOS and exact Nerves host inventories, containment, offline
operation and physical cohort qualification pass separately.
H17-T8: authoring documentation, reproducible locked builds, bounded diagnostics
and measured cold/warm cost support the declared operational budget.

Catalogue evidence remains missing until complete environment-specific cases
exist. Software preview tests cannot close lifecycle, installed-host or physical
obligations.

## Implemented development checkpoint

The import-free world now has a separately compiled Rust author example and an
independent Canonical ABI fixture. Home stages private content-addressed bundles
and performs exact component/WIT checks through a one-shot native Wasmtime
49.0.2 worker. Actual component function types are checked before initialization,
then generated bindings check calls. OTP bounds admitted jobs and the caller-visible
deadline; tests observe native retirement on EOF/caller loss/timeout/shutdown,
malformed framing, state isolation and Store availability. A dishonest decoder
remains an unqualified preview and changes no durable facts. Host configuration
is optional, and runner failure leaves earlier Store/driver children running.

This covers software portions of H17-T1–T4/T8 on the development Mac. The
[validation record](../plans/component-extensions-validation.md) records actual
checks and measurements. H17-T5–T7, enforceable production native-memory/OS
containment, signed delivery and physical mapping admission remain unimplemented
or unqualified. Existing Store schema, compiled profile admission and default
physical dispatch are unchanged; catalogue evidence remains missing.
Cancellation releases the admitted-job slot before native exit is observed;
rapid replacement/restart can overlap retiring workers. H17-T4's complete
production capacity obligation therefore remains open along with H17-T5–T7.
