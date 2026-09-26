defmodule ExMaude.Backend.NIF do
  @moduledoc """
  NIF-based backend for ExMaude using Rustler.

  Manages a Maude subprocess from Rust, communicating via stdin/stdout pipes
  through dedicated reader threads. It avoids an Erlang Port or distribution
  hop, but should be benchmarked with the caller's own workload. Like any NIF,
  the native extension shares the BEAM's OS process.

  ## Features

    * Per-command timeouts enforced inside the NIF
    * Runs all blocking operations on the `DirtyIo` scheduler
    * Structured error returns (`:timeout`, `:eof`, `:io_error`, `:lock_poisoned`)

  ## Trade-offs

    * **No process isolation** — a segfault in the NIF crashes the BEAM.
      Rustler wraps NIF entry points in `std::panic::catch_unwind`, so a
      Rust `panic!` becomes an Elixir exception; segfaults from `unsafe`
      code are still fatal.
    * More complex deployment than the Port backend.

  ## Configuration

      config :ex_maude,
        backend: :nif,
        max_response_bytes: 16_777_216

  ## Getting the NIF

  Published Hex packages use checksummed precompiled binaries for the supported
  targets below. The release pipeline generates the checksum file after the
  matching GitHub release assets exist and before publishing the package.

  A source checkout intentionally has an empty checksum file, so development
  builds must opt into compilation from source (requires a Rust toolchain):

      EX_MAUDE_BUILD=1 mix compile --force        # in this project
      EX_MAUDE_BUILD=1 mix deps.compile ex_maude  # as a dependency

  Use `:port` as the default when a precompiled NIF is unavailable and a local
  Rust build is not desired.
  """

  @behaviour ExMaude.Backend

  use GenServer
  require Logger

  alias ExMaude.{Binary, Command, Config, Error, Parser, Preloads, Telemetry}

  @default_timeout 30_000
  @default_max_response_bytes 16 * 1024 * 1024
  @maximum_response_bytes 2_147_483_000

  @typedoc """
  Internal state for the NIF backend GenServer.
  """
  @type t :: %__MODULE__{
          handle: reference() | nil,
          maude_path: String.t() | nil,
          max_response_bytes: pos_integer()
        }

  defstruct handle: nil,
            maude_path: nil,
            max_response_bytes: @default_max_response_bytes

  defmodule Native do
    @moduledoc false

    # Source builds are opt-in. A path dependency may share this checkout
    # (and its ignored build artifacts) with another project, while Rustler
    # itself is intentionally optional and therefore not inherited by
    # consumers. Letting an artifact force compilation would make consumer
    # builds depend on unrelated local state.
    @force_build System.get_env("EX_MAUDE_BUILD") in ["1", "true"]
    @checksum_file "checksum-Elixir.ExMaude.Backend.NIF.Native.exs"
    @has_precompiled (case File.read(@checksum_file) do
                        {:ok, content} ->
                          {checksums, _} = Code.eval_string(content)
                          map_size(checksums) > 0

                        _ ->
                          false
                      end)

    if @has_precompiled or @force_build do
      mix_config = Mix.Project.config()
      version = mix_config[:version]
      github_url = mix_config[:package][:links]["GitHub"]

      use RustlerPrecompiled,
        otp_app: :ex_maude,
        crate: "ex_maude_nif",
        base_url: "#{github_url}/releases/download/v#{version}",
        version: version,
        targets: ~w(
          aarch64-apple-darwin
          aarch64-unknown-linux-gnu
          aarch64-unknown-linux-musl
          x86_64-apple-darwin
          x86_64-unknown-linux-gnu
          x86_64-unknown-linux-musl
          x86_64-pc-windows-gnu
          x86_64-pc-windows-msvc
        ),
        force_build: @force_build
    end

    # NIF stubs — replaced at load time by Rust implementations.
    #
    # The specs include `{:error, term()}` because Rustler returns
    # `Err(rustler::Error::Term(t))` as the wrapped tuple `{:error, t}`
    # rather than raising. The Elixir wrapper pattern-matches on these.

    @doc false
    @spec nif_loaded() :: boolean()
    def nif_loaded, do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec start(String.t()) :: reference() | {:error, term()}
    def start(_), do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec start_with_timeout(String.t(), non_neg_integer()) :: reference() | {:error, term()}
    def start_with_timeout(_, _), do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec execute_with_timeout(reference(), String.t(), non_neg_integer()) ::
            binary() | {:error, term()}
    def execute_with_timeout(_, _, _), do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec execute_with_limit(reference(), String.t(), non_neg_integer(), pos_integer()) ::
            binary() | {:error, term()}
    def execute_with_limit(_, _, _, _), do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec stop(reference()) :: :ok | {:error, term()}
    def stop(_), do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec alive(reference()) :: boolean()
    def alive(_), do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec child_pid(reference()) :: non_neg_integer() | {:error, term()}
    def child_pid(_), do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec last_spawned_pid() :: non_neg_integer()
    def last_spawned_pid, do: :erlang.nif_error(:nif_not_loaded)
  end

  # Client API

  @impl ExMaude.Backend
  @doc """
  Starts the NIF backend worker.

  ## Options

    * `:maude_path` - Path to Maude executable (optional, auto-detected)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl ExMaude.Backend
  @doc """
  Executes a Maude command via NIF.

  ## Options

    * `:timeout` - Maximum time to wait in milliseconds (default: 30000)
  """
  @spec execute(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute(server, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(@default_timeout))

    try do
      GenServer.call(server, {:execute, command, timeout}, timeout + 1_000)
    catch
      :exit, {:timeout, _} ->
        {:error, Error.timeout(timeout)}

      :exit, {{:shutdown, reason}, _} ->
        # The worker stopped mid-call (e.g. it was checked out again in the
        # narrow window between a failure reply and the pool reaping it).
        {:error, Error.pool_error({:worker_stopped, reason})}
    end
  end

  @impl ExMaude.Backend
  @doc """
  Loads a Maude file via NIF.

  Uses application configuration `:timeout`, with a 30,000 ms fallback when
  unset. This function does not accept per-call options.
  """
  @spec load_file(GenServer.server(), Path.t()) :: :ok | {:error, term()}
  def load_file(server, path) do
    timeout = Config.timeout(@default_timeout)
    GenServer.call(server, {:load_file, path, timeout}, timeout + 1_000)
  catch
    :exit, {:timeout, _} ->
      {:error, Error.timeout(Config.timeout(@default_timeout))}

    :exit, {{:shutdown, reason}, _} ->
      {:error, Error.pool_error({:worker_stopped, reason})}
  end

  @impl ExMaude.Backend
  @doc """
  Checks if the NIF backend is alive.
  """
  @spec alive?(GenServer.server()) :: boolean()
  def alive?(server) do
    GenServer.call(server, :alive?)
  catch
    :exit, _ -> false
  end

  @impl ExMaude.Backend
  @doc """
  Stops the NIF backend worker.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # Server callbacks

  @impl GenServer
  def init(opts) do
    maude_path = opts[:maude_path] || Binary.find() || "maude"
    pool = Keyword.get(opts, :pool, :ex_maude_pool)
    preload_modules = Preloads.for_pool(pool, opts[:preload_modules])
    startup_timeout = opts[:startup_timeout_ms] || 10_000
    max_response_bytes = response_limit(opts[:max_response_bytes])

    case start_native(maude_path, startup_timeout) do
      {:ok, handle} ->
        case preload_native_modules(handle, preload_modules, max_response_bytes) do
          :ok ->
            Preloads.mark_loaded(pool, preload_modules)
            emit_telemetry(:start, %{maude_path: maude_path})

            {:ok,
             %__MODULE__{
               handle: handle,
               maude_path: maude_path,
               max_response_bytes: max_response_bytes
             }}

          {:error, reason} ->
            Native.stop(handle)
            {:stop, {:preload_failed, reason}}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:execute, command, timeout}, _, %{handle: handle} = state) do
    command = Command.normalize(command)
    Telemetry.command_started(:nif, command)

    case run_native_execute(handle, command, timeout, state.max_response_bytes) do
      {:ok, raw} ->
        result = Parser.parse_backend_response(raw)
        emit_telemetry(:command_complete, %{success: match?({:ok, _}, result)})
        {:reply, result, state}

      {:error, err} ->
        stop_on_native_failure(err, state)
    end
  end

  def handle_call({:load_file, path, timeout}, _, %{handle: handle} = state) do
    case run_native_execute(
           handle,
           Command.normalize(Command.load_file(path)),
           timeout,
           state.max_response_bytes
         ) do
      {:ok, raw} ->
        result =
          case Parser.parse_backend_response(raw) do
            {:ok, _} -> :ok
            {:error, _} = err -> err
          end

        {:reply, result, state}

      {:error, err} ->
        stop_on_native_failure(err, state)
    end
  end

  def handle_call(:alive?, _, %{handle: handle} = state) do
    alive =
      try do
        Native.alive(handle)
      rescue
        _ -> false
      end

    {:reply, alive, state}
  end

  @impl GenServer
  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def terminate(reason, %{handle: handle}) do
    Logger.debug("ExMaude.Backend.NIF terminating: #{inspect(reason)}")

    try do
      if handle, do: Native.stop(handle)
    rescue
      _ -> :ok
    end

    :ok
  end

  # Every error surfaced by the native layer (timeout, EOF, I/O failure,
  # poisoned lock) leaves the subprocess and its reader channel in an
  # untrustworthy state: Maude may still be computing, and its eventual
  # output sits in the channel where it would be served as the *next*
  # command's response. Reply, then stop so the pool starts a fresh worker.
  defp stop_on_native_failure(%Error{} = err, state) do
    if err.type == :timeout do
      emit_telemetry(:timeout, %{timeout_ms: err.details.timeout_ms})
    end

    emit_telemetry(:command_complete, %{success: false})
    {:stop, {:shutdown, {:native_failure, err.type}}, {:error, err}, state}
  end

  defp start_native(maude_path, startup_timeout) do
    case safe_call(fn -> Native.start_with_timeout(maude_path, startup_timeout) end) do
      {:ok, handle} when is_reference(handle) ->
        {:ok, handle}

      {:ok, other} ->
        {:error, {:nif_start_failed, Error.exception(:nif_error, inspect(other))}}

      {:error, %Error{type: :nif_not_loaded} = err} ->
        {:error, {:nif_not_loaded, err.message}}

      {:error, %Error{} = err} ->
        {:error, {:nif_start_failed, err}}
    end
  end

  defp run_native_execute(handle, command, timeout, max_response_bytes) do
    safe_call(fn ->
      Native.execute_with_limit(handle, command, timeout, max_response_bytes)
    end)
  end

  # Wraps a NIF call and maps both raised errors and returned `{:error, t}`
  # tuples into a uniform `{:ok, value} | {:error, %Error{}}` shape. The
  # NIFs we wrap return either a successful payload (`reference()` for
  # `start/1`, `binary()` for the execute functions) or `{:error, t}`.
  defp safe_call(fun) do
    case fun.() do
      output when is_binary(output) -> {:ok, output}
      handle when is_reference(handle) -> {:ok, handle}
      {:error, term} -> {:error, decode_nif_error(term)}
    end
  rescue
    e in [UndefinedFunctionError] ->
      {:error, nif_not_loaded(Exception.message(e))}

    e in [ErlangError] ->
      case Map.get(e, :original) do
        :nif_not_loaded ->
          {:error, nif_not_loaded("Rustler did not populate the NIF function table.")}

        term ->
          {:error, decode_nif_error(term)}
      end

    e ->
      {:error, Error.exception(:nif_error, Exception.message(e))}
  end

  defp decode_nif_error({:timeout, ms}) when is_integer(ms), do: Error.timeout(ms)
  defp decode_nif_error({:response_too_large, bytes}), do: Error.response_too_large(bytes)
  defp decode_nif_error(:eof), do: Error.crash(0)
  defp decode_nif_error({:io_error, msg}), do: Error.exception(:nif_error, msg)

  defp decode_nif_error({:lock_poisoned, what}),
    do: Error.exception(:nif_error, "lock poisoned: #{what}")

  defp decode_nif_error(other), do: Error.exception(:nif_error, inspect(other))

  defp nif_not_loaded(detail) do
    Error.exception(
      :nif_not_loaded,
      "NIF binary failed to load — set EX_MAUDE_BUILD=1 to build from source, " <>
        "or check that your platform is in the supported targets list. " <>
        "Underlying: #{detail}"
    )
  end

  defp preload_native_modules(_, [], _), do: :ok

  defp preload_native_modules(handle, [path | paths], max_response_bytes) do
    timeout = Config.timeout(@default_timeout)

    with {:ok, raw} <-
           run_native_execute(
             handle,
             Command.normalize(Command.load_file(path)),
             timeout,
             max_response_bytes
           ),
         {:ok, _} <- Parser.parse_backend_response(raw) do
      preload_native_modules(handle, paths, max_response_bytes)
    else
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp response_limit(bytes)
       when is_integer(bytes) and bytes in 1..@maximum_response_bytes,
       do: bytes

  defp response_limit(_), do: Config.max_response_bytes(@default_max_response_bytes)

  defp emit_telemetry(event, measurements) do
    Telemetry.server_event(event, measurements, %{pid: self(), backend: :nif})
  end
end
