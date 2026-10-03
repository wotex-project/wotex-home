# Development WIT component host

This optional native worker implements the import-free world in
`wit/profile.wit`. It runs outside the BEAM and only supplies unqualified payload
previews. It is not part of the packaged macOS/Nerves closure. Production
activation, publisher policy, OS sandboxing and physical qualification follow
[WOH.17](../../docs/specs/WOH.17-component-extensions.md).

[ADR 0010](../../docs/decisions/0010-data-first-profile-admission.md) keeps this
engine optional. The [shared profile plan](../../docs/plans/portable-profile-admission.md)
builds data admission independently; a production helper first needs a named
mapping benefit plus containment/retirement evidence. This guide operates only
the implemented development preview, not an external active-profile loader.

The native runner pins Wasmtime 49.0.2 with synchronous component-model,
Cranelift, runtime and standard-library support. No WASI library or guest logging service is linked. Wasmtime async/component
async and guest thread features are disabled; native watchdog/EOF threads are
host implementation details. Native cache deserialization is absent. WIT bindings are
generated from the authored world at compile time.

## Initial budgets and framing

| Boundary | Development limit |
| --- | --- |
| Component bytes | 512 KiB |
| Input bytes | 2 for decode; one Boolean byte for encode |
| IPC response | 8 bytes excluding four-byte prefix |
| Lifted byte list | At most the guest memory range, up to 4 MiB, then exact six-byte validation |
| Admission | One admitted OTP job per runner; no queue; retiring native children are not yet included in the ceiling |
| Elixir total job deadline | 5 seconds from admission |
| Native lifetime watchdog | 5 seconds from process start |
| Fuel / guest stack | 2,000,000 / 512 KiB |
| Linear memory | 4 MiB each, at most four memories |
| Tables / entries / instances | Four / 1,024 each / 16 |
| Native CPU / open descriptors / core files | 3 seconds / 32 / disabled |
| Linux native address space | 512 MiB |

Address-space enforcement on macOS is not treated as an RSS sandbox. Guest
memory and the watchdog do not bound all compiler/host allocations. Measure
native RSS and establish production host containment before delivery. The
runner exits on stdin EOF even during compilation or guest execution; its
independent watchdog covers work outside guest fuel. The guest has no imports.
On cancellation the OTP slot is released before native exit is observed. Tests
check eventual OS retirement, but rapid replacements/restarts can overlap old
workers. Production must retain a retirement owner and fence capacity across
that boundary; do not treat this table as a hard live-process/RSS guarantee.

IPC is four-byte big-endian length followed by a closed binary body. Request:
version byte 1, operation byte (0 decode / 1 encode), 32 raw component SHA-256 bytes,
32 raw WIT-source SHA-256 bytes, four-byte component length, component bytes, then input. The maximum body is
524,360 bytes. Response: version 1, kind (0 decoded Boolean, 1 decode error,
2 six-byte encoded payload, 3 worker error), then a Boolean/error byte or
payload. Decode-error codes are 0 malformed, 1 unsupported. Worker-error codes
are 0 invalid request, 1 digest mismatch, 2 invalid component, 3 incompatible
world, 4 guest trap, 5 invalid output, 6 resource setup failure, 7 guest resource
exhaustion, 8 interface-source mismatch. SIGXCPU exit 152 is resource exhaustion;
other unexpected native exits remain native loss. Native watchdog
exit is 124 and EOF retirement is 125. Errors contain no guest text. Framing,
identity and output semantics are checked again in Elixir; stderr is never
merged into the protocol. A process handles one request and exits.

## Build and validate locally

The tested Rust compiler is 1.97.1; Elixir/OTP use the repository pins. The runner
and author example each have a committed Cargo lock. These commands add no Mix
dependency and do not update existing pins. Run from the repository root:

```sh
rustup target add wasm32-unknown-unknown
CARGO_TARGET_DIR="$PWD/_build/component-native" cargo build --locked --manifest-path native/components/runner/Cargo.toml
CARGO_TARGET_DIR="$PWD/_build/component-example" cargo build --release --locked --target wasm32-unknown-unknown --manifest-path native/components/examples/rust/Cargo.toml
python3 native/components/build_fixtures.py --wasm-tools /absolute/path/to/wasm-tools
WOTEX_HOME_GIT_DEPS=1 WOTEX_HOME_COMPONENT_NATIVE_TESTS=1 mise exec -- mix test test/wotex_home/component_bundle_test.exs test/wotex_home/component_runner_test.exs test/wotex_home/component_native_test.exs
CARGO_TARGET_DIR="$PWD/_build/component-native" cargo test --locked --manifest-path native/components/runner/Cargo.toml
python3 native/components/test_runner.py
python3 native/components/benchmark.py
```

