defmodule WotexHome.Profiles.GenerationRunner do
  @moduledoc """
  Owns one temporary bounded provider-response channel without retrying it.

  After committing a guarded handoff reservation, Store calls `start/5` with
  an explicitly selected `WotexHome.Profiles.GenerationProvider`, private UTF-8
  document, output ceiling, timeout and opaque result token. Input is at most
  1,048,576 bytes, output is at most 262,144 bytes, and timeout is 1–30,000
  milliseconds. A separate helper makes the adapter's `GenServer.call/3` with
  `{:generate_profile, document, output_ceiling}`; success must contain nonempty
  UTF-8 bytes within that ceiling.

  The runner monitors Store and the helper, returning results only with this
  runner PID and the supplied token. `cancel/1`, timeout or owner loss kills the
  helper and closes this channel without restarting work. Payloads and arbitrary
  provider errors are omitted from diagnostic status.

  Stopping the channel cannot retract exported input or prove that an external
  model stopped. `WotexHome.Durable.Store` owns durable uncertainty and final
  candidate acceptance; trusted adapters separately enforce transport response
  bounds and model confinement.
  """

  use GenServer, restart: :temporary
  alias WotexHome.Profiles.GenerationProvider

  @doc "Starts an unlinked, monitored-owner response channel for an explicit bounded call."
  def start(provider, document, output_bytes, timeout_ms, token) do
    GenServer.start(__MODULE__, {self(), provider, document, output_bytes, timeout_ms, token})
  end

  @doc "Retires the channel; it neither retries nor asserts remote cancellation."
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  @impl true
  def init({owner, provider, document, output, timeout, token}) do
    with :ok <- GenerationProvider.validate(provider),
         true <-
           is_binary(document) and byte_size(document) in 1..1_048_576 and String.valid?(document),
         true <- is_integer(output) and output in 1..262_144,
         true <- is_integer(timeout) and timeout in 1..30000 and is_reference(token) do
      parent = self()
      Process.flag(:trap_exit, true)
      monitor = Process.monitor(owner)

      {helper, helper_monitor} =
        :erlang.spawn_opt(
          fn ->
            result = call_provider(provider.pid, document, output, timeout)
            send(parent, {:result, self(), result})
          end,
          [:link, :monitor]
        )

      timer = Process.send_after(self(), :deadline, timeout)

      {:ok,
       %{
         owner: owner,
         owner_monitor: monitor,
         token: token,
         helper: helper,
         helper_monitor: helper_monitor,
         timer: timer
       }}
    else
      _ -> {:stop, :generation_unavailable}
    end
  end

  @impl true
  def handle_info({:result, helper, result}, %{helper: helper} = state) do
    send(state.owner, {:generation_result, self(), state.token, result})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{owner_monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _, _}, %{helper_monitor: monitor} = state) do
    send(state.owner, {:generation_result, self(), state.token, {:error, :unknown}})
    {:stop, :normal, state}
  end

  def handle_info(:deadline, state) do
    send(state.owner, {:generation_result, self(), state.token, {:error, :deadline_expired}})
    {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_cast(:cancel, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    Process.demonitor(state.owner_monitor, [:flush])
    Process.demonitor(state.helper_monitor, [:flush])
    if Process.alive?(state.helper), do: Process.exit(state.helper, :kill)
    :ok
  end

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :private_generation_runner) |> Map.put(:message, :redacted)

  defp call_provider(pid, document, output, timeout) do
    case GenServer.call(pid, {:generate_profile, document, output}, timeout) do
      {:ok, bytes}
      when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= output ->
        if String.valid?(bytes), do: {:ok, bytes}, else: {:error, :invalid_response}

      {:error, :unavailable} ->
        {:error, :unavailable}

      _ ->
        {:error, :invalid_response}
    end
  catch
    :exit, {:timeout, _} -> {:error, :deadline_expired}
    _, _ -> {:error, :unknown}
  end
end
