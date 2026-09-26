# ExMaude

**Elixir bindings for the Maude formal verification system**

[![Hex.pm](https://img.shields.io/hexpm/v/ex_maude.svg)](https://hex.pm/packages/ex_maude) [![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ex_maude) [![CI](https://github.com/futhr/ex_maude/actions/workflows/ci.yml/badge.svg)](https://github.com/futhr/ex_maude/actions/workflows/ci.yml) [![Coverage](https://codecov.io/gh/futhr/ex_maude/branch/main/graph/badge.svg)](https://codecov.io/gh/futhr/ex_maude) [![License: MIT](https://img.shields.io/github/license/futhr/ex_maude)](https://opensource.org/licenses/MIT)

[Installation](#installation) |
[Quick Start](#quick-start) |
[Documentation](https://hexdocs.pm/ex_maude)

---

## Overview

ExMaude provides a high-level Elixir API for interacting with [Maude](https://maude.cs.illinois.edu/),
a formal specification language based on rewriting logic. Use ExMaude for:

- **Term Reduction** - Simplify expressions using equational logic
- **State Space Search** - Explore reachable states in system models  
- **Formal Verification** - Verify properties of concurrent and distributed systems
- **IoT Rule Conflict Detection** - Detect conflicts in physical-IoT automation rules
- **AI Rule Conflict Detection** - Verify multi-tenant agent policies, capability grants,
  sovereignty, authority levels, and approval gates

---

## Why Maude Instead of Native Erlang?

Maude isn't "better Erlang"; it solves a different problem.

Erlang is excellent for building concurrent, fault-tolerant applications. Maude
is special because it treats your system as mathematics: states are terms,
behavior is expressed as rewrite rules, and properties can be explored
systematically.

For ExMaude's IoT use case, Maude provides:

- **Declarative rules** - Describe what transitions mean instead of writing
  control flow
- **Equational reasoning** - Automatically normalize values using equations,
  including reasoning modulo properties such as associativity and commutativity
- **State-space search** - Explore many possible rule applications and execution
  orders, not merely one execution
- **Formal verification** - Check reachability, invariants, deadlocks, and
  potentially model-check temporal properties
- **Executable specifications** - Run and analyze the same formal model

For AI rules, ExMaude checks structured policies against its explicit Maude model. An AI model may propose different actions, while
Maude checks each structured rule or action for capability, authority,
sovereignty, approval, and cross-rule conflicts. It can explore nondeterministic
execution paths—what *could* happen—without estimating how probable each path
is. Probability and model-confidence scoring remain outside the current AI-rule
module. Verification results depend on the predicates and transitions represented
in that model.

You could implement the conflict detector in native Erlang, but you would also
need to implement—and trust—your own term-rewriting engine, canonicalization
rules, nondeterministic search, cycle detection, and possibly a model checker.
That becomes a substantial verification project by itself.

Maude's biggest advantage is when the question is:

> Can this happen under any valid sequence of rule applications?

Native Erlang is generally preferable when the question is simply:

> Please execute this known application workflow efficiently.

There are costs: an external process, serialization and parsing overhead,
another language to maintain, and a less familiar ecosystem. Maude earns its
place where formal reasoning and nondeterministic exploration are central;
ordinary application behavior should remain in Elixir/Erlang.

---

## Features

| Feature | Description |
|---------|-------------|
| **Port-based IPC** | Efficient communication via Erlang Ports |
| **Worker Pool** | Concurrent operations via Poolboy |
| **High-level API** | `reduce/3`, `rewrite/3`, `search/4`, and pool-wide module loading |
| **Output Parsing** | Structured parsing of Maude results |
| **Telemetry** | Built-in observability events |
| **IoT Module** | Formal conflict detection for physical-IoT automation rules |
| **AI Module** | Formal conflict detection for AI agent policies (capability, sovereignty, authority, approval) |

---

## Installation

### Requirements

- Elixir ~> 1.17
- Erlang/OTP 27+

Add `ex_maude` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_maude, "~> 0.4.3"}
  ]
end
```

Then install the Maude binary (the hex package ships only MIT-licensed
Elixir/Rust/C sources — Maude itself is GPL-licensed and installed separately):

```bash
mix deps.get
mix maude.install
```

The installer verifies the SHA-256 digest published by GitHub and fails closed
when a release asset has no valid digest. Official stable installers are
available for macOS arm64/x64 and Linux x64. On Linux arm64, configure a
system-provided Maude executable instead.

Already have Maude on your system? Skip the install task and either keep it on
your `PATH` or point the library at it:

```elixir
config :ex_maude, maude_path: "/usr/local/bin/maude"
```

---

## Quick Start

```elixir
# In your application supervision tree:
children = [
  ExMaude.Pool.child_spec(pool_size: 4)
]

# Reduce a term to normal form
{:ok, "6"} = ExMaude.reduce("NAT", "1 + 2 + 3")

# Search state space
{:ok, solutions} = ExMaude.search("MY-MODULE", "initial", "goal", max_depth: 10)

# Load a custom module
:ok = ExMaude.load_file("/path/to/my-module.maude")
```

---

## Configuration

```elixir
config :ex_maude,
  backend: :port,                      # :port | :cnode | :nif
  maude_path: nil,                     # config/env/installed binary/PATH resolution
  pool_size: 4,                        # Number of worker processes
  pool_max_overflow: 2,                # Extra workers under load
  timeout: 5_000,                      # Default command timeout (ms)
  max_response_bytes: 16_777_216,      # Per-command output ceiling (16 MiB)
  use_pty: false,                      # PTY wrapper opt-in (Port backend only)
  preload_modules: [],                 # Modules loaded when workers start
  telemetry_include_commands: false   # Keep command text out of telemetry
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `backend` | `atom()` | `:port` | Communication backend (`:port`, `:cnode`, `:nif`) |
| `maude_path` | `String.t()` | `nil` | Path to Maude; otherwise use `MAUDE_PATH`, an installed local binary, or `PATH` |
| `pool_size` | `integer()` | `4` | Number of Maude worker processes |
| `pool_max_overflow` | `integer()` | `2` | Extra workers allowed under load |
| `timeout` | `integer()` | `5000` | Default command timeout in ms |
| `max_response_bytes` | `integer()` | `16777216` | Maximum response bytes accepted before the worker is replaced |
| `use_pty` | `boolean()` | `false` | Wrap Maude in a PTY instead of pipes with `-interactive` |
| `preload_modules` | `[Path.t()]` | `[]` | Modules loaded by every worker at startup |
| `telemetry_include_commands` | `boolean()` | `false` | Include truncated Maude commands in server telemetry; opt in only when commands contain no secrets |

ExMaude is a library application: it starts no processes automatically. Add
`ExMaude.Pool.child_spec/1` wherever the pool belongs in your supervision tree.
Pass `:name` when you need multiple independent pools, then select one with the
`:pool` option accepted by `ExMaude.Pool` operations and the high-level API.
Runtime module preloads are tracked independently for each named pool.

By default the Port backend talks to `maude -interactive` over plain pipes — the same mode the C-Node and NIF backends use, and it needs no extra tooling. Set `use_pty: true` to wrap Maude in a PTY (`script`/`unbuffer`) instead.

### Backend Selection

The Hex package does not contain Maude. Install it with `mix maude.install`,
provide `MAUDE_PATH`, or keep `maude` on `PATH`.

```elixir
# Check available backends
ExMaude.Backend.available_backends()
#=> [:port]  # plus :cnode if maude_bridge is compiled, :nif if the NIF loaded

# Configure before the pool starts
config :ex_maude, backend: :cnode
```

Changing `:backend` does not replace workers already running in the pool.
Restart the host application's affected pools after changing it.

---

## API Reference

### Term Operations

```elixir
# Reduce using equations (deterministic)
ExMaude.reduce(module, term, opts \\ [])

# Rewrite using rules and equations
ExMaude.rewrite(module, term, opts \\ [])

# Search state space
ExMaude.search(module, initial, pattern, opts \\ [])
```

### Module Loading

```elixir
# Load or reload from a file immediately on every worker
ExMaude.load_file("/path/to/module.maude", pool: :verification_pool)

# Idempotent loading for paths reached concurrently at runtime
ExMaude.ensure_file_loaded("/path/to/module.maude", pool: :verification_pool)

# Load from string
ExMaude.load_module("""
fmod MY-NAT is
  sort MyNat .
  op zero : -> MyNat .
  op s : MyNat -> MyNat .
endfm
""", pool: :verification_pool)
```

Use `preload_modules` for modules known when the pool starts. For dynamic
paths, `ensure_file_loaded/2` serializes the first pool-wide load and remembers
source paths for replacement workers; keep those files available. String modules
use private temporary files removed when the pool exits; `load_file/2` deliberately
broadcasts every call and is appropriate when an explicit reload is required.

### Direct Execution

```elixir
# Execute raw Maude commands
{:ok, output} = ExMaude.execute("show modules .")

# Get Maude version
{:ok, version} = ExMaude.version()
```

---

## IoT Rule Conflict Detection

ExMaude includes a Maude model for four useful IoT conflict categories. Its
rule schema is inspired by the categories discussed in the
[AutoIoT paper](https://arxiv.org/abs/2411.10665), but it is a smaller custom
model rather than an implementation of the paper's full system.

```elixir
rules = [
  %{
    id: "motion-light",
    thing_id: "light-1",
    trigger: {:prop_eq, "motion", true},
    actions: [{:set_prop, "light-1", "state", "on"}],
    priority: 1
  },
  %{
    id: "night-mode",
    thing_id: "light-1",
    trigger: {:prop_gt, "time", 2300},
    actions: [{:set_prop, "light-1", "state", "off"}],
    priority: 1
  }
]

{:ok, conflicts} = ExMaude.IoT.detect_conflicts(rules)

# Run an isolated check with an attributable receipt
{:ok, receipt} = ExMaude.IoT.detect_conflicts_with_receipt(rules)
receipt.semantic.digest       # same question and pinned model => same digest
receipt.execution.run_id      # unique to this execution
receipt.execution.findings    # findings from the four bundled checks
```

### Detected Conflict Types

| Type | Description |
|------|-------------|
| **State Conflict** | Same device, incompatible state changes |
| **Environment Conflict** | Opposing environmental effects |
| **State Cascading** | Rule output triggers conflicting rule |
| **State-Env Cascading** | Combined cascading effects |

See `ExMaude.IoT` for the full rule schema, trigger types, and action types.

`verify_safety_with_receipt/3` records a bounded search for a reachable bad
state. `verify_liveness_with_receipt/3` records a bounded search for a terminal
state missing a goal. Both return `{:ok, receipt}` even when the run times out
or produces malformed output; inspect `receipt.execution.completion` before
using findings. `:bounded_complete` means the requested bounded command
finished, not that safety or liveness was proved. A solution witness contains
the returned state and substitution, not a transition trace.

Receipt runs start a fresh Port worker with private snapshots of the bundled
IoT model, Maude executable, and adjacent `prelude.maude`; they do not use a
shared pool or accept arbitrary model text. The API requires an executable
with that adjacent prelude. `:timeout` covers preparation and execution;
`:max_response_bytes` and `:max_witness_bytes` limit evidence size. Caller
`:assumptions` are recorded in the semantic identity as assertions, not
verified facts. The profile has no OS memory limit. The legacy APIs and their
return values are unchanged.

---

## AI Rule Conflict Detection

ExMaude includes a Maude module for checking a defined AI-rule schema over
agents, capability grants, tool invocations, sovereignty, authority levels,
and approval gates.

```elixir
rules = [
  %{
    id: "approve-then-dose",
    agent_id: {"acme", "ph-controller"},
    trigger: {:prop_lt, "ph", {:int, 6}},
    invocations: [
      {:require_approval, "dosing_high_delta"},
      {:invoke_tool, "dose", %{"ml" => 50}, "high_impact", :eu}
    ],
    capability_grants: [{:cap, "ph_dosing", "v1"}],
    authority_required: 2,
    priority: 1
  },
  %{
    id: "auto-dose",
    agent_id: {"acme", "ph-controller"},
    trigger: {:prop_lt, "ph", {:int, 5}},
    invocations: [
      {:invoke_tool, "dose", %{"ml" => 100}, "high_impact", :eu}
    ],
    priority: 1
  }
]

{:ok, conflicts} = ExMaude.AI.detect_conflicts(rules, jurisdictions: [:eu, :ch])
# => [%{type: :approval_gate_bypass, rule1: "auto-dose", rule2: nil, ...}]
```

### Detected Conflict Types

| Type | Detection | Description |
|------|-----------|-------------|
| **Tool Call Conflict** | pairwise | Same agent, same tool, conflicting required arguments |
| **Capability Shadowing** | pairwise | Two rules grant the same capability at equal priority within a tenant |
| **Pack Tool Composition Mismatch** | pairwise | Same capability name, mismatched type-shape signatures |
| **Authority Escalation** | pairwise | Rule grants a capability another rule requires at higher authority |
| **Agent Loop Cascade** | pairwise | One rule's capability grants another rule's required capability |
| **Sovereignty Violation** | single-rule | Tool invocation routes through a forbidden jurisdiction |
| **Approval Gate Bypass** | single-rule | High-impact invocation reachable without an approval gate |

### When to choose AI rules over IoT rules

Use `ExMaude.IoT` for Things, Properties, and Actions in a single deployment
(one building, one factory, one farm). Use `ExMaude.AI` for Agents with capability
ontologies, tool-invocation arguments, tenant scoping, sovereignty, authority levels,
or approval gates. Both can coexist — the templates and APIs are independent.

### Unsupported predicates

`:contains` and `:matches` are not implemented by `ai-rules.maude`. The
validator rejects them explicitly. Evaluate string or regex predicates in the
component that owns their matching semantics.

See `ExMaude.AI` for the full rule schema, predicate vocabulary, and invocation types.

---

## Telemetry

ExMaude emits telemetry events compatible with Prometheus, OpenTelemetry, and other exporters.
Durations and system timestamps use native time units. Counts and byte sizes
retain their stated units.

### Events

| Event | Description |
|-------|-------------|
| `[:ex_maude, :command, :start]` | Command execution started |
| `[:ex_maude, :command, :stop]` | Command execution completed |
| `[:ex_maude, :command, :exception]` | Command raised an exception |
| `[:ex_maude, :server, :command_start]` | Backend command started |
| `[:ex_maude, :server, :command_complete]` | Backend command completed |
| `[:ex_maude, :pool, :checkout, :start]` | Pool checkout started |
| `[:ex_maude, :pool, :checkout, :stop]` | Pool checkout completed |
| `[:ex_maude, :iot, :detect_conflicts, :start]` | IoT conflict detection started |
| `[:ex_maude, :iot, :detect_conflicts, :stop]` | IoT conflict detection completed |
| `[:ex_maude, :ai, :detect_conflicts, :start]` | AI conflict detection started |
| `[:ex_maude, :ai, :detect_conflicts, :stop]` | AI conflict detection completed |

### Measurements

- `duration` - Time in native units (convert with `System.convert_time_unit/3`)
- `system_time` - Wall clock time when event started
- `rule_count` - Number of rules (IoT and AI events)
- `conflict_count` - Conflicts detected (IoT and AI events)
- `command_bytes` - UTF-8 byte size of a backend command

### Metadata

- `operation` - Command type (`:reduce`, `:rewrite`, `:search`, `:execute`, `:parse`, `:load_file`, `:ensure_file_loaded`, `:load_module`)
- `module` - Maude module name
- `result` - `:ok` or `:error`
- `template` - Conflict-detection template in use (`:iot_rules` or `:ai_rules`)

Raw command text is absent by default because Maude terms may contain
credentials or policy data. Set `telemetry_include_commands: true` only after
reviewing that risk; opted-in text is truncated to 100 characters.

### Example: Prometheus Metrics

```elixir
# In your application's telemetry module
defp metrics do
  [
    counter("ex_maude.command.stop.count", tags: [:operation, :result]),
    distribution("ex_maude.command.stop.duration",
      unit: {:native, :millisecond},
      tags: [:operation, :result]
    ),
    last_value("ex_maude.iot.detect_conflicts.stop.conflict_count")
  ]
end
```

### Example: Custom Handler

```elixir
:telemetry.attach(
  "my-logger",
  [:ex_maude, :command, :stop],
  fn _, %{duration: d}, %{operation: op, result: r}, _ ->
    ms = System.convert_time_unit(d, :native, :millisecond)
    Logger.info("ExMaude #{op}: #{r} in #{ms}ms")
  end,
  nil
)
```

For complete event documentation, see `ExMaude.Telemetry`.

---

## Architecture

ExMaude uses a pluggable backend architecture, allowing different communication strategies:

```
                        ExMaude (Public API)
                              │
                    ExMaude.Backend (Behaviour)
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
ExMaude.Backend.Port   ExMaude.Backend.CNode   ExMaude.Backend.NIF
        │                     │                     │
        ▼                     ▼                     ▼
  Pipes + Maude CLI   Erlang Distribution    Rust-managed Maude
                      + maude_bridge         subprocess via Rustler
```

All three backends run Maude as a **separate OS process** — a Maude crash never
takes down the BEAM. They differ in transport and in how much native code runs
inside the BEAM itself:

| Backend | Transport | Notes |
|---------|-----------|-------|
| **Port** | Erlang Port over pipes | Default; no ExMaude native extension required |
| **C-Node** | Erlang distribution to a C bridge | Requires `epmd` and the compiled bridge |
| **NIF** | Rustler NIF driving subprocess pipes | Rust runs in-BEAM; a native crash can crash the VM |

### Module Overview

```
ExMaude
    ├── ExMaude.Backend    Backend behaviour and selection
    ├── ExMaude.Binary     Binary lookup and platform detection
    ├── ExMaude.Maude      High-level command builders (reduce, rewrite, search)
    ├── ExMaude.Pool       Poolboy worker pool management
    ├── ExMaude.Server     Dispatches calls to each worker's backend
    ├── ExMaude.Parser     Output parsing utilities
    ├── ExMaude.Telemetry  Telemetry events and helpers
    ├── ExMaude.IoT        IoT rule conflict detection (Things, Properties, Actions)
    └── ExMaude.AI         AI rule conflict detection (Agents, Capabilities, Invocations)
```

---

## Development

```bash
mix setup # Setup
mix test  # Run tests
mix check --no-retry # Run all quality checks, including previously passing ones
mix docs  # Generate documentation
```

### Running Benchmarks

```bash
mix bench              # Parser benchmarks
mix bench.backends     # Benchmark every backend available in this VM
mix bench.backends.all # Start distribution, then benchmark available backends
```

The C bridge builds automatically when a C compiler, Make, and Erlang's
`erl_interface` are available. Set `EX_MAUDE_BUILD_CNODE=0` to skip it for a
Port-only installation, or `EX_MAUDE_BUILD_CNODE=1` to require a build and
surface missing tools as errors. `CC`, `CFLAGS`, and `LDFLAGS` can customize
the native build.

**C-Node Testing:**
```bash
mix test.cnode # Run C-Node integration tests
```

**Note:** C-Node requires:
1. Compiled binary: `cd c_src && make`
2. The `mix bench.backends.all` and `mix test.cnode` aliases automatically handle Erlang distribution

---

## Performance

ExMaude includes local benchmarks for parser, pool, and backend behavior.

### Benchmark Results

- **[bench/output/benchmarks.md](bench/output/benchmarks.md)** - Parser and Maude integration benchmarks

Backend performance depends on the Maude model, response size, platform, and
concurrency. `mix bench.backends` starts each available worker before timing
and writes a local comparison to `bench/output/backend_comparison.md`. Start
with Port and change backend only when a workload-specific benchmark supports
the choice.

### Running Benchmarks

See [Development](#development) section for benchmark commands.

---

## Interactive Notebooks

Explore ExMaude interactively with Livebook:

The notebooks form a learning path — follow them in order for a gradual introduction to Maude and formal verification:

| Notebook | Description | Livebook |
|----------|-------------|----------|
| [Quick Start](notebooks/quickstart.livemd) | First contact: reduce, parse, modules, error handling | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fquickstart.livemd) |
| [Term Rewriting](notebooks/rewriting.livemd) | Equations vs rules, search, and your first verification | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Frewriting.livemd) |
| [Advanced Usage](notebooks/advanced.livemd) | IoT rule-conflict detection, custom modules, pooling, telemetry | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fadvanced.livemd) |
| [AI Rules](notebooks/ai-rules.livemd) | Conflict detection for AI agent policies | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fai-rules.livemd) |
| [Benchmarks](notebooks/benchmarks.livemd) | Latency, concurrency, and how verification cost scales | [![Run in Livebook](https://livebook.dev/badge/v1/pink.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffuthr%2Fex_maude%2Fmain%2Fnotebooks%2Fbenchmarks.livemd) |

---

## Documentation

- [GitHub](https://github.com/futhr/ex_maude) - Documentation and source code
- [Usage Rules](usage-rules.md) - Integration and operational patterns

---

## References

- [Maude System](https://maude.cs.illinois.edu/) - Official Maude website
- [Maude Manual](https://maude.lcc.uma.es/maude-manual/) - Complete documentation
- [AutoIoT Paper](https://arxiv.org/abs/2411.10665) - IoT conflict detection research
- [Haskell Maude Bindings](https://hackage.haskell.org/package/maude) - Reference implementation

---

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## License

ExMaude is released under the MIT License. See [LICENSE](LICENSE) for details.
