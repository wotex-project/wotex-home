defmodule WotexHome.Plugins.Runner do
  @moduledoc """
  Admits bounded, unqualified native component previews outside the BEAM.

  Start a runner with `start_link/1`, supplying an absolute `:executable` for the
  native preview helper and an absolute mode-0700 `:root` containing bundles
  staged by `WotexHome.Plugins.Bundle`. The executable must be a regular executable
  file. Optional `:deadline_ms` is an integer from 50 to 5,000, defaulting to 5,000;
  `:name` supplies the usual GenServer registration.

  `preview/4` takes the runner, a lowercase hex64 bundle digest and either
  `:decode_power` with a binary of at most two bytes, or `:encode_power` with a
  Boolean. It revalidates the installed bundle before native execution. A
  successful host run returns `{:ok, preview}` with `:scope` equal to
  `:unqualified_profile_preview`, component/WIT digests and a `:result` of
  `{:ok, value}` or `{:error, guest_reason}`. An outer `{:error, reason}` reports
  an admission, loading, protocol or lifecycle failure; an outer success does
  not require the guest operation itself to succeed.

  One aggregate slot per BEAM VM covers bundle loading, execution and retirement
  across all runner instances and restarts. Valid competing calls return
  `{:error, :component_capacity}` without loading another bundle or queuing work.
  Invalid digests and inputs retain `:invalid_bundle` and `:invalid_input` errors.
  There is no automatic retry.

  One original monotonic deadline includes loading, native work and response
  checking. Runner keeps an independent timer; `preview/4` also has a 6,000 ms
  outer call bound whose exits become `{:error, :runner_unavailable}`. Returning
  an error or `{:error, :component_timeout}` does not prove native termination.
  `WotexHome.Plugins.RetirementOwner` keeps the slot until it proves no Port was
  opened or observes the original native exit status. Losing that evidence can
  fence new work for the remainder of the VM, including after Runner restart.

  The helper receives bounded component bytes rather than a source path, with
  no arguments or inherited environment. Results commit no facts or effects and
  grant no profile activation or device authority. This optional development
  preview does not establish whole-VM restart safety, host-wide resource limits
  or production process containment.
  """

  use GenServer
  import Bitwise
  alias WotexHome.Plugins.{IPC, RetirementOwner}

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
        case RetirementOwner.ensure_started() do
          {:ok, owner} ->
            token = make_ref()
            deadline = System.monotonic_time(:millisecond) + state.deadline
            monitor = Process.monitor(owner)
            timer = Process.send_after(self(), {:deadline, token}, state.deadline)
            active = %{owner: owner, token: token, monitor: monitor, timer: timer, from: from}

            RetirementOwner.submit(
              owner,
              self(),
              elem(from, 0),
              token,
              state,
              digest,
              operation,
              input,
              deadline
            )

            {:noreply, %{state | active: active}}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  def handle_info(
        {:component_outcome, owner, token, result},
        %{active: %{owner: owner, token: token}} = state
      ),
      do: {:noreply, reply_once(state, result)}

  def handle_info(
        {:component_retired, owner, token, result},
        %{active: %{owner: owner, token: token}} = state
      ) do
    state = reply_once(state, result)
    Process.cancel_timer(state.active.timer)
    Process.demonitor(state.active.monitor, [:flush])
    {:noreply, %{state | active: nil}}
  end

  def handle_info({:deadline, token}, %{active: %{token: token}} = state) do
    RetirementOwner.cancel(state.active.owner, token)
    {:noreply, reply_once(state, {:error, :component_timeout})}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{active: %{monitor: monitor}} = state) do
    state = reply_once(state, {:error, :native_crash})
    Process.cancel_timer(state.active.timer)
    {:noreply, %{state | active: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{active: %{owner: owner, token: token}}),
    do: RetirementOwner.cancel(owner, token)

  def terminate(_, _), do: :ok

  defp reply_once(%{active: %{from: nil}} = state, _), do: state

  defp reply_once(state, result) do
    GenServer.reply(state.active.from, result)
    put_in(state.active.from, nil)
  end
end
