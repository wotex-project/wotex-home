# AGENTS.md

Guidance for AI agents working with ExMaude.

For detailed usage patterns and API guidelines, see [usage-rules.md](usage-rules.md).

## Project Overview

ExMaude is an Elixir library providing bindings to [Maude](https://maude.cs.illinois.edu/) formal verification system. It features a pluggable backend architecture with Poolboy worker pool management.

## Architecture

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

### Backend Comparison

| Backend | Transport | Requirements |
|---------|-----------|--------------|
| **Port** | Erlang Port over pipes | Default; requires only a Maude executable |
| **C-Node** | Erlang distribution to a C bridge | Requires `epmd` and the compiled bridge |
| **NIF** | Rustler NIF driving subprocess pipes | Requires a supported precompiled NIF or Rust toolchain |

All three backends run Maude as a separate OS process — a Maude crash never
takes down the BEAM.

### Module Overview

```
ExMaude (Main API)
    │
    ├── ExMaude.Backend         Backend behaviour and selection
    │   ├── Backend.Port        Pipe-based Port communication
    │   ├── Backend.CNode       Erlang C-Node bridge
    │   └── Backend.NIF         Rustler NIF subprocess driver
    │
    ├── ExMaude.Binary          Maude binary management & platform detection
    ├── ExMaude.Maude           High-level operations (reduce, rewrite, search)
    ├── ExMaude.Pool            Poolboy worker pool management
    ├── ExMaude.Server          Delegates to Backend.impl()
    ├── ExMaude.Parser          Output parsing utilities
    ├── ExMaude.Telemetry       Telemetry events and helpers
    │
    ├── ExMaude.IoT             IoT rule conflict detection API
    │   ├── IoT.Encoder         Rule-to-Maude encoding
    │   ├── IoT.Validator       Rule validation
    │   └── IoT.ConflictParser  Conflict output parsing
    │
    ├── ExMaude.Term            Structured term representation
    ├── ExMaude.Error           Structured error types
    └── ExMaude.Result.*        Result types (Reduction, Search, Solution)
```

## Key Files

| File | Purpose |
|------|---------|
| `lib/ex_maude.ex` | Main API module, delegates to Maude |
| `lib/ex_maude/backend.ex` | Backend behaviour definition and selection |
| `lib/ex_maude/backend/port.ex` | Port-based backend implementation |
| `lib/ex_maude/backend/cnode.ex` | C-Node backend implementation |
| `lib/ex_maude/backend/nif.ex` | Rustler NIF backend |
| `lib/ex_maude/binary.ex` | Maude binary management and platform detection |
| `lib/ex_maude/maude.ex` | High-level Maude operations |
| `lib/ex_maude/server.ex` | Server delegating to configured backend |
| `lib/ex_maude/pool.ex` | Poolboy worker pool |
| `lib/ex_maude/parser.ex` | Output parsing |
| `lib/ex_maude/telemetry.ex` | Telemetry events and span helper |
| `lib/ex_maude/iot.ex` | IoT conflict detection API |
| `lib/ex_maude/iot/encoder.ex` | Rule encoding to Maude syntax |
| `lib/ex_maude/iot/validator.ex` | Rule validation with depth limits |
| `lib/ex_maude/iot/conflict_parser.ex` | Conflict output parsing |
| `lib/ex_maude/term.ex` | Structured term type |
| `lib/ex_maude/error.ex` | Structured error types |
| `lib/ex_maude/result/reduction.ex` | Reduction result type |
| `lib/ex_maude/result/search.ex` | Search result type |
| `lib/ex_maude/result/solution.ex` | Solution type |
| `c_src/maude_bridge.c` | C-Node bridge source code |
| `c_src/Makefile` | C-Node compilation |
| `priv/maude/bin/` | Development-checkout Maude files; excluded from Hex |
| `priv/maude/iot-rules.maude` | IoT conflict detection Maude module |

## Development Commands

```bash
mix setup                       # Install deps
mix test                        # Run tests (unit only)
mix test --include integration  # Run with Maude
mix test --include network      # Run GitHub API tests
mix lint                        # Format + Credo + Dialyzer
mix check --no-retry             # All quality checks, ignoring cached failures
mix sobelow                     # Security analysis
mix docs                        # Generate docs
mix maude.install               # Install Maude binary
mix maude.install --check       # Check Maude availability
mix coveralls                   # Test coverage report (text)
mix coveralls.json              # Test coverage report (json/codecov)
mix bench                       # Run main benchmarks
mix bench.backends              # Run backend comparison benchmarks
```

## C-Node Compilation

The C-Node backend requires compilation:

```bash
cd c_src && make      # Compile maude_bridge binary
cd c_src && make clean  # Clean build artifacts
```

Or automatically via `elixir_make` during `mix compile`.

## Testing

- **Unit tests** - Run without Maude, test parsing/validation logic
- **Integration tests** - Tagged `@tag :integration`, require Maude binary
- **Network tests** - Tagged `@tag :network`, make GitHub API calls
- Use `ExMaude.MaudeCase` for integration test setup

Test structure:
```
test/
├── ex_maude/
│   ├── maude_test.exs        # Maude module tests
│   ├── pool_test.exs         # Pool tests
│   ├── server_test.exs       # Server tests
│   ├── parser_test.exs       # Parser unit tests
│   ├── telemetry_test.exs    # Telemetry event tests
│   ├── iot_test.exs          # IoT module tests
│   ├── error_test.exs        # Error type tests
│   ├── term_test.exs         # Term type tests
│   └── integration_test.exs  # Full integration tests
├── mix/tasks/                 # Mix task tests
└── support/
    └── maude_case.ex         # Shared integration test setup
```

## Telemetry Events

ExMaude emits standard telemetry events:

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:ex_maude, :command, :start]` | `system_time` | `operation`, `module` |
| `[:ex_maude, :command, :stop]` | `duration` | `operation`, `module`, `result` |
| `[:ex_maude, :command, :exception]` | `duration` | `operation`, `module`, `kind`, `reason` |
| `[:ex_maude, :server, :command_start]` | `system_time`, `command_bytes` | `pid`, `backend`; optional truncated `command` |
| `[:ex_maude, :server, :command_complete]` | `system_time`, optional `response_size` | `pid`, `backend`, `result` |
| `[:ex_maude, :pool, :checkout, :start]` | `system_time` | `backend` |
| `[:ex_maude, :pool, :checkout, :stop]` | `duration` | `result`, `backend` |
| `[:ex_maude, :iot, :detect_conflicts, :start]` | `system_time`, `rule_count` | - |
| `[:ex_maude, :iot, :detect_conflicts, :stop]` | `duration`, `conflict_count` | `result` |

See `ExMaude.Telemetry.events/0` for programmatic access.

## Error Handling

Command and backend errors normally use `ExMaude.Error` with the types below.
Rule validators return field-error lists or maps; verification APIs also return
counterexample tuples. Match the documented return type of each function.

| Type | Description |
|------|-------------|
| `:timeout` | Operation timed out |
| `:parse_error` | Maude syntax/parse error |
| `:module_not_found` | Module was not found |
| `:syntax_error` | Invalid Maude syntax |
| `:busy` | Worker already has an in-flight command |
| `:load_error` | Module load failed on one or more workers |
| `:maude_crash` | Maude process crashed |
| `:file_not_found` | File does not exist |
| `:pool_error` | Pool checkout failed |
| `:invalid_path` | Path validation failed |
| `:ambiguous_term` | Term has multiple parses |
| `:sort_error` | Sort/type mismatch |
| `:not_connected` / `:cnode_error` | C-node connectivity or protocol failure |
| `:nif_not_loaded` / `:nif_error` | NIF availability or runtime failure |
| `:validation` | Rule validation failed |
| `:unknown` | Unrecognized Maude error |

## Configuration

```elixir
config :ex_maude,
  backend: :port,                      # :port | :cnode | :nif
  maude_path: nil,                     # nil = env, local install, or system PATH
  pool_size: 4,                        # Worker processes
  pool_max_overflow: 2,                # Extra workers under load
  timeout: 5_000,                      # Default command timeout
  use_pty: false                       # PTY wrapper opt-in (Port backend)
