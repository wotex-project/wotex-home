defmodule ExMaude.Server do
  @moduledoc """
  GenServer that manages a single Maude process.

  This module delegates to the configured backend (Port, C-Node, or NIF).
  See `ExMaude.Backend` for backend selection.

  ## Architecture

  Each Server maintains a persistent Maude session. Commands are sent via
  the configured backend and responses are collected until complete.

  ## Usage

  This module is typically used via `ExMaude.Pool` rather than directly:

      {:ok, pid} = ExMaude.Server.start_link([])
      {:ok, result} = ExMaude.Server.execute(pid, "reduce in NAT : 1 + 2 .")

  ## Configuration

  The following options can be passed to `start_link/1`:

    * `:maude_path` - Path to Maude executable (default: resolved by `ExMaude.Binary`)
    * `:preload_modules` - List of Maude files to load on startup
    * `:max_response_bytes` - Maximum response size (default: 16 MiB)

  ## Application Configuration

      config :ex_maude,
        backend: :port,              # :port | :cnode | :nif
        maude_path: nil,             # nil = env, local install, or system PATH
        use_pty: false,              # PTY wrapper opt-in (Port backend only)
        telemetry_include_commands: false

  """

  alias ExMaude.{Backend, Config}

  @default_timeout_ms 5_000

  @doc """
  Starts a new Maude server process using the configured backend.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Backend.impl().start_link(opts)
  end

  @doc """
  Executes a Maude command and waits for the result.

  ## Options

    * `:timeout` - Command deadline in ms, including pipe writes and reads.
      Defaults to application `:timeout`, or the backend default (Port: 5000;
      C-Node and NIF: 30000).
  """
  @spec execute(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute(server, command, opts \\ []) do
    backend_for(server).execute(server, command, opts)
  end

  @doc """
  Loads a Maude file into this server's session.
  """
  @spec load_file(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def load_file(server, path) do
    backend_for(server).load_file(server, path)
  end

  @doc """
  Checks if the Maude process is alive.
  """
  @spec alive?(GenServer.server()) :: boolean()
  def alive?(server) do
    backend_for(server).alive?(server)
  end

  @doc """
  Stops the Maude server.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    backend_for(server).stop(server)
  end

  @doc """
  Returns the default timeout in milliseconds.
  """
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: Config.timeout(@default_timeout_ms)

  defp backend_for(server) when is_pid(server) do
    with {:dictionary, dictionary} <- Process.info(server, :dictionary),
         {module, :init, 1} <- Keyword.get(dictionary, :"$initial_call"),
         true <- module in backend_modules() do
      module
    else
      _ -> Backend.impl()
    end
  end

  defp backend_for(_), do: Backend.impl()

  defp backend_modules do
    [ExMaude.Backend.Port, ExMaude.Backend.CNode, ExMaude.Backend.NIF]
  end
end
