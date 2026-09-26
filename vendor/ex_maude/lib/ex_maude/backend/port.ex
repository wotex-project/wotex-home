defmodule ExMaude.Backend.Port do
  @moduledoc """
  Port-based backend for ExMaude.

  This backend communicates with Maude via an Erlang Port over plain pipes,
  passing `-interactive` so Maude prints its prompt for response detection
  (the same mode the C-Node and NIF backends use).

  ## Features

    * Full process isolation - Maude crashes don't affect the BEAM
    * Works with any Maude installation
    * No native code compilation required

  ## Trade-offs

    * Port messaging and text parsing occur for every command
    * Regex-based error detection
    * Larger memory footprint per worker

  ## Configuration

      config :ex_maude,
        backend: :port,
        max_response_bytes: 16_777_216,
        use_pty: false  # Set to true to wrap Maude in a PTY (script/unbuffer)

  ## Timeouts and worker lifecycle

  Each command carries its own timeout. When it fires, the caller receives
  `{:error, %ExMaude.Error{type: :timeout}}` and the worker **stops** with
  `{:shutdown, :command_timeout}` so the pool replaces it with a fresh
  process. Maude has no way to cancel an in-flight computation, so a
  timed-out session is in an indeterminate state — reusing it could deliver
  the previous command's response to the next caller.
  """

  @behaviour ExMaude.Backend

  use GenServer
  require Logger

  alias ExMaude.{Binary, Command, Config, Error, Preloads, Telemetry}

  @default_timeout_ms 5_000
  @default_max_response_bytes 16 * 1024 * 1024
  @startup_timeout_ms 10_000
  @prompt_marker "Maude> "
  @prompt_marker_size byte_size(@prompt_marker)
  @maximum_response_bytes 2_147_483_000
  @maude_args ["-no-banner", "-no-wrap", "-no-advise"]

  @typedoc """
  The in-flight command, if any.

  The `ref` ties the pending command to its `{:command_timeout, ref}` timer
  message: a timer that fires after its command completed carries a stale
  ref and is ignored instead of cutting into the next command.
  """
  @type pending :: %{
          from: GenServer.from(),
          ref: reference(),
          timer: reference(),
          timeout: pos_integer()
        }

  @typedoc """
  Internal state for the Port backend GenServer.
  """
  @type t :: %__MODULE__{
          port: port() | nil,
          buffer: [binary()],
          buffer_size: non_neg_integer(),
          scan_tail: binary(),
          pending: pending() | nil,
          maude_path: String.t() | nil,
          os_pid: non_neg_integer() | nil,
          max_response_bytes: pos_integer()
        }

  defstruct port: nil,
            buffer: [],
            buffer_size: 0,
            scan_tail: "",
            pending: nil,
            maude_path: nil,
            os_pid: nil,
            max_response_bytes: @default_max_response_bytes

  # Client API

  @impl ExMaude.Backend
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl ExMaude.Backend
  def execute(server, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Config.timeout(@default_timeout_ms))

    try do
      GenServer.call(server, {:execute, command, timeout}, timeout + 1_000)
    catch
      :exit, {:timeout, _} ->
        {:error, Error.timeout(timeout)}

      :exit, {{:shutdown, reason}, _} ->
        # The worker stopped mid-call (e.g. it was checked out again in the
        # narrow window between a timeout reply and the pool reaping it).
        {:error, Error.pool_error({:worker_stopped, reason})}
    end
  end

  @impl ExMaude.Backend
  def load_file(server, path) do
    case execute(server, Command.load_file(path)) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl ExMaude.Backend
  def alive?(server) do
    GenServer.call(server, :alive?)
  catch
    :exit, _ -> false
  end

  @impl ExMaude.Backend
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # Server callbacks

  @impl GenServer
  def init(opts) do
    maude_path = opts[:maude_path] || find_maude_path()
    pool = Keyword.get(opts, :pool, :ex_maude_pool)

    preload_modules = preload_paths(opts, pool)

    startup_timeout = opts[:startup_timeout_ms] || @startup_timeout_ms
    max_response_bytes = response_limit(opts[:max_response_bytes])

    case start_maude_port(maude_path, opts) do
      {:ok, port} ->
        state = %__MODULE__{
          port: port,
          maude_path: maude_path,
          os_pid: port_os_pid(port),
          max_response_bytes: max_response_bytes
        }

        # Receipt tasks can be killed at their absolute deadline while this
        # worker is still starting. Retire the native process even when a
        # killed BEAM process cannot run terminate/2.
        maybe_guard_os_process(opts, state)

        case become_ready(state, preload_modules, startup_timeout) do
          {:ok, state} ->
            remember_preloads(opts, pool, preload_modules)
            emit_telemetry(:start, %{maude_path: maude_path})
            {:ok, state}

          {:error, reason} ->
            # init returning {:stop, _} skips terminate/2 — clean up inline.
            shutdown_maude(state)
            {:stop, {:maude_start_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:maude_start_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:execute, command, timeout}, from, %{pending: nil} = state) do
    command = Command.port_command(command)

    if Port.command(state.port, command, [:nosuspend]) do
      begin_command(command, timeout, from, state)
    else
      {:reply, {:error, Error.new(:busy, "Maude input pipe is full")}, state}
    end
  end

  def handle_call({:execute, _, _}, _, state) do
    # Unreachable through the pool (a worker serves one checked-out caller at
    # a time) but a direct caller could race the in-flight command.
    {:reply, {:error, Error.new(:busy, "another command is already in flight")}, state}
  end

  def handle_call(:alive?, _, state) do
    alive = port_alive?(state.port)
    {:reply, alive, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    chunk = IO.iodata_to_binary(data)
    chunks = [chunk | state.buffer]
    buffer_size = state.buffer_size + byte_size(chunk)

    case prompt_offset(state.scan_tail, chunk, state.buffer_size) do
      {:ok, offset} when offset <= state.max_response_bytes ->
        raw = assemble_response(chunks, offset)
        response = parse_response(raw)
        reply_to_pending(state.pending, response)

        emit_telemetry(:command_complete, %{
          success: match?({:ok, _}, response),
          response_size: byte_size(raw)
        })

        {:noreply, reset_response(%{state | pending: nil})}

      {:ok, _} ->
        response_too_large(%{state | buffer_size: buffer_size})

      :error when buffer_size > state.max_response_bytes + @prompt_marker_size ->
        response_too_large(%{state | buffer_size: buffer_size})

      :error ->
        {:noreply,
         %{
           state
           | buffer: chunks,
             buffer_size: buffer_size,
             scan_tail: next_scan_tail(state.scan_tail, chunk)
         }}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Maude process exited with status #{status}")
    emit_telemetry(:crash, %{exit_status: status})

    if state.pending do
      GenServer.reply(state.pending.from, {:error, Error.crash(status)})
    end

    {:stop, {:maude_exit, status}, %{state | pending: nil}}
  end

  def handle_info({:command_timeout, ref}, %{pending: %{ref: ref} = pending} = state) do
    GenServer.reply(pending.from, {:error, Error.timeout(pending.timeout)})

    emit_telemetry(:timeout, %{
      buffer_size: state.buffer_size,
      timeout_ms: pending.timeout
    })

    # Maude is still chewing on the timed-out command; its eventual output
    # would be misattributed to the next caller. Stop so the pool replaces
    # this worker with a fresh process. {:shutdown, _} keeps logs quiet.
    {:stop, {:shutdown, :command_timeout}, %{state | pending: nil}}
  end

  def handle_info({:command_timeout, _}, state) do
    # The timer fired after its command completed (cancel_timer lost the
    # race); the ref no longer matches the pending command, so drop it.
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.debug("ExMaude.Backend.Port terminating: #{inspect(reason)}")
    shutdown_maude(state)
    :ok
  end

  # Private functions

  defp begin_command(command, timeout, from, state) do
    ref = make_ref()
    timer = Process.send_after(self(), {:command_timeout, ref}, timeout)

    Telemetry.command_started(:port, command)

    pending = %{from: from, ref: ref, timer: timer, timeout: timeout}
    {:noreply, reset_response(%{state | pending: pending})}
  end

  defp shutdown_maude(state) do
    if state.port do
      try do
        if port_alive?(state.port) do
          Port.command(state.port, "quit\n", [:nosuspend])
          Port.close(state.port)
        end
      rescue
        ArgumentError -> :ok
      end
    end

    kill_os_process(state.os_pid)
  end

  # A wedged Maude (e.g. mid-infinite-rewrite) never reads the `quit`, and
  # Port.close/1 does not signal the OS process — without this a timed-out
  # command would leak a CPU-pegged interpreter. In PTY mode the pid is the
  # wrapper's; killing it tears down its PTY and Maude with it.
  defp guard_os_process(worker, os_pid) do
    spawn(fn ->
      ref = Process.monitor(worker)

      receive do
        {:DOWN, ^ref, :process, ^worker, :normal} -> :ok
        {:DOWN, ^ref, :process, ^worker, {:shutdown, _}} -> :ok
        {:DOWN, ^ref, :process, ^worker, _} -> kill_os_process(os_pid)
      end
    end)
  end

  defp preload_paths(opts, pool) do
    if opts[:isolated_preloads],
      do: opts[:preload_modules] || [],
      else: Preloads.for_pool(pool, opts[:preload_modules])
  end

  defp maybe_guard_os_process(opts, state) do
    if opts[:isolated_preloads], do: guard_os_process(self(), state.os_pid)
  end

  defp remember_preloads(opts, pool, paths) do
    unless opts[:isolated_preloads], do: Preloads.mark_loaded(pool, paths)
  end

  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp start_maude_port(maude_path, opts) do
    maude_executable = find_executable(maude_path)
    use_pty = Keyword.get(opts, :use_pty, Application.get_env(:ex_maude, :use_pty, false))

    {wrapper_executable, wrapper_args} =
      resolve_launcher(use_pty, :os.type(), maude_executable)

    try do
      port =
        Port.open(
          {:spawn_executable, wrapper_executable},
          [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:args, wrapper_args},
            :stream
          ]
        )

      {:ok, port}
    rescue
      e -> {:error, e}
    end
  end

  @doc false
  # Maude only prints its `Maude>` prompt when it believes it is interactive:
  # either stdin is a TTY (PTY wrapper) or `-interactive` forces it. Every
  # branch must produce one of the two — a launcher with neither yields a
  # worker whose commands can never complete.
  #
  # PTY wrappers: macOS `script -q`, Linux `unbuffer` (expect) or `script -qc`.
  # When no wrapper exists (minimal containers), fall back to plain pipes
  # with `-interactive`, the same mode the NIF and C-Node backends use.
  @spec resolve_launcher(boolean(), {atom(), atom()}, String.t(), (String.t() -> String.t() | nil)) ::
          {String.t(), [String.t()]}
  def resolve_launcher(use_pty?, os_type, executable, finder \\ &System.find_executable/1)

  def resolve_launcher(false, _, executable, _) do
    {executable, ["-interactive" | @maude_args]}
  end

  def resolve_launcher(true, {:unix, :darwin}, executable, finder) do
    case finder.("script") do
      nil -> {executable, ["-interactive" | @maude_args]}
      script_path -> {script_path, ["-q", "/dev/null", executable | @maude_args]}
    end
  end

  def resolve_launcher(true, {:unix, _}, executable, finder) do
    # Linux: prefer `unbuffer` (from expect); fall back to `script -qc`
    # whose syntax differs from macOS.
    cond do
      unbuffer = finder.("unbuffer") ->
        {unbuffer, [executable | @maude_args]}

      script = finder.("script") ->
        cmd = Enum.map_join([executable | @maude_args], " ", &shell_quote/1)
        {script, ["-qc", cmd, "/dev/null"]}

      true ->
        {executable, ["-interactive" | @maude_args]}
    end
  end

  def resolve_launcher(true, _, executable, _) do
    {executable, ["-interactive" | @maude_args]}
  end

  defp shell_quote(argument) do
    "'" <> String.replace(argument, "'", "'\\''") <> "'"
  end

  defp find_executable(path) do
    case System.find_executable(path) do
      nil -> raise "Maude executable not found at #{path}"
      found -> found
    end
  end

  defp find_maude_path do
    Binary.find() || "maude"
  end

  defp become_ready(state, preload, startup_timeout) do
    with {:ok, state, _} <- wait_for_ready(state, startup_timeout) do
      preload_modules(state, preload, startup_timeout)
    end
  end

  defp wait_for_ready(state, startup_timeout) do
    deadline = System.monotonic_time(:millisecond) + startup_timeout
    wait_for_ready_until(state, "", deadline)
  end

  defp wait_for_ready_until(state, buffer, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {port, {:data, data}} when port == state.port ->
        buffer = buffer <> to_string(data)

        case prompt_offset("", buffer, 0) do
          {:ok, offset} when offset <= state.max_response_bytes ->
            {:ok, reset_response(state), binary_part(buffer, 0, offset)}

          {:ok, _} ->
            {:error, :response_too_large}

          :error when byte_size(buffer) > state.max_response_bytes + @prompt_marker_size ->
            {:error, :response_too_large}

          :error ->
            wait_for_ready_until(state, buffer, deadline)
        end

      {port, {:exit_status, status}} when port == state.port ->
        {:error, {:exited_during_startup, status}}
    after
      remaining ->
        Logger.error("Timeout waiting for Maude prompt")
        {:error, :no_prompt}
    end
  end

  defp preload_modules(state, [], _), do: {:ok, state}

  defp preload_modules(state, [path | rest], startup_timeout) do
    if File.exists?(path) do
      Port.command(state.port, Command.port_command(Command.load_file(path)), [:nosuspend])

      with {:ok, state, output} <- wait_for_ready(state, startup_timeout),
           {:ok, _} <- parse_response(output) do
        preload_modules(state, rest, startup_timeout)
      else
        {:error, reason} -> {:error, {:preload_failed, path, reason}}
      end
    else
      {:error, {:preload_failed, path, Error.file_not_found(path)}}
    end
  end

  defp parse_response(buffer), do: ExMaude.Parser.parse_backend_response(buffer)

  defp assemble_response(chunks, response_size) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> binary_part(0, response_size)
  end

  defp response_limit(bytes)
       when is_integer(bytes) and bytes in 1..@maximum_response_bytes,
       do: bytes

  defp response_limit(_), do: Config.max_response_bytes(@default_max_response_bytes)

  defp response_too_large(state) do
    error = Error.response_too_large(state.max_response_bytes)
    reply_to_pending(state.pending, {:error, error})

    emit_telemetry(:command_complete, %{
      success: false,
      response_size: state.buffer_size,
      max_response_bytes: state.max_response_bytes
    })

    {:stop, {:shutdown, :response_too_large}, reset_response(%{state | pending: nil})}
  end

  defp reply_to_pending(nil, _), do: :ok

  defp reply_to_pending(pending, response) do
    Process.cancel_timer(pending.timer)
    GenServer.reply(pending.from, response)
  end

  defp reset_response(state) do
    %{state | buffer: [], buffer_size: 0, scan_tail: ""}
  end

  defp next_scan_tail(tail, chunk) do
    combined = tail <> chunk
    start = max(byte_size(combined) - @prompt_marker_size, 0)
    binary_part(combined, start, byte_size(combined) - start)
  end

  defp prompt_offset(tail, chunk, preceding_size) do
    candidate = tail <> chunk
    base_offset = preceding_size - byte_size(tail)
    find_prompt(candidate, base_offset, 0)
  end

  defp find_prompt(candidate, base_offset, search_start) do
    scope_size = byte_size(candidate) - search_start

    case :binary.match(candidate, @prompt_marker, scope: {search_start, scope_size}) do
      {offset, _} ->
        absolute_offset = base_offset + offset

        if prompt_boundary?(candidate, offset, absolute_offset) do
          {:ok, absolute_offset}
        else
          find_prompt(candidate, base_offset, offset + 1)
        end

      :nomatch ->
        :error
    end
  end

  defp prompt_boundary?(_, _, 0), do: true

  defp prompt_boundary?(candidate, offset, _) when offset > 0 do
    :binary.at(candidate, offset - 1) in [?\n, ?\r]
  end

  defp prompt_boundary?(_, _, _), do: false

  defp port_alive?(port), do: Port.info(port) != nil

  defp emit_telemetry(event, measurements) do
    Telemetry.server_event(event, measurements, %{pid: self(), backend: :port})
  end
end
