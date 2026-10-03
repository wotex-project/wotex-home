defmodule WotexHome.Plugins.Runner do
  @moduledoc """
  OTP admission and retirement for disposable native component previews.

  One admitted job, no queue. The native process receives a closed bounded
  message and no filesystem path or inherited environment. A caller's death,
  timeout or supervisor stop closes its Port; the worker's EOF monitor and
  independent watchdog enforce native retirement. Nothing here commits facts
  or effects. Production host containment remains a separate requirement.
  """

  use GenServer
  import Bitwise
  alias WotexHome.Plugins.{Bundle, IPC}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def preview(runner, digest, operation, input) do
    GenServer.call(runner, {:preview, digest, operation, input}, 6_000)
  catch
    :exit, _ -> {:error, :runner_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    executable = Keyword.get(opts, :executable)
    root = Keyword.get(opts, :root)
    deadline = Keyword.get(opts, :deadline_ms, 5_000)

    with true <- is_binary(executable) and Path.type(executable) == :absolute,
         {:ok, %{type: :regular, mode: mode}} <- File.lstat(executable),
         true <- band(mode, 0o111) != 0,
         true <- is_binary(root) and Path.type(root) == :absolute,
         {:ok, %{type: :directory, mode: root_mode}} <- File.lstat(root),
         true <- band(root_mode, 0o777) == 0o700,
         true <- is_integer(deadline) and deadline in 50..5_000 do
      {:ok, %{executable: executable, root: root, deadline: deadline, active: nil}}
    else
      _ -> {:stop, :invalid_runner_config}
    end
  end

  @impl true
  def handle_call({:preview, digest, operation, input}, from, state) do
    cond do
      not (is_binary(digest) and byte_size(digest) == 64 and
               Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)) ->
        {:reply, {:error, :invalid_bundle}, state}

      IPC.input(operation, input) != :ok ->
        {:reply, {:error, :invalid_input}, state}

      state.active != nil ->
        {:reply, {:error, :component_capacity}, state}

      true ->
        parent = self()

        {:ok, job} =
          Task.start_link(fn ->
            result = execute(state, digest, operation, input)
            send(parent, {:completed, self(), result})
          end)

        active = %{
          job: job,
          job_monitor: Process.monitor(job),
          caller_monitor: Process.monitor(elem(from, 0)),
          from: from,
          timer: Process.send_after(self(), {:deadline, job}, state.deadline)
        }

        {:noreply, %{state | active: active}}
    end
  end

  @impl true
  def handle_info({:completed, job, result}, %{active: %{job: job}} = state),
    do: finish(state, result)

  def handle_info({:deadline, job}, %{active: %{job: job}} = state) do
    Process.exit(job, :kill)
    finish(state, {:error, :component_timeout})
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{active: active} = state)
      when not is_nil(active) do
    cond do
      monitor == active.caller_monitor ->
        Process.exit(active.job, :kill)
        {:noreply, %{state | active: cleanup(active)}}

      monitor == active.job_monitor ->
        finish(state, {:error, :native_crash})

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, job, reason}, %{active: %{job: job}} = state)
      when reason != :normal,
      do: finish(state, {:error, :native_crash})

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{active: %{job: job}}), do: Process.exit(job, :kill)
  def terminate(_, _), do: :ok

  defp finish(state, result) do
    GenServer.reply(state.active.from, result)
    {:noreply, %{state | active: cleanup(state.active)}}
  end

  defp cleanup(active) do
    Process.cancel_timer(active.timer)
    Process.demonitor(active.caller_monitor, [:flush])
    Process.demonitor(active.job_monitor, [:flush])
    nil
  end

  defp execute(state, digest, operation, input) do
    with {:ok, bundle} <- Bundle.read(state.root, digest) do
      Process.flag(:trap_exit, true)
      env = Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end)

      port =
        Port.open({:spawn_executable, String.to_charlist(state.executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :eof,
          {:args, []},
          {:env, env},
          {:cd, String.to_charlist(state.root)}
        ])

      try do
        true = Port.command(port, IPC.request(bundle, operation, input))
        result = receive_reply(port, <<>>, nil, operation, input)

        case result do
          {:response, value} -> {:ok, IPC.preview(bundle, value)}
          error -> error
        end
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    end
  rescue
    _ -> {:error, :native_crash}
  end

  # Stream mode checks the prefix before accepting a body. ERTS packet mode
  # would trust an unchecked native length prefix for its receive allocation.
  defp receive_reply(port, buffer, response, operation, input) do
    receive do
      {^port, {:data, bytes}} when byte_size(buffer) + byte_size(bytes) <= 12 ->
        joined = buffer <> bytes

        case joined do
          <<size::32, _::binary>> when size > 8 or size < 3 ->
            {:error, :invalid_response}

          <<size::32, body::binary>> when byte_size(body) > size ->
            {:error, :invalid_response}

          <<size::32, body::binary-size(size)>> ->
            case IPC.response(body, operation, input) do
              {:error, :invalid_response} -> {:error, :invalid_response}
              value -> receive_reply(port, joined, value, operation, input)
            end

          _ ->
            receive_reply(port, joined, response, operation, input)
        end

      {^port, {:data, _}} ->
        {:error, :invalid_response}

      {^port, {:exit_status, 0}} when not is_nil(response) ->
        {:response, response}

      {^port, {:exit_status, 124}} ->
        {:error, :component_timeout}

      {^port, {:exit_status, 152}} ->
        {:error, :resource_exhausted}

      {^port, {:exit_status, _}} ->
        {:error, :native_crash}

      {^port, :eof} ->
        receive_reply(port, buffer, response, operation, input)

      {:EXIT, ^port, :normal} ->
        receive_reply(port, buffer, response, operation, input)

      {:EXIT, _, _} ->
        {:error, :native_crash}
    end
  end
end