The fixture builder requires exactly wasm-tools 1.261.0; provision the official
platform release or use `cargo install wasm-tools --version 1.261.0 --locked`
into a selected local tools directory. The research report records the verified
Mac archive identity. The Rust library embeds generated WIT metadata; the
fixture builder wraps its core binary as a component. Rust uses the import-free
`wasm32-unknown-unknown` target here, avoiding WASI stdlib services. A future
WASI/async author SDK has a different qualified world.

`examples/reference/profile.wat` is an independently written one-shot Canonical
ABI fixture with a limited allocator. It is not a general author SDK or a
production decoder. Build output and generated adversarial fixtures stay in
ignored `_build/`. The normal Elixir suite marks the actual native component
module skipped unless `WOTEX_HOME_COMPONENT_NATIVE_TESTS=1`; installer/IPC and
scripted process-retirement tests still run. Enabling that module without the
runner/fixtures fails visibly. An optimized runner can be built with `--release`
and selected using `WOTEX_HOME_COMPONENT_RUNNER=/absolute/path/to/runner` for
native tests, or `benchmark.py --runner /absolute/path/to/runner` for measurement.

## Authoring and Elixir integration

Implement the generated `light_power::Guest` trait as shown in
`examples/rust/src/lib.rs`. Only WIT-defined pure values cross the boundary.
A new source project with the same world can be built, staged and previewed
without recompiling Home. Use `wasm-tools validate` and `wasm-tools component wit`
for author diagnostics. The native host intentionally returns finite error
codes rather than potentially private guest text or backtraces. Package/type
compatibility does not establish semantic correctness.

In a trusted development IEx session (`WOTEX_HOME_GIT_DEPS=1 mise exec -- iex -S mix`),
create a private local artifact directory and stage one generated example:

```elixir
root = Path.expand("_build/local-component-store")
File.mkdir_p!(root)
File.chmod!(root, 0o700)
{:ok, digest} = WotexHome.Plugins.Bundle.install(root, Path.expand("_build/component-fixtures/rust.wasm"))
{:ok, runner} = WotexHome.Plugins.Runner.start_link(root: root, executable: Path.expand("_build/component-native/debug/woh-component-runner"))
WotexHome.Plugins.Runner.preview(runner, digest, :decode_power, <<255, 255>>)
WotexHome.Plugins.Runner.preview(runner, digest, :encode_power, false)
```

`Bundle.install/2` is trusted local staging. Its root must already be a private
0700 directory. It checks portable component framing, writes a private complete
staging directory and atomically publishes the component/closed manifest under
its digest. It verifies existing bytes on an exact retry. It does not qualify
world compatibility until preview, persist an active pointer, accept URLs or
provide crash/power-loss durability. Abandoned `.stage-*` directories are inert;
remove them only with no installer running. Published bytes are revalidated
before every call and hashed again in the worker.

For an explicitly enabled Home host, set the trusted application value
`:component_preview` to `[root: absolute_private_artifact_root, executable:
absolute_runner_path]` before host startup. The runner is the last supervised
child, so its failure does not restart Store or device workers. Call
`WotexHome.Authority.profile_preview(WotexHome.Host.authority(), digest,
:decode_power, payload)` through the application boundary. The returned
`unqualified_profile_preview` contains exact component/WIT identities and a
nested typed result; it has no observation or command authority. The default
host starts no component worker. There is no public socket plugin operation.

The executable path is trusted host configuration and never guest metadata or
an API client field. Starting a component process removes the inherited
environment, uses no shell/arguments and sends bounded component bytes rather
than paths. Wasm has no filesystem/network imports. The same-user native
compiler still has OS permissions: signed host sandbox/native-memory policy,
production artifact retention and durable activation remain open delivery gates.
Do not copy this binary into an inventoried app, OTP release or firmware without
the owning native/legal/containment checks.
