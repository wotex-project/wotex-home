defmodule ExMaude.Backend do
  @moduledoc """
  Behaviour for ExMaude communication backends.

  All backends must implement this behaviour to be used
  interchangeably by the ExMaude API. This enables swapping
  between different communication strategies:

    * `:port` - Erlang Port over pipes (default)
    * `:cnode` - C bridge over Erlang distribution
    * `:nif` - Rustler NIF managing subprocess pipes

  ## Configuration

      config :ex_maude,
        backend: :port  # :port | :cnode | :nif

  ## Example

      # Get the configured backend module
      backend = ExMaude.Backend.impl()

      # Start a worker
      {:ok, server} = backend.start_link([])

      # Execute a command
      {:ok, result} = backend.execute(server, "reduce in NAT : 1 + 2 .")

  """

  @type command :: String.t()
  @type result :: {:ok, String.t()} | {:error, term()}

  @doc """
  Starts a backend worker process.

  ## Options

    * `:maude_path` - Path to Maude executable (optional)
    * `:startup_timeout_ms` - Backend-specific startup wait in ms
    * `:preload_modules` - List of Maude files to load on startup

  Default command timeouts come from application configuration `:timeout`,
  with per-command overrides in `execute/3`.

  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Executes a Maude command and returns the result.

  ## Options

    * `:timeout` - Maximum time to wait in ms

  """
  @callback execute(server :: GenServer.server(), command(), keyword()) :: result()

  @doc """
  Checks if the backend worker is alive and ready.
  """
  @callback alive?(server :: GenServer.server()) :: boolean()

  @doc """
  Loads a Maude file into the session.
  """
  @callback load_file(server :: GenServer.server(), path :: Path.t()) :: :ok | {:error, term()}

  @doc """
  Stops the backend worker.
  """
  @callback stop(server :: GenServer.server()) :: :ok

  @typedoc "Backend module types"
  @type backend_module :: ExMaude.Backend.Port | ExMaude.Backend.CNode | ExMaude.Backend.NIF

  @typedoc "Backend configuration atoms"
  @type backend_type :: :port | :cnode | :nif

  @doc """
  Returns the backend implementation module based on configuration.

  Reads `:backend` from the `:ex_maude` application env (defaults to `:port`)
  and maps it to the implementation module.

  ## Examples

      ExMaude.Backend.impl()
      #=> ExMaude.Backend.Port

  """
  @spec impl() :: backend_module()
  def impl do
    case Application.get_env(:ex_maude, :backend, :port) do
      :port -> ExMaude.Backend.Port
      :cnode -> ExMaude.Backend.CNode
      :nif -> ExMaude.Backend.NIF
    end
  end

  @doc """
  Checks if a backend is available on this system.

  The Port backend is always available. C-Node requires the `maude_bridge`
  binary to be compiled. NIF reports available when its native function table
  has been loaded from either a precompiled binary or a source build (probed
  via a cheap `nif_loaded/0` NIF that raises `:nif_not_loaded` while the stub
  is in place).

  ## Examples

      ExMaude.Backend.available?(:port)
      #=> true

      ExMaude.Backend.available?(:cnode)
      #=> true if priv/maude_bridge has been compiled

      ExMaude.Backend.available?(:nif)
      #=> true if the NIF loaded for this platform

  """
  @spec available?(backend_type()) :: boolean()
  def available?(:port), do: true

  def available?(:cnode) do
    bridge_path = cnode_binary()
    ExMaude.Binary.executable?(bridge_path)
  end

  def available?(:nif) do
    Code.ensure_loaded?(ExMaude.Backend.NIF.Native) and probe_nif_loaded()
  end

  # Probes Rustler's load state: the Elixir stub `nif_loaded/0` raises
  # `:nif_not_loaded` until Rustler replaces it with the real function.
  defp probe_nif_loaded do
    ExMaude.Backend.NIF.Native.nif_loaded()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  Returns a list of all available backends on this system.
  """
  @spec available_backends() :: [atom()]
  def available_backends do
    Enum.filter([:port, :cnode, :nif], &available?/1)
  end

  @doc """
  Returns the path to the C-Node bridge binary.
  """
  @spec cnode_binary() :: Path.t()
  def cnode_binary do
    priv_dir = :code.priv_dir(:ex_maude)
    Path.join(priv_dir, "maude_bridge")
  end
end
