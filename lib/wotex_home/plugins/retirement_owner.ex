defmodule WotexHome.Plugins.RetirementOwner do
  @moduledoc """
  Owns native preview retirement independently of Runner and caller lifetimes.

  `WotexHome.Plugins.Runner` lazily starts one fixed, locally registered owner
  without linking it to the Runner, caller or Host supervisor. Its hidden entry
  points are internal collaborators of Runner. One VM-wide slot covers a bounded
  bundle-loading worker, native execution and retirement; no successor is
  admitted while any of those phases remains outstanding.

  The owner monitors the original Runner and caller, retains the original Port,
  and validates its bounded response and exit status against the original
  monotonic deadline. Success requires a complete matching response and status 0
  before that deadline. A response by itself cannot complete the invocation;
  late output cannot replace an outcome already sent to Runner.

  On cancellation, deadline expiry, caller/Runner loss or invalid output, the
  owner discards response state and attempts one extra zero byte on the original
  stdin using a nonblocking Port write. This requests retirement from the native
  monitor; it is not another operation or an acknowledgement. Failed cancellation
  writes retain the slot while awaiting exit. No numeric OS PID is signalled.

  Only the original Port's `:exit_status` proves that external process has
  terminated. EOF, normal Port EXIT, a parsed response or elapsed time do not
  release native capacity. Before Port creation, completion or failure of the
  loading worker can release the unused slot. An abnormal Port loss without exit
  evidence fences new work.

  A VM-local persistent marker is set before loading or spawn and cleared only
  when no native Port was opened or its exit status was observed. If the owner
  dies with that marker set, a replacement refuses work with
  `{:error, :component_capacity}`. Runner/Host restart, timers and PID probes
  cannot reset this uncertainty; no administrative reset is provided. The marker
  contains only an invocation reference, never component input or private data.
  Whole-VM restart and production OS containment require separate qualification.
  """

  use GenServer
  alias WotexHome.Plugins.{Bundle, IPC}

  @marker {__MODULE__, :outstanding}

  @doc false
  def ensure_started do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      _ -> {:error, :runner_unavailable}
    end
  end

  @doc false
  def submit(owner, runner, caller, token, config, digest, operation, input, deadline) do
    GenServer.cast(
      owner,
      {:submit, runner, caller, token, config, digest, operation, input, deadline}
    )
  end

  @doc false
  def cancel(owner, token), do: GenServer.cast(owner, {:cancel, token})

  @impl true
  def init([]) do
    Process.flag(:trap_exit, true)
    {:ok, %{active: nil, fenced: :persistent_term.get(@marker, nil) != nil}}
  end

  @impl true
  def handle_cast(
        {:submit, runner, caller, token, config, digest, operation, input, deadline},
        state
      ) do
    cond do
      state.fenced or state.active != nil ->
        refused(runner, token, :component_capacity)
        {:noreply, state}

      not fresh?(deadline) or not Process.alive?(runner) or not Process.alive?(caller) ->
        refused(runner, token, :component_timeout)
        {:noreply, state}

      true ->
        :persistent_term.put(@marker, token)
        runner_monitor = Process.monitor(runner)
        caller_monitor = Process.monitor(caller)
        owner = self()

        {:ok, loader} =
          Task.start_link(fn ->
            send(owner, {:loaded, token, self(), Bundle.read(config.root, digest)})
          end)

        active = %{
          token: token,
          runner: runner,
          runner_monitor: runner_monitor,
          caller: caller,
          caller_monitor: caller_monitor,
          config: config,
          operation: operation,
          input: input,
          deadline: deadline,
          timer: Process.send_after(self(), {:deadline, token}, max(0, deadline - now())),
          loader: loader,
          loader_monitor: Process.monitor(loader),
          port: nil,
          bundle: nil,
          buffer: <<>>,
          response: nil,
          retiring: false,
          outcome_sent: false
        }

        {:noreply, %{state | active: active}}
    end
  end

  def handle_cast({:cancel, token}, %{active: %{token: token}} = state),
    do: {:noreply, retire(state, {:error, :component_timeout})}

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:loaded, token, loader, result},
        %{active: %{token: token, loader: loader}} = state
      ) do
    Process.demonitor(state.active.loader_monitor, [:flush])
    state = put_in(state.active, %{state.active | loader: nil, loader_monitor: nil})

    cond do
      state.active.retiring ->
        {:noreply, release(state)}

      not current?(state.active) ->
        {:noreply, state |> retire({:error, :component_timeout}) |> release()}

      true ->
        {:noreply, loaded(state, result)}
    end
  end

  def handle_info({:deadline, token}, %{active: %{token: token}} = state),
    do: {:noreply, retire(state, {:error, :component_timeout})}

  def handle_info({port, {:data, bytes}}, %{active: %{port: port, retiring: false}} = state)
      when is_port(port), do: {:noreply, response(state, bytes)}

  def handle_info({port, {:data, _}}, %{active: %{port: port}} = state) when is_port(port),
    do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{active: %{port: port}} = state)
      when is_port(port) do
    result =
      cond do
        not fresh?(state.active.deadline) ->
          {:error, :component_timeout}

        status == 0 and state.active.response != nil ->
          {:ok, IPC.preview(state.active.bundle, state.active.response)}

        status == 124 ->
          {:error, :component_timeout}

        status == 152 ->
          {:error, :resource_exhausted}

        true ->
          {:error, :native_crash}
      end

    # Exit status is the proof; closing a still-connected Port is only cleanup.
    close_retired_port(port)
    {:noreply, release(state, result)}
  end

  def handle_info({port, :eof}, %{active: %{port: port}} = state) when is_port(port),
    do: {:noreply, state}

  def handle_info({:EXIT, port, :normal}, %{active: %{port: port}} = state) when is_port(port),
    do: {:noreply, state}

  def handle_info({:EXIT, port, _}, %{active: %{port: port}} = state) when is_port(port),
    do: {:noreply, %{retire(state, {:error, :native_crash}) | fenced: true}}

  def handle_info({:DOWN, monitor, :process, _, _}, %{active: active} = state)
      when not is_nil(active) do
    cond do
      monitor == active.loader_monitor ->
        state = put_in(state.active, %{active | loader: nil, loader_monitor: nil})
        {:noreply, release(state, {:error, :native_crash})}

      monitor in [active.runner_monitor, active.caller_monitor] ->
        {:noreply, retire(state, {:error, :runner_unavailable})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    Map.update(status, :state, :redacted, fn state ->
      %{active: state.active != nil, fenced: state.fenced}
    end)
  end

  defp loaded(state, {:ok, bundle}) do
    env = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)

    opened =
      try do
        {:ok,
         Port.open({:spawn_executable, String.to_charlist(state.active.config.executable)}, [
           :binary,
           :exit_status,
           :use_stdio,
           :eof,
           {:args, []},
           {:env, env},
           {:cd, String.to_charlist(state.active.config.root)}
         ])}
      rescue
        _ -> {:error, :native_crash}
      end

    case opened do
      {:ok, port} ->
        state = put_in(state.active, %{state.active | port: port, bundle: bundle})

        if current?(state.active) and
             command(port, IPC.request(bundle, state.active.operation, state.active.input)),
           do: state,
           else: retire(state, {:error, :component_timeout})

      error ->
        release(state, error)
    end
  end

  defp loaded(state, error), do: release(state, error)

  defp response(state, bytes) when byte_size(state.active.buffer) + byte_size(bytes) <= 12 do
    joined = state.active.buffer <> bytes

    case joined do
      <<size::32, _::binary>> when size > 8 or size < 3 ->
        retire(state, {:error, :invalid_response})

      <<size::32, body::binary>> when byte_size(body) > size ->
        retire(state, {:error, :invalid_response})

      <<size::32, body::binary-size(size)>> ->
        case IPC.response(body, state.active.operation, state.active.input) do
          {:error, :invalid_response} -> retire(state, {:error, :invalid_response})
          value -> put_in(state.active, %{state.active | buffer: joined, response: value})
        end

      _ ->
        put_in(state.active.buffer, joined)
    end
  end

  defp response(state, _), do: retire(state, {:error, :invalid_response})

  defp retire(%{active: %{retiring: true}} = state, _), do: state

  defp retire(state, result) do
    state = outcome(state, result)
    active = %{state.active | retiring: true, buffer: <<>>, response: nil, bundle: nil}
    if active.loader, do: Process.exit(active.loader, :kill)
    if active.port, do: command(active.port, <<0>>)
    %{state | active: active}
  end

  defp outcome(%{active: %{outcome_sent: true}} = state, _), do: state

  defp outcome(state, result) do
    send(state.active.runner, {:component_outcome, self(), state.active.token, result})
    put_in(state.active.outcome_sent, true)
  end

  # Only reached before Port creation or after this Port's actual exit status.
  defp release(state, result \\ {:error, :native_crash}) do
    active = state.active
    Process.cancel_timer(active.timer)
    Process.demonitor(active.runner_monitor, [:flush])
    Process.demonitor(active.caller_monitor, [:flush])
    :persistent_term.erase(@marker)
    send(active.runner, {:component_retired, self(), active.token, result})
    %{state | active: nil}
  end

  defp refused(runner, token, reason) do
    send(runner, {:component_retired, self(), token, {:error, reason}})
  end

  defp command(port, bytes) do
    Port.command(port, bytes, [:nosuspend])
  rescue
    _ -> false
  end

  defp close_retired_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
  rescue
    _ -> :ok
  end

  defp current?(active),
    do:
      fresh?(active.deadline) and Process.alive?(active.runner) and Process.alive?(active.caller)

  defp fresh?(deadline), do: now() < deadline
  defp now, do: System.monotonic_time(:millisecond)
end