```

ExMaude starts no supervision tree automatically. Host applications add
`ExMaude.Pool.child_spec/1` to their own tree and may use distinct `:name`
values for independent pools.

### Backend Selection

```elixir
# Check available backends
ExMaude.Backend.available_backends()
#=> [:port] or [:port, :cnode]

# Get current backend module
ExMaude.Backend.impl()
#=> ExMaude.Backend.Port
```

## Common Patterns

### Running Maude Commands

```elixir
# High-level API (preferred)
{:ok, result} = ExMaude.reduce("NAT", "1 + 2")
{:ok, solutions} = ExMaude.search("MOD", "init", "goal")

# Low-level with pool
ExMaude.Pool.transaction(fn worker ->
  ExMaude.Server.execute(worker, "reduce in NAT : 1 + 2 .")
end)
```

### Loading Modules

```elixir
# From file (explicitly broadcasts to all workers)
:ok = ExMaude.load_file("/path/to/module.maude")

# Idempotent load for concurrent runtime paths
:ok = ExMaude.ensure_file_loaded("/path/to/module.maude")

# From string
:ok = ExMaude.load_module("fmod TEST is ... endfm")

# IoT rules module
:ok = ExMaude.ensure_file_loaded(ExMaude.iot_rules_path())
```

### IoT Conflict Detection

```elixir
rules = [
  %{id: "r1", thing_id: "light", trigger: {:prop_eq, "motion", true},
    actions: [{:set_prop, "light", "state", "on"}], priority: 1},
  %{id: "r2", thing_id: "light", trigger: {:prop_gt, "time", 2300},
    actions: [{:set_prop, "light", "state", "off"}], priority: 1}
]

{:ok, conflicts} = ExMaude.IoT.detect_conflicts(rules)
```

## Commit Conventions

All commits must follow the [Conventional Commits](https://www.conventionalcommits.org/) specification. git_ops parses these to auto-generate CHANGELOG.md and determine version bumps.

Format: `type(optional scope): description`

Do not add `Co-Authored-By` or any AI/Claude attribution to commit messages.

| Type | Version bump | Changelog |
|------|-------------|-----------|
| `feat:` | minor | "Features" |
| `fix:` | patch | "Bug Fixes" |
| `feat!:` / `fix!:` / `BREAKING CHANGE:` | major | shown |
| `chore:`, `docs:`, `ci:`, `refactor:`, `style:`, `test:`, `build:` | none | hidden |

### Release Flow

1. `mix git_ops.release` — updates changelog, bumps version in mix.exs and README.md, commits, and tags
2. `git push --follow-tags` — pushes commit and tag
3. `release.yml` builds and publishes the precompiled NIF artifacts
4. After that workflow succeeds, `publish.yml` checks out and verifies the
   exact tagged commit, runs release gates, generates NIF checksums, and
   publishes to Hex

## References

- [usage-rules.md](usage-rules.md) - Detailed usage patterns
- [README.md](README.md) - Quick start guide
- [Maude System](https://maude.cs.illinois.edu/)
- [Maude Manual](https://maude.lcc.uma.es/maude-manual/)
- [AutoIoT Paper](https://arxiv.org/abs/2411.10665) - IoT conflict detection
