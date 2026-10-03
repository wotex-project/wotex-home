# ADR 0009 — Typed components outside the BEAM

Status: accepted target decision, 2026-10-03. Initial implementation is a
development-only pure profile preview.

For optional executable Home helpers, use versioned WIT worlds. Execute them in
native Wasmtime processes managed by OTP, with generated WIT bindings and a
separate closed Elixir IPC codec. Start with synchronous, import-free payload
codecs. Keep Home one application; the native executable is an implementation
detail, not a second authority. Reusable hosting mechanics can move upstream
after this consumer establishes their requirements; household semantics stay
in Home under ADR 0002.

[ADR 0010](0010-data-first-profile-admission.md) refines the production order:
portable profile data first, existing rule source next, executable helpers only
for a named mapping need. This decision owns the optional execution boundary,
not a requirement that every profile or host load a Wasm runtime.

Choose Wasmtime 49.0.2 with an explicit minimal synchronous feature set. Do not
embed the initial runtime as a NIF: a native crash would share the BEAM failure
domain, and a wrapper call timeout alone does not cancel guest execution. Use
one disposable process per invocation initially, one admitted invocation per
runner, immediate capacity rejection and no pending queue. Measure this cost
before adding a warm pool. Pooling would require tested cancellation, identity,
reset and stale-result rules rather than changing this contract implicitly.
Production capacity must include retiring native processes and runner restarts.
The development runner releases its OTP slot before observing native retirement
on cancellation; its one-job limit is not a strict one-live-process guarantee.

The guest receives component bytes and bounded values, never a filesystem path,
Store handle, bearer, socket or device credential. Provide no WASI linker or
custom host imports. Apply limits before instantiation, including start code,
and a process deadline covering parsing, compilation, lifting and destruction.
EOF retirement and an independent native watchdog supplement guest fuel; closing
an Erlang Port alone is not a hard cancellation guarantee for arbitrary code.

For the first pure preview, local installation is an explicit development
operation into a private content-addressed store. Hash and interface validation
establish byte identity only. There is no active profile pointer, permission,
observation commit or transport integration. Publisher trust, durable activation,
retention and revocation under WOH.18 must be implemented before helpers replace
qualified compiled profiles. The current full Home/UDP digest is retained.

The alternative of exposing generic WASI networking would obscure device grant
scope. Future driver worlds must import prebound host resources and preserve
the existing handoff and uncertainty ledger. New capability semantics require
host support; components cannot mint capabilities or extend the rule grammar.

Consequences: authors can build separately and use a language-independent ABI;
OTP remains responsible for supervision and capacity. Native packaging, signed
macOS execution, Nerves libc/board compatibility, compiler memory containment
and supply-chain review are additional gates. A successful desktop preview is
not installation qualification or approval of physical behavior. See
[the extension contract](../specs/WOH.17-component-extensions.md) and
[the implementation plan](../plans/component-extensions.md).
