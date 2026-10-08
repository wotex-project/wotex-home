defmodule WotexHome.Durable.Store.ScheduledPower do
  @moduledoc "Store-derived scheduled power selection and scoped fresh report publication. No bearer, timer, connection or transport."
  alias WotexHome.Durable.Receipt
  alias WotexHome.Durable.Store.{Integrity, MaintenanceWriter, ObservationWriter, PowerCapture}
  import WotexHome.Durable.Store.SQL, only: [query: 2, query: 3]
  @max 9_223_372_036_854_775_807
  @denials ~w(invalid_guard_input not_scheduled_request stale_refresh_basis refresh_unavailable)a

  def pending(db, after_revision) when is_integer(after_revision) and after_revision in 0..@max do
    with :ok <- Integrity.validate_snapshot(db),
         :ok <- MaintenanceWriter.guard(db),
         {:ok, [[window_revision]]} <- query(db, "SELECT value FROM meta WHERE key='revision'"),
         {:ok, rows} <-
           query(
             db,
             """
             SELECT r.principal_id,r.authority_epoch,r.operation_id,c.created_revision
             FROM request_receipts r JOIN request_causal_roots c USING(principal_id,authority_epoch,operation_id)
             WHERE c.origin='schedule_occurrence' AND c.created_revision>? AND
                   r.disposition IN ('held','queued') AND r.capability_key='power' AND r.value_kind='boolean'
             ORDER BY c.created_revision LIMIT 17
             """,
             [after_revision]
           ) do
      selected = Enum.take(rows, 16)

      {:ok,
       %{
         window_revision: window_revision,
         requests:
           Enum.map(selected, fn [principal, epoch, operation, created] ->
             %{
               principal_id: principal,
               authority_epoch: epoch,
               operation_id: operation,
               created_revision: created
             }
           end),
         next_revision:
           case List.last(selected) do
             nil -> after_revision
             [_, _, _, created] -> created
           end,
         has_more: length(rows) > 16
       }}
    else
      error -> normalize(error)
    end
  end

  def pending(_, _), do: {:error, :invalid_guard_input}

  def refresh_basis(db, principal, epoch, operation, clock),
    do: PowerCapture.basis(db, principal, epoch, operation, clock, "schedule_occurrence", [:held])

  def delivery_basis(db, principal, epoch, operation, clock) do
    with {:ok, basis} <-
           PowerCapture.basis(db, principal, epoch, operation, clock, "schedule_occurrence", [
             :held,
             :queued
           ]) do
      if basis.receipt.disposition == :queued do
        case query(
               db,
               "SELECT o.source_epoch FROM request_execution e JOIN observation_current o ON o.thing_id=e.target_id AND o.capability_key='power' AND o.revision=e.baseline_revision WHERE e.principal_id=? AND e.authority_epoch=? AND e.operation_id=?",
               [principal, epoch, operation]
             ) do
          {:ok, [[source]]} -> {:ok, Map.put(basis, :baseline_source_epoch, source)}
          {:ok, []} -> {:error, :observation_unavailable}
          error -> normalize(error)
        end
      else
        {:ok, basis}
      end
    end
  end

  def commit_refresh(db, basis, pairs, clock) do
    case repeat_basis(db, basis, clock) do
      :ok ->
        ObservationWriter.record_lifx_refresh_batch(
          db,
          pairs,
          WotexHome.Durable.Store.ClockContext.receipt(clock)
        )

      {:error, reason} ->
        refusal(reason)
    end
  end

  def repeat_basis(db, %{receipt: %Receipt{} = receipt} = basis, clock) do
    case refresh_basis(
           db,
           receipt.principal_id,
           receipt.authority_epoch,
           receipt.operation_id,
           clock
         ) do
      {:ok, ^basis} -> :ok
      {:ok, _} -> {:error, :stale_refresh_basis}
      {:error, reason} -> {:error, reason}
    end
  end

  def repeat_basis(_, _, _), do: {:error, :invalid_guard_input}

  def refusal(reason),
    do: if(policy_denial?(reason), do: {:rollback, {:policy, reason}}, else: {:rollback, reason})

  def policy_denial?(reason),
    do: reason in @denials or WotexHome.Durable.Store.ExecutionWriter.inspection_policy?(reason)

  defp normalize({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize(_), do: {:error, :store_unavailable}
end
