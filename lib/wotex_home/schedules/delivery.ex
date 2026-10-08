defmodule WotexHome.Schedules.Delivery do
  @moduledoc "Bounded controller-owned temporal polling and delivery. Owns no clock confidence, bearer, Store connection or retained device data."
  use GenServer
  alias WotexHome.Authority

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, 100)
    delivery = Keyword.get(opts, :delivery_opts, [])

    with %Authority{} = authority <- Keyword.get(opts, :authority),
         true <- is_integer(interval) and interval in 100..1_000,
         true <- valid_delivery?(delivery) do
      Process.send_after(self(), :poll, interval)

      {:ok,
       %{
         authority: authority,
         interval: interval,
         delivery: delivery,
         cursor: 0,
         cycle_end: nil,
         last_poll: :idle,
         last_result: :idle
       }}
    else
      _ -> {:stop, :invalid_schedule_delivery_owner}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    next =
      if state.authority.power_dispatch, do: tick(state), else: %{state | last_result: :disabled}

    Process.send_after(self(), :poll, state.interval)
    {:noreply, next}
  end

  defp tick(state) do
    poll = Authority.consider_schedule(state.authority)
    state = %{state | last_poll: poll_state(poll)}

    case Authority.pending_scheduled_power(state.authority, state.cursor) do
      {:ok, %{requests: [], has_more: false}} ->
        reset(state)

      {:ok, %{requests: requests, window_revision: revision}} ->
        cutoff = state.cycle_end || revision

        case Enum.take_while(requests, &(&1.created_revision <= cutoff)) do
          [] -> reset(state)
          [request | _] -> deliver(%{state | cycle_end: cutoff}, request)
        end

      {:error, reason} ->
        %{state | last_result: reason}
    end
  end

  defp deliver(state, request) do
    result = safe_delivery(state, request)

    case result do
      {:ok, receipt} ->
        %{state | cursor: request.created_revision, last_result: receipt.disposition}

      {:error, reason} ->
        # Refusal cannot reject a claim/handoff raced by another worker. The
        # Store derives actual phase and preserves every spent reservation.
        _ =
          Authority.block_scheduled_power(
            state.authority,
            request.principal_id,
            request.authority_epoch,
            request.operation_id,
            reason
          )

        %{state | cursor: request.created_revision, last_result: reason}
    end
  end

  defp safe_delivery(state, request) do
    Authority.deliver_scheduled_power(
      state.authority,
      request.principal_id,
      request.authority_epoch,
      request.operation_id,
      state.delivery
    )
  rescue
    _ -> {:error, :delivery_unavailable}
  catch
    :exit, _ -> {:error, :delivery_unavailable}
  end

  defp poll_state({:ok, %{state: state}}), do: state
  defp poll_state({:error, reason}), do: reason
  defp reset(state), do: %{state | cursor: 0, cycle_end: nil, last_result: :idle}

  defp valid_delivery?(opts) when is_list(opts) do
    Keyword.keyword?(opts) and length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
      Enum.all?(
        Keyword.keys(opts),
        &(&1 in [:transport_factory, :ack_timeout_ms, :read_timeout_ms])
      ) and
      (not Keyword.has_key?(opts, :transport_factory) or is_function(opts[:transport_factory], 0)) and
      Enum.all?([:ack_timeout_ms, :read_timeout_ms], fn key ->
        value = Keyword.get(opts, key, 1_000)
        is_integer(value) and value in 1..5_000
      end)
  end

  defp valid_delivery?(_), do: false
end
