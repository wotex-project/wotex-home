defmodule WotexHome.Durable.Store.AttemptGuard do
  @moduledoc """
  Stateless, bounded attempt-history reader under the single Store writer.

  Call only on a schema-13-or-later integrity-checked connection, inside the current
  authority transaction, with Store-owned boot/time and compiled profile data.
  A passing read is transient: final handoff repeats it and commits the clock
  marker together. This module owns no clock, process, transport or permission.

  Counts every committed handoff irrespective of outcome. Old epochs/untimed
  history impose a complete cold-start window; they never become current timers.
  """

  alias WotexHome.Id
  import WotexHome.Durable.Store.SQL, only: [query: 3]
  @max_i64 9_223_372_036_854_775_807
  @keys [:profile, :window_ms, :max_handoffs, :min_gap_ms]

  @spec check(term(), String.t(), {String.t(), non_neg_integer()}, map()) ::
          :ok | {:error, term()}
  def check(db, target_id, {epoch, now_ms}, limits) do
    if Id.valid?(target_id) and Id.valid?(epoch) and integer?(now_ms) and valid_limits?(limits) do
      check_history(db, target_id, epoch, now_ms, limits, nil)
    else
      {:error, :corrupt_receipt}
    end
  end

  def check(_db, _target_id, _clock, _limits), do: {:error, :corrupt_receipt}

  @doc "Final enclosing handoff repeat excludes only its own tentative row; every other committed attempt still counts."
  def check_excluding(
        db,
        target_id,
        {epoch, now_ms},
        limits,
        {principal, authority, operation} = identity
      ) do
    if Id.valid?(target_id) and Id.valid?(epoch) and integer?(now_ms) and valid_limits?(limits) and
         Id.valid?(principal) and integer?(authority) and Id.valid?(operation),
       do: check_history(db, target_id, epoch, now_ms, limits, identity),
       else: {:error, :corrupt_receipt}
  end

  def check_excluding(_, _, _, _, _), do: {:error, :corrupt_receipt}

  def valid_limits?(limits) when is_map(limits) do
    Enum.sort(Map.keys(limits)) == Enum.sort(@keys) and Id.valid?(limits.profile) and
      is_integer(limits.window_ms) and limits.window_ms in 1..86_400_000 and
      is_integer(limits.max_handoffs) and limits.max_handoffs in 1..1_024 and
      is_integer(limits.min_gap_ms) and limits.min_gap_ms in 0..limits.window_ms
  end

  def valid_limits?(_limits), do: false

  defp check_history(db, target_id, epoch, now_ms, limits, excluding) do
    {filter, parameters} =
      case excluding do
        nil ->
          {"", []}

        {principal, authority, operation} ->
          {" AND NOT (principal_id=? AND authority_epoch=? AND operation_id=?)",
           [principal, authority, operation]}
      end

    with {:ok, [[latest, 0]]} <-
           query(
             db,
             "SELECT MAX(handoff_store_monotonic_ms), COALESCE(SUM(CASE WHEN typeof(handoff_store_monotonic_ms) != 'integer' OR handoff_store_monotonic_ms < 0 THEN 1 ELSE 0 END), 0) FROM request_execution WHERE effect_domain=? AND handoff_revision IS NOT NULL AND handoff_store_boot_epoch=?" <>
               filter,
             [target_id, epoch] ++ parameters
           ),
         true <- is_nil(latest) or (integer?(latest) and latest <= now_ms),
         {:ok, old} <-
           query(
             db,
             "SELECT 1 FROM request_execution WHERE effect_domain=? AND handoff_revision IS NOT NULL AND (handoff_store_boot_epoch IS NULL OR handoff_store_boot_epoch != ?)" <>
               filter <> " LIMIT 1",
             [target_id, epoch] ++ parameters
           ),
         {:ok, times} <-
           query(
             db,
             "SELECT handoff_store_monotonic_ms FROM request_execution WHERE effect_domain=? AND handoff_revision IS NOT NULL AND handoff_store_boot_epoch=?" <>
               filter <>
               " ORDER BY handoff_store_monotonic_ms DESC, handoff_revision DESC LIMIT ?",
             [target_id, epoch] ++ parameters ++ [limits.max_handoffs + 1]
           ),
         true <- old in [[], [[1]]],
         true <- Enum.all?(times, fn [ms] -> integer?(ms) and ms <= now_ms end) do
      recent = Enum.count(times, fn [ms] -> ms > now_ms - limits.window_ms end)

      cond do
        old != [] and now_ms < limits.window_ms -> {:error, :attempt_history_cold}
        recent >= limits.max_handoffs -> {:error, :attempt_rate_exhausted}
        times != [] and now_ms - hd(hd(times)) < limits.min_gap_ms -> {:error, :attempt_spacing}
        true -> :ok
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :corrupt_receipt}
    end
  end

  defp integer?(value), do: is_integer(value) and value >= 0 and value <= @max_i64
end
