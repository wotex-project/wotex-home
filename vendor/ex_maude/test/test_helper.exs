# Configure ExUnit
#
# Integration tests are excluded by default.
# Run `mix test --include integration` to run integration tests when Maude is installed.
#
# Network tests (downloading from GitHub) are always excluded by default.
# Run `mix test --include network` to run network-dependent tests.
#
# C-Node tests require the maude_bridge binary and distributed node.
# Run `mix test --include cnode --include integration` to run C-Node tests.
#
# NIF tests require the Rustler NIF to be compiled.
# Run `mix test --include nif --include integration` to run NIF tests.

# Benchmark regressions spawn a dev Mix process; mix check runs them separately.

# function_exported?/3 does not load modules, ExUnit randomizes test order,
# and whether `mix test` happens to preload task modules varies across
# Elixir versions — eagerly load every application module so the
# module-contract tests cannot flake on first-touch ordering.
{:ok, modules} = :application.get_key(:ex_maude, :modules)
Enum.each(modules, &Code.ensure_loaded!/1)

# Integration remains opt-in even when Maude happens to be installed on the
# developer's machine. `mix test --include integration` enables it; MaudeCase
# requires a working executable for tests that declare Maude availability.
ExUnit.start(exclude: [:integration, :network, :cnode, :nif, :benchmark])
