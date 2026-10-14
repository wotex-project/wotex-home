defmodule WotexHome.Lifx.PowerDelivery do
  @moduledoc """
  Consumes retained explicit Light-power work through the owning Authority.

  The worker polls at the configured bounded interval, selects a finite revision
  window and asks Authority to deliver one original request at a time. Its scan
  cursor is transient; durable receipts and duplicate/handoff guards remain in
  Store, so restarting the worker cannot turn an uncertain handoff into a new
  request.

  This process retains no bearer, routing cache, report or SQLite connection.
  Device reads and writes follow Authority's current guards, and acknowledgement
  remains separate from observed state or physical outcome.
  """

  use GenServer
  alias WotexHome.Authority

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, 1_000)

    with %Authority{} = authority <- Keyword.get(opts, :authority),
         true <- is_integer(interval) and interval in 100..30_000,
         delivery when is_list(delivery) <- Keyword.get(opts, :delivery_opts, []),
         true <- Keyword.keyword?(delivery) do
      Process.send_after(self(), :poll, interval)

      {:ok,
       %{
         authority: authority,
         interval: interval,
         delivery: delivery,
         cursor: 0,
         cycle_end: nil,
         deferred: %{},
         last_result: :idle
       }}
    else
      _ -> {:stop, :invalid_power_delivery_owner}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    now = System.monotonic_time(:millisecond)

    state = %{
      state
      | deferred: Map.reject(state.deferred, fn {_revision, until} -> until <= now end)
    }

    next =
      if state.authority.power_dispatch,
        do: consume(state),
        else: %{state | last_result: :disabled}

    Process.send_after(self(), :poll, state.interval)
    {:noreply, next}
  end

  defp consume(state) do
    case Authority.pending_explicit_power(state.authority, state.cursor) do
      {:ok, %{requests: [], has_more: false}} ->
        %{state | cursor: 0, cycle_end: nil, last_result: :idle}

      {:ok, %{requests: requests, window_revision: window}} ->
        cutoff = state.cycle_end || window
        bounded = Enum.take_while(requests, &(&1.created_revision <= cutoff))
        state = %{state | cycle_end: cutoff}

        case {bounded,
              Enum.find(bounded, &(not Map.has_key?(state.deferred, &1.created_revision)))} do
          {[], _} ->
            %{state | cursor: 0, cycle_end: nil, last_result: :idle}

          {_, nil} ->
            %{state | cursor: List.last(bounded).created_revision, last_result: :deferred}

          {_, request} ->
            result = safe_delivery(state.authority, request, state.delivery)
            next = %{state | cursor: request.created_revision, last_result: disposition(result)}

            case result do
              {:ok, _} ->
                next

              {:error, _} ->
                %{
                  next
                  | deferred:
                      Map.put(
                        next.deferred,
                        request.created_revision,
                        System.monotonic_time(:millisecond) + 30_000
                      )
                }
            end
        end

      {:error, reason} ->
        %{state | last_result: reason}
    end
  end

  defp safe_delivery(authority, request, opts) do
    Authority.deliver_explicit_power(
      authority,
      request.principal_id,
      request.authority_epoch,
      request.operation_id,
      opts
    )
  rescue
    _ -> {:error, :delivery_unavailable}
  catch
    :exit, _ -> {:error, :delivery_unavailable}
  end

  defp disposition({:ok, receipt}), do: receipt.disposition
  defp disposition({:error, reason}), do: reason
end
