defmodule ExMaude do
  @moduledoc """
  Elixir bindings for the Maude formal specification and verification system.

  ExMaude provides a high-level API for interacting with Maude, a formal
  specification language based on rewriting logic. It supports:

  - Term reduction and normalization
  - Module loading and management
  - Search operations for state space exploration
  - IoT rule conflict detection (`ExMaude.IoT`)
  - AI rule conflict detection (`ExMaude.AI`)
  - Pluggable backend architecture (Port, C-Node, NIF)

  ## Quick Start

      # Add `ExMaude.Pool.child_spec/1` to your application's supervision tree.

      # Reduce a term
      {:ok, result} = ExMaude.reduce("NAT", "1 + 2 + 3")
      # => {:ok, "6"}

      # Load a custom module
      :ok = ExMaude.load_file("/path/to/my-module.maude")

      # Search for states
      {:ok, states} = ExMaude.search("MY-MOD", "initial", "final", max_depth: 10)

  ## Configuration

      config :ex_maude,
        backend: :port,                # :port | :cnode | :nif
        maude_path: nil,               # config/env/installed binary/PATH
        pool_size: 4,                  # Worker processes
        pool_max_overflow: 2,          # Extra workers under load
        timeout: 5_000,                # Default command timeout
        use_pty: false,                # PTY wrapper opt-in (Port backend only)
        preload_modules: [],           # Modules loaded when workers start
        telemetry_include_commands: false

  ## Architecture

  ExMaude uses a pluggable backend architecture with a Poolboy worker pool.
  Each worker maintains a persistent Maude session.

  ```
                        ExMaude (Public API)
                              │
                    ExMaude.Backend (Behaviour)
                              │
        ┌─────────────────────┼─────────────────────┐
        │                     │                     │
        ▼                     ▼                     ▼
  Backend.Port         Backend.CNode         Backend.NIF
        │                     │                     │
        ▼                     ▼                     ▼
   Pipes + Maude CLI   Erlang Distribution   Rust-managed Maude
                       + C bridge process    subprocess (pipes)
  ```

  ## Backends

  All three backends run Maude as a **separate OS process** — a Maude crash
  never takes down the BEAM. They differ in transport and in how much
  native code runs inside the BEAM itself:

  | Backend | Transport | Notes |
  |---------|-----------|-------|
  | `:port` | Erlang Port over pipes | Default; no ExMaude native extension required |
  | `:cnode` | Erlang distribution to a C bridge | Needs epmd and the compiled bridge |
  | `:nif` | Rustler NIF driving subprocess pipes | Rust runs inside the BEAM; a native crash can crash the VM |

  """

  @doc """
  Reduces a term in the given module to its normal form.

  ## Examples

      ExMaude.reduce("NAT", "1 + 2")
      #=> {:ok, "3"}

      ExMaude.reduce("STRING", "\"hello\" + \" \" + \"world\"")
      #=> {:ok, "\"hello world\""}

  ## Options

    * `:timeout` - Maximum time in milliseconds (default: 5000)
  """
  @spec reduce(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate reduce(module, term, opts \\ []), to: ExMaude.Maude

  @doc """
  Rewrites a term using the rules in the given module.

  Unlike `reduce/3`, this applies rewrite rules (potentially non-deterministically)
  rather than just equations.

  ## Examples

      ExMaude.rewrite("MY-MOD", "initial-state", max_rewrites: 100)
      #=> {:ok, "final-state"}
  """
  @spec rewrite(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate rewrite(module, term, opts \\ []), to: ExMaude.Maude

  @doc """
  Searches for states reachable from an initial term.

  Uses Maude's `search` command to explore the state space defined by rewrite rules.

  ## Examples

      ExMaude.search("MY-MOD", "init", "target", max_depth: 10)
      #=> {:ok, [%{solution: 1, state_num: 5, substitution: %{"S" => "target"}}]}

  ## Options

    * `:max_depth` - Maximum search depth (default: 100)
    * `:max_solutions` - Maximum solutions to find (default: 1)
    * `:arrow` - Search arrow: `=>1` (one step), `=>+` (one or more),
      `=>*` (zero or more), `=>!` (terminal states only) (default: `=>*`)
    * `:condition` - Additional search condition (`such that ...`)
    * `:timeout` - Maximum time in milliseconds (default: 30000)
  """
  @spec search(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  defdelegate search(module, initial, pattern, opts \\ []), to: ExMaude.Maude

  @doc """
  Loads a Maude file into all pool workers.

  ## Examples

      ExMaude.load_file("/path/to/my-module.maude")
      #=> :ok

  Pass `pool: name` to load into a caller-owned named pool.
  """
  @spec load_file(Path.t(), keyword()) :: :ok | {:error, ExMaude.Error.t()}
  defdelegate load_file(path, opts \\ []), to: ExMaude.Maude

  @doc """
  Ensures every current worker has loaded the current contents of a file.

  Prefer this over `load_file/2` on any path that can run concurrently.
  See `ExMaude.Maude.ensure_file_loaded/2`.
  """
  @spec ensure_file_loaded(Path.t(), keyword()) :: :ok | {:error, ExMaude.Error.t()}
  defdelegate ensure_file_loaded(path, opts \\ []), to: ExMaude.Maude

  @doc """
  Loads a Maude module from a string.

  ## Examples

      ExMaude.load_module("fmod MY-MOD is sort Foo . endfm")
      #=> :ok

  Pass `pool: name` to load into a caller-owned named pool.
  """
  @spec load_module(String.t(), keyword()) :: :ok | {:error, ExMaude.Error.t()}
  defdelegate load_module(source, opts \\ []), to: ExMaude.Maude

  @doc """
  Executes a raw Maude command and returns the output.

  Use this for commands not covered by the high-level API.

  ## Examples

      ExMaude.execute("show module NAT .")
      #=> {:ok, "fmod NAT is ..."}
  """
  @spec execute(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate execute(command, opts \\ []), to: ExMaude.Maude

  @doc """
  Returns the Maude interpreter version.

  Runs `maude --version` on the resolved binary; works without a started
  pool.

  ## Examples

      ExMaude.version()
      #=> {:ok, "3.5.1"}
  """
  @spec version() :: {:ok, String.t()} | {:error, term()}
  defdelegate version(), to: ExMaude.Maude

  @doc """
  Parses a term in the given module without reducing it.

  Useful for checking syntax and seeing how Maude disambiguates a term.

  ## Examples

      ExMaude.parse("NAT", "1 + 2 + 3")
      #=> {:ok, "1 + 2 + 3"}

  ## Options

    * `:timeout` - Maximum time in milliseconds (default: 5000)
  """
  @spec parse(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate parse(module, term, opts \\ []), to: ExMaude.Maude

  @doc """
  Shows the definition of a loaded module.

  ## Examples

      ExMaude.show_module("NAT")
      #=> {:ok, "fmod NAT is ..."}
  """
  @spec show_module(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate show_module(module, opts \\ []), to: ExMaude.Maude

  @doc """
  Lists all loaded modules.

  ## Examples

      {:ok, modules} = ExMaude.list_modules()
  """
  @spec list_modules(keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate list_modules(opts \\ []), to: ExMaude.Maude

  @doc """
  Returns the path to the bundled IoT rules Maude module.
  """
  @spec iot_rules_path() :: Path.t()
  def iot_rules_path do
    :ex_maude
    |> :code.priv_dir()
    |> Path.join("maude/iot-rules.maude")
  end

  @doc """
  Returns the path to the bundled AI rules Maude module.

  The AI rule model covers tool-invocation arguments, capability grants,
  sovereignty constraints, authority levels, and approval gates.
  """
  @spec ai_rules_path() :: Path.t()
  def ai_rules_path do
    :ex_maude
    |> :code.priv_dir()
    |> Path.join("maude/ai-rules.maude")
  end
end
