# Component preview validation

Reviewed: 2026-10-03. Development Mac, arm64. This records the first bounded
implementation against [the plan](component-extensions.md) and
[WOH.17](../specs/WOH.17-component-extensions.md); it closes no physical or
installed-host acceptance case.

## Implemented boundary

Elixir/OTP 1.19.6/28.5.0.6, Rust 1.97.1, Wasmtime 49.0.2, wit-bindgen 0.62.0
and wasm-tools 1.261.0 were used. New Cargo closures are committed separately;
existing Mix dependencies and `mix.lock` were not updated. The native feature
set is explicit and excludes WASI and component async/guest threads. A binary
component entry point avoids native cache deserialization. Generated native
WIT bindings and a separate closed binary IPC codec join Elixir.

The installer publishes immutable private directories addressed by component
SHA-256. It binds the exact WIT source, rejects metadata/byte drift and sends
bounded bytes to the native worker. The worker verifies both component and WIT
hashes, actual imports/exports and function types before initialization. The
first build uses fuel plus a disposable-process watchdog rather than epoch
scheduling; there are no imported callbacks to cancel. Native limits cover
start functions as well as calls. A new process discards state after every job.

Both the Rust author implementation and separately written Canonical ABI fixture
run through Home without rebuilding its application for either installation.
They match seven independent vectors: off/on decode, empty/one-byte malformed,
unsupported intermediate level, and both zero-duration encodes. The reference
fixture's limited allocator is not a general production SDK.

## Failure and review findings

Actual component tests cover initialization/execution loops, traps, memory
growth, output length abuse, unbound imports, extra outer/inner exports, wrong
function types, state isolation and a dishonest decoder. A wrong-type component
with a looping initializer is rejected before the initializer runs. The lying
decoder returns a false proposal for an on payload, but its explicit unqualified
scope never updates Store or dispatches. Encoding is checked independently
against the requested level and zero duration in both native and Elixir layers.

Scripted native peers cover capacity, caller loss, timeout, shutdown, unexpected
exit, truncated/huge/trailing frames and inherited-secret removal. Tests inspect
actual OS PIDs until workers exit; they do not equate an Elixir timeout with
cancellation. Real Wasmtime process tests also exercise EOF during a 450,000-NOP
compilation, a five-second watchdog while input stalls, framing bounds and an
empty-environment call. Store health/revision remain unchanged and available.
The optional host child restarts without restarting Store or the power pool.

Iterations corrected an Elixir variable-range guard warning, a test's nonexistent
Store snapshot helper, and a native error-type API mismatch. Review found an
stdin-lock lifetime that could prevent the EOF thread reading during work;
the lock now drops before execution. Watchdog/EOF retirement uses Unix `_exit`
to avoid waiting for C exit handlers or allocator cleanup. A trailing-frame test first timed out;
extra bytes now fail immediately. Source inspection also showed generated
bindings check function types while loading an instantiated component, so an
explicit pre-initialization type check was added. The tagged
[binding generator](https://github.com/bytecodealliance/wasmtime/blob/v49.0.2/crates/wit-bindgen/src/lib.rs),
[component types](https://github.com/bytecodealliance/wasmtime/blob/v49.0.2/crates/wasmtime/src/runtime/component/types.rs)
and [resource limiter](https://github.com/bytecodealliance/wasmtime/blob/v49.0.2/crates/wasmtime/src/runtime/limits.rs)
were inspected alongside the local locked sources. These findings are resolved
in the current preview; broader host/lifecycle obligations remain open.

## Measurement and limits

Twenty calls per implementation used fresh native processes and fresh compilation,
with an optimized runner. The reference was 2,228 bytes and Rust 20,771 bytes.
Median process/call/exit times were 6.196 ms and 16.258 ms respectively; maxima
were 361.972 ms and 16.926 ms. The first executable launch is included in these
samples; filesystem/OS caches are not reset between launches. Maximum child RSS
reported by `getrusage` over these calls was 13.91 MiB. Debug calls were much
slower (roughly 18 ms/203 ms medians under concurrent validation), illustrating
why that build is not a production throughput basis.

The optimized runner SHA-256 was
`69d8941f6fdc5edb0a82a5a593577d65407edb0babe1d69e5af4ce930bd13d52`;
WIT SHA-256 was
`8914e52d5442b695428f1f2cf48bde71afdf5580464526afd23e06f654a01521`.
Generated components, binaries and measurement JSON were stored in ignored
`_build/` and were removed during the requested disk cleanup. These are retained
historical observations, not currently available raw measurement artifacts.
Authored fixtures and locked build commands remain for a fresh reproduction.
Measurements are development observations, not capacity guarantees for larger
plugins, frame floods or appliance hardware. No warm pool/cache was measured or
implemented. The five-second job budget contains failures, rather than promising
that all valid plugins are suitable for real-time observation.

macOS native RSS is not hard-capped by this implementation. Wasm memory bounds,
native CPU/descriptor limits and a watchdog are not a complete native-memory or
OS permission sandbox. On Linux the code additionally sets a 512 MiB address
space limit, but no Linux/Nerves execution result is claimed here. Typed lifted
lists can consume up to a bounded guest memory range before exact output-length
validation; the reply itself remains at most eight bytes. Production containment
and high-rate pooling need their own design and actual host evidence.

The optimized Mach-O declares macOS 11.0 minimum, built with SDK 27.0, and its
direct loads are only `/usr/lib/libiconv.2.dylib` and `/usr/lib/libSystem.B.dylib`.
This local `otool` inspection is not signing, minimum-OS execution or transitive
closure evidence. The binary was not inserted into an app/release inventory.

## Validation results

The focused regression run passed 85 Elixir tests; a later host/Authority/catalogue
run passed 25, including the optional restart domain. The optimized native runner
passed all four actual component integration tests. The native Rust unit suite
passed three tests, and four standalone native process tests passed. Rust Clippy
passed with warnings denied for both runner and author example. The full
`WOTEX_HOME_GIT_DEPS=1 WOTEX_HOME_COMPONENT_NATIVE_TESTS=1 mix test` run passed
543 tests with no failures, including real socket/TLS fixtures; no socket-free
exclusion was used. The final native hard-exit adjustment was followed by the
affected component/host regression and standalone native retirement/unit checks.
`mix format --check-formatted`, `mix compile --warnings-as-errors` and
`mix woh.spec.check` passed (18 contracts); Rust format checks passed for both
projects. Local documentation references, benchmark artifact identities,
unchanged existing dependency pins and `git diff --check` passed. None of these
checks establishes signed installation, Linux containment or physical behavior.

## Remaining delivery work

The [consolidated research](extension-consolidation.md) additionally
identifies a cancellation-capacity gap: the OTP slot is released before native
retirement is observed, so retiring children can overlap new jobs. The earlier
PID checks establish eventual retirement for their cases, not a hard live-process
ceiling under rapid replacement or runner restarts. This and pre-validation
host allocations belong to the optional helper hardening gate in the
[portable profile plan](portable-profile-admission.md). Data admission proceeds
independently; this historical preview record does not close that lifecycle.

No durable active profile pointer, publisher trust policy, artifact retention
ledger, restore dependency transfer or brokered I/O was added. Current Store
schema 18, compiled profile admission, full Home/UDP digest and default-disabled
physical dispatch remain. Nothing was signed, packaged into the macOS app or
Nerves image, or sent to a device. WOH.17 implementation is partial and evidence
missing. Continue under the shared data-first lifecycle plan and optional helper
gates, then actual host/physical qualification. No Git refs were pushed.
